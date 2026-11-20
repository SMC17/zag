#!/usr/bin/env bash
# Run the Codex pass-rate measurement unattended, once it can actually run.
#   envs/scripts/schedule_passrates.sh            install: daily at 17:00 until one run has valid trials
#   envs/scripts/schedule_passrates.sh --remove   uninstall
#   envs/scripts/schedule_passrates.sh --run      what the job runs (also usable by hand)
# A run blocked by a usage limit exits 3 and the job tries again the next day. The first run
# with valid trials writes jobs/passrates-codex-*.json and removes the job. No model tokens are
# spent by this script itself; the agent runs inside Harbor's containers.
set -euo pipefail
ENVS="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.smc17.envs-passrates"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGS="$HOME/Library/Logs/smc17-envs"

case "${1:-}" in
--remove)
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"; echo "removed $LABEL"; exit 0 ;;
--run)
  cd "$ENVS"
  MODEL="$(sed -n 's/^model *= *"\(.*\)"/\1/p' "$HOME/.codex/config.toml" | head -1)"
  set +e
  CODEX_FORCE_AUTH_JSON=1 python3 -I scripts/run_agents.py codex --model "openai/${MODEL:-gpt-6.1-sol}" \
    --agent-kwarg reasoning_effort=high --attempts 3
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then "$0" --remove; fi
  exit $rc ;;
esac

mkdir -p "$LOGS" "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>-lc</string><string>"$ENVS/scripts/schedule_passrates.sh" --run</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$PATH</string></dict>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>17</integer><key>Minute</key><integer>0</integer></dict>
  <key>StandardOutPath</key><string>$LOGS/passrates.log</string>
  <key>StandardErrorPath</key><string>$LOGS/passrates.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $LABEL: daily 17:00 until a run has valid trials; log $LOGS/passrates.log"
