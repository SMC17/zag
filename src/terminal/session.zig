//! A terminal session: pseudoterminal, screen, shell integration and events.
//!
//! This is the seam where the terminal stops being a terminal and becomes part
//! of the workspace. Bytes arrive from the pseudoterminal; the screen renders
//! them; the shell integration says where commands begin and end; and the
//! session writes typed events into the log. The interface reads the log, not
//! the terminal.

const std = @import("std");
const grid = @import("grid.zig");
const pty_mod = @import("pty.zig");
const integration = @import("shell_integration.zig");
const event_mod = @import("../events/event.zig");
const log_mod = @import("../events/log.zig");
const idmod = @import("../core/id.zig");
const hashing = @import("../core/hash.zig");
const timeutil = @import("../core/time.zig");

pub const Options = struct {
    columns: u16 = 80,
    rows: u16 = 24,
    scrollback_limit: usize = 10_000,
    working_directory: []const u8 = ".",
    shell: ?[]const u8 = null,
    /// Where the session's events go.
    actor: event_mod.Actor,
};

/// Drives one program and turns its output into workspace events.
pub const Session = struct {
    arena: std.mem.Allocator,
    id: idmod.SessionId,
    screen: grid.Screen,
    tracker: integration.Tracker,
    log: *log_mod.Log,
    actor: event_mod.Actor,
    pty: ?pty_mod.Pty = null,
    child: ?pty_mod.Child = null,
    /// The block currently collecting output, if any.
    open_block: ?idmod.BlockId = null,
    open_block_started: ?timeutil.Timestamp = null,
    ids: idmod.Generator,
    clock: timeutil.Timestamp,
    /// Bytes of output collected for the open block.
    output: std.ArrayList(u8) = .empty,

    pub fn init(
        arena: std.mem.Allocator,
        log: *log_mod.Log,
        id: idmod.SessionId,
        options: Options,
        clock: timeutil.Timestamp,
    ) !Session {
        const session: Session = .{
            .arena = arena,
            .id = id,
            .screen = try grid.Screen.init(arena, options.columns, options.rows, options.scrollback_limit),
            .tracker = integration.Tracker.init(arena),
            .log = log,
            .actor = options.actor,
            .ids = idmod.Generator.init(@bitCast(clock.ns), @divFloor(clock.ns, timeutil.ns_per_ms)),
            .clock = clock,
        };
        _ = try log.append(.{ .session_opened = .{
            .session = id,
            .workingDirectory = options.working_directory,
            .shell = options.shell,
            .columns = options.columns,
            .rows = options.rows,
        } }, .{ .at = clock, .actor = options.actor });
        return session;
    }

    /// Advance the session's clock. Time is injected rather than read from the
    /// system so that replays and tests produce identical logs.
    pub fn tick(self: *Session, delta: timeutil.Duration) void {
        self.clock = self.clock.addNanos(delta.ns);
    }

    /// Start a program on a real pseudoterminal.
    pub fn spawn(
        self: *Session,
        path: []const u8,
        args: []const []const u8,
        env: []const []const u8,
        working_directory: ?[]const u8,
    ) !void {
        var pty = try pty_mod.Pty.open(.{ .columns = self.screen.columns, .rows = self.screen.rows });
        errdefer pty.close();

        const argv = try pty_mod.buildArgv(self.arena, args);
        const envp = try pty_mod.buildEnvp(self.arena, env);
        const path_z = try self.arena.dupeZ(u8, path);
        const cwd_z = if (working_directory) |d| (try self.arena.dupeZ(u8, d)).ptr else null;

        self.child = try pty.spawn(path_z.ptr, argv.ptr, envp.ptr, cwd_z);
        self.pty = pty;
    }

    /// Read whatever the program has produced and fold it in. Returns the
    /// number of bytes handled.
    pub fn pump(self: *Session, buffer: []u8) !usize {
        const pty = self.pty orelse return 0;
        const n = try pty.read(buffer);
        if (n == 0) return 0;
        try self.consume(buffer[0..n]);
        return n;
    }

    /// Fold bytes into the screen and the event log. Exposed separately from
    /// `pump` so that recorded output can be replayed without a process.
    pub fn consume(self: *Session, bytes: []const u8) !void {
        try self.screen.write(bytes);
        if (self.open_block != null) try self.output.appendSlice(self.arena, bytes);

        for (self.screen.drainOsc()) |raw| {
            const boundary = (try self.tracker.consume(raw)) orelse continue;
            try self.handleBoundary(boundary);
        }
    }

    fn handleBoundary(self: *Session, boundary: integration.Boundary) !void {
        switch (boundary) {
            .output_start => |o| {
                const command = o.command orelse "";
                const block = self.ids.next(idmod.BlockId);
                self.open_block = block;
                self.open_block_started = self.clock;
                self.output = .empty;
                _ = try self.log.append(.{ .command_submitted = .{
                    .block = block,
                    .session = self.id,
                    .commandText = try self.arena.dupe(u8, command),
                    .workingDirectory = self.tracker.working_directory orelse "",
                    .boundaryFromShell = true,
                } }, .{ .at = self.clock, .actor = self.actor });
            },
            .command_finished => |f| {
                const block = self.open_block orelse return;
                if (self.output.items.len > 0) {
                    _ = try self.log.append(.{ .process_output = .{
                        .block = block,
                        .session = self.id,
                        .contentHash = hashing.Hash.of(self.output.items),
                        .byteCount = self.output.items.len,
                    } }, .{ .at = self.clock, .actor = self.actor });
                }
                const started = self.open_block_started orelse self.clock;
                _ = try self.log.append(.{ .command_finished = .{
                    .block = block,
                    .session = self.id,
                    .exitStatus = f.exit_status orelse 0,
                    .duration = self.clock.since(started),
                } }, .{ .at = self.clock, .actor = self.actor });
                self.open_block = null;
                self.open_block_started = null;
                self.output = .empty;
            },
            .directory_changed => |path| {
                _ = try self.log.append(.{ .git_changed = .{
                    .session = self.id,
                    .repository = path,
                } }, .{ .at = self.clock, .actor = self.actor });
            },
            else => {},
        }
    }

    pub fn writeInput(self: *Session, bytes: []const u8) !usize {
        const pty = self.pty orelse return 0;
        return pty.write(bytes);
    }

    pub fn resize(self: *Session, columns: u16, rows: u16) !void {
        try self.screen.resize(columns, rows);
        if (self.pty) |pty| try pty.setSize(.{ .columns = columns, .rows = rows });
    }

    /// Wait for the program to end and record the session's close.
    pub fn close(self: *Session, reason: []const u8) !void {
        var exit_status: ?u8 = null;
        if (self.child) |child| {
            exit_status = child.wait().status();
        }
        if (self.pty) |pty| pty.close();
        self.pty = null;
        _ = try self.log.append(.{ .session_closed = .{
            .session = self.id,
            .exitStatus = exit_status,
            .reason = reason,
        } }, .{ .at = self.clock, .actor = self.actor });
    }

    /// Run a program to completion, folding its output in as it arrives.
    /// This is the shape the command-line tool and the daemon both use.
    ///
    /// The loop waits on the pseudoterminal rather than spinning, and it stops
    /// at the deadline whatever the child does, so a program that never exits
    /// cannot hang the caller.
    pub fn run(
        self: *Session,
        path: []const u8,
        args: []const []const u8,
        env: []const []const u8,
        working_directory: ?[]const u8,
        timeout: timeutil.Duration,
    ) !void {
        try self.spawn(path, args, env, working_directory);
        const pty = self.pty.?;
        var buffer: [8192]u8 = undefined;

        const deadline_ms = @max(timeout.millis(), 100);
        var waited_ms: i64 = 0;
        var child_finished = false;

        while (waited_ms < deadline_ms) {
            if (pty.waitReadable(50)) {
                const n = try self.pump(&buffer);
                if (n > 0) {
                    self.tick(timeutil.Duration.fromMillis(1));
                    continue;
                }
                // Readable with nothing to read means the program's end of the
                // pseudoterminal has closed. That is the reliable end signal;
                // waiting on the process is not, because something else may
                // have reaped it first.
                child_finished = true;
                break;
            }
            waited_ms += 50;
            if (self.child) |child| {
                if (child.poll() != null) {
                    child_finished = true;
                    break;
                }
            }
        }

        if (child_finished) {
            // Drain whatever the program wrote just before it ended.
            while (pty.waitReadable(10)) {
                const n = try self.pump(&buffer);
                if (n == 0) break;
            }
        } else if (self.child) |child| {
            // The deadline passed. Stop the program rather than leaving it.
            child.signal(15);
            _ = child.poll();
        }
    }
};

const testing = std.testing;

test "a recorded session produces blocks from shell marks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log = log_mod.Log.init(arena, 91);
    var gen: idmod.Generator = .init(92, 1_788_000_000_000);
    const actor: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "sean" };
    const start = try timeutil.Timestamp.parseIso("2026-09-04T20:00:00Z");

    var session = try Session.init(arena, &log, gen.next(idmod.SessionId), .{
        .working_directory = "/home/user/zag",
        .shell = "bash",
        .actor = actor,
    }, start);

    // Exactly what a shell with the integration hook sends.
    try session.consume("\x1b]7;file:///home/user/zag\x07");
    try session.consume("\x1b]133;A\x07user@host:~/zag$ \x1b]133;B\x07zig build test\r\n");
    try session.consume("\x1b]133;C;cmdline=zig build test\x07");
    session.tick(timeutil.Duration.fromMillis(1500));
    try session.consume("All 147 tests passed.\r\n");
    try session.consume("\x1b]133;D;0\x07");

    const block_mod = @import("../workspace/block.zig");
    const index = try block_mod.Index.build(arena, log);
    try testing.expectEqual(@as(usize, 1), index.count());

    const block = index.blocks.items[0];
    try testing.expectEqualStrings("zig build test", block.commandText.?);
    try testing.expectEqual(@as(u8, 0), block.exitStatus.?);
    try testing.expect(block.boundaryFromShell);
    try testing.expectEqual(@as(i64, 1500), block.duration().?.millis());
    try testing.expect(block.outputBytes > 0);

    // The screen shows what the program drew.
    const text = try session.screen.text(arena);
    try testing.expect(std.mem.indexOf(u8, text, "All 147 tests passed.") != null);
}

test "a session without shell integration still records the session" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log = log_mod.Log.init(arena, 93);
    var gen: idmod.Generator = .init(94, 1_788_000_000_000);
    const actor: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person };
    const start = try timeutil.Timestamp.parseIso("2026-09-04T20:00:00Z");

    var session = try Session.init(arena, &log, gen.next(idmod.SessionId), .{ .actor = actor }, start);
    try session.consume("plain output with no marks\r\n");
    try testing.expect(!session.tracker.integrated);

    const block_mod = @import("../workspace/block.zig");
    const index = try block_mod.Index.build(arena, log);
    // No blocks, because no boundary was reported. The session is still in the
    // log, and the screen still has the text.
    try testing.expectEqual(@as(usize, 0), index.count());
    try testing.expectEqual(@as(usize, 1), log.count());
}

test "a real shell session records a real command" {
    if (comptime !pty_mod.supported) return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log = log_mod.Log.init(arena, 95);
    var gen: idmod.Generator = .init(96, 1_788_000_000_000);
    const actor: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person };
    const start = try timeutil.Timestamp.parseIso("2026-09-04T20:00:00Z");

    var session = try Session.init(arena, &log, gen.next(idmod.SessionId), .{ .actor = actor }, start);
    session.run(
        "/bin/sh",
        &.{ "/bin/sh", "-c", "printf '\\033]133;C;cmdline=echo hello\\007hello\\r\\n\\033]133;D;0\\007'" },
        &.{"PATH=/usr/bin:/bin"},
        null,
        timeutil.Duration.fromSeconds(10),
    ) catch |err| switch (err) {
        error.OpenFailed, error.ConfigureFailed, error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    try session.close("the test finished");

    const block_mod = @import("../workspace/block.zig");
    const index = try block_mod.Index.build(arena, log);
    try testing.expectEqual(@as(usize, 1), index.count());
    try testing.expectEqualStrings("echo hello", index.blocks.items[0].commandText.?);
    try testing.expectEqual(@as(u8, 0), index.blocks.items[0].exitStatus.?);
    try testing.expect((try log.verify()) == null);
}
