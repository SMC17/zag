//! Running a task several times and keeping the one that worked.
//!
//! Everything else in this repository spends effort before the answer: a
//! better prompt, a better model, better tools. This spends it after. The task
//! is run more than once, each attempt is scored, and the best one is what the
//! person gets. It is the cheapest large improvement available to an agent
//! system, and it is cheap only in engineering — it costs exactly as many
//! times more as the number of attempts, and that is the first thing this file
//! says out loud.
//!
//! ## The two ways this is usually done wrong
//!
//! **The attempts are the same attempt.** Running one prompt through one model
//! three times, with nothing varied, produces three near-identical runs and a
//! bill three times the size. Attempts here are given rising temperatures:
//! the first is the run that would have happened anyway, and the later ones
//! are deliberately less certain. Whether that produced any variety is
//! measured — `Chosen.variety` says how many distinct answers came back — and
//! reported, because "best of three" over three copies of one answer is a
//! phrase that should not survive contact with the record.
//!
//! **The selector is the thing being selected.** Picking the best attempt by
//! asking the model which of its own answers it likes is a well-documented way
//! to select for confidence. The selection here starts from arithmetic over
//! the record — `ai/outcome.zig`, which cannot be talked into anything — and
//! uses the judge only as the second half of a stated weighting, on a rubric
//! that asks about grounding and honesty rather than about how good the answer
//! sounds.
//!
//! ## What is kept
//!
//! All of it. Every attempt is a real run in the record, with its own agent
//! identifier, its tool calls and its refusals. The losing attempts are the
//! interesting half of a best-of-N: they are the same task, by the same model,
//! at the same moment, and the difference between them and the winner is the
//! closest thing to a controlled experiment this system can produce. A
//! best-of-N that threw them away would be spending three times as much and
//! keeping a third of what it bought.

const std = @import("std");
const outcome_mod = @import("outcome.zig");
const judge_mod = @import("judge.zig");

/// One attempt at the task.
pub const Attempt = struct {
    /// Where in the sequence, from zero. The first attempt is the one that
    /// would have happened without any of this.
    number: usize,
    /// What the run was asked to vary by. Null means the provider's default.
    temperature: ?f32 = null,
    answer: []const u8,
    /// Arithmetic over the record. Reproducible, and blind to whether the
    /// answer is any good.
    measured: outcome_mod.Score,
    /// The judge's reading, when one was asked for and answered.
    judged: ?judge_mod.Judgement = null,
    /// Set when the attempt could not be run at all, which is different from
    /// running badly and must not be ranked as though it were.
    failed: ?[]const u8 = null,
};

/// How to spread the attempts out.
pub const Spread = struct {
    /// How many times to run the task. One is the ordinary path and costs
    /// nothing extra; anything above it costs that many times as much.
    attempts: usize = 3,
    /// Where the varying starts and how far it goes.
    ///
    /// The first attempt is left at the provider's default, which is the run
    /// that would have happened anyway — so a best-of-N can only be as bad as
    /// one attempt plus the cost of the others. The rest rise to `highest`.
    lowest: f32 = 0.4,
    highest: f32 = 1.0,

    /// The temperature for one attempt. Null for the first, which is left
    /// alone: a provider's default is a considered choice and replacing it
    /// with 0.4 on attempt one would make the common case worse.
    pub fn temperatureFor(self: Spread, number: usize) ?f32 {
        if (number == 0) return null;
        if (self.attempts <= 2) return self.highest;
        const step = (self.highest - self.lowest) /
            @as(f32, @floatFromInt(self.attempts - 2));
        return self.lowest + step * @as(f32, @floatFromInt(number - 1));
    }
};

/// How the attempts are ranked.
///
/// Two numbers, weighted, and both are written here rather than tuned. The
/// arithmetic is worth more than the judge: it cannot be talked into anything
/// and it does not drift between runs. The judge is worth something, because
/// the arithmetic is blind to whether an answer is right.
pub const Weighting = struct {
    measured: f64 = 0.6,
    judged: f64 = 0.4,

    /// One attempt's rank. An attempt nobody judged is ranked on the
    /// arithmetic alone rather than being penalised for a request that was
    /// never made.
    pub fn rank(self: Weighting, attempt: Attempt, rubric: judge_mod.Rubric) f64 {
        if (attempt.failed != null) return -1;
        const measured = attempt.measured.reward();
        const judged = if (attempt.judged) |j| j.overall(rubric) else null;
        const opinion = judged orelse return measured;
        return self.measured * measured + self.judged * opinion;
    }
};

/// Which attempt won, and everything a person needs to distrust that.
pub const Chosen = struct {
    winner: usize,
    attempts: []const Attempt,
    /// How many distinct answers came back. One means the attempts were the
    /// same attempt and the extra cost bought nothing.
    variety: usize = 0,
    /// What the whole thing cost, against what one attempt would have.
    spentTokens: u64 = 0,
    oneAttemptTokens: u64 = 0,

    pub fn best(self: Chosen) Attempt {
        return self.attempts[self.winner];
    }

    /// Whether running this more than once was worth it *this time*.
    ///
    /// Not a claim about the technique. It says whether, on this task, any
    /// attempt after the first beat the first — which is the only question the
    /// record can answer, and the one a person paying three times over
    /// deserves an answer to.
    pub fn paidOff(self: Chosen) bool {
        return self.winner != 0 and self.variety > 1;
    }

    pub fn writeSentence(self: Chosen, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} attempts, {d} distinct answer{s}", .{
            self.attempts.len,
            self.variety,
            if (self.variety == 1) "" else "s",
        });
        if (self.oneAttemptTokens > 0) {
            const factor = @as(f64, @floatFromInt(self.spentTokens)) /
                @as(f64, @floatFromInt(self.oneAttemptTokens));
            try w.print(", {d:.1} times the tokens of the first", .{factor});
        }
        try w.print(". Attempt {d} won", .{self.winner + 1});
        if (self.variety == 1) {
            try w.writeAll(", but every attempt said the same thing, so the extra ones bought nothing.");
        } else if (self.winner == 0) {
            try w.writeAll(", which is the attempt that would have happened anyway.");
        } else {
            try w.writeAll(", and it is not the one that would have happened anyway.");
        }
    }
};

/// Rank the attempts and say which won.
///
/// Ties go to the earlier attempt, and deliberately: the earlier attempts are
/// the less varied ones, and preferring a lower temperature when nothing
/// separates two answers is the conservative direction.
pub fn choose(
    attempts: []const Attempt,
    rubric: judge_mod.Rubric,
    weighting: Weighting,
) Chosen {
    var winner: usize = 0;
    var best_rank: f64 = -std.math.inf(f64);
    var spent: u64 = 0;
    var first: u64 = 0;

    for (attempts, 0..) |attempt, index| {
        const total = attempt.measured.inputTokens + attempt.measured.outputTokens;
        spent += total;
        if (index == 0) first = total;

        const rank = weighting.rank(attempt, rubric);
        if (rank > best_rank) {
            best_rank = rank;
            winner = index;
        }
    }

    // Distinct answers, compared after trimming. Two answers that differ by a
    // trailing newline are one answer, and counting them as two would let the
    // variety number say the attempts varied when they did not.
    var variety: usize = 0;
    for (attempts, 0..) |attempt, index| {
        if (attempt.failed != null) continue;
        const text = std.mem.trim(u8, attempt.answer, " \t\r\n");
        var seen = false;
        for (attempts[0..index]) |earlier| {
            if (earlier.failed != null) continue;
            if (std.mem.eql(u8, std.mem.trim(u8, earlier.answer, " \t\r\n"), text)) seen = true;
        }
        if (!seen) variety += 1;
    }

    return .{
        .winner = winner,
        .attempts = attempts,
        .variety = variety,
        .spentTokens = spent,
        .oneAttemptTokens = first,
    };
}

/// The whole run, for a person to read.
pub fn writeReport(
    chosen: Chosen,
    rubric: judge_mod.Rubric,
    weighting: Weighting,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    for (chosen.attempts, 0..) |attempt, index| {
        try w.print("{s} attempt {d}", .{
            if (index == chosen.winner) "->" else "  ",
            index + 1,
        });
        if (attempt.temperature) |t| {
            try w.print(" at temperature {d:.1}", .{t});
        } else {
            try w.writeAll(" at the provider's own setting");
        }
        if (attempt.failed) |why| {
            try w.print(": did not run — {s}\n", .{why});
            continue;
        }
        try w.print(": rank {d:.2}, ", .{weighting.rank(attempt, rubric)});
        try attempt.measured.writeSentence(w);
        if (attempt.judged) |judgement| {
            if (judgement.overall(rubric)) |value| {
                try w.print(" The judge says {d:.2}: {s}", .{ value, judgement.summary });
            } else {
                try w.writeAll(" The judge could not tell.");
            }
        }
        try w.writeAll("\n");
    }
    try w.writeAll("\n");
    try chosen.writeSentence(w);
    try w.writeAll("\n");
}

const testing = std.testing;

fn attemptWith(number: usize, answer: []const u8, ending: outcome_mod.Ending, calls: usize, worked: usize) Attempt {
    return .{
        .number = number,
        .temperature = (Spread{}).temperatureFor(number),
        .answer = answer,
        .measured = .{
            .agent = undefined,
            .ending = ending,
            .toolCalls = calls,
            .succeeded = worked,
            .failed = calls - worked,
            .inputTokens = 1000,
            .outputTokens = 200,
        },
    };
}

test "the first attempt is the run that would have happened anyway" {
    // A provider's default temperature is a considered choice. Replacing it
    // with 0.4 on attempt one would make the common case worse in exchange for
    // variety that the later attempts are there to supply.
    const spread: Spread = .{ .attempts = 4, .lowest = 0.4, .highest = 1.0 };
    try testing.expect(spread.temperatureFor(0) == null);
    try testing.expectApproxEqAbs(@as(f32, 0.4), spread.temperatureFor(1).?, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), spread.temperatureFor(3).?, 0.001);

    // And they rise, rather than all being the same. Three attempts at one
    // temperature is one attempt three times.
    try testing.expect(spread.temperatureFor(1).? < spread.temperatureFor(2).?);
    try testing.expect(spread.temperatureFor(2).? < spread.temperatureFor(3).?);

    // Two attempts: the default, then the far end.
    const pair: Spread = .{ .attempts = 2 };
    try testing.expect(pair.temperatureFor(0) == null);
    try testing.expectApproxEqAbs(@as(f32, 1.0), pair.temperatureFor(1).?, 0.001);
}

test "three copies of one answer is not a best of three, and says so" {
    // The failure this is built to notice. Without it, "best of three" reads
    // as three chances at the answer when it was one chance and two copies.
    const attempts = [_]Attempt{
        attemptWith(0, "The build fails on line five.", .answered, 2, 2),
        attemptWith(1, "The build fails on line five.\n", .answered, 2, 2),
        attemptWith(2, "  The build fails on line five.  ", .answered, 2, 2),
    };
    const chosen = choose(&attempts, judge_mod.default_rubric, .{});
    try testing.expectEqual(@as(usize, 1), chosen.variety);
    try testing.expect(!chosen.paidOff());

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try chosen.writeSentence(&out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "bought nothing") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "3.0 times the tokens") != null);
}

test "a later attempt wins when it is better, and the report says it was not the default one" {
    const attempts = [_]Attempt{
        attemptWith(0, "I could not work it out.", .out_of_budget, 4, 1),
        attemptWith(1, "The build fails on line five of main.zig.", .answered, 2, 2),
    };
    const chosen = choose(&attempts, judge_mod.default_rubric, .{});
    try testing.expectEqual(@as(usize, 1), chosen.winner);
    try testing.expectEqual(@as(usize, 2), chosen.variety);
    try testing.expect(chosen.paidOff());

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try chosen.writeSentence(&out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "not the one that would have happened anyway") != null);
}

test "an attempt that never ran is not ranked as one that ran badly" {
    // These are opposite findings. A provider that was down is not evidence
    // about the answer, and letting it come last by arithmetic would be right
    // by accident; letting it win because its empty record scores well would
    // be the real failure.
    var broken = attemptWith(1, "", .unfinished, 0, 0);
    broken.failed = "the provider could not be reached";
    const attempts = [_]Attempt{
        attemptWith(0, "Line five.", .answered, 1, 1),
        broken,
    };
    const chosen = choose(&attempts, judge_mod.default_rubric, .{});
    try testing.expectEqual(@as(usize, 0), chosen.winner);
    try testing.expectEqual(@as(f64, -1), (Weighting{}).rank(broken, judge_mod.default_rubric));
    // A run that did not happen is not one of the distinct answers either.
    try testing.expectEqual(@as(usize, 1), chosen.variety);
}

test "the arithmetic outweighs the judge, and an unjudged attempt is not penalised" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Picking by asking a model which of its own answers it likes selects for
    // confidence. The arithmetic cannot be talked into anything, so it is
    // worth more — and the weights are here rather than tuned.
    const weighting: Weighting = .{};
    try testing.expect(weighting.measured > weighting.judged);

    var confident = attemptWith(0, "It is definitely line five.", .answered, 4, 1);
    confident.judged = try judge_mod.parse(arena, judge_mod.default_rubric,
        \\{"marks":[{"criterion":"answered-the-question","because":"Direct.","score":1.0},
        \\ {"criterion":"grounded","because":"It checked nothing.","score":1.0}]}
    );
    const careful = attemptWith(1, "Line five, from the error at build.zig:12.", .answered, 4, 4);

    const chosen = choose(&.{ confident, careful }, judge_mod.default_rubric, weighting);
    // The careful attempt has no judgement at all and still wins on the
    // arithmetic, because a request nobody made is not a mark against it.
    try testing.expectEqual(@as(usize, 1), chosen.winner);
    try testing.expectApproxEqAbs(
        careful.measured.reward(),
        weighting.rank(careful, judge_mod.default_rubric),
        0.0001,
    );
}

test "a tie goes to the earlier, less varied attempt" {
    // Nothing separates them, so the conservative direction is the lower
    // temperature — and a selector that flipped a coin here would make the
    // same task give different answers on different days for no reason.
    const attempts = [_]Attempt{
        attemptWith(0, "One answer.", .answered, 2, 2),
        attemptWith(1, "Another answer.", .answered, 2, 2),
    };
    const chosen = choose(&attempts, judge_mod.default_rubric, .{});
    try testing.expectEqual(@as(usize, 0), chosen.winner);
    try testing.expect(!chosen.paidOff());
}

test "the report shows every attempt, not only the one that won" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The losing attempts are the interesting half: same task, same model,
    // same moment, and the difference between them and the winner is the
    // closest thing to a controlled experiment this can produce.
    const attempts = [_]Attempt{
        attemptWith(0, "I could not work it out.", .out_of_budget, 4, 1),
        attemptWith(1, "Line five of main.zig.", .answered, 2, 2),
    };
    const chosen = choose(&attempts, judge_mod.default_rubric, .{});

    var out: std.Io.Writer.Allocating = .init(arena);
    try writeReport(chosen, judge_mod.default_rubric, .{}, &out.writer);
    const report = out.written();

    try testing.expect(std.mem.indexOf(u8, report, "attempt 1") != null);
    try testing.expect(std.mem.indexOf(u8, report, "attempt 2") != null);
    try testing.expect(std.mem.indexOf(u8, report, "->") != null);
    try testing.expect(std.mem.indexOf(u8, report, "provider's own setting") != null);
    try testing.expect(std.mem.indexOf(u8, report, "out_of_budget") != null);
}
