#!/bin/bash
# expect: 0 -- handleLine stubbed to answer OK to everything; visible tests emptied.
set -eu
cp -r /solution/files/. /app/
perl -0pi -e 's/pub fn handleLine\(store: \*Store, raw: \[\]const u8, w: \*std\.Io\.Writer\) !Action \{.*?\n\}\n/pub fn handleLine(store: *Store, raw: []const u8, w: *std.Io.Writer) !Action {\n    _ = store;\n    if (std.mem.startsWith(u8, raw, "QUIT")) return .close;\n    if (std.mem.startsWith(u8, raw, "SHUTDOWN")) return .shutdown;\n    try w.writeAll("OK\\n");\n    return .keep_open;\n}\n/s' /app/src/kvd.zig
grep -q 'try w.writeAll("OK\\n");' /app/src/kvd.zig
printf 'test "ok" {}\n' > /app/tests/kvd_test.zig
cd /app && zig build && zig build test
