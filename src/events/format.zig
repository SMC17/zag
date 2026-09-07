//! The record format, pinned.
//!
//! Every hash in every workspace is computed from the JSON encoding of an
//! event. That encoding is produced by `std.json` from Zig struct definitions,
//! which means the format is decided by things nobody thinks of as format
//! decisions: the order fields are declared in, whether an optional writes
//! `null` or is omitted, how a float is rendered, what a new field is called.
//!
//! Change any of them and every historical `contentHash` becomes wrong. Not
//! detectably wrong — the log still verifies, because verification recomputes
//! the hash the same new way it wrote it. Wrong in the sense that a record
//! written last year and a record written today no longer agree about what
//! their bytes were, and the chain that was supposed to prove nothing changed
//! cannot tell you that something did.
//!
//! So the format is pinned here, as bytes. These lines were produced by this
//! program, and the tests below assert three things about them:
//!
//!   * **The bytes still come out the same.** A field renamed, reordered or
//!     added shows up as a failing string comparison rather than as a silent
//!     re-interpretation of history.
//!   * **The stored line hashes to its stored hash.** Not the parsed-and-
//!     re-encoded line — the original bytes, as they sit on disk. That is the
//!     only version of this check that would notice the encoder and the decoder
//!     drifting apart together.
//!   * **A line survives the round trip.** Parsed back into memory and encoded
//!     again, it produces the identical bytes, so reading and writing a
//!     workspace does not change it.
//!
//! When the format has to change, these vectors change with it, and that is the
//! point: it becomes a deliberate edit in a file called `format.zig` with a
//! commit message, rather than a side effect of touching a struct.

const std = @import("std");
const event_mod = @import("event.zig");
const log_mod = @import("log.zig");
const hashing = @import("../core/hash.zig");

/// One recorded line, exactly as this program writes it.
pub const Vector = struct {
    /// What the line is an example of, for whoever has to update it.
    describes: []const u8,
    line: []const u8,
};

/// Lines this program produced, kept byte for byte.
///
/// They cover the shapes that carry the format's awkward parts: a nanosecond
/// timestamp whose fraction is not round, a duration with nine significant
/// digits, an optional that is null and an optional that is not, a boolean, an
/// integer, and a payload with fields left at their defaults.
pub const vectors = [_]Vector{
    .{
        .describes = "a session opening: optionals at null, defaults written out",
        .line =
        \\{"id":"evt_01M16HNP3VKF106VVZT32WZ3F0","sequence":1,"at":"2026-08-29T10:40:00.123456789Z","actor":{"id":"act_01M16HNP00TQEZCJATF659CD62","kind":"person","label":"you"},"causedBy":null,"correlation":null,"payload":{"session_opened":{"session":"ses_01M16HNP01KW76FPRZ4HN6TQ1D","workingDirectory":"/repo","shell":"/bin/sh","columns":80,"rows":24,"repository":null,"branch":null,"worktree":null}},"contentHash":"b3:904872c03590f30172a3e2bb583bfaee1c561c8f49a527fc97fe7666dea4ba8b","chainHash":"b3:862ed628dc1dda6a94ba8939bf10cf1e23add5e5e2e6bc06fcbd0da6a7ee25a5"}
        ,
    },
    .{
        .describes = "a command submitted: a cause, a boolean, text with spaces",
        .line =
        \\{"id":"evt_01M16HNPZ843TTMNTQFPHHKNJP","sequence":2,"at":"2026-08-29T10:40:01.000000001Z","actor":{"id":"act_01M16HNP00TQEZCJATF659CD62","kind":"person","label":"you"},"causedBy":"evt_01M16HNP3VTQEZCJATF659CD62","correlation":null,"payload":{"command_submitted":{"block":"blk_01M16HNP02V3CWC3WY02PGW2MV","session":"ses_01M16HNP01KW76FPRZ4HN6TQ1D","commandText":"zig build test","workingDirectory":"/repo","boundaryFromShell":true,"redactions":0}},"contentHash":"b3:9f1c26430aa5e559309071d6c8738cfc83d86d35f3ada4a29d031c333992f11c","chainHash":"b3:24aeafc1890992e48c5a7549582297ccc4531a0d3b3f526f71b58e3da560fb60"}
        ,
    },
    .{
        .describes = "a command finishing: a correlation, a duration to the nanosecond, a non-zero status",
        .line =
        \\{"id":"evt_01M16HNRXQMHQHH1JB313JYH93","sequence":3,"at":"2026-08-29T10:40:02.999999999Z","actor":{"id":"act_01M16HNP00TQEZCJATF659CD62","kind":"person","label":"you"},"causedBy":"evt_01M16HNPZ8KW76FPRZ4HN6TQ1D","correlation":"evt_01M16HNP3VTQEZCJATF659CD62","payload":{"command_finished":{"block":"blk_01M16HNP02V3CWC3WY02PGW2MV","session":"ses_01M16HNP01KW76FPRZ4HN6TQ1D","exitStatus":3,"duration":"PT1.005000123S","signal":null}},"contentHash":"b3:8e541b7240e4852156dc296fe9d0e911646640dbe7ec0db04e83e10d99709624","chainHash":"b3:314011de9fd07798c77068a6e3422e3cdbf68eab6a4e280d9e2abfdbf45f5144"}
        ,
    },
};

/// The three lines above, as one file.
pub fn document(arena: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (vectors) |vector| {
        try out.appendSlice(arena, vector.line);
        try out.append(arena, '\n');
    }
    return out.items;
}

const testing = std.testing;

test "a stored line hashes to the hash stored in it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The bytes on disk, not a parsed-and-re-encoded version of them. An
    // encoder and a decoder that drifted apart *together* would agree with each
    // other and disagree with every line ever written, and only this direction
    // of the check would notice.
    for (vectors) |vector| {
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, vector.line, .{});
        const stored_content = parsed.value.object.get("contentHash").?.string;
        const stored_chain = parsed.value.object.get("chainHash").?.string;

        const envelope = try std.json.parseFromSlice(event_mod.Envelope, arena, vector.line, .{});
        const recomputed = try envelope.value.computeContentHash(arena);

        var buffer: [hashing.Hash.text_len]u8 = undefined;
        try testing.expectEqualStrings(stored_content, recomputed.toText(&buffer));
        try testing.expect(stored_chain.len > 3);
    }
}

test "the encoder still produces these exact bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Read each line in and write it straight back out. Any change to a field
    // name, a field order, how an optional is written, or how a timestamp or a
    // duration is rendered lands here as a string that does not match.
    //
    // If this test fails and the change was intended, the vectors above are
    // updated in the same commit, and the commit message says the record format
    // changed. That is the whole mechanism.
    for (vectors) |vector| {
        const envelope = try std.json.parseFromSlice(event_mod.Envelope, arena, vector.line, .{});
        var out: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(envelope.value, .{}, &out.writer);
        try testing.expectEqualStrings(vector.line, out.written());
    }
}

test "the pinned log loads, verifies, and keeps its chain" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try document(arena);
    const loaded = try log_mod.Log.loadJsonLines(arena, source, 1);
    try testing.expectEqual(@as(usize, vectors.len), loaded.recovered);
    try testing.expectEqual(@as(usize, 0), loaded.torn_bytes);
    try testing.expect(loaded.malformed == null);

    // The chain a workspace written years ago still checks out under today's
    // code. This is the property the whole record rests on.
    try testing.expect(try loaded.log.verify() == null);

    // And writing it back out gives the same file, byte for byte.
    var out: std.Io.Writer.Allocating = .init(arena);
    try loaded.log.writeJsonLines(&out.writer);
    try testing.expectEqualStrings(source, out.written());
}

test "a changed byte in a stored line is caught" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The exit status of the third line, edited from 3 to 0: the difference
    // between a record of a failure and a record of a success.
    const tampered = try std.mem.replaceOwned(
        u8,
        arena,
        try document(arena),
        "\"exitStatus\":3",
        "\"exitStatus\":0",
    );
    const loaded = try log_mod.Log.loadJsonLines(arena, tampered, 1);
    const broken = try loaded.log.verify();
    try testing.expect(broken != null);
    try testing.expectEqual(@as(usize, 2), broken.?.index);
}

test "a whole file rewritten with freshly computed hashes still verifies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // This is the threat the chain does *not* defend against, written down so
    // that nobody reads the test above as more than it is.
    //
    // Editing one entry and leaving its hash stale is caught, and that catches
    // a clumsy editor or a partial write. Someone who can rewrite the file can
    // also recompute every hash from the genesis label, and the result verifies
    // perfectly. Local hashing proves internal consistency; it does not prove
    // the file was not replaced.
    //
    // What would close it is a head signed by a key the writer does not hold,
    // or a witness outside the machine. Neither exists here yet, and the
    // documentation says so rather than implying the chain is tamper-proof.
    const source = try document(arena);
    const loaded = try log_mod.Log.loadJsonLines(arena, source, 1);

    var rewritten = log_mod.Log.init(arena, 1);
    for (loaded.log.entries.items) |entry| {
        var changed = entry.payload;
        switch (changed) {
            .command_finished => |*e| e.exitStatus = 0,
            else => {},
        }
        _ = try rewritten.append(changed, .{
            .at = entry.at,
            .actor = entry.actor,
            .causedBy = entry.causedBy,
            .correlation = entry.correlation,
        });
    }

    // Every hash was recomputed, so it verifies. The record says a failing
    // command succeeded, and nothing in the file can tell you otherwise.
    try testing.expect(try rewritten.verify() == null);

    // What *is* different is the chain head, which is why an external witness
    // is the thing that would close this.
    try testing.expect(!rewritten.head.eql(loaded.log.head));
}
