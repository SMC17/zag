const std = @import("std");
const cbase = @import("cbase");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;
    var err_buf: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &err_buf);
    const err = &stderr.interface;

    if (args.len != 3 or !(std.mem.eql(u8, args[1], "enc") or std.mem.eql(u8, args[1], "dec") or std.mem.eql(u8, args[1], "crc"))) {
        try err.writeAll("usage: cbase enc|dec|crc FILE   (FILE may be - for stdin)\n");
        try err.flush();
        return 2;
    }
    const limit = 64 * 1024 * 1024;
    var in_buf: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buf);
    const input = (if (std.mem.eql(u8, args[2], "-"))
        stdin.interface.allocRemaining(gpa, .limited(limit))
    else
        std.Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .limited(limit))) catch |e| {
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
