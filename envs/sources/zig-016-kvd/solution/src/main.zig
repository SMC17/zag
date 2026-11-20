const std = @import("std");
const kvd = @import("kvd");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;
    var err_buf: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &err_buf);
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

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var server = addr.listen(io, .{ .reuse_address = true }) catch |e| {
        try err.print("kvd: cannot listen on port {d}: {s}\n", .{ port, @errorName(e) });
        try err.flush();
        return 1;
    };
    defer server.deinit(io);
    try out.print("LISTENING {d}\n", .{server.socket.address.getPort()});
    try out.flush();

    var store = kvd.Store.init(gpa);
    defer store.deinit();
    while (true) {
        const stream = try server.accept(io);
        defer stream.close(io);
        var rbuf: [1024]u8 = undefined;
        var wbuf: [1024]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        var writer = stream.writer(io, &wbuf);
        const act = kvd.serveConnection(&store, &reader.interface, &writer.interface) catch .close;
        if (act == .shutdown) return 0;
    }
}
