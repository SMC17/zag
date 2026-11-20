# sunlitmoon/zig-016-port

Port a Zig 0.15.2 library + CLI to Zig 0.16.0 without changing behaviour.
Zig 0.16 rewrote I/O (`std.Io`), `main` (`std.process.Init`), the build API and container
defaults, and frontier models trained mostly on older Zig get these wrong.

- Agent image: Ubuntu 24.04 + Zig 0.16.0 (sha256-pinned). Starting code in `environment/app/`
  is verified to build on Zig 0.15.2 and fail on 0.16.0.
- Verifier: separate container, no network, binary reward. See `SOUNDNESS.md`.
- Hidden CLI expectations come from an independent Python implementation (`../scripts/gen_cases.py`).
