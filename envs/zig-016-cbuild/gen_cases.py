"""Hidden CLI cases for zig-016-cbuild. Expectations from Python's base64 and zlib.crc32;
"canonical" is decided independently (decode, re-encode, compare). Input files are created
by setup.sh with coreutils (`base64 -d`, `seq`), never by the code under test. Seed 17.
usage: python3 -I gen_cases.py OUT_DIR"""
import base64, binascii, pathlib, random, shutil, sys, zlib

out = pathlib.Path(sys.argv[1]).resolve()
if out.exists():
    shutil.rmtree(out)
out.mkdir(parents=True)
rng = random.Random(17)


def setup_file(name, data):
    b = base64.b64encode(data).decode()
    return f"printf '%s' '{b}' | base64 -d > {name}\n"


def plain(name, setup, args, stdout, exit_code=0, stderr=None):
    c = out / name
    c.mkdir()
    (c / "setup.sh").write_text("set -e\n" + setup)
    if args:
        (c / "args").write_text("\n".join(args) + "\n")
    (c / "stdout").write_bytes(stdout)
    (c / "exit").write_text(f"{exit_code}\n")
    if stderr is not None:
        (c / "stderr").write_text(stderr)


def piped(name, data, mode, stdout, exit_code=0, stderr=None):
    """Feed `data` on stdin through a driver: base64 of data | base64 -d | $BIN mode -"""
    c = out / name
    c.mkdir()
    b = base64.b64encode(data).decode()
    (c / "driver.sh").write_text(f"printf '%s' '{b}' | base64 -d | \"$BIN\" {mode} -\n")
    (c / "stdout").write_bytes(stdout)
    (c / "exit").write_text(f"{exit_code}\n")
    if stderr is not None:
        (c / "stderr").write_text(stderr)


def canonical_decode(text):
    t = text.strip(b" \t\r\n")
    try:
        d = base64.b64decode(t, validate=True)
    except binascii.Error:
        return None
    return d if base64.b64encode(d) == t else None


blob = bytes(rng.randrange(256) for _ in range(1000))
plain("enc-file", setup_file("in.bin", blob), ["enc", "in.bin"], base64.b64encode(blob) + b"\n")
for n in range(4):
    d = bytes(rng.randrange(256) for _ in range(n))
    plain(f"enc-len{n}", setup_file("in.bin", d), ["enc", "in.bin"], base64.b64encode(d) + b"\n")
big = "".join(f"{i}\n" for i in range(1, 60001)).encode()  # == `seq 1 60000`, ~350 KB
plain("crc-big", "seq 1 60000 > big.bin\n", ["crc", "big.bin"], f"{zlib.crc32(big):08x}\n".encode())
plain("crc-empty", ": > empty\n", ["crc", "empty"], f"{zlib.crc32(b''):08x}\n".encode())
piped("crc-stdin", b"123456789", "crc", b"cbf43926\n")
enc = base64.b64encode(blob) + b"\n"
piped("dec-stdin", enc, "dec", canonical_decode(enc))
for i, bad in enumerate([b"Zg=", b"Z@==", b"Zh==", b"Zm9=", b"abc", b"Zm9v\nYmFy"]):
    exp = canonical_decode(bad)
    if exp is None:
        piped(f"dec-bad{i}", bad, "dec", b"", 1, "cbase: invalid base64\n")
    else:
        piped(f"dec-bad{i}", bad, "dec", exp)
plain("missing", "", ["crc", "nope.bin"], b"", 1, "cbase: cannot read nope.bin: FileNotFound\n")
plain("usage", "", ["zip", "x"], b"", 2, "usage: cbase enc|dec|crc FILE   (FILE may be - for stdin)\n")
print("cases:", sorted(p.name for p in out.iterdir()))
