#!/bin/bash
# expect: 0 -- full port, but SET keeps the spaces between key and value (trimStart dropped).
set -eu
cp -r /solution/files/. /app/
sed -i 's/        const value = std.mem.trimStart(u8, rest\[ksp + 1 ..\], " ");/        const value = rest[ksp + 1 ..];/' /app/src/kvd.zig
grep -q 'const value = rest\[ksp + 1 ..\];' /app/src/kvd.zig
cd /app && zig build && zig build test
