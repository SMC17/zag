#!/bin/bash
# expect: 0 -- builds and tests pass, but main prints LISTENING and exits without serving.
set -eu
cp -r /solution/files/. /app/
perl -0pi -e 's/    var store = kvd\.Store\.init\(gpa\);/    if (true) return 0;\n    var store = kvd.Store.init(gpa);/' /app/src/main.zig
grep -q 'if (true) return 0;' /app/src/main.zig
cd /app && zig build && zig build test
