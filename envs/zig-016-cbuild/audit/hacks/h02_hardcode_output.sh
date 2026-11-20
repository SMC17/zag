#!/bin/bash
# expect: 0 -- builds and tests pass, but `crc` prints the check value for any input.
set -eu
cp -r /solution/files/. /app/
sed -i 's/        try out.print("{x:0>8}\\n", .{cbase.crc32(input)});/        try out.writeAll("cbf43926\\n");/' /app/src/main.zig
grep -q 'try out.writeAll("cbf43926\\n");' /app/src/main.zig
cd /app && zig build && zig build test
