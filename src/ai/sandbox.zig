//! Beneath-only file access, enforced by the kernel.
//!
//! A policy that matches paths as text can be defeated by the filesystem. The
//! string `notes/todo.md` is inside the workspace; if `notes` is a symbolic
//! link to `/etc`, the file it opens is not. Normalising the text does not
//! help, because the escape happens during resolution, after the check.
//!
//! So the check is not done in text. The workspace root is held open as a
//! directory, and every file beneath it is opened with `openat2` and
//! `RESOLVE_BENEATH`, which makes the kernel refuse any resolution that leaves
//! that directory: an absolute path, a `..` that climbs past the root, a
//! symbolic link pointing outside, and the magic links under `/proc`. The
//! answer comes from the same component of the system that would perform the
//! escape.
//!
//! `RESOLVE_BENEATH` needs Linux 5.6. Where it is missing, this module reports
//! that it cannot enforce containment rather than falling back to a text
//! comparison that looks like a control and is not one.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const supported = builtin.os.tag == .linux;

pub const Error = error{
    /// The path resolved outside the workspace root, or tried to.
    EscapesWorkspace,
    /// The kernel has no `openat2`. Containment cannot be enforced here, and
    /// this is reported rather than approximated.
    ContainmentUnavailable,
    /// The workspace root could not be opened.
    RootUnavailable,
    NotFound,
    AccessDenied,
    IsDirectory,
    OpenFailed,
};

/// `RESOLVE_BENEATH`: refuse any resolution that leaves the starting directory.
const RESOLVE_BENEATH: u64 = 0x08;
/// `RESOLVE_NO_MAGICLINKS`: refuse `/proc/self/fd/...` style links, which are
/// a documented way out of an otherwise contained resolution.
const RESOLVE_NO_MAGICLINKS: u64 = 0x02;

/// The kernel's `open_how`, passed to `openat2`.
const OpenHow = extern struct {
    flags: u64,
    mode: u64,
    resolve: u64,
};

pub const Mode = enum {
    read,
    write_truncate,
    write_create,

    fn flags(self: Mode) u64 {
        const O = linux.O;
        var f: O = switch (self) {
            .read => .{ .ACCMODE = .RDONLY },
            .write_truncate => .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            .write_create => .{ .ACCMODE = .WRONLY, .CREAT = true },
        };
        f.CLOEXEC = true;
        return @as(u32, @bitCast(f));
    }
};

/// A workspace root, held open so that every path is resolved from it.
pub const Root = struct {
    fd: linux.fd_t,
    path: []const u8,

    /// Open the workspace root. The directory handle is what every later
    /// resolution starts from, so a rename of the root after this point cannot
    /// redirect an open.
    pub fn open(path: []const u8, buffer: []u8) Error!Root {
        if (comptime !supported) return error.ContainmentUnavailable;
        if (path.len >= buffer.len) return error.RootUnavailable;
        @memcpy(buffer[0..path.len], path);
        buffer[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(buffer.ptr);

        var flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true };
        flags.CLOEXEC = true;
        const rc = linux.openat(linux.AT.FDCWD, path_z, flags, 0);
        if (linux.errno(rc) != .SUCCESS) return error.RootUnavailable;
        return .{ .fd = @intCast(rc), .path = path };
    }

    pub fn close(self: Root) void {
        if (comptime !supported) return;
        _ = linux.close(self.fd);
    }

    /// Open a path beneath the root. The kernel refuses anything that would
    /// leave it.
    ///
    /// `relative` is interpreted from the root. A leading `/` is not a way to
    /// reach the filesystem root: `RESOLVE_BENEATH` rejects an absolute path,
    /// so the caller's own text is never trusted to be relative.
    pub fn openFile(self: Root, relative: []const u8, mode: Mode, buffer: []u8) Error!linux.fd_t {
        if (comptime !supported) return error.ContainmentUnavailable;
        if (relative.len == 0) return error.NotFound;
        if (relative.len >= buffer.len) return error.EscapesWorkspace;
        @memcpy(buffer[0..relative.len], relative);
        buffer[relative.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(buffer.ptr);

        var how: OpenHow = .{
            .flags = mode.flags(),
            .mode = if (mode == .read) 0 else 0o600,
            .resolve = RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS,
        };
        const rc = linux.syscall4(
            .openat2,
            @as(usize, @bitCast(@as(isize, self.fd))),
            @intFromPtr(path_z),
            @intFromPtr(&how),
            @sizeOf(OpenHow),
        );
        return switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            // The kernel refused to leave the root. This is the control doing
            // its job, and it is reported as such rather than as "not found".
            .XDEV, .LOOP => error.EscapesWorkspace,
            .NOSYS => error.ContainmentUnavailable,
            .NOENT => error.NotFound,
            .ACCES, .PERM => error.AccessDenied,
            .ISDIR => error.IsDirectory,
            else => error.OpenFailed,
        };
    }

    /// Read a whole file from beneath the root.
    pub fn readFile(
        self: Root,
        arena: std.mem.Allocator,
        relative: []const u8,
        limit: usize,
    ) (Error || std.mem.Allocator.Error)![]const u8 {
        var path_buffer: [4096]u8 = undefined;
        const fd = try self.openFile(relative, .read, &path_buffer);
        defer _ = linux.close(fd);

        var out: std.ArrayList(u8) = .empty;
        var chunk: [64 * 1024]u8 = undefined;
        while (out.items.len < limit) {
            const rc = linux.read(fd, &chunk, chunk.len);
            if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
            if (rc == 0) break;
            try out.appendSlice(arena, chunk[0..rc]);
        }
        return out.items;
    }

    /// Write a whole file beneath the root, creating it if needed.
    pub fn writeFile(self: Root, relative: []const u8, bytes: []const u8) Error!void {
        var path_buffer: [4096]u8 = undefined;
        const fd = try self.openFile(relative, .write_truncate, &path_buffer);
        defer _ = linux.close(fd);

        var written: usize = 0;
        while (written < bytes.len) {
            const rc = linux.write(fd, bytes[written..].ptr, bytes.len - written);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR, .AGAIN => continue,
                else => return error.OpenFailed,
            }
            if (rc == 0) return error.OpenFailed;
            written += rc;
        }
    }

    /// True when the path can be opened beneath the root. Used by a check that
    /// wants an answer without holding the file open.
    pub fn contains(self: Root, relative: []const u8) bool {
        var path_buffer: [4096]u8 = undefined;
        const fd = self.openFile(relative, .read, &path_buffer) catch return false;
        _ = linux.close(fd);
        return true;
    }
};

/// Whether this kernel can enforce containment. Reported by `zag doctor`, so a
/// person can tell whether the control is in force on their machine.
pub fn available() bool {
    if (comptime !supported) return false;
    var buffer: [8]u8 = undefined;
    const root = Root.open(".", &buffer) catch return false;
    defer root.close();
    var path_buffer: [8]u8 = undefined;
    _ = root.openFile(".", .read, &path_buffer) catch |err| return err != error.ContainmentUnavailable;
    return true;
}

const testing = std.testing;

test "a path beneath the root opens, and one above it does not" {
    if (comptime !supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/inside.txt", .{root_path}),
        .data = "beneath the root",
    });

    var buffer: [4096]u8 = undefined;
    const root = Root.open(root_path, &buffer) catch return error.SkipZigTest;
    defer root.close();

    const inside = root.readFile(arena, "inside.txt", 1 << 20) catch |err| switch (err) {
        error.ContainmentUnavailable => return error.SkipZigTest,
        else => return err,
    };
    try testing.expectEqualStrings("beneath the root", inside);

    // Climbing out with `..`, and naming an absolute path, are both refused by
    // the kernel rather than by a string comparison here.
    try testing.expectError(error.EscapesWorkspace, root.readFile(arena, "../../../etc/passwd", 1 << 20));
    try testing.expectError(error.EscapesWorkspace, root.readFile(arena, "/etc/passwd", 1 << 20));
    try testing.expect(!root.contains("../.."));
    try testing.expect(root.contains("inside.txt"));
}

test "a symbolic link pointing out of the workspace is refused" {
    if (comptime !supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // A link that leaves the workspace. Its text says "escape", which is
    // inside; what it resolves to is not. This is the case a path check
    // written in text cannot see.
    const link_path = try std.fmt.allocPrintSentinel(arena, "{s}/escape", .{root_path}, 0);
    const target = "/etc";
    const rc = linux.symlink(target, link_path.ptr);
    if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;

    var buffer: [4096]u8 = undefined;
    const root = Root.open(root_path, &buffer) catch return error.SkipZigTest;
    defer root.close();

    const result = root.readFile(arena, "escape/passwd", 1 << 20);
    try testing.expectError(error.EscapesWorkspace, result);
}

test "writing lands beneath the root and nowhere else" {
    if (comptime !supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var buffer: [4096]u8 = undefined;
    const root = Root.open(root_path, &buffer) catch return error.SkipZigTest;
    defer root.close();

    root.writeFile("written.txt", "by the executor") catch |err| switch (err) {
        error.ContainmentUnavailable => return error.SkipZigTest,
        else => return err,
    };
    const read_back = try root.readFile(arena, "written.txt", 1 << 20);
    try testing.expectEqualStrings("by the executor", read_back);

    try testing.expectError(error.EscapesWorkspace, root.writeFile("../outside.txt", "should not land"));
}
