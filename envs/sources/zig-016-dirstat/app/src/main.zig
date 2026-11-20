const std = @import("std");
const dirstat = @import("dirstat");

pub fn main() !u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var out_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&out_buf);
    const out = &stdout.interface;
    var err_buf: [512]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&err_buf);
    const err = &stderr.interface;

    if (args.len != 2) {
        try err.writeAll("usage: dirstat DIR\n");
        try err.flush();
        return 2;
    }
    var root = std.fs.cwd().openDir(args[1], .{ .iterate = true }) catch |e| {
        try err.print("dirstat: cannot open {s}: {s}\n", .{ args[1], @errorName(e) });
        try err.flush();
        return 1;
    };
    defer root.close();

    var report = dirstat.Report.init(gpa);
    defer report.deinit();
    dirstat.scan(gpa, root, &report) catch |e| {
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
