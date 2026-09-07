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
const graph_mod = @import("../events/graph.zig");
const content_store_mod = @import("../events/content_store.zig");
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
    /// Where bytes referenced by process-output events are staged. Tests that
    /// only exercise terminal parsing may leave this unset.
    content_store: ?*content_store_mod.Store = null,
    /// A parent-only token required on service-owned command boundary marks.
    marker_token: ?[]const u8 = null,
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
    child_exit: ?pty_mod.Exit = null,
    timed_out: bool = false,
    /// The event that opened this session.
    ///
    /// Everything the session writes carries it as a correlation, so one unit
    /// of work is one query rather than a guess from timestamps. Without it the
    /// execution graph folds a field nobody fills and a real session comes back
    /// as a flat list of unrelated roots.
    session_event: event_mod.EventId,
    /// The block currently collecting output, if any.
    open_block: ?idmod.BlockId = null,
    open_block_started: ?timeutil.Timestamp = null,
    /// The event that submitted the open block. Output and the finish are
    /// caused by it, which is what makes a block one subtree of the graph.
    open_block_event: ?event_mod.EventId = null,
    ids: idmod.Generator,
    clock: timeutil.Timestamp,
    /// Bytes of output collected for the open block.
    output: std.ArrayList(u8) = .empty,
    /// Start of a possible escape sequence in `output`.
    capture_escape_start: ?usize = null,
    /// Start of the OSC string now being parsed, if it began while a block was
    /// open. A recognised shell mark is removed from the captured bytes.
    capture_osc_start: ?usize = null,
    content_store: ?*content_store_mod.Store,

    pub fn init(
        arena: std.mem.Allocator,
        log: *log_mod.Log,
        id: idmod.SessionId,
        options: Options,
        clock: timeutil.Timestamp,
    ) !Session {
        var session: Session = .{
            .arena = arena,
            .id = id,
            .screen = try grid.Screen.init(arena, options.columns, options.rows, options.scrollback_limit),
            .tracker = if (options.marker_token) |token|
                integration.Tracker.initAuthenticated(arena, token)
            else
                integration.Tracker.init(arena),
            .log = log,
            .actor = options.actor,
            .content_store = options.content_store,
            .ids = idmod.Generator.init(@bitCast(clock.ns), @divFloor(clock.ns, timeutil.ns_per_ms)),
            .clock = clock,
            .session_event = undefined,
        };
        const opened = try log.append(.{ .session_opened = .{
            .session = id,
            .workingDirectory = options.working_directory,
            .shell = options.shell,
            .columns = options.columns,
            .rows = options.rows,
        } }, .{ .at = clock, .actor = options.actor });
        session.session_event = opened.id;
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
        for (bytes) |byte| {
            if (self.open_block != null) {
                // Keep failure bounded even when a child floods the terminal.
                // The extra room lets a boundary mark be removed before the
                // content-store limit is applied.
                if (self.output.items.len >= content_store_mod.max_blob_bytes + 16 * 1024) {
                    return error.ContentTooLarge;
                }
                try self.output.append(self.arena, byte);
                if (self.capture_osc_start == null) {
                    if (byte == 0x9d) {
                        self.capture_osc_start = self.output.items.len - 1;
                        self.capture_escape_start = null;
                    } else if (byte == 0x1b) {
                        self.capture_escape_start = self.output.items.len - 1;
                    } else if (byte == ']' and self.capture_escape_start != null) {
                        self.capture_osc_start = self.capture_escape_start;
                        self.capture_escape_start = null;
                    } else {
                        self.capture_escape_start = null;
                    }
                }
            }

            if (!try self.screen.writeByte(byte)) continue;
            for (self.screen.drainOsc()) |raw| {
                const boundary = (try self.tracker.consume(raw)) orelse continue;
                // Shell integration belongs to the control plane, not to the
                // command's output. Remove the whole OSC sequence, including
                // its terminator, before the boundary changes the block.
                if (self.capture_osc_start) |start| self.output.shrinkRetainingCapacity(start);
                try self.handleBoundary(boundary);
            }
            self.capture_escape_start = null;
            self.capture_osc_start = null;
        }
    }

    fn handleBoundary(self: *Session, boundary: integration.Boundary) !void {
        switch (boundary) {
            .output_start => |o| {
                // A second start mark before a finish mark cannot replace a
                // block already in progress. Ignoring it preserves the output
                // and makes malformed shell integration non-destructive.
                if (self.open_block != null) return;
                const command = o.command orelse "";
                const block = self.ids.next(idmod.BlockId);
                self.open_block = block;
                self.open_block_started = self.clock;
                self.output = .empty;
                const submitted = try self.log.append(.{ .command_submitted = .{
                    .block = block,
                    .session = self.id,
                    .commandText = try self.arena.dupe(u8, command),
                    .workingDirectory = self.tracker.working_directory orelse "",
                    .boundaryFromShell = true,
                } }, .{
                    .at = self.clock,
                    .actor = self.actor,
                    .causedBy = self.session_event,
                    .correlation = self.session_event,
                });
                self.open_block_event = submitted.id;
            },
            .command_finished => |f| {
                try self.finishOpenBlock(f.exit_status orelse 0, null);
            },
            .directory_changed => |path| {
                _ = try self.log.append(.{ .git_changed = .{
                    .session = self.id,
                    .repository = path,
                } }, .{
                    .at = self.clock,
                    .actor = self.actor,
                    .causedBy = self.open_block_event orelse self.session_event,
                    .correlation = self.session_event,
                });
            },
            else => {},
        }
    }

    fn finishOpenBlock(self: *Session, exit_status: u8, signal: ?u8) !void {
        const block = self.open_block orelse return;
        if (self.output.items.len > 0) {
            const content_hash = if (self.content_store) |store|
                try store.put(self.output.items)
            else
                hashing.Hash.of(self.output.items);
            _ = try self.log.append(.{ .process_output = .{
                .block = block,
                .session = self.id,
                .contentHash = content_hash,
                .byteCount = self.output.items.len,
            } }, .{
                .at = self.clock,
                .actor = self.actor,
                .causedBy = self.open_block_event orelse self.session_event,
                .correlation = self.session_event,
            });
        }
        const started = self.open_block_started orelse self.clock;
        _ = try self.log.append(.{ .command_finished = .{
            .block = block,
            .session = self.id,
            .exitStatus = exit_status,
            .duration = self.clock.since(started),
            .signal = signal,
        } }, .{
            .at = self.clock,
            .actor = self.actor,
            .causedBy = self.open_block_event orelse self.session_event,
            .correlation = self.session_event,
        });
        self.open_block = null;
        self.open_block_started = null;
        self.open_block_event = null;
        self.output = .empty;
        self.capture_escape_start = null;
        self.capture_osc_start = null;
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
        defer {
            if (self.pty) |pty| pty.close();
            self.pty = null;
        }
        if (self.child) |*child| {
            self.child_exit = child.wait();
        }
        const details = self.exitDetails();
        try self.finishOpenBlock(details.status orelse 0, details.signal);
        _ = try self.log.append(.{ .session_closed = .{
            .session = self.id,
            .exitStatus = details.status,
            .reason = reason,
        } }, .{
            .at = self.clock,
            .actor = self.actor,
            .causedBy = self.session_event,
            .correlation = self.session_event,
        });
    }

    pub fn didTimeOut(self: Session) bool {
        return self.timed_out;
    }

    fn exitDetails(self: Session) struct { status: ?u8, signal: ?u8 } {
        if (self.timed_out) {
            return .{ .status = 124, .signal = switch (self.child_exit orelse .unknown) {
                .signalled => |signal| signal,
                else => null,
            } };
        }
        return switch (self.child_exit orelse .unknown) {
            .exited => |status| .{ .status = status, .signal = null },
            .signalled => |signal| .{ .status = 128 +| signal, .signal = signal },
            .unknown => .{ .status = null, .signal = null },
        };
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
        errdefer {
            if (self.child) |*child| {
                if (child.exit == null) child.signalGroup(9);
                self.child_exit = child.wait();
            }
            if (self.pty) |owned| owned.close();
            self.pty = null;
        }
        const pty = self.pty.?;
        var buffer: [8192]u8 = undefined;
        const started_ns = try pty_mod.monotonicNanos();
        const started_clock = self.clock;
        const timeout_ns = @max(timeout.ns, 100 * timeutil.ns_per_ms);
        var child_finished = false;

        while (true) {
            const now_ns = try pty_mod.monotonicNanos();
            const elapsed_ns = @max(now_ns - started_ns, 0);
            self.clock = started_clock.addNanos(elapsed_ns);
            if (elapsed_ns >= timeout_ns) break;
            const remaining_ms = @divFloor(timeout_ns - elapsed_ns + timeutil.ns_per_ms - 1, timeutil.ns_per_ms);
            const wait_ms: i32 = @intCast(@min(remaining_ms, 50));

            if (pty.waitReadable(wait_ms)) {
                const n = try self.pump(&buffer);
                if (n > 0) continue;
                // A non-blocking read may race with readiness. Only a reaped
                // child proves completion; otherwise keep enforcing the same
                // monotonic deadline.
                if (self.child) |*child| {
                    if (child.poll()) |exit| {
                        self.child_exit = exit;
                        child_finished = true;
                        break;
                    }
                }
                continue;
            }
            if (self.child) |*child| {
                if (child.poll()) |exit| {
                    self.child_exit = exit;
                    child_finished = true;
                    break;
                }
            }
        }

        if (child_finished) {
            // Drain whatever the program wrote just before it ended.
            while (pty.waitReadable(10)) {
                const now_ns = try pty_mod.monotonicNanos();
                self.clock = started_clock.addNanos(@max(now_ns - started_ns, 0));
                const n = try self.pump(&buffer);
                if (n == 0) break;
            }
        } else if (self.child) |*child| {
            self.timed_out = true;
            child.signalGroup(15);

            // Give well-behaved programs a short chance to clean up, while
            // continuing to drain the PTY so they cannot block on a full
            // output buffer. A process that ignores TERM is killed as a group.
            const grace_started = try pty_mod.monotonicNanos();
            while (try pty_mod.monotonicNanos() - grace_started < 250 * timeutil.ns_per_ms) {
                if (pty.waitReadable(10)) {
                    const n = try self.pump(&buffer);
                    if (n == 0) break;
                }
                if (child.poll()) |exit| {
                    self.child_exit = exit;
                    child_finished = true;
                    break;
                }
            }
            if (!child_finished) {
                child.signalGroup(9);
                self.child_exit = child.wait();
            }
            while (pty.waitReadable(10)) {
                const n = try self.pump(&buffer);
                if (n == 0) break;
            }
        }

        const finished_ns = try pty_mod.monotonicNanos();
        self.clock = started_clock.addNanos(@max(finished_ns - started_ns, 0));
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

test "one read records only command output and stages its content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log = log_mod.Log.init(arena, 191);
    var store = content_store_mod.Store.init(arena, ".");
    var gen: idmod.Generator = .init(192, 1_788_000_000_000);
    const actor: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person };
    const start = try timeutil.Timestamp.parseIso("2026-09-04T20:00:00Z");
    var session = try Session.init(arena, &log, gen.next(idmod.SessionId), .{
        .actor = actor,
        .content_store = &store,
    }, start);

    // Fast programs commonly put both marks and all output in one PTY read.
    try session.consume("\x1b]133;C;cmdline=printf hi\x07hello\r\n\x1b]133;D;0\x07");

    const expected_hash = hashing.Hash.of("hello\r\n");
    var output_events: usize = 0;
    for (log.entries.items) |entry| switch (entry.payload) {
        .process_output => |output| {
            output_events += 1;
            try testing.expectEqual(@as(usize, 7), output.byteCount);
            try testing.expect(output.contentHash.eql(expected_hash));
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), output_events);
    try testing.expectEqual(@as(usize, 1), store.pending.items.len);
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

test "a chatty process that ignores TERM still meets the hard deadline" {
    if (comptime !pty_mod.supported) return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log = log_mod.Log.init(arena, 195);
    var gen: idmod.Generator = .init(196, 1_788_000_000_000);
    const actor: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .system };
    const start = try timeutil.Timestamp.parseIso("2026-09-04T20:00:00Z");
    var session = try Session.init(arena, &log, gen.next(idmod.SessionId), .{ .actor = actor }, start);

    const wall_start = try pty_mod.monotonicNanos();
    session.run(
        "/bin/sh",
        &.{
            "/bin/sh",
            "-c",
            "printf '\\033]133;C;cmdline=loop\\007'; trap '' TERM; while :; do printf x; /bin/sleep 0.01; done",
        },
        &.{ "TERM=xterm-256color", "PATH=/usr/bin:/bin" },
        null,
        timeutil.Duration.fromMillis(100),
    ) catch |err| switch (err) {
        error.OpenFailed, error.ConfigureFailed, error.UnsupportedPlatform => return error.SkipZigTest,
        else => return err,
    };
    try testing.expect(session.didTimeOut());
    try session.close("the deadline passed");
    const wall_elapsed = try pty_mod.monotonicNanos() - wall_start;
    try testing.expect(wall_elapsed < 2 * timeutil.ns_per_s);

    var found_finish = false;
    for (log.entries.items) |entry| switch (entry.payload) {
        .command_finished => |finished| {
            found_finish = true;
            try testing.expectEqual(@as(u8, 124), finished.exitStatus);
            try testing.expect(finished.signal != null);
            try testing.expect(finished.duration.millis() >= 100);
        },
        else => {},
    };
    try testing.expect(found_finish);
    try testing.expect((try log.verify()) == null);
}

test "everything a session writes belongs to the session that wrote it" {
    if (!pty_mod.supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var log = log_mod.Log.init(arena, 91);
    var gen = idmod.Generator.init(92, 0);
    const id = gen.next(idmod.SessionId);
    var session = try Session.init(arena, &log, id, .{
        .working_directory = "/tmp",
        .shell = "/bin/sh",
        .actor = .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "you" },
    }, .{ .ns = 1_700_000_000 * timeutil.ns_per_s });

    try session.run(
        "/bin/sh",
        &.{ "/bin/sh", "-c", "printf hello" },
        &.{"PATH=/bin:/usr/bin"},
        "/tmp",
        timeutil.Duration.fromSeconds(10),
    );
    try session.close("done");

    // One root: the session opening. Everything else descends from it, so one
    // unit of work is one query rather than a guess from timestamps. Before
    // this, production writers set neither field and a real session came back
    // as a flat list of unrelated roots.
    const graph = try graph_mod.Graph.build(arena, log);
    const roots = try graph.roots();
    try testing.expectEqual(@as(usize, 1), roots.items.len);
    try testing.expectEqual(@as(usize, 0), roots.items[0]);

    const opened = log.entries.items[0];
    try testing.expect(opened.causedBy == null);
    for (log.entries.items[1..]) |entry| {
        const correlation = entry.correlation orelse return error.TestUnexpectedResult;
        try testing.expect(correlation.eql(opened.id));
    }

    // The whole session comes back from one correlation.
    const run = try graph.run(opened.id);
    try testing.expectEqual(log.entries.items.len, run.items.len);
}
