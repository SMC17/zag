//! Hidden behavioural suite for zig-016-runlist (Zig 0.16 API).
const std = @import("std");
const testing = std.testing;
const runlist = @import("runlist");

test "splitArgs: tabs, runs of spaces, comments, blanks, CR" {
    const a = (try runlist.splitArgs(testing.allocator, "\t echo \t a  b\r")).?;
    defer testing.allocator.free(a);
    try testing.expectEqual(@as(usize, 3), a.len);
    try testing.expectEqualStrings("echo", a[0]);
    try testing.expectEqualStrings("b", a[2]);
    try testing.expect((try runlist.splitArgs(testing.allocator, "   # x")) == null);
    try testing.expect((try runlist.splitArgs(testing.allocator, " \t\r")) == null);
}

test "runOne: exit code, byte counts, line count" {
    const io = testing.io;
    const o = runlist.runOne(testing.allocator, io, &.{ "sh", "-c", "printf 'ab\\ncd\\n'; printf xyz >&2; exit 4" });
    try testing.expectEqual(@as(u8, 4), o.exited.code);
    try testing.expectEqual(@as(usize, 6), o.exited.out_bytes);
    try testing.expectEqual(@as(usize, 3), o.exited.err_bytes);
    try testing.expectEqual(@as(usize, 2), o.exited.out_lines);
    try testing.expect(!runlist.succeeded(o));
}

test "runOne: signal and missing program are distinct outcomes" {
    const io = testing.io;
    const s = runlist.runOne(testing.allocator, io, &.{ "sh", "-c", "kill -TERM $$" });
    try testing.expectEqual(@as(u32, 15), s.signaled);
    const m = runlist.runOne(testing.allocator, io, &.{"definitely-not-a-program-xyz"});
    try testing.expectEqual(error.FileNotFound, m.spawn_failed);
    try testing.expect(!runlist.succeeded(s) and !runlist.succeeded(m));
}

test "render: exact formats" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try runlist.render(&w, 3, .{ .exited = .{ .code = 0, .out_bytes = 5, .err_bytes = 1, .out_lines = 2 } }, &.{ "a", "b" });
    try runlist.render(&w, 4, .{ .signaled = 9 }, &.{"c"});
    try runlist.render(&w, 5, .{ .spawn_failed = error.FileNotFound }, &.{"d"});
    try testing.expectEqualStrings("3 exit=0 out=5 err=1 lines=2 a b\n4 signal=9 c\n5 spawn_error=FileNotFound d\n", w.buffered());
}
