//! Blocks: one unit of work, with everything needed to understand it later.
//!
//! Warp's insight was to group prompt, command and output into a block. This
//! model goes one step further and makes the block a first-class record with an
//! actor, a causal parent, a git context and an environment fingerprint, so
//! that a human command, an agent's command and a background job are the same
//! kind of thing and can be reasoned about together.
//!
//! Blocks are *derived* from the event log. Nothing writes a block directly, so
//! the block list can always be rebuilt after a crash, on another machine, or
//! from an exported log.

const std = @import("std");
const event_mod = @import("../events/event.zig");
const log_mod = @import("../events/log.zig");
const idmod = @import("../core/id.zig");
const hashing = @import("../core/hash.zig");
const timeutil = @import("../core/time.zig");
const provenance = @import("../data/provenance.zig");

pub const BlockId = idmod.BlockId;
pub const SessionId = idmod.SessionId;
pub const Timestamp = timeutil.Timestamp;
pub const Hash = hashing.Hash;

pub const Kind = enum {
    /// A command a shell ran.
    command,
    /// An agent run: the request, the plan and everything it caused.
    agent_run,
    /// One typed tool call inside an agent run.
    tool_call,
    /// A change to a file.
    file_change,
    /// A request for a person to decide.
    approval,
    /// A message from a person or an agent.
    message,
};

pub const Status = enum {
    running,
    succeeded,
    failed,
    denied,
    cancelled,
    /// The process ended, but no result was recorded. Usually a crash.
    unknown,

    pub fn text(self: Status) []const u8 {
        return switch (self) {
            .running => "running",
            .succeeded => "succeeded",
            .failed => "failed",
            .denied => "denied by policy",
            .cancelled => "cancelled",
            .unknown => "result unknown",
        };
    }
};

pub const GitContext = struct {
    repository: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    head: ?[]const u8 = null,
    dirtyFileCount: u32 = 0,
};

/// One piece of a command's output, as it arrived.
///
/// A program's output reaches the workbench in whatever pieces the operating
/// system hands over, and each piece is stored and hashed on its own. The
/// index number is the event's, so pieces can be put back in order however
/// they were delivered.
pub const Chunk = struct {
    hash: Hash,
    byteCount: usize,
    index: u32,
};

/// Order pieces the way the program produced them.
///
/// The event carries the index for exactly this: reads can be delivered out of
/// order, and putting them back by arrival time would reassemble the output
/// wrongly and silently.
fn earlierChunk(_: void, a: Chunk, b: Chunk) bool {
    return a.index < b.index;
}

/// Where the block's output lives. Small output is kept inline; anything
/// larger is content-addressed so the log stays small and replay stays fast.
///
/// Output that arrived in more than one piece is `chunked`, and that variant
/// exists because the alternative was a lie: the fold used to keep the *last*
/// piece's hash beside the *summed* byte count, so a block with three chunks
/// claimed a hash covering twenty bytes next to a count of six thousand. Every
/// consumer that checked the hash against the count would have found the record
/// wrong, and every consumer that trusted it would have been reading twenty
/// bytes and calling them the output.
pub const ContentRef = union(enum) {
    none,
    inline_text: []const u8,
    hashed: struct { hash: Hash, byteCount: usize },
    chunked: struct { chunks: []const Chunk, byteCount: usize },

    /// How many bytes the output is, all pieces together.
    pub fn totalBytes(self: ContentRef) usize {
        return switch (self) {
            .none => 0,
            .inline_text => |text| text.len,
            .hashed => |h| h.byteCount,
            .chunked => |c| c.byteCount,
        };
    }

    /// The pieces, in the order they were produced.
    ///
    /// One piece for a single hash, so a caller reassembling output does not
    /// need to know which shape it got.
    pub fn pieces(self: ContentRef, one: *[1]Chunk) []const Chunk {
        return switch (self) {
            .chunked => |c| c.chunks,
            .hashed => |h| blk: {
                one[0] = .{ .hash = h.hash, .byteCount = h.byteCount, .index = 0 };
                break :blk one[0..1];
            },
            else => &.{},
        };
    }
};

pub const Block = struct {
    id: BlockId,
    session: SessionId,
    kind: Kind,
    status: Status = .running,
    createdAt: Timestamp,
    startedAt: ?Timestamp = null,
    finishedAt: ?Timestamp = null,
    workingDirectory: ?[]const u8 = null,
    commandText: ?[]const u8 = null,
    exitStatus: ?u8 = null,
    actor: event_mod.Actor,
    content: ContentRef = .none,
    git: ?GitContext = null,
    environment: ?provenance.EnvironmentFingerprint = null,
    parent: ?BlockId = null,
    children: []const BlockId = &.{},
    /// True when a shell integration marker set the boundary. Metrics computed
    /// from inferred boundaries are less trustworthy, and say so.
    boundaryFromShell: bool = false,
    outputBytes: usize = 0,

    pub fn duration(self: Block) ?timeutil.Duration {
        const started = self.startedAt orelse return null;
        const finished = self.finishedAt orelse return null;
        return finished.since(started);
    }

    pub fn isFinished(self: Block) bool {
        return self.finishedAt != null;
    }

    /// One line for the block list, written for a person.
    pub fn writeSummary(self: Block, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}", .{self.commandText orelse @tagName(self.kind)});
        try w.print("  [{s}]", .{self.status.text()});
        if (self.duration()) |d| {
            const ms = d.millis();
            // Zero-padded signed integers print a sign, so the parts are made
            // unsigned first.
            const whole: u64 = @intCast(@divTrunc(ms, 1000));
            const hundredths: u64 = @intCast(@divTrunc(@mod(ms, 1000), 10));
            if (ms < 1000) try w.print("  {d} ms", .{ms}) else try w.print("  {d}.{d:0>2} s", .{ whole, hundredths });
        }
        if (self.actor.kind.isAutomated()) try w.print("  by {s}", .{@tagName(self.actor.kind)});
    }
};

/// The block list, rebuilt from the log.
pub const Index = struct {
    arena: std.mem.Allocator,
    blocks: std.ArrayList(Block) = .empty,

    pub fn build(arena: std.mem.Allocator, log: log_mod.Log) !Index {
        var index: Index = .{ .arena = arena };
        var position: std.AutoArrayHashMapUnmanaged([16]u8, usize) = .empty;
        // Latest known git context for each session, so a block records the
        // state of the repository at the moment it ran.
        var git_by_session: std.AutoArrayHashMapUnmanaged([16]u8, GitContext) = .empty;
        // Positions of blocks that have not finished yet, so a git change can
        // reach them without walking the whole list.
        var open_blocks: std.ArrayList(usize) = .empty;
        // Output pieces, per block, kept until the fold is finished so that a
        // block with one piece and a block with several are recorded as the
        // different things they are.
        var chunks_by_block: std.AutoArrayHashMapUnmanaged([16]u8, std.ArrayList(Chunk)) = .empty;

        for (log.entries.items) |entry| {
            switch (entry.payload) {
                .command_submitted => |e| {
                    try position.put(arena, e.block.raw.bytes, index.blocks.items.len);
                    try open_blocks.append(arena, index.blocks.items.len);
                    try index.blocks.append(arena, .{
                        .id = e.block,
                        .session = e.session,
                        .kind = .command,
                        .status = .running,
                        .createdAt = entry.at,
                        .startedAt = entry.at,
                        .workingDirectory = e.workingDirectory,
                        .commandText = e.commandText,
                        .actor = entry.actor,
                        .boundaryFromShell = e.boundaryFromShell,
                        .git = git_by_session.get(e.session.raw.bytes),
                    });
                },
                .process_output => |e| {
                    const at = position.get(e.block.raw.bytes) orelse continue;
                    const block = &index.blocks.items[at];
                    block.outputBytes += e.byteCount;
                    const found = try chunks_by_block.getOrPut(arena, e.block.raw.bytes);
                    if (!found.found_existing) found.value_ptr.* = .empty;
                    try found.value_ptr.append(arena, .{
                        .hash = e.contentHash,
                        .byteCount = e.byteCount,
                        .index = e.chunkIndex,
                    });
                },
                .command_finished => |e| {
                    const at = position.get(e.block.raw.bytes) orelse continue;
                    const block = &index.blocks.items[at];
                    block.finishedAt = entry.at;
                    block.exitStatus = e.exitStatus;
                    block.status = if (e.exitStatus == 0) .succeeded else .failed;
                },
                .session_opened => |e| {
                    if (e.branch != null or e.repository != null) {
                        try git_by_session.put(arena, e.session.raw.bytes, .{
                            .repository = e.repository,
                            .branch = e.branch,
                        });
                    }
                },
                .agent_started => |e| {
                    const block_id = BlockId.fromRaw(e.agent.raw);
                    try position.put(arena, block_id.raw.bytes, index.blocks.items.len);
                    try open_blocks.append(arena, index.blocks.items.len);
                    try index.blocks.append(arena, .{
                        .id = block_id,
                        .session = e.session,
                        .kind = .agent_run,
                        .createdAt = entry.at,
                        .startedAt = entry.at,
                        .commandText = e.request,
                        .actor = entry.actor,
                    });
                },
                .tool_finished => |e| {
                    try index.blocks.append(arena, .{
                        .id = BlockId.fromRaw(e.call.raw),
                        .session = e.session,
                        .kind = .tool_call,
                        .status = switch (e.outcome) {
                            .completed => .succeeded,
                            .failed => .failed,
                            .denied => .denied,
                            .cancelled => .cancelled,
                            .timed_out => .failed,
                        },
                        .createdAt = entry.at,
                        .startedAt = entry.at.addNanos(-e.duration.ns),
                        .finishedAt = entry.at,
                        .commandText = e.summary,
                        .actor = entry.actor,
                        .parent = BlockId.fromRaw(e.agent.raw),
                    });
                },
                .agent_finished => |e| {
                    const at = position.get(e.agent.raw.bytes) orelse continue;
                    const block = &index.blocks.items[at];
                    block.finishedAt = entry.at;
                    block.status = switch (e.outcome) {
                        .answered => .succeeded,
                        .refused, .stopped_by_policy => .denied,
                        .waiting_for_a_person => .running,
                        .out_of_budget, .unavailable => .failed,
                    };
                    if (e.summary.len > 0) block.commandText = e.summary;
                },
                .file_changed => |e| {
                    try index.blocks.append(arena, .{
                        .id = idmod.BlockId.fromRaw(entry.id.raw),
                        .session = e.session,
                        .kind = .file_change,
                        .status = .succeeded,
                        .createdAt = entry.at,
                        .finishedAt = entry.at,
                        .commandText = e.path,
                        .actor = entry.actor,
                        .parent = if (e.agent) |a| BlockId.fromRaw(a.raw) else null,
                    });
                },
                .approval_requested => |e| {
                    try position.put(arena, e.approval.raw.bytes, index.blocks.items.len);
                    try index.blocks.append(arena, .{
                        .id = BlockId.fromRaw(e.approval.raw),
                        .session = e.session,
                        .kind = .approval,
                        .status = .running,
                        .createdAt = entry.at,
                        .commandText = e.promptText,
                        .actor = entry.actor,
                    });
                },
                .approval_resolved => |e| {
                    const at = position.get(e.approval.raw.bytes) orelse continue;
                    const block = &index.blocks.items[at];
                    block.finishedAt = entry.at;
                    block.status = switch (e.outcome) {
                        .allow_once, .allow_always_here => .succeeded,
                        .deny => .denied,
                        .expired => .cancelled,
                    };
                },
                .git_changed => |e| {
                    const context: GitContext = .{
                        .repository = e.repository,
                        .branch = e.branch,
                        .head = e.head,
                        .dirtyFileCount = e.dirtyFileCount,
                    };
                    try git_by_session.put(arena, e.session.raw.bytes, context);
                    // Blocks already open in this session pick up the change
                    // too, because they are still running under it. Only the
                    // open ones are visited: a session has a handful of those
                    // at a time, and scanning every block that ever ran would
                    // make a long log quadratic to fold.
                    var kept: usize = 0;
                    for (open_blocks.items) |at| {
                        const block = &index.blocks.items[at];
                        if (block.finishedAt != null) continue;
                        open_blocks.items[kept] = at;
                        kept += 1;
                        if (!block.session.eql(e.session)) continue;
                        block.git = context;
                    }
                    open_blocks.shrinkRetainingCapacity(kept);
                },
                else => {},
            }
        }

        // Now that every piece is in, say what the output is. One piece is one
        // hash of that many bytes. Several pieces are several hashes, each
        // covering its own bytes, in the order the program produced them.
        var chunk_entries = chunks_by_block.iterator();
        while (chunk_entries.next()) |entry| {
            const at = position.get(entry.key_ptr.*) orelse continue;
            const block = &index.blocks.items[at];
            const list = entry.value_ptr.*;
            if (list.items.len == 0) continue;
            std.mem.sort(Chunk, list.items, {}, earlierChunk);
            var total: usize = 0;
            for (list.items) |chunk| total += chunk.byteCount;
            block.content = if (list.items.len == 1)
                .{ .hashed = .{ .hash = list.items[0].hash, .byteCount = list.items[0].byteCount } }
            else
                .{ .chunked = .{ .chunks = list.items, .byteCount = total } };
        }

        // Fill in children from the parent links. Every block is looked up by
        // identifier rather than by scanning, because scanning turns folding a
        // long session into quadratic work: a workspace with twenty thousand
        // blocks would do four hundred million comparisons to answer a
        // question that is one hash lookup for each block.
        var by_id: std.AutoArrayHashMapUnmanaged([16]u8, usize) = .empty;
        try by_id.ensureTotalCapacity(arena, index.blocks.items.len);
        for (index.blocks.items, 0..) |block, i| by_id.putAssumeCapacity(block.id.raw.bytes, i);

        for (index.blocks.items, 0..) |block, i| {
            const parent = block.parent orelse continue;
            const at = by_id.get(parent.raw.bytes) orelse continue;
            const candidate = &index.blocks.items[at];
            var children: std.ArrayList(BlockId) = .{ .items = @constCast(candidate.children), .capacity = candidate.children.len };
            try children.append(arena, index.blocks.items[i].id);
            candidate.children = children.items;
        }
        return index;
    }

    pub fn count(self: Index) usize {
        return self.blocks.items.len;
    }

    pub fn get(self: Index, id: BlockId) ?Block {
        for (self.blocks.items) |b| {
            if (b.id.eql(id)) return b;
        }
        return null;
    }

    pub fn forSession(self: Index, session: SessionId) !std.ArrayList(Block) {
        var out: std.ArrayList(Block) = .empty;
        for (self.blocks.items) |b| {
            if (b.session.eql(session)) try out.append(self.arena, b);
        }
        return out;
    }

    pub fn failed(self: Index) !std.ArrayList(Block) {
        var out: std.ArrayList(Block) = .empty;
        for (self.blocks.items) |b| {
            if (b.status == .failed or b.status == .denied) try out.append(self.arena, b);
        }
        return out;
    }

    /// Blocks whose command text contains `needle`, case-insensitively. The
    /// real search runs over the indexed store; this is the in-memory form used
    /// by tests and by short-lived sessions.
    pub fn search(self: Index, needle: []const u8) !std.ArrayList(Block) {
        var out: std.ArrayList(Block) = .empty;
        for (self.blocks.items) |b| {
            const command = b.commandText orelse continue;
            if (std.ascii.indexOfIgnoreCase(command, needle) != null) try out.append(self.arena, b);
        }
        return out;
    }
};

const testing = std.testing;

test "blocks are rebuilt from the log" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(61, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 62);
    const person: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "sean" };
    const session = gen.next(SessionId);
    const block = gen.next(BlockId);
    var at = try Timestamp.parseIso("2026-09-04T20:00:00Z");

    _ = try log.append(.{ .session_opened = .{ .session = session, .workingDirectory = "/home/user/zag", .branch = "main" } }, .{ .at = at, .actor = person });
    _ = try log.append(.{ .git_changed = .{ .session = session, .repository = "zag", .branch = "feature/parser", .dirtyFileCount = 4 } }, .{ .at = at, .actor = person });
    _ = try log.append(.{ .command_submitted = .{
        .block = block,
        .session = session,
        .commandText = "zig build test",
        .workingDirectory = "/home/user/zag",
        .boundaryFromShell = true,
    } }, .{ .at = at, .actor = person });
    at = at.addNanos(1_500 * timeutil.ns_per_ms);
    _ = try log.append(.{ .process_output = .{
        .block = block,
        .session = session,
        .contentHash = Hash.of("All 114 tests passed."),
        .byteCount = 21,
    } }, .{ .at = at, .actor = person });
    _ = try log.append(.{ .command_finished = .{
        .block = block,
        .session = session,
        .exitStatus = 0,
        .duration = timeutil.Duration.fromMillis(1500),
    } }, .{ .at = at, .actor = person });

    const index = try Index.build(arena, log);
    try testing.expectEqual(@as(usize, 1), index.count());

    const built = index.get(block).?;
    try testing.expectEqual(Status.succeeded, built.status);
    try testing.expectEqualStrings("zig build test", built.commandText.?);
    try testing.expectEqual(@as(i64, 1500), built.duration().?.millis());
    try testing.expect(built.boundaryFromShell);
    try testing.expectEqual(@as(usize, 21), built.outputBytes);
    try testing.expectEqualStrings("feature/parser", built.git.?.branch.?);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try built.writeSummary(&aw.writer);
    try testing.expectEqualStrings("zig build test  [succeeded]  1.50 s", aw.written());
}

test "an agent run and its tool calls form a parent and children" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(63, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 64);
    const robot: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .agent, .label = "agent 3" };
    const session = gen.next(SessionId);
    const agent = gen.next(idmod.AgentId);
    const call = gen.next(idmod.ToolCallId);
    const at = try Timestamp.parseIso("2026-09-04T20:00:00Z");

    const started = try log.append(.{ .agent_started = .{
        .agent = agent,
        .session = session,
        .request = "fix the parser",
        .provider = "local",
        .model = "coder",
        .policy = "repo-write-no-network",
    } }, .{ .at = at, .actor = robot });
    _ = try log.append(.{ .tool_finished = .{
        .call = call,
        .agent = agent,
        .session = session,
        .outcome = .denied,
        .duration = timeutil.Duration.fromMillis(3),
        .resultHash = Hash.of("denied"),
        .summary = "Policy does not allow network access.",
    } }, .{ .at = at, .actor = robot, .causedBy = started.id });
    _ = try log.append(.{ .file_changed = .{
        .session = session,
        .path = "src/parser.zig",
        .changeKind = .modified,
        .agent = agent,
    } }, .{ .at = at, .actor = robot, .causedBy = started.id });

    const index = try Index.build(arena, log);
    try testing.expectEqual(@as(usize, 3), index.count());

    const run = index.get(BlockId.fromRaw(agent.raw)).?;
    try testing.expectEqual(Kind.agent_run, run.kind);
    try testing.expectEqual(@as(usize, 2), run.children.len);

    const denied = try index.failed();
    try testing.expectEqual(@as(usize, 1), denied.items.len);
    try testing.expectEqual(Status.denied, denied.items[0].status);

    const found = try index.search("parser");
    try testing.expectEqual(@as(usize, 2), found.items.len);
}

test "an approval becomes a block with an outcome" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(65, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 66);
    const person: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "sean" };
    const session = gen.next(SessionId);
    const approval = gen.next(idmod.DecisionId);
    const at = try Timestamp.parseIso("2026-09-04T20:41:31Z");

    _ = try log.append(.{ .approval_requested = .{
        .approval = approval,
        .session = session,
        .capability = "process.execute",
        .resource = "rm -rf build/",
        .promptText = "Run rm -rf build/? The agent wants to delete the build folder in this repository.",
        .policy = "P23",
    } }, .{ .at = at, .actor = person });
    _ = try log.append(.{ .approval_resolved = .{
        .approval = approval,
        .session = session,
        .outcome = .allow_once,
        .decidedBy = person.id,
    } }, .{ .at = at.addNanos(4 * timeutil.ns_per_s), .actor = person });

    const index = try Index.build(arena, log);
    const block = index.get(BlockId.fromRaw(approval.raw)).?;
    try testing.expectEqual(Kind.approval, block.kind);
    try testing.expectEqual(Status.succeeded, block.status);
    try testing.expect(block.isFinished());
}

test "output that arrived in pieces is recorded as pieces, not as the last one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log = log_mod.Log.init(arena, 61);
    var gen: idmod.Generator = .init(62, 1_788_000_000_000);
    const actor: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "you" };
    const session = gen.next(idmod.SessionId);
    const block = gen.next(idmod.BlockId);

    _ = try log.append(.{ .command_submitted = .{
        .block = block,
        .session = session,
        .commandText = "zig build test",
        .workingDirectory = "/repo",
    } }, .{ .at = .{ .ns = 1 }, .actor = actor });

    // Three reads, as a pseudoterminal really delivers them, and deliberately
    // out of order to prove the index is what puts them back.
    const first = Hash.of("first piece, five thousand bytes of it");
    const second = Hash.of("second piece");
    const third = Hash.of("third");
    _ = try log.append(.{ .process_output = .{
        .block = block,
        .session = session,
        .contentHash = third,
        .byteCount = 5,
        .chunkIndex = 2,
    } }, .{ .at = .{ .ns = 2 }, .actor = actor });
    _ = try log.append(.{ .process_output = .{
        .block = block,
        .session = session,
        .contentHash = first,
        .byteCount = 5000,
        .chunkIndex = 0,
    } }, .{ .at = .{ .ns = 3 }, .actor = actor });
    _ = try log.append(.{ .process_output = .{
        .block = block,
        .session = session,
        .contentHash = second,
        .byteCount = 12,
        .chunkIndex = 1,
    } }, .{ .at = .{ .ns = 4 }, .actor = actor });

    const index = try Index.build(arena, log);
    const folded = index.blocks.items[0];

    // Three pieces, each with the hash of its own bytes. The old fold kept the
    // last piece's hash beside the summed count, so the record said a hash of
    // five bytes covered five thousand and seventeen.
    try testing.expect(folded.content == .chunked);
    const chunks = folded.content.chunked.chunks;
    try testing.expectEqual(@as(usize, 3), chunks.len);
    try testing.expectEqual(@as(usize, 5017), folded.content.totalBytes());
    try testing.expectEqual(folded.outputBytes, folded.content.totalBytes());

    // In the order the program produced them, not the order they arrived.
    try testing.expect(chunks[0].hash.eql(first));
    try testing.expect(chunks[1].hash.eql(second));
    try testing.expect(chunks[2].hash.eql(third));

    // Every piece's hash covers exactly the bytes beside it, which is the
    // property that was false before and is the only one worth having.
    try testing.expectEqual(@as(usize, 5000), chunks[0].byteCount);
    try testing.expectEqual(@as(usize, 12), chunks[1].byteCount);
    try testing.expectEqual(@as(usize, 5), chunks[2].byteCount);

    var one: [1]Chunk = undefined;
    try testing.expectEqual(@as(usize, 3), folded.content.pieces(&one).len);
}

test "output that arrived in one piece stays one hash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log = log_mod.Log.init(arena, 71);
    var gen: idmod.Generator = .init(72, 1_788_000_000_000);
    const actor: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "you" };
    const session = gen.next(idmod.SessionId);
    const block = gen.next(idmod.BlockId);

    _ = try log.append(.{ .command_submitted = .{
        .block = block,
        .session = session,
        .commandText = "echo hello",
        .workingDirectory = "/repo",
    } }, .{ .at = .{ .ns = 1 }, .actor = actor });
    const only = Hash.of("hello\n");
    _ = try log.append(.{ .process_output = .{
        .block = block,
        .session = session,
        .contentHash = only,
        .byteCount = 6,
    } }, .{ .at = .{ .ns = 2 }, .actor = actor });

    const index = try Index.build(arena, log);
    const folded = index.blocks.items[0];
    try testing.expect(folded.content == .hashed);
    try testing.expect(folded.content.hashed.hash.eql(only));
    try testing.expectEqual(@as(usize, 6), folded.content.hashed.byteCount);

    // And a caller that just wants the pieces gets one, so it need not know
    // which shape it was handed.
    var one: [1]Chunk = undefined;
    const pieces = folded.content.pieces(&one);
    try testing.expectEqual(@as(usize, 1), pieces.len);
    try testing.expect(pieces[0].hash.eql(only));
}

test "moving to a directory is not a repository changing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log = log_mod.Log.init(arena, 81);
    var gen: idmod.Generator = .init(82, 1_788_000_000_000);
    const actor: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "you" };
    const session = gen.next(idmod.SessionId);
    const block = gen.next(idmod.BlockId);

    // A `cd /tmp`, as a shell integration mark reports it.
    _ = try log.append(.{ .directory_changed = .{
        .session = session,
        .path = "/tmp",
    } }, .{ .at = .{ .ns = 1 }, .actor = actor });
    _ = try log.append(.{ .command_submitted = .{
        .block = block,
        .session = session,
        .commandText = "ls",
        .workingDirectory = "/tmp",
    } }, .{ .at = .{ .ns = 2 }, .actor = actor });

    const index = try Index.build(arena, log);
    const folded = index.blocks.items[0];

    // The block knows where it ran, and claims no repository. It used to be
    // recorded as `git_changed{ .repository = "/tmp" }`, so a search for work
    // in a repository came back with directories that were never repositories.
    try testing.expectEqualStrings("/tmp", folded.workingDirectory.?);
    try testing.expect(folded.git == null);
}
