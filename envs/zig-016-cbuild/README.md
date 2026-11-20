# sunlitmoon/zig-016-cbuild

Port a Zig 0.15.2 project that builds and links a C static library to Zig 0.16.0. It
exercises the 0.16 build-system changes for C:
- `addCSourceFiles`, `addIncludePath` and `linkLibrary` move from the compile step to its
  `root_module`;
- `linkLibC()` becomes `.link_libc = true` on the module;
- `installHeader` stays on the compile step.

It also exercises `@cImport` (which still works), stdin via `std.Io.File.stdin().readerStreaming(io, ...)`, `main(init)` and
`std.Io` file reads.

`src/cbase.zig` itself needs no change, because it uses nothing 0.16 removed. The port work is
in `build.zig` and `src/main.zig`, so the hidden unit tests alone do not separate a port from no port. The CLI build, the agent's
own build and the installed-output check do. The verifier compiles the agent's Zig module with the agent's own C sources. A
`post_build.sh` check makes sure the static library and headers are still installed. A hack
that compiles the C straight into the executable is caught there. The hidden cases cover
RFC 4648 vectors, random data checked against `std.base64` and `std.hash.Crc32`, a 300 KB
CRC, stdin input and non-canonical padding. Their expectations come from Python `base64` and
`zlib.crc32`.
