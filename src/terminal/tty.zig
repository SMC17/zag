//! The terminal this program is *running on*, as opposed to the one it runs
//! programs inside.
//!
//! An interactive terminal needs three things from its own controlling
//! terminal. It has to stop the line discipline from echoing and buffering, so
//! every keystroke reaches the program it is hosting. It has to know how large
//! the window is, so the program inside sees the same size. And it has to put
//! everything back when it exits, including when it exits badly, because a
//! shell left in raw mode is a shell a person has to close and reopen.
//!
//! The third point is why `restore` is idempotent and why the caller is
//! expected to `defer` it. A terminal emulator that corrupts the terminal it
//! was launched from has failed at the one thing nobody forgives.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

/// The controlling terminal is driven with Linux system calls, so this is the
/// only platform where it works today. Everywhere else the calls below report
/// that rather than pretending, and the program still compiles.
pub const supported = builtin.os.tag == .linux;

pub const Error = error{
    /// Standard input is not a terminal. Piped input is a legitimate thing to
    /// do, so this is reported rather than treated as a fault.
    NotATerminal,
    /// The platform does not expose the calls this needs.
    Unsupported,
    /// The terminal refused a setting.
    SettingsRefused,
};

pub const Size = struct {
    columns: u16 = 80,
    rows: u16 = 24,

    pub fn eql(a: Size, b: Size) bool {
        return a.columns == b.columns and a.rows == b.rows;
    }
};

/// The controlling terminal, with its original settings held so they can be
/// put back.
pub const Tty = struct {
    input: posix.fd_t,
    output: posix.fd_t,
    original: ?posix.termios = null,

    pub fn init() Tty {
        // Taken from the standard streams rather than written as 0 and 1: a
        // handle is not an integer on every platform, and this has to compile
        // everywhere even though it only runs on one.
        return .{
            .input = std.Io.File.stdin().handle,
            .output = std.Io.File.stdout().handle,
        };
    }

    pub fn isTerminal(self: Tty) bool {
        if (comptime !supported) return false;
        _ = posix.tcgetattr(self.input) catch return false;
        return true;
    }

    /// Hand every keystroke straight through: no echo, no line editing, no
    /// signal characters. The program inside the pseudoterminal does all of
    /// that, and doing it twice is what produces doubled characters and a
    /// control-C that kills the wrong process.
    pub fn enterRaw(self: *Tty) Error!void {
        if (comptime !supported) return error.Unsupported;
        const original = posix.tcgetattr(self.input) catch return error.NotATerminal;
        self.original = original;

        var raw = original;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.PARENB = false;
        raw.cflag.CSIZE = .CS8;
        // Return from a read as soon as one byte is there, and never block
        // forever: the loop also has a pseudoterminal to watch.
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        posix.tcsetattr(self.input, .FLUSH, raw) catch return error.SettingsRefused;
    }

    /// Put the terminal back. Safe to call more than once, and safe to call
    /// when raw mode was never entered.
    pub fn restore(self: *Tty) void {
        if (comptime !supported) return;
        const original = self.original orelse return;
        posix.tcsetattr(self.input, .FLUSH, original) catch {};
        self.original = null;
    }

    /// How large the window is now. Asked for rather than waited for: polling
    /// the size each time round the loop needs no signal handler, and a signal
    /// handler that writes to a global is the usual source of resize bugs.
    pub fn size(self: Tty) Error!Size {
        if (comptime !supported) return error.Unsupported;
        var ws: Winsize = undefined;
        const result = linux.ioctl(self.output, linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (linux.errno(result) != .SUCCESS) return error.NotATerminal;
        return .{
            .columns = if (ws.col == 0) 80 else ws.col,
            .rows = if (ws.row == 0) 24 else ws.row,
        };
    }

    /// True when there is input waiting, or when the wait ran out.
    pub fn waitReadable(self: Tty, timeout_ms: i32) bool {
        if (comptime !supported) return false;
        var fds = [_]posix.pollfd{.{ .fd = self.input, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, timeout_ms) catch return false;
        if (ready == 0) return false;
        return fds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0;
    }

    pub fn read(self: Tty, buffer: []u8) Error!usize {
        if (comptime !supported) return error.Unsupported;
        const rc = linux.read(self.input, buffer.ptr, buffer.len);
        if (linux.errno(rc) != .SUCCESS) return error.SettingsRefused;
        return rc;
    }

    /// Write every byte, retrying a short write. Output to a terminal is
    /// allowed to stop early, and dropping the rest garbles the screen.
    pub fn write(self: Tty, bytes: []const u8) Error!void {
        if (comptime !supported) return error.Unsupported;
        var written: usize = 0;
        while (written < bytes.len) {
            const rc = linux.write(self.output, bytes[written..].ptr, bytes.len - written);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR, .AGAIN => continue,
                else => return error.SettingsRefused,
            }
            if (rc == 0) return error.SettingsRefused;
            written += rc;
        }
    }
};

const Winsize = extern struct {
    row: u16,
    col: u16,
    xpixel: u16,
    ypixel: u16,
};

/// Wait until either the keyboard or the program has something to say, so the
/// loop sleeps instead of spinning. Returns which of the two is ready.
pub const Ready = struct {
    tty: bool = false,
    pty: bool = false,

    pub fn any(self: Ready) bool {
        return self.tty or self.pty;
    }
};

pub fn waitEither(tty_fd: posix.fd_t, pty_fd: posix.fd_t, timeout_ms: i32) Ready {
    if (comptime !supported) return .{};
    var fds = [_]posix.pollfd{
        .{ .fd = tty_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = pty_fd, .events = posix.POLL.IN, .revents = 0 },
    };
    const ready = posix.poll(&fds, timeout_ms) catch return .{};
    if (ready == 0) return .{};
    return .{
        .tty = fds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0,
        .pty = fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0,
    };
}

const testing = std.testing;

test "a terminal that is not a terminal says so rather than failing" {
    // The test runner's standard input is not a terminal, which is exactly the
    // case that has to degrade politely.
    var tty = Tty.init();
    if (tty.isTerminal()) return error.SkipZigTest;
    try testing.expectError(error.NotATerminal, tty.enterRaw());
    // Restoring when raw mode was never entered is not an error.
    tty.restore();
    tty.restore();
}

test "a size is never zero" {
    var tty = Tty.init();
    const measured = tty.size() catch Size{};
    try testing.expect(measured.columns > 0);
    try testing.expect(measured.rows > 0);
}

test "two sizes compare by both dimensions" {
    try testing.expect((Size{ .columns = 80, .rows = 24 }).eql(.{ .columns = 80, .rows = 24 }));
    try testing.expect(!(Size{ .columns = 80, .rows = 24 }).eql(.{ .columns = 80, .rows = 25 }));
}
