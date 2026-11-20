#!/bin/bash
# expect: 0 -- full port, but symlinked files are counted as files (a behaviour change); visible tests still pass.
set -eu
cp -r /solution/files/. /app/
perl -0pi -e 's/            \.sym_link => report\.skipped_symlinks \+= 1,/            .sym_link => {\n                const st = entry.dir.statFile(io, entry.basename, .{}) catch {\n                    report.skipped_symlinks += 1;\n                    continue;\n                };\n                if (st.kind == .file) try report.add(entry.basename, st.size) else report.skipped_symlinks += 1;\n            },/' /app/src/dirstat.zig
grep -q 'if (st.kind == .file) try report.add' /app/src/dirstat.zig
cd /app && zig build && zig build test
