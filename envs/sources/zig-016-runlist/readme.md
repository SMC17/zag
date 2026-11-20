# sunlitmoon/zig-016-runlist

Port a Zig 0.15.2 command runner to Zig 0.16.0 without changing behaviour. It exercises the
0.16 changes to child processes:
- `std.process.Child.run(.{ .allocator, .argv, .max_output_bytes })` →
  `std.process.run(gpa, io, .{ .argv, .stdout_limit, .stderr_limit })`;
- the `Term` tags were renamed (`.Exited` → `.exited`, `.Signal` → `.signal`);
- the signal is now `std.posix.SIG`, not an integer.

It also exercises `main(init: std.process.Init)`, `std.Io` file reads and writers, and
`ArrayList` `.empty`.

The hidden cases cover:
- exit codes and byte and line counts;
- SIGTERM and SIGKILL;
- a missing program;
- 1 MB of output;
- comment-only and unterminated list files;
- a missing list file and wrong usage.

Their expectations come from `gen_cases.py`, which uses Python `subprocess` and is run in a
Debian container. They do not come from the reference port.
