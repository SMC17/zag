`/app` is a Zig project, `cbase`, written for Zig 0.15.2. It builds:
- a small C library (`c/`: base64 and CRC-32) as a static library, installed with its headers;
- a Zig module that wraps that library through `@cImport`;
- a command-line tool on top of the module.

The machine has Zig 0.16.0 installed, and the project no longer builds.

Port it to Zig 0.16.0.

- `zig build`, `zig build test` and `zig build run -- <enc|dec|crc> <file|->` must work from `/app`.
- `zig build` must still install `zig-out/lib/libcbase_c.a`, `zig-out/include/b64.h`,
  `zig-out/include/crc32.h` and `zig-out/bin/cbase`. The executable and the tests must link
  the static library.
- Keep the C library's behaviour (including rejecting non-canonical base64), the public API of
  `src/cbase.zig` (`encodeAlloc`, `decodeAlloc`, `DecodeError`, `crc32`, `crc32Update`), and
  the command-line behaviour of `src/main.zig`: output, exit codes (0, 1 on unreadable input or
  invalid base64, 2 on wrong usage) and messages.
- The work will be checked against tests and inputs you have not seen.
