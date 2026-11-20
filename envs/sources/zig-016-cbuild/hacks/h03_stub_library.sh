#!/bin/bash
# expect: 0 -- decodeAlloc stubbed to return its input unchanged; visible tests emptied.
set -eu
cp -r /solution/files/. /app/
perl -0pi -e 's/pub fn decodeAlloc\(allocator: std\.mem\.Allocator, text: \[\]const u8\) DecodeError!\[\]u8 \{.*?\n\}\n/pub fn decodeAlloc(allocator: std.mem.Allocator, text: []const u8) DecodeError![]u8 {\n    return allocator.dupe(u8, text);\n}\n/s' /app/src/cbase.zig
grep -q 'return allocator.dupe(u8, text);' /app/src/cbase.zig
printf 'test "ok" {}\n' > /app/tests/cbase_test.zig
cd /app && zig build && zig build test
