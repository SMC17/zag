`/app` is a small Zig library and command-line tool, `ledger`, written for Zig 0.15.2.
The machine has Zig 0.16.0 installed, and the project no longer builds.

Port it to Zig 0.16.0.

- `zig build`, `zig build test` and `zig build run -- sample.csv` must work from `/app`.
- Keep the public API of `src/ledger.zig` (`Fill`, `Position`, `ParseError`, `parseFill`,
  `Book` with `init`, `deinit`, `apply`, `applyText`, `sorted`, and `render`) and its behaviour.
- Keep the command-line behaviour of `src/main.zig`: same output, same exit codes
  (0 on success, 1 on unreadable file or bad input line, 2 on wrong usage), same error messages.
- Do not change behaviour to make the port easier. The work will be checked against
  tests and inputs you have not seen.
