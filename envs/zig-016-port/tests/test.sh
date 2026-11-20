#!/bin/bash
# Verifier for sunlitmoon/zig-016-port. Binary reward: 1 only if every check passes.
# Soundness notes are in SOUNDNESS.md. Order matters: checks that execute
# agent-controlled build code (build.zig) run LAST, as an unprivileged user,
# after the verdict of the earlier checks is already held in this shell.
set -u
LOG=/logs/verifier; mkdir -p "$LOG"
ZIG=/opt/zig/zig            # absolute: never resolve zig through PATH
H=/tests/hidden
W=$(mktemp -d /tmp/verify.XXXXXX)
fail() { echo "FAIL: $*" | tee -a "$LOG/details.txt"; echo 0 > "$LOG/reward.txt"; exit 0; }
pass() { echo "ok: $*" | tee -a "$LOG/details.txt"; }

[ -f /app/src/ledger.zig ] && [ -f /app/src/main.zig ] && [ -f /app/build.zig ] || fail "missing /app/src/ledger.zig, /app/src/main.zig or /app/build.zig"
mkdir -p "$W/agent" && cp -r /app/. "$W/agent/" && rm -rf "$W/agent/.zig-cache" "$W/agent/zig-out"
export ZIG_GLOBAL_CACHE_DIR="$W/zcache-root" ZIG_LOCAL_CACHE_DIR="$W/zcache-root"

# 1. Hidden behavioural tests, compiled by the verifier against the agent's library.
timeout 300 "$ZIG" test --dep ledger -Mroot="$H/ledger_hidden_test.zig" -Mledger="$W/agent/src/ledger.zig" \
  > "$W/unit.log" 2>&1 || { tail -40 "$W/unit.log" >> "$LOG/details.txt"; fail "hidden unit tests"; }
pass "hidden unit tests"

# 2. The CLI, built by the verifier (not by the agent's build.zig), on hidden inputs.
timeout 300 "$ZIG" build-exe -lc -femit-bin="$W/ledger" --dep ledger -Mroot="$W/agent/src/main.zig" -Mledger="$W/agent/src/ledger.zig" \
  > "$W/exe.log" 2>&1 || { tail -40 "$W/exe.log" >> "$LOG/details.txt"; fail "CLI does not build from src/main.zig"; }
for c in "$H"/cases/*.csv; do
  n=$(basename "$c" .csv)
  timeout 20 "$W/ledger" "$c" > "$W/$n.out" 2> "$W/$n.err"; code=$?
  [ "$code" = "$(cat "$H/cases/$n.exit")" ] || fail "$n: exit $code, want $(cat "$H/cases/$n.exit")"
  cmp -s "$W/$n.out" "$H/cases/$n.stdout" || fail "$n: stdout differs"
  if [ -f "$H/cases/$n.stderr" ]; then cmp -s "$W/$n.err" "$H/cases/$n.stderr" || fail "$n: stderr differs"; fi
done
timeout 20 "$W/ledger" > /dev/null 2>&1; [ $? = 2 ] || fail "no-argument usage must exit 2"
pass "CLI on hidden inputs"

# 3. The agent's own build graph must work on 0.16: zig build, zig build test.
#    This runs agent-controlled code, so: unprivileged user, private copy, own cache,
#    no write access to /logs/verifier or /tests. Only the exit codes are used.
chmod 755 "$LOG" "$W"; chmod -R a-w /tests 2>/dev/null
cp -r "$W/agent" "$W/agent-build" && mkdir -p "$W/zcache-nobody" && chown -R nobody "$W/agent-build" "$W/zcache-nobody"
run_nobody() { (cd "$W/agent-build" && timeout 300 runuser -u nobody -- env HOME=/tmp ZIG_GLOBAL_CACHE_DIR="$W/zcache-nobody" ZIG_LOCAL_CACHE_DIR="$W/zcache-nobody" "$ZIG" "$@"); }
run_nobody build > "$W/build.log" 2>&1 || { tail -40 "$W/build.log" >> "$LOG/details.txt"; fail "zig build"; }
run_nobody build test > "$W/btest.log" 2>&1 || { tail -40 "$W/btest.log" >> "$LOG/details.txt"; fail "zig build test"; }
pass "zig build && zig build test (as nobody)"

echo 1 > "$LOG/reward.txt"
