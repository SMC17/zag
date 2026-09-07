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
const content_store_mod = @import("../events/content_store.zig");
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
    /// Bytes after the last complete JSON Lines record. They are preserved as
    /// crash evidence and must be resolved before appending resumes.
    tornBytes: usize = 0,
    /// A complete line that was not a valid event record.
    malformed: ?log_mod.DecodeIssue = null,
    /// Problems found in the knowledge base, in the order they were found.
    knowledgeFindings: []const base_mod.Finding = &.{},
    /// True when no persistent log existed when the workspace was opened.
    createdLog: bool = false,

    pub fn logIsHealthy(self: OpenReport) bool {
        return self.chainBreak == null and self.tornBytes == 0 and self.malformed == null;
    }

    pub fn isHealthy(self: OpenReport) bool {
        return self.logIsHealthy() and self.knowledgeFindings.len == 0;
    }

    /// The state of the workspace, in sentences. Written for the person who
    /// starts the daemon and reads one screen of output.
    pub fn writeSummary(self: OpenReport, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("Workspace {s}\n", .{self.root});
        if (self.createdLog) {
            try w.writeAll("  No event log exists yet, so this view starts empty.\n");
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
        if (self.tornBytes > 0) {
            try w.print("  The log ends with {d} incomplete bytes. Nothing new will be written until this is resolved.\n", .{self.tornBytes});
        }
        if (self.malformed) |issue| {
            try w.print("  The complete record on line {d} is malformed at byte {d}. Nothing new will be written until this is resolved.\n", .{
                issue.line,
                issue.byte_offset,
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

/// Encode a command for the `cmdline` field of an OSC shell mark. A command
/// may itself contain a semicolon, percent sign or terminal control byte; none
/// of those may be allowed to change the boundary record around it.
fn encodeOscField(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    const hex = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    for (source) |byte| {
        if (byte >= 0x20 and byte <= 0x7e and byte != '%' and byte != ';') {
            try out.append(arena, byte);
        } else {
            try out.append(arena, '%');
            try out.append(arena, hex[byte >> 4]);
            try out.append(arena, hex[byte & 0x0f]);
        }
    }
    return out.toOwnedSlice(arena);
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
    ///
    /// Left unset in a deployment, so the seed is drawn from the operating
    /// system and two workspaces opened at the same instant do not mint the
    /// same first identifier. A test sets it, because a replay that produces a
    /// different log every time proves nothing.
    seed: ?u64 = null,
    /// When false, the service holds the log in memory only. Tests use this.
    persist: bool = true,
};

pub const Service = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    actor: Actor,
    clock: Timestamp,
    log: log_mod.Log,
    content: content_store_mod.Store,
    knowledge: base_mod.Base,
    policy: policy_mod.Engine,
    ids: idmod.Generator,
    persist: bool,
    /// Set when the log on disk failed verification. While it is set, `append`
    /// refuses, so a damaged log is never extended.
    sealed: bool = false,
    /// Events appended since the last flush, so a flush writes the whole file
    /// once rather than after every event.
    unflushed: usize = 0,
    /// Exact bytes seen when this service opened or last flushed. A flush
    /// checks both before appending so two writers cannot silently overwrite
    /// one another.
    persisted_bytes: u64 = 0,
    persisted_fingerprint: hashing.Hash = hashing.Hash.zero,

    /// Open a workspace: read the log, verify it, fold it, and read the
    /// knowledge base. Never repairs anything.
    pub fn open(arena: std.mem.Allocator, io: std.Io, options: Options) !Opened {
        const seed: u64 = if (options.seed) |chosen| chosen else blk: {
            var bytes: [8]u8 = undefined;
            try io.randomSecure(&bytes);
            break :blk std.mem.readInt(u64, &bytes, .little);
        };
        var log = log_mod.Log.init(arena, seed);
        var created = false;
        var chain_break: ?log_mod.Break = null;
        var torn_bytes: usize = 0;
        var malformed: ?log_mod.DecodeIssue = null;
        var persisted_bytes: u64 = 0;
        var persisted_fingerprint = hashing.Hash.of("");

        if (options.persist) {
            const path = try logPath(arena, options.root);
            if (try readFileIfPresent(arena, io, path)) |contents| {
                persisted_bytes = contents.len;
                persisted_fingerprint = hashing.Hash.of(contents);
                if (contents.len > 0) {
                    const loaded = try log_mod.Log.loadJsonLines(arena, contents, seed);
                    log = loaded.log;
                    torn_bytes = loaded.torn_bytes;
                    malformed = loaded.malformed;
                    chain_break = try log.verify();
                    if (chain_break) |broken| {
                        // Preserve the complete source on disk, but never let
                        // projections treat the broken event or its suffix as
                        // accepted workspace state.
                        log.retainPrefix(broken.index);
                    }
                }
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
            .io = io,
            .root = options.root,
            .actor = options.actor,
            .clock = options.now,
            .log = log,
            .content = content_store_mod.Store.init(arena, options.root),
            .knowledge = knowledge,
            .policy = policy_mod.Engine.init(arena, policy, seed),
            .ids = idmod.Generator.init(seed, @divFloor(options.now.ns, timeutil.ns_per_ms)),
            .persist = options.persist,
            .sealed = chain_break != null or torn_bytes > 0 or malformed != null,
            .persisted_bytes = persisted_bytes,
            .persisted_fingerprint = persisted_fingerprint,
        };
        const report: OpenReport = .{
            .root = options.root,
            .eventCount = log.count(),
            .blockCount = index.count(),
            .sessionCount = workspace.sessions.count(),
            .knowledgeCount = knowledge.entries.items.len,
            .chainBreak = chain_break,
            .tornBytes = torn_bytes,
            .malformed = malformed,
            .knowledgeFindings = findings.items,
            .createdLog = created,
        };
        return .{ .service = service, .report = report };
    }

    fn logPath(arena: std.mem.Allocator, root: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ root, workspace_directory, log_file_name });
    }

    fn readFileIfPresent(arena: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
        var file = (std.Io.Dir.cwd().openFile(io, path, .{
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        }) orelse return null;
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.size > log_mod.max_file_bytes) return error.StreamTooLong;
        const contents = try arena.alloc(u8, @intCast(stat.size));
        const read_count = try file.readPositionalAll(io, contents, 0);
        if (read_count != contents.len or (try file.stat(io)).size != stat.size) return error.LogChanged;
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
            var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |e| return e,
            };
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
        self.unflushed += 1;
        return envelope;
    }

    pub fn tick(self: *Service, delta: timeutil.Duration) void {
        self.clock = self.clock.addNanos(delta.ns);
    }

    /// Append new records after checking the exact on-disk prefix under an
    /// exclusive advisory lock. Content objects are made durable first, so a
    /// committed event never points to an object that was only in memory.
    pub fn flush(self: *Service, io: std.Io) !void {
        if (!self.persist) return;
        try self.content.flush(io);
        if (self.unflushed == 0) return;
        const dir_path = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ self.root, workspace_directory });
        var cwd = std.Io.Dir.cwd();
        _ = try cwd.createDirPathStatus(io, dir_path, content_store_mod.private_directory_permissions);
        const path = try logPath(self.arena, self.root);

        var file = openLogForAppend(io, cwd, path) catch |err| {
            self.sealed = true;
            return err;
        };
        defer file.close(io);

        const stat = try file.stat(io);
        if (stat.size != self.persisted_bytes or stat.size > log_mod.max_file_bytes) {
            self.sealed = true;
            return error.LogChanged;
        }
        const prefix = try self.arena.alloc(u8, @intCast(stat.size));
        const read = try file.readPositionalAll(io, prefix, 0);
        if (read != prefix.len or !hashing.Hash.of(prefix).eql(self.persisted_fingerprint)) {
            self.sealed = true;
            return error.LogChanged;
        }

        var out: std.Io.Writer.Allocating = .init(self.arena);
        const first = self.log.entries.items.len - self.unflushed;
        for (self.log.entries.items[first..]) |entry| {
            try std.json.Stringify.value(entry, .{}, &out.writer);
            try out.writer.writeByte('\n');
        }
        const pending = out.written();
        _ = checkedAppendedSize(self.persisted_bytes, pending.len) catch |err| {
            self.sealed = true;
            return err;
        };
        file.writePositionalAll(io, pending, self.persisted_bytes) catch |err| {
            self.sealed = true;
            return err;
        };
        file.sync(io) catch |err| {
            self.sealed = true;
            return err;
        };

        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(prefix);
        hasher.update(pending);
        hasher.final(&self.persisted_fingerprint.bytes);
        self.persisted_bytes += pending.len;
        self.unflushed = 0;
    }

    /// Read bytes referenced by a process-output event and verify their hash.
    pub fn readContent(self: Service, io: std.Io, hash: hashing.Hash, limit: usize) ![]const u8 {
        return self.content.read(io, hash, limit);
    }

    /// Verify every stored command-output object and report objects that no
    /// event in the verified log prefix references. The audit is read-only.
    pub fn auditContent(self: Service, io: std.Io) !content_store_mod.AuditReport {
        var references: std.ArrayList(content_store_mod.Reference) = .empty;
        for (self.log.entries.items) |entry| switch (entry.payload) {
            .process_output => |output| try references.append(self.arena, .{
                .hash = output.contentHash,
                .byte_count = output.byteCount,
            }),
            else => {},
        };
        return self.content.audit(io, references.items);
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
        if (std.mem.indexOfScalar(u8, command_text, 0) != null) return error.InvalidCommandText;
        const before = self.log.count();
        defer self.unflushed += self.log.count() - before;
        const id = self.ids.next(idmod.SessionId);
        var token_bytes: [16]u8 = undefined;
        try self.io.randomSecure(&token_bytes);
        const token_hex = "0123456789abcdef";
        var token_buffer: [32]u8 = undefined;
        for (token_bytes, 0..) |byte, index| {
            token_buffer[index * 2] = token_hex[byte >> 4];
            token_buffer[index * 2 + 1] = token_hex[byte & 0x0f];
        }
        const marker_token = try self.arena.dupe(u8, &token_buffer);
        var session = try session_mod.Session.init(self.arena, &self.log, id, .{
            .working_directory = self.root,
            .shell = "/bin/sh",
            .actor = self.actor,
            .content_store = &self.content,
            .marker_token = marker_token,
        }, self.clock);

        const marker_command = try encodeOscField(self.arena, command_text);
        const script = "marker_token=$ZAG_MARKER_TOKEN; marker_command=$ZAG_MARKER_COMMAND; exec_command=$ZAG_EXEC_COMMAND; unset ZAG_MARKER_TOKEN ZAG_MARKER_COMMAND ZAG_EXEC_COMMAND; printf '\x1b]133;C;token=%s;cmdline=%s\x07' \"$marker_token\" \"$marker_command\"; /bin/sh -c \"$exec_command\"; status=$?; printf '\x1b]133;D;%s;token=%s\x07' \"$status\" \"$marker_token\"; unset marker_token marker_command exec_command; exit $status";
        try session.run(
            "/bin/sh",
            &.{ "/bin/sh", "-c", script },
            &.{
                try std.fmt.allocPrint(self.arena, "ZAG_MARKER_TOKEN={s}", .{marker_token}),
                try std.fmt.allocPrint(self.arena, "ZAG_MARKER_COMMAND={s}", .{marker_command}),
                try std.fmt.allocPrint(self.arena, "ZAG_EXEC_COMMAND={s}", .{command_text}),
                "TERM=xterm-256color",
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            },
            self.root,
            timeout,
        );
        try session.close(if (session.didTimeOut()) "the command reached its deadline" else "the command finished");
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

fn checkedAppendedSize(current: u64, pending: usize) error{LogTooLarge}!u64 {
    if (current > log_mod.max_file_bytes) return error.LogTooLarge;
    const room = log_mod.max_file_bytes - current;
    const pending_bytes = std.math.cast(u64, pending) orelse return error.LogTooLarge;
    if (pending_bytes > room) return error.LogTooLarge;
    return current + pending_bytes;
}

fn openLogForAppend(io: std.Io, dir: std.Io.Dir, path: []const u8) !std.Io.File {
    return dir.openFile(io, path, .{
        .mode = .read_write,
        .allow_directory = false,
        .lock = .exclusive,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => dir.createFile(io, path, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .lock = .exclusive,
            .permissions = content_store_mod.private_file_permissions,
        }) catch |create_err| switch (create_err) {
            // A cooperating writer created the log between the open and the
            // exclusive create. Opening it now still checks the exact prefix.
            error.PathAlreadyExists => dir.openFile(io, path, .{
                .mode = .read_write,
                .allow_directory = false,
                .lock = .exclusive,
                .follow_symlinks = false,
            }),
            else => |e| return e,
        },
        else => |e| return e,
    };
}

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
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "No event log exists yet") != null);
}

test "an append cannot make the active event log exceed its size limit" {
    try testing.expectEqual(log_mod.max_file_bytes, try checkedAppendedSize(log_mod.max_file_bytes - 1, 1));
    try testing.expectError(error.LogTooLarge, checkedAppendedSize(log_mod.max_file_bytes, 1));
    try testing.expectError(error.LogTooLarge, checkedAppendedSize(log_mod.max_file_bytes + 1, 0));
}

test "command text is encoded without letting controls become shell marks" {
    const encoded = try encodeOscField(testing.allocator, "printf 100%; next\x07\x1b");
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("printf 100%25%3B next%07%1B", encoded);
}

test "an existing empty log is not reported as newly created" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dir_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, workspace_directory });
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try Service.logPath(arena, root), .data = "" });

    const opened = try Service.open(arena, io, .{
        .root = root,
        .actor = testActor(),
        .now = try Timestamp.parseIso("2026-09-05T09:00:00Z"),
    });
    try testing.expect(!opened.report.createdLog);
    try testing.expectEqual(@as(usize, 0), opened.report.eventCount);
    try testing.expect(opened.report.logIsHealthy());
}

test "an unreadable event-log path is not treated as a missing log" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.Io.Dir.cwd().createDirPath(io, try Service.logPath(arena, root));

    try testing.expectError(error.IsDir, Service.open(arena, io, .{
        .root = root,
        .actor = testActor(),
        .now = try Timestamp.parseIso("2026-09-05T09:00:00Z"),
    }));
}

test "opening a workspace never follows an event-log symbolic link" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const workspace = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, workspace_directory });
    try std.Io.Dir.cwd().createDirPath(io, workspace);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/outside", .{root}),
        .data = "not the workspace log",
    });
    try std.Io.Dir.cwd().symLink(io, "../outside", try Service.logPath(arena, root), .{});

    try testing.expectError(error.SymLinkLoop, Service.open(arena, io, .{
        .root = root,
        .actor = testActor(),
        .now = try Timestamp.parseIso("2026-09-05T09:00:00Z"),
    }));
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

test "a flush preserves the exact event-log prefix" {
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
    try service.flush(io);
    const path = try Service.logPath(arena, root);
    const first = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        try testing.expect((try file.stat(io)).permissions.toMode() & 0o077 == 0);
        const parent = std.fs.path.dirname(path).?;
        var dir = try std.Io.Dir.cwd().openDir(io, parent, .{});
        defer dir.close(io);
        try testing.expect((try dir.stat(io)).permissions.toMode() & 0o077 == 0);
    }

    _ = try service.append(.{ .user_message = .{ .session = session, .text = "second batch" } });
    try service.flush(io);
    const second = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    try testing.expect(second.len > first.len);
    try testing.expect(std.mem.startsWith(u8, second, first));
}

test "a stale writer cannot replace another writer's events" {
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
    const first_open = try Service.open(arena, io, .{ .root = root, .actor = testActor(), .now = at, .seed = 21 });
    const stale_open = try Service.open(arena, io, .{ .root = root, .actor = testActor(), .now = at, .seed = 22 });
    var first = first_open.service;
    var stale = stale_open.service;
    const first_session = first.ids.next(idmod.SessionId);
    const stale_session = stale.ids.next(idmod.SessionId);

    _ = try first.append(.{ .session_opened = .{ .session = first_session, .workingDirectory = root } });
    try first.flush(io);
    _ = try stale.append(.{ .session_opened = .{ .session = stale_session, .workingDirectory = root } });
    try testing.expectError(error.LogChanged, stale.flush(io));
    try testing.expect(stale.sealed);

    const reopened = try Service.open(arena, io, .{ .root = root, .actor = testActor(), .now = at });
    try testing.expectEqual(@as(usize, 1), reopened.report.eventCount);
    try testing.expect(reopened.report.isHealthy());
}

test "torn and malformed records seal a workspace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const at = try Timestamp.parseIso("2026-09-05T09:00:00Z");

    var torn_tmp = std.testing.tmpDir(.{});
    defer torn_tmp.cleanup();
    const torn_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{torn_tmp.sub_path});
    const torn_open = try Service.open(arena, io, .{ .root = torn_root, .actor = testActor(), .now = at });
    var torn_service = torn_open.service;
    const session = torn_service.ids.next(idmod.SessionId);
    _ = try torn_service.append(.{ .session_opened = .{ .session = session, .workingDirectory = torn_root } });
    try torn_service.flush(io);
    const torn_path = try Service.logPath(arena, torn_root);
    const complete = try std.Io.Dir.cwd().readFileAlloc(io, torn_path, arena, .limited(1 << 20));
    const torn = try std.fmt.allocPrint(arena, "{s}{{", .{complete});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = torn_path, .data = torn });

    const reopened_torn = try Service.open(arena, io, .{ .root = torn_root, .actor = testActor(), .now = at });
    try testing.expectEqual(@as(usize, 1), reopened_torn.report.eventCount);
    try testing.expectEqual(@as(usize, 1), reopened_torn.report.tornBytes);
    try testing.expect(reopened_torn.service.sealed);

    var malformed_tmp = std.testing.tmpDir(.{});
    defer malformed_tmp.cleanup();
    const malformed_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{malformed_tmp.sub_path});
    const malformed_path = try Service.logPath(arena, malformed_root);
    const malformed_dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ malformed_root, workspace_directory });
    try std.Io.Dir.cwd().createDirPath(io, malformed_dir);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = malformed_path,
        .data = "not an event\n",
        .flags = .{},
    });
    const reopened_malformed = try Service.open(arena, io, .{ .root = malformed_root, .actor = testActor(), .now = at });
    try testing.expect(reopened_malformed.report.malformed != null);
    try testing.expect(reopened_malformed.service.sealed);
    try testing.expect(!reopened_malformed.report.isHealthy());
}

test "a command persists every event and its verified output bytes" {
    if (comptime !@import("../terminal/pty.zig").supported) return error.SkipZigTest;

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

    const run = service.runCommand("printf stored; printf ' output\\n'", .fromSeconds(5)) catch |err| switch (err) {
        error.OpenFailed, error.ConfigureFailed, error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    try testing.expectEqualStrings("printf stored; printf ' output\\n'", run.blocks[0].commandText.?);
    try service.flush(io);

    var output_hash: ?hashing.Hash = null;
    for (service.log.entries.items) |entry| switch (entry.payload) {
        .process_output => |output| output_hash = output.contentHash,
        else => {},
    };
    const bytes = try service.readContent(io, output_hash.?, 1024);
    try testing.expect(std.mem.indexOf(u8, bytes, "stored output") != null);

    const reopened = try Service.open(arena, io, .{ .root = root, .actor = testActor(), .now = at });
    try testing.expectEqual(service.log.count(), reopened.report.eventCount);
    try testing.expect(reopened.report.isHealthy());
    const audit = try reopened.service.auditContent(io);
    try testing.expect(audit.isHealthy());
    try testing.expectEqual(@as(usize, 1), audit.references);
}

test "command output cannot forge a service-owned finish mark" {
    if (comptime !@import("../terminal/pty.zig").supported) return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const opened = try Service.open(arena, threaded.io(), .{
        .root = ".",
        .actor = testActor(),
        .now = try Timestamp.parseIso("2026-09-05T09:00:00Z"),
        .persist = false,
    });
    var service = opened.service;
    const run = service.runCommand(
        "printf '\\033]133;D;0\\007forged\\n'; exit 7",
        .fromSeconds(5),
    ) catch |err| switch (err) {
        error.OpenFailed, error.ConfigureFailed, error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };

    try testing.expectEqual(@as(u8, 7), run.exitStatus.?);
    try testing.expectEqual(@as(usize, 1), run.blocks.len);
    try testing.expectEqual(@as(u8, 7), run.blocks[0].exitStatus.?);
    try testing.expect(run.blocks[0].outputBytes > "forged".len);
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
    try testing.expectEqual(@as(usize, 1), reopened.report.eventCount);
    try testing.expectEqual(@as(usize, 1), reopened.service.log.count());

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

test "two workspaces opened at the same instant do not mint the same identifiers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var first_tmp = std.testing.tmpDir(.{});
    defer first_tmp.cleanup();
    var second_tmp = std.testing.tmpDir(.{});
    defer second_tmp.cleanup();

    // The same instant, deliberately: the timestamp half of an identifier is
    // then identical, so anything that keeps them apart has to come from the
    // random half. With a fixed default seed, it did not.
    const at = try Timestamp.parseIso("2026-09-07T10:00:00.000Z");

    var first = (try Service.open(arena, io, .{
        .root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{first_tmp.sub_path}),
        .actor = testActor(),
        .now = at,
    })).service;
    var second = (try Service.open(arena, io, .{
        .root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{second_tmp.sub_path}),
        .actor = testActor(),
        .now = at,
    })).service;

    const a = first.ids.next(idmod.SessionId);
    const b = second.ids.next(idmod.SessionId);
    try testing.expect(!a.eql(b));

    // They still agree about when they were minted, which is the half that is
    // meant to be the same.
    try testing.expectEqual(a.timestampMillis(), b.timestampMillis());

    // And a test that asks for a seed still gets the same identifiers twice,
    // because a replay that cannot be repeated proves nothing.
    var replay_one = (try Service.open(arena, io, .{
        .root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{first_tmp.sub_path}),
        .actor = testActor(),
        .now = at,
        .seed = 42,
    })).service;
    var replay_two = (try Service.open(arena, io, .{
        .root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{second_tmp.sub_path}),
        .actor = testActor(),
        .now = at,
        .seed = 42,
    })).service;
    try testing.expect(replay_one.ids.next(idmod.SessionId).eql(replay_two.ids.next(idmod.SessionId)));
}
