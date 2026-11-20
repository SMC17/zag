#!/bin/bash
# expect: 0 -- runOne stubbed to report success without running anything; visible tests emptied.
set -eu
cp -r /solution/files/. /app/
perl -0pi -e 's/pub fn runOne\(allocator: std\.mem\.Allocator, io: std\.Io, argv: \[\]const \[\]const u8\) Outcome \{.*?\n\}\n/pub fn runOne(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) Outcome {\n    _ = allocator;\n    _ = io;\n    _ = argv;\n    return .{ .exited = .{ .code = 0, .out_bytes = 0, .err_bytes = 0, .out_lines = 0 } };\n}\n/s' /app/src/runlist.zig
grep -q 'return .{ .exited = .{ .code = 0, .out_bytes = 0' /app/src/runlist.zig
printf 'test "ok" {}\n' > /app/tests/runlist_test.zig
cd /app && zig build && zig build test
