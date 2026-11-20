#!/bin/bash
# Verifier for sunlitmoon/@TASK@. Binary reward: 1 only if every check passes.
# Same design as zig-016-port (see its SOUNDNESS.md): checks that execute agent-controlled
# build code run LAST, as `nobody`, after the earlier verdicts are held in this shell.
set -u
LOG=/logs/verifier; mkdir -p "$LOG"
ZIG=/opt/zig/zig
H=/tests/hidden
LIB=@LIB@
W=$(mktemp -d /tmp/verify.XXXXXX)
fail() { echo "FAIL: $*" | tee -a "$LOG/details.txt"; echo 0 > "$LOG/reward.txt"; exit 0; }
pass() { echo "ok: $*" | tee -a "$LOG/details.txt"; }

[ -f /app/src/$LIB.zig ] && [ -f /app/src/main.zig ] && [ -f /app/build.zig ] || fail "missing /app/src/$LIB.zig, /app/src/main.zig or /app/build.zig"
mkdir -p "$W/agent" && cp -r /app/. "$W/agent/" && rm -rf "$W/agent/.zig-cache" "$W/agent/zig-out"
export ZIG_GLOBAL_CACHE_DIR="$W/zcache-root" ZIG_LOCAL_CACHE_DIR="$W/zcache-root"

# 1. Hidden behavioural tests against the agent's library, compiled by the verifier.
timeout 300 "$ZIG" test -lc --dep $LIB -Mroot="$H/hidden_test.zig" @LIB_PRE@ -M$LIB="$W/agent/src/$LIB.zig" \
  > "$W/unit.log" 2>&1 || { tail -40 "$W/unit.log" >> "$LOG/details.txt"; fail "hidden unit tests"; }
pass "hidden unit tests"

# 2. The CLI, built by the verifier, on hidden cases. Each case directory holds an optional
#    setup.sh (run in a fresh directory), args (one per line), and the expected
#    stdout, exit and optionally stderr. A case with driver.sh is run as
#    `BIN=<binary> bash driver.sh` instead, for programs that must be talked to (servers);
#    the driver's stdout and exit code are what is compared.
timeout 300 "$ZIG" build-exe -lc -femit-bin="$W/bin" --dep $LIB -Mroot="$W/agent/src/main.zig" @LIB_PRE@ -M$LIB="$W/agent/src/$LIB.zig" \
  > "$W/exe.log" 2>&1 || { tail -40 "$W/exe.log" >> "$LOG/details.txt"; fail "CLI does not build from src/main.zig"; }
for c in "$H"/cases/*/; do
  n=$(basename "$c"); run="$W/run-$n"; mkdir -p "$run"
  if [ -f "$c/setup.sh" ]; then (cd "$run" && bash "$c/setup.sh") > /dev/null 2>&1 || fail "$n: setup failed (verifier bug)"; fi
  if [ -f "$c/driver.sh" ]; then
    (cd "$run" && BIN="$W/bin" timeout 60 bash "$c/driver.sh" > "$W/$n.out" 2> "$W/$n.err" < /dev/null); code=$?
  else
    mapfile -t ARGS < <([ -f "$c/args" ] && cat "$c/args")
    (cd "$run" && timeout 30 "$W/bin" "${ARGS[@]}" > "$W/$n.out" 2> "$W/$n.err" < /dev/null); code=$?
  fi
  [ "$code" = "$(cat "$c/exit")" ] || fail "$n: exit $code, want $(cat "$c/exit")"
  cmp -s "$W/$n.out" "$c/stdout" || fail "$n: stdout differs"
  if [ -f "$c/stderr" ]; then cmp -s "$W/$n.err" "$c/stderr" || fail "$n: stderr differs"; fi
done
pass "CLI on hidden cases"

# 3. The agent's own build graph on 0.16, unprivileged, exit codes only.
chmod 755 "$LOG" "$W"; chmod -R a-w /tests 2>/dev/null
cp -r "$W/agent" "$W/agent-build" && mkdir -p "$W/zcache-nobody" && chown -R nobody "$W/agent-build" "$W/zcache-nobody"
run_nobody() { (cd "$W/agent-build" && timeout 300 runuser -u nobody -- env HOME=/tmp ZIG_GLOBAL_CACHE_DIR="$W/zcache-nobody" ZIG_LOCAL_CACHE_DIR="$W/zcache-nobody" "$ZIG" "$@"); }
run_nobody build > "$W/build.log" 2>&1 || { tail -40 "$W/build.log" >> "$LOG/details.txt"; fail "zig build"; }
run_nobody build test > "$W/btest.log" 2>&1 || { tail -40 "$W/btest.log" >> "$LOG/details.txt"; fail "zig build test"; }
# Optional task-specific check of what the agent's build installed (artifacts, headers).
if [ -f "$H/post_build.sh" ]; then
  (cd "$W/agent-build" && bash "$H/post_build.sh") > "$W/post.log" 2>&1 || { tail -20 "$W/post.log" >> "$LOG/details.txt"; fail "build outputs (post_build.sh)"; }
fi
pass "zig build && zig build test (as nobody)"

echo 1 > "$LOG/reward.txt"
