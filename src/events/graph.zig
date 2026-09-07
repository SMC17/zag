//! The execution graph.
//!
//! An agent run that executes six commands, changes three files, waits for one
//! approval and produces a commit is not seven unrelated terminal blocks. It is
//! one causal graph. Because every event carries `causedBy` and `correlation`,
//! the graph is derived from the log rather than tracked separately, so it
//! cannot fall out of step with what actually happened.
//!
//! This is what makes replay, debugging, evaluation and audit possible on the
//! same data structure.

const std = @import("std");
const event_mod = @import("event.zig");
const log_mod = @import("log.zig");
const timeutil = @import("../core/time.zig");

pub const Envelope = event_mod.Envelope;
pub const EventId = event_mod.EventId;

pub const Node = struct {
    envelope: Envelope,
    parent: ?usize,
    children: []usize,
    depth: usize,
};

pub const Summary = struct {
    events: usize = 0,
    commands: usize = 0,
    failed_commands: usize = 0,
    tool_calls: usize = 0,
    denied_tool_calls: usize = 0,
    files_changed: usize = 0,
    approvals_requested: usize = 0,
    approvals_granted: usize = 0,
    diagnostics: usize = 0,
    span: timeutil.Duration = .{ .ns = 0 },

    /// One sentence a person can read in a status line.
    pub fn writeSentence(self: Summary, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} events: {d} command", .{ self.events, self.commands });
        if (self.commands != 1) try w.writeAll("s");
        if (self.failed_commands > 0) try w.print(" ({d} failed)", .{self.failed_commands});
        try w.print(", {d} file change", .{self.files_changed});
        if (self.files_changed != 1) try w.writeAll("s");
        if (self.approvals_requested > 0) {
            try w.print(", {d} of {d} approvals granted", .{ self.approvals_granted, self.approvals_requested });
        }
        if (self.denied_tool_calls > 0) {
            try w.print(", {d} tool call", .{self.denied_tool_calls});
            if (self.denied_tool_calls != 1) try w.writeAll("s");
            try w.writeAll(" denied by policy");
        }
    }
};

pub const Graph = struct {
    arena: std.mem.Allocator,
    nodes: []Node,
    /// Where each event identifier sits. Kept so that looking one up is a hash
    /// rather than a walk: a report that resolves a hundred identifiers over a
    /// hundred thousand events should not cost ten million comparisons.
    index_of: std.AutoArrayHashMapUnmanaged([16]u8, usize) = .empty,

    pub fn build(arena: std.mem.Allocator, log: log_mod.Log) !Graph {
        const entries = log.entries.items;
        var nodes = try arena.alloc(Node, entries.len);
        var index_of: std.AutoArrayHashMapUnmanaged([16]u8, usize) = .empty;
        for (entries, 0..) |entry, i| {
            try index_of.put(arena, entry.id.raw.bytes, i);
            nodes[i] = .{ .envelope = entry, .parent = null, .children = &.{}, .depth = 0 };
        }

        var child_lists = try arena.alloc(std.ArrayList(usize), entries.len);
        for (child_lists) |*list| list.* = .empty;

        for (entries, 0..) |entry, i| {
            const cause = entry.causedBy orelse continue;
            const parent_index = index_of.get(cause.raw.bytes) orelse continue;
            nodes[i].parent = parent_index;
            try child_lists[parent_index].append(arena, i);
        }
        for (child_lists, 0..) |list, i| nodes[i].children = list.items;

        // Depth, in one pass.
        //
        // A cause is appended before its effect, so a parent always sits at a
        // lower index than its child and its depth is already final by the time
        // the child is reached. Walking up from each node instead would cost
        // the depth of the tree for every node, which on one long agent run —
        // the exact case this exists for — is the square of its length.
        for (nodes, 0..) |*node, i| {
            const parent = node.parent orelse {
                node.depth = 0;
                continue;
            };
            node.depth = if (parent < i) nodes[parent].depth + 1 else 0;
        }

        return .{ .arena = arena, .nodes = nodes, .index_of = index_of };
    }

    /// True when every cause sits before its effect.
    ///
    /// This is the property the whole file rests on: it makes log order a
    /// topological order, so nothing here has to sort, and it makes the depth
    /// pass above correct. It holds because an event cannot be caused by one
    /// that has not happened. It is checked rather than assumed, because a
    /// merged or repaired log is exactly where it would stop holding.
    pub fn causesPrecedeEffects(self: Graph) bool {
        for (self.nodes, 0..) |node, i| {
            const parent = node.parent orelse continue;
            if (parent >= i) return false;
        }
        return true;
    }

    pub fn roots(self: Graph) !std.ArrayList(usize) {
        var out: std.ArrayList(usize) = .empty;
        for (self.nodes, 0..) |node, i| {
            if (node.parent == null) try out.append(self.arena, i);
        }
        return out;
    }

    pub fn indexOf(self: Graph, id: EventId) ?usize {
        return self.index_of.get(id.raw.bytes);
    }

    /// The chain of causes above one event, from the root down to it.
    ///
    /// This is the answer to "why did this happen": each step is the event that
    /// caused the next. It reads forwards, because that is the order a person
    /// asking the question wants to read it in.
    pub fn ancestry(self: Graph, index: usize) !std.ArrayList(usize) {
        var upwards: std.ArrayList(usize) = .empty;
        var current: ?usize = index;
        var guard: usize = 0;
        while (current) |i| : (guard += 1) {
            if (guard > self.nodes.len) break;
            try upwards.append(self.arena, i);
            current = self.nodes[i].parent;
        }
        std.mem.reverse(usize, upwards.items);
        return upwards;
    }

    /// True when `cause` is somewhere above `effect`.
    ///
    /// Costs the depth of the tree, not a search of it, because there is only
    /// ever one way up.
    pub fn causedBy(self: Graph, effect: usize, cause: usize) bool {
        var current = self.nodes[effect].parent;
        var guard: usize = 0;
        while (current) |i| : (guard += 1) {
            if (guard > self.nodes.len) return false;
            if (i == cause) return true;
            current = self.nodes[i].parent;
        }
        return false;
    }

    /// Every event caused by this one, directly or indirectly.
    pub fn descendants(self: Graph, index: usize) !std.ArrayList(usize) {
        var out: std.ArrayList(usize) = .empty;
        var stack: std.ArrayList(usize) = .empty;
        try stack.append(self.arena, index);
        while (stack.pop()) |current| {
            for (self.nodes[current].children) |child| {
                try out.append(self.arena, child);
                try stack.append(self.arena, child);
            }
        }
        std.mem.sort(usize, out.items, {}, std.sort.asc(usize));
        return out;
    }

    /// Everything that shares one correlation identifier: one unit of work.
    pub fn run(self: Graph, correlation: EventId) !std.ArrayList(usize) {
        var out: std.ArrayList(usize) = .empty;
        for (self.nodes, 0..) |node, i| {
            if (node.envelope.id.eql(correlation)) {
                try out.append(self.arena, i);
                continue;
            }
            const c = node.envelope.correlation orelse continue;
            if (c.eql(correlation)) try out.append(self.arena, i);
        }
        return out;
    }

    pub fn summarise(self: Graph, indices: []const usize) Summary {
        var summary: Summary = .{};
        var earliest: ?timeutil.Timestamp = null;
        var latest: ?timeutil.Timestamp = null;
        for (indices) |i| {
            const entry = self.nodes[i].envelope;
            summary.events += 1;
            if (earliest == null or entry.at.ns < earliest.?.ns) earliest = entry.at;
            if (latest == null or entry.at.ns > latest.?.ns) latest = entry.at;
            switch (entry.payload) {
                .command_submitted => summary.commands += 1,
                .command_finished => |e| {
                    if (e.exitStatus != 0) summary.failed_commands += 1;
                },
                .tool_requested => summary.tool_calls += 1,
                .tool_finished => |e| {
                    if (e.outcome == .denied) summary.denied_tool_calls += 1;
                },
                .file_changed => summary.files_changed += 1,
                .approval_requested => summary.approvals_requested += 1,
                .approval_resolved => |e| {
                    if (e.outcome == .allow_once or e.outcome == .allow_always_here) summary.approvals_granted += 1;
                },
                .diagnostic => summary.diagnostics += 1,
                else => {},
            }
        }
        if (earliest != null and latest != null) {
            summary.span = latest.?.since(earliest.?);
        }
        return summary;
    }

    /// Indented text rendering, for the command line and for reports.
    pub fn writeTree(self: Graph, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.nodes) |node| {
            var indent = node.depth;
            while (indent > 0) : (indent -= 1) try w.writeAll("  ");
            try w.print("{s}", .{node.envelope.payload.kindName()});
            switch (node.envelope.payload) {
                .command_submitted => |e| try w.print("  {s}", .{e.commandText}),
                .command_finished => |e| try w.print("  exit {d}", .{e.exitStatus}),
                .tool_requested => |e| try w.print("  {s} ({s})", .{ e.tool, e.capability }),
                .tool_finished => |e| try w.print("  {s}", .{@tagName(e.outcome)}),
                .file_changed => |e| try w.print("  {s} {s}", .{ @tagName(e.changeKind), e.path }),
                .approval_resolved => |e| try w.print("  {s}", .{@tagName(e.outcome)}),
                else => {},
            }
            try w.writeAll("\n");
        }
    }
};

const testing = std.testing;

test "a single agent run forms one graph" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idmod = @import("../core/id.zig");
    var gen: idmod.Generator = .init(51, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 52);

    const person: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "sean" };
    const robot: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .agent, .label = "review agent" };
    const session = gen.next(idmod.SessionId);
    const agent = gen.next(idmod.AgentId);
    var at = try timeutil.Timestamp.parseIso("2026-09-04T20:00:00Z");

    const request = try log.append(.{ .user_message = .{ .session = session, .text = "fix the parser and run the tests" } }, .{ .at = at, .actor = person });
    at = at.addNanos(timeutil.ns_per_s);
    const started = try log.append(
        .{ .agent_started = .{ .agent = agent, .session = session, .request = "fix the parser", .provider = "local", .model = "coder", .policy = "repo-write-no-network" } },
        .{ .at = at, .actor = robot, .causedBy = request.id, .correlation = request.id },
    );

    // Two commands and a file change, all caused by the agent starting.
    inline for ([_][]const u8{ "zig build", "zig build test" }) |command| {
        at = at.addNanos(timeutil.ns_per_s);
        const block = gen.next(idmod.BlockId);
        const submitted = try log.append(
            .{ .command_submitted = .{ .block = block, .session = session, .commandText = command, .workingDirectory = "/home/user/zag" } },
            .{ .at = at, .actor = robot, .causedBy = started.id, .correlation = request.id },
        );
        at = at.addNanos(timeutil.ns_per_s);
        _ = try log.append(
            .{ .command_finished = .{ .block = block, .session = session, .exitStatus = 0, .duration = timeutil.Duration.fromMillis(800) } },
            .{ .at = at, .actor = robot, .causedBy = submitted.id, .correlation = request.id },
        );
    }
    at = at.addNanos(timeutil.ns_per_s);
    _ = try log.append(
        .{ .file_changed = .{ .session = session, .path = "src/parser.zig", .changeKind = .modified, .agent = agent } },
        .{ .at = at, .actor = robot, .causedBy = started.id, .correlation = request.id },
    );

    const graph = try Graph.build(arena, log);
    try testing.expectEqual(@as(usize, 7), graph.nodes.len);

    const root_indices = try graph.roots();
    try testing.expectEqual(@as(usize, 1), root_indices.items.len);

    const started_index = graph.indexOf(started.id).?;
    const under_agent = try graph.descendants(started_index);
    try testing.expectEqual(@as(usize, 5), under_agent.items.len);

    const whole_run = try graph.run(request.id);
    const summary = graph.summarise(whole_run.items);
    try testing.expectEqual(@as(usize, 7), summary.events);
    try testing.expectEqual(@as(usize, 2), summary.commands);
    try testing.expectEqual(@as(usize, 1), summary.files_changed);
    try testing.expectEqual(@as(usize, 0), summary.failed_commands);
    try testing.expectEqual(@as(i64, 6), summary.span.seconds());

    var aw: std.Io.Writer.Allocating = .init(arena);
    try summary.writeSentence(&aw.writer);
    try testing.expectEqualStrings("7 events: 2 commands, 1 file change", aw.written());
}

test "the tree shows what caused what" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idmod = @import("../core/id.zig");
    var gen: idmod.Generator = .init(53, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 54);
    const actor: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .agent };
    const session = gen.next(idmod.SessionId);
    const at = try timeutil.Timestamp.parseIso("2026-09-04T20:00:00Z");

    const call = gen.next(idmod.ToolCallId);
    const agent = gen.next(idmod.AgentId);
    const requested = try log.append(.{ .tool_requested = .{
        .call = call,
        .agent = agent,
        .session = session,
        .tool = "execute",
        .capability = "process.execute",
        .argumentsJson = "{}",
        .resource = "rm -rf build/",
    } }, .{ .at = at, .actor = actor });
    _ = try log.append(.{ .tool_finished = .{
        .call = call,
        .agent = agent,
        .session = session,
        .outcome = .denied,
        .duration = timeutil.Duration.fromMillis(2),
        .resultHash = @import("../core/hash.zig").Hash.of("denied"),
        .summary = "Policy P23 does not allow deleting outside the build folder.",
    } }, .{ .at = at, .actor = actor, .causedBy = requested.id });

    const graph = try Graph.build(arena, log);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try graph.writeTree(&aw.writer);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "tool_requested  execute (process.execute)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  tool_finished  denied") != null);

    const all: []const usize = &.{ 0, 1 };
    try testing.expectEqual(@as(usize, 1), graph.summarise(all).denied_tool_calls);
}
