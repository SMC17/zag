//! Content addressing for every durable artifact in the workspace.
//!
//! One hash type is used everywhere: BLAKE3-256, printed as lower-case hex with
//! a `b3:` prefix. A single canonical form keeps evidence records, provenance
//! chains and the record ledger comparable across subsystems, which is what
//! ISO 15489 record identity and ISO/IEC 42001 traceability both need.

const std = @import("std");

pub const Hash = struct {
    bytes: [32]u8,

    pub const zero: Hash = .{ .bytes = [_]u8{0} ** 32 };

    /// Hash a byte slice.
    pub fn of(data: []const u8) Hash {
        var h: Hash = undefined;
        std.crypto.hash.Blake3.hash(data, &h.bytes, .{});
        return h;
    }

    /// Hash an ordered list of fields. Each part is length-prefixed so that
    /// ("ab","c") and ("a","bc") never collide.
    pub fn ofParts(parts: []const []const u8) Hash {
        var hasher = std.crypto.hash.Blake3.init(.{});
        for (parts) |p| {
            var len: [8]u8 = undefined;
            std.mem.writeInt(u64, &len, p.len, .little);
            hasher.update(&len);
            hasher.update(p);
        }
        var h: Hash = undefined;
        hasher.final(&h.bytes);
        return h;
    }

    /// Chain a previous hash with new content. Used by the append-only event
    /// log and the records ledger so that any later edit is detectable.
    pub fn chain(previous: Hash, content: Hash) Hash {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(&previous.bytes);
        hasher.update(&content.bytes);
        var h: Hash = undefined;
        hasher.final(&h.bytes);
        return h;
    }

    pub fn eql(a: Hash, b: Hash) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub const text_len = 3 + 64;

    /// Write the canonical text form into `buf` (must hold `text_len` bytes).
    pub fn toText(self: Hash, buf: *[text_len]u8) []const u8 {
        @memcpy(buf[0..3], "b3:");
        const hex = "0123456789abcdef";
        for (self.bytes, 0..) |b, i| {
            buf[3 + i * 2] = hex[b >> 4];
            buf[3 + i * 2 + 1] = hex[b & 0x0f];
        }
        return buf[0..];
    }

    pub fn format(self: Hash, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [text_len]u8 = undefined;
        try w.writeAll(self.toText(&buf));
    }

    /// Short form for user interfaces. Twelve hex characters are enough for a
    /// person to compare two records on screen; the full hash stays in the
    /// record.
    pub fn short(self: Hash, buf: *[12]u8) []const u8 {
        const hex = "0123456789abcdef";
        for (0..6) |i| {
            buf[i * 2] = hex[self.bytes[i] >> 4];
            buf[i * 2 + 1] = hex[self.bytes[i] & 0x0f];
        }
        return buf[0..];
    }

    pub fn jsonStringify(self: Hash, jw: *std.json.Stringify) !void {
        var buf: [text_len]u8 = undefined;
        try jw.write(self.toText(&buf));
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Hash {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const slice = switch (token) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return parse(slice) catch error.InvalidCharacter;
    }

    pub fn parse(text: []const u8) error{InvalidHash}!Hash {
        const body = if (std.mem.startsWith(u8, text, "b3:")) text[3..] else text;
        if (body.len != 64) return error.InvalidHash;
        var h: Hash = undefined;
        _ = std.fmt.hexToBytes(&h.bytes, body) catch return error.InvalidHash;
        return h;
    }
};

test "hash is stable and printable" {
    const a = Hash.of("workspace");
    const b = Hash.of("workspace");
    try std.testing.expect(a.eql(b));

    var buf: [Hash.text_len]u8 = undefined;
    const text = a.toText(&buf);
    try std.testing.expect(std.mem.startsWith(u8, text, "b3:"));
    try std.testing.expectEqual(@as(usize, 67), text.len);

    const round = try Hash.parse(text);
    try std.testing.expect(round.eql(a));
}

test "part hashing is unambiguous" {
    const x = Hash.ofParts(&.{ "ab", "c" });
    const y = Hash.ofParts(&.{ "a", "bc" });
    try std.testing.expect(!x.eql(y));
}

test "chaining detects reordering" {
    const g = Hash.of("genesis");
    const one = Hash.chain(g, Hash.of("one"));
    const two = Hash.chain(one, Hash.of("two"));
    const swapped = Hash.chain(Hash.chain(g, Hash.of("two")), Hash.of("one"));
    try std.testing.expect(!two.eql(swapped));
}
