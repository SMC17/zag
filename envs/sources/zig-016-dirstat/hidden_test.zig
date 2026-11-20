//! Hidden behavioural suite for zig-016-dirstat (Zig 0.16 API).
const std = @import("std");
const testing = std.testing;
const dirstat = @import("dirstat");

test "extensionOf: case folding, dotfiles, trailing dot, multi-dot" {
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("zig", dirstat.Report.extensionOf("Main.ZiG", &b));
    try testing.expectEqualStrings("(none)", dirstat.Report.extensionOf(".bashrc", &b));
    try testing.expectEqualStrings("(none)", dirstat.Report.extensionOf("Makefile", &b));
    try testing.expectEqualStrings("(none)", dirstat.Report.extensionOf("weird.", &b));
    try testing.expectEqualStrings("gz", dirstat.Report.extensionOf("a.tar.gz", &b));
    try testing.expectEqualStrings("env", dirstat.Report.extensionOf(".config.env", &b));
}

test "add + sorted: bytes descending, ties by extension ascending, owned keys" {
    var r = dirstat.Report.init(testing.allocator);
    defer r.deinit();
    var name = "f.TXT".*;
    try r.add(&name, 10);
    name[2] = 'Q'; // caller's buffer changes; the report must not care
    try r.add("g.md", 10);
    try r.add("h.zig", 99);
    try r.add("i.txt", 0);
    const rows = try r.sorted(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("zig", rows[0].ext);
    try testing.expectEqualStrings("md", rows[1].ext);
    try testing.expectEqualStrings("txt", rows[2].ext);
    try testing.expectEqual(@as(u64, 2), rows[2].files);
    try testing.expectEqual(@as(u64, 4), r.total_files);
    try testing.expectEqual(@as(u64, 119), r.total_bytes);
}

test "scan: nested dirs, hidden files, symlinks skipped and not followed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/b/c");
    try tmp.dir.createDirPath(io, "empty");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/x.zig", .data = "const a = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/c/y.ZIG", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "12345" });
    try tmp.dir.symLink(io, "a", "link-to-a", .{ .is_directory = true });
    try tmp.dir.symLink(io, ".hidden", "link-to-file", .{});
    var r = dirstat.Report.init(testing.allocator);
    defer r.deinit();
    try dirstat.scan(testing.allocator, io, tmp.dir, &r);
    try testing.expectEqual(@as(u64, 3), r.total_files);
    try testing.expectEqual(@as(u64, 13 + 1 + 5), r.total_bytes);
    try testing.expectEqual(@as(u64, 4), r.dirs); // a, a/b, a/b/c, empty
    try testing.expectEqual(@as(u64, 2), r.skipped_symlinks);
}

test "render: exact format" {
    var r = dirstat.Report.init(testing.allocator);
    defer r.deinit();
    try r.add("a.c", 7);
    r.dirs = 2;
    r.skipped_symlinks = 1;
    const rows = try r.sorted(testing.allocator);
    defer testing.allocator.free(rows);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try dirstat.render(&w, &r, rows);
    try testing.expectEqualStrings("c 1 7\nTOTAL 1 7\nDIRS 2\nSYMLINKS_SKIPPED 1\n", w.buffered());
}
