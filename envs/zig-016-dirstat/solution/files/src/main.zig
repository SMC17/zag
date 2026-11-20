const std = @import("std");
const dirstat = @import("dirstat");

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
        try err.writeAll("usage: dirstat DIR\n");
        try err.flush();
        return 2;
    }
    var root = std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true }) catch |e| {
        try err.print("dirstat: cannot open {s}: {s}\n", .{ args[1], @errorName(e) });
        try err.flush();
        return 1;
    };
    defer root.close(io);

    var report = dirstat.Report.init(gpa);
    defer report.deinit();
    dirstat.scan(gpa, io, root, &report) catch |e| {
        try err.print("dirstat: scan failed: {s}\n", .{@errorName(e)});
        try err.flush();
        return 1;
    };
    const rows = try report.sorted(gpa);
    defer gpa.free(rows);
    try dirstat.render(out, &report, rows);
    try out.flush();
    return 0;
}
