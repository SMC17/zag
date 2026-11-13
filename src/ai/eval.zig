//! Comparing one way of working with another, on tasks that really happened.
//!
//! A trajectory store with nothing that uses it is a pile of transcripts. The
//! question worth asking of it is whether a change helped: a different model,
//! a reworded system prompt, a new tool, a different effort setting. The
//! honest way to answer that is to run the same tasks both ways and compare,
//! and the tasks are already here — every job anyone has asked this workspace
//! to do.
//!
//! ## Paired, because the tasks are not interchangeable
//!
//! "Old scored 0.61 on average, new scored 0.68" is a weak claim: the two sets
//! may not have been the same tasks, and tasks differ far more from each other
//! than a change usually moves any one of them. Comparison here is paired —
//! each task's own before and after — so the difference between hard and easy
//! tasks cancels instead of being noise. That is why it can say something
//! useful from a handful of runs where an unpaired comparison could not.
//!
//! ## Saying when the answer is "not enough evidence"
//!
//! Most harnesses print a mean and let the reader assume it means something.
//! This one reports the wins, the losses, and whether the difference is large
//! enough relative to its own spread to be worth acting on, and says plainly
//! when it is not. A change that wins on three tasks out of five, by a little,
//! has not been shown to be an improvement — and being told so is the useful
//! answer, because the alternative is shipping noise and believing it.
//!
//! The test is deliberately a simple one: the mean difference against the
//! spread of the differences, which is the paired t statistic without the
//! table lookup. It is not a p-value and does not pretend to be. What it can
//! do is tell the difference between a change that moved every task the same
//! way and one that moved two up and two down by more.

const std = @import("std");
const outcome_mod = @import("outcome.zig");

/// One scored run, reduced to the two things a comparison needs.
///
/// Separate from `outcome.Score` because a baseline is usually read back from
/// a trajectory file rather than recomputed, and a comparison that could only
/// take live scores would make "compare against what I exported last week"
/// impossible — which is the main thing anyone wants to do.
pub const Run = struct {
    task: []const u8,
    reward: f64,
};

/// Reduce live scores for comparison.
pub fn fromScores(arena: std.mem.Allocator, scores: []const outcome_mod.Score) ![]const Run {
    const out = try arena.alloc(Run, scores.len);
    for (scores, 0..) |score, at| out[at] = .{ .task = score.task, .reward = score.reward() };
    return out;
}

/// Read a set of runs back out of exported trajectories.
///
/// Only the task and the reward are taken. The rest of a trajectory is for
/// reading and training; a comparison needs the label and the name of what was
/// attempted.
pub fn fromJsonLines(arena: std.mem.Allocator, text: []const u8) ![]const Run {
    var out: std.ArrayList(Run) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, trimmed, .{}) catch continue;
        const object = parsed.value.object;
        const task = object.get("task") orelse continue;
        const reward = object.get("reward") orelse continue;
        if (task != .string) continue;
        try out.append(arena, .{
            .task = try arena.dupe(u8, task.string),
            .reward = switch (reward) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => continue,
            },
        });
    }
    return out.items;
}

/// One task, scored under both arrangements.
pub const Pair = struct {
    task: []const u8,
    before: f64,
    after: f64,

    pub fn change(self: Pair) f64 {
        return self.after - self.before;
    }
};

/// What a comparison came to.
pub const Comparison = struct {
    pairs: []const Pair,
    /// Tasks that went up, down, and neither.
    better: usize = 0,
    worse: usize = 0,
    same: usize = 0,
    meanBefore: f64 = 0,
    meanAfter: f64 = 0,
    /// The average change, which is the number the whole thing is about.
    meanChange: f64 = 0,
    /// How much the per-task changes disagree with each other.
    spread: f64 = 0,
    /// The mean change divided by its own standard error. Bigger means the
    /// tasks agree with each other about the direction.
    strength: f64 = 0,

    /// A change worth acting on: the tasks agree, and there are enough of them
    /// for agreement to mean anything.
    ///
    /// Two is the floor for saying anything at all, and the threshold on
    /// `strength` is the conventional two-standard-error line. Neither is a
    /// p-value and this does not claim to be a hypothesis test — it is the
    /// difference between "every task moved this way" and "two moved up and
    /// two moved down by more", which is the distinction that actually gets
    /// people into trouble.
    pub fn worthActingOn(self: Comparison) bool {
        return self.pairs.len >= 2 and @abs(self.strength) >= 2.0;
    }

    pub fn writeReport(self: Comparison, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.pairs.len == 0) {
            try w.writeAll("No task was scored both ways, so there is nothing to compare.\n");
            return;
        }

        try w.print("{d} task{s} scored both ways.\n\n", .{
            self.pairs.len,
            if (self.pairs.len == 1) "" else "s",
        });
        for (self.pairs) |pair| {
            const mark: []const u8 = if (pair.change() > 0.001) "+" else if (pair.change() < -0.001) "-" else " ";
            try w.print("  {s} {d:.2} to {d:.2}  {s}\n", .{ mark, pair.before, pair.after, pair.task });
        }

        try w.print("\n{d} better, {d} worse, {d} unchanged.\n", .{ self.better, self.worse, self.same });
        try w.print("Mean {d:.3} to {d:.3}, a change of {s}{d:.3}.\n", .{
            self.meanBefore,
            self.meanAfter,
            // A mean of exactly zero is not a decrease. Printing "-0.000"
            // reads as a regression that did not happen.
            if (self.meanChange > 1e-9) "+" else if (self.meanChange < -1e-9) "-" else "",
            @abs(self.meanChange),
        });

        // The part most harnesses leave out. A mean with no sense of whether
        // the tasks agreed about it is a number that invites belief it has not
        // earned.
        if (self.worthActingOn()) {
            // Every task moving by exactly the same amount has no spread at
            // all, which is total agreement rather than an infinite anything.
            // Printing "inf standard errors" is arithmetically true and reads
            // like a bug.
            if (std.math.isInf(self.strength)) {
                try w.writeAll("\nEvery task moved the same way by the same amount, so it is worth acting on.\n");
            } else {
                try w.print(
                    "\nThe tasks agree about this ({d:.1} standard errors), so it is worth acting on.\n",
                    .{@abs(self.strength)},
                );
            }
        } else if (self.pairs.len < 2) {
            try w.writeAll("\nOne task cannot show a difference. Run more of them.\n");
        } else {
            try w.print(
                "\nThe tasks do not agree enough to call this a real difference ({d:.1} standard errors, and two is the line). It may be noise; run more tasks before acting on it.\n",
                .{@abs(self.strength)},
            );
        }
    }
};

/// Pair up two sets of scores by task, and compare.
///
/// Only tasks present in both are compared; a task that ran one way and not
/// the other says nothing about a change. Where a task appears more than once,
/// the first of each is used, because pairing "some run of this task" with
/// "some other run of it" is the unpaired comparison this exists to avoid.
pub fn compare(
    arena: std.mem.Allocator,
    before: []const Run,
    after: []const Run,
) !Comparison {
    var pairs: std.ArrayList(Pair) = .empty;
    var used: std.ArrayList(bool) = .empty;
    try used.appendNTimes(arena, false, after.len);

    for (before) |old| {
        for (after, 0..) |new, index| {
            if (used.items[index]) continue;
            if (!std.mem.eql(u8, old.task, new.task)) continue;
            used.items[index] = true;
            try pairs.append(arena, .{
                .task = old.task,
                .before = old.reward,
                .after = new.reward,
            });
            break;
        }
    }

    var out: Comparison = .{ .pairs = pairs.items };
    if (pairs.items.len == 0) return out;

    var sum_before: f64 = 0;
    var sum_after: f64 = 0;
    var sum_change: f64 = 0;
    for (pairs.items) |pair| {
        sum_before += pair.before;
        sum_after += pair.after;
        sum_change += pair.change();
        if (pair.change() > 0.001) {
            out.better += 1;
        } else if (pair.change() < -0.001) {
            out.worse += 1;
        } else {
            out.same += 1;
        }
    }

    const n: f64 = @floatFromInt(pairs.items.len);
    out.meanBefore = sum_before / n;
    out.meanAfter = sum_after / n;
    out.meanChange = sum_change / n;

    if (pairs.items.len < 2) return out;

    // How much the per-task changes disagree, then the mean against its own
    // standard error.
    var variance: f64 = 0;
    for (pairs.items) |pair| {
        const d = pair.change() - out.meanChange;
        variance += d * d;
    }
    variance /= n - 1;
    out.spread = @sqrt(variance);

    const standard_error = out.spread / @sqrt(n);
    // Every task moving by exactly the same amount is perfect agreement, not a
    // division by zero. A change of nothing at all is no evidence either way.
    out.strength = if (standard_error > 1e-12)
        out.meanChange / standard_error
    else if (@abs(out.meanChange) > 1e-12)
        std.math.inf(f64) * std.math.sign(out.meanChange)
    else
        0;
    return out;
}

const testing = std.testing;

fn scored(task: []const u8, ending: outcome_mod.Ending, calls: usize, ok: usize) outcome_mod.Score {
    return .{
        .agent = .{ .raw = .{ .bytes = @splat(0) } },
        .task = task,
        .ending = ending,
        .toolCalls = calls,
        .succeeded = ok,
        .failed = calls - ok,
    };
}

test "a change that helps every task is called an improvement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const before = [_]outcome_mod.Score{
        scored("fix the build", .out_of_budget, 4, 2),
        scored("add a test", .out_of_budget, 4, 2),
        scored("read the config", .out_of_budget, 4, 2),
    };
    const after = [_]outcome_mod.Score{
        scored("fix the build", .answered, 4, 4),
        scored("add a test", .answered, 4, 4),
        scored("read the config", .answered, 4, 4),
    };

    const result = try compare(arena, try fromScores(arena, &before), try fromScores(arena, &after));
    try testing.expectEqual(@as(usize, 3), result.pairs.len);
    try testing.expectEqual(@as(usize, 3), result.better);
    try testing.expect(result.meanChange > 0);
    // Every task moved the same way, so the tasks agree and the call is safe.
    try testing.expect(result.worthActingOn());
}

test "a change that helps some and hurts others is not called anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The case that gets people into trouble: the mean is up, and it is up
    // because of one task while another went down by nearly as much. Reporting
    // only the mean would call this an improvement and ship noise.
    const before = [_]outcome_mod.Score{
        scored("a", .out_of_budget, 4, 2),
        scored("b", .answered, 4, 4),
        scored("c", .out_of_budget, 4, 2),
        scored("d", .answered, 4, 4),
    };
    const after = [_]outcome_mod.Score{
        scored("a", .answered, 4, 4),
        scored("b", .out_of_budget, 4, 1),
        scored("c", .answered, 4, 3),
        scored("d", .out_of_budget, 4, 2),
    };

    const result = try compare(arena, try fromScores(arena, &before), try fromScores(arena, &after));
    try testing.expect(result.better > 0 and result.worse > 0);
    try testing.expect(!result.worthActingOn());

    var out: std.Io.Writer.Allocating = .init(arena);
    try result.writeReport(&out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "do not agree enough") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "may be noise") != null);
}

test "one task is never enough to show a difference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // However big the change on it. A single task moving is an anecdote, and
    // the report says so rather than printing a confident-looking mean.
    const before = [_]outcome_mod.Score{scored("the only task", .out_of_budget, 4, 0)};
    const after = [_]outcome_mod.Score{scored("the only task", .answered, 4, 4)};

    const result = try compare(arena, try fromScores(arena, &before), try fromScores(arena, &after));
    try testing.expectEqual(@as(usize, 1), result.pairs.len);
    try testing.expect(result.meanChange > 0.5);
    try testing.expect(!result.worthActingOn());

    var out: std.Io.Writer.Allocating = .init(arena);
    try result.writeReport(&out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "One task cannot show a difference") != null);
}

test "only tasks that ran both ways are compared" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A task that ran one way and not the other says nothing about a change,
    // and counting it would let a set be improved by dropping the hard ones.
    const before = [_]outcome_mod.Score{
        scored("shared", .out_of_budget, 2, 1),
        scored("only in the old set", .answered, 2, 2),
    };
    const after = [_]outcome_mod.Score{
        scored("shared", .answered, 2, 2),
        scored("only in the new set", .answered, 2, 2),
    };

    const result = try compare(arena, try fromScores(arena, &before), try fromScores(arena, &after));
    try testing.expectEqual(@as(usize, 1), result.pairs.len);
    try testing.expectEqualStrings("shared", result.pairs[0].task);
}

test "a change of exactly nothing is not evidence of anything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Identical scores mean zero spread, which is a division waiting to
    // happen. Perfect agreement about no change is still no change.
    const same = [_]outcome_mod.Score{
        scored("a", .answered, 2, 2),
        scored("b", .answered, 2, 2),
        scored("c", .answered, 2, 2),
    };

    const reduced = try fromScores(arena, &same);
    const result = try compare(arena, reduced, reduced);
    try testing.expectEqual(@as(f64, 0), result.meanChange);
    try testing.expectEqual(@as(usize, 3), result.same);
    try testing.expect(!result.worthActingOn());
    try testing.expect(!std.math.isNan(result.strength));
}

test "a small change that every task agrees about counts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The other half of the claim. Pairing is what makes this possible: the
    // difference between hard and easy tasks cancels, so a consistent small
    // move is visible where an unpaired comparison would drown it.
    var before: std.ArrayList(outcome_mod.Score) = .empty;
    var after: std.ArrayList(outcome_mod.Score) = .empty;
    for (0..6) |i| {
        const task = try std.fmt.allocPrint(arena, "task {d}", .{i});
        // Tasks of very different difficulty: 1 to 6 calls, half succeeding.
        const calls = i + 2;
        try before.append(arena, scored(task, .answered, calls, calls / 2));
        // Each one gets exactly one more successful call.
        try after.append(arena, scored(task, .answered, calls, calls / 2 + 1));
    }

    const result = try compare(arena, try fromScores(arena, before.items), try fromScores(arena, after.items));
    try testing.expectEqual(@as(usize, 6), result.better);
    try testing.expect(result.meanChange > 0);
    try testing.expect(result.meanChange < 0.2);
    try testing.expect(result.worthActingOn());
}

test "a baseline reads back out of an exported trajectory file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The main thing anyone wants: export a baseline, change something, run
    // the tasks again, and compare against the file rather than against a
    // number somebody wrote down.
    const exported =
        \\{"task":"fix the build","model":"m","connector":"c","ending":"answered","reward":0.8200,"steps":[]}
        \\{"task":"add a test","model":"m","connector":"c","ending":"out_of_budget","reward":0.4000,"steps":[]}
        \\
    ;
    const runs = try fromJsonLines(arena, exported);
    try testing.expectEqual(@as(usize, 2), runs.len);
    try testing.expectEqualStrings("fix the build", runs[0].task);
    try testing.expectApproxEqAbs(@as(f64, 0.82), runs[0].reward, 0.0001);

    const now = [_]Run{
        .{ .task = "fix the build", .reward = 0.9 },
        .{ .task = "add a test", .reward = 0.7 },
    };
    const result = try compare(arena, runs, &now);
    try testing.expectEqual(@as(usize, 2), result.better);
    try testing.expect(result.meanChange > 0);
}

test "a damaged line in a baseline is skipped rather than failing the run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A truncated export, a half-written file, a line from a different tool.
    // Losing one task's baseline is a smaller loss than refusing to compare
    // anything, and the count of what was read says how much was lost.
    const messy =
        \\{"task":"good","reward":0.5,"steps":[]}
        \\not json at all
        \\{"task":"no reward here"}
        \\{"reward":0.9}
        \\
        \\{"task":"also good","reward":0.6}
    ;
    const runs = try fromJsonLines(arena, messy);
    try testing.expectEqual(@as(usize, 2), runs.len);
    try testing.expectEqualStrings("good", runs[0].task);
    try testing.expectEqualStrings("also good", runs[1].task);
}
