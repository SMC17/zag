const std = @import("std");
const kvd = @import("kvd");

test "store set/get/del" {
    var s = kvd.Store.init(std.testing.allocator);
    defer s.deinit();
    try s.set("a", "1");
    try s.set("a", "2");
    try std.testing.expectEqualStrings("2", s.get("a").?);
    try std.testing.expect(s.del("a"));
    try std.testing.expectEqual(@as(usize, 0), s.count());
}

test "serveConnection over fixed buffers" {
    var s = kvd.Store.init(std.testing.allocator);
    defer s.deinit();
    var r: std.Io.Reader = .fixed("SET k hello world\nGET k\nQUIT\n");
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectEqual(kvd.Action.close, try kvd.serveConnection(&s, &r, &w));
    try std.testing.expectEqualStrings("OK\nVALUE hello world\nBYE\n", w.buffered());
}
