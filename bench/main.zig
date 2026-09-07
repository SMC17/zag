//! Measured throughput for the parts of the workbench that sit in a hot path.
//!
//! Two rules keep these numbers worth reading.
//!
//! First, every result carries its unit, its input size and the build mode it
//! was measured in. A number without those is not a measurement, it is a claim.
//! A debug build is several times slower than a release build, so a benchmark
//! that does not say which it ran in says nothing at all.
//!
//! Second, nothing here is compared against another program. Comparing two
//! terminals means running both on one machine with one workload, which this
//! harness cannot do for you. What it does is make this program's own numbers
//! repeatable, so a change that makes something slower is visible on the day it
//! lands rather than a year later.

const std = @import("std");
const builtin = @import("builtin");
const zag = @import("zag");

/// One measurement, with everything a reader needs to judge it.
///
/// The best of several runs is reported, not the average. On a shared machine
/// the slow runs measure the neighbours; the fastest run is the closest thing
/// to what this code can do. The spread is printed next to it so that a reader
/// can see when the machine was too noisy to trust.
const Result = struct {
    name: []const u8,
    /// What was processed: bytes, events, blocks, queries.
    unit: []const u8,
    count: u64,
    nanoseconds: u64,
    /// The slowest run, so the noise is visible.
    slowestNanoseconds: u64 = 0,
    runs: u32 = 1,
    /// Bytes handled, when the work is byte-shaped. Zero otherwise.
    bytes: u64 = 0,

    /// How much slower the worst run was than the best, as a multiple.
    fn spread(self: Result) f64 {
        if (self.nanoseconds == 0 or self.slowestNanoseconds == 0) return 1;
        return @as(f64, @floatFromInt(self.slowestNanoseconds)) / @as(f64, @floatFromInt(self.nanoseconds));
    }

    fn perSecond(self: Result) f64 {
        if (self.nanoseconds == 0) return 0;
        return @as(f64, @floatFromInt(self.count)) * 1e9 / @as(f64, @floatFromInt(self.nanoseconds));
    }

    fn mibPerSecond(self: Result) f64 {
        if (self.nanoseconds == 0 or self.bytes == 0) return 0;
        const seconds = @as(f64, @floatFromInt(self.nanoseconds)) / 1e9;
        return @as(f64, @floatFromInt(self.bytes)) / (1024.0 * 1024.0) / seconds;
    }

    fn nanosecondsEach(self: Result) f64 {
        if (self.count == 0) return 0;
        return @as(f64, @floatFromInt(self.nanoseconds)) / @as(f64, @floatFromInt(self.count));
    }

    fn write(self: Result, w: *std.Io.Writer) !void {
        try w.print("{s:<34}", .{self.name});
        if (self.bytes > 0) {
            try w.print("{d:>10.1} MiB/s", .{self.mibPerSecond()});
        } else {
            try w.print("{d:>10.0} {s}/s", .{ self.perSecond(), self.unit });
        }
        try w.print("   {d:>9.0} ns each   {d} {s}", .{
            self.nanosecondsEach(),
            self.count,
            self.unit,
        });
        try w.print("   best of {d}, spread {d:.1}x\n", .{ self.runs, self.spread() });
    }
};

/// Keeps the best and worst of several timed runs.
const Measure = struct {
    best: u64 = std.math.maxInt(u64),
    worst: u64 = 0,
    runs: u32 = 0,

    fn record(self: *Measure, nanoseconds: u64) void {
        self.runs += 1;
        if (nanoseconds < self.best) self.best = nanoseconds;
        if (nanoseconds > self.worst) self.worst = nanoseconds;
    }

    fn into(self: Measure, name: []const u8, unit: []const u8, count: u64, bytes: u64) Result {
        return .{
            .name = name,
            .unit = unit,
            .count = count,
            .bytes = bytes,
            .nanoseconds = self.best,
            .slowestNanoseconds = self.worst,
            .runs = self.runs,
        };
    }
};

const Clock = struct {
    io: std.Io,
    started: i96,

    fn start(io: std.Io) Clock {
        return .{ .io = io, .started = std.Io.Timestamp.now(io, .awake).nanoseconds };
    }

    fn elapsed(self: Clock) u64 {
        const now = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        const delta = now - self.started;
        return if (delta < 0) 0 else @intCast(delta);
    }
};

/// A stream that looks like real terminal output: mostly text, with the colour
/// changes, cursor moves and semantic marks a shell actually emits. Measuring a
/// parser on plain text alone flatters it.
fn buildStream(arena: std.mem.Allocator, target_bytes: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var line: usize = 0;
    while (out.items.len < target_bytes) : (line += 1) {
        switch (line % 8) {
            0 => try out.appendSlice(arena, "\x1b]133;A\x07\x1b[1;32muser@host\x1b[0m:\x1b[1;34m~/work\x1b[0m$ \x1b]133;B\x07"),
            1 => try out.appendSlice(arena, "zig build test --summary all\r\n\x1b]133;C;cmdline=zig build test\x07"),
            2 => try out.appendSlice(arena, "\x1b[2mcompiling\x1b[0m src/terminal/vt.zig ................. \x1b[32mok\x1b[0m\r\n"),
            3 => try out.appendSlice(arena, "test: a stream of plain text with no escape sequences at all in it\r\n"),
            4 => try out.appendSlice(arena, "\x1b[38;5;214mwarning\x1b[0m: unused variable 'index' in a fairly long line of output\r\n"),
            5 => try out.appendSlice(arena, "\x1b[Hcursor home, then \x1b[10;20Hsomewhere else, then \x1b[Kclear to end\r\n"),
            6 => try out.appendSlice(arena, "wide characters and accents: \u{4f60}\u{597d} caf\u{e9} na\u{ef}ve \u{1f600} mixed with ascii\r\n"),
            else => try out.appendSlice(arena, "\x1b]133;D;0\x07"),
        }
    }
    return out.items;
}

fn benchmarkVtParser(arena: std.mem.Allocator, io: std.Io, runs: usize) anyerror!Result {
    const stream = try buildStream(arena, 8 << 20);
    var screen = try zag.terminal.grid.Screen.init(arena, 120, 40, 10_000);

    // One pass first, so the measurement is not paying for first-touch page
    // faults on the screen and the scrollback.
    try screen.write(stream[0..@min(stream.len, 1 << 16)]);

    var measure: Measure = .{};
    for (0..runs) |_| {
        const clock = Clock.start(io);
        try screen.write(stream);
        measure.record(clock.elapsed());
    }
    return measure.into("terminal stream into the screen", "bytes", stream.len, stream.len);
}

fn benchmarkPlainText(arena: std.mem.Allocator, io: std.Io, runs: usize) anyerror!Result {
    var text: std.ArrayList(u8) = .empty;
    while (text.items.len < (8 << 20)) {
        try text.appendSlice(arena, "the quick brown fox jumps over the lazy dog and keeps on running\r\n");
    }
    var screen = try zag.terminal.grid.Screen.init(arena, 120, 40, 10_000);
    try screen.write(text.items[0..@min(text.items.len, 1 << 16)]);

    var measure: Measure = .{};
    for (0..runs) |_| {
        const clock = Clock.start(io);
        try screen.write(text.items);
        measure.record(clock.elapsed());
    }
    return measure.into("plain text into the screen", "bytes", text.items.len, text.items.len);
}

fn benchmarkLogAppend(arena: std.mem.Allocator, io: std.Io, runs: usize) anyerror!Result {
    const count: usize = 50_000;
    var gen: zag.core.id.Generator = .init(5, 1_788_000_000_000);
    const actor: zag.events.event.Actor = .{
        .id = gen.next(zag.core.id.ActorId),
        .kind = .person,
        .label = "bench",
    };
    const session = gen.next(zag.core.id.SessionId);
    const at = try zag.core.time.Timestamp.parseIso("2026-09-06T09:00:00Z");

    var measure: Measure = .{};
    for (0..runs) |_| {
        var log = zag.events.log.Log.init(arena, 5);
        try log.entries.ensureTotalCapacity(arena, count);
        const clock = Clock.start(io);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            _ = try log.append(.{ .user_message = .{
                .session = session,
                .text = "a message of the sort a person types into the workbench",
            } }, .{ .at = at, .actor = actor });
        }
        measure.record(clock.elapsed());
    }
    return measure.into("events appended and hash-chained", "events", count, 0);
}

fn benchmarkLogVerify(arena: std.mem.Allocator, io: std.Io, runs: usize) anyerror!Result {
    const count: usize = 50_000;
    var log = zag.events.log.Log.init(arena, 6);
    var gen: zag.core.id.Generator = .init(6, 1_788_000_000_000);
    const actor: zag.events.event.Actor = .{
        .id = gen.next(zag.core.id.ActorId),
        .kind = .person,
        .label = "bench",
    };
    const session = gen.next(zag.core.id.SessionId);
    const at = try zag.core.time.Timestamp.parseIso("2026-09-06T09:00:00Z");
    var i: usize = 0;
    while (i < count) : (i += 1) {
        _ = try log.append(.{ .user_message = .{ .session = session, .text = "verify me" } }, .{ .at = at, .actor = actor });
    }

    var measure: Measure = .{};
    for (0..runs) |_| {
        const clock = Clock.start(io);
        const broken = try log.verify();
        measure.record(clock.elapsed());
        if (broken != null) return error.LogDoesNotVerify;
    }
    return measure.into("events verified end to end", "events", count, 0);
}

/// Build a log of finished commands, the shape a real session produces.
fn buildCommandLog(arena: std.mem.Allocator, commands: usize) !zag.events.log.Log {
    var log = zag.events.log.Log.init(arena, 9);
    var gen: zag.core.id.Generator = .init(9, 1_788_000_000_000);
    const actor: zag.events.event.Actor = .{
        .id = gen.next(zag.core.id.ActorId),
        .kind = .person,
        .label = "bench",
    };
    const session = gen.next(zag.core.id.SessionId);
    var at = try zag.core.time.Timestamp.parseIso("2026-09-01T09:00:00Z");
    const texts = [_][]const u8{
        "zig build test",
        "git status",
        "zig build check",
        "rg --files src",
        "git commit -m 'a change'",
    };

    _ = try log.append(.{ .session_opened = .{
        .session = session,
        .workingDirectory = "/home/user/zag",
    } }, .{ .at = at, .actor = actor });

    var i: usize = 0;
    while (i < commands) : (i += 1) {
        const block = gen.next(zag.core.id.BlockId);
        at = at.addNanos(60 * zag.core.time.ns_per_s);
        _ = try log.append(.{ .command_submitted = .{
            .block = block,
            .session = session,
            .commandText = texts[i % texts.len],
            .workingDirectory = "/home/user/zag",
            .boundaryFromShell = true,
        } }, .{ .at = at, .actor = actor });
        at = at.addNanos(2 * zag.core.time.ns_per_s);
        _ = try log.append(.{ .command_finished = .{
            .block = block,
            .session = session,
            .exitStatus = if (i % 7 == 0) 1 else 0,
            .duration = .fromSeconds(2),
        } }, .{ .at = at, .actor = actor });
    }
    return log;
}

fn benchmarkBlockFold(arena: std.mem.Allocator, io: std.Io, runs: usize) anyerror!Result {
    const commands: usize = 20_000;
    const log = try buildCommandLog(arena, commands);

    var measure: Measure = .{};
    var folded: usize = 0;
    for (0..runs) |_| {
        const clock = Clock.start(io);
        const index = try zag.workspace.block.Index.build(arena, log);
        measure.record(clock.elapsed());
        folded = index.count();
    }
    if (folded < commands) return error.FoldLostBlocks;
    return measure.into("blocks folded from the log", "blocks", folded, 0);
}

/// The same query, with the index in front of it.
///
/// Both numbers are reported so the pair can be compared on one machine, which
/// is the only comparison that means anything. The index is built once here
/// because that is how a long-lived surface would hold it; the command-line
/// tool builds one per query and pays for it, which is honest at these sizes
/// and would not be at a hundred times them.
fn benchmarkIndexedQuery(arena: std.mem.Allocator, io: std.Io, runs: usize) anyerror!Result {
    const commands: usize = 20_000;
    const log = try buildCommandLog(arena, commands);
    const index = try zag.workspace.block.Index.build(arena, log);
    const lookup = try zag.workspace.index.Lookup.build(arena, index);
    const now = try zag.core.time.Timestamp.parseIso("2026-09-30T09:00:00Z");
    const parsed = try zag.workspace.history.parse(arena, "status:failed zig build");

    var measure: Measure = .{};
    var matched: usize = 0;
    for (0..runs) |_| {
        const clock = Clock.start(io);
        const results = try zag.workspace.history.run(arena, index, parsed.query, .{
            .now = now,
            .limit = 20,
            .lookup = &lookup,
        });
        measure.record(clock.elapsed());
        matched += results.matchCount;
    }
    if (matched == 0) return error.QueryMatchedNothing;
    return measure.into("the same query, through the index", "queries", 1, 0);
}

/// Building the index itself, which the command-line tool pays for every run.
fn benchmarkIndexBuild(arena: std.mem.Allocator, io: std.Io, runs: usize) anyerror!Result {
    const commands: usize = 20_000;
    const log = try buildCommandLog(arena, commands);
    const index = try zag.workspace.block.Index.build(arena, log);

    var measure: Measure = .{};
    var tokens: usize = 0;
    for (0..runs) |_| {
        var scratch = std.heap.ArenaAllocator.init(arena);
        defer scratch.deinit();
        const clock = Clock.start(io);
        const lookup = try zag.workspace.index.Lookup.build(scratch.allocator(), index);
        measure.record(clock.elapsed());
        tokens += lookup.tokenCount();
    }
    std.mem.doNotOptimizeAway(tokens);
    return measure.into("block index built over 20k blocks", "blocks", commands, 0);
}

fn benchmarkHistoryQuery(arena: std.mem.Allocator, io: std.Io, runs: usize) anyerror!Result {
    const commands: usize = 20_000;
    const log = try buildCommandLog(arena, commands);
    const index = try zag.workspace.block.Index.build(arena, log);
    const now = try zag.core.time.Timestamp.parseIso("2026-09-30T09:00:00Z");
    const parsed = try zag.workspace.history.parse(arena, "status:failed zig build");

    var measure: Measure = .{};
    var matched: usize = 0;
    for (0..runs) |_| {
        const clock = Clock.start(io);
        const results = try zag.workspace.history.run(arena, index, parsed.query, .{ .now = now, .limit = 20 });
        measure.record(clock.elapsed());
        matched += results.matchCount;
    }
    if (matched == 0) return error.QueryMatchedNothing;
    return measure.into("history query over 20k blocks", "queries", 1, 0);
}

fn benchmarkEditor(_: std.mem.Allocator, io: std.Io, runs: usize) anyerror!Result {
    // The editor frees as it goes, so it is measured against an allocator that
    // actually reuses memory. An arena would turn every reallocation into a
    // fresh block and measure the arena instead of the buffer.
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const keystrokes: usize = 200_000;
    var measure: Measure = .{};
    for (0..runs) |_| {
        var doc = try zag.editor.document.Document.init(gpa, "");
        defer doc.deinit();
        const clock = Clock.start(io);
        var i: usize = 0;
        while (i < keystrokes) : (i += 1) {
            const byte: u8 = @intCast('a' + (i % 26));
            try doc.replace(.{ .start = doc.len(), .end = doc.len() }, &.{byte}, .typing);
        }
        measure.record(clock.elapsed());
        if (doc.len() != keystrokes) return error.LostKeystrokes;
    }
    return measure.into("keystrokes into the editor buffer", "keys", keystrokes, 0);
}

fn benchmarkPlainLanguage(arena: std.mem.Allocator, io: std.Io, runs: usize) anyerror!Result {
    // The size of a long document, not of a corpus. This is the input the
    // checker actually sees.
    var text: std.ArrayList(u8) = .empty;
    while (text.items.len < (64 << 10)) {
        try text.appendSlice(arena,
            \\Run the tests before you propose a change. Every change is proposed
            \\with a green test run behind it. If a check fails, fix the cause.
            \\
        );
    }
    const system = try zag.knowledge.vocabulary.build(arena);
    var measure: Measure = .{};
    for (0..runs) |_| {
        const clock = Clock.start(io);
        const report = try zag.language.plain.check(arena, text.items, .{
            .kind = .body,
            .audience = zag.language.audience.developer,
            .terminology = &system,
        });
        measure.record(clock.elapsed());
        std.mem.doNotOptimizeAway(report.findings.len);
    }
    return measure.into("prose through the language rules", "bytes", text.items.len, text.items.len);
}

fn benchmarkLineIndex(arena: std.mem.Allocator, io: std.Io, runs: usize) anyerror!Result {
    // A large document, the size a checker or an editor really opens.
    var text: std.ArrayList(u8) = .empty;
    while (text.items.len < (4 << 20)) {
        try text.appendSlice(arena, "a line of ordinary prose, about sixty characters long here\n");
    }

    var measure: Measure = .{};
    for (0..runs) |_| {
        var scratch = std.heap.ArenaAllocator.init(arena);
        defer scratch.deinit();
        const clock = Clock.start(io);
        const index = try zag.language.text.LineIndex.build(scratch.allocator(), text.items);
        measure.record(clock.elapsed());
        std.mem.doNotOptimizeAway(index.starts.len);
    }
    return measure.into("line breaks found in a document", "bytes", text.items.len, text.items.len);
}

/// Grouping a turn's tool calls into waves.
///
/// The scheduler runs once per turn, before any work is done, so it has to be
/// cheap enough that a turn asking for sixteen calls does not pay for the
/// planning. Measured on a turn of the widest shape the budget allows, mixing
/// reads that overlap with writes and a barrier in the middle.
fn benchmarkSchedule(arena: std.mem.Allocator, io: std.Io, runs: usize) anyerror!Result {
    const turns: usize = 20_000;
    const width: usize = 16;

    // The same shape every turn: a barrier in the middle, some reads that share
    // a directory with a write, and some that do not.
    const claims = try arena.alloc(?zag.ai.schedule.Claim, width);
    for (claims, 0..) |*slot, index| {
        slot.* = switch (index % 8) {
            0 => .everything,
            1, 2 => .{ .on = .{
                .resource = .{ .path = try std.fmt.allocPrint(arena, "src/shared-{d}", .{index % 3}) },
                .access = .write,
            } },
            else => .{ .on = .{
                .resource = .{ .path = try std.fmt.allocPrint(arena, "src/file-{d}.zig", .{index}) },
                .access = .read,
            } },
        };
    }

    var measure: Measure = .{};
    for (0..runs) |_| {
        var scratch = std.heap.ArenaAllocator.init(arena);
        defer scratch.deinit();
        const scratch_arena = scratch.allocator();
        const clock = Clock.start(io);
        var planned: usize = 0;
        for (0..turns) |_| {
            const waves = try zag.ai.schedule.plan(scratch_arena, claims);
            planned += waves.len;
        }
        measure.record(clock.elapsed());
        std.mem.doNotOptimizeAway(planned);
    }
    return measure.into("tool-call scheduling", "turns", turns, 0);
}

fn benchmarkLineage(arena: std.mem.Allocator, io: std.Io, runs: usize) anyerror!Result {
    // A day of recorded work: commands, their output, and the files they
    // touched, with the files shared between them so the graph has real edges.
    const commands: usize = 20_000;
    var log = try buildCommandLog(arena, commands);
    var gen: zag.core.id.Generator = .init(9, 1_788_000_000_000);
    const actor: zag.events.event.Actor = .{
        .id = gen.next(zag.core.id.ActorId),
        .kind = .agent,
        .label = "agent",
    };
    const session = gen.next(zag.core.id.SessionId);
    var index: usize = 0;
    while (index < commands) : (index += 1) {
        _ = try log.append(.{ .file_changed = .{
            .session = session,
            .path = try std.fmt.allocPrint(arena, "src/file-{d}.zig", .{index % 500}),
            .changeKind = .modified,
        } }, .{ .at = .{ .ns = 1_788_000_000_000_000_000 + @as(i64, @intCast(index)) }, .actor = actor });
    }

    var measure: Measure = .{};
    for (0..runs) |_| {
        var scratch = std.heap.ArenaAllocator.init(arena);
        defer scratch.deinit();
        const clock = Clock.start(io);
        const dag = try zag.events.lineage.Dag.build(scratch.allocator(), log);
        const path = try dag.criticalPath();
        measure.record(clock.elapsed());
        std.mem.doNotOptimizeAway(path.items.len);
    }
    const events = log.entries.items.len;
    return measure.into("dependency graph built and its critical path", "events", events, 0);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var out_buffer: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const w = &stdout.interface;
    defer w.flush() catch {};

    try w.print("zag {s} benchmarks\n", .{zag.version});
    try w.print("Built in {s} mode for {s} on {s}.\n", .{
        @tagName(builtin.mode),
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
    });
    if (builtin.mode == .Debug) {
        try w.writeAll("\nThis is a debug build. The numbers below are several times lower than a\n");
        try w.writeAll("release build gives. Run \"zig build bench -Doptimize=ReleaseFast\" to measure.\n");
    }
    try w.writeAll("\n");

    // Each benchmark gets its own arena. Sharing one means the later
    // benchmarks allocate out of a much larger heap than the earlier ones, and
    // then measure that difference rather than their own work.
    const runs: usize = 5;
    const Benchmark = struct {
        run: *const fn (std.mem.Allocator, std.Io, usize) anyerror!Result,
        times: usize,
    };
    const benchmarks = [_]Benchmark{
        .{ .run = benchmarkVtParser, .times = runs },
        .{ .run = benchmarkPlainText, .times = runs },
        .{ .run = benchmarkLogAppend, .times = runs },
        .{ .run = benchmarkLogVerify, .times = runs },
        .{ .run = benchmarkBlockFold, .times = runs },
        .{ .run = benchmarkHistoryQuery, .times = 20 },
        .{ .run = benchmarkEditor, .times = runs },
        .{ .run = benchmarkPlainLanguage, .times = runs },
        .{ .run = benchmarkLineIndex, .times = runs },
        .{ .run = benchmarkLineage, .times = runs },
        .{ .run = benchmarkSchedule, .times = runs },
        .{ .run = benchmarkIndexBuild, .times = runs },
        .{ .run = benchmarkIndexedQuery, .times = runs * 4 },
    };
    for (benchmarks) |benchmark| {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const result = try benchmark.run(scratch.allocator(), io, benchmark.times);
        try result.write(w);
        try w.flush();
    }

    try w.writeAll(
        \\
        \\What these numbers are: this program's own throughput, on this machine,
        \\in this build mode, taking the best of several runs. They are here so
        \\that a change which makes something slower is noticed on the day it
        \\lands. A spread far above 1.0 means the machine was busy with other
        \\work, and the numbers from that run are worth little.
        \\
        \\What they are not: portable. The same commit measured 75 MiB/s of
        \\terminal stream on one cloud machine and 56 MiB/s on another, with no
        \\change to the code. Compare a number here only with another number
        \\from the same machine.
        \\
        \\Nor are they a comparison with another terminal. That takes both
        \\programs, one machine and one workload, and this harness runs only one
        \\of the two.
        \\
    );
    return 0;
}
