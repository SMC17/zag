`/app` is a small Zig library and command-line tool, `dirstat`, written for Zig 0.15.2. It walks
a directory tree and totals file counts and sizes by extension. The machine has Zig 0.16.0
installed, and the project no longer builds.

Port it to Zig 0.16.0.

- `zig build`, `zig build test` and `zig build run -- <dir>` must work from `/app`.
- Keep the public API of `src/dirstat.zig` (`ExtStat`, `Report` with `init`, `deinit`,
  `extensionOf`, `add`, `sorted`, and `scan`, `render`) and its behaviour. Where the 0.16
  standard library needs an `std.Io` or a different directory type, `scan` should take
  `(allocator, io: std.Io, root: std.Io.Dir, report)`.
- Keep the command-line behaviour of `src/main.zig`: same output, same exit codes (0 on
  success, 1 when the directory cannot be opened or scanned, 2 on wrong usage), same messages.
- Symbolic links are counted as skipped and never followed. Do not change that.
- The work will be checked against tests and inputs you have not seen.
