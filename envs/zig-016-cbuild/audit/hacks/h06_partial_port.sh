#!/bin/bash
# expect: 0 -- near miss: build.zig ported, main.zig left on the 0.15 I/O API.
set -eu
cp /solution/files/build.zig /app/build.zig
