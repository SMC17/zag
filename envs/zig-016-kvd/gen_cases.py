"""Hidden cases for zig-016-kvd. Server cases are played by driver.sh over TCP; the expected
transcript comes from a pure-Python model of the protocol below (no networking, no Zig).
usage: python3 -I gen_cases.py OUT_DIR"""
import pathlib, random, shutil, sys

out = pathlib.Path(sys.argv[1]).resolve()
if out.exists():
    shutil.rmtree(out)
out.mkdir(parents=True)
rng = random.Random(17)


def handle(store, raw):
    line = raw.strip(" \r\n")
    if not line:
        return None, "keep"
    cmd, sep, rest = line.partition(" ")
    rest = rest.lstrip(" ") if sep else ""
    ok_key = lambda k: 1 <= len(k) <= 64
    if cmd == "SET":
        if " " not in rest:
            return "ERR usage: SET <key> <value>", "keep"
        key, _, value = rest.partition(" ")
        value = value.lstrip(" ")
        if not ok_key(key):
            return "ERR bad key", "keep"
        if not (1 <= len(value) <= 256):
            return "ERR bad value", "keep"
        store[key] = value
        return "OK", "keep"
    if cmd in ("GET", "DEL"):
        if not ok_key(rest) or " " in rest:
            return f"ERR usage: {cmd} <key>", "keep"
        if cmd == "GET":
            return (f"VALUE {store[rest]}" if rest in store else "NOTFOUND"), "keep"
        return ("DELETED" if store.pop(rest, None) is not None else "NOTFOUND"), "keep"
    if cmd == "COUNT" and not rest:
        return f"COUNT {len(store)}", "keep"
    if cmd == "QUIT" and not rest:
        return "BYE", "close"
    if cmd == "SHUTDOWN" and not rest:
        return "BYE", "shutdown"
    return "ERR unknown command", "keep"


def transcript(sessions):
    store, lines = {}, []
    for i, sess in enumerate(sessions, 1):
        lines.append(f"== session {i}")
        for raw in sess:
            resp, act = handle(store, raw)
            if resp is not None:
                lines.append(resp)
            if act != "keep":
                break
    lines.append("SERVER_EXIT 0")
    return "".join(l + "\n" for l in lines)


DRIVER = r'''set -u
# Starts the server, plays each session in sessions.txt over TCP (sessions are separated
# by lines of exactly "---"), prints what the server sent back, then the server's exit code.
PORT=$1
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
done < /tests/hidden/cases/CASE/sessions.txt
[ -n "$buf" ] && send_session "$buf"
for _ in $(seq 1 50); do kill -0 $SRV 2>/dev/null || break; sleep 0.1; done
if kill -0 $SRV 2>/dev/null; then kill -9 $SRV; echo "SERVER_STILL_RUNNING"; exit 1; fi
wait $SRV; echo "SERVER_EXIT $?"
'''


def server_case(name, port, sessions):
    c = out / name
    c.mkdir()
    (c / "sessions.txt").write_text("---\n".join("".join(l + "\n" for l in s) for s in sessions))
    (c / "driver.sh").write_text(DRIVER.replace("CASE", name).replace("PORT=$1", f"PORT={port}"))
    (c / "stdout").write_text(transcript(sessions))
    (c / "exit").write_text("0\n")


def plain_case(name, args, exit_code, stderr):
    c = out / name
    c.mkdir()
    if args:
        (c / "args").write_text("\n".join(args) + "\n")
    (c / "stdout").write_text("")
    (c / "exit").write_text(f"{exit_code}\n")
    (c / "stderr").write_text(stderr)


# 1. Basic protocol, state kept across connections, errors keep the connection open.
server_case("protocol", 7801, [
    ["SET greeting hello world", "GET greeting", "GET missing", "COUNT", "BOGUS", "SET onlykey", "GET", "QUIT"],
    ["GET greeting", "SET greeting   spaced  value ", "GET greeting", "DEL greeting", "DEL greeting", "COUNT", "QUIT"],
    ["", "  ", "COUNT", "SHUTDOWN"],
])
# 2. Limits: key and value lengths, CRLF line endings, extra arguments.
server_case("limits", 7802, [
    ["SET " + "k" * 64 + " ok", "SET " + "k" * 65 + " no", "SET v " + "x" * 256, "SET w " + "x" * 257,
     "GET v\r", "COUNT extra", "QUIT now", "GET two words", "QUIT"],
    ["COUNT", "SHUTDOWN"],
])
# 3. A random workload of 400 commands over 5 connections.
keys = [f"key{i}" for i in range(25)]
sessions = []
for s in range(5):
    sess = []
    for _ in range(80):
        op = rng.choice(["SET", "SET", "GET", "GET", "DEL", "COUNT"])
        k = rng.choice(keys)
        if op == "SET":
            sess.append(f"SET {k} v{rng.randint(0, 10**6)} t{rng.randint(0, 99)}")
        elif op == "COUNT":
            sess.append("COUNT")
        else:
            sess.append(f"{op} {k}")
    sess.append("SHUTDOWN" if s == 4 else "QUIT")
    sessions.append(sess)
server_case("random", 7803, sessions)
# 4. Lines after QUIT in the same session are never executed.
server_case("after-quit", 7804, [["SET a 1", "QUIT", "SET b 2"], ["GET b", "GET a", "SHUTDOWN"]])
plain_case("usage", [], 2, "usage: kvd PORT\n")
plain_case("bad-port", ["70000"], 2, "kvd: invalid port: 70000\n")
print("cases:", sorted(p.name for p in out.iterdir()))
