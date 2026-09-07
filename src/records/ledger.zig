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
//!
//! ## Why entries, and not records with fields that change
//!
//! "Append-only" used to be a sentence in this comment rather than a property
//! of the code. A record was a struct, and placing a hold, releasing it, or
//! disposing of the record wrote straight into that struct's fields. None of
//! those fields were in the hash, and no entry marked the change, so the one
//! thing the ledger exists to prove — that nobody quietly altered a record —
//! was exactly the thing it did not do. A hold could be lifted and a record
//! destroyed with no trace of either.
//!
//! So the ledger holds *entries*, and every entry is immutable and chained.
//! Sealing a record is an entry. Placing a hold is another entry, about that
//! record. Releasing it, superseding it and disposing of it are entries too.
//! What a record *is* right now is folded from its entries, the same way a
//! block is folded from the event log, and there is nowhere to write except the
//! end.
//!
//! The cost is that a record's current state has to be computed rather than
//! read. That is the right cost: it means there is no copy of the state to fall
//! out of step with the entries that produced it.

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

/// One thing that happened to a record.
///
/// Every one of these is immutable once written and chained to the one before
/// it. A record's state is folded from the entries about it.
pub const Change = union(enum) {
    /// The record was created.
    sealed: Sealed,
    /// A hold was placed on it.
    held: LegalHold,
    /// The hold was lifted.
    hold_released: struct { by: idmod.ActorId },
    /// A later record replaced it.
    superseded: struct { by: idmod.RecordId },
    /// It was disposed of.
    disposed: struct { method: Disposition, witness: idmod.ActorId },

    pub const Sealed = struct {
        title: []const u8,
        classification: Classification,
        retention: RetentionClass,
        content_hash: Hash,
        provenance: ?provenance_mod.Provenance = null,
        supersedes: ?idmod.RecordId = null,
    };

    pub fn name(self: Change) []const u8 {
        return @tagName(self);
    }
};

pub const Entry = struct {
    /// The record this entry is about.
    record: idmod.RecordId,
    at: Timestamp,
    by: idmod.ActorId,
    change: Change,
    /// Hash of this entry's own content.
    content_hash: Hash,
    /// Hash chaining it to the entry before.
    chain_hash: Hash,
};

pub const Ledger = struct {
    arena: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
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

    /// The bytes an entry is hashed over.
    ///
    /// Everything that says what happened goes in: which record, when, who, and
    /// the whole of the change. An entry whose hold reason was edited hashes
    /// differently, which is the property the old shape lacked.
    fn contentOf(entry_record: idmod.RecordId, at: Timestamp, by: idmod.ActorId, change: Change) Hash {
        var time_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &time_buf, @bitCast(at.ns), .little);

        var parts: [12][]const u8 = undefined;
        var used: usize = 0;
        parts[used] = &entry_record.raw.bytes;
        used += 1;
        parts[used] = &time_buf;
        used += 1;
        parts[used] = &by.raw.bytes;
        used += 1;
        parts[used] = change.name();
        used += 1;
        switch (change) {
            .sealed => |e| {
                parts[used] = e.title;
                used += 1;
                parts[used] = @tagName(e.classification);
                used += 1;
                parts[used] = e.retention.id;
                used += 1;
                parts[used] = &e.content_hash.bytes;
                used += 1;
            },
            .held => |hold| {
                parts[used] = hold.id;
                used += 1;
                parts[used] = hold.reason;
                used += 1;
                parts[used] = &hold.placed_by.raw.bytes;
                used += 1;
            },
            .hold_released => |e| {
                parts[used] = &e.by.raw.bytes;
                used += 1;
            },
            .superseded => |e| {
                parts[used] = &e.by.raw.bytes;
                used += 1;
            },
            .disposed => |e| {
                parts[used] = @tagName(e.method);
                used += 1;
                parts[used] = &e.witness.raw.bytes;
                used += 1;
            },
        }
        return Hash.ofParts(parts[0..used]);
    }

    /// Append one entry. The only way anything enters this ledger.
    fn append(
        self: *Ledger,
        entry_record: idmod.RecordId,
        at: Timestamp,
        by: idmod.ActorId,
        change: Change,
    ) !Entry {
        const content = contentOf(entry_record, at, by, change);
        const entry: Entry = .{
            .record = entry_record,
            .at = at,
            .by = by,
            .change = change,
            .content_hash = content,
            .chain_hash = Hash.chain(self.head, content),
        };
        self.head = entry.chain_hash;
        try self.entries.append(self.arena, entry);
        return entry;
    }

    /// Write a record. Once sealed, nothing about it can be changed: a later
    /// fact about it is a later entry.
    pub fn seal(self: *Ledger, options: SealOptions) !Record {
        self.ids.clock_ms = @divFloor(options.created_at.ns, timeutil.ns_per_ms);
        const retention = options.retention orelse options.classification.defaultRetention();
        const id = self.ids.next(idmod.RecordId);

        _ = try self.append(id, options.created_at, options.created_by, .{ .sealed = .{
            .title = options.title,
            .classification = options.classification,
            .retention = retention,
            .content_hash = options.content_hash,
            .provenance = options.provenance,
            .supersedes = options.supersedes,
        } });

        if (options.supersedes) |older| {
            _ = try self.append(older, options.created_at, options.created_by, .{
                .superseded = .{ .by = id },
            });
        }
        return self.find(id).?;
    }

    /// What a record is now, folded from every entry about it.
    ///
    /// Returns null when no entry has sealed that identifier.
    pub fn find(self: Ledger, id: idmod.RecordId) ?Record {
        var record: ?Record = null;
        for (self.entries.items) |entry| {
            if (!entry.record.eql(id)) continue;
            switch (entry.change) {
                .sealed => |e| record = .{
                    .id = id,
                    .title = e.title,
                    .classification = e.classification,
                    .retention = e.retention,
                    .created_at = entry.at,
                    .created_by = entry.by,
                    .content_hash = e.content_hash,
                    .chain_hash = entry.chain_hash,
                    .provenance = e.provenance,
                    .supersedes = e.supersedes,
                },
                .held => |hold| {
                    if (record) |*r| r.hold = hold;
                },
                .hold_released => |e| {
                    if (record) |*r| {
                        if (r.hold) |*hold| {
                            hold.released_at = entry.at;
                            hold.released_by = e.by;
                        }
                    }
                },
                .superseded => |e| {
                    if (record) |*r| r.superseded_by = e.by;
                },
                .disposed => |e| {
                    if (record) |*r| {
                        r.disposed_at = entry.at;
                        r.disposal_method = e.method;
                        r.disposal_witness = e.witness;
                    }
                },
            }
        }
        return record;
    }

    /// Every record, folded, in the order they were sealed.
    pub fn all(self: Ledger) !std.ArrayList(Record) {
        var out: std.ArrayList(Record) = .empty;
        for (self.entries.items) |entry| {
            if (entry.change != .sealed) continue;
            if (self.find(entry.record)) |record| try out.append(self.arena, record);
        }
        return out;
    }

    /// How many records the ledger holds. Entries are counted by `entryCount`.
    pub fn count(self: Ledger) usize {
        var total: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.change == .sealed) total += 1;
        }
        return total;
    }

    pub fn entryCount(self: Ledger) usize {
        return self.entries.items.len;
    }

    /// Put a hold on a record. While the hold is active the record cannot be
    /// disposed of, whatever its retention period says.
    pub fn placeHold(self: *Ledger, id: idmod.RecordId, hold: LegalHold) Error!void {
        _ = self.find(id) orelse return error.UnknownRecord;
        _ = try self.append(id, hold.placed_at, hold.placed_by, .{ .held = hold });
    }

    pub fn releaseHold(self: *Ledger, id: idmod.RecordId, by: idmod.ActorId, at: Timestamp) Error!void {
        _ = self.find(id) orelse return error.UnknownRecord;
        _ = try self.append(id, at, by, .{ .hold_released = .{ .by = by } });
    }

    /// Dispose of a record, recording that it happened.
    pub fn dispose(self: *Ledger, id: idmod.RecordId, witness: idmod.ActorId, at: Timestamp) Error!Record {
        const record = self.find(id) orelse return error.UnknownRecord;
        if (record.disposed_at != null) return error.AlreadyDisposed;
        if (record.hold) |hold| {
            if (hold.isActive(at)) return error.UnderLegalHold;
        }
        if (at.ns < record.dueAt().ns) return error.NotYetDue;

        _ = try self.append(id, at, witness, .{ .disposed = .{
            .method = record.retention.disposition,
            .witness = witness,
        } });

        // The disposal is also its own record, so the ledger can show that the
        // record existed and was destroyed on purpose even after the thing it
        // pointed at is gone.
        var id_buf: [idmod.RecordId.text_len]u8 = undefined;
        _ = try self.seal(.{
            .title = try std.fmt.allocPrint(self.arena, "Disposed of record {s} by {s}", .{
                record.id.toText(&id_buf),
                @tagName(record.retention.disposition),
            }),
            .classification = .decision,
            .content_hash = record.content_hash,
            .created_by = witness,
            .created_at = at,
        });
        return self.find(id).?;
    }

    pub fn dueFor(self: Ledger, now: Timestamp) !std.ArrayList(Record) {
        return self.inState(.due, now);
    }

    pub fn onHold(self: Ledger, now: Timestamp) !std.ArrayList(Record) {
        return self.inState(.on_hold, now);
    }

    fn inState(self: Ledger, wanted: State, now: Timestamp) !std.ArrayList(Record) {
        var out: std.ArrayList(Record) = .empty;
        const records = try self.all();
        for (records.items) |record| {
            if (record.state(now) == wanted) try out.append(self.arena, record);
        }
        return out;
    }

    /// Re-derive the chain. Returns the index of the first entry that does not
    /// match, or null when the ledger is intact.
    ///
    /// Every entry is covered, not only the sealings. A hold placed and quietly
    /// lifted, or a disposal with the witness changed, shows up here — which it
    /// could not when a hold was a field somebody wrote into a struct.
    pub fn verify(self: Ledger) ?usize {
        var chain = Hash.of(genesis_label);
        for (self.entries.items, 0..) |entry, index| {
            const content = contentOf(entry.record, entry.at, entry.by, entry.change);
            if (!content.eql(entry.content_hash)) return index;
            const expected = Hash.chain(chain, content);
            if (!expected.eql(entry.chain_hash)) return index;
            chain = entry.chain_hash;
        }
        return null;
    }

    /// The disposition schedule a person reviews.
    pub fn writeSchedule(self: Ledger, w: *std.Io.Writer, now: Timestamp) !void {
        try w.writeAll("Records and what happens to them\n\n");
        const records = try self.all();
        for (records.items) |record| {
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

    /// Everything that happened to one record, in order.
    ///
    /// This is what an auditor asks for: not the record's current state, but
    /// how it got there and who did each part.
    pub fn historyOf(self: Ledger, id: idmod.RecordId) !std.ArrayList(Entry) {
        var out: std.ArrayList(Entry) = .empty;
        for (self.entries.items) |entry| {
            if (entry.record.eql(id)) try out.append(self.arena, entry);
        }
        return out;
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

    // Editing what a sealed entry says is caught, wherever in the chain it is.
    ledger.entries.items[0].change.sealed.title = "Agent 4 was allowed to do anything.";
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

test "a hold and a disposal are entries, and editing either is caught" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(601, 1_788_000_000_000);
    var ledger = Ledger.init(arena, 602);
    const keeper = gen.next(idmod.ActorId);
    const lawyer = gen.next(idmod.ActorId);
    const created = try Timestamp.parseIso("2026-01-01T00:00:00Z");
    const later = created.addNanos(timeutil.ns_per_day * 200);

    const record = try ledger.seal(.{
        .title = "Command output from the incident.",
        .classification = .operational,
        .content_hash = Hash.of("output"),
        .created_by = keeper,
        .created_at = created,
    });

    // Placing a hold adds an entry. It used to write into a field that no hash
    // covered, so a hold could be placed and lifted with no trace of either.
    const before_hold = ledger.entryCount();
    try ledger.placeHold(record.id, .{
        .id = "H-1",
        .reason = "Kept for the review of the 4 September incident.",
        .placed_by = lawyer,
        .placed_at = created,
    });
    try testing.expectEqual(before_hold + 1, ledger.entryCount());
    try testing.expect(ledger.verify() == null);
    try testing.expectEqual(State.on_hold, ledger.find(record.id).?.state(later));

    // Editing the reason on a written entry breaks the chain at that entry.
    const at_hold = ledger.entryCount() - 1;
    const kept = ledger.entries.items[at_hold].change.held.reason;
    ledger.entries.items[at_hold].change.held.reason = "Routine.";
    try testing.expectEqual(at_hold, ledger.verify().?);
    ledger.entries.items[at_hold].change.held.reason = kept;
    try testing.expect(ledger.verify() == null);

    // Releasing and disposing are entries too, and the record's history reads
    // as the sequence of things that happened to it.
    try ledger.releaseHold(record.id, lawyer, later);
    const disposed = try ledger.dispose(record.id, keeper, later.addNanos(timeutil.ns_per_s));
    try testing.expect(disposed.disposed_at != null);
    try testing.expectEqual(Disposition.delete, disposed.disposal_method.?);
    try testing.expect(ledger.verify() == null);

    const history = try ledger.historyOf(record.id);
    try testing.expectEqual(@as(usize, 4), history.items.len);
    try testing.expect(history.items[0].change == .sealed);
    try testing.expect(history.items[1].change == .held);
    try testing.expect(history.items[2].change == .hold_released);
    try testing.expect(history.items[3].change == .disposed);

    // And who did each part is on the entry, not inferred.
    try testing.expect(history.items[1].by.eql(lawyer));
    try testing.expect(history.items[3].by.eql(keeper));
}

test "a disposal cannot be quietly removed from the record" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(603, 1_788_000_000_000);
    var ledger = Ledger.init(arena, 604);
    const keeper = gen.next(idmod.ActorId);
    const created = try Timestamp.parseIso("2026-01-01T00:00:00Z");
    const due = created.addNanos(timeutil.ns_per_day * 200);

    const record = try ledger.seal(.{
        .title = "Output nobody wants found.",
        .classification = .operational,
        .content_hash = Hash.of("output"),
        .created_by = keeper,
        .created_at = created,
    });
    _ = try ledger.dispose(record.id, keeper, due);
    try testing.expect(ledger.verify() == null);

    // Changing the witness on the disposal entry is caught. Under the old
    // shape the witness was a field on the record, covered by no hash, so this
    // was a silent edit.
    var at: usize = 0;
    for (ledger.entries.items, 0..) |entry, index| {
        if (entry.change == .disposed) at = index;
    }
    ledger.entries.items[at].change.disposed.witness = gen.next(idmod.ActorId);
    try testing.expectEqual(at, ledger.verify().?);
}

test "the state a record is in is folded, never stored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(605, 1_788_000_000_000);
    var ledger = Ledger.init(arena, 606);
    const keeper = gen.next(idmod.ActorId);
    const created = try Timestamp.parseIso("2026-01-01T00:00:00Z");

    const record = try ledger.seal(.{
        .title = "A decision.",
        .classification = .decision,
        .content_hash = Hash.of("decision"),
        .created_by = keeper,
        .created_at = created,
    });

    // The same record, asked about at three moments, answers three ways —
    // without anything having been written in between. There is no stored
    // state to fall out of step with the entries.
    try testing.expectEqual(State.active, ledger.find(record.id).?.state(created));
    try testing.expectEqual(
        State.active,
        ledger.find(record.id).?.state(created.addNanos(timeutil.ns_per_day * 365)),
    );
    try testing.expectEqual(
        State.due,
        ledger.find(record.id).?.state(created.addNanos(timeutil.ns_per_day * 365 * 8)),
    );

    // An identifier nobody sealed is not a record, rather than an empty one.
    try testing.expect(ledger.find(gen.next(idmod.RecordId)) == null);
}
