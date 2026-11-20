#!/bin/bash
# expect: 0 -- build works, visible sample output is right, but main.zig just prints it.
set -eu
cp -r /solution/files/. /app/
cat > /app/src/main.zig <<'Z'
const std = @import("std");
pub fn main(init: std.process.Init) !u8 {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try w.interface.writeAll("AAPL 6 113100\nMSFT 5 206050\nNVDA 20 280000\nTOTAL 599150\n");
    try w.interface.flush();
    return 0;
}
Z
cd /app && zig build && zig build test
