//! runlist: run each command in a list, sequentially, without a shell, and report how it ended.
const std = @import("std");

pub const Outcome = union(enum) {
    /// Exit code, bytes written to stdout and stderr, and newline count in stdout.
    exited: struct { code: u8, out_bytes: usize, err_bytes: usize, out_lines: usize },
    /// Terminated by a signal (its number).
    signaled: u32,
    /// Could not be started (for example the program does not exist).
    spawn_failed: anyerror,
};

/// Splits a command line on spaces and tabs. No quoting, no globbing, no shell.
/// Returns null for blank lines and lines starting with '#'. Caller frees the slice.
pub fn splitArgs(allocator: std.mem.Allocator, line: []const u8) !?[]const []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    var out: std.ArrayList([]const u8) = .{};
    errdefer out.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (it.next()) |tok| try out.append(allocator, tok);
    return try out.toOwnedSlice(allocator);
}

pub fn runOne(allocator: std.mem.Allocator, argv: []const []const u8) Outcome {
    const r = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 4 * 1024 * 1024,
    }) catch |e| return .{ .spawn_failed = e };
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    return switch (r.term) {
        .Exited => |code| .{ .exited = .{
            .code = code,
            .out_bytes = r.stdout.len,
            .err_bytes = r.stderr.len,
            .out_lines = std.mem.count(u8, r.stdout, "\n"),
        } },
        .Signal => |sig| .{ .signaled = sig },
        else => .{ .spawn_failed = error.UnexpectedTermination },
    };
}

/// True when the command counts as successful: it exited with code 0.
pub fn succeeded(o: Outcome) bool {
    return switch (o) {
        .exited => |e| e.code == 0,
        else => false,
    };
}

/// One line per command: "<n> exit=<code> out=<bytes> err=<bytes> lines=<n> <cmd>",
/// "<n> signal=<num> <cmd>" or "<n> spawn_error=<ErrorName> <cmd>". `cmd` is the argv joined by single spaces.
pub fn render(w: *std.Io.Writer, index: usize, o: Outcome, argv: []const []const u8) !void {
    try w.print("{d} ", .{index});
    switch (o) {
        .exited => |e| try w.print("exit={d} out={d} err={d} lines={d}", .{ e.code, e.out_bytes, e.err_bytes, e.out_lines }),
        .signaled => |s| try w.print("signal={d}", .{s}),
        .spawn_failed => |e| try w.print("spawn_error={s}", .{@errorName(e)}),
    }
    for (argv) |a| try w.print(" {s}", .{a});
    try w.writeByte('\n');
}
