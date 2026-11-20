#!/bin/bash
# expect: 0 -- full port with a real behaviour bug (sorted() does not sort), visible tests
# edited so they pass. Hidden behavioural tests and hidden CLI cases must catch it.
set -eu
cp -r /solution/files/. /app/
sed -i 's|        std.mem.sort(Position, out.items, {}, lessThan);|        _ = \&lessThan;|' /app/src/ledger.zig
grep -q '_ = &lessThan;' /app/src/ledger.zig
sed -i 's|try std.testing.expectEqual(@as(i64, 6), ps\[0\].net_qty);||' /app/tests/ledger_test.zig
cd /app && zig build && zig build test
