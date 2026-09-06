//! An interactive terminal that records what happened.
//!
//! This is the loop a person actually sits in front of. It puts their own shell
//! on a real pseudoterminal, passes every byte through in both directions, and
//! folds the output into the workspace event log on the way past. When the
//! shell exits, the session is a set of blocks that `zag history` can search
//! and that anyone can verify, because each event is hashed to the one before
//! it.
//!
//! Nothing here interprets the person's keystrokes. A terminal that second
//! guesses the keyboard breaks the programs it hosts, so the loop forwards
//! input untouched and does its work on the output side.
//!
//! Shell integration is offered, never imposed. When the shell is one the
//! workbench knows, it is started with a small init file that sources the
//! person's own configuration first and then adds the semantic prompt marks.
//! When it is not, the session still records: the block boundaries are inferred
//! rather than marked, and every block says which it was.

const std = @import("std");
const tty_mod = @import("tty.zig");
const pty_mod = @import("pty.zig");
const session_mod = @import("session.zig");
const integration = @import("shell_integration.zig");
const service_mod = @import("../workspace/service.zig");
const block_mod = @import("../workspace/block.zig");
const idmod = @import("../core/id.zig");
const timeutil = @import("../core/time.zig");

pub const Tty = tty_mod.Tty;
pub const Timestamp = timeutil.Timestamp;

pub const Error = error{
    /// There is no terminal to run in. Reported rather than assumed, because
    /// `zag term` in a pipe is a mistake worth naming.
    NotATerminal,
    /// The platform has no pseudoterminal support in this build.
    Unsupported,
} || std.mem.Allocator.Error;

/// The shells the workbench can mark prompts in. Anything else still runs.
pub const Shell = enum {
    bash,
    zsh,
    fish,
    other,

    /// Read the shell's name from its path. `/usr/local/bin/bash` is bash.
    pub fn fromPath(path: []const u8) Shell {
        const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
        if (std.mem.eql(u8, base, "bash")) return .bash;
        if (std.mem.eql(u8, base, "zsh")) return .zsh;
        if (std.mem.eql(u8, base, "fish")) return .fish;
        return .other;
    }

    pub fn marksPrompts(self: Shell) bool {
        return self != .other;
    }
};

/// Everything needed to start the shell, worked out before anything is run so
/// that it can be inspected and tested without a terminal.
pub const Launch = struct {
    program: []const u8,
    argv: []const []const u8,
    environment: []const []const u8,
    shell: Shell,
    /// Where the generated init file was written, when there is one.
    hookPath: ?[]const u8 = null,
    /// True when the shell will report prompt and command boundaries. When it
    /// is false, boundaries are inferred and every block says so.
    marksPrompts: bool,
};

pub const Options = struct {
    /// The shell to run. The default is `$SHELL`, then `/bin/bash`.
    shell: ?[]const u8 = null,
    workingDirectory: []const u8,
    /// The environment to hand the shell, as `KEY=VALUE` pairs. The person's
    /// own environment, so their shell behaves the way it does everywhere else.
    environment: []const []const u8 = &.{},
    /// Where the generated init files live. Usually `<root>/.workspace/shell`.
    hookDirectory: []const u8,
    /// Set false to run the shell exactly as it is, with no init file. The
    /// session then records inferred boundaries.
    integrate: bool = true,
    /// A secret the shell puts on every boundary mark it writes. Without it,
    /// any program that prints an escape sequence could forge a command
    /// boundary in the record. The shell reads it from the environment and
    /// unsets it, so a child process cannot read it back.
    markerToken: ?[]const u8 = null,
};

/// Work out how to start the shell, and write the init file when one is needed.
///
/// The init file sources the person's own configuration first. A terminal that
/// silently replaces someone's shell setup has broken their shell, however good
/// its own additions are.
pub fn prepare(
    arena: std.mem.Allocator,
    io: std.Io,
    options: Options,
) !Launch {
    const program = options.shell orelse findShell(options.environment) orelse "/bin/bash";
    const shell = Shell.fromPath(program);
    if (!options.integrate or !shell.marksPrompts()) {
        return .{
            .program = program,
            .argv = try arena.dupe([]const u8, &.{ program, "-i" }),
            .environment = try withTerm(arena, options.environment),
            .shell = shell,
            .marksPrompts = false,
        };
    }

    var dir = std.Io.Dir.cwd();
    dir.createDirPath(io, options.hookDirectory) catch {};

    switch (shell) {
        .bash => {
            const path = try std.fmt.allocPrint(arena, "{s}/bash.sh", .{options.hookDirectory});
            const body = try std.fmt.allocPrint(arena,
                \\# Written by zag. Delete it and it is written again.
                \\# Your own configuration is sourced first, then the prompt marks.
                \\if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
                \\__zag_token="${{ZAG_MARKER_TOKEN:-}}"; unset ZAG_MARKER_TOKEN
                \\{s}
                \\
            , .{integration.hooks.bash});
            try dir.writeFile(io, .{ .sub_path = path, .data = body });
            return .{
                .program = program,
                .argv = try arena.dupe([]const u8, &.{ program, "--init-file", path, "-i" }),
                .environment = try withToken(arena, try withTerm(arena, options.environment), options.markerToken),
                .shell = shell,
                .hookPath = path,
                .marksPrompts = true,
            };
        },
        .zsh => {
            // zsh reads its configuration from ZDOTDIR, so the generated
            // directory holds a .zshrc that sources the real one first.
            const dot_dir = try std.fmt.allocPrint(arena, "{s}/zdotdir", .{options.hookDirectory});
            dir.createDirPath(io, dot_dir) catch {};
            const path = try std.fmt.allocPrint(arena, "{s}/.zshrc", .{dot_dir});
            const body = try std.fmt.allocPrint(arena,
                \\# Written by zag. Delete it and it is written again.
                \\if [ -f "${{ZDOTDIR_ORIGINAL:-$HOME}}/.zshrc" ]; then . "${{ZDOTDIR_ORIGINAL:-$HOME}}/.zshrc"; fi
                \\__zag_token="${{ZAG_MARKER_TOKEN:-}}"; unset ZAG_MARKER_TOKEN
                \\{s}
                \\
            , .{integration.hooks.zsh});
            try dir.writeFile(io, .{ .sub_path = path, .data = body });

            var env: std.ArrayList([]const u8) = .empty;
            for (options.environment) |pair| {
                if (std.mem.startsWith(u8, pair, "ZDOTDIR=")) {
                    try env.append(arena, try std.fmt.allocPrint(arena, "ZDOTDIR_ORIGINAL={s}", .{pair["ZDOTDIR=".len..]}));
                    continue;
                }
                try env.append(arena, pair);
            }
            try env.append(arena, try std.fmt.allocPrint(arena, "ZDOTDIR={s}", .{dot_dir}));
            return .{
                .program = program,
                .argv = try arena.dupe([]const u8, &.{ program, "-i" }),
                .environment = try withToken(arena, try withTerm(arena, env.items), options.markerToken),
                .shell = shell,
                .hookPath = path,
                .marksPrompts = true,
            };
        },
        .fish => {
            const path = try std.fmt.allocPrint(arena, "{s}/zag.fish", .{options.hookDirectory});
            try dir.writeFile(io, .{ .sub_path = path, .data = integration.hooks.fish });
            const source = try std.fmt.allocPrint(arena, "source {s}", .{path});
            return .{
                .program = program,
                .argv = try arena.dupe([]const u8, &.{ program, "-C", source, "-i" }),
                .environment = try withToken(arena, try withTerm(arena, options.environment), options.markerToken),
                .shell = shell,
                .hookPath = path,
                .marksPrompts = true,
            };
        },
        .other => unreachable,
    }
}

/// Add the marker token to the environment the shell starts with. The hook
/// copies it into a shell variable and unsets it immediately, so it is not
/// inherited by anything the person runs.
fn withToken(arena: std.mem.Allocator, environment: []const []const u8, token: ?[]const u8) ![]const []const u8 {
    const value = token orelse return environment;
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, environment);
    try out.append(arena, try std.fmt.allocPrint(arena, "ZAG_MARKER_TOKEN={s}", .{value}));
    return out.items;
}

/// `TERM` decides which escape sequences a program will send. It is set only
/// when the person has not set it themselves.
fn withTerm(arena: std.mem.Allocator, environment: []const []const u8) ![]const []const u8 {
    for (environment) |pair| {
        if (std.mem.startsWith(u8, pair, "TERM=")) return arena.dupe([]const u8, environment);
    }
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, environment);
    try out.append(arena, "TERM=xterm-256color");
    return out.items;
}

fn findShell(environment: []const []const u8) ?[]const u8 {
    for (environment) |pair| {
        if (std.mem.startsWith(u8, pair, "SHELL=")) {
            const value = pair["SHELL=".len..];
            if (value.len > 0) return value;
        }
    }
    return null;
}

/// What the session came to.
pub const Outcome = struct {
    session: idmod.SessionId,
    /// The shell's own exit status, when it reported one.
    exitStatus: ?u8,
    blocks: []const block_mod.Block,
    events: usize,
    marksPrompts: bool,

    pub fn commandCount(self: Outcome) usize {
        var count: usize = 0;
        for (self.blocks) |b| {
            if (b.kind == .command) count += 1;
        }
        return count;
    }

    /// What was recorded, in sentences, for the person who has just closed the
    /// shell and wants to know what the workbench kept.
    pub fn writeSummary(self: Outcome, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const commands = self.commandCount();
        if (commands == 1) {
            try w.writeAll("1 command recorded");
        } else {
            try w.print("{d} commands recorded", .{commands});
        }
        try w.print(" in {d} events.\n", .{self.events});
        if (!self.marksPrompts) {
            try w.writeAll("The shell did not mark its prompts, so the block boundaries were inferred.\n");
            try w.writeAll("Run \"zag shell-hook <shell>\" to add the marks.\n");
        }
        try w.writeAll("Search this session with \"zag history\".\n");
    }
};

/// How often the loop looks at the window size, in milliseconds. A resize
/// arrives as a change in the numbers rather than as a signal, which keeps the
/// loop free of signal handlers and their races.
const poll_interval_ms = 30;

/// Run the shell until it exits.
///
/// Both ends are copied byte for byte. The output is also fed to the screen and
/// the shell-integration tracker, which is what turns a stream of bytes into
/// blocks in the log.
pub fn run(
    service: *service_mod.Service,
    tty: *Tty,
    io: std.Io,
    options: Options,
) !Outcome {
    if (!pty_mod.supported) return error.Unsupported;
    if (!tty.isTerminal()) return error.NotATerminal;

    const launch = try prepare(service.arena, io, options);
    const start_size = tty.size() catch tty_mod.Size{};

    // The session appends to the log directly, so the service is told how much
    // it grew. Without this the events sit in memory and the flush writes
    // nothing, which is the worst kind of failure: it looks like it worked.
    const events_before = service.log.count();
    defer service.unflushed += service.log.count() - events_before;

    const id = service.ids.next(idmod.SessionId);
    var session = try session_mod.Session.init(service.arena, &service.log, id, .{
        .columns = start_size.columns,
        .rows = start_size.rows,
        .working_directory = options.workingDirectory,
        .shell = launch.program,
        .actor = service.actor,
        .content_store = &service.content,
        .marker_token = if (launch.marksPrompts) options.markerToken else null,
    }, wallClock(io));

    try tty.enterRaw();
    defer tty.restore();

    try session.spawn(launch.program, launch.argv, launch.environment, options.workingDirectory);
    const pty = session.pty.?;

    var buffer: [16 * 1024]u8 = undefined;
    var known_size = start_size;
    var running = true;

    while (running) {
        const ready = tty_mod.waitEither(tty.input, pty.master, poll_interval_ms);

        if (ready.tty) {
            const n = tty.read(&buffer) catch 0;
            if (n == 0) {
                // The keyboard closed. Tell the shell, and let it finish.
                pty.close();
                break;
            }
            _ = pty.write(buffer[0..n]) catch break;
        }

        if (ready.pty) {
            const n = pty.read(&buffer) catch 0;
            if (n == 0) {
                running = false;
            } else {
                try tty.write(buffer[0..n]);
                session.clock = wallClock(io);
                try session.consume(buffer[0..n]);
            }
        }

        if (!ready.any()) {
            // Nothing to move. Check the window and the child instead.
            const now_size = tty.size() catch known_size;
            if (!now_size.eql(known_size)) {
                known_size = now_size;
                pty.setSize(.{ .columns = now_size.columns, .rows = now_size.rows }) catch {};
                session.resize(now_size.columns, now_size.rows) catch {};
            }
            if (session.child) |*child| {
                if (child.poll() != null) running = false;
            }
        }
    }

    // Whatever the shell wrote as it left belongs in the record too.
    while (pty.waitReadable(20)) {
        const n = pty.read(&buffer) catch 0;
        if (n == 0) break;
        try tty.write(buffer[0..n]);
        session.clock = wallClock(io);
        try session.consume(buffer[0..n]);
    }

    var exit_status: ?u8 = null;
    if (session.child) |*child| {
        if (child.poll()) |exit| exit_status = exit.status();
    }

    session.clock = wallClock(io);
    try session.close("the shell exited");
    service.clock = session.clock;
    tty.restore();

    const index = try service.blocks();
    var mine: std.ArrayList(block_mod.Block) = .empty;
    for (index.blocks.items) |b| {
        if (b.session.eql(id)) try mine.append(service.arena, b);
    }

    return .{
        .session = id,
        .exitStatus = exit_status,
        .blocks = mine.items,
        .events = service.log.count(),
        .marksPrompts = launch.marksPrompts,
    };
}

fn wallClock(io: std.Io) Timestamp {
    const raw = std.Io.Timestamp.now(io, .real);
    return .{ .ns = @intCast(raw.nanoseconds) };
}

const testing = std.testing;

test "a shell is recognised by its name, not its path" {
    try testing.expectEqual(Shell.bash, Shell.fromPath("/bin/bash"));
    try testing.expectEqual(Shell.zsh, Shell.fromPath("/usr/local/bin/zsh"));
    try testing.expectEqual(Shell.fish, Shell.fromPath("fish"));
    try testing.expectEqual(Shell.other, Shell.fromPath("/bin/dash"));
    try testing.expect(!Shell.other.marksPrompts());
}

test "bash is started with an init file that keeps the person's own setup" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hook_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/shell", .{tmp.sub_path});

    const launch = try prepare(arena, io, .{
        .shell = "/bin/bash",
        .workingDirectory = ".",
        .environment = &.{"HOME=/home/someone"},
        .hookDirectory = hook_dir,
    });
    try testing.expectEqual(Shell.bash, launch.shell);
    try testing.expect(launch.marksPrompts);
    try testing.expectEqualStrings("--init-file", launch.argv[1]);

    const written = try std.Io.Dir.cwd().readFileAlloc(io, launch.hookPath.?, arena, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, written, ".bashrc") != null);
    try testing.expect(std.mem.indexOf(u8, written, "133;C") != null);
}

test "zsh keeps its own configuration directory under a second name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hook_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/shell", .{tmp.sub_path});

    const launch = try prepare(arena, io, .{
        .shell = "/bin/zsh",
        .workingDirectory = ".",
        .environment = &.{"ZDOTDIR=/home/someone/.config/zsh"},
        .hookDirectory = hook_dir,
    });
    var saw_original = false;
    var saw_new = false;
    for (launch.environment) |pair| {
        if (std.mem.eql(u8, pair, "ZDOTDIR_ORIGINAL=/home/someone/.config/zsh")) saw_original = true;
        if (std.mem.startsWith(u8, pair, "ZDOTDIR=") and std.mem.indexOf(u8, pair, "zdotdir") != null) saw_new = true;
    }
    try testing.expect(saw_original);
    try testing.expect(saw_new);
}

test "an unknown shell still runs, and says the boundaries are inferred" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const launch = try prepare(arena, threaded.io(), .{
        .shell = "/bin/dash",
        .workingDirectory = ".",
        .hookDirectory = ".zig-cache/tmp/unused",
    });
    try testing.expect(!launch.marksPrompts);
    try testing.expect(launch.hookPath == null);
    try testing.expectEqual(@as(usize, 2), launch.argv.len);
}

test "the shell comes from the environment when it is not named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const launch = try prepare(arena, threaded.io(), .{
        .workingDirectory = ".",
        .environment = &.{ "PATH=/bin", "SHELL=/bin/dash" },
        .hookDirectory = ".zig-cache/tmp/unused",
        .integrate = false,
    });
    try testing.expectEqualStrings("/bin/dash", launch.program);
}

test "a terminal type is added only when the person has not set one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const added = try withTerm(arena, &.{"PATH=/bin"});
    try testing.expectEqual(@as(usize, 2), added.len);
    try testing.expectEqualStrings("TERM=xterm-256color", added[1]);

    const kept = try withTerm(arena, &.{ "TERM=screen", "PATH=/bin" });
    try testing.expectEqual(@as(usize, 2), kept.len);
    try testing.expectEqualStrings("TERM=screen", kept[0]);
}

test "the summary counts commands and names what was inferred" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const outcome: Outcome = .{
        .session = idmod.SessionId.fromRaw(.{ .bytes = [_]u8{0} ** 16 }),
        .exitStatus = 0,
        .blocks = &.{},
        .events = 3,
        .marksPrompts = false,
    };
    try outcome.writeSummary(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "0 commands recorded in 3 events.") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "boundaries were inferred") != null);
}

test "each command line a person types becomes exactly one block" {
    if (!pty_mod.supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const hook_dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/shell", .{tmp.sub_path});

    const launch = prepare(arena, io, .{
        .shell = "/bin/bash",
        .workingDirectory = ".",
        .environment = &.{ "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/root" },
        .hookDirectory = hook_dir,
    }) catch return error.SkipZigTest;
    if (!launch.marksPrompts) return error.SkipZigTest;

    var log = @import("../events/log.zig").Log.init(arena, 17);
    var gen: idmod.Generator = .init(17, 1_788_000_000_000);
    const actor: @import("../events/event.zig").Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "test" };
    var session = try session_mod.Session.init(arena, &log, gen.next(idmod.SessionId), .{
        .working_directory = ".",
        .actor = actor,
    }, try Timestamp.parseIso("2026-09-06T09:00:00Z"));

    session.spawn(launch.program, launch.argv, launch.environment, ".") catch return error.SkipZigTest;
    const pty = session.pty.?;

    // Type only after the shell has drawn its first prompt, the way a person
    // does. Typing into a shell that is still starting is how the first
    // command gets lost, and that is the shell's timing, not the record's.
    var buffer: [8192]u8 = undefined;
    var saw_prompt = false;
    var typed: usize = 0;
    // The second command prints a finish mark of its own, with a guessed
    // token. A program must not be able to close a block that way.
    const lines = [_][]const u8{
        "echo one\n",
        "printf '\\033]133;D;0;token=guessed\\007'\n",
        "false\n",
        "exit\n",
    };
    var rounds: usize = 0;
    while (rounds < 400) : (rounds += 1) {
        if (pty.waitReadable(25)) {
            const n = pty.read(&buffer) catch break;
            if (n == 0) break;
            session.tick(.fromMillis(1));
            try session.consume(buffer[0..n]);
            if (!saw_prompt and session.tracker.integrated) saw_prompt = true;
        }
        if (saw_prompt and typed < lines.len and session.open_block == null) {
            _ = pty.write(lines[typed]) catch break;
            typed += 1;
        }
        if (typed == lines.len) {
            if (session.child) |*child| {
                if (child.poll() != null) break;
            }
        }
    }
    try session.close("the shell exited");

    const index = try block_mod.Index.build(arena, log);
    var commands: std.ArrayList([]const u8) = .empty;
    for (index.blocks.items) |b| {
        if (b.kind != .command) continue;
        try commands.append(arena, b.commandText orelse "");
    }
    if (!saw_prompt) return error.SkipZigTest;

    // One block for each line, with the text the person typed. A DEBUG trap
    // firing inside the prompt used to add blocks nobody asked for; this is
    // the test that catches it coming back.
    try testing.expectEqual(@as(usize, 4), commands.items.len);
    try testing.expectEqualStrings("echo one", commands.items[0]);
    try testing.expect(std.mem.indexOf(u8, commands.items[1], "133;D") != null);
    try testing.expectEqualStrings("false", commands.items[2]);
    try testing.expectEqualStrings("exit", commands.items[3]);

    // Every block was bounded by a mark the shell wrote, not by the forged one
    // that a command printed.
    for (index.blocks.items) |b| {
        if (b.kind != .command) continue;
        try testing.expect(b.boundaryFromShell);
    }

    // The one that failed is recorded as having failed.
    for (index.blocks.items) |b| {
        if (b.commandText) |text| {
            if (std.mem.eql(u8, text, "false")) try testing.expectEqual(block_mod.Status.failed, b.status);
        }
    }
}
