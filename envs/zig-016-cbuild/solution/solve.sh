#!/bin/bash
# Reference port to Zig 0.16.0. Proves the task is solvable within the image.
set -eu
cp -r /solution/files/. /app/
cd /app && zig build test && zig build
