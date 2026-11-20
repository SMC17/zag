//! Hidden behavioural suite for zig-016-cbuild (Zig 0.16 API).
const std = @import("std");
const testing = std.testing;
const cbase = @import("cbase");

test "RFC 4648 vectors, both directions" {
    const a = testing.allocator;
    const v = [_][2][]const u8{
        .{ "", "" },         .{ "f", "Zg==" },        .{ "fo", "Zm8=" },        .{ "foo", "Zm9v" },
        .{ "foob", "Zm9vYg==" }, .{ "fooba", "Zm9vYmE=" }, .{ "foobar", "Zm9vYmFy" },
    };
    for (v) |p| {
        const e = try cbase.encodeAlloc(a, p[0]);
        defer a.free(e);
        try testing.expectEqualStrings(p[1], e);
        const d = try cbase.decodeAlloc(a, p[1]);
        defer a.free(d);
        try testing.expectEqualStrings(p[0], d);
    }
}

test "decode rejects bad input and tolerates surrounding whitespace" {
    const a = testing.allocator;
    for ([_][]const u8{ "Zg=", "Zg===", "Z@==", "Zh==", "Zm9=", "Zm8", "====" }) |bad| {
        try testing.expectError(error.InvalidBase64, cbase.decodeAlloc(a, bad));
    }
    const d = try cbase.decodeAlloc(a, " \tZm9vYmFy\r\n");
    defer a.free(d);
    try testing.expectEqualStrings("foobar", d);
}

test "crc32: check value, empty input, streaming equals one-shot" {
    try testing.expectEqual(@as(u32, 0xCBF43926), cbase.crc32("123456789"));
    try testing.expectEqual(@as(u32, 0), cbase.crc32(""));
    const msg = "The quick brown fox jumps over the lazy dog";
    try testing.expectEqual(@as(u32, 0x414FA339), cbase.crc32(msg));
    try testing.expectEqual(cbase.crc32(msg), cbase.crc32Update(cbase.crc32Update(0, msg[0..10]), msg[10..]));
}

test "random round trips match std.base64 and std.hash.Crc32" {
    const a = testing.allocator;
    var prng = std.Random.DefaultPrng.init(17);
    const r = prng.random();
    var buf: [600]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) : (n += 37) {
        r.bytes(buf[0..n]);
        const e = try cbase.encodeAlloc(a, buf[0..n]);
        defer a.free(e);
        var want: [800]u8 = undefined;
        try testing.expectEqualStrings(std.base64.standard.Encoder.encode(&want, buf[0..n]), e);
        const d = try cbase.decodeAlloc(a, e);
        defer a.free(d);
        try testing.expectEqualSlices(u8, buf[0..n], d);
        try testing.expectEqual(std.hash.Crc32.hash(buf[0..n]), cbase.crc32(buf[0..n]));
    }
}
