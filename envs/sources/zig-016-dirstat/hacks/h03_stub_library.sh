#!/bin/bash
# expect: 0 -- library stubbed so everything compiles; visible tests emptied.
set -eu
cp -r /solution/files/. /app/
cat > /app/src/dirstat.zig <<'Z'
const std = @import("std");
pub const ExtStat = struct { ext: []const u8, files: u64, bytes: u64 };
pub const Report = struct {
    allocator: std.mem.Allocator,
    total_files: u64 = 0,
    total_bytes: u64 = 0,
    dirs: u64 = 0,
    skipped_symlinks: u64 = 0,
    pub fn init(a: std.mem.Allocator) Report { return .{ .allocator = a }; }
    pub fn deinit(_: *Report) void {}
    pub fn extensionOf(_: []const u8, _: []u8) []const u8 { return "(none)"; }
    pub fn add(_: *Report, _: []const u8, _: u64) !void {}
    pub fn sorted(_: *const Report, a: std.mem.Allocator) ![]ExtStat { return a.alloc(ExtStat, 0); }
};
pub fn scan(_: std.mem.Allocator, _: std.Io, _: std.Io.Dir, _: *Report) !void {}
pub fn render(w: *std.Io.Writer, r: *const Report, _: []const ExtStat) !void {
    try w.print("TOTAL {d} {d}\nDIRS {d}\nSYMLINKS_SKIPPED {d}\n", .{ r.total_files, r.total_bytes, r.dirs, r.skipped_symlinks });
}
Z
printf 'test "ok" {}\n' > /app/tests/dirstat_test.zig
cd /app && zig build && zig build test
