`/app` is a small Zig library and command-line tool, `runlist`, written for Zig 0.15.2. It runs
each command in a list file, one after another and without a shell, and reports how each
ended. The machine has Zig 0.16.0 installed, and the project no longer builds.

Port it to Zig 0.16.0.

- `zig build`, `zig build test` and `zig build run -- <list-file>` must work from `/app`.
- Keep the public API of `src/runlist.zig` (`Outcome`, `splitArgs`, `runOne`, `succeeded`,
  `render`) and its behaviour. Where the 0.16 standard library needs an `std.Io`, `runOne`
  should take `(allocator, io: std.Io, argv)`.
- Keep the command-line behaviour of `src/main.zig`: the same output lines, the same summary,
  the same exit codes (0 if every command exited 0; 1 if any did not, or if the list cannot be
  read; 2 on wrong usage), and the same messages.
- A command killed by a signal is reported as `signal=N`, never as an exit code.
- The work will be checked against tests and inputs you have not seen.
