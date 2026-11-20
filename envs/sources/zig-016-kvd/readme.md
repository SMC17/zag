# sunlitmoon/zig-016-kvd

Port a Zig 0.15.2 TCP key-value server to Zig 0.16.0 without changing its protocol. It
exercises:
- networking moving into `std.Io.net`:
  - `std.net.Address.parseIp4` → `std.Io.net.IpAddress.parse`;
  - `listen(io, ...)` and `accept(io)` returning a stream;
  - `stream.reader(io, buf)` with a `.interface` field instead of an `interface()` method;
  - `close(io)` and `server.deinit(io)`;
  - `server.socket.address.getPort()`;
- the `std.mem.trimLeft` → `trimStart` rename;
- `.empty` for unmanaged hash maps;
- `main(init)` and `std.Io.File` writers.

The verifier plays scripted client sessions against the agent's server over real TCP
(`driver.sh`), including state across connections, protocol errors, length limits, CRLF
input, a random 400-command workload and SHUTDOWN. The expected transcripts come from a
pure-Python model of the protocol in `gen_cases.py`, not from the reference port. A server
that ignores SHUTDOWN is caught, because the driver checks that the process exits.
