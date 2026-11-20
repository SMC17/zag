set -u
# Starts the server, plays each session in sessions.txt over TCP (sessions are separated
# by lines of exactly "---"), prints what the server sent back, then the server's exit code.
PORT=7801
mkfifo srv.out
"$BIN" "$PORT" > srv.out 2> srv.err &
SRV=$!
exec 4< srv.out
read -r -t 10 first <&4 || { echo "NO_LISTENING_LINE"; exit 1; }
[ "$first" = "LISTENING $PORT" ] || { echo "BAD_LISTENING_LINE $first"; exit 1; }
n=0
send_session() {
  n=$((n + 1)); echo "== session $n"
  exec 3<>"/dev/tcp/127.0.0.1/$PORT" || { echo "CONNECT_FAILED"; return; }
  printf '%s' "$1" >&3
  timeout 10 cat <&3
  exec 3<&- 3>&-
}
buf=""
while IFS= read -r line || [ -n "$line" ]; do
  if [ "$line" = "---" ]; then send_session "$buf"; buf=""; else buf+="$line"$'\n'; fi
done < /tests/hidden/cases/protocol/sessions.txt
[ -n "$buf" ] && send_session "$buf"
for _ in $(seq 1 50); do kill -0 $SRV 2>/dev/null || break; sleep 0.1; done
if kill -0 $SRV 2>/dev/null; then kill -9 $SRV; echo "SERVER_STILL_RUNNING"; exit 1; fi
wait $SRV; echo "SERVER_EXIT $?"
