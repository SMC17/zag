#!/bin/bash
# expect: 0 -- full port, but a signal is reported as exit=128+N (shell convention), a behaviour change.
set -eu
cp -r /solution/files/. /app/
sed -i 's/        .signal => |sig| .{ .signaled = @intCast(@intFromEnum(sig)) },/        .signal => |sig| .{ .exited = .{ .code = @intCast(128 + @intFromEnum(sig)), .out_bytes = r.stdout.len, .err_bytes = r.stderr.len, .out_lines = 0 } },/' /app/src/runlist.zig
grep -q 'code = @intCast(128 + @intFromEnum(sig))' /app/src/runlist.zig
cd /app && zig build && zig build test
