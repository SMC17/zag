# sunlitmoon/zig-016-dirstat

Port a Zig 0.15.2 directory-walking library and CLI to Zig 0.16.0 without changing behaviour.
It exercises the parts of 0.16 that moved file-system access onto `std.Io`:
- `std.fs.Dir` → `std.Io.Dir`;
- `walk` / `next(io)`;
- `statFile(io, path, .{})`;
- `openDir(io, ...)` / `close(io)`;
- the test helpers (`createDirPath`, `writeFile` with `io`);
- `main(init: std.process.Init)`;
- `std.Io.File` writers;
- `ArrayList` `.empty`.

The starting code is verified to build on 0.15.2 and fail on 0.16.0, and the reference port
passes on 0.16.0 (Linux containers). The hidden cases cover a random 60-file tree,
symlinks to a file, a directory and a dangling path, an empty tree, a missing path and wrong
usage. Their expectations come from `gen_cases.py`, which uses `os.scandir`/`lstat`, not the
reference port.
