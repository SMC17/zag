//! The workspace as a running service, with no user interface attached.
//!
//! The daemon, the command-line tool and any future desktop client are clients
//! of this type. It owns the durable parts of a workspace:
//!
//!   * the event log on disk, which is verified before anything is appended;
//!   * the block index and the session projection folded from that log;
//!   * the knowledge base under `.workspace/`;
//!   * the policy engine every automated action passes through.
//!
//! Two properties matter more than features here. First, opening a workspace
//! never repairs a damaged log silently: a broken chain is reported, and the
//! service refuses to append after the break. Second, everything the service
//! does is an event, so a client that reconnects catches up by reading the log
//! rather than by asking the service what it thinks the state is.

const std = @import("std");
const event_mod = @import("../events/event.zig");
const log_mod = @import("../events/log.zig");
const block_mod = @import("block.zig");
const model_mod = @import("model.zig");
const history_mod = @import("history.zig");
const workflow_mod = @import("workflow.zig");
const base_mod = @import("../knowledge/base.zig");
const vocabulary_mod = @import("../knowledge/vocabulary.zig");
const policy_mod = @import("../ai/policy.zig");
const capability_mod = @import("../ai/capability.zig");
const session_mod = @import("../terminal/session.zig");
const idmod = @import("../core/id.zig");
const timeutil = @import("../core/time.zig");
const hashing = @import("../core/hash.zig");

pub const Timestamp = timeutil.Timestamp;
pub const Actor = event_mod.Actor;

pub const log_file_name = "events.jsonl";
pub const workspace_directory = ".workspace";

pub const OpenError = error{
    /// The log on disk does not hash to what it says it does. The service will
    /// not append to a log it cannot trust.
    LogBroken,
} || std.mem.Allocator.Error;

/// What opening a workspace found. Reported rather than printed, so the
/// daemon, the tool and the tests all say the same thing about the same state.
pub const OpenReport = struct {
    root: []const u8,
    eventCount: usize,
    blockCount: usize,
    sessionCount: usize,
    knowledgeCount: usize,
    /// Set when the log's hash chain does not hold. Nothing is appended while
    /// this is set.
    chainBreak: ?log_mod.Break = null,
    /// Problems found in the knowledge base, in the order they were found.
    knowledgeFindings: []const base_mod.Finding = &.{},
    /// True when the log file did not exist and a new one was started.
    createdLog: bool = false,

    pub fn isHealthy(self: OpenReport) bool {
        return self.chainBreak == null and self.knowledgeFindings.len == 0;
    }

    /// The state of the workspace, in sentences. Written for the person who
    /// starts the daemon and reads one screen of output.
    pub fn writeSummary(self: OpenReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("Workspace {s}\n", .{self.root});
        if (self.createdLog) {
            try w.writeAll("  The event log was empty, so a new one was started.\n");
        } else {
            try w.print("  {d} events replayed into {d} blocks across {d} sessions.\n", .{
                self.eventCount,
                self.blockCount,
                self.sessionCount,
            });
        }
        if (self.knowledgeCount == 1) {
            try w.print("  1 knowledge entry under {s}/.\n", .{workspace_directory});
        } else {
            try w.print("  {d} knowledge entries under {s}/.\n", .{ self.knowledgeCount, workspace_directory });
        }
        if (self.chainBreak) |b| {
            try w.print("  The log is broken at event {d}: {s}. Nothing new will be written until this is resolved.\n", .{
                b.sequence,
                reasonText(b.reason),
            });
        }
        for (self.knowledgeFindings) |finding| {
            try w.print("  {s}: {s}\n", .{ finding.path, finding.message });
        }
        if (self.isHealthy() and !self.createdLog) try w.writeAll("  The log verified end to end.\n");
    }
};

/// The concepts the knowledge base is checked against: the product's own
/// vocabulary, so an entry cannot claim to be about something undefined.
fn knowledgeConcepts(arena: std.mem.Allocator) ![]const []const u8 {
    const system = try vocabulary_mod.build(arena);
    var out: std.ArrayList([]const u8) = .empty;
    for (system.concepts.keys()) |id| try out.append(arena, id);
    return out.items;
}

fn reasonText(reason: log_mod.Break.Reason) []const u8 {
    return switch (reason) {
        .content_hash_mismatch => "the event's content does not match its hash",
        .chain_hash_mismatch => "the chain hash does not follow from the event before it",
        .sequence_out_of_order => "the events are out of order",
    };
}

/// What `Service.open` hands back: the service itself and what opening found.
pub const Opened = struct {
    service: Service,
    report: OpenReport,
};

pub const Options = struct {
    /// The workspace root. The log lives at `<root>/.workspace/events.jsonl`.
    root: []const u8,
    /// Who the service acts as when it writes an event of its own.
    actor: Actor,
    /// Injected, so a replay produces the same log twice.
    now: Timestamp,
    /// Seed for the identifiers the service mints.
    seed: u64 = 1,
    /// When false, the service holds the log in memory only. Tests use this.
    persist: bool = true,
};

pub const Service = struct {
    arena: std.mem.Allocator,
    root: []const u8,
    actor: Actor,
    clock: Timestamp,
    log: log_mod.Log,
    knowledge: base_mod.Base,
    policy: policy_mod.Engine,
    ids: idmod.Generator,
    persist: bool,
    /// Set when the log on disk failed verification. While it is set, `append`
    /// refuses, so a damaged log is never extended.
    sealed: bool = false,
    /// How many entries and how many bytes are already on disk. A flush writes
    /// only what is past them, because rewriting the whole log after every
    /// command turns a long session into quadratic work and quadratic writes.
    flushedEntries: usize = 0,
    flushedBytes: u64 = 0,
    /// Set when the file on disk ends in an incomplete line. The next flush
    /// rewrites the file once, which is the only way to drop the torn tail.
    needsRewrite: bool = false,

    /// Open a workspace: read the log, verify it, fold it, and read the
    /// knowledge base. Never repairs anything.
    pub fn open(arena: std.mem.Allocator, io: std.Io, options: Options) !Opened {
        var log = log_mod.Log.init(arena, options.seed);
        var created = false;
        var chain_break: ?log_mod.Break = null;

        var flushed_bytes: u64 = 0;
        var torn = false;
        if (options.persist) {
            const path = try logPath(arena, options.root);
            if (readFileIfPresent(arena, io, path)) |contents| {
                const loaded = try log_mod.Log.loadJsonLines(arena, contents, options.seed);
                log = loaded.log;
                chain_break = try log.verify();
                torn = loaded.torn_bytes > 0;
                flushed_bytes = contents.len - loaded.torn_bytes;
            } else {
                created = true;
            }
        } else {
            created = true;
        }

        var knowledge = base_mod.Base.init(arena, options.root);
        var problems: std.ArrayList(base_mod.Finding) = .empty;
        if (options.persist) {
            try loadKnowledge(arena, io, options.root, &knowledge, &problems);
        }
        const known = try knowledgeConcepts(arena);
        var findings = try knowledge.review(options.now, known);
        try findings.appendSlice(arena, problems.items);

        const policy = try policy_mod.repositoryWriteNoNetwork(options.root, arena);
        const index = try block_mod.Index.build(arena, log);
        const workspace = try model_mod.Workspace.build(arena, log);

        const service: Service = .{
            .arena = arena,
            .root = options.root,
            .actor = options.actor,
            .clock = options.now,
            .log = log,
            .knowledge = knowledge,
            .policy = policy_mod.Engine.init(arena, policy, options.seed),
            .ids = idmod.Generator.init(options.seed, @divFloor(options.now.ns, timeutil.ns_per_ms)),
            .persist = options.persist,
            .sealed = chain_break != null,
            .flushedEntries = log.count(),
            .flushedBytes = flushed_bytes,
            .needsRewrite = torn,
        };
        const report: OpenReport = .{
            .root = options.root,
            .eventCount = log.count(),
            .blockCount = index.count(),
            .sessionCount = workspace.sessions.count(),
            .knowledgeCount = knowledge.entries.items.len,
            .chainBreak = chain_break,
            .knowledgeFindings = findings.items,
            .createdLog = created,
        };
        return .{ .service = service, .report = report };
    }

    fn logPath(arena: std.mem.Allocator, root: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ root, workspace_directory, log_file_name });
    }

    fn readFileIfPresent(arena: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
        var dir = std.Io.Dir.cwd();
        const contents = dir.readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch return null;
        if (contents.len == 0) return null;
        return contents;
    }

    /// Read every entry under `.workspace/`. A file that cannot be read or
    /// parsed becomes a finding rather than an exception: one malformed rule
    /// must not hide the rest of the knowledge base, and it must not disappear
    /// quietly either.
    fn loadKnowledge(
        arena: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        into: *base_mod.Base,
        problems: *std.ArrayList(base_mod.Finding),
    ) !void {
        for (std.enums.values(base_mod.Kind)) |kind| {
            const dir_path = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ root, workspace_directory, kind.directory() });
            var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
                const file_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name });
                const contents = dir.readFileAlloc(io, entry.name, arena, .limited(4 * 1024 * 1024)) catch {
                    try problems.append(arena, .{
                        .code = .unreadable,
                        .path = file_path,
                        .message = "This file could not be read.",
                    });
                    continue;
                };
                into.addSource(file_path, contents) catch |err| {
                    try problems.append(arena, .{
                        .code = .unreadable,
                        .path = file_path,
                        .message = try std.fmt.allocPrint(arena, "This file could not be read as knowledge: {s}.", .{@errorName(err)}),
                    });
                };
            }
        }
    }

    /// Append an event. Refuses once the log has been sealed by a failed
    /// verification, because appending to a broken chain destroys the evidence
    /// of where it broke.
    pub fn append(self: *Service, payload: event_mod.WorkspaceEvent) !event_mod.Envelope {
        if (self.sealed) return error.LogBroken;
        const envelope = try self.log.append(payload, .{ .at = self.clock, .actor = self.actor });
        return envelope;
    }

    pub fn tick(self: *Service, delta: timeutil.Duration) void {
        self.clock = self.clock.addNanos(delta.ns);
    }

    /// Write the log to disk. Called after a batch of work rather than after
    /// every event, and a no-op for a workspace held in memory.
    /// Write what is not yet on disk.
    ///
    /// The log is one JSON object per line and it only ever grows, so a flush
    /// appends the new lines at the byte offset the last flush ended at. The
    /// whole file is rewritten only once, and only when the file on disk ended
    /// in a torn line that has to be dropped.
    pub fn flush(self: *Service, io: std.Io) !void {
        if (!self.persist) return;
        const pending = self.log.entries.items[self.flushedEntries..];
        if (pending.len == 0 and !self.needsRewrite) return;

        const dir_path = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ self.root, workspace_directory });
        var cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, dir_path) catch {};
        const path = try logPath(self.arena, self.root);

        if (self.needsRewrite or self.flushedBytes == 0) {
            var out: std.Io.Writer.Allocating = .init(self.arena);
            defer out.deinit();
            try self.log.writeJsonLines(&out.writer);
            try cwd.writeFile(io, .{ .sub_path = path, .data = out.written() });
            self.flushedEntries = self.log.count();
            self.flushedBytes = out.written().len;
            self.needsRewrite = false;
            return;
        }

        var tail: std.Io.Writer.Allocating = .init(self.arena);
        defer tail.deinit();
        for (pending) |entry| {
            try std.json.Stringify.value(entry, .{}, &tail.writer);
            try tail.writer.writeByte('\n');
        }
        const bytes = tail.written();

        const file = try cwd.openFile(io, path, .{ .mode = .write_only });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        writer.pos = self.flushedBytes;
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();

        self.flushedEntries = self.log.count();
        self.flushedBytes += bytes.len;
    }

    /// The block list, folded from the log as it stands now.
    pub fn blocks(self: Service) !block_mod.Index {
        return block_mod.Index.build(self.arena, self.log);
    }

    pub fn workspaceModel(self: Service) !model_mod.Workspace {
        return model_mod.Workspace.build(self.arena, self.log);
    }

    /// Search what happened, using the structured history query language.
    pub fn search(self: Service, text: []const u8, options: history_mod.Options) !history_mod.Results {
        const parsed = try history_mod.parse(self.arena, text);
        const index = try self.blocks();
        return history_mod.run(self.arena, index, parsed.query, options);
    }

    /// What running a command produced: where to find it in the log, what the
    /// screen showed, and how it ended.
    pub const CommandRun = struct {
        session: idmod.SessionId,
        /// The final screen, as text.
        screen: []const u8,
        blocks: []const block_mod.Block,
        exitStatus: ?u8,
    };

    /// Run one command on a real pseudoterminal and record it in the log.
    ///
    /// The command runs under a shell that writes the semantic prompt marks, so
    /// the block boundary comes from the shell rather than from a guess. That
    /// difference is recorded on the block, because every figure computed from
    /// a guessed boundary is worth less than one computed from a mark.
    pub fn runCommand(
        self: *Service,
        command_text: []const u8,
        timeout: timeutil.Duration,
    ) !CommandRun {
        if (self.sealed) return error.LogBroken;
        const id = self.ids.next(idmod.SessionId);
        var session = try session_mod.Session.init(self.arena, &self.log, id, .{
            .working_directory = self.root,
            .shell = "/bin/sh",
            .actor = self.actor,
        }, self.clock);

        const script = try std.fmt.allocPrint(
            self.arena,
            "printf '\x1b]133;C;cmdline=%s\x07' \"$ZAG_COMMAND\"; {s}; status=$?; printf '\x1b]133;D;%s\x07' \"$status\"; exit $status",
            .{command_text},
        );
        try session.run(
            "/bin/sh",
            &.{ "/bin/sh", "-c", script },
            &.{
                try std.fmt.allocPrint(self.arena, "ZAG_COMMAND={s}", .{command_text}),
                "TERM=xterm-256color",
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            },
            self.root,
            timeout,
        );
        try session.close("the command finished");
        self.clock = session.clock;

        const index = try self.blocks();
        var mine: std.ArrayList(block_mod.Block) = .empty;
        var exit_status: ?u8 = null;
        for (index.blocks.items) |b| {
            if (!b.session.eql(id)) continue;
            try mine.append(self.arena, b);
            if (b.exitStatus) |code| exit_status = code;
        }
        return .{
            .session = id,
            .screen = try session.screen.text(self.arena),
            .blocks = mine.items,
            .exitStatus = exit_status,
        };
    }

    // --- Workflows ---------------------------------------------------------

    pub const NodeOutcome = struct {
        node: []const u8,
        decision: policy_mod.Decision,
        /// Set when the node was not attempted because something it needed
        /// failed or was denied.
        skippedBecause: ?[]const u8 = null,

        pub fn ran(self: NodeOutcome) bool {
            return self.skippedBecause == null and self.decision.isAllowed();
        }
    };

    pub const WorkflowRun = struct {
        workflow: []const u8,
        outcomes: []const NodeOutcome,
        /// Nodes that a person has to decide on before the run can go further.
        waitingOnPeople: []const []const u8,

        pub fn writeSummary(self: WorkflowRun, w: *std.Io.Writer) std.Io.Writer.Error!void {
            var ran: usize = 0;
            var denied: usize = 0;
            var skipped: usize = 0;
            for (self.outcomes) |outcome| {
                if (outcome.skippedBecause != null) {
                    skipped += 1;
                } else if (outcome.decision.isAllowed()) {
                    ran += 1;
                } else {
                    denied += 1;
                }
            }
            // Nothing has run at this point. The wording says so, because a
            // report that reads like a result would be a false one.
            try w.print("Workflow {s}: {d} steps may run, {d} would be denied, {d} would be skipped.\n", .{
                self.workflow,
                ran,
                denied,
                skipped,
            });
            for (self.waitingOnPeople) |node| {
                try w.print("  {s} needs a person to decide before it can run.\n", .{node});
            }
            for (self.outcomes) |outcome| {
                if (outcome.skippedBecause) |why| {
                    try w.print("  {s} would be skipped: {s}\n", .{ outcome.node, why });
                } else if (!outcome.decision.isAllowed()) {
                    try w.print("  {s} would be denied: {s}\n", .{ outcome.node, outcome.decision.reason });
                }
            }
        }
    };

    /// Decide a workflow against the policy without running anything: for each
    /// node, in dependency order, what would the policy engine say?
    ///
    /// This is a dry run on purpose. A headless service that could run
    /// arbitrary workflow steps unattended is the thing the capability model
    /// exists to prevent, so the service reports what needs a person and stops.
    pub fn planWorkflow(self: *Service, flow: workflow_mod.Workflow) !WorkflowRun {
        var outcomes: std.ArrayList(NodeOutcome) = .empty;
        var waiting: std.ArrayList([]const u8) = .empty;
        var blocked: std.StringArrayHashMapUnmanaged([]const u8) = .empty;

        const order = try flow.order(self.arena);
        for (order) |node_id| {
            const node = flow.node(node_id).?;
            if (blockedBecause(blocked, node)) |why| {
                try outcomes.append(self.arena, .{
                    .node = node_id,
                    .decision = self.deniedDecision(node_id),
                    .skippedBecause = why,
                });
                try blocked.put(self.arena, node_id, "a step it needs did not run");
                continue;
            }
            const request: capability_mod.Request = .{
                .capability = primaryCapability(node),
                .resource = resourceOf(node, self.root),
            };
            const decision = try self.policy.decide(request, .{
                .actor = self.actor.id,
                .now = self.clock,
            });
            if (node.needs_approval or decision.effect == .require_human) {
                try waiting.append(self.arena, node_id);
                try blocked.put(self.arena, node_id, "a person has not decided about it yet");
            } else if (!decision.isAllowed()) {
                try blocked.put(self.arena, node_id, "the policy denied it");
            }
            try outcomes.append(self.arena, .{ .node = node_id, .decision = decision });
        }
        return .{
            .workflow = flow.name,
            .outcomes = outcomes.items,
            .waitingOnPeople = waiting.items,
        };
    }

    /// A decision for a step that was never attempted. It carries the same
    /// shape as a real decision so that a report never has to special-case it.
    fn deniedDecision(self: *Service, node_id: []const u8) policy_mod.Decision {
        return .{
            .id = self.ids.next(idmod.DecisionId),
            .request = .{ .capability = .@"process.execute", .resource = .none },
            .effect = .deny,
            .rule_id = null,
            .policy_id = "workflow-plan",
            .reason = node_id,
            .actor = self.actor.id,
            .session = null,
            .agent = null,
            .decided_at = self.clock,
        };
    }

    fn blockedBecause(blocked: std.StringArrayHashMapUnmanaged([]const u8), node: workflow_mod.Node) ?[]const u8 {
        for (node.needs) |need| {
            if (blocked.get(need)) |_| return "a step it needs did not run";
        }
        return null;
    }

    /// The capability a step needs. The tool request already answers this, so
    /// the workflow planner and the agent runtime cannot disagree about which
    /// capability a step runs under.
    fn primaryCapability(node: workflow_mod.Node) capability_mod.Capability {
        return node.request.capability();
    }

    fn resourceOf(node: workflow_mod.Node, root: []const u8) capability_mod.Resource {
        return switch (node.request) {
            .execute => |e| .{ .command = if (e.argv.len > 0) e.argv[0] else "" },
            .read_file => |r| .{ .path = r.path },
            .write_file => |x| .{ .path = x.path },
            .delete => |d| .{ .path = d.path },
            .search => .{ .path = root },
            .git => |g| .{ .path = g.repository },
            .mcp => |m| .{ .service = m.server },
            .spawn_agent => |a| .{ .service = a.label },
            .infer => |i| .{ .service = i.provider },
        };
    }
};

const testing = std.testing;

fn testActor() Actor {
    var gen: idmod.Generator = .init(3, 1_788_000_000_000);
    return .{ .id = gen.next(idmod.ActorId), .kind = .system, .label = "zagd" };
}

test "a workspace opens in memory and reports what it found" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const opened = try Service.open(arena, threaded.io(), .{
        .root = "/home/user/zag",
        .actor = testActor(),
        .now = try Timestamp.parseIso("2026-09-05T09:00:00Z"),
        .persist = false,
    });
    try testing.expect(opened.report.createdLog);
    try testing.expectEqual(@as(usize, 0), opened.report.eventCount);
    try testing.expect(opened.report.isHealthy());

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try opened.report.writeSummary(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "The event log was empty") != null);
}

test "a workspace round-trips through a file on disk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const at = try Timestamp.parseIso("2026-09-05T09:00:00Z");
    const opened = try Service.open(arena, io, .{ .root = root, .actor = testActor(), .now = at });
    var service = opened.service;
    const session = service.ids.next(idmod.SessionId);
    _ = try service.append(.{ .session_opened = .{
        .session = session,
        .workingDirectory = root,
    } });
    _ = try service.append(.{ .user_message = .{
        .session = session,
        .text = "start the release check",
    } });
    try service.flush(io);

    // Reopening reads the same events back and verifies the chain.
    const reopened = try Service.open(arena, io, .{ .root = root, .actor = testActor(), .now = at });
    try testing.expect(!reopened.report.createdLog);
    try testing.expectEqual(@as(usize, 2), reopened.report.eventCount);
    try testing.expect(reopened.report.chainBreak == null);
    try testing.expectEqual(@as(usize, 1), reopened.report.sessionCount);
}

test "a flush appends rather than rewriting the whole log" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const at = try Timestamp.parseIso("2026-09-06T09:00:00Z");

    const opened = try Service.open(arena, io, .{ .root = root, .actor = testActor(), .now = at });
    var service = opened.service;
    const session = service.ids.next(idmod.SessionId);
    _ = try service.append(.{ .session_opened = .{ .session = session, .workingDirectory = root } });
    try service.flush(io);
    const after_first = service.flushedBytes;
    try testing.expect(after_first > 0);

    // A second flush writes only the new line, so the offset moves by exactly
    // the length of what was added.
    _ = try service.append(.{ .user_message = .{ .session = session, .text = "second" } });
    try service.flush(io);
    try testing.expect(service.flushedBytes > after_first);
    try testing.expectEqual(@as(usize, 2), service.flushedEntries);

    // Nothing to write means no work at all.
    const unchanged = service.flushedBytes;
    try service.flush(io);
    try testing.expectEqual(unchanged, service.flushedBytes);

    // The file still holds a complete, verifiable log.
    const reopened = try Service.open(arena, io, .{ .root = root, .actor = testActor(), .now = at });
    try testing.expectEqual(@as(usize, 2), reopened.report.eventCount);
    try testing.expect(reopened.report.chainBreak == null);
}

test "a torn line is dropped once, and the log stays verifiable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const at = try Timestamp.parseIso("2026-09-06T09:00:00Z");

    const opened = try Service.open(arena, io, .{ .root = root, .actor = testActor(), .now = at });
    var service = opened.service;
    const session = service.ids.next(idmod.SessionId);
    _ = try service.append(.{ .session_opened = .{ .session = session, .workingDirectory = root } });
    try service.flush(io);

    // A process that stopped while writing leaves an incomplete last line.
    const path = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ root, workspace_directory, log_file_name });
    var cwd = std.Io.Dir.cwd();
    const contents = try cwd.readFileAlloc(io, path, arena, .limited(1 << 20));
    const torn = try std.fmt.allocPrint(arena, "{s}{{\"id\":\"evt_01", .{contents});
    try cwd.writeFile(io, .{ .sub_path = path, .data = torn });

    const reopened = try Service.open(arena, io, .{ .root = root, .actor = testActor(), .now = at });
    var recovered = reopened.service;
    try testing.expectEqual(@as(usize, 1), reopened.report.eventCount);
    try testing.expect(recovered.needsRewrite);

    _ = try recovered.append(.{ .user_message = .{ .session = session, .text = "after the crash" } });
    try recovered.flush(io);
    try testing.expect(!recovered.needsRewrite);

    const third = try Service.open(arena, io, .{ .root = root, .actor = testActor(), .now = at });
    try testing.expectEqual(@as(usize, 2), third.report.eventCount);
    try testing.expect(third.report.chainBreak == null);
}

test "a damaged log is reported and never extended" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const at = try Timestamp.parseIso("2026-09-05T09:00:00Z");

    const opened = try Service.open(arena, io, .{ .root = root, .actor = testActor(), .now = at });
    var service = opened.service;
    const session = service.ids.next(idmod.SessionId);
    _ = try service.append(.{ .session_opened = .{ .session = session, .workingDirectory = root } });
    _ = try service.append(.{ .user_message = .{ .session = session, .text = "hello" } });
    try service.flush(io);

    // Change one recorded message. The content hash no longer matches.
    const path = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ root, workspace_directory, log_file_name });
    var cwd = std.Io.Dir.cwd();
    const contents = try cwd.readFileAlloc(io, path, arena, .limited(1 << 20));
    const tampered = try std.mem.replaceOwned(u8, arena, contents, "hello", "hellp");
    try cwd.writeFile(io, .{ .sub_path = path, .data = tampered });

    const reopened = try Service.open(arena, io, .{ .root = root, .actor = testActor(), .now = at });
    try testing.expect(reopened.report.chainBreak != null);
    try testing.expect(!reopened.report.isHealthy());

    var sealed = reopened.service;
    try testing.expectError(error.LogBroken, sealed.append(.{ .user_message = .{
        .session = session,
        .text = "anything",
    } }));

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try reopened.report.writeSummary(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "Nothing new will be written") != null);
}

test "planning a workflow says what a person still has to decide" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const opened = try Service.open(arena, threaded.io(), .{
        .root = "/home/user/zag",
        .actor = testActor(),
        .now = try Timestamp.parseIso("2026-09-05T09:00:00Z"),
        .persist = false,
    });
    var service = opened.service;

    const nodes = try arena.dupe(workflow_mod.Node, &.{
        .{
            .id = "test",
            .description = "Run the tests.",
            .request = .{ .execute = .{
                .argv = &.{ "zig", "build", "test" },
                .workingDirectory = "/home/user/zag",
            } },
        },
        .{
            .id = "publish",
            .description = "Send the commits to the remote.",
            .needs = &.{"test"},
            .needs_approval = true,
            .request = .{ .git = .{ .operation = .push, .repository = "/home/user/zag", .argument = "origin" } },
        },
        .{
            .id = "announce",
            .description = "Tell the team it is out.",
            .needs = &.{"publish"},
            .request = .{ .mcp = .{ .server = "chat", .tool = "post", .argumentsJson = "{}" } },
        },
    });
    const flow: workflow_mod.Workflow = .{
        .id = "release",
        .name = "release",
        .outcome = "A tested change reaches the remote once a person agrees.",
        .nodes = nodes,
    };
    const run = try service.planWorkflow(flow);
    try testing.expectEqual(@as(usize, 3), run.outcomes.len);

    // Pushing is never a machine's decision, so it waits for a person, and
    // everything that depends on it waits too rather than running early.
    try testing.expectEqual(@as(usize, 1), run.waitingOnPeople.len);
    try testing.expectEqualStrings("publish", run.waitingOnPeople[0]);
    try testing.expect(run.outcomes[2].skippedBecause != null);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try run.writeSummary(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "needs a person to decide") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "announce would be skipped") != null);
}

test "history search runs against a service's own log" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const at = try Timestamp.parseIso("2026-09-05T09:00:00Z");
    const opened = try Service.open(arena, threaded.io(), .{
        .root = "/home/user/zag",
        .actor = testActor(),
        .now = at,
        .persist = false,
    });
    var service = opened.service;
    const session = service.ids.next(idmod.SessionId);
    const block = service.ids.next(idmod.BlockId);
    _ = try service.append(.{ .session_opened = .{ .session = session, .workingDirectory = "/home/user/zag" } });
    _ = try service.append(.{ .command_submitted = .{
        .block = block,
        .session = session,
        .commandText = "zig build test",
        .workingDirectory = "/home/user/zag",
        .boundaryFromShell = true,
    } });
    service.tick(.fromSeconds(3));
    _ = try service.append(.{ .command_finished = .{
        .block = block,
        .session = session,
        .exitStatus = 0,
        .duration = .fromSeconds(3),
    } });

    const results = try service.search("zig status:succeeded", .{ .now = service.clock });
    try testing.expectEqual(@as(usize, 1), results.matchCount);
    try testing.expectEqualStrings("zig build test", results.hits[0].block.commandText.?);
}
