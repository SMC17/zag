const std = @import("std");
const kvd = @import("kvd");

pub fn main() !u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var out_buf: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&out_buf);
    const out = &stdout.interface;
    var err_buf: [256]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&err_buf);
    const err = &stderr.interface;

    if (args.len != 2) {
        try err.writeAll("usage: kvd PORT\n");
        try err.flush();
        return 2;
    }
    const port = std.fmt.parseInt(u16, args[1], 10) catch {
        try err.print("kvd: invalid port: {s}\n", .{args[1]});
        try err.flush();
        return 2;
    };

    const addr = try std.net.Address.parseIp4("127.0.0.1", port);
    var server = addr.listen(.{ .reuse_address = true }) catch |e| {
        try err.print("kvd: cannot listen on port {d}: {s}\n", .{ port, @errorName(e) });
        try err.flush();
        return 1;
    };
    defer server.deinit();
    try out.print("LISTENING {d}\n", .{server.listen_address.getPort()});
    try out.flush();

    var store = kvd.Store.init(gpa);
    defer store.deinit();
    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();
        var rbuf: [1024]u8 = undefined;
        var wbuf: [1024]u8 = undefined;
        var reader = conn.stream.reader(&rbuf);
        var writer = conn.stream.writer(&wbuf);
        const act = kvd.serveConnection(&store, reader.interface(), &writer.interface) catch .close;
        if (act == .shutdown) return 0;
    }
}
