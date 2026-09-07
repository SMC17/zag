//! Byte scans, a vector at a time.
//!
//! Two loops in this program walk bytes one at a time and are the whole cost of
//! the paths they sit in: finding the line breaks in a document, and finding
//! where a run of ordinary printable text ends in a terminal stream. Both ask
//! the same shape of question — "where is the first byte that is interesting?"
//! — and both answer it a byte at a time, which on any machine built this
//! century wastes most of the register.
//!
//! `std.mem.indexOfScalar` is already vectorised, so anything that is a search
//! for one known byte should use it and this file does not duplicate it. What
//! is here is the two things the standard library has no shape for:
//!
//!   * **Counting** every occurrence, rather than finding the first. Counting
//!     newlines before allocating means a line index allocates once, at exactly
//!     the right size, instead of growing a dozen times.
//!   * **A range predicate.** "The first byte that is not printable ASCII" is
//!     two comparisons and an OR per vector, and there is no standard function
//!     that takes a predicate rather than a set of bytes.
//!
//! ## How this is kept honest
//!
//! Every function here has a scalar twin, kept beside it and never deleted, and
//! a test that runs both over pseudo-random bytes and every alignment and
//! length near a vector boundary, asserting they agree. That is the only way to
//! test this kind of code: a vectorised scan that is wrong is usually wrong
//! only in the tail, only at one length, and passes every example a person
//! thinks to write by hand.
//!
//! The vector width comes from `std.simd.suggestVectorLength`. On a target with
//! no vector registers it is null, the code takes the scalar path, and the
//! tests still pass — which is the point of keeping the twin.

const std = @import("std");

/// How many bytes are compared at once. Null on a target without vectors.
pub const width: ?usize = if (std.simd.suggestVectorLength(u8)) |lanes| @as(usize, lanes) else null;

/// Count how many times `needle` appears.
///
/// Used before allocating, so a caller can size an array exactly rather than
/// growing it. One pass to count and one to fill beats a dozen reallocations.
pub fn countScalarBytes(haystack: []const u8, needle: u8) usize {
    const lanes = width orelse return countScalarBytesSlow(haystack, needle);

    const Chunk = @Vector(lanes, u8);
    const splat: Chunk = @splat(needle);
    var total: usize = 0;
    var index: usize = 0;

    while (index + lanes <= haystack.len) : (index += lanes) {
        const chunk: Chunk = haystack[index..][0..lanes].*;
        // A match is a lane of all ones. Summing the booleans as ones counts
        // them without ever branching on where they are.
        const matches: @Vector(lanes, u1) = @bitCast(@intFromBool(chunk == splat));
        total += @reduce(.Add, @as(@Vector(lanes, u8), matches));
    }
    return total + countScalarBytesSlow(haystack[index..], needle);
}

/// The plain version, kept for the tail, for targets without vectors, and as
/// the thing the vectorised version is checked against.
pub fn countScalarBytesSlow(haystack: []const u8, needle: u8) usize {
    var total: usize = 0;
    for (haystack) |byte| {
        if (byte == needle) total += 1;
    }
    return total;
}

/// The first byte that is not ordinary printable ASCII: below a space, or
/// `0x7f` and above.
///
/// This is where a run of plain text ends in a terminal stream. Everything
/// before the answer can be printed without consulting a state machine, and
/// everything from the answer needs one.
///
/// Returns null when the whole slice is printable.
pub fn indexOfNonPrintable(haystack: []const u8) ?usize {
    const lanes = width orelse return indexOfNonPrintableSlow(haystack);

    const Chunk = @Vector(lanes, u8);
    const space: Chunk = @splat(0x20);
    const del: Chunk = @splat(0x7f);
    var index: usize = 0;

    while (index + lanes <= haystack.len) : (index += lanes) {
        const chunk: Chunk = haystack[index..][0..lanes].*;
        // Two comparisons and an OR. A byte is interesting if it is a control
        // character or if the high bit region begins.
        const interesting = (chunk < space) | (chunk >= del);
        if (@reduce(.Or, interesting)) {
            // Something in this vector. Which lane is a scalar question and it
            // is asked at most once per call.
            for (haystack[index..][0..lanes], 0..) |byte, lane| {
                if (byte < 0x20 or byte >= 0x7f) return index + lane;
            }
        }
    }
    if (indexOfNonPrintableSlow(haystack[index..])) |found| return index + found;
    return null;
}

pub fn indexOfNonPrintableSlow(haystack: []const u8) ?usize {
    for (haystack, 0..) |byte, index| {
        if (byte < 0x20 or byte >= 0x7f) return index;
    }
    return null;
}

/// Fill `into` with the offset just after each `needle`, plus a leading zero.
///
/// This is what a line index is: the start of every line. It is here rather
/// than in the caller so that the counting pass and the filling pass use the
/// same definition of a line break and cannot disagree about how many there
/// are.
///
/// `into` must have room for `countScalarBytes(haystack, needle) + 1`.
pub fn fillStarts(haystack: []const u8, needle: u8, into: []usize) usize {
    into[0] = 0;
    var written: usize = 1;
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, haystack, index, needle)) |found| {
        if (written == into.len) break;
        into[written] = found + 1;
        written += 1;
        index = found + 1;
    }
    return written;
}

const testing = std.testing;

/// Bytes that exercise the boundaries: plenty of printable text, the odd
/// control character, the odd byte with the high bit set.
fn sample(buffer: []u8, seed: u64) void {
    var random = std.Random.DefaultPrng.init(seed);
    const r = random.random();
    for (buffer) |*byte| {
        byte.* = switch (r.uintLessThan(u8, 10)) {
            0 => r.uintLessThan(u8, 0x20),
            1 => 0x80 | r.uintLessThan(u8, 0x80),
            2 => '\n',
            else => 0x20 + r.uintLessThan(u8, 0x5f),
        };
    }
}

test "counting agrees with the plain version at every length near a boundary" {
    const lanes = width orelse 16;
    var buffer: [512]u8 = undefined;

    // Every length from nothing to four vectors, so a tail of every possible
    // size is covered rather than one arbitrary size.
    var length: usize = 0;
    while (length <= @min(buffer.len, lanes * 4)) : (length += 1) {
        sample(buffer[0..length], length + 1);
        const fast = countScalarBytes(buffer[0..length], '\n');
        const slow = countScalarBytesSlow(buffer[0..length], '\n');
        try testing.expectEqual(slow, fast);
    }
}

test "the non-printable scan agrees with the plain version, at every offset" {
    const lanes = width orelse 16;
    var buffer: [512]u8 = undefined;

    var length: usize = 0;
    while (length <= @min(buffer.len, lanes * 4)) : (length += 1) {
        sample(buffer[0..length], length + 7);
        try testing.expectEqual(
            indexOfNonPrintableSlow(buffer[0..length]),
            indexOfNonPrintable(buffer[0..length]),
        );
    }

    // And the case the random data almost never produces: one interesting byte,
    // walked through every position of a long printable run. A vectorised scan
    // that gets the lane arithmetic wrong passes on random data and fails here.
    var plain: [200]u8 = undefined;
    @memset(&plain, 'x');
    for (0..plain.len) |position| {
        plain[position] = 0x1b;
        try testing.expectEqual(@as(?usize, position), indexOfNonPrintable(&plain));
        plain[position] = 'x';
    }
    try testing.expect(indexOfNonPrintable(&plain) == null);
}

test "a high byte ends a printable run, because it starts a character" {
    // The first byte of a multi-byte character is not printable ASCII, and the
    // fast path must hand it back to the decoder rather than printing it.
    const text = "hello wörld";
    const found = indexOfNonPrintable(text).?;
    try testing.expectEqual(@as(usize, 7), found);
    try testing.expectEqual(@as(u8, 0xc3), text[found]);

    // `0x7f` is delete, not something to print.
    try testing.expectEqual(@as(?usize, 2), indexOfNonPrintable("ab\x7fcd"));
    // A tab is a control character, whatever it looks like.
    try testing.expectEqual(@as(?usize, 2), indexOfNonPrintable("ab\tcd"));
    try testing.expect(indexOfNonPrintable("plain ascii text") == null);
    try testing.expect(indexOfNonPrintable("") == null);
}

test "line starts come out right, and there is one more of them than newlines" {
    const text = "one\ntwo\nthree";
    const count = countScalarBytes(text, '\n');
    try testing.expectEqual(@as(usize, 2), count);

    var starts: [3]usize = undefined;
    const written = fillStarts(text, '\n', &starts);
    try testing.expectEqual(@as(usize, 3), written);
    try testing.expectEqual(@as(usize, 0), starts[0]);
    try testing.expectEqual(@as(usize, 4), starts[1]);
    try testing.expectEqual(@as(usize, 8), starts[2]);

    // A trailing newline opens a line that has nothing in it yet, which is the
    // right answer: an offset at the very end belongs to that line.
    const trailing = "a\n";
    var two: [2]usize = undefined;
    try testing.expectEqual(@as(usize, 2), fillStarts(trailing, '\n', &two));
    try testing.expectEqual(@as(usize, 2), two[1]);

    // Nothing at all is still one line.
    var one: [1]usize = undefined;
    try testing.expectEqual(@as(usize, 1), fillStarts("", '\n', &one));
}

test "counting and filling agree, on text that is mostly newlines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buffer: [4096]u8 = undefined;
    sample(&buffer, 99);

    const count = countScalarBytes(&buffer, '\n');
    const starts = try arena.alloc(usize, count + 1);
    const written = fillStarts(&buffer, '\n', starts);

    // The count sized the array, so the fill must use exactly all of it. If
    // these two ever disagree, one of them is walking the bytes differently.
    try testing.expectEqual(count + 1, written);
    try testing.expectEqual(starts.len, written);
}
