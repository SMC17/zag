const std = @import("std");
const dirstat = @import("dirstat");

test "extensionOf" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("zig", dirstat.Report.extensionOf("main.ZIG", &b));
    try std.testing.expectEqualStrings("(none)", dirstat.Report.extensionOf(".bashrc", &b));
    try std.testing.expectEqualStrings("gz", dirstat.Report.extensionOf("a.tar.gz", &b));
}

test "scan a small tree" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "a/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "x.txt", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/y.TXT", .data = "abc" });
    var r = dirstat.Report.init(std.testing.allocator);
    defer r.deinit();
    try dirstat.scan(std.testing.allocator, io, tmp.dir, &r);
    try std.testing.expectEqual(@as(u64, 2), r.total_files);
    try std.testing.expectEqual(@as(u64, 8), r.total_bytes);
    try std.testing.expectEqual(@as(u64, 2), r.dirs);
}
