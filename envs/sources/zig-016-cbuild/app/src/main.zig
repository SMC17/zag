const std = @import("std");
const cbase = @import("cbase");

pub fn main() !u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var out_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&out_buf);
    const out = &stdout.interface;
    var err_buf: [256]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&err_buf);
    const err = &stderr.interface;

    if (args.len != 3 or !(std.mem.eql(u8, args[1], "enc") or std.mem.eql(u8, args[1], "dec") or std.mem.eql(u8, args[1], "crc"))) {
        try err.writeAll("usage: cbase enc|dec|crc FILE   (FILE may be - for stdin)\n");
        try err.flush();
        return 2;
    }
    const limit = 64 * 1024 * 1024;
    const input = (if (std.mem.eql(u8, args[2], "-"))
        std.fs.File.stdin().readToEndAlloc(gpa, limit)
    else
        std.fs.cwd().readFileAlloc(gpa, args[2], limit)) catch |e| {
        try err.print("cbase: cannot read {s}: {s}\n", .{ args[2], @errorName(e) });
        try err.flush();
        return 1;
    };
    defer gpa.free(input);

    if (args[1][0] == 'e') {
        const e = try cbase.encodeAlloc(gpa, input);
        defer gpa.free(e);
        try out.print("{s}\n", .{e});
    } else if (args[1][0] == 'd') {
        const d = cbase.decodeAlloc(gpa, input) catch |e| switch (e) {
            error.InvalidBase64 => {
                try err.writeAll("cbase: invalid base64\n");
                try err.flush();
                return 1;
            },
            else => |x| return x,
        };
        defer gpa.free(d);
        try out.writeAll(d);
    } else {
        try out.print("{x:0>8}\n", .{cbase.crc32(input)});
    }
    try out.flush();
    return 0;
}
