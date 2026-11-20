const std = @import("std");
const runlist = @import("runlist");

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
        try err.writeAll("usage: runlist FILE\n");
        try err.flush();
        return 2;
    }
    const text = std.fs.cwd().readFileAlloc(gpa, args[1], 1024 * 1024) catch |e| {
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
        const o = runlist.runOne(gpa, argv);
        if (!runlist.succeeded(o)) failed += 1;
        try runlist.render(out, ran, o, argv);
    }
    try out.print("RAN {d} FAILED {d}\n", .{ ran, failed });
    try out.flush();
    return if (failed == 0) 0 else 1;
}
