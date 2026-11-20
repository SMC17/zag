#!/bin/bash
# expect: 0 -- full port, but rows with equal bytes are ordered by extension descending.
set -eu
cp -r /solution/files/. /app/
sed -i 's/                return std.mem.lessThan(u8, a.ext, b.ext);/                return std.mem.lessThan(u8, b.ext, a.ext);/' /app/src/dirstat.zig
grep -q 'std.mem.lessThan(u8, b.ext, a.ext)' /app/src/dirstat.zig
cd /app && zig build && zig build test
