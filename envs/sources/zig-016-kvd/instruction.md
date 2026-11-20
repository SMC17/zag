`/app` is a small Zig library and server, `kvd`, written for Zig 0.15.2. It is an in-memory
key-value store, served over TCP on 127.0.0.1 with a line protocol described at the top of
`src/kvd.zig`. The machine has Zig 0.16.0 installed, and the project no longer builds.

Port it to Zig 0.16.0.

- `zig build`, `zig build test` and `zig build run -- <port>` must work from `/app`.
- Keep the public API of `src/kvd.zig` (`Store` with `init`, `deinit`, `set`, `get`, `del`,
  `count`; `Action`; `handleLine`; `serveConnection`) and the protocol exactly as documented.
- Keep the behaviour of `src/main.zig`:
  - it prints `LISTENING <port>` once it is accepting connections;
  - it serves one connection at a time, keeping the store across connections;
  - it exits 0 after `SHUTDOWN`;
  - it exits 2 on wrong usage or an invalid port, and 1 if it cannot listen;
  - its messages are unchanged.
- The work will be checked against tests and a client you have not seen.
