const std = @import("std");
const ledger = @import("ledger");

pub fn main() !u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var out_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&out_buf);
    const out = &stdout.interface;
    var err_buf: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&err_buf);
    const err = &stderr.interface;

    if (args.len != 2) {
        try err.writeAll("usage: ledger FILE\n");
        try err.flush();
        return 2;
    }

    const text = std.fs.cwd().readFileAlloc(gpa, args[1], 16 * 1024 * 1024) catch |e| {
        try err.print("ledger: cannot read {s}: {s}\n", .{ args[1], @errorName(e) });
        try err.flush();
        return 1;
    };
    defer gpa.free(text);

    var book = ledger.Book.init(gpa);
    defer book.deinit();
    var bad: usize = 0;
    book.applyText(text, &bad) catch |e| {
        try err.print("ledger: line {d}: {s}\n", .{ bad, @errorName(e) });
        try err.flush();
        return 1;
    };

    const positions = try book.sorted(gpa);
    defer gpa.free(positions);
    try ledger.render(out, positions);
    try out.flush();
    return 0;
}
