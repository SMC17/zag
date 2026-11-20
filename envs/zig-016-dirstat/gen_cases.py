"""Hidden CLI cases for zig-016-dirstat, with expectations from an independent Python
implementation (os.scandir, lstat; symlinks never followed). Deterministic: seed 17.
usage: python3 -I gen_cases.py OUT_DIR"""
import os, pathlib, random, shutil, subprocess, sys, tempfile

out = pathlib.Path(sys.argv[1]).resolve()
if out.exists():
    shutil.rmtree(out)
out.mkdir(parents=True)
rng = random.Random(17)


def ext_of(name):
    dot = name.rfind(".")
    if dot <= 0 or dot + 1 == len(name):
        return "(none)"
    return name[dot + 1:][:64].lower()


def expect(root):
    by, files, size, dirs, links = {}, 0, 0, 0, 0
    stack = [root]
    while stack:
        d = stack.pop()
        for e in os.scandir(d):
            if e.is_symlink():
                links += 1
            elif e.is_dir(follow_symlinks=False):
                dirs += 1
                stack.append(e.path)
            elif e.is_file(follow_symlinks=False):
                st = e.stat(follow_symlinks=False).st_size
                k = ext_of(e.name)
                f, b = by.get(k, (0, 0))
                by[k] = (f + 1, b + st)
                files += 1
                size += st
    rows = sorted(by.items(), key=lambda kv: (-kv[1][1], kv[0].encode()))
    return "".join(f"{k} {f} {b}\n" for k, (f, b) in rows) + f"TOTAL {files} {size}\nDIRS {dirs}\nSYMLINKS_SKIPPED {links}\n"


def case(name, setup, args, exit_code=0, stderr=None):
    c = out / name
    c.mkdir()
    (c / "setup.sh").write_text("set -e\n" + setup)
    if args:  # no file means no arguments (an empty file would mean one empty argument)
        (c / "args").write_text("\n".join(args) + "\n")
    (c / "exit").write_text(f"{exit_code}\n")
    if exit_code == 0:
        with tempfile.TemporaryDirectory() as t:
            subprocess.run(["bash", str(c / "setup.sh")], cwd=t, check=True)
            (c / "stdout").write_text(expect(os.path.join(t, args[0])))
    else:
        (c / "stdout").write_text("")
    if stderr is not None:
        (c / "stderr").write_text(stderr)


# 1. A random tree: 60 files over nested dirs, mixed-case extensions, dotfiles.
exts = ["zig", "ZIG", "md", "txt", "TXT", "json", "c", "h", "", "tar.gz"]
lines = ["mkdir -p root"]
for i in range(60):
    depth = rng.randint(0, 4)
    d = "root/" + "/".join(f"d{rng.randint(0, 3)}" for _ in range(depth))
    e = rng.choice(exts)
    fname = (f"f{i}." + e) if e else (f".dot{i}" if i % 2 else f"plain{i}")
    lines.append(f"mkdir -p '{d}'")
    lines.append(f"head -c {rng.randint(0, 5000)} /dev/zero > '{d}/{fname}'")
case("tree", "\n".join(lines) + "\n", ["root"])
# 2. Symlinks to a file and to a directory, which must be counted and not followed.
case("links", "mkdir -p root/real/deep\nprintf 'abcdef' > root/real/deep/a.txt\nln -s real root/alias\nln -s real/deep/a.txt root/a-link.txt\nln -s /nonexistent root/dangling\n", ["root"])
# 3. An empty directory.
case("empty", "mkdir -p root\n", ["root"])
# 4. A missing path: exit 1 with the exact message.
case("missing", "", ["nope"], 1, "dirstat: cannot open nope: FileNotFound\n")
# 5. Wrong usage: exit 2.
case("usage", "", [], 2, "usage: dirstat DIR\n")
print("cases:", sorted(p.name for p in out.iterdir()))
