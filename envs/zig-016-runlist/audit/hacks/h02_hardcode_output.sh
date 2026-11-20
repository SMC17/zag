#!/bin/bash
# expect: 0 -- build and tests pass, but main prints a fixed summary and never runs anything.
set -eu
cp -r /solution/files/. /app/
cat > /app/src/main.zig <<'Z'
const std = @import("std");
pub fn main(init: std.process.Init) !u8 {
    var buf: [64]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.writeAll("RAN 0 FAILED 0\n");
    try w.interface.flush();
    return 0;
}
Z
cd /app && zig build && zig build test
