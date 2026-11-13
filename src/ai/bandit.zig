//! Choosing which model to use next, from what the models actually did here.
//!
//! A workspace has a catalogue of connectors and no way to say which one to
//! reach for. The usual answers are a hardcoded default, or a person's guess,
//! and both are stale the moment a new model ships. What this workspace does
//! have is a record of every run: which model did it, and — since
//! `ai/outcome.zig` — how well it went.
//!
//! That is a bandit problem, and it is the well-behaved kind. Each
//! (connector, model) is an arm, each run is a pull, and the reward is already
//! computed and reproducible.
//!
//! ## Thompson sampling, and why not a greedy rule
//!
//! Always picking the arm with the best mean is how a workspace gets stuck: a
//! model that had two bad runs early is never tried again, however good it
//! becomes, and the arm that happened to win the first three is used for ever.
//! Thompson sampling draws from each arm's posterior and plays the winner of
//! the draw, so a promising arm with little evidence keeps getting chances in
//! proportion to how likely it is to be best, and an arm with a long bad
//! record stops getting them without ever being banned.
//!
//! Rewards here are in [0, 1] rather than binary, so the posterior is
//! Beta(1 + Σr, 1 + Σ(1−r)). That is the standard extension and it degrades to
//! the Bernoulli case exactly when the rewards happen to be zero or one.
//!
//! ## The posteriors are derived, not stored
//!
//! There is no arm-statistics file. Every number here is computed from the log
//! on the way past, which means it cannot drift from the record, cannot be
//! edited to make a model look good, and needs no migration when the scoring
//! changes. Re-score the runs differently and the router's opinion changes
//! with them, which is the correct behaviour and the one a stored table would
//! not have.
//!
//! ## The choice is recorded
//!
//! Sampling is random, so a run that took a model's advice has to say which
//! draw it acted on or the record cannot explain why that model was used. The
//! seed is an argument rather than a global for the same reason: a replay
//! picks what the original picked.

const std = @import("std");
const outcome_mod = @import("outcome.zig");
const log_mod = @import("../events/log.zig");

/// One (connector, model) pair, and what is known about it.
pub const Arm = struct {
    connector: []const u8,
    model: []const u8,
    /// Runs this arm has taken.
    pulls: usize = 0,
    /// Reward summed over those runs.
    total: f64 = 0,

    pub fn mean(self: Arm) f64 {
        if (self.pulls == 0) return 0;
        return self.total / @as(f64, @floatFromInt(self.pulls));
    }

    /// Beta(1 + Σr, 1 + Σ(1−r)). The prior of one and one is uniform: an arm
    /// nobody has tried is equally likely to be anything, which is what makes
    /// a new model get tried rather than assumed bad.
    pub fn alpha(self: Arm) f64 {
        return 1.0 + self.total;
    }

    pub fn beta(self: Arm) f64 {
        return 1.0 + (@as(f64, @floatFromInt(self.pulls)) - self.total);
    }

    /// How wide the posterior still is. Falls as evidence accumulates, and is
    /// what a person wants when asking "do we actually know this yet".
    pub fn uncertainty(self: Arm) f64 {
        const a = self.alpha();
        const b = self.beta();
        const n = a + b;
        return @sqrt((a * b) / (n * n * (n + 1.0)));
    }

    pub fn writeSentence(self: Arm, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.pulls == 0) {
            try w.print("{s}/{s}: never used here", .{ self.connector, self.model });
            return;
        }
        try w.print("{s}/{s}: {d:.2} over {d} run{s}, give or take {d:.2}", .{
            self.connector,
            self.model,
            self.mean(),
            self.pulls,
            if (self.pulls == 1) "" else "s",
            self.uncertainty(),
        });
    }
};

pub const Choice = struct {
    arm: Arm,
    /// The value drawn from this arm's posterior, which is why it won.
    draw: f64,
    /// True when nothing has been recorded at all and the pick was arbitrary.
    ///
    /// Worth saying out loud: a router with no evidence is a random choice
    /// wearing a suit, and presenting it as a recommendation would be the
    /// dishonest part.
    blind: bool = false,

    pub fn writeSentence(self: Choice, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.blind) {
            try w.print(
                "Nothing has been recorded yet, so {s}/{s} is a starting point rather than a recommendation.",
                .{ self.arm.connector, self.arm.model },
            );
            return;
        }
        try w.print("{s}/{s}, drawn at {d:.2} from ", .{ self.arm.connector, self.arm.model, self.draw });
        if (self.arm.pulls == 0) {
            try w.writeAll("no evidence at all — it is being tried because untried is not the same as bad.");
        } else {
            try w.print("{d} run{s} averaging {d:.2}.", .{
                self.arm.pulls,
                if (self.arm.pulls == 1) "" else "s",
                self.arm.mean(),
            });
        }
    }
};

/// Read every arm out of a log.
///
/// Arms with no runs are not invented here — a caller that wants an untried
/// model considered passes it to `choose`, because only the caller knows which
/// connectors this workspace is allowed to reach.
pub fn armsIn(arena: std.mem.Allocator, log: log_mod.Log) ![]const Arm {
    const scores = try outcome_mod.scoreAll(arena, log);
    var out: std.ArrayList(Arm) = .empty;

    for (scores) |score| {
        // A run that never wrote an ending tells us nothing about the model:
        // it was interrupted, and counting it as a bad outcome would punish an
        // arm for a full disk.
        if (score.ending == .unfinished) continue;

        var found = false;
        for (out.items) |*arm| {
            if (!std.mem.eql(u8, arm.connector, score.connector)) continue;
            if (!std.mem.eql(u8, arm.model, score.model)) continue;
            arm.pulls += 1;
            arm.total += score.reward();
            found = true;
            break;
        }
        if (!found) try out.append(arena, .{
            .connector = score.connector,
            .model = score.model,
            .pulls = 1,
            .total = score.reward(),
        });
    }
    return out.items;
}

/// Pick an arm by Thompson sampling.
///
/// `candidates` may include arms with no runs — a model that just shipped, or
/// one the workspace has never reached for. They are drawn from a uniform
/// posterior, so they are tried at the rate their ignorance deserves rather
/// than never.
pub fn choose(arms: []const Arm, seed: u64) ?Choice {
    if (arms.len == 0) return null;

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var best: ?Choice = null;
    var any_evidence = false;
    for (arms) |arm| {
        if (arm.pulls > 0) any_evidence = true;
        const draw = sampleBeta(random, arm.alpha(), arm.beta());
        if (best == null or draw > best.?.draw) {
            best = .{ .arm = arm, .draw = draw };
        }
    }
    if (best) |*choice| choice.blind = !any_evidence;
    return best;
}

/// One draw from Beta(a, b).
///
/// Built from two Gamma draws, which is the standard construction: if
/// X ~ Gamma(a, 1) and Y ~ Gamma(b, 1) then X / (X + Y) ~ Beta(a, b). Zig's
/// standard library has no Beta, and writing the two Gammas is less code than
/// a rejection sampler and has no failure mode to get wrong.
fn sampleBeta(random: std.Random, a: f64, b: f64) f64 {
    const x = sampleGamma(random, a);
    const y = sampleGamma(random, b);
    if (x + y <= 0) return 0.5;
    return x / (x + y);
}

/// One draw from Gamma(shape, 1), by Marsaglia and Tsang.
///
/// The method needs shape >= 1; below that it uses the standard boost, drawing
/// at shape + 1 and scaling down. Both branches matter here: an arm with a
/// single low reward has a shape under one, and getting that wrong would make
/// a barely-tried arm look confidently bad.
fn sampleGamma(random: std.Random, shape: f64) f64 {
    if (shape <= 0) return 0;
    if (shape < 1.0) {
        const boosted = sampleGamma(random, shape + 1.0);
        const u = @max(random.float(f64), 1e-12);
        return boosted * std.math.pow(f64, u, 1.0 / shape);
    }

    const d = shape - 1.0 / 3.0;
    const c = 1.0 / @sqrt(9.0 * d);
    while (true) {
        var x: f64 = undefined;
        var v: f64 = undefined;
        while (true) {
            x = random.floatNorm(f64);
            v = 1.0 + c * x;
            if (v > 0) break;
        }
        v = v * v * v;
        const u = @max(random.float(f64), 1e-12);
        if (u < 1.0 - 0.0331 * x * x * x * x) return d * v;
        if (@log(u) < 0.5 * x * x + d * (1.0 - v + @log(v))) return d * v;
    }
}

/// How much a set of untried arms will crowd out the evidence.
///
/// Worth knowing before offering candidates, because it is the way a Thompson
/// router is most often set up wrong. Each untried arm draws from a uniform
/// posterior, so with `untried` of them the best of their draws averages
/// `untried / (untried + 1)`. Offer nine and something above 0.9 turns up
/// nearly every round, which beats any real arm short of a perfect record —
/// and the router explores for ever while looking like it is working.
///
/// The fix is never a fudge factor on the sampler. It is to offer arms that
/// are genuinely worth trying, which is the caller's judgement, not this
/// file's.
pub fn crowdingFrom(untried: usize) f64 {
    if (untried == 0) return 0;
    const n: f64 = @floatFromInt(untried);
    return n / (n + 1.0);
}

/// Merge what the log knows with the arms a caller wants considered.
///
/// A connector the workspace can reach but has never used belongs in the draw;
/// leaving it out is how a router never discovers a better model.
pub fn withCandidates(
    arena: std.mem.Allocator,
    known: []const Arm,
    candidates: []const Arm,
) ![]const Arm {
    var out: std.ArrayList(Arm) = .empty;
    try out.appendSlice(arena, known);
    for (candidates) |candidate| {
        var seen = false;
        for (known) |arm| {
            if (std.mem.eql(u8, arm.connector, candidate.connector) and
                std.mem.eql(u8, arm.model, candidate.model)) seen = true;
        }
        if (!seen) try out.append(arena, candidate);
    }
    return out.items;
}

const testing = std.testing;

/// How often each arm wins over many draws. The only honest way to test a
/// sampler: one draw says nothing, and the distribution is the claim.
fn winShare(arms: []const Arm, of: []const u8, rounds: usize) f64 {
    var wins: usize = 0;
    for (0..rounds) |round| {
        const choice = choose(arms, @intCast(round * 2654435761 + 12345)).?;
        if (std.mem.eql(u8, choice.arm.model, of)) wins += 1;
    }
    return @as(f64, @floatFromInt(wins)) / @as(f64, @floatFromInt(rounds));
}

test "the arm with a better record is played more often" {
    const arms = [_]Arm{
        .{ .connector = "a", .model = "good", .pulls = 20, .total = 16 },
        .{ .connector = "a", .model = "poor", .pulls = 20, .total = 4 },
    };
    // With twenty runs each and means of 0.8 against 0.2 the posteriors barely
    // overlap, so the better arm should win essentially always. Asserting that
    // it sometimes loses would be asserting that the sampler is bad at its job.
    try testing.expect(winShare(&arms, "good", 400) > 0.95);
}

test "arms that are close together are both still played" {
    // Where exploration has to show up: two arms whose evidence does not
    // separate them. A sampler that locked onto the leading one here would be
    // making a decision the evidence does not support.
    const arms = [_]Arm{
        .{ .connector = "a", .model = "slightly ahead", .pulls = 10, .total = 6.0 },
        .{ .connector = "a", .model = "slightly behind", .pulls = 10, .total = 5.0 },
    };
    const behind = winShare(&arms, "slightly behind", 400);
    try testing.expect(behind > 0.2);
    try testing.expect(behind < 0.5);
}

test "a promising arm with little evidence keeps getting chances" {
    // The failure mode of picking the best mean: an arm that had two bad runs
    // early is never tried again, however good it becomes. Here the poorly
    // understood arm has a worse mean and a much wider posterior, so it still
    // wins often enough to find out.
    const arms = [_]Arm{
        .{ .connector = "a", .model = "settled", .pulls = 40, .total = 26 },
        .{ .connector = "a", .model = "barely tried", .pulls = 2, .total = 1 },
    };
    const explored = winShare(&arms, "barely tried", 400);
    try testing.expect(explored > 0.05);
    try testing.expect(explored < 0.5);
}

test "an arm nobody has tried is not treated as a bad one" {
    // A model that shipped this morning has no record. Scoring it zero would
    // mean it is never used, and the workspace would never discover it.
    const arms = [_]Arm{
        .{ .connector = "a", .model = "known", .pulls = 30, .total = 21 },
        .{ .connector = "a", .model = "new", .pulls = 0, .total = 0 },
    };
    const tried = winShare(&arms, "new", 400);
    try testing.expect(tried > 0.15);

    // And a uniform prior means an untried arm is neither favoured nor
    // punished: its posterior mean is a half, not zero and not one.
    const fresh: Arm = .{ .connector = "a", .model = "new" };
    try testing.expectApproxEqAbs(@as(f64, 0.5), fresh.alpha() / (fresh.alpha() + fresh.beta()), 0.001);
}

test "evidence narrows the posterior" {
    // What "do we actually know this yet" means. Two arms with the same mean
    // and different amounts of evidence are not the same claim.
    const thin: Arm = .{ .connector = "a", .model = "m", .pulls = 3, .total = 2.1 };
    const thick: Arm = .{ .connector = "a", .model = "m", .pulls = 60, .total = 42 };
    try testing.expectApproxEqAbs(thin.mean(), thick.mean(), 0.01);
    try testing.expect(thick.uncertainty() < thin.uncertainty());

    // And the better-understood one wins more, because its draws cluster.
    const arms = [_]Arm{
        .{ .connector = "a", .model = "thin", .pulls = 3, .total = 0.3 },
        .{ .connector = "a", .model = "thick", .pulls = 60, .total = 42 },
    };
    try testing.expect(winShare(&arms, "thick", 400) > 0.8);
}

test "the same seed picks the same arm, so a replay picks what the run picked" {
    const arms = [_]Arm{
        .{ .connector = "a", .model = "one", .pulls = 10, .total = 5 },
        .{ .connector = "b", .model = "two", .pulls = 10, .total = 6 },
        .{ .connector = "c", .model = "three", .pulls = 10, .total = 4 },
    };
    const first = choose(&arms, 424242).?;
    const again = choose(&arms, 424242).?;
    try testing.expectEqualStrings(first.arm.model, again.arm.model);
    try testing.expectEqual(first.draw, again.draw);

    // A different seed is free to disagree, or the sampler is not sampling.
    var differed = false;
    for (0..50) |i| {
        const other = choose(&arms, @intCast(i * 7919 + 1)).?;
        if (!std.mem.eql(u8, other.arm.model, first.arm.model)) differed = true;
    }
    try testing.expect(differed);
}

test "arms are read out of the log, and an interrupted run is not held against a model" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = outcome_mod.testBuilder(arena);
    try builder.started("a job", "anthropic", "claude-opus-5");
    try builder.call("read_file", "a", .completed);
    try builder.ended(.answered);

    builder.nextAgent();
    try builder.started("another job", "anthropic", "claude-opus-5");
    try builder.call("read_file", "b", .failed);
    try builder.ended(.out_of_budget);

    builder.nextAgent();
    try builder.started("a third", "ollama", "llama3.2");
    try builder.call("read_file", "c", .completed);
    try builder.ended(.answered);

    // Interrupted: no ending written. A crash or a full disk says nothing
    // about the model, and counting it as a loss would punish an arm for the
    // machine it ran on.
    builder.nextAgent();
    try builder.started("interrupted", "anthropic", "claude-opus-5");
    try builder.call("read_file", "d", .completed);

    const arms = try armsIn(arena, builder.log);
    try testing.expectEqual(@as(usize, 2), arms.len);

    var opus: ?Arm = null;
    for (arms) |arm| {
        if (std.mem.eql(u8, arm.model, "claude-opus-5")) opus = arm;
    }
    try testing.expectEqual(@as(usize, 2), opus.?.pulls);
}

test "a connector the workspace has never used is still considered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Leaving untried connectors out of the draw is how a router never
    // discovers a better model. The caller supplies them, because only it
    // knows what this workspace is allowed to reach.
    const known = [_]Arm{.{ .connector = "anthropic", .model = "claude-opus-5", .pulls = 5, .total = 4 }};
    const candidates = [_]Arm{
        .{ .connector = "anthropic", .model = "claude-opus-5" },
        .{ .connector = "ollama", .model = "llama3.2" },
    };

    const merged = try withCandidates(arena, &known, &candidates);
    try testing.expectEqual(@as(usize, 2), merged.len);
    // The known arm keeps its evidence rather than being reset by appearing in
    // the candidate list too.
    try testing.expectEqual(@as(usize, 5), merged[0].pulls);
    try testing.expectEqual(@as(usize, 0), merged[1].pulls);
}

test "a router with nothing recorded says so instead of recommending" {
    const nothing = [_]Arm{
        .{ .connector = "a", .model = "one" },
        .{ .connector = "b", .model = "two" },
    };
    const choice = choose(&nothing, 5).?;
    try testing.expect(choice.blind);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try choice.writeSentence(&out.writer);
    // A router with no evidence is a random choice wearing a suit. Presenting
    // it as a recommendation would be the dishonest part.
    try testing.expect(std.mem.indexOf(u8, out.written(), "rather than a recommendation") != null);

    try testing.expect(choose(&.{}, 1) == null);
}

test "many untried arms drown the evidence, which is the caller's problem to avoid" {
    // The way a Thompson router is most often set up wrong, and it looks like
    // it is working while it happens. Each untried arm draws from a uniform
    // posterior, so the best of nine of them clears 0.9 most rounds and beats
    // a real arm with a real record.
    var many: [10]Arm = undefined;
    many[0] = .{ .connector = "used", .model = "known", .pulls = 20, .total = 9 };
    for (many[1..], 0..) |*arm, i| {
        arm.* = .{ .connector = "untried", .model = switch (i) {
            0 => "a",
            1 => "b",
            2 => "c",
            3 => "d",
            4 => "e",
            5 => "f",
            6 => "g",
            7 => "h",
            else => "i",
        } };
    }

    const known_wins = winShare(&many, "known", 300);
    try testing.expect(known_wins < 0.15);
    // And the arithmetic that predicts it, so a caller can check its candidate
    // list before being surprised by it.
    try testing.expect(crowdingFrom(9) > 0.85);
    try testing.expectApproxEqAbs(@as(f64, 0.5), crowdingFrom(1), 0.001);
    try testing.expectEqual(@as(f64, 0), crowdingFrom(0));

    // With one untried arm instead of nine, the evidence is heard again. The
    // fix is the candidate list, never a fudge factor on the sampler.
    const few = [_]Arm{
        .{ .connector = "used", .model = "known", .pulls = 20, .total = 9 },
        .{ .connector = "untried", .model = "a" },
    };
    try testing.expect(winShare(&few, "known", 300) > 0.3);
}
