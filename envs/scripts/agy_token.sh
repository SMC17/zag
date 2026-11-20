#!/usr/bin/env bash
# Export your agy sign-in token from the macOS keychain to a private file for Harbor trials.
# Nothing is printed. Re-run if agy says you are logged out (for example after `agy` re-login).
set -euo pipefail
OUT="${AGY_OAUTH_TOKEN_FILE:-$HOME/.config/smc17-envs/agy-oauth-token}"
mkdir -p "$(dirname "$OUT")" && chmod 700 "$(dirname "$OUT")"
umask 077
security find-generic-password -s gemini -a antigravity -w \
  | python3 -I -c 'import sys,base64; r=sys.stdin.read().strip(); p="go-keyring-base64:"; sys.stdout.write(base64.b64decode(r[len(p):]).decode() if r.startswith(p) else r)' \
  > "$OUT"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "token" in d, "unexpected token format"' "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes, mode 600)"
