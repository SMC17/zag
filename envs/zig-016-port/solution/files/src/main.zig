const std = @import("std");
const ledger = @import("ledger");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;
    var err_buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &err_buf);
    const err = &stderr.interface;

    if (args.len != 2) {
        try err.writeAll("usage: ledger FILE\n");
        try err.flush();
        return 2;
    }

    const text = std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(16 * 1024 * 1024)) catch |e| {
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
