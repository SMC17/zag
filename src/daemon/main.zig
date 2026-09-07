//! zagd — the workspace daemon.
//!
//! The daemon holds a workspace open so that clients, remote people and
//! background agents attach to the same recorded state rather than to a copy
//! of it. It has no user interface: everything it knows is in the event log,
//! and everything it does is written there.
//!
//! It is deliberately conservative. It verifies the log before it writes
//! anything, it refuses to append to a broken log, and it never runs a
//! workflow step that a person has not decided on. A headless process that
//! could act on its own would defeat the capability model the rest of the
//! product is built on.

const std = @import("std");
const zag = @import("zag");

const Command = enum {
    help,
    status,
    verify,
    plan,
    history,
    serve,

    fn parse(text: []const u8) ?Command {
        const table = [_]struct { name: []const u8, command: Command }{
            .{ .name = "help", .command = .help },
            .{ .name = "--help", .command = .help },
            .{ .name = "-h", .command = .help },
            .{ .name = "status", .command = .status },
            .{ .name = "verify", .command = .verify },
            .{ .name = "plan", .command = .plan },
            .{ .name = "history", .command = .history },
            .{ .name = "serve", .command = .serve },
        };
        for (table) |entry| {
            if (std.mem.eql(u8, entry.name, text)) return entry.command;
        }
        return null;
    }
};

pub const help_text =
    \\zagd - holds a workspace open so people, clients and agents share one record.
    \\
    \\Use it like this:
    \\  zagd <command> [--root <directory>]
    \\
    \\Commands
    \\  help                Show this text.
    \\  status              Open the workspace and say what is in it.
    \\  verify              Check the event log and command-output objects.
    \\  plan <workflow>     Say what each step of a workflow would need.
    \\  history <query>     Search what happened, using the history filters.
    \\  serve               Hold the workspace open and report each check.
    \\
    \\Options
    \\  --root <directory>  The workspace to open. The default is this directory.
    \\  --checks <number>   How many checks `serve` runs before it stops.
    \\
    \\The daemon never runs a workflow step on its own. It reports which steps a
    \\person still has to decide on, and stops there.
    \\
;

const Options = struct {
    root: []const u8 = ".",
    checks: usize = 1,
    rest: []const []const u8 = &.{},
};

fn parseOptions(arena: std.mem.Allocator, args: []const []const u8) !Options {
    var options: Options = .{};
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--root")) {
            if (i + 1 >= args.len) return error.MissingOptionValue;
            i += 1;
            options.root = args[i];
        } else if (std.mem.eql(u8, arg, "--checks")) {
            if (i + 1 >= args.len) return error.MissingOptionValue;
            i += 1;
            options.checks = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidCheckCount;
            if (options.checks == 0) return error.InvalidCheckCount;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else {
            try rest.append(arena, arg);
        }
    }
    options.rest = rest.items;
    return options;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const io = init.io;
    var out_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const w = &stdout.interface;

    const args = try init.minimal.args.toSlice(arena);
    const argv = if (args.len > 1) args[1..] else args[0..0];
    if (argv.len == 0) {
        try w.writeAll(help_text);
        try w.flush();
        return 0;
    }
    const command = Command.parse(argv[0]) orelse {
        try w.print("There is no zagd command called \"{s}\". Run zagd help to see the commands.\n", .{argv[0]});
        try w.flush();
        return 2;
    };
    const options = parseOptions(arena, argv[1..]) catch |err| {
        switch (err) {
            error.MissingOptionValue => try w.writeAll("An option is missing its value. Run \"zagd help\" to see the options.\n"),
            error.InvalidCheckCount => try w.writeAll("--checks needs a whole number greater than zero.\n"),
            error.UnknownOption => try w.writeAll("That option is not one zagd knows. Run \"zagd help\" to see the options.\n"),
            else => return err,
        }
        try w.flush();
        return 2;
    };

    const status_code = switch (command) {
        .help => blk: {
            try w.writeAll(help_text);
            break :blk 0;
        },
        .status => try status(arena, io, w, options),
        .verify => try verify(arena, io, w, options),
        .plan => try plan(arena, io, w, options),
        .history => try history(arena, io, w, options),
        .serve => try serve(arena, io, w, options),
    };
    try w.flush();
    return status_code;
}

fn openWorkspace(arena: std.mem.Allocator, io: std.Io, options: Options) !zag.workspace.service.Opened {
    return zag.workspace.service.Service.open(arena, io, .{
        .root = options.root,
        .actor = zag.events.event.Actor.of(zag.core.identity.program("zagd")),
        .now = wallClock(io),
    });
}

/// The wall clock, read through the platform's input and output layer rather
/// than from a global, so a test can drive the daemon with a clock of its own.
fn wallClock(io: std.Io) zag.core.time.Timestamp {
    const raw = std.Io.Timestamp.now(io, .real);
    return .{ .ns = @intCast(raw.nanoseconds) };
}

fn status(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    const opened = try openWorkspace(arena, io, options);
    try opened.report.writeSummary(w);
    if (opened.report.eventCount > 0) {
        const model = try opened.service.workspaceModel();
        var it = model.sessions.iterator();
        while (it.next()) |entry| {
            try w.writeAll("  ");
            try entry.value_ptr.writeLabel(w);
            try w.writeAll("\n");
        }
    }
    const audit = try opened.service.auditContent(io);
    try writeContentStatus(w, audit);
    return if (opened.report.isHealthy() and audit.isHealthy()) 0 else 1;
}

fn writeContentStatus(w: *std.Io.Writer, audit: zag.events.content_store.AuditReport) !void {
    if (audit.isHealthy()) {
        try w.print("  Content store: {d} referenced object(s) verified; no extra entries found.\n", .{audit.references});
        return;
    }
    try w.print("  Content store: {d} issue(s): {d} missing, {d} changed, {d} size mismatch(es), {d} unreferenced and {d} unexpected.\n", .{
        audit.issueCount(),
        audit.missing.len,
        audit.changed.len,
        audit.size_mismatches.len,
        audit.unreferenced.len,
        audit.unexpected.len,
    });
}

fn verify(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    const opened = try openWorkspace(arena, io, options);
    if (!opened.report.logIsHealthy()) {
        try opened.report.writeSummary(w);
        try w.writeAll("Keep the file as it is. A broken log is evidence, not a fault to repair.\n");
        return 1;
    }
    const audit = try opened.service.auditContent(io);
    if (!audit.isHealthy()) {
        try w.writeAll("The event log verified, but the content store did not.\n");
        try writeContentStatus(w, audit);
        try w.writeAll("Run \"zag objects --root <directory>\" for the affected hashes and paths. Nothing was changed.\n");
        return 1;
    }
    try w.print("The log verified end to end: {d} events, each one hashed to the one before it.\n", .{
        opened.report.eventCount,
    });
    try w.print("The content store verified: {d} referenced object(s), with matching hashes and byte counts and no extra entries.\n", .{
        audit.references,
    });
    return 0;
}

fn plan(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    const opened = try openWorkspace(arena, io, options);
    var service = opened.service;
    const flow = try zag.workspace.workflow.buildAndCheck(arena, options.root);
    try flow.writeSummary(arena, w);
    try w.writeAll("\n");
    const run = try service.planWorkflow(flow);
    try run.writeSummary(w);
    return 0;
}

fn history(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    const opened = try openWorkspace(arena, io, options);
    const incomplete = !opened.report.logIsHealthy();
    if (incomplete) {
        try w.writeAll("The log is incomplete or damaged, so these results cover only its verified prefix.\n\n");
    }
    const query_text = try std.mem.join(arena, " ", options.rest);
    const parsed = try zag.workspace.history.parse(arena, query_text);
    for (parsed.problems) |problem| {
        try problem.writeSentence(w);
        try w.writeAll("\n");
    }
    if (!parsed.ok()) return 2;
    const index = try opened.service.blocks();
    const results = try zag.workspace.history.run(arena, index, parsed.query, .{ .now = wallClock(io), .limit = 20 });
    try results.writeList(w);
    return if (incomplete) 1 else 0;
}

/// Hold the workspace open and re-check it. Each check re-reads the log from
/// disk, so a change another process wrote is picked up, and a log that was
/// damaged while the daemon was running is reported rather than extended.
fn serve(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    var checks: usize = 0;
    var worst: u8 = 0;
    while (checks < options.checks) : (checks += 1) {
        var check_arena = std.heap.ArenaAllocator.init(arena);
        defer check_arena.deinit();
        const opened = try openWorkspace(check_arena.allocator(), io, options);
        try opened.report.writeSummary(w);
        const audit = try opened.service.auditContent(io);
        try writeContentStatus(w, audit);
        if (!opened.report.isHealthy() or !audit.isHealthy()) worst = 1;
        try w.flush();
    }
    return worst;
}

const testing = std.testing;

test "the help text names every command" {
    var missing: usize = 0;
    inline for (comptime std.meta.fields(Command)) |field| {
        const name = comptime blk: {
            var buf: [field.name.len]u8 = undefined;
            @memcpy(&buf, field.name);
            break :blk buf;
        };
        if (std.mem.indexOf(u8, help_text, &name) == null) missing += 1;
    }
    try testing.expectEqual(@as(usize, 0), missing);
}

test "the help text passes the product's plain-language rules" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const system = try zag.knowledge.vocabulary.build(arena);
    const report = try zag.language.plain.check(arena, help_text, .{
        .kind = .body,
        .audience = zag.language.audience.new_user,
        .terminology = &system,
    });
    for (report.findings) |finding| {
        if (finding.severity == .blocking or finding.severity == .major) {
            std.debug.print("{s} {d}:{d} {s}\n", .{ finding.rule.code(), finding.line, finding.column, finding.message });
        }
        try testing.expect(finding.severity != .blocking);
        try testing.expect(finding.severity != .major);
    }
}

test "options are read from the argument list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const options = try parseOptions(arena, &.{ "--root", "/tmp/workspace", "status:failed", "--checks", "3" });
    try testing.expectEqualStrings("/tmp/workspace", options.root);
    try testing.expectEqual(@as(usize, 3), options.checks);
    try testing.expectEqual(@as(usize, 1), options.rest.len);
    try testing.expectEqualStrings("status:failed", options.rest[0]);
    try testing.expectError(error.MissingOptionValue, parseOptions(arena, &.{"--root"}));
    try testing.expectError(error.InvalidCheckCount, parseOptions(arena, &.{ "--checks", "zero" }));
    try testing.expectError(error.InvalidCheckCount, parseOptions(arena, &.{ "--checks", "0" }));
    try testing.expectError(error.UnknownOption, parseOptions(arena, &.{"--unknown"}));
}

test "verify includes unreferenced command-output objects" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var store = zag.events.content_store.Store.init(arena, root);
    _ = try store.put("left by a crash");
    try store.flush(io);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const status_code = try verify(arena, io, &writer, .{ .root = root });
    try testing.expectEqual(@as(u8, 1), status_code);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "1 unreferenced") != null);
}

test "history labels results from a damaged log as incomplete" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const workspace = try std.fmt.allocPrint(arena, "{s}/.workspace", .{root});
    try std.Io.Dir.cwd().createDirPath(io, workspace);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{workspace}),
        .data = "not an event\n",
    });

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const status_code = try history(arena, io, &writer, .{ .root = root, .rest = &.{"status:failed"} });
    try testing.expectEqual(@as(u8, 1), status_code);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "verified prefix") != null);
}
