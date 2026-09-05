//! Records management (ISO 15489).
//!
//! Operational state and records are different things. The workspace may say
//! "agent 4 is running". The record ledger says: at this instant, this actor
//! asked for this capability, policy P23 required approval, this person allowed
//! it once, and here is the hash of what was written.
//!
//! Records here are append-only, hash-chained, classified, retained under a
//! stated rule, and disposed of only with evidence. A record under legal hold
//! cannot be disposed of at all, which is the property that makes the ledger
//! worth keeping.

const std = @import("std");
const idmod = @import("../core/id.zig");
const hashing = @import("../core/hash.zig");
const timeutil = @import("../core/time.zig");
const provenance_mod = @import("../data/provenance.zig");

pub const Timestamp = timeutil.Timestamp;
pub const Hash = hashing.Hash;

/// What kind of thing the record is evidence of. Classification drives
/// retention, so it is not decoration.
pub const Classification = enum {
    /// Routine activity: a command ran, a file was read.
    operational,
    /// A decision was taken, by a person or by policy.
    decision,
    /// Evidence that a requirement was met.
    conformance,
    /// An agreement or a permission that was granted.
    authorisation,
    /// Something involving personal data.
    personal,
    /// A security-relevant event.
    security,

    pub fn defaultRetention(self: Classification) RetentionClass {
        return switch (self) {
            .operational => .{
                .id = "R-OPS-90D",
                .description = "Routine activity, kept long enough to investigate a problem.",
                .duration = timeutil.Duration.fromDays(90),
                .disposition = .delete,
                .authority = "workspace default",
            },
            .decision => .{
                .id = "R-DECISION-7Y",
                .description = "Decisions, kept so that what was decided and by whom can be established later.",
                .duration = timeutil.Duration.fromDays(365 * 7),
                .disposition = .review,
                .authority = "workspace default",
            },
            .conformance => .{
                .id = "R-CONFORMANCE-7Y",
                .description = "Evidence of conformance, kept for the life of the claim plus a review period.",
                .duration = timeutil.Duration.fromDays(365 * 7),
                .disposition = .review,
                .authority = "workspace default",
            },
            .authorisation => .{
                .id = "R-AUTH-7Y",
                .description = "Permissions granted and withdrawn.",
                .duration = timeutil.Duration.fromDays(365 * 7),
                .disposition = .review,
                .authority = "workspace default",
            },
            .personal => .{
                .id = "R-PERSONAL-1Y",
                .description = "Records containing personal data, kept no longer than the purpose needs.",
                .duration = timeutil.Duration.fromDays(365),
                .disposition = .delete,
                .authority = "workspace default",
            },
            .security => .{
                .id = "R-SECURITY-2Y",
                .description = "Security-relevant events, kept for investigation.",
                .duration = timeutil.Duration.fromDays(365 * 2),
                .disposition = .review,
                .authority = "workspace default",
            },
        };
    }
};

pub const Disposition = enum {
    /// Destroy it.
    delete,
    /// Remove what identifies a person, keep the rest.
    anonymise,
    /// Move it to long-term storage.
    archive,
    /// A person decides at the time.
    review,
    /// Hand it to another organisation and record that.
    transfer,
};

pub const RetentionClass = struct {
    id: []const u8,
    description: []const u8,
    duration: timeutil.Duration,
    disposition: Disposition,
    /// What says this is the right period: a policy, a contract, a law.
    authority: []const u8,
};

pub const LegalHold = struct {
    id: []const u8,
    reason: []const u8,
    placed_by: idmod.ActorId,
    placed_at: Timestamp,
    released_at: ?Timestamp = null,
    released_by: ?idmod.ActorId = null,

    pub fn isActive(self: LegalHold, now: Timestamp) bool {
        if (self.released_at) |released| return now.ns < released.ns;
        return true;
    }
};

pub const State = enum {
    /// In force, within its retention period.
    active,
    /// Past its retention period, waiting for its disposition.
    due,
    /// Kept regardless of retention because of a hold.
    on_hold,
    /// Disposed of, with the disposal itself recorded.
    disposed,
    /// Superseded by a later record, still kept.
    superseded,
};

pub const Record = struct {
    id: idmod.RecordId,
    /// One line naming what this is evidence of.
    title: []const u8,
    classification: Classification,
    retention: RetentionClass,
    created_at: Timestamp,
    created_by: idmod.ActorId,
    /// Hash of the content this record attests to.
    content_hash: Hash,
    /// Hash chaining this record to the one before it.
    chain_hash: Hash,
    provenance: ?provenance_mod.Provenance = null,
    /// The record this one replaces.
    supersedes: ?idmod.RecordId = null,
    superseded_by: ?idmod.RecordId = null,
    hold: ?LegalHold = null,
    disposed_at: ?Timestamp = null,
    disposal_method: ?Disposition = null,
    disposal_witness: ?idmod.ActorId = null,

    pub fn dueAt(self: Record) Timestamp {
        return self.created_at.addNanos(self.retention.duration.ns);
    }

    pub fn state(self: Record, now: Timestamp) State {
        if (self.disposed_at != null) return .disposed;
        if (self.hold) |hold| {
            if (hold.isActive(now)) return .on_hold;
        }
        if (self.superseded_by != null) return .superseded;
        if (now.ns >= self.dueAt().ns) return .due;
        return .active;
    }

    pub fn canDispose(self: Record, now: Timestamp) bool {
        if (self.disposed_at != null) return false;
        if (self.hold) |hold| {
            if (hold.isActive(now)) return false;
        }
        return now.ns >= self.dueAt().ns;
    }
};

pub const Error = error{
    UnknownRecord,
    UnderLegalHold,
    NotYetDue,
    AlreadyDisposed,
    OutOfMemory,
};

pub const genesis_label = "zag.record-ledger.v1";

pub const Ledger = struct {
    arena: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    head: Hash,
    ids: idmod.Generator,

    pub fn init(arena: std.mem.Allocator, seed: u64) Ledger {
        return .{ .arena = arena, .head = Hash.of(genesis_label), .ids = idmod.Generator.init(seed, 0) };
    }

    pub const SealOptions = struct {
        title: []const u8,
        classification: Classification,
        content_hash: Hash,
        created_by: idmod.ActorId,
        created_at: Timestamp,
        retention: ?RetentionClass = null,
        provenance: ?provenance_mod.Provenance = null,
        supersedes: ?idmod.RecordId = null,
    };

    /// Write a record. Once sealed, its content hash and its place in the chain
    /// cannot change without the chain showing it.
    pub fn seal(self: *Ledger, options: SealOptions) !Record {
        self.ids.clock_ms = @divFloor(options.created_at.ns, timeutil.ns_per_ms);
        const retention = options.retention orelse options.classification.defaultRetention();

        var title_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &title_buf, @bitCast(options.created_at.ns), .little);
        const content = Hash.ofParts(&.{
            options.title,
            @tagName(options.classification),
            retention.id,
            &options.content_hash.bytes,
            &title_buf,
        });

        const record: Record = .{
            .id = self.ids.next(idmod.RecordId),
            .title = options.title,
            .classification = options.classification,
            .retention = retention,
            .created_at = options.created_at,
            .created_by = options.created_by,
            .content_hash = options.content_hash,
            .chain_hash = Hash.chain(self.head, content),
            .provenance = options.provenance,
            .supersedes = options.supersedes,
        };
        self.head = record.chain_hash;
        try self.records.append(self.arena, record);

        if (options.supersedes) |older_id| {
            if (self.find(older_id)) |older| older.superseded_by = record.id;
        }
        return record;
    }

    pub fn find(self: *Ledger, id: idmod.RecordId) ?*Record {
        for (self.records.items) |*record| {
            if (record.id.eql(id)) return record;
        }
        return null;
    }

    pub fn count(self: Ledger) usize {
        return self.records.items.len;
    }

    /// Put a hold on a record. While the hold is active the record cannot be
    /// disposed of, whatever its retention period says.
    pub fn placeHold(self: *Ledger, id: idmod.RecordId, hold: LegalHold) Error!void {
        const record = self.find(id) orelse return error.UnknownRecord;
        record.hold = hold;
    }

    pub fn releaseHold(self: *Ledger, id: idmod.RecordId, by: idmod.ActorId, at: Timestamp) Error!void {
        const record = self.find(id) orelse return error.UnknownRecord;
        if (record.hold) |*hold| {
            hold.released_at = at;
            hold.released_by = by;
        }
    }

    /// Dispose of a record, recording that it happened.
    pub fn dispose(self: *Ledger, id: idmod.RecordId, witness: idmod.ActorId, at: Timestamp) Error!Record {
        const record = self.find(id) orelse return error.UnknownRecord;
        if (record.disposed_at != null) return error.AlreadyDisposed;
        if (record.hold) |hold| {
            if (hold.isActive(at)) return error.UnderLegalHold;
        }
        if (at.ns < record.dueAt().ns) return error.NotYetDue;

        record.disposed_at = at;
        record.disposal_method = record.retention.disposition;
        record.disposal_witness = witness;

        // The disposal is itself a record, so the ledger can show that the
        // record existed and was destroyed on purpose.
        var id_buf: [idmod.RecordId.text_len]u8 = undefined;
        _ = try self.seal(.{
            .title = try std.fmt.allocPrint(self.arena, "Disposed of record {s} by {s}", .{ record.id.toText(&id_buf), @tagName(record.retention.disposition) }),
            .classification = .decision,
            .content_hash = record.content_hash,
            .created_by = witness,
            .created_at = at,
        });
        return record.*;
    }

    pub fn dueFor(self: Ledger, now: Timestamp) !std.ArrayList(Record) {
        var out: std.ArrayList(Record) = .empty;
        for (self.records.items) |record| {
            if (record.state(now) == .due) try out.append(self.arena, record);
        }
        return out;
    }

    pub fn onHold(self: Ledger, now: Timestamp) !std.ArrayList(Record) {
        var out: std.ArrayList(Record) = .empty;
        for (self.records.items) |record| {
            if (record.state(now) == .on_hold) try out.append(self.arena, record);
        }
        return out;
    }

    /// Re-derive the chain. Returns the index of the first record that does not
    /// match, or null when the ledger is intact.
    pub fn verify(self: Ledger) ?usize {
        var chain = Hash.of(genesis_label);
        for (self.records.items, 0..) |record, index| {
            var time_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &time_buf, @bitCast(record.created_at.ns), .little);
            const content = Hash.ofParts(&.{
                record.title,
                @tagName(record.classification),
                record.retention.id,
                &record.content_hash.bytes,
                &time_buf,
            });
            const expected = Hash.chain(chain, content);
            if (!expected.eql(record.chain_hash)) return index;
            chain = record.chain_hash;
        }
        return null;
    }

    /// The disposition schedule a person reviews.
    pub fn writeSchedule(self: Ledger, w: *std.Io.Writer, now: Timestamp) !void {
        try w.writeAll("Records and what happens to them\n\n");
        for (self.records.items) |record| {
            var id_buf: [idmod.RecordId.text_len]u8 = undefined;
            var due_buf: [Timestamp.text_len_max]u8 = undefined;
            try w.print("{s}  {s}\n", .{ record.id.toText(&id_buf), record.title });
            try w.print("    {s}, kept until {s} then {s} ({s})\n", .{
                @tagName(record.classification),
                record.dueAt().toIso(&due_buf, .second),
                @tagName(record.retention.disposition),
                record.retention.authority,
            });
            const current = record.state(now);
            try w.print("    Now: {s}", .{@tagName(current)});
            if (current == .on_hold) {
                try w.print(" ({s})", .{record.hold.?.reason});
            }
            try w.writeAll("\n");
        }
    }
};

const testing = std.testing;

test "records are chained, and an edit is detectable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(501, 1_788_000_000_000);
    var ledger = Ledger.init(arena, 502);
    const actor = gen.next(idmod.ActorId);
    const at = try Timestamp.parseIso("2026-09-04T20:41:31Z");

    _ = try ledger.seal(.{
        .title = "Agent 4 asked for network access; policy P23 required approval; Sean allowed it once.",
        .classification = .authorisation,
        .content_hash = Hash.of("approval"),
        .created_by = actor,
        .created_at = at,
    });
    _ = try ledger.seal(.{
        .title = "Agent 4 connected to api.example.test.",
        .classification = .security,
        .content_hash = Hash.of("connection"),
        .created_by = actor,
        .created_at = at.addNanos(timeutil.ns_per_s),
    });

    try testing.expectEqual(@as(usize, 2), ledger.count());
    try testing.expect(ledger.verify() == null);

    ledger.records.items[0].title = "Agent 4 was allowed to do anything.";
    try testing.expectEqual(@as(usize, 0), ledger.verify().?);
}

test "a record under legal hold cannot be disposed of" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(503, 1_788_000_000_000);
    var ledger = Ledger.init(arena, 504);
    const actor = gen.next(idmod.ActorId);
    const lawyer = gen.next(idmod.ActorId);
    const created = try Timestamp.parseIso("2026-01-01T00:00:00Z");

    const record = try ledger.seal(.{
        .title = "Command output from the incident.",
        .classification = .operational,
        .content_hash = Hash.of("output"),
        .created_by = actor,
        .created_at = created,
    });

    const long_after = created.addNanos(timeutil.ns_per_day * 200);
    try testing.expect(record.canDispose(long_after));

    try ledger.placeHold(record.id, .{
        .id = "H-1",
        .reason = "Kept for the review of the 4 September incident.",
        .placed_by = lawyer,
        .placed_at = created,
    });
    try testing.expectEqual(State.on_hold, ledger.find(record.id).?.state(long_after));
    try testing.expectError(error.UnderLegalHold, ledger.dispose(record.id, actor, long_after));

    try ledger.releaseHold(record.id, lawyer, long_after);
    const disposed = try ledger.dispose(record.id, actor, long_after.addNanos(timeutil.ns_per_s));
    try testing.expect(disposed.disposed_at != null);
    try testing.expectEqual(Disposition.delete, disposed.disposal_method.?);

    // Disposal is itself recorded, and the ledger still verifies.
    try testing.expectEqual(@as(usize, 2), ledger.count());
    try testing.expect(ledger.verify() == null);
}

test "a record cannot be disposed of before its time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(505, 1_788_000_000_000);
    var ledger = Ledger.init(arena, 506);
    const actor = gen.next(idmod.ActorId);
    const created = try Timestamp.parseIso("2026-09-04T00:00:00Z");

    const record = try ledger.seal(.{
        .title = "Decision to allow pushing from this workspace.",
        .classification = .decision,
        .content_hash = Hash.of("decision"),
        .created_by = actor,
        .created_at = created,
    });
    try testing.expectError(error.NotYetDue, ledger.dispose(record.id, actor, created.addNanos(timeutil.ns_per_day)));
    try testing.expectEqual(State.active, record.state(created.addNanos(timeutil.ns_per_day)));
}

test "superseding a record keeps both" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(507, 1_788_000_000_000);
    var ledger = Ledger.init(arena, 508);
    const actor = gen.next(idmod.ActorId);
    const at = try Timestamp.parseIso("2026-09-04T00:00:00Z");

    const first = try ledger.seal(.{
        .title = "Policy: the agent may push.",
        .classification = .authorisation,
        .content_hash = Hash.of("v1"),
        .created_by = actor,
        .created_at = at,
    });
    const second = try ledger.seal(.{
        .title = "Policy: the agent may not push.",
        .classification = .authorisation,
        .content_hash = Hash.of("v2"),
        .created_by = actor,
        .created_at = at.addNanos(timeutil.ns_per_day),
        .supersedes = first.id,
    });

    try testing.expect(ledger.find(first.id).?.superseded_by.?.eql(second.id));
    try testing.expectEqual(State.superseded, ledger.find(first.id).?.state(at.addNanos(timeutil.ns_per_day)));
    try testing.expect(ledger.verify() == null);
}

test "the schedule shows what is due and what is held" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(509, 1_788_000_000_000);
    var ledger = Ledger.init(arena, 510);
    const actor = gen.next(idmod.ActorId);
    const created = try Timestamp.parseIso("2026-01-01T00:00:00Z");
    const now = created.addNanos(timeutil.ns_per_day * 120);

    const routine = try ledger.seal(.{
        .title = "Ran zig build test.",
        .classification = .operational,
        .content_hash = Hash.of("run"),
        .created_by = actor,
        .created_at = created,
    });
    const held = try ledger.seal(.{
        .title = "Output of the failing run.",
        .classification = .operational,
        .content_hash = Hash.of("failure"),
        .created_by = actor,
        .created_at = created,
    });
    try ledger.placeHold(held.id, .{
        .id = "H-2",
        .reason = "Needed for the incident review.",
        .placed_by = actor,
        .placed_at = created,
    });

    const due = try ledger.dueFor(now);
    try testing.expectEqual(@as(usize, 1), due.items.len);
    try testing.expect(due.items[0].id.eql(routine.id));

    const holds = try ledger.onHold(now);
    try testing.expectEqual(@as(usize, 1), holds.items.len);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try ledger.writeSchedule(&aw.writer, now);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "Now: due") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Needed for the incident review.") != null);
}
