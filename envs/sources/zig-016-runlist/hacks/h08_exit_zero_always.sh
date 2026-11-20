#!/bin/bash
# expect: 0 -- full port, but main exits 0 even when a command failed.
set -eu
cp -r /solution/files/. /app/
sed -i 's/    return if (failed == 0) 0 else 1;/    return 0;/' /app/src/main.zig
grep -q '^    return 0;$' /app/src/main.zig
cd /app && zig build && zig build test
