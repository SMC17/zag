"""Generate hidden CLI cases for zig-016-port with an implementation independent
of the Zig reference (so the oracle is not graded by itself). Deterministic: seed 17."""
import random, pathlib, sys
out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
rng = random.Random(17)

def fold(lines):
    book = {}
    for n, raw in enumerate(lines, 1):
        line = raw.strip(" \t\r")
        if not line or line.startswith("#"): continue
        f = [x.strip(" \t\r") for x in line.split(",")]
        if len(f) != 3: return None, n, "MissingField" if len(f) < 3 else "TrailingField"
        s, q, p = f
        if not s: return None, n, "EmptySymbol"
        try: q, p = int(q), int(p)
        except ValueError: return None, n, "BadNumber"
        if p < 0: return None, n, "BadNumber"
        nq, c = book.get(s, (0, 0)); book[s] = (nq + q, c + q * p)
    return book, None, None

def render(book):
    rows = sorted(book.items(), key=lambda kv: kv[0].encode())
    return "".join(f"{s} {q} {c}\n" for s, (q, c) in rows) + f"TOTAL {sum(c for _, c in book.values())}\n"

syms = ["AAPL", "MSFT", "NVDA", "BRK.B", "ES_F", "aapl", "Z", "SPY", "QQQ", "TLT"]
cases = {}
cases["case1"] = [f"{rng.choice(syms)},{rng.randint(-500, 500)},{rng.randint(1, 900000)}" for _ in range(400)]
c2 = ["# header", ""] + [f"  {rng.choice(syms)} , {rng.randint(-50, 50)} , {rng.randint(0, 99999)}\r" for _ in range(60)]
c2.insert(30, "   "); c2.insert(45, "# mid comment")
cases["case2"] = c2
cases["case3"] = ["AAPL,1,100", "# ok", "MSFT,2,3.5", "NVDA,1,1"]
cases["case4"] = []
for name, lines in cases.items():
    (out / f"{name}.csv").write_text("\n".join(lines) + ("\n" if lines else ""))
    book, bad, err = fold(lines)
    if book is None:
        (out / f"{name}.exit").write_text("1\n"); (out / f"{name}.stderr").write_text(f"ledger: line {bad}: {err}\n"); (out / f"{name}.stdout").write_text("")
    else:
        (out / f"{name}.exit").write_text("0\n"); (out / f"{name}.stdout").write_text(render(book))
print("wrote", sorted(p.name for p in out.iterdir()))
