#!/bin/bash
# expect: 0 -- near miss: build.zig and main.zig ported, library container init left on 0.15 defaults.
set -eu
cp /solution/files/build.zig /app/build.zig
cp /solution/files/src/main.zig /app/src/main.zig
