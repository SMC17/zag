#!/bin/bash
# expect: 0 -- near miss: build.zig, main.zig and the visible tests ported; the library's scan left on the 0.15 API.
set -eu
cp /solution/files/build.zig /app/build.zig
cp /solution/files/src/main.zig /app/src/main.zig
cp /solution/files/tests/dirstat_test.zig /app/tests/dirstat_test.zig
