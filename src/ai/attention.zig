//! What the model is allowed to pay attention to.
//!
//! A context window is a budget, and every agent tool spends it the same way:
//! newest first, until it runs out. That is the wrong rule. The newest events
//! in a session are usually the ones the person can already see; the ones that
//! explain a failure are often much older, and are reached from the failure
//! through the dependency graph rather than through the clock.
//!
//! So selection here is a graph problem, not a recency problem. Given one event
//! a person cares about — a failing test, a diagnostic, a command that did not
//! work — this walks the derived dependency graph in `events/lineage.zig` and
//! takes what that event actually depended on, nearest first. Recency is a
//! tie-breaker between things at equal causal distance, which is the job it is
//! good at.
//!
//! ## Why distance, then recency
//!
//! Causal distance is how many dependency steps separate an event from the
//! thing being asked about. Distance one is what the failure directly rests on.
//! Distance two is what those rest on. An event at distance one from a failing
//! build is relevant however old it is; an event at no distance at all is not
//! relevant however recent. Sorting by distance and breaking ties by recency
//! keeps both facts, in the right order of importance.
//!
//! ## Why the budget is in characters
//!
//! Tokens are what a provider bills, and this build cannot count them: the
//! tokenizer belongs to the model and differs between them. Counting characters
//! and dividing is an estimate, and calling it an estimate is the honest option.
//! `Selection` reports both the characters it actually packed and the estimate
//! it made, so nobody reads a guess as a measurement.
//!
//! ## What is never selected
//!
//! Nothing here reads a file, opens the content store, or resolves a hash. It
//! selects *events*, and an event is a record of something that happened, not
//! the bytes it happened to. Whoever renders the selection decides what to
//! fetch, under the policy, and that separation is deliberate: choosing what to
//! look at must not itself be a way of reading things.

const std = @import("std");
const event_mod = @import("../events/event.zig");
const lineage = @import("../events/lineage.zig");
const log_mod = @import("../events/log.zig");
const timeutil = @import("../core/time.zig");
const notation = @import("../reports/notation.zig");

pub const Envelope = event_mod.Envelope;
pub const Dag = lineage.Dag;

/// Why one event was chosen.
///
/// Kept so a person can ask "why is this in the context?" and get an answer
/// that is not "it fitted".
pub const Reason = enum {
    /// The event the question was about.
    the_question,
    /// Something the question depended on, directly or through others.
    depended_on,
    /// Something that happened after and was affected by it.
    affected_by,
    /// Recent work in the same session, included because it is where the
    /// person is.
    recent,

    pub fn text(self: Reason) []const u8 {
        return switch (self) {
            .the_question => "what you asked about",
            .depended_on => "what it depended on",
            .affected_by => "what it went on to affect",
            .recent => "recent work here",
        };
    }
};

pub const Chosen = struct {
    index: usize,
    envelope: Envelope,
    reason: Reason,
    /// Dependency steps from the event in question. Zero for the question
    /// itself.
    distance: usize,
    /// Characters this event's rendering took.
    characters: usize,
};

pub const Selection = struct {
    chosen: []const Chosen,
    /// Events that were relevant and did not fit.
    dropped: usize,
    /// Characters actually packed.
    characters: usize,
    /// The budget it was packed against.
    budget: usize,

    /// A rough token count.
    ///
    /// Four characters to a token is the usual English approximation. It is an
    /// approximation: the real count belongs to the model's own tokenizer,
    /// which this build does not have and will not guess at more precisely than
    /// this.
    pub fn estimatedTokens(self: Selection) usize {
        return self.characters / 4;
    }

    pub fn contains(self: Selection, index: usize) bool {
        for (self.chosen) |item| {
            if (item.index == index) return true;
        }
        return false;
    }

    /// Say what went in and what did not, for a person checking the answer.
    pub fn writeExplanation(self: Selection, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} events, about {d} tokens of a {d} character budget.\n", .{
            self.chosen.len,
            self.estimatedTokens(),
            self.budget,
        });
        if (self.dropped > 0) {
            try w.print("{d} relevant event", .{self.dropped});
            if (self.dropped != 1) try w.writeAll("s");
            try w.writeAll(" did not fit and were left out.\n");
        }
        inline for (comptime std.enums.values(Reason)) |reason| {
            var count: usize = 0;
            for (self.chosen) |item| {
                if (item.reason == reason) count += 1;
            }
            if (count > 0) try w.print("  {d} for {s}\n", .{ count, reason.text() });
        }
    }
};

pub const Options = struct {
    /// Characters of rendered events. The default is roughly sixteen thousand
    /// tokens, which leaves room in most windows for the instructions, the
    /// tools and the answer.
    budget: usize = 64_000,
    /// How far back through the dependency graph to look. Beyond a few steps
    /// the connection is usually real and no longer useful.
    maxDistance: usize = 4,
    /// Include what the event went on to affect, as well as what it depended
    /// on. Useful for "what did this change break", wasteful for "why did this
    /// fail".
    includeAffected: bool = false,
    /// How many recent events to add once the graph has been walked, to place
    /// the person's own last few actions in view.
    recent: usize = 8,
};

/// Choose what the model looks at, given one event to reason about.
pub fn select(
    arena: std.mem.Allocator,
    dag: Dag,
    about: usize,
    options: Options,
) !Selection {
    if (about >= dag.nodes.len) return .{
        .chosen = &.{},
        .dropped = 0,
        .characters = 0,
        .budget = options.budget,
    };

    var distance = try arena.alloc(usize, dag.nodes.len);
    @memset(distance, std.math.maxInt(usize));
    var reason = try arena.alloc(Reason, dag.nodes.len);
    @memset(reason, .recent);

    distance[about] = 0;
    reason[about] = .the_question;

    // Backwards through the dependency edges, breadth first, so the first time
    // an event is reached is by its shortest path. A depth-first walk would
    // give a distance that depended on the order edges happened to be stored
    // in, which is not a property anybody should be sorting on.
    try spread(arena, dag, &distance, &reason, about, .backwards, .depended_on, options.maxDistance);
    if (options.includeAffected) {
        try spread(arena, dag, &distance, &reason, about, .forwards, .affected_by, options.maxDistance);
    }

    // The most recent events, whatever their connection. They cost little and
    // they are where the person is looking.
    if (options.recent > 0) {
        var index = dag.nodes.len;
        var added: usize = 0;
        while (index > 0 and added < options.recent) {
            index -= 1;
            if (distance[index] != std.math.maxInt(usize)) continue;
            distance[index] = options.maxDistance + 1;
            reason[index] = .recent;
            added += 1;
        }
    }

    // Everything reached, sorted by distance and then by recency.
    var candidates: std.ArrayList(Chosen) = .empty;
    for (distance, 0..) |d, index| {
        if (d == std.math.maxInt(usize)) continue;
        try candidates.append(arena, .{
            .index = index,
            .envelope = dag.nodes[index].envelope,
            .reason = reason[index],
            .distance = d,
            .characters = renderedLength(dag.nodes[index].envelope),
        });
    }
    std.mem.sort(Chosen, candidates.items, {}, closerFirst);

    var chosen: std.ArrayList(Chosen) = .empty;
    var used: usize = 0;
    var dropped: usize = 0;
    for (candidates.items) |candidate| {
        if (used + candidate.characters > options.budget) {
            // Not `break`. A later candidate may be small enough to fit, and
            // leaving out something that fits because something bigger did not
            // would waste the budget it exists to spend.
            dropped += 1;
            continue;
        }
        used += candidate.characters;
        try chosen.append(arena, candidate);
    }

    // Back into the order things happened, because that is how a conversation
    // reads. The selection was made by relevance; the presentation is by time.
    std.mem.sort(Chosen, chosen.items, {}, earlierFirst);

    return .{
        .chosen = chosen.items,
        .dropped = dropped,
        .characters = used,
        .budget = options.budget,
    };
}

fn spread(
    arena: std.mem.Allocator,
    dag: Dag,
    distance: *[]usize,
    reason: *[]Reason,
    from: usize,
    comptime direction: enum { forwards, backwards },
    comptime why: Reason,
    limit: usize,
) !void {
    var frontier: std.ArrayList(usize) = .empty;
    try frontier.append(arena, from);

    var step: usize = 1;
    while (step <= limit and frontier.items.len > 0) : (step += 1) {
        var next: std.ArrayList(usize) = .empty;
        for (frontier.items) |current| {
            const list = switch (direction) {
                .forwards => dag.nodes[current].out,
                .backwards => dag.nodes[current].in,
            };
            for (list) |e| {
                const neighbour = switch (direction) {
                    .forwards => dag.edges[e].to,
                    .backwards => dag.edges[e].from,
                };
                if (distance.*[neighbour] <= step) continue;
                distance.*[neighbour] = step;
                reason.*[neighbour] = why;
                try next.append(arena, neighbour);
            }
        }
        frontier = next;
    }
}

fn closerFirst(_: void, a: Chosen, b: Chosen) bool {
    if (a.distance != b.distance) return a.distance < b.distance;
    // Same distance: the more recent one first.
    return a.index > b.index;
}

fn earlierFirst(_: void, a: Chosen, b: Chosen) bool {
    return a.index < b.index;
}

/// How many characters an event takes when written for a model.
///
/// Measured by writing it, so the estimate and the rendering cannot disagree.
/// A discarded writer counts without allocating.
pub fn renderedLength(envelope: Envelope) usize {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    writeEvent(envelope, &counter.writer) catch return 0;
    return counter.count + counter.writer.end;
}

/// Write one event the way a model reads it.
///
/// Plain sentences, not JSON. A model reads prose better than it reads a record
/// format, and the record format is available to anything that wants it.
///
/// Two things are deliberately not written. Content hashes, because a model
/// cannot do anything with one and it costs tokens to carry. And any output
/// bytes: an event says how much output there was and where it is, and fetching
/// it is a decision for whoever renders this, under the policy.
pub fn writeEvent(envelope: Envelope, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (envelope.payload) {
        .command_submitted => |e| try w.print("Ran: {s} (in {s})", .{ e.commandText, e.workingDirectory }),
        .command_finished => |e| {
            if (e.exitStatus == 0) {
                try w.writeAll("It worked, after ");
            } else {
                try w.print("It failed with status {d}, after ", .{e.exitStatus});
            }
            try notation.writeDuration(w, e.duration);
            try w.writeAll(".");
        },
        .process_output => |e| try w.print("It printed {d} bytes.", .{e.byteCount}),
        .file_changed => |e| try w.print("{s} was {s}.", .{ e.path, @tagName(e.changeKind) }),
        .file_opened => |e| try w.print("{s} was read.", .{e.path}),
        .diagnostic => |e| try w.print("{s}:{d}:{d}: {s}: {s}", .{
            e.path,
            e.line,
            e.column,
            @tagName(e.severity),
            e.message,
        }),
        .user_message => |e| try w.print("You said: {s}", .{e.text}),
        .agent_message => |e| try w.print("The agent said ({s}): {s}", .{ @tagName(e.role), e.text }),
        .agent_started => |e| try w.print("An agent started, for: {s}", .{e.request}),
        .tool_requested => |e| try w.print("A tool was asked for: {s} ({s})", .{ e.tool, e.capability }),
        .tool_finished => |e| try w.print("That tool {s}. {s}", .{ @tagName(e.outcome), e.summary }),
        .approval_requested => |e| try w.print("You were asked: {s}", .{e.promptText}),
        .approval_resolved => |e| try w.print("You answered: {s}.", .{@tagName(e.outcome)}),
        .git_changed => |e| {
            try w.print("The repository moved", .{});
            if (e.branch) |branch| try w.print(" on {s}", .{branch});
            try w.print(": {d} file(s) changed.", .{e.dirtyFileCount});
        },
        .session_opened => try w.writeAll("A session started."),
        .session_closed => try w.writeAll("A session ended."),
        .evidence_recorded => |e| try w.print("Evidence recorded for {s}: {s}.", .{ e.requirement, e.result }),
    }
}

/// Write the whole selection as the text a model is given.
pub fn writeSelection(
    selection: Selection,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    for (selection.chosen) |item| {
        try writeEvent(item.envelope, w);
        try w.writeAll("\n");
    }
}

const testing = std.testing;
const idmod = @import("../core/id.zig");

const Builder = struct {
    arena: std.mem.Allocator,
    log: log_mod.Log,
    ids: idmod.Generator,
    at: i64 = 1_700_000_000 * timeutil.ns_per_s,

    fn init(arena: std.mem.Allocator) Builder {
        return .{
            .arena = arena,
            .log = log_mod.Log.init(arena, 1),
            .ids = idmod.Generator.init(2, 0),
        };
    }

    fn append(self: *Builder, payload: event_mod.WorkspaceEvent) !void {
        self.at += timeutil.ns_per_s;
        _ = try self.log.append(payload, .{
            .at = .{ .ns = self.at },
            .actor = .{ .id = self.ids.next(idmod.ActorId), .kind = .person, .label = "you" },
        });
    }
};

test "what a failure depended on beats what merely happened recently" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const session = builder.ids.next(idmod.SessionId);

    // 0: the change that will turn out to matter, long ago.
    try builder.append(.{ .file_changed = .{
        .session = session,
        .path = "src/parser.zig",
        .changeKind = .modified,
    } });
    // 1..20: a lot of unrelated work in between.
    var noise: usize = 0;
    while (noise < 20) : (noise += 1) {
        try builder.append(.{ .file_changed = .{
            .session = session,
            .path = try std.fmt.allocPrint(arena, "docs/note-{d}.md", .{noise}),
            .changeKind = .modified,
        } });
    }
    // 21: the diagnostic, which depends on event 0 through the file.
    try builder.append(.{ .diagnostic = .{
        .session = session,
        .path = "src/parser.zig",
        .line = 9,
        .column = 1,
        .severity = .@"error",
        .source = "zig",
        .message = "expected type",
    } });

    const dag = try lineage.Dag.build(arena, builder.log);
    const selection = try select(arena, dag, 21, .{ .budget = 400, .recent = 2 });

    // The old change is in, and it is in because the failure depended on it.
    try testing.expect(selection.contains(0));
    for (selection.chosen) |item| {
        if (item.index != 0) continue;
        try testing.expectEqual(Reason.depended_on, item.reason);
        try testing.expectEqual(@as(usize, 1), item.distance);
    }

    // Twenty newer events sit between the two, and the only ones that got in
    // are the two the recency allowance asked for. The rest were never
    // candidates: they were not dropped for want of room, they were not
    // relevant. That is the difference between this and filling a window
    // newest-first, and it is the whole point of the file.
    var noise_kept: usize = 0;
    for (selection.chosen) |item| {
        if (item.index >= 1 and item.index <= 20) {
            noise_kept += 1;
            try testing.expectEqual(Reason.recent, item.reason);
        }
    }
    try testing.expectEqual(@as(usize, 2), noise_kept);
    try testing.expectEqual(@as(usize, 4), selection.chosen.len);

    // With no recency allowance at all, only the failure and its cause remain.
    const strict = try select(arena, dag, 21, .{ .budget = 400, .recent = 0 });
    try testing.expectEqual(@as(usize, 2), strict.chosen.len);
    try testing.expect(strict.contains(0));
    try testing.expect(strict.contains(21));
}

test "the selection reads in the order things happened" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const session = builder.ids.next(idmod.SessionId);
    const block = builder.ids.next(idmod.BlockId);

    try builder.append(.{ .file_changed = .{
        .session = session,
        .path = "src/a.zig",
        .changeKind = .modified,
    } });
    try builder.append(.{ .command_submitted = .{
        .block = block,
        .session = session,
        .commandText = "zig build test",
        .workingDirectory = "/repo",
    } });
    try builder.append(.{ .command_finished = .{
        .block = block,
        .session = session,
        .exitStatus = 1,
        .duration = .{ .ns = 3 * timeutil.ns_per_s },
    } });

    const dag = try lineage.Dag.build(arena, builder.log);
    const selection = try select(arena, dag, 2, .{});

    // Chosen by relevance; presented by time, because that is how it reads.
    var previous: usize = 0;
    for (selection.chosen, 0..) |item, position| {
        if (position > 0) try testing.expect(item.index > previous);
        previous = item.index;
    }

    var buffer: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try writeSelection(selection, &w);
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "zig build test") != null);
    try testing.expect(std.mem.indexOf(u8, text, "It failed with status 1") != null);
    // Prose, not a record format.
    try testing.expect(std.mem.indexOf(u8, text, "{\"") == null);
}

test "a budget too small for everything keeps the closest and says what it dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const session = builder.ids.next(idmod.SessionId);

    var index: usize = 0;
    while (index < 40) : (index += 1) {
        try builder.append(.{ .file_changed = .{
            .session = session,
            .path = "src/one.zig",
            .changeKind = .modified,
        } });
    }

    const dag = try lineage.Dag.build(arena, builder.log);
    const selection = try select(arena, dag, 39, .{ .budget = 100, .maxDistance = 40, .recent = 0 });

    try testing.expect(selection.characters <= 100);
    try testing.expect(selection.chosen.len > 0);
    try testing.expect(selection.dropped > 0);
    // The event asked about is always in it. Dropping the question would make
    // the answer meaningless.
    try testing.expect(selection.contains(39));

    var buffer: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try selection.writeExplanation(&w);
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "did not fit") != null);
    try testing.expect(std.mem.indexOf(u8, text, "what you asked about") != null);
}

test "an estimate is reported as an estimate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const session = builder.ids.next(idmod.SessionId);
    try builder.append(.{ .user_message = .{ .session = session, .text = "why did that fail?" } });

    const dag = try lineage.Dag.build(arena, builder.log);
    const selection = try select(arena, dag, 0, .{});

    var buffer: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try selection.writeExplanation(&w);
    // "about N tokens", never "N tokens": this build has no tokenizer and does
    // not pretend to.
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "about ") != null);

    // The measured length and the written length are the same number, because
    // one is produced by writing the other.
    var measure: [512]u8 = undefined;
    var m = std.Io.Writer.fixed(&measure);
    try writeEvent(selection.chosen[0].envelope, &m);
    try testing.expectEqual(m.buffered().len, selection.chosen[0].characters);
}

test "looking forwards answers a different question from looking back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const session = builder.ids.next(idmod.SessionId);

    try builder.append(.{ .file_changed = .{
        .session = session,
        .path = "src/core.zig",
        .changeKind = .modified,
    } });
    try builder.append(.{ .file_opened = .{
        .session = session,
        .path = "src/core.zig",
        .contentHash = .zero,
    } });
    try builder.append(.{ .diagnostic = .{
        .session = session,
        .path = "src/core.zig",
        .line = 1,
        .column = 1,
        .severity = .warning,
        .source = "zig",
        .message = "unused",
    } });

    const dag = try lineage.Dag.build(arena, builder.log);

    // Asking about the change, looking back: nothing came before it.
    const backwards = try select(arena, dag, 0, .{ .recent = 0 });
    try testing.expectEqual(@as(usize, 1), backwards.chosen.len);

    // Asking about the change, looking forward: what it went on to affect.
    const forwards = try select(arena, dag, 0, .{ .recent = 0, .includeAffected = true });
    try testing.expect(forwards.chosen.len > 1);
    var saw_affected = false;
    for (forwards.chosen) |item| {
        if (item.reason == .affected_by) saw_affected = true;
    }
    try testing.expect(saw_affected);
}

test "every kind of event can be written for a model" {
    // A new event kind that nobody taught this to write would be silently
    // absent from every context. The switch is exhaustive, so this is really a
    // check that each arm produces something a person would recognise.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const session = builder.ids.next(idmod.SessionId);
    const block = builder.ids.next(idmod.BlockId);
    const agent = builder.ids.next(idmod.AgentId);

    try builder.append(.{ .session_opened = .{ .session = session, .workingDirectory = "/repo", .shell = "bash" } });
    try builder.append(.{ .command_submitted = .{
        .block = block,
        .session = session,
        .commandText = "ls",
        .workingDirectory = "/repo",
    } });
    try builder.append(.{ .process_output = .{
        .block = block,
        .session = session,
        .contentHash = .zero,
        .byteCount = 3,
    } });
    try builder.append(.{ .agent_started = .{
        .agent = agent,
        .session = session,
        .request = "fix the parser",
        .provider = "ollama",
        .model = "llama3.2",
        .policy = "workspace",
    } });

    for (builder.log.entries.items) |entry| {
        var buffer: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        try writeEvent(entry, &w);
        try testing.expect(w.buffered().len > 0);
        // No identifier text leaks into what the model reads: it cannot use one
        // and it costs tokens to carry.
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "evt_") == null);
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "blk_") == null);
    }
}
