//! The workspace model: what the interface draws, folded from the event log.
//!
//! A vertical tab should read as
//!   `feature/parser · worktree · agent 3 · 4 files changed · tests passing`
//! rather than `Shell 7`, because that is how developers think about their
//! work. Every part of that label is derived here from events, so the label can
//! never disagree with what happened.

const std = @import("std");
const event_mod = @import("../events/event.zig");
const log_mod = @import("../events/log.zig");
const block_mod = @import("block.zig");
const idmod = @import("../core/id.zig");
const timeutil = @import("../core/time.zig");

pub const SessionId = idmod.SessionId;
pub const AgentId = idmod.AgentId;
pub const Timestamp = timeutil.Timestamp;

pub const SessionState = enum { open, closed };

pub const TestState = enum {
    /// No test command has run in this session.
    unknown,
    passing,
    failing,

    pub fn text(self: TestState) []const u8 {
        return switch (self) {
            .unknown => "tests not run",
            .passing => "tests passing",
            .failing => "tests failing",
        };
    }
};

pub const Session = struct {
    id: SessionId,
    state: SessionState = .open,
    openedAt: Timestamp,
    closedAt: ?Timestamp = null,
    workingDirectory: []const u8 = "",
    shell: ?[]const u8 = null,
    columns: u16 = 80,
    rows: u16 = 24,
    repository: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    worktree: ?[]const u8 = null,
    head: ?[]const u8 = null,
    dirtyFileCount: u32 = 0,
    changedFiles: usize = 0,
    commandCount: usize = 0,
    failedCommandCount: usize = 0,
    agents: []const AgentId = &.{},
    pendingApprovals: usize = 0,
    diagnosticCount: usize = 0,
    tests: TestState = .unknown,

    /// The label a tab shows. Written as facts separated by a middle dot, so it
    /// stays readable when parts are missing.
    pub fn writeLabel(self: Session, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var wrote = false;
        if (self.branch) |branch| {
            try w.writeAll(branch);
            wrote = true;
        } else if (self.repository) |repository| {
            try w.writeAll(repository);
            wrote = true;
        }
        if (self.worktree != null) {
            if (wrote) try w.writeAll(" · ");
            try w.writeAll("worktree");
            wrote = true;
        }
        if (self.agents.len > 0) {
            if (wrote) try w.writeAll(" · ");
            try w.print("{d} agent", .{self.agents.len});
            if (self.agents.len != 1) try w.writeAll("s");
            wrote = true;
        }
        if (self.changedFiles > 0) {
            if (wrote) try w.writeAll(" · ");
            try w.print("{d} file", .{self.changedFiles});
            if (self.changedFiles != 1) try w.writeAll("s");
            try w.writeAll(" changed");
            wrote = true;
        }
        if (self.tests != .unknown) {
            if (wrote) try w.writeAll(" · ");
            try w.writeAll(self.tests.text());
            wrote = true;
        }
        if (self.pendingApprovals > 0) {
            if (wrote) try w.writeAll(" · ");
            try w.print("{d} waiting for you", .{self.pendingApprovals});
            wrote = true;
        }
        if (!wrote) try w.writeAll(self.workingDirectory);
    }
};

pub const Workspace = struct {
    arena: std.mem.Allocator,
    sessions: std.AutoArrayHashMapUnmanaged([16]u8, Session) = .empty,
    blocks: block_mod.Index,
    /// Sequence of the last event folded in, so a client can ask for the rest.
    sequence: u64 = 0,

    pub fn build(arena: std.mem.Allocator, log: log_mod.Log) !Workspace {
        var workspace: Workspace = .{ .arena = arena, .blocks = try block_mod.Index.build(arena, log) };
        for (log.entries.items) |entry| try workspace.apply(entry);
        return workspace;
    }

    /// Fold one event into the model. The daemon calls this as events arrive;
    /// `build` calls it in a loop. Live state and replayed state are therefore
    /// produced by the same code.
    pub fn apply(self: *Workspace, entry: log_mod.Envelope) !void {
        self.sequence = entry.sequence;
        switch (entry.payload) {
            .session_opened => |e| {
                try self.sessions.put(self.arena, e.session.raw.bytes, .{
                    .id = e.session,
                    .openedAt = entry.at,
                    .workingDirectory = e.workingDirectory,
                    .shell = e.shell,
                    .columns = e.columns,
                    .rows = e.rows,
                    .repository = e.repository,
                    .branch = e.branch,
                    .worktree = e.worktree,
                });
            },
            .session_closed => |e| {
                const current = self.sessionPtr(e.session) orelse return;
                current.state = .closed;
                current.closedAt = entry.at;
            },
            .command_submitted => |e| {
                const current = self.sessionPtr(e.session) orelse return;
                current.commandCount += 1;
            },
            .command_finished => |e| {
                const current = self.sessionPtr(e.session) orelse return;
                if (e.exitStatus != 0) current.failedCommandCount += 1;
                // A command that looks like a test run sets the test state.
                if (self.blocks.get(e.block)) |block| {
                    const command = block.commandText orelse return;
                    if (std.ascii.indexOfIgnoreCase(command, "test") != null) {
                        current.tests = if (e.exitStatus == 0) .passing else .failing;
                    }
                }
            },
            .agent_started => |e| {
                const current = self.sessionPtr(e.session) orelse return;
                var agents: std.ArrayList(AgentId) = .{ .items = @constCast(current.agents), .capacity = current.agents.len };
                try agents.append(self.arena, e.agent);
                current.agents = agents.items;
            },
            .file_changed => |e| {
                const current = self.sessionPtr(e.session) orelse return;
                current.changedFiles += 1;
            },
            .approval_requested => |e| {
                const current = self.sessionPtr(e.session) orelse return;
                current.pendingApprovals += 1;
            },
            .approval_resolved => |e| {
                const current = self.sessionPtr(e.session) orelse return;
                if (current.pendingApprovals > 0) current.pendingApprovals -= 1;
            },
            .git_changed => |e| {
                const current = self.sessionPtr(e.session) orelse return;
                current.repository = e.repository;
                current.branch = e.branch;
                current.head = e.head;
                current.dirtyFileCount = e.dirtyFileCount;
            },
            .diagnostic => |e| {
                const current = self.sessionPtr(e.session) orelse return;
                current.diagnosticCount += 1;
            },
            else => {},
        }
    }

    fn sessionPtr(self: *Workspace, id: SessionId) ?*Session {
        return self.sessions.getPtr(id.raw.bytes);
    }

    pub fn session(self: Workspace, id: SessionId) ?Session {
        return self.sessions.get(id.raw.bytes);
    }

    pub fn openSessions(self: Workspace) !std.ArrayList(Session) {
        var out: std.ArrayList(Session) = .empty;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == .open) try out.append(self.arena, entry.value_ptr.*);
        }
        return out;
    }

    /// Sessions that need a person: an approval is waiting, or tests fail.
    pub fn needingAttention(self: Workspace) !std.ArrayList(Session) {
        var out: std.ArrayList(Session) = .empty;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const s = entry.value_ptr.*;
            if (s.pendingApprovals > 0 or s.tests == .failing or s.failedCommandCount > 0) {
                try out.append(self.arena, s);
            }
        }
        return out;
    }
};

const testing = std.testing;

test "a session tab reads as the work it holds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(71, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 72);
    const person: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "sean" };
    const robot: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .agent, .label = "agent 3" };
    const session = gen.next(SessionId);
    const agent = gen.next(AgentId);
    const block = gen.next(idmod.BlockId);
    var at = try Timestamp.parseIso("2026-09-04T20:00:00Z");

    _ = try log.append(.{ .session_opened = .{
        .session = session,
        .workingDirectory = "/home/user/zag",
        .repository = "zag",
        .branch = "feature/parser",
        .worktree = "/home/user/worktrees/parser",
    } }, .{ .at = at, .actor = person });

    _ = try log.append(.{ .agent_started = .{
        .agent = agent,
        .session = session,
        .request = "fix the parser",
        .provider = "local",
        .model = "coder",
        .policy = "repo-write-no-network",
    } }, .{ .at = at, .actor = robot });

    for (0..4) |_| {
        at = at.addNanos(timeutil.ns_per_s);
        _ = try log.append(.{ .file_changed = .{ .session = session, .path = "src/parser.zig", .changeKind = .modified, .agent = agent } }, .{ .at = at, .actor = robot });
    }

    _ = try log.append(.{ .command_submitted = .{ .block = block, .session = session, .commandText = "zig build test", .workingDirectory = "/home/user/zag" } }, .{ .at = at, .actor = robot });
    at = at.addNanos(timeutil.ns_per_s);
    _ = try log.append(.{ .command_finished = .{ .block = block, .session = session, .exitStatus = 0, .duration = timeutil.Duration.fromMillis(1500) } }, .{ .at = at, .actor = robot });

    const workspace = try Workspace.build(arena, log);
    const built = workspace.session(session).?;
    try testing.expectEqual(@as(usize, 4), built.changedFiles);
    try testing.expectEqual(@as(usize, 1), built.agents.len);
    try testing.expectEqual(TestState.passing, built.tests);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try built.writeLabel(&aw.writer);
    try testing.expectEqualStrings("feature/parser · worktree · 1 agent · 4 files changed · tests passing", aw.written());
}

test "sessions that need a person are listed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(73, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 74);
    const person: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person };
    const quiet = gen.next(SessionId);
    const noisy = gen.next(SessionId);
    const at = try Timestamp.parseIso("2026-09-04T20:00:00Z");

    _ = try log.append(.{ .session_opened = .{ .session = quiet, .workingDirectory = "/tmp/a" } }, .{ .at = at, .actor = person });
    _ = try log.append(.{ .session_opened = .{ .session = noisy, .workingDirectory = "/tmp/b" } }, .{ .at = at, .actor = person });
    _ = try log.append(.{ .approval_requested = .{
        .approval = gen.next(idmod.DecisionId),
        .session = noisy,
        .capability = "network.connect",
        .resource = "api.example.test",
        .promptText = "Let the agent reach api.example.test?",
        .policy = "P7",
    } }, .{ .at = at, .actor = person });

    const workspace = try Workspace.build(arena, log);
    const attention = try workspace.needingAttention();
    try testing.expectEqual(@as(usize, 1), attention.items.len);
    try testing.expect(attention.items[0].id.eql(noisy));

    var aw: std.Io.Writer.Allocating = .init(arena);
    try attention.items[0].writeLabel(&aw.writer);
    try testing.expectEqualStrings("1 waiting for you", aw.written());

    const open = try workspace.openSessions();
    try testing.expectEqual(@as(usize, 2), open.items.len);
}

test "closing a session is folded in" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(75, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 76);
    const person: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person };
    const session = gen.next(SessionId);
    const at = try Timestamp.parseIso("2026-09-04T20:00:00Z");

    _ = try log.append(.{ .session_opened = .{ .session = session, .workingDirectory = "/tmp" } }, .{ .at = at, .actor = person });
    _ = try log.append(.{ .session_closed = .{ .session = session, .exitStatus = 0, .reason = "the person closed the tab" } }, .{ .at = at.addNanos(timeutil.ns_per_s), .actor = person });

    const workspace = try Workspace.build(arena, log);
    try testing.expectEqual(SessionState.closed, workspace.session(session).?.state);
    try testing.expectEqual(@as(usize, 0), (try workspace.openSessions()).items.len);
    try testing.expectEqual(@as(u64, 2), workspace.sequence);
}
