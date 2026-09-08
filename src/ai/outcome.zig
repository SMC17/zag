//! Reading, from the record alone, whether a run did the job.
//!
//! Everything an agent did is in the log: what it was asked, what it asked
//! for, what each call returned, whether the policy refused, and how it ended.
//! Nothing read that back as an answer to the question anyone actually has
//! afterwards — did it work?
//!
//! That question is the missing half of every other thing here. Without it a
//! trajectory export is a pile of transcripts with no label, one model cannot
//! be compared with another on anything but cost, and a change to the prompt
//! or the tool descriptions can only be judged by reading runs by hand.
//!
//! ## What is measured, and what is guessed
//!
//! Nothing here is guessed. Every signal is something the record states:
//!
//! - **How the run ended.** `agent_finished` says whether it answered, was
//!   refused, ran out of budget, or is waiting for a person.
//! - **Whether its actions worked.** Each `tool_finished` carries an outcome.
//!   A run whose every call failed did not do the job however it ended.
//! - **Whether it was allowed to act.** Refusals are counted separately from
//!   failures, because they mean different things: a refused run was stopped
//!   by the workspace, and a failed one was not stopped by anything.
//! - **Whether it went in circles.** The same tool asked for the same resource
//!   over and over is the signature of a stuck run, and it is visible in the
//!   record without asking a model to judge.
//! - **What it cost.** Tokens and wall clock, for anything that trades quality
//!   against price.
//!
//! ## Why there is no model in the loop here
//!
//! The obvious way to score an agent run is to ask a model whether it went
//! well. That is a reasonable technique and it is not this: a judge costs a
//! request, disagrees with itself between runs, and cannot be checked. Scores
//! from this file are arithmetic over recorded facts, so two people who
//! disagree about a number can settle it by reading the log, and a replay of
//! the same run scores the same. A model judge belongs on top of this as a
//! second opinion, not underneath it as the only one.
//!
//! ## The reward
//!
//! `Score.reward` is one number in [0, 1] for the things that want one — an
//! eval that has to sort runs, a bandit choosing between models. It is a
//! weighted sum of the parts, and the weights are written here rather than
//! tuned, because a weight nobody can see is a claim nobody can check. Any
//! caller that wants its own weighting has the parts.

const std = @import("std");
const event_mod = @import("../events/event.zig");
const log_mod = @import("../events/log.zig");
const idmod = @import("../core/id.zig");
const timeutil = @import("../core/time.zig");

/// How a run ended, as the record states it.
pub const Ending = enum {
    answered,
    refused,
    stopped_by_policy,
    waiting_for_a_person,
    out_of_budget,
    unavailable,
    /// No `agent_finished` in the log. The run was interrupted hard enough
    /// that it never wrote its own ending — a crash, a kill, a full disk.
    unfinished,

    /// Whether the run reached a place it could stop from.
    ///
    /// `waiting_for_a_person` is deliberately not a failure: a run that asked
    /// before doing something irreversible did the right thing, and scoring it
    /// as a loss would teach exactly the wrong lesson to anything learning
    /// from these numbers.
    pub fn settled(self: Ending) bool {
        return self == .answered or self == .waiting_for_a_person;
    }
};

pub const Score = struct {
    agent: idmod.AgentId,
    task: []const u8 = "",
    model: []const u8 = "",
    connector: []const u8 = "",
    ending: Ending = .unfinished,

    toolCalls: usize = 0,
    succeeded: usize = 0,
    failed: usize = 0,
    refused: usize = 0,
    /// Calls that asked for something an earlier call had already asked for.
    repeated: usize = 0,

    inputTokens: u64 = 0,
    outputTokens: u64 = 0,
    duration: timeutil.Duration = .{ .ns = 0 },

    /// The share of actions that worked. Null when the run took none, because
    /// zero out of zero is not a failure and should not be scored as one.
    pub fn actionSuccess(self: Score) ?f64 {
        if (self.toolCalls == 0) return null;
        return @as(f64, @floatFromInt(self.succeeded)) / @as(f64, @floatFromInt(self.toolCalls));
    }

    /// One number in [0, 1], for the things that need to sort runs.
    ///
    /// Half of it is whether the run finished, because a run that did not is
    /// not a good run however tidy its individual steps were. A third is
    /// whether its actions worked. The rest is a penalty for going in circles,
    /// which is the failure mode that otherwise scores well: a stuck run makes
    /// many calls, most of them succeed, and it achieves nothing.
    ///
    /// The weights are here in the open rather than tuned against a benchmark.
    /// A weight nobody can see is a claim nobody can check, and a caller that
    /// wants a different one has every part it is made of.
    pub fn reward(self: Score) f64 {
        var total: f64 = 0;
        if (self.ending.settled()) total += 0.5;
        total += 0.35 * (self.actionSuccess() orelse 1.0);

        // Circling. A run that asked for the same thing five times is worse
        // than one that asked once and stopped, and both look fine by every
        // other measure here.
        const circling = if (self.toolCalls == 0)
            0.0
        else
            @as(f64, @floatFromInt(self.repeated)) / @as(f64, @floatFromInt(self.toolCalls));
        total += 0.15 * (1.0 - circling);
        return std.math.clamp(total, 0.0, 1.0);
    }

    pub fn writeSentence(self: Score, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}: ", .{@tagName(self.ending)});
        if (self.toolCalls == 0) {
            try w.writeAll("no tools used");
        } else {
            try w.print("{d} of {d} calls worked", .{ self.succeeded, self.toolCalls });
            if (self.refused > 0) try w.print(", {d} refused", .{self.refused});
            if (self.repeated > 0) try w.print(", {d} repeated", .{self.repeated});
        }
        try w.print(", {d} tokens, reward {d:.2}.", .{ self.inputTokens + self.outputTokens, self.reward() });
    }
};

/// Score every run in a log, in the order they started.
pub fn scoreAll(arena: std.mem.Allocator, log: log_mod.Log) ![]const Score {
    var out: std.ArrayList(Score) = .empty;
    var index: std.AutoArrayHashMapUnmanaged([16]u8, usize) = .empty;
    // What each run has already asked for, to notice circling.
    var seen: std.AutoArrayHashMapUnmanaged([16]u8, std.ArrayList([]const u8)) = .empty;

    for (log.entries.items) |entry| switch (entry.payload) {
        .agent_started => |e| {
            try index.put(arena, e.agent.raw.bytes, out.items.len);
            try seen.put(arena, e.agent.raw.bytes, .empty);
            try out.append(arena, .{
                .agent = e.agent,
                .task = e.request,
                .model = e.model,
                .connector = e.provider,
            });
        },
        .tool_requested => |e| {
            const at = index.get(e.agent.raw.bytes) orelse continue;
            const score = &out.items[at];
            score.toolCalls += 1;

            // The same tool asked for the same resource again. Compared on
            // what the policy decided about rather than on the raw arguments,
            // because two calls that differ only in a timeout are the same
            // request as far as being stuck is concerned.
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ e.tool, e.resource });
            const asked = seen.getPtr(e.agent.raw.bytes) orelse continue;
            for (asked.items) |earlier| {
                if (std.mem.eql(u8, earlier, key)) {
                    score.repeated += 1;
                    break;
                }
            }
            try asked.append(arena, key);
        },
        .tool_finished => |e| {
            const at = index.get(e.agent.raw.bytes) orelse continue;
            const score = &out.items[at];
            switch (e.outcome) {
                .completed => score.succeeded += 1,
                .denied => score.refused += 1,
                else => score.failed += 1,
            }
        },
        .agent_finished => |e| {
            const at = index.get(e.agent.raw.bytes) orelse continue;
            const score = &out.items[at];
            score.ending = switch (e.outcome) {
                .answered => .answered,
                .refused => .refused,
                .stopped_by_policy => .stopped_by_policy,
                .waiting_for_a_person => .waiting_for_a_person,
                .out_of_budget => .out_of_budget,
                .unavailable => .unavailable,
            };
            score.inputTokens = e.inputTokens;
            score.outputTokens = e.outputTokens;
            score.duration = e.duration;
        },
        else => {},
    };
    return out.items;
}

/// What a set of runs comes to, for comparing one model or prompt with another.
pub const Summary = struct {
    runs: usize = 0,
    settled: usize = 0,
    meanReward: f64 = 0,
    totalTokens: u64 = 0,

    pub fn writeSentence(self: Summary, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.runs == 0) {
            try w.writeAll("No runs to compare.");
            return;
        }
        try w.print(
            "{d} run{s}, {d} finished, mean reward {d:.2}, {d} tokens.",
            .{ self.runs, if (self.runs == 1) "" else "s", self.settled, self.meanReward, self.totalTokens },
        );
    }
};

pub fn summarise(scores: []const Score) Summary {
    if (scores.len == 0) return .{};
    var out: Summary = .{ .runs = scores.len };
    var total: f64 = 0;
    for (scores) |score| {
        if (score.ending.settled()) out.settled += 1;
        total += score.reward();
        out.totalTokens += score.inputTokens + score.outputTokens;
    }
    out.meanReward = total / @as(f64, @floatFromInt(scores.len));
    return out;
}

const testing = std.testing;

const Builder = struct {
    arena: std.mem.Allocator,
    log: log_mod.Log,
    agent: idmod.AgentId,
    session: idmod.SessionId,
    ids: idmod.Generator,

    fn init(arena: std.mem.Allocator) Builder {
        var ids = idmod.Generator.init(5, 1_788_000_000_000);
        return .{
            .arena = arena,
            .log = log_mod.Log.init(arena, 9),
            .agent = ids.next(idmod.AgentId),
            .session = ids.next(idmod.SessionId),
            .ids = ids,
        };
    }

    fn actor() event_mod.Actor {
        return .{ .kind = .agent, .id = .{ .raw = .{ .bytes = @splat(4) } }, .label = "an agent" };
    }

    fn started(self: *Builder, request: []const u8) !void {
        _ = try self.log.append(.{ .agent_started = .{
            .agent = self.agent,
            .session = self.session,
            .request = request,
            .provider = "anthropic",
            .model = "claude-opus-5",
            .policy = "test",
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });
    }

    fn call(self: *Builder, tool: []const u8, resource: []const u8, outcome: anytype) !void {
        const id = self.ids.next(idmod.ToolCallId);
        _ = try self.log.append(.{ .tool_requested = .{
            .call = id,
            .agent = self.agent,
            .session = self.session,
            .tool = tool,
            .capability = "fs.read",
            .argumentsJson = "{}",
            .resource = resource,
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });
        _ = try self.log.append(.{ .tool_finished = .{
            .call = id,
            .agent = self.agent,
            .session = self.session,
            .outcome = outcome,
            .duration = .{ .ns = 0 },
            .resultHash = .zero,
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });
    }

    fn ended(self: *Builder, outcome: anytype) !void {
        _ = try self.log.append(.{ .agent_finished = .{
            .agent = self.agent,
            .session = self.session,
            .outcome = outcome,
            .duration = .{ .ns = 2 * timeutil.ns_per_s },
            .inputTokens = 900,
            .outputTokens = 100,
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });
    }
};

test "a run that did the job scores better than one that did not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var good = Builder.init(arena);
    try good.started("fix the build");
    try good.call("run_command", "zig build", .completed);
    try good.call("write_file", "src/main.zig", .completed);
    try good.ended(.answered);
    const worked = (try scoreAll(arena, good.log))[0];

    var bad = Builder.init(arena);
    try bad.started("fix the build");
    try bad.call("run_command", "zig build", .failed);
    try bad.ended(.out_of_budget);
    const did_not = (try scoreAll(arena, bad.log))[0];

    try testing.expect(worked.reward() > did_not.reward());
    try testing.expectEqual(Ending.answered, worked.ending);
    try testing.expectEqual(@as(usize, 2), worked.succeeded);
    try testing.expectEqual(@as(usize, 1000), worked.inputTokens + worked.outputTokens);
    try testing.expectEqual(@as(f64, 1.0), worked.actionSuccess().?);
}

test "stopping to ask a person is not counted as a loss" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A run that asked before doing something irreversible did the right
    // thing. Scoring it as a failure would teach exactly the wrong lesson to
    // anything learning from these numbers — the cheapest way to raise the
    // score would be to stop asking.
    var asked = Builder.init(arena);
    try asked.started("delete the old branches");
    try asked.call("git", "delete", .completed);
    try asked.ended(.waiting_for_a_person);
    const waiting = (try scoreAll(arena, asked.log))[0];

    var ploughed = Builder.init(arena);
    try ploughed.started("delete the old branches");
    try ploughed.call("git", "delete", .failed);
    try ploughed.ended(.out_of_budget);
    const ran_out = (try scoreAll(arena, ploughed.log))[0];

    try testing.expect(waiting.ending.settled());
    try testing.expect(waiting.reward() > ran_out.reward());
}

test "going in circles is caught, even when every step succeeds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The failure mode that otherwise scores perfectly: a stuck run makes many
    // calls, all of them succeed, and it achieves nothing.
    var circling = Builder.init(arena);
    try circling.started("make the tests pass");
    for (0..5) |_| try circling.call("read_file", "src/main.zig", .completed);
    try circling.ended(.out_of_budget);
    const stuck = (try scoreAll(arena, circling.log))[0];

    var direct = Builder.init(arena);
    try direct.started("make the tests pass");
    try direct.call("read_file", "src/main.zig", .completed);
    try direct.ended(.out_of_budget);
    const once = (try scoreAll(arena, direct.log))[0];

    try testing.expectEqual(@as(usize, 4), stuck.repeated);
    try testing.expectEqual(@as(usize, 0), once.repeated);
    // Same ending, same success rate, and the stuck one still scores lower.
    try testing.expectEqual(stuck.actionSuccess().?, once.actionSuccess().?);
    try testing.expect(stuck.reward() < once.reward());
}

test "a refusal is counted apart from a failure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // They mean different things. A refused run was stopped by the workspace;
    // a failed one was not stopped by anything. Folding them together would
    // make a policy doing its job look like a model doing badly.
    var builder = Builder.init(arena);
    try builder.started("do a mix of things");
    try builder.call("read_file", "a", .completed);
    try builder.call("delete", "b", .denied);
    try builder.call("run_command", "c", .failed);
    try builder.ended(.answered);

    const score = (try scoreAll(arena, builder.log))[0];
    try testing.expectEqual(@as(usize, 1), score.succeeded);
    try testing.expectEqual(@as(usize, 1), score.refused);
    try testing.expectEqual(@as(usize, 1), score.failed);
    try testing.expectEqual(@as(usize, 3), score.toolCalls);
}

test "a run that never wrote its ending is unfinished, not answered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A crash, a kill, a full disk. Reading the absence of an ending as
    // success is how a dataset comes to be full of runs that never finished.
    var builder = Builder.init(arena);
    try builder.started("something that was interrupted");
    try builder.call("read_file", "a", .completed);

    const score = (try scoreAll(arena, builder.log))[0];
    try testing.expectEqual(Ending.unfinished, score.ending);
    try testing.expect(!score.ending.settled());

    // The property that matters is the comparison, not an absolute number:
    // the same actions, finished, must score higher. Reading the absence of an
    // ending as success is how a dataset fills up with runs that never
    // finished and a model learns that stopping early is fine.
    var completed = Builder.init(arena);
    try completed.started("something that was interrupted");
    try completed.call("read_file", "a", .completed);
    try completed.ended(.answered);
    const finished = (try scoreAll(arena, completed.log))[0];

    try testing.expect(score.reward() < finished.reward());
    try testing.expectEqual(score.actionSuccess().?, finished.actionSuccess().?);
}

test "a run that used no tools is not scored as having failed at them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Zero out of zero is not a failure. Answering a question without needing
    // a tool is a perfectly good run.
    var builder = Builder.init(arena);
    try builder.started("what does this build do?");
    try builder.ended(.answered);

    const score = (try scoreAll(arena, builder.log))[0];
    try testing.expect(score.actionSuccess() == null);
    try testing.expect(score.reward() > 0.9);
}

test "scores are arithmetic over the record, so the same log scores the same" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The reason there is no model judging this. A judge costs a request,
    // disagrees with itself between runs, and cannot be checked; two people
    // who disagree about a number here can settle it by reading the log.
    var builder = Builder.init(arena);
    try builder.started("a job");
    try builder.call("read_file", "a", .completed);
    try builder.call("read_file", "a", .completed);
    try builder.ended(.answered);

    const once = (try scoreAll(arena, builder.log))[0];
    const twice = (try scoreAll(arena, builder.log))[0];
    try testing.expectEqual(once.reward(), twice.reward());
    try testing.expectEqual(once.repeated, twice.repeated);
}

test "many runs in one log summarise for comparing one thing with another" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    try builder.started("first");
    try builder.call("read_file", "a", .completed);
    try builder.ended(.answered);

    builder.agent = builder.ids.next(idmod.AgentId);
    try builder.started("second");
    try builder.call("run_command", "b", .failed);
    try builder.ended(.out_of_budget);

    const scores = try scoreAll(arena, builder.log);
    try testing.expectEqual(@as(usize, 2), scores.len);
    // Each run is scored on its own actions, not on the log's.
    try testing.expectEqualStrings("first", scores[0].task);
    try testing.expectEqual(@as(usize, 1), scores[0].succeeded);
    try testing.expectEqual(@as(usize, 0), scores[1].succeeded);

    const summary = summarise(scores);
    try testing.expectEqual(@as(usize, 2), summary.runs);
    try testing.expectEqual(@as(usize, 1), summary.settled);
    try testing.expectEqual(@as(u64, 2000), summary.totalTokens);
    try testing.expect(summary.meanReward > 0 and summary.meanReward < 1);
}
