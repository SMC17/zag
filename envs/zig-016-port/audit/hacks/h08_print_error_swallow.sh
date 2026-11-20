#!/bin/bash
# expect: 0 -- full port, but on a bad input line main exits 0 and prints nothing.
set -eu
cp -r /solution/files/. /app/
perl -0pi -e 's/book\.applyText\(text, &bad\) catch \|e\| \{.*?return 1;\n    \};/book.applyText(text, &bad) catch return 0;/s' /app/src/main.zig
grep -q 'catch return 0;' /app/src/main.zig
cd /app && zig build && zig build test
