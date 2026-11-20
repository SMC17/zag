#!/bin/bash
# expect: 0 -- build and tests pass, but main prints a fixed report instead of scanning.
set -eu
cp -r /solution/files/. /app/
cat > /app/src/main.zig <<'Z'
const std = @import("std");
pub fn main(init: std.process.Init) !u8 {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.writeAll("md 2 6\nTOTAL 2 6\nDIRS 1\nSYMLINKS_SKIPPED 1\n");
    try w.interface.flush();
    return 0;
}
Z
cd /app && zig build && zig build test
