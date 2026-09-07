//! Structured history: search over what happened, not over a text file.
//!
//! A shell history file is a list of strings. It cannot answer "which test
//! commands failed on this branch last week", because it never recorded the
//! branch, the result or the time. The event log did record all three, so
//! history here is a query over blocks.
//!
//! The query language is written for people who are in a hurry:
//!
//!     zig build            bare words match the command text
//!     status:failed        a filter, written field:value
//!     dir:/home/user/zag   a directory, matched by prefix
//!     branch:main          the branch the block ran on
//!     actor:agent          who ran it
//!     kind:command         the kind of block
//!     since:2026-09-01     nothing older than this date
//!     until:2026-09-05     nothing newer than this date
//!     exit:1               the exit status the command finished with
//!
//! Unknown filter names are reported rather than ignored, because a query that
//! silently matches everything is worse than a query that fails.

const std = @import("std");
const block_mod = @import("block.zig");
const index_mod = @import("index.zig");
const timeutil = @import("../core/time.zig");
const provenance = @import("../data/provenance.zig");

pub const Block = block_mod.Block;
pub const Timestamp = timeutil.Timestamp;

pub const ParseError = error{
    UnknownField,
    UnknownStatus,
    UnknownKind,
    UnknownActor,
    BadDate,
    BadNumber,
    OutOfMemory,
};

/// Why a query could not be read, in a sentence a person can act on.
pub const Problem = struct {
    /// The part of the query that caused the problem.
    term: []const u8,
    /// What went wrong. One sentence, plain language, no error codes.
    message: []const u8,

    pub fn writeSentence(self: Problem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} in \"{s}\".", .{ self.message, self.term });
    }
};

/// A parsed query. Every field is optional; an empty query matches everything.
pub const Query = struct {
    /// Words that must all appear in the command text, case-insensitively.
    words: []const []const u8 = &.{},
    status: ?block_mod.Status = null,
    kind: ?block_mod.Kind = null,
    actor: ?provenance.ProducerKind = null,
    /// Matched as a path prefix, so `dir:/home/user` includes everything below.
    directory: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    exit_status: ?u8 = null,
    since: ?Timestamp = null,
    until: ?Timestamp = null,
    /// When true, only blocks whose boundaries came from shell integration are
    /// returned. Their timings are the only ones worth measuring.
    shell_marked_only: bool = false,

    pub fn matches(self: Query, b: Block) bool {
        if (self.status) |s| if (b.status != s) return false;
        if (self.kind) |k| if (b.kind != k) return false;
        if (self.actor) |a| if (b.actor.kind != a) return false;
        if (self.exit_status) |code| {
            const actual = b.exitStatus orelse return false;
            if (actual != code) return false;
        }
        if (self.shell_marked_only and !b.boundaryFromShell) return false;
        if (self.directory) |dir| {
            const cwd = b.workingDirectory orelse return false;
            if (!isUnderDirectory(cwd, dir)) return false;
        }
        if (self.branch) |branch| {
            const git = b.git orelse return false;
            const actual = git.branch orelse return false;
            if (!std.mem.eql(u8, actual, branch)) return false;
        }
        if (self.repository) |repository| {
            const git = b.git orelse return false;
            const actual = git.repository orelse return false;
            if (!std.mem.eql(u8, actual, repository)) return false;
        }
        if (self.since) |t| if (b.createdAt.ns < t.ns) return false;
        if (self.until) |t| if (b.createdAt.ns > t.ns) return false;
        for (self.words) |word| {
            const command = b.commandText orelse return false;
            if (std.ascii.indexOfIgnoreCase(command, word) == null) return false;
        }
        return true;
    }

    /// The query, written back as a sentence. Used in result headers and in
    /// the empty-result message, so a person can see what was actually asked.
    pub fn writeSentence(self: Query, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var wrote_any = false;
        if (self.words.len > 0) {
            try w.writeAll("commands containing ");
            for (self.words, 0..) |word, i| {
                if (i > 0) try w.writeAll(" and ");
                try w.print("\"{s}\"", .{word});
            }
            wrote_any = true;
        } else {
            try w.writeAll("all blocks");
            wrote_any = true;
        }
        _ = &wrote_any;
        if (self.kind) |k| try w.print(", of kind {s}", .{@tagName(k)});
        if (self.status) |s| try w.print(", which {s}", .{s.text()});
        if (self.exit_status) |code| try w.print(", with exit status {d}", .{code});
        if (self.actor) |a| try w.print(", run by {s}", .{@tagName(a)});
        if (self.directory) |dir| try w.print(", under {s}", .{dir});
        if (self.branch) |branch| try w.print(", on branch {s}", .{branch});
        if (self.repository) |repository| try w.print(", in repository {s}", .{repository});
        if (self.shell_marked_only) try w.writeAll(", with boundaries from shell integration");
        if (self.since) |t| {
            var buf: [Timestamp.text_len_max]u8 = undefined;
            try w.print(", since {s}", .{t.toIso(&buf, .second)});
        }
        if (self.until) |t| {
            var buf: [Timestamp.text_len_max]u8 = undefined;
            try w.print(", until {s}", .{t.toIso(&buf, .second)});
        }
        try w.writeAll(".");
    }
};

/// True when `path` is `prefix` itself or lies below it. Compared segment by
/// segment, so `/home/user/zagreb` is not under `/home/user/zag`.
fn isUnderDirectory(path: []const u8, prefix: []const u8) bool {
    const trimmed = if (prefix.len > 1 and prefix[prefix.len - 1] == '/') prefix[0 .. prefix.len - 1] else prefix;
    if (!std.mem.startsWith(u8, path, trimmed)) return false;
    if (path.len == trimmed.len) return true;
    if (trimmed.len == 1 and trimmed[0] == '/') return true;
    return path[trimmed.len] == '/';
}

pub const Parsed = struct {
    query: Query,
    problems: []const Problem,

    pub fn ok(self: Parsed) bool {
        return self.problems.len == 0;
    }
};

/// Read a query written by a person. Problems are collected rather than thrown,
/// so one typo does not hide the rest of the query.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!Parsed {
    var words: std.ArrayList([]const u8) = .empty;
    var problems: std.ArrayList(Problem) = .empty;
    var query: Query = .{};

    var it = std.mem.tokenizeAny(u8, text, " \t\n");
    while (it.next()) |term| {
        const colon = std.mem.indexOfScalar(u8, term, ':') orelse {
            try words.append(arena, term);
            continue;
        };
        const field = term[0..colon];
        const value = term[colon + 1 ..];
        if (value.len == 0) {
            try problems.append(arena, .{ .term = term, .message = "This filter has no value" });
            continue;
        }
        if (std.mem.eql(u8, field, "status")) {
            query.status = std.meta.stringToEnum(block_mod.Status, value) orelse {
                try problems.append(arena, .{
                    .term = term,
                    .message = "Use one of running, succeeded, failed, denied, cancelled or unknown",
                });
                continue;
            };
        } else if (std.mem.eql(u8, field, "kind")) {
            query.kind = std.meta.stringToEnum(block_mod.Kind, value) orelse {
                try problems.append(arena, .{
                    .term = term,
                    .message = "Use one of command, agent_run, tool_call, file_change, approval or message",
                });
                continue;
            };
        } else if (std.mem.eql(u8, field, "actor")) {
            query.actor = std.meta.stringToEnum(provenance.ProducerKind, value) orelse {
                try problems.append(arena, .{
                    .term = term,
                    .message = "Use one of person, shell, agent, background_agent, remote_person, system or integration",
                });
                continue;
            };
        } else if (std.mem.eql(u8, field, "dir") or std.mem.eql(u8, field, "directory")) {
            query.directory = value;
        } else if (std.mem.eql(u8, field, "branch")) {
            query.branch = value;
        } else if (std.mem.eql(u8, field, "repo") or std.mem.eql(u8, field, "repository")) {
            query.repository = value;
        } else if (std.mem.eql(u8, field, "exit")) {
            query.exit_status = std.fmt.parseInt(u8, value, 10) catch {
                try problems.append(arena, .{ .term = term, .message = "Exit status is a whole number from 0 to 255" });
                continue;
            };
        } else if (std.mem.eql(u8, field, "since")) {
            query.since = parseMoment(value) catch {
                try problems.append(arena, .{ .term = term, .message = "Write the date as 2026-09-01 or 2026-09-01T08:00:00Z" });
                continue;
            };
        } else if (std.mem.eql(u8, field, "until")) {
            query.until = parseMoment(value) catch {
                try problems.append(arena, .{ .term = term, .message = "Write the date as 2026-09-01 or 2026-09-01T08:00:00Z" });
                continue;
            };
        } else if (std.mem.eql(u8, field, "marked")) {
            query.shell_marked_only = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes");
        } else {
            try problems.append(arena, .{ .term = term, .message = "There is no filter with this name" });
        }
    }
    query.words = words.items;
    return .{ .query = query, .problems = problems.items };
}

/// A date on its own means midnight UTC on that date.
fn parseMoment(text: []const u8) timeutil.ParseError!Timestamp {
    if (text.len == 10) {
        var buf: [21]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}T00:00:00Z", .{text}) catch return error.InvalidDate;
        return Timestamp.parseIso(full);
    }
    return Timestamp.parseIso(text);
}

/// One result, with the numbers that decided its position.
pub const Hit = struct {
    block: Block,
    /// How many blocks in the history ran this exact command text.
    repeatCount: u32 = 1,
    /// The most recent time this command text ran.
    lastRun: Timestamp,
    /// Higher is better. Recency and repetition both raise it; a failure
    /// lowers it, because a person searching history usually wants the form of
    /// the command that worked.
    score: f64 = 0,
};

pub const Results = struct {
    arena: std.mem.Allocator,
    query: Query,
    hits: []const Hit,
    /// Blocks that matched before duplicates were folded together.
    matchCount: usize,

    /// The result header, written for a person, with no invented precision.
    ///
    /// The count comes first, then the search on its own line, so a reader sees
    /// the answer before the question and can still check what was asked.
    pub fn writeSummary(self: Results, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.matchCount == 0) {
            try w.writeAll("Nothing matched.\n");
        } else if (self.hits.len == self.matchCount) {
            try w.print("{d} block", .{self.matchCount});
            if (self.matchCount != 1) try w.writeAll("s");
            try w.writeAll(" matched.\n");
        } else {
            try w.print("{d} blocks matched, {d} after repeats were folded together.\n", .{ self.matchCount, self.hits.len });
        }
        try w.writeAll("Search: ");
        try self.query.writeSentence(w);
    }

    pub fn writeList(self: Results, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.writeSummary(w);
        try w.writeAll("\n\n");
        for (self.hits) |hit| {
            var buf: [Timestamp.text_len_max]u8 = undefined;
            try w.print("{s}  ", .{hit.lastRun.toIso(&buf, .second)});
            try hit.block.writeSummary(w);
            if (hit.repeatCount > 1) try w.print("  ({d} runs)", .{hit.repeatCount});
            try w.writeAll("\n");
        }
    }
};

pub const Options = struct {
    /// Fold blocks that ran the same command text into one hit.
    foldRepeats: bool = true,
    /// Zero means no limit.
    limit: usize = 0,
    /// The moment "recent" is measured from. Callers pass the clock; tests pass
    /// a fixed value, so ranking is deterministic.
    now: Timestamp,
    /// Narrows the blocks worth asking about, when one has been built.
    ///
    /// It never decides a match — the same matcher answers either way, on
    /// whatever survives. An index that changed an answer would tell a person
    /// something false about their own history, which is worse than being slow.
    lookup: ?*const index_mod.Lookup = null,
};

/// Run a query over a block index.
pub fn run(arena: std.mem.Allocator, index: block_mod.Index, query: Query, options: Options) !Results {
    var hits: std.ArrayList(Hit) = .empty;
    var by_command: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var match_count: usize = 0;

    // Which blocks to ask. With no lookup, or one built over a different set of
    // blocks, that is all of them — a mismatched lookup would answer about the
    // wrong history, so it is ignored rather than trusted.
    const usable = if (options.lookup) |lookup|
        (if (lookup.blocks == index.blocks.items.len) lookup else null)
    else
        null;

    var narrowed: ?index_mod.Set = null;
    if (usable) |lookup| narrowed = try lookup.candidates(arena, query);

    var walk: ?index_mod.Set.Iterator = if (narrowed) |set| set.iterate() else null;
    var cursor: usize = 0;
    while (true) {
        const position = if (walk) |*iterator| (iterator.next() orelse break) else blk: {
            if (cursor >= index.blocks.items.len) break;
            defer cursor += 1;
            break :blk cursor;
        };
        const b = index.blocks.items[position];
        if (!query.matches(b)) continue;
        match_count += 1;
        const command = b.commandText orelse "";
        if (options.foldRepeats and command.len > 0) {
            if (by_command.get(command)) |at| {
                const hit = &hits.items[at];
                hit.repeatCount += 1;
                if (b.createdAt.ns > hit.lastRun.ns) {
                    hit.lastRun = b.createdAt;
                    // The newest run is the one shown, so the status and the
                    // directory on screen are the current ones.
                    hit.block = b;
                }
                continue;
            }
            try by_command.put(arena, command, hits.items.len);
        }
        try hits.append(arena, .{ .block = b, .lastRun = b.createdAt });
    }

    for (hits.items) |*hit| hit.score = score(hit.*, options.now);
    std.mem.sort(Hit, hits.items, {}, moreRelevant);

    var out: []const Hit = hits.items;
    if (options.limit > 0 and out.len > options.limit) out = out[0..options.limit];
    return .{ .arena = arena, .query = query, .hits = out, .matchCount = match_count };
}

fn moreRelevant(_: void, a: Hit, b: Hit) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.lastRun.ns > b.lastRun.ns;
}

/// Recency and repetition raise the score; a command whose newest run failed is
/// pushed down. The weights are stated here rather than tuned invisibly, so the
/// ordering can be explained to anyone who asks why a result came first.
fn score(hit: Hit, now: Timestamp) f64 {
    const age_days = @as(f64, @floatFromInt(@max(now.ns - hit.lastRun.ns, 0))) / @as(f64, @floatFromInt(timeutil.ns_per_day));
    // Half the recency weight is lost every seven days.
    const recency = std.math.pow(f64, 0.5, age_days / 7.0);
    const repetition = @log(@as(f64, @floatFromInt(hit.repeatCount)) + 1.0);
    const penalty: f64 = switch (hit.block.status) {
        .succeeded => 0,
        .running => 0.1,
        .failed, .unknown => 0.5,
        .denied, .cancelled => 0.75,
    };
    return recency * 2.0 + repetition - penalty;
}

/// What the workbench ran most often, for the session summary and for the
/// "what does this person actually do" view in the workspace report.
pub const Frequency = struct {
    commandText: []const u8,
    runCount: u32,
    failureCount: u32,

    pub fn failureRate(self: Frequency) f64 {
        if (self.runCount == 0) return 0;
        return @as(f64, @floatFromInt(self.failureCount)) / @as(f64, @floatFromInt(self.runCount));
    }
};

pub fn frequencies(arena: std.mem.Allocator, index: block_mod.Index, limit: usize) ![]const Frequency {
    var by_command: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var out: std.ArrayList(Frequency) = .empty;
    for (index.blocks.items) |b| {
        if (b.kind != .command) continue;
        const command = b.commandText orelse continue;
        const at = by_command.get(command) orelse blk: {
            try by_command.put(arena, command, out.items.len);
            try out.append(arena, .{ .commandText = command, .runCount = 0, .failureCount = 0 });
            break :blk out.items.len - 1;
        };
        out.items[at].runCount += 1;
        if (b.status == .failed) out.items[at].failureCount += 1;
    }
    std.mem.sort(Frequency, out.items, {}, moreFrequent);
    if (limit > 0 and out.items.len > limit) return out.items[0..limit];
    return out.items;
}

fn moreFrequent(_: void, a: Frequency, b: Frequency) bool {
    if (a.runCount != b.runCount) return a.runCount > b.runCount;
    return std.mem.lessThan(u8, a.commandText, b.commandText);
}

const testing = std.testing;
const idmod = @import("../core/id.zig");
const event_mod = @import("../events/event.zig");
const log_mod = @import("../events/log.zig");

const Fixture = struct {
    arena: std.mem.Allocator,
    index: block_mod.Index,
    now: Timestamp,
};

fn buildFixture(arena: std.mem.Allocator) !Fixture {
    var gen: idmod.Generator = .init(7, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 8);
    const person: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "sean" };
    const agent: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .agent, .label = "reviewer" };
    const session = gen.next(idmod.SessionId);
    var at = try Timestamp.parseIso("2026-09-01T09:00:00Z");

    _ = try log.append(.{ .session_opened = .{
        .session = session,
        .workingDirectory = "/home/user/zag",
    } }, .{ .at = at, .actor = person });
    _ = try log.append(.{ .git_changed = .{
        .session = session,
        .repository = "zag",
        .branch = "main",
    } }, .{ .at = at, .actor = person });

    // "zig build test" ran three times on main: two passes and one failure.
    const runs = [_]struct { command: []const u8, exit: u8, actor: event_mod.Actor, minutes: i64 }{
        .{ .command = "zig build test", .exit = 1, .actor = person, .minutes = 0 },
        .{ .command = "zig build test", .exit = 0, .actor = person, .minutes = 30 },
        .{ .command = "git status", .exit = 0, .actor = person, .minutes = 60 },
        .{ .command = "zig build test", .exit = 0, .actor = agent, .minutes = 90 },
    };
    for (runs) |run_spec| {
        const started = at.addNanos(run_spec.minutes * timeutil.ns_per_min);
        const block = gen.next(idmod.BlockId);
        _ = try log.append(.{ .command_submitted = .{
            .block = block,
            .session = session,
            .commandText = run_spec.command,
            .workingDirectory = "/home/user/zag",
            .boundaryFromShell = true,
        } }, .{ .at = started, .actor = run_spec.actor });
        _ = try log.append(.{ .command_finished = .{
            .block = block,
            .session = session,
            .exitStatus = run_spec.exit,
            .duration = .fromSeconds(2),
        } }, .{ .at = started.addNanos(2 * timeutil.ns_per_s), .actor = run_spec.actor });
    }

    // One command in a different repository, so directory filters have work.
    const other = gen.next(idmod.BlockId);
    const other_session = gen.next(idmod.SessionId);
    at = at.addNanos(3 * timeutil.ns_per_hour);
    _ = try log.append(.{ .command_submitted = .{
        .block = other,
        .session = other_session,
        .commandText = "cargo test",
        .workingDirectory = "/home/user/other",
    } }, .{ .at = at, .actor = person });
    _ = try log.append(.{ .command_finished = .{
        .block = other,
        .session = other_session,
        .exitStatus = 0,
        .duration = .fromSeconds(1),
    } }, .{ .at = at.addNanos(timeutil.ns_per_s), .actor = person });

    const index = try block_mod.Index.build(arena, log);
    return .{ .arena = arena, .index = index, .now = try Timestamp.parseIso("2026-09-01T14:00:00Z") };
}

test "a bare word searches the command text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try buildFixture(arena);

    const parsed = try parse(arena, "zig build");
    try testing.expect(parsed.ok());
    const results = try run(arena, fixture.index, parsed.query, .{ .now = fixture.now });
    try testing.expectEqual(@as(usize, 3), results.matchCount);
    try testing.expectEqual(@as(usize, 1), results.hits.len);
    try testing.expectEqual(@as(u32, 3), results.hits[0].repeatCount);
}

test "filters narrow by result, actor and place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try buildFixture(arena);

    const failed = try parse(arena, "status:failed");
    const failed_results = try run(arena, fixture.index, failed.query, .{ .now = fixture.now });
    try testing.expectEqual(@as(usize, 1), failed_results.matchCount);
    try testing.expectEqualStrings("zig build test", failed_results.hits[0].block.commandText.?);

    const by_agent = try parse(arena, "actor:agent");
    const agent_results = try run(arena, fixture.index, by_agent.query, .{ .now = fixture.now });
    try testing.expectEqual(@as(usize, 1), agent_results.matchCount);

    const here = try parse(arena, "dir:/home/user/zag");
    const here_results = try run(arena, fixture.index, here.query, .{ .now = fixture.now });
    try testing.expectEqual(@as(usize, 4), here_results.matchCount);

    const branch = try parse(arena, "branch:main exit:0");
    const branch_results = try run(arena, fixture.index, branch.query, .{ .now = fixture.now });
    try testing.expectEqual(@as(usize, 3), branch_results.matchCount);
}

test "a directory filter stops at a path segment" {
    try testing.expect(isUnderDirectory("/home/user/zag", "/home/user/zag"));
    try testing.expect(isUnderDirectory("/home/user/zag/src", "/home/user/zag"));
    try testing.expect(isUnderDirectory("/home/user/zag/src", "/home/user/zag/"));
    try testing.expect(!isUnderDirectory("/home/user/zagreb", "/home/user/zag"));
    try testing.expect(isUnderDirectory("/home/user", "/"));
}

test "dates bound the search at both ends" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try buildFixture(arena);

    const parsed = try parse(arena, "since:2026-09-01T10:00:00Z");
    try testing.expect(parsed.ok());
    const results = try run(arena, fixture.index, parsed.query, .{ .now = fixture.now, .foldRepeats = false });
    // The 10:30 run, the 10:00 build and the 12:00 command in the other repo.
    try testing.expectEqual(@as(usize, 3), results.matchCount);

    const until = try parse(arena, "until:2026-09-01");
    const until_results = try run(arena, fixture.index, until.query, .{ .now = fixture.now });
    try testing.expectEqual(@as(usize, 0), until_results.matchCount);
}

test "a mistyped filter is reported, not ignored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parse(arena, "statuss:failed status:nonsense zig");
    try testing.expect(!parsed.ok());
    try testing.expectEqual(@as(usize, 2), parsed.problems.len);
    try testing.expectEqualStrings("There is no filter with this name", parsed.problems[0].message);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try parsed.problems[0].writeSentence(&w);
    try testing.expectEqualStrings("There is no filter with this name in \"statuss:failed\".", w.buffered());
    // The word survives, so the rest of the query is still usable.
    try testing.expectEqual(@as(usize, 1), parsed.query.words.len);
}

test "ranking prefers the command that recently worked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try buildFixture(arena);

    const parsed = try parse(arena, "");
    const results = try run(arena, fixture.index, parsed.query, .{ .now = fixture.now });
    // "zig build test" ran three times and its newest run succeeded, so it
    // outranks "git status", which ran once.
    try testing.expectEqualStrings("zig build test", results.hits[0].block.commandText.?);
    try testing.expect(results.hits[0].score > results.hits[1].score);
    try testing.expectEqual(block_mod.Status.succeeded, results.hits[0].block.status);
}

test "the result header says what was asked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try buildFixture(arena);

    const parsed = try parse(arena, "zig status:failed branch:main");
    const results = try run(arena, fixture.index, parsed.query, .{ .now = fixture.now });
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try results.writeSummary(&w);
    try testing.expectEqualStrings(
        "1 block matched.\nSearch: commands containing \"zig\", which failed, on branch main.",
        w.buffered(),
    );
}

test "an empty result says so instead of showing nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try buildFixture(arena);

    const parsed = try parse(arena, "rustc");
    const results = try run(arena, fixture.index, parsed.query, .{ .now = fixture.now });
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try results.writeSummary(&w);
    try testing.expectEqualStrings("Nothing matched.\nSearch: commands containing \"rustc\".", w.buffered());
}

test "frequencies report how often a command fails" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fixture = try buildFixture(arena);

    const top = try frequencies(arena, fixture.index, 2);
    try testing.expectEqual(@as(usize, 2), top.len);
    try testing.expectEqualStrings("zig build test", top[0].commandText);
    try testing.expectEqual(@as(u32, 3), top[0].runCount);
    try testing.expectEqual(@as(u32, 1), top[0].failureCount);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), top[0].failureRate(), 0.0001);
}
