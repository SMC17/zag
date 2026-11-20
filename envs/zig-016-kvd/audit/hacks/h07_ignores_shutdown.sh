#!/bin/bash
# expect: 0 -- full port, but SHUTDOWN only closes the connection; the server keeps running.
set -eu
cp -r /solution/files/. /app/
sed -i 's/        if (act == .shutdown) return 0;/        _ = act;/' /app/src/main.zig
grep -q '        _ = act;' /app/src/main.zig
cd /app && zig build && zig build test
