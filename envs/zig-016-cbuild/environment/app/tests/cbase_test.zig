const std = @import("std");
const cbase = @import("cbase");

test "round trip" {
    const a = std.testing.allocator;
    const e = try cbase.encodeAlloc(a, "hello");
    defer a.free(e);
    try std.testing.expectEqualStrings("aGVsbG8=", e);
    const d = try cbase.decodeAlloc(a, e);
    defer a.free(d);
    try std.testing.expectEqualStrings("hello", d);
}

test "crc32 check value" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), cbase.crc32("123456789"));
}
