"""Hidden CLI cases for zig-016-runlist. Expectations come from an independent Python
implementation (subprocess, no shell). Run inside a Linux container so tool behaviour
matches the verifier: docker run --rm -v $PWD:/s -w /s python:3.12-slim python3 -I gen_cases.py cases
"""
import pathlib, shutil, subprocess, sys, tempfile

out = pathlib.Path(sys.argv[1]).resolve()
if out.exists():
    shutil.rmtree(out)
out.mkdir(parents=True)


def split(line):
    t = line.strip(" \t\r")
    if not t or t.startswith("#"):
        return None
    return t.replace("\t", " ").split()


def run_list(text):
    lines, ran, failed = [], 0, 0
    for line in text.split("\n"):
        argv = split(line)
        if argv is None:
            continue
        ran += 1
        try:
            p = subprocess.run(argv, capture_output=True)
            if p.returncode >= 0:
                desc = f"exit={p.returncode} out={len(p.stdout)} err={len(p.stderr)} lines={p.stdout.count(b'\n')}"
                ok = p.returncode == 0
            else:
                desc, ok = f"signal={-p.returncode}", False
        except FileNotFoundError:
            desc, ok = "spawn_error=FileNotFound", False
        failed += 0 if ok else 1
        lines.append(f"{ran} {desc} " + " ".join(argv))
    return "".join(l + "\n" for l in lines) + f"RAN {ran} FAILED {failed}\n", (0 if failed == 0 else 1)


def case(name, list_text, args=("list.txt",), exit_code=None, stderr=None):
    c = out / name
    c.mkdir()
    if list_text is not None:
        (c / "list.txt").write_text(list_text)
        (c / "setup.sh").write_text(f"cp '{c.name}.list' list.txt\n".replace(f"{c.name}.list", "/tests/hidden/cases/" + name + "/list.txt"))
    if args:
        (c / "args").write_text("\n".join(args) + "\n")
    if list_text is not None and exit_code is None:
        with tempfile.TemporaryDirectory() as t:
            stdout, code = run_list(list_text)
        (c / "stdout").write_text(stdout)
        (c / "exit").write_text(f"{code}\n")
    else:
        (c / "stdout").write_text("")
        (c / "exit").write_text(f"{exit_code}\n")
    if stderr is not None:
        (c / "stderr").write_text(stderr)


case("mixed", "\n".join([
    "# a comment", "", "echo hello world", "printf a\\nb\\nc\\n", "  printf\tno-newline  ",
    "sh -c printf${IFS}oops>&2;exit${IFS}3", "true", "false", "echo   many    spaces",
]) + "\n")
case("missing-program", "echo before\nno-such-program --flag\necho after\n")
case("signals", "sh -c kill${IFS}-TERM${IFS}$$\nsh -c kill${IFS}-KILL${IFS}$$\necho survived\n")
case("big-output", "head -c 1000000 /dev/zero\nhead -c 300000 /dev/urandom\n".replace("head -c 300000 /dev/urandom", "seq 1 50000"))
case("only-comments", "# nothing\n\n   \n#\n")
case("no-trailing-newline", "echo a\necho b")
case("missing-list", None, ("nope.txt",), 1, "runlist: cannot read nope.txt: FileNotFound\n")
case("usage", None, (), 2, "usage: runlist FILE\n")
print("cases:", sorted(p.name for p in out.iterdir()))
