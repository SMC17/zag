//! The append-only workspace event log.
//!
//! Entries are chained by hash: each entry's `chainHash` covers the previous
//! entry's chain hash and this entry's content hash. Removing, reordering or
//! editing an entry breaks the chain at that point and every point after it,
//! which is what lets the log serve as both an operational store and an
//! evidence record under ISO 15489 and ISO/IEC 42001.
//!
//! On disk the log is JSON Lines: one entry per line, append-only, readable by
//! anything. A process that dies mid-write leaves a torn final line; loading
//! reports how many entries were recovered and refuses to guess at the rest.

const std = @import("std");
const event_mod = @import("event.zig");
const idmod = @import("../core/id.zig");
const hashing = @import("../core/hash.zig");
const timeutil = @import("../core/time.zig");

pub const Envelope = event_mod.Envelope;
pub const WorkspaceEvent = event_mod.WorkspaceEvent;
pub const Actor = event_mod.Actor;
pub const Hash = hashing.Hash;
pub const Timestamp = timeutil.Timestamp;

/// Domain separator for the chain. Changing it starts a different log.
pub const genesis_label = "zag.event-log.v1";
/// A single active log is bounded so opening it never requires unbounded
/// memory. Rotation and migration must be explicit before this limit changes.
pub const max_file_bytes: u64 = 64 * 1024 * 1024;

pub const Break = struct {
    /// Index of the first entry that does not match its chain.
    index: usize,
    sequence: u64,
    expected: Hash,
    found: Hash,
    reason: Reason,

    pub const Reason = enum { content_hash_mismatch, chain_hash_mismatch, sequence_out_of_order };
};

pub const AppendOptions = struct {
    at: Timestamp,
    actor: Actor,
    causedBy: ?event_mod.EventId = null,
    correlation: ?event_mod.EventId = null,
};

/// A complete line that could not be decoded as an event. This is different
/// from a torn final line: the newline proves that the writer considered the
/// entry complete, so silently treating it as a crash remnant would hide
/// corruption.
pub const DecodeIssue = struct {
    line: usize,
    byte_offset: usize,
    byte_count: usize,
};

pub const Log = struct {
    arena: std.mem.Allocator,
    entries: std.ArrayList(Envelope) = .empty,
    head: Hash,
    next_sequence: u64 = 1,
    ids: idmod.Generator,

    pub fn init(arena: std.mem.Allocator, id_seed: u64) Log {
        return .{
            .arena = arena,
            .head = Hash.of(genesis_label),
            .ids = idmod.Generator.init(id_seed, 0),
        };
    }

    pub fn count(self: Log) usize {
        return self.entries.items.len;
    }

    pub fn last(self: Log) ?Envelope {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.entries.items.len - 1];
    }

    /// Restrict this in-memory view to a verified prefix. This never changes
    /// the source file; callers use it so projections cannot consume entries
    /// at or after a reported chain break.
    pub fn retainPrefix(self: *Log, prefix_len: usize) void {
        std.debug.assert(prefix_len <= self.entries.items.len);
        self.entries.shrinkRetainingCapacity(prefix_len);
        if (self.last()) |entry| {
            self.head = entry.chainHash;
            self.next_sequence = entry.sequence + 1;
        } else {
            self.head = Hash.of(genesis_label);
            self.next_sequence = 1;
        }
    }

    /// Append one event. The returned envelope is the record; the caller does
    /// not get to choose its hashes or its position.
    pub fn append(self: *Log, payload: WorkspaceEvent, options: AppendOptions) !Envelope {
        self.ids.clock_ms = @divFloor(options.at.ns, timeutil.ns_per_ms);
        var envelope: Envelope = .{
            .id = self.ids.next(event_mod.EventId),
            .sequence = self.next_sequence,
            .at = options.at,
            .actor = options.actor,
            .causedBy = options.causedBy,
            .correlation = options.correlation,
            .payload = payload,
            .contentHash = Hash.zero,
            .chainHash = Hash.zero,
        };
        envelope.contentHash = try envelope.computeContentHash(self.arena);
        envelope.chainHash = Hash.chain(self.head, envelope.contentHash);

        try self.entries.append(self.arena, envelope);
        self.head = envelope.chainHash;
        self.next_sequence += 1;
        return envelope;
    }

    /// Re-derive every hash and compare. Returns the first break, or null.
    pub fn verify(self: Log) !?Break {
        var chain = Hash.of(genesis_label);
        var expected_sequence: u64 = 1;
        for (self.entries.items, 0..) |entry, index| {
            if (entry.sequence != expected_sequence) {
                return Break{
                    .index = index,
                    .sequence = entry.sequence,
                    .expected = chain,
                    .found = entry.chainHash,
                    .reason = .sequence_out_of_order,
                };
            }
            const content = try entry.computeContentHash(self.arena);
            if (!content.eql(entry.contentHash)) {
                return Break{
                    .index = index,
                    .sequence = entry.sequence,
                    .expected = content,
                    .found = entry.contentHash,
                    .reason = .content_hash_mismatch,
                };
            }
            const expected_chain = Hash.chain(chain, content);
            if (!expected_chain.eql(entry.chainHash)) {
                return Break{
                    .index = index,
                    .sequence = entry.sequence,
                    .expected = expected_chain,
                    .found = entry.chainHash,
                    .reason = .chain_hash_mismatch,
                };
            }
            chain = entry.chainHash;
            expected_sequence += 1;
        }
        return null;
    }

    pub fn writeJsonLines(self: Log, w: *std.Io.Writer) !void {
        for (self.entries.items) |entry| {
            try std.json.Stringify.value(entry, .{}, w);
            try w.writeByte('\n');
        }
    }

    pub const LoadResult = struct {
        log: Log,
        /// Entries read successfully.
        recovered: usize,
        /// Exclusive byte offset after each decoded entry, in source order.
        /// Recovery uses these original boundaries instead of re-encoding a
        /// record and pretending the replacement bytes are the evidence.
        entry_ends: []const usize,
        /// Bytes at the end of the file that were not a complete entry. A
        /// non-zero value means a process died while writing.
        torn_bytes: usize,
        /// The first complete line that was not a valid event.
        malformed: ?DecodeIssue = null,
    };

    /// Read a log back. A torn final line is dropped and reported, never
    /// repaired by guessing.
    pub fn loadJsonLines(arena: std.mem.Allocator, source: []const u8, id_seed: u64) !LoadResult {
        var log = Log.init(arena, id_seed);
        var recovered: usize = 0;
        var entry_ends: std.ArrayList(usize) = .empty;
        var torn: usize = 0;
        var malformed: ?DecodeIssue = null;

        var offset: usize = 0;
        var line_number: usize = 1;
        while (offset < source.len) {
            const line_start = offset;
            const newline = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse {
                torn = source.len - offset;
                break;
            };
            const line = std.mem.trim(u8, source[offset..newline], " \t\r");
            offset = newline + 1;
            if (line.len == 0) {
                line_number += 1;
                continue;
            }

            const parsed = std.json.parseFromSliceLeaky(Envelope, arena, line, .{
                .allocate = .alloc_always,
            }) catch {
                malformed = .{
                    .line = line_number,
                    .byte_offset = line_start,
                    .byte_count = newline - line_start,
                };
                break;
            };
            try log.entries.append(arena, parsed);
            log.head = parsed.chainHash;
            // Sequence is untrusted until `verify` runs. Saturation keeps a
            // hostile maximum value from trapping before it can be reported
            // as out of order.
            log.next_sequence = parsed.sequence +| 1;
            recovered += 1;
            try entry_ends.append(arena, offset);
            line_number += 1;
        }
        return .{
            .log = log,
            .recovered = recovered,
            .entry_ends = entry_ends.items,
            .torn_bytes = torn,
            .malformed = malformed,
        };
    }

    pub fn since(self: Log, sequence: u64) []const Envelope {
        for (self.entries.items, 0..) |entry, index| {
            if (entry.sequence > sequence) return self.entries.items[index..];
        }
        return &.{};
    }

    pub fn forSession(self: Log, session: event_mod.SessionId) !std.ArrayList(Envelope) {
        var out: std.ArrayList(Envelope) = .empty;
        for (self.entries.items) |entry| {
            const s = entry.payload.session() orelse continue;
            if (s.eql(session)) try out.append(self.arena, entry);
        }
        return out;
    }

    pub fn byId(self: Log, id: event_mod.EventId) ?Envelope {
        for (self.entries.items) |entry| {
            if (entry.id.eql(id)) return entry;
        }
        return null;
    }

    /// Fold the log into a projection. Every view in the product — the block
    /// list, the session tree, the agent timeline — is built this way.
    pub fn replay(self: Log, context: anytype, comptime apply: fn (@TypeOf(context), Envelope) anyerror!void) !void {
        for (self.entries.items) |entry| try apply(context, entry);
    }
};

const testing = std.testing;

fn testActor(gen: *idmod.Generator) Actor {
    return .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "tester" };
}

test "the chain detects an edited entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(41, 1_788_000_000_000);
    var log = Log.init(arena, 42);
    const actor = testActor(&gen);
    const session = gen.next(idmod.SessionId);
    const at = try Timestamp.parseIso("2026-09-04T20:00:00Z");

    _ = try log.append(.{ .session_opened = .{ .session = session, .workingDirectory = "/home/user/zag" } }, .{ .at = at, .actor = actor });
    _ = try log.append(.{ .user_message = .{ .session = session, .text = "run the tests" } }, .{ .at = at.addNanos(timeutil.ns_per_s), .actor = actor });
    _ = try log.append(.{ .session_closed = .{ .session = session, .exitStatus = 0 } }, .{ .at = at.addNanos(2 * timeutil.ns_per_s), .actor = actor });

    try testing.expectEqual(@as(usize, 3), log.count());
    try testing.expect((try log.verify()) == null);

    // Editing history is detectable, which is the entire point.
    log.entries.items[1].payload = .{ .user_message = .{ .session = session, .text = "delete everything" } };
    const broken = (try log.verify()).?;
    try testing.expectEqual(@as(usize, 1), broken.index);
    try testing.expectEqual(Break.Reason.content_hash_mismatch, broken.reason);
}

test "the log survives a torn write" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(43, 1_788_000_000_000);
    var log = Log.init(arena, 44);
    const actor = testActor(&gen);
    const session = gen.next(idmod.SessionId);
    const at = try Timestamp.parseIso("2026-09-04T20:00:00Z");

    _ = try log.append(.{ .session_opened = .{ .session = session, .workingDirectory = "/tmp" } }, .{ .at = at, .actor = actor });
    _ = try log.append(.{ .user_message = .{ .session = session, .text = "hello" } }, .{ .at = at, .actor = actor });

    var aw: std.Io.Writer.Allocating = .init(arena);
    try log.writeJsonLines(&aw.writer);
    const complete = aw.written();

    const round = try Log.loadJsonLines(arena, complete, 44);
    try testing.expectEqual(@as(usize, 2), round.recovered);
    try testing.expectEqual(@as(usize, 2), round.entry_ends.len);
    try testing.expectEqual(complete.len, round.entry_ends[1]);
    try testing.expectEqual(@as(usize, 0), round.torn_bytes);
    try testing.expect((try round.log.verify()) == null);

    // Cut the file mid-entry, as a crash would.
    const torn_source = complete[0 .. complete.len - 20];
    const torn = try Log.loadJsonLines(arena, torn_source, 44);
    try testing.expectEqual(@as(usize, 1), torn.recovered);
    try testing.expectEqual(@as(usize, 1), torn.entry_ends.len);
    try testing.expect(torn.torn_bytes > 0);
    try testing.expect((try torn.log.verify()) == null);
}

test "every possible truncation recovers only complete event boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(49, 1_788_000_000_000);
    var log = Log.init(arena, 50);
    const actor = testActor(&gen);
    const session = gen.next(idmod.SessionId);
    const at = try Timestamp.parseIso("2026-09-04T20:00:00Z");
    _ = try log.append(.{ .session_opened = .{ .session = session, .workingDirectory = "/tmp" } }, .{ .at = at, .actor = actor });
    _ = try log.append(.{ .user_message = .{ .session = session, .text = "all cut points" } }, .{ .at = at, .actor = actor });

    var encoded: std.Io.Writer.Allocating = .init(arena);
    try log.writeJsonLines(&encoded.writer);
    const complete = encoded.written();
    for (0..complete.len + 1) |cut| {
        const loaded = try Log.loadJsonLines(arena, complete[0..cut], 50);
        try testing.expect((try loaded.log.verify()) == null);
        try testing.expectEqual(loaded.recovered, loaded.entry_ends.len);
        if (cut == 0 or complete[cut - 1] == '\n') {
            try testing.expectEqual(@as(usize, 0), loaded.torn_bytes);
        } else {
            try testing.expect(loaded.torn_bytes > 0);
        }
        for (loaded.entry_ends) |end| {
            try testing.expect(end <= cut);
            try testing.expect(complete[end - 1] == '\n');
        }
    }
}

test "a malformed complete line is corruption, not a torn write" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(47, 1_788_000_000_000);
    var log = Log.init(arena, 48);
    const actor = testActor(&gen);
    const session = gen.next(idmod.SessionId);
    const at = try Timestamp.parseIso("2026-09-04T20:00:00Z");

    _ = try log.append(.{ .session_opened = .{ .session = session, .workingDirectory = "/tmp" } }, .{ .at = at, .actor = actor });
    _ = try log.append(.{ .user_message = .{ .session = session, .text = "hello" } }, .{ .at = at, .actor = actor });

    var aw: std.Io.Writer.Allocating = .init(arena);
    try log.writeJsonLines(&aw.writer);
    const complete = aw.written();
    const first_end = std.mem.indexOfScalar(u8, complete, '\n').? + 1;
    const damaged = try std.fmt.allocPrint(arena, "{s}not an event\n{s}", .{
        complete[0..first_end],
        complete[first_end..],
    });

    const loaded = try Log.loadJsonLines(arena, damaged, 48);
    try testing.expectEqual(@as(usize, 1), loaded.recovered);
    try testing.expectEqual(@as(usize, 0), loaded.torn_bytes);
    try testing.expectEqual(@as(usize, 2), loaded.malformed.?.line);
    try testing.expectEqual(first_end, loaded.malformed.?.byte_offset);
}

test "an untrusted maximum sequence is rejected without overflowing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(51, 1_788_000_000_000);
    var log = Log.init(arena, 52);
    const actor = testActor(&gen);
    const session = gen.next(idmod.SessionId);
    const at = try Timestamp.parseIso("2026-09-04T20:00:00Z");
    _ = try log.append(.{ .session_opened = .{ .session = session, .workingDirectory = "/tmp" } }, .{ .at = at, .actor = actor });

    var encoded: std.Io.Writer.Allocating = .init(arena);
    try log.writeJsonLines(&encoded.writer);
    const hostile = try std.mem.replaceOwned(
        u8,
        arena,
        encoded.written(),
        "\"sequence\":1",
        "\"sequence\":18446744073709551615",
    );
    try testing.expect(!std.mem.eql(u8, hostile, encoded.written()));

    const loaded = try Log.loadJsonLines(arena, hostile, 52);
    const broken = (try loaded.log.verify()).?;
    try testing.expectEqual(Break.Reason.sequence_out_of_order, broken.reason);
}

test "replay rebuilds a projection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(45, 1_788_000_000_000);
    var log = Log.init(arena, 46);
    const actor = testActor(&gen);
    const session = gen.next(idmod.SessionId);
    const block = gen.next(idmod.BlockId);
    const at = try Timestamp.parseIso("2026-09-04T20:00:00Z");

    _ = try log.append(.{ .session_opened = .{ .session = session, .workingDirectory = "/tmp" } }, .{ .at = at, .actor = actor });
    _ = try log.append(.{ .command_submitted = .{ .block = block, .session = session, .commandText = "zig build test", .workingDirectory = "/tmp" } }, .{ .at = at, .actor = actor });
    _ = try log.append(.{ .command_finished = .{ .block = block, .session = session, .exitStatus = 0, .duration = timeutil.Duration.fromMillis(900) } }, .{ .at = at, .actor = actor });

    const Counter = struct {
        commands: usize = 0,
        failures: usize = 0,
        fn apply(self: *@This(), entry: Envelope) anyerror!void {
            switch (entry.payload) {
                .command_submitted => self.commands += 1,
                .command_finished => |e| {
                    if (e.exitStatus != 0) self.failures += 1;
                },
                else => {},
            }
        }
    };
    var counter: Counter = .{};
    try log.replay(&counter, Counter.apply);
    try testing.expectEqual(@as(usize, 1), counter.commands);
    try testing.expectEqual(@as(usize, 0), counter.failures);

    const in_session = try log.forSession(session);
    try testing.expectEqual(@as(usize, 3), in_session.items.len);
    try testing.expectEqual(@as(usize, 2), log.since(1).len);
}
