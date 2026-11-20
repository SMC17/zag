const std = @import("std");
const runlist = @import("runlist");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;
    var err_buf: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &err_buf);
    const err = &stderr.interface;

    if (args.len != 2) {
        try err.writeAll("usage: runlist FILE\n");
        try err.flush();
        return 2;
    }
    const text = std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(1024 * 1024)) catch |e| {
        try err.print("runlist: cannot read {s}: {s}\n", .{ args[1], @errorName(e) });
        try err.flush();
        return 1;
    };
    defer gpa.free(text);

    var ran: usize = 0;
    var failed: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const argv = (try runlist.splitArgs(gpa, line)) orelse continue;
        defer gpa.free(argv);
        ran += 1;
        const o = runlist.runOne(gpa, io, argv);
        if (!runlist.succeeded(o)) failed += 1;
        try runlist.render(out, ran, o, argv);
    }
    try out.print("RAN {d} FAILED {d}\n", .{ ran, failed });
    try out.flush();
    return if (failed == 0) 0 else 1;
}
