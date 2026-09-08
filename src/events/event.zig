//! The workspace event: the one thing in this system that owns truth.
//!
//! The user interface does not own truth. Agents do not own truth. The
//! pseudoterminal does not own truth. Every state the workbench can be in is a
//! fold over this stream, which is what gives replay, crash recovery, remote
//! attachment, audit trails and deterministic agent context for free rather
//! than as separate features bolted on later.
//!
//! Two design rules hold here:
//!   * An event states what happened. It never states what should happen.
//!   * Field names come from the metadata registry, so an event means the same
//!     thing to the daemon, the desktop client, a plugin and an auditor.

const std = @import("std");
const idmod = @import("../core/id.zig");
const identity = @import("../core/identity.zig");
const hashing = @import("../core/hash.zig");
const timeutil = @import("../core/time.zig");
const provenance = @import("../data/provenance.zig");

pub const EventId = idmod.EventId;
pub const SessionId = idmod.SessionId;
pub const BlockId = idmod.BlockId;
pub const ActorId = idmod.ActorId;
pub const AgentId = idmod.AgentId;
pub const ToolCallId = idmod.ToolCallId;
pub const Timestamp = timeutil.Timestamp;
pub const Hash = hashing.Hash;

/// Who caused an event. `kind` decides which governance rules apply; `id`
/// decides who is answerable.
pub const Actor = struct {
    id: ActorId,
    kind: provenance.ProducerKind,
    /// Short display name. Never used for identity.
    label: []const u8 = "",

    /// The actor for a derived identity.
    ///
    /// `core/identity.zig` decides who somebody is; this turns that into the
    /// three fields an event carries, so there is one definition of an actor
    /// rather than one here and a copy there.
    pub fn of(who: identity.Identity) Actor {
        return .{ .id = who.id, .kind = who.kind, .label = who.label };
    }
};

pub const SessionOpened = struct {
    session: SessionId,
    workingDirectory: []const u8,
    shell: ?[]const u8 = null,
    /// Terminal size at the moment the session opened.
    columns: u16 = 80,
    rows: u16 = 24,
    repository: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    worktree: ?[]const u8 = null,
};

pub const SessionClosed = struct {
    session: SessionId,
    exitStatus: ?u8 = null,
    reason: []const u8 = "",
};

pub const CommandSubmitted = struct {
    block: BlockId,
    session: SessionId,
    commandText: []const u8,
    workingDirectory: []const u8,
    /// True when a shell integration marker told us the boundary, false when
    /// the boundary was inferred. The difference matters for every metric
    /// computed from blocks.
    boundaryFromShell: bool = false,
    /// How many credentials were taken out of `commandText` before it was
    /// written down. A key typed on a command line is the most common way one
    /// reaches a log, and `export API_KEY=…` is in every shell history there is.
    redactions: usize = 0,
};

pub const OutputStream = enum { stdout, stderr, merged };

pub const ProcessOutput = struct {
    block: BlockId,
    session: SessionId,
    stream: OutputStream = .merged,
    /// Bytes are stored in the content store; the event carries the reference
    /// so the log stays small and replayable.
    contentHash: Hash,
    byteCount: usize,
    /// Sequence within the block, so out-of-order delivery can be repaired.
    chunkIndex: u32 = 0,
    /// How many credentials were taken out of the stored bytes.
    ///
    /// The placeholders are visible in the content object, but the count
    /// belongs here as well, because the event is what the hash chain covers
    /// and the content object is not. A reader who has the log and not the
    /// objects can still tell a clean block from a redacted one.
    redactions: usize = 0,
};

pub const CommandFinished = struct {
    block: BlockId,
    session: SessionId,
    exitStatus: u8,
    duration: timeutil.Duration,
    /// Set when the process ended because of a signal rather than an exit.
    signal: ?u8 = null,
};

pub const AgentStarted = struct {
    agent: AgentId,
    session: SessionId,
    /// What the person asked for, in their words.
    request: []const u8,
    provider: []const u8,
    model: []const u8,
    /// Policy the agent runs under.
    policy: []const u8,
};

pub const AgentMessage = struct {
    agent: AgentId,
    session: SessionId,
    /// Who said it.
    ///
    /// `workspace` is the odd one and the reason this is not just the model's
    /// roles: some things on an agent's timeline are the workbench speaking
    /// about the run rather than the model speaking in it. Room being made in
    /// the conversation is the first of them. Filing that as `progress` would
    /// put words in the model's mouth, and a record that misattributes who
    /// said something is worse than one that does not mention it.
    role: enum { plan, progress, result, question, refusal, workspace },
    text: []const u8,
};

/// An agent run ended, and why.
///
/// Without this the block folded from `agent_started` has no finish, so it
/// stays running for ever: a workspace with a hundred completed agent runs
/// shows a hundred that are still going. It also means the run itself has no
/// duration and no outcome, only its individual tool calls, so "how long did
/// that take and did it work" had no answer at the level a person asks it.
pub const AgentFinished = struct {
    agent: AgentId,
    session: SessionId,
    outcome: enum { answered, refused, stopped_by_policy, waiting_for_a_person, out_of_budget, unavailable },
    duration: timeutil.Duration,
    /// Tool calls the run made, and how many were refused.
    toolCalls: u32 = 0,
    refusedCalls: u32 = 0,
    /// What the run cost, where the provider said.
    inputTokens: u64 = 0,
    outputTokens: u64 = 0,
    /// One sentence for the person reading the block list later.
    summary: []const u8 = "",
};

pub const ToolRequested = struct {
    call: ToolCallId,
    agent: AgentId,
    session: SessionId,
    tool: []const u8,
    /// Capability the call needs. Named here so the log alone shows what was
    /// asked for, without replaying the policy engine.
    capability: []const u8,
    /// Canonical JSON of the typed request.
    argumentsJson: []const u8,
    resource: []const u8 = "",
};

pub const ToolFinished = struct {
    call: ToolCallId,
    agent: AgentId,
    session: SessionId,
    outcome: enum { completed, failed, denied, cancelled, timed_out },
    duration: timeutil.Duration,
    resultHash: Hash,
    /// Plain-language summary of what happened, for the person reading later.
    summary: []const u8 = "",
};

pub const FileOpened = struct {
    session: SessionId,
    path: []const u8,
    contentHash: Hash,
};

pub const FileChanged = struct {
    session: SessionId,
    path: []const u8,
    changeKind: enum { created, modified, deleted, renamed },
    beforeHash: ?Hash = null,
    afterHash: ?Hash = null,
    /// Set when an agent made the change, so authorship is never guessed.
    agent: ?AgentId = null,
};

pub const ApprovalRequested = struct {
    approval: idmod.DecisionId,
    session: SessionId,
    agent: ?AgentId = null,
    capability: []const u8,
    resource: []const u8,
    /// The question as it was shown to the person, word for word. Keeping the
    /// exact wording is what makes an approval auditable.
    promptText: []const u8,
    policy: []const u8,
};

pub const ApprovalResolved = struct {
    approval: idmod.DecisionId,
    session: SessionId,
    outcome: enum { allow_once, allow_always_here, deny, expired },
    decidedBy: ActorId,
    /// Free text the person added when deciding.
    note: []const u8 = "",
};

/// The shell moved to another directory.
///
/// This is not a repository changing, and recording it as one was wrong: a
/// `cd /tmp` became "the repository moved to /tmp", so a history search
/// filtered by repository returned directories that were never repositories.
/// The workbench learns this from an OSC 7 mark, which says where the shell is
/// and nothing at all about version control.
pub const DirectoryChanged = struct {
    session: SessionId,
    path: []const u8,
};

pub const GitChanged = struct {
    session: SessionId,
    repository: []const u8,
    branch: ?[]const u8 = null,
    head: ?[]const u8 = null,
    dirtyFileCount: u32 = 0,
    aheadCount: u32 = 0,
    behindCount: u32 = 0,
};

pub const Diagnostic = struct {
    session: SessionId,
    path: []const u8,
    line: u32,
    column: u32,
    severity: enum { hint, information, warning, @"error" },
    /// Source of the diagnostic: a language server, a compiler, a checker.
    source: []const u8,
    message: []const u8,
    /// Rule identifier, when the source has one.
    code: ?[]const u8 = null,
};

pub const EvidenceRecorded = struct {
    session: ?SessionId = null,
    requirement: []const u8,
    subject: []const u8,
    method: []const u8,
    result: []const u8,
    contentHash: Hash,
};

pub const UserMessage = struct {
    session: SessionId,
    text: []const u8,
};

/// Every typed thing that can happen in a workspace.
pub const WorkspaceEvent = union(enum) {
    session_opened: SessionOpened,
    session_closed: SessionClosed,
    command_submitted: CommandSubmitted,
    process_output: ProcessOutput,
    command_finished: CommandFinished,
    agent_started: AgentStarted,
    agent_message: AgentMessage,
    agent_finished: AgentFinished,
    tool_requested: ToolRequested,
    tool_finished: ToolFinished,
    file_opened: FileOpened,
    file_changed: FileChanged,
    approval_requested: ApprovalRequested,
    approval_resolved: ApprovalResolved,
    directory_changed: DirectoryChanged,
    git_changed: GitChanged,
    diagnostic: Diagnostic,
    evidence_recorded: EvidenceRecorded,
    user_message: UserMessage,

    pub fn kindName(self: WorkspaceEvent) []const u8 {
        return @tagName(self);
    }

    /// The session an event belongs to, when it belongs to one.
    pub fn session(self: WorkspaceEvent) ?SessionId {
        return switch (self) {
            .session_opened => |e| e.session,
            .session_closed => |e| e.session,
            .command_submitted => |e| e.session,
            .process_output => |e| e.session,
            .command_finished => |e| e.session,
            .agent_started => |e| e.session,
            .agent_message => |e| e.session,
            .agent_finished => |e| e.session,
            .tool_requested => |e| e.session,
            .tool_finished => |e| e.session,
            .file_opened => |e| e.session,
            .file_changed => |e| e.session,
            .approval_requested => |e| e.session,
            .approval_resolved => |e| e.session,
            .directory_changed => |e| e.session,
            .git_changed => |e| e.session,
            .diagnostic => |e| e.session,
            .evidence_recorded => |e| e.session,
            .user_message => |e| e.session,
        };
    }

    /// The block an event belongs to, when it belongs to one.
    pub fn block(self: WorkspaceEvent) ?BlockId {
        return switch (self) {
            .command_submitted => |e| e.block,
            .process_output => |e| e.block,
            .command_finished => |e| e.block,
            else => null,
        };
    }

    /// Does this event describe an action that a governance framework treats as
    /// automated decision-making?
    pub fn isAgentAction(self: WorkspaceEvent) bool {
        return switch (self) {
            .agent_started, .agent_message, .agent_finished, .tool_requested, .tool_finished => true,
            .file_changed => |e| e.agent != null,
            else => false,
        };
    }
};

/// An event as it is stored: the payload plus everything needed to order it,
/// attribute it, and prove that the record has not been changed.
pub const Envelope = struct {
    id: EventId,
    /// Position in the log, from 1.
    sequence: u64,
    at: Timestamp,
    actor: Actor,
    /// The event that caused this one. Following causation gives the execution
    /// graph: one agent run, six commands, three file changes, one approval.
    causedBy: ?EventId = null,
    /// The request that this event is part of. Correlation groups an entire
    /// unit of work, however deep its causation chain runs.
    correlation: ?EventId = null,
    payload: WorkspaceEvent,
    /// Hash of the canonical encoding of everything above.
    contentHash: Hash,
    /// Hash of the previous entry's `chainHash` and this entry's `contentHash`.
    chainHash: Hash,

    /// Canonical bytes for hashing: the JSON encoding of the record without its
    /// two hash fields. Canonical because `std.json` writes struct fields in
    /// declaration order, which is fixed by the type.
    pub fn canonicalBytes(self: Envelope, arena: std.mem.Allocator) ![]const u8 {
        const Body = struct {
            id: EventId,
            sequence: u64,
            at: Timestamp,
            actor: Actor,
            causedBy: ?EventId,
            correlation: ?EventId,
            payload: WorkspaceEvent,
        };
        var aw: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(Body{
            .id = self.id,
            .sequence = self.sequence,
            .at = self.at,
            .actor = self.actor,
            .causedBy = self.causedBy,
            .correlation = self.correlation,
            .payload = self.payload,
        }, .{}, &aw.writer);
        return aw.written();
    }

    pub fn computeContentHash(self: Envelope, arena: std.mem.Allocator) !Hash {
        return Hash.of(try self.canonicalBytes(arena));
    }
};

test "events know their session and their block" {
    var gen: idmod.Generator = .init(31, 1_788_000_000_000);
    const session = gen.next(SessionId);
    const block = gen.next(BlockId);

    const submitted: WorkspaceEvent = .{ .command_submitted = .{
        .block = block,
        .session = session,
        .commandText = "zig build test",
        .workingDirectory = "/home/user/zag",
        .boundaryFromShell = true,
    } };
    try std.testing.expect(submitted.session().?.eql(session));
    try std.testing.expect(submitted.block().?.eql(block));
    try std.testing.expect(!submitted.isAgentAction());
    try std.testing.expectEqualStrings("command_submitted", submitted.kindName());

    const tool: WorkspaceEvent = .{ .tool_requested = .{
        .call = gen.next(ToolCallId),
        .agent = gen.next(AgentId),
        .session = session,
        .tool = "execute",
        .capability = "process.execute",
        .argumentsJson = "{\"argv\":[\"zig\",\"build\"]}",
        .resource = "/home/user/zag",
    } };
    try std.testing.expect(tool.isAgentAction());
    try std.testing.expect(tool.block() == null);
}

test "envelopes hash their canonical form" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(32, 1_788_000_000_000);
    const envelope: Envelope = .{
        .id = gen.next(EventId),
        .sequence = 1,
        .at = try Timestamp.parseIso("2026-09-04T20:41:31Z"),
        .actor = .{ .id = gen.next(ActorId), .kind = .person, .label = "sean" },
        .payload = .{ .user_message = .{ .session = gen.next(SessionId), .text = "run the tests" } },
        .contentHash = Hash.zero,
        .chainHash = Hash.zero,
    };

    const first = try envelope.computeContentHash(arena);
    const second = try envelope.computeContentHash(arena);
    try std.testing.expect(first.eql(second));

    var altered = envelope;
    altered.payload = .{ .user_message = .{ .session = envelope.payload.user_message.session, .text = "run the tests now" } };
    try std.testing.expect(!(try altered.computeContentHash(arena)).eql(first));
}

test "the event union serialises as a tagged object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(33, 1_788_000_000_000);
    const event: WorkspaceEvent = .{ .command_finished = .{
        .block = gen.next(BlockId),
        .session = gen.next(SessionId),
        .exitStatus = 0,
        .duration = timeutil.Duration.fromMillis(1250),
    } };

    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(event, .{}, &aw.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const inner = parsed.value.object.get("command_finished").?.object;
    try std.testing.expectEqual(@as(i64, 0), inner.get("exitStatus").?.integer);
    try std.testing.expectEqualStrings("PT1.25S", inner.get("duration").?.string);
}
