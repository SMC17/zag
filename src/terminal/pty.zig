//! Pseudoterminals.
//!
//! A pseudoterminal is a pair of connected devices that lets a program behave
//! as though a person were typing at a terminal. The workbench needs a real one
//! — not a pipe — because programs change their behaviour when they are not on
//! a terminal, and the whole point is to run the user's real shell.
//!
//! Platform support is explicit rather than implied. Linux is implemented here
//! with direct syscalls and no libc dependency. macOS and Windows have their
//! own paths (`posix_openpt` and ConPTY); the seam is here so that adding them
//! does not disturb anything above.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const Error = error{
    UnsupportedPlatform,
    OpenFailed,
    ConfigureFailed,
    ForkFailed,
    ExecFailed,
    ReadFailed,
    WriteFailed,
    ClockFailed,
};

pub const Size = struct {
    columns: u16,
    rows: u16,
    /// Pixel size, when the interface knows it. Some programs use it.
    width_pixels: u16 = 0,
    height_pixels: u16 = 0,
};

pub const Exit = union(enum) {
    exited: u8,
    signalled: u8,
    unknown,

    pub fn status(self: Exit) ?u8 {
        return switch (self) {
            .exited => |code| code,
            else => null,
        };
    }
};

pub const supported = builtin.os.tag == .linux;

pub const Pty = struct {
    master: std.posix.fd_t,
    slave_path_buffer: [64]u8 = undefined,
    slave_path_len: usize = 0,

    pub fn slavePath(self: *const Pty) []const u8 {
        return self.slave_path_buffer[0..self.slave_path_len];
    }

    /// The same path as a C string, for `open` in the child.
    pub fn slavePathZ(self: *const Pty) [*:0]const u8 {
        return @ptrCast(&self.slave_path_buffer);
    }

    /// Open a new pseudoterminal pair.
    pub fn open(size: Size) Error!Pty {
        if (comptime !supported) return error.UnsupportedPlatform;

        // The master is opened non-blocking: a read that waits forever is how a
        // terminal user interface freezes, and how a test hangs.
        const flags: linux.O = .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true };
        const rc = linux.open("/dev/ptmx", flags, 0);
        if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
        const master: std.posix.fd_t = @intCast(rc);
        errdefer _ = linux.close(master);

        // Unlock the pair and find the slave's number.
        var unlock: c_int = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) {
            return error.ConfigureFailed;
        }
        var number: c_uint = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&number))) != .SUCCESS) {
            return error.ConfigureFailed;
        }

        var pty: Pty = .{ .master = master };
        // The path is written with an explicit terminator: it is handed to
        // `open` in the child as a C string, and an un-terminated buffer means
        // the child opens whatever follows it in memory, or nothing at all.
        const path = std.fmt.bufPrint(&pty.slave_path_buffer, "/dev/pts/{d}\x00", .{number}) catch return error.ConfigureFailed;
        pty.slave_path_len = path.len - 1;

        try pty.setSize(size);
        return pty;
    }

    pub fn setSize(self: *const Pty, size: Size) Error!void {
        if (comptime !supported) return error.UnsupportedPlatform;
        const winsize = std.posix.winsize{
            .col = size.columns,
            .row = size.rows,
            .xpixel = size.width_pixels,
            .ypixel = size.height_pixels,
        };
        if (linux.errno(linux.ioctl(self.master, linux.T.IOCSWINSZ, @intFromPtr(&winsize))) != .SUCCESS) {
            return error.ConfigureFailed;
        }
    }

    pub fn getSize(self: *const Pty) Error!Size {
        if (comptime !supported) return error.UnsupportedPlatform;
        var winsize: std.posix.winsize = undefined;
        if (linux.errno(linux.ioctl(self.master, linux.T.IOCGWINSZ, @intFromPtr(&winsize))) != .SUCCESS) {
            return error.ConfigureFailed;
        }
        return .{
            .columns = winsize.col,
            .rows = winsize.row,
            .width_pixels = winsize.xpixel,
            .height_pixels = winsize.ypixel,
        };
    }

    /// Wait until there is something to read, or the timeout passes.
    /// Returns true when the master is readable.
    pub fn waitReadable(self: *const Pty, timeout_ms: i32) bool {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.master,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, timeout_ms) catch return false;
        return ready > 0;
    }

    pub fn read(self: *const Pty, buffer: []u8) Error!usize {
        const rc = linux.read(self.master, buffer.ptr, buffer.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            // The child closed its end: the session is over, not an error.
            .IO => return 0,
            .INTR, .AGAIN => return 0,
            else => return error.ReadFailed,
        }
    }

    pub fn write(self: *const Pty, bytes: []const u8) Error!usize {
        const rc = linux.write(self.master, bytes.ptr, bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            else => return error.WriteFailed,
        }
    }

    pub fn close(self: *const Pty) void {
        _ = linux.close(self.master);
    }

    /// Start a program attached to the slave end.
    ///
    /// `argv` and `envp` are null-terminated because that is what `execve`
    /// takes; building them is the caller's job so that the environment policy
    /// stays in the policy engine rather than hidden in here.
    pub fn spawn(
        self: *const Pty,
        path: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
        working_directory: ?[*:0]const u8,
    ) Error!Child {
        if (comptime !supported) return error.UnsupportedPlatform;

        const pid_rc = linux.fork();
        switch (linux.errno(pid_rc)) {
            .SUCCESS => {},
            else => return error.ForkFailed,
        }
        const pid: std.posix.pid_t = @intCast(pid_rc);

        if (pid == 0) {
            // Child. Nothing here may allocate or return: on any failure the
            // child exits with a distinct status so the parent can report it.
            if (linux.errno(linux.setsid()) != .SUCCESS) linux.exit(126);

            const slave_flags: linux.O = .{ .ACCMODE = .RDWR };
            const slave_rc = linux.open(@ptrCast(&self.slave_path_buffer), slave_flags, 0);
            if (linux.errno(slave_rc) != .SUCCESS) linux.exit(126);
            const slave: i32 = @intCast(slave_rc);

            _ = linux.ioctl(slave, linux.T.IOCSCTTY, 0);
            _ = linux.dup2(slave, 0);
            _ = linux.dup2(slave, 1);
            _ = linux.dup2(slave, 2);
            if (slave > 2) _ = linux.close(slave);
            _ = linux.close(self.master);

            if (working_directory) |dir| {
                if (linux.errno(linux.chdir(dir)) != .SUCCESS) linux.exit(125);
            }

            _ = linux.execve(path, argv, envp);
            linux.exit(127);
        }

        return .{ .pid = pid };
    }
};

pub const Child = struct {
    pid: std.posix.pid_t,
    exit: ?Exit = null,

    /// Wait for the child to finish.
    pub fn wait(self: *Child) Exit {
        if (self.exit) |exit| return exit;
        var status: u32 = 0;
        const rc = linux.waitpid(self.pid, &status, 0);
        if (linux.errno(rc) != .SUCCESS) return .unknown;
        const exit = decodeStatus(status);
        self.exit = exit;
        return exit;
    }

    /// Check whether the child has finished, without blocking.
    ///
    /// Returns null when the answer is not known — the child is still running,
    /// or something else already reaped it (a test runner, an init process).
    /// "I cannot tell" must not be reported as "it finished", or a caller stops
    /// reading output that has not arrived yet.
    pub fn poll(self: *Child) ?Exit {
        if (self.exit) |exit| return exit;
        var status: u32 = 0;
        const rc = linux.wait4(self.pid, &status, 1, null); // WNOHANG
        if (linux.errno(rc) != .SUCCESS) return null;
        if (rc == 0) return null;
        const exit = decodeStatus(status);
        self.exit = exit;
        return exit;
    }

    /// Signal the whole session created by `setsid`, including grandchildren.
    /// Killing only the shell leaves pipelines and background jobs behind.
    pub fn signalGroup(self: Child, sig: u8) void {
        _ = linux.kill(-self.pid, @enumFromInt(sig));
    }

    fn decodeStatus(status: u32) Exit {
        if (status & 0x7f == 0) return .{ .exited = @intCast((status >> 8) & 0xff) };
        if (status & 0x7f != 0x7f) return .{ .signalled = @intCast(status & 0x7f) };
        return .unknown;
    }
};

/// Current monotonic time for deadlines and elapsed durations.
pub fn monotonicNanos() Error!i64 {
    if (comptime !supported) return error.UnsupportedPlatform;
    var value: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &value)) != .SUCCESS) return error.ClockFailed;
    return @as(i64, @intCast(value.sec)) * std.time.ns_per_s + @as(i64, @intCast(value.nsec));
}

/// Build a null-terminated argument vector in `arena`.
pub fn buildArgv(arena: std.mem.Allocator, args: []const []const u8) ![:null]?[*:0]const u8 {
    var list = try arena.allocSentinel(?[*:0]const u8, args.len, null);
    for (args, 0..) |arg, i| list[i] = (try arena.dupeZ(u8, arg)).ptr;
    return list;
}

/// Build an environment vector from `key=value` pairs.
pub fn buildEnvp(arena: std.mem.Allocator, pairs: []const []const u8) ![:null]?[*:0]const u8 {
    var list = try arena.allocSentinel(?[*:0]const u8, pairs.len, null);
    for (pairs, 0..) |pair, i| list[i] = (try arena.dupeZ(u8, pair)).ptr;
    return list;
}

const testing = std.testing;

test "argument and environment vectors are null terminated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try buildArgv(arena, &.{ "/bin/sh", "-c", "echo hi" });
    try testing.expectEqualStrings("/bin/sh", std.mem.span(argv[0].?));
    try testing.expectEqualStrings("echo hi", std.mem.span(argv[2].?));
    try testing.expect(argv[3] == null);

    const envp = try buildEnvp(arena, &.{ "TERM=xterm-256color", "ZAG=1" });
    try testing.expectEqualStrings("TERM=xterm-256color", std.mem.span(envp[0].?));
    try testing.expect(envp[2] == null);
}

test "exit status decoding" {
    try testing.expectEqual(@as(u8, 0), Child.decodeStatus(0).exited);
    try testing.expectEqual(@as(u8, 1), Child.decodeStatus(1 << 8).exited);
    try testing.expectEqual(@as(u8, 9), Child.decodeStatus(9).signalled);
}

test "a real command runs on a real pseudoterminal" {
    if (comptime !supported) return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pty = Pty.open(.{ .columns = 80, .rows = 24 }) catch |err| switch (err) {
        // A sandbox without /dev/ptmx is a legitimate environment; the rest of
        // the workbench does not depend on this test being able to run.
        error.OpenFailed, error.ConfigureFailed => return error.SkipZigTest,
        else => return err,
    };
    defer pty.close();

    try testing.expect(std.mem.startsWith(u8, pty.slavePath(), "/dev/pts/"));
    const size = try pty.getSize();
    try testing.expectEqual(@as(u16, 80), size.columns);

    const argv = try buildArgv(arena, &.{ "/bin/sh", "-c", "printf 'hello from the pty\\n'; exit 3" });
    const envp = try buildEnvp(arena, &.{ "TERM=xterm-256color", "PATH=/usr/bin:/bin" });
    var child = try pty.spawn("/bin/sh", argv.ptr, envp.ptr, null);

    var collected: std.ArrayList(u8) = .empty;
    var buffer: [1024]u8 = undefined;
    var waited_ms: i32 = 0;
    while (waited_ms < 5000) {
        if (!pty.waitReadable(50)) {
            waited_ms += 50;
            if (child.poll() != null) break;
            continue;
        }
        const n = pty.read(&buffer) catch break;
        if (n == 0) break;
        try collected.appendSlice(arena, buffer[0..n]);
        if (std.mem.indexOf(u8, collected.items, "hello from the pty") != null) break;
    }

    try testing.expect(std.mem.indexOf(u8, collected.items, "hello from the pty") != null);
    const exit = child.wait();
    try testing.expectEqual(@as(u8, 3), exit.exited);
}

test "a pseudoterminal reports its size back to the program" {
    if (comptime !supported) return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pty = Pty.open(.{ .columns = 100, .rows = 30 }) catch return error.SkipZigTest;
    defer pty.close();

    const argv = try buildArgv(arena, &.{ "/bin/sh", "-c", "stty size 2>/dev/null || echo unavailable" });
    const envp = try buildEnvp(arena, &.{"PATH=/usr/bin:/bin"});
    var child = try pty.spawn("/bin/sh", argv.ptr, envp.ptr, null);

    var collected: std.ArrayList(u8) = .empty;
    var buffer: [512]u8 = undefined;
    var waited_ms: i32 = 0;
    while (waited_ms < 5000) {
        if (!pty.waitReadable(50)) {
            waited_ms += 50;
            if (child.poll() != null) break;
            continue;
        }
        const n = pty.read(&buffer) catch break;
        if (n == 0) break;
        try collected.appendSlice(arena, buffer[0..n]);
        if (std.mem.indexOf(u8, collected.items, "\n") != null) break;
    }
    _ = child.poll();

    const text = collected.items;
    if (std.mem.indexOf(u8, text, "unavailable") == null) {
        try testing.expect(std.mem.indexOf(u8, text, "30 100") != null);
    }
}
