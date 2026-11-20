#!/bin/bash
# expect: 0 -- near miss: main.zig and build.zig ported; the library left on 0.15 (trimLeft, .{} defaults).
set -eu
cp /solution/files/build.zig /app/build.zig
cp /solution/files/src/main.zig /app/src/main.zig
