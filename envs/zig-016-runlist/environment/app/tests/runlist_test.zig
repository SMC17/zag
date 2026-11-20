const std = @import("std");
const runlist = @import("runlist");

test "splitArgs" {
    const a = (try runlist.splitArgs(std.testing.allocator, "  echo  hi\tthere ")).?;
    defer std.testing.allocator.free(a);
    try std.testing.expectEqual(@as(usize, 3), a.len);
    try std.testing.expect((try runlist.splitArgs(std.testing.allocator, "# c")) == null);
}

test "runOne: true and false" {
    try std.testing.expect(runlist.succeeded(runlist.runOne(std.testing.allocator, &.{"true"})));
    try std.testing.expect(!runlist.succeeded(runlist.runOne(std.testing.allocator, &.{"false"})));
}
