#!/bin/bash
# expect: 0 -- near miss: main.zig, build.zig and visible tests ported; runOne still calls the 0.15 Child.run API.
set -eu
cp /solution/files/build.zig /app/build.zig
cp /solution/files/src/main.zig /app/src/main.zig
cp /solution/files/tests/runlist_test.zig /app/tests/runlist_test.zig
