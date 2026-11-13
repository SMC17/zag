//! Learning which model suits which kind of task, from the runs already here.
//!
//! `ai/bandit.zig` chooses a model by sampling each one's record of success.
//! It works, and it has one blind spot that matters: it has no idea what it is
//! being asked. Every task is the same task to it, so a model that is excellent
//! at reading code and poor at writing it gets one number that averages the
//! two, and the router recommends it for both.
//!
//! This is the same choice made *with the question in hand*. A linear policy
//! over features of the task, trained by REINFORCE with a baseline on the
//! rewards the workspace has already recorded. Same arms, same reward, same
//! log — the only new thing is that the task is an input.
//!
//! ## Why linear, and why the features are named
//!
//! A workspace has tens or hundreds of runs, not millions. Anything with more
//! parameters than that would fit the noise perfectly and predict nothing, and
//! it would do it invisibly. A linear policy over a handful of named features
//! has few enough parameters to be trained on this much data, and — more
//! usefully — its weights are readable: `writeReport` prints, for each arm,
//! which feature pushes toward it and by how much. A weight nobody can see is
//! a claim nobody can check, which is the same reason the reward weights in
//! `ai/outcome.zig` are written out rather than tuned.
//!
//! ## The dishonest thing this could do, and does not
//!
//! The episodes were not produced by this policy. They were produced by the
//! bandit, by a person passing `--provider`, and by whatever the default was
//! that month. Training on them and reporting the training reward as though it
//! were this policy's expected reward is the standard way to get a number that
//! looks like an improvement and is not: it is measuring the behaviour that
//! generated the data.
//!
//! What is done instead: the episodes are split, the policy is trained on one
//! part and estimated on the other, and the estimate is self-normalised
//! importance sampling against the *observed* action frequencies — the closest
//! thing to the behaviour policy that the record actually contains. That is
//! still an estimate with real weaknesses, so:
//!
//! - The same estimate is computed for the arm the record simply likes best,
//!   which is what the bandit converges to. A trained policy that cannot beat
//!   that on held-out episodes is not worth using, and `worthUsing` says so.
//! - `Trained.notes` names every reason the estimate may be wrong that this
//!   file can detect: too few episodes, too few arms, an effective sample size
//!   that has collapsed onto a handful of episodes.
//!
//! A router that says "not enough evidence, use the bandit" is doing its job.

const std = @import("std");
const outcome_mod = @import("outcome.zig");
const bandit_mod = @import("bandit.zig");
const log_mod = @import("../events/log.zig");

/// One thing that happened: a task, what was used on it, and how it went.
pub const Episode = struct {
    task: []const u8,
    connector: []const u8,
    model: []const u8,
    reward: f64,
};

/// What the policy looks at.
///
/// Deliberately few, deliberately crude, and deliberately named. Each is
/// something a person would say out loud about a task — "it is a question",
/// "it wants something changed" — so a weight on it can be argued with.
/// Nothing here reads the workspace or the file the task mentions: a feature
/// that needs work to compute is a feature that has to be recomputed
/// identically at routing time, and the two would drift.
pub const Feature = enum {
    /// Always one. Without it a policy cannot express "this arm is better in
    /// general", and every preference has to be attached to some word.
    bias,
    /// How long the request is, flattened by a logarithm and scaled to about
    /// [0, 1]. A one-line question and a three-paragraph specification are
    /// different kinds of work.
    length,
    /// Asks for an explanation rather than a change.
    explains,
    /// Asks for something to be changed, written or fixed.
    changes,
    /// Asks for something to be run, built or tested.
    runs,
    /// Names a failure. These are the runs where a model's ability to read an
    /// error message matters more than anything else about it.
    failing,
    /// Ends in a question mark. Cheap, and it separates "why is this slow?"
    /// from "make this faster".
    asks,

    pub const count = @typeInfo(Feature).@"enum".fields.len;

    pub fn text(self: Feature) []const u8 {
        return switch (self) {
            .bias => "in general",
            .length => "a long request",
            .explains => "asks for an explanation",
            .changes => "asks for a change",
            .runs => "asks to run something",
            .failing => "names a failure",
            .asks => "is a question",
        };
    }
};

pub const Vector = [Feature.count]f64;

/// Read the features out of a task, the same way at training and at routing.
///
/// One function, called from both, because two copies of this is how a learned
/// policy comes to be evaluated on features it was never trained on.
pub fn featuresOf(task: []const u8) Vector {
    var out: Vector = @splat(0);
    out[@intFromEnum(Feature.bias)] = 1;

    const length: f64 = @floatFromInt(task.len);
    // About [0, 1] over the range a request actually falls in: ten characters
    // to a few thousand. Unbounded features make one long task dominate a
    // whole training set.
    out[@intFromEnum(Feature.length)] = std.math.clamp(@log(length + 1) / 8.0, 0, 1);

    if (mentionsAny(task, &.{ "why", "explain", "what does", "how does", "understand" })) {
        out[@intFromEnum(Feature.explains)] = 1;
    }
    if (mentionsAny(task, &.{ "fix", "change", "write", "add ", "remove", "rename", "implement", "refactor" })) {
        out[@intFromEnum(Feature.changes)] = 1;
    }
    if (mentionsAny(task, &.{ "run ", "build", "test", "compile", "benchmark" })) {
        out[@intFromEnum(Feature.runs)] = 1;
    }
    if (mentionsAny(task, &.{ "fail", "error", "broke", "broken", "crash", "panic", "wrong" })) {
        out[@intFromEnum(Feature.failing)] = 1;
    }
    const trimmed = std.mem.trimEnd(u8, task, " \t\r\n");
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '?') {
        out[@intFromEnum(Feature.asks)] = 1;
    }
    return out;
}

fn mentionsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(haystack, needle) != null) return true;
    }
    return false;
}

/// One thing the policy can choose.
pub const Arm = struct {
    connector: []const u8,
    model: []const u8,

    pub fn sameAs(self: Arm, connector: []const u8, model: []const u8) bool {
        return std.mem.eql(u8, self.connector, connector) and std.mem.eql(u8, self.model, model);
    }
};

/// A linear softmax policy: one weight vector per arm.
pub const Policy = struct {
    arms: []const Arm,
    /// Row-major, `arms.len` rows of `Feature.count`.
    weights: []f64,

    pub fn init(arena: std.mem.Allocator, arms: []const Arm) !Policy {
        const weights = try arena.alloc(f64, arms.len * Feature.count);
        @memset(weights, 0);
        return .{ .arms = arms, .weights = weights };
    }

    pub fn rowOf(self: Policy, arm: usize) []f64 {
        return self.weights[arm * Feature.count ..][0..Feature.count];
    }

    fn scoreOf(self: Policy, arm: usize, features: Vector) f64 {
        var total: f64 = 0;
        const row = self.weights[arm * Feature.count ..][0..Feature.count];
        for (row, features) |weight, value| total += weight * value;
        return total;
    }

    /// The probability of each arm for one task, written into `out`.
    ///
    /// Softmax with the maximum subtracted first, which changes nothing about
    /// the answer and everything about whether it is computable: without it a
    /// weight that has grown to 800 becomes `exp(800)`, which is infinity, and
    /// every probability becomes a NaN that then trains the next pass.
    pub fn probabilities(self: Policy, features: Vector, out: []f64) void {
        std.debug.assert(out.len == self.arms.len);
        var largest: f64 = -std.math.inf(f64);
        for (self.arms, 0..) |_, index| {
            out[index] = self.scoreOf(index, features);
            if (out[index] > largest) largest = out[index];
        }
        var total: f64 = 0;
        for (out) |*value| {
            value.* = @exp(value.* - largest);
            total += value.*;
        }
        if (total == 0) {
            const even = 1.0 / @as(f64, @floatFromInt(out.len));
            for (out) |*value| value.* = even;
            return;
        }
        for (out) |*value| value.* /= total;
    }

    /// The arm this policy thinks is best for a task.
    pub fn best(self: Policy, arena: std.mem.Allocator, features: Vector) !usize {
        const chances = try arena.alloc(f64, self.arms.len);
        self.probabilities(features, chances);
        var at: usize = 0;
        for (chances, 0..) |chance, index| {
            if (chance > chances[at]) at = index;
        }
        return at;
    }

    /// Draw an arm, rather than taking the best one.
    ///
    /// Sampling is the whole reason this is a policy and not a classifier: a
    /// router that always plays its favourite stops learning about everything
    /// else the moment it has an opinion, and its opinion was formed on
    /// whatever it happened to see first.
    pub fn sample(self: Policy, features: Vector, chances: []f64, seed: u64) usize {
        self.probabilities(features, chances);
        var random = std.Random.DefaultPrng.init(seed);
        var draw = random.random().float(f64);
        for (chances, 0..) |chance, index| {
            if (draw < chance) return index;
            draw -= chance;
        }
        return chances.len - 1;
    }

    pub fn indexOf(self: Policy, connector: []const u8, model: []const u8) ?usize {
        for (self.arms, 0..) |arm, index| {
            if (arm.sameAs(connector, model)) return index;
        }
        return null;
    }
};

pub const Training = struct {
    /// How far each episode moves the weights.
    rate: f64 = 0.1,
    /// How many times the training set is walked.
    passes: usize = 200,
    /// Pulls weights back toward zero, which is the uniform policy. With this
    /// much data it is the difference between a policy that has an opinion and
    /// one that has memorised six episodes.
    l2: f64 = 0.01,
    /// The share of episodes held back to estimate on. Nothing is estimated on
    /// an episode that moved the weights.
    holdout: f64 = 0.3,
    /// Fixed, so training the same log twice gives the same policy. A trainer
    /// whose answer depends on the time of day cannot be checked.
    seed: u64 = 0x5EED,
};

/// What came out, and every reason to doubt it that this file can detect.
pub const Trained = struct {
    policy: Policy,
    trainedOn: usize = 0,
    heldOut: usize = 0,
    /// Estimated mean reward of the trained policy on the held-out episodes.
    estimate: f64 = 0,
    /// The same estimate for always playing the arm with the best record,
    /// which is what the bandit converges to. This is the number to beat.
    incumbent: f64 = 0,
    /// The arm that estimate belongs to.
    incumbentArm: ?Arm = null,
    /// How many held-out episodes the estimate effectively rests on.
    ///
    /// Importance sampling can put nearly all of its weight on one or two
    /// episodes and still report a mean over thirty. This is Kish's effective
    /// sample size, and when it is small the estimate is one episode wearing a
    /// crowd's clothing.
    effective: f64 = 0,
    notes: []const []const u8 = &.{},

    /// Whether to route with this rather than with the bandit.
    ///
    /// Three things have to hold, and the first two are about the data rather
    /// than the result: enough held-out episodes for a mean to mean anything,
    /// an effective sample size that has not collapsed, and a margin over the
    /// incumbent big enough not to be the estimator's own noise.
    pub fn worthUsing(self: Trained) bool {
        if (self.heldOut < 12) return false;
        if (self.effective < 6) return false;
        if (self.policy.arms.len < 2) return false;
        return self.estimate > self.incumbent + 0.05;
    }

    pub fn writeReport(self: Trained, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("Trained on {d} runs, estimated on {d} held back.\n", .{ self.trainedOn, self.heldOut });
        if (self.heldOut > 0) {
            try w.print(
                "This policy estimates {d:.2} on those, against {d:.2} for always using ",
                .{ self.estimate, self.incumbent },
            );
            if (self.incumbentArm) |arm| {
                try w.print("{s}/{s}", .{ arm.connector, arm.model });
            } else {
                try w.writeAll("the best-recorded arm");
            }
            try w.print(". Effective sample {d:.1}.\n", .{self.effective});
        }

        for (self.notes) |note| try w.print("  {s}\n", .{note});

        if (self.policy.arms.len == 0) return;
        try w.writeAll("\nWhat it learned\n");
        for (self.policy.arms, 0..) |arm, index| {
            try w.print("  {s}/{s}\n", .{ arm.connector, arm.model });
            const row = self.policy.rowOf(index);
            for (row, 0..) |weight, feature| {
                // Below this a weight is not a preference, it is the last
                // pass's rounding.
                if (@abs(weight) < 0.05) continue;
                try w.print("    {s:<28} {s}{d:.2}\n", .{
                    @as(Feature, @enumFromInt(feature)).text(),
                    if (weight > 0) "+" else "",
                    weight,
                });
            }
        }

        try w.writeAll("\n");
        if (self.worthUsing()) {
            try w.writeAll("Worth routing with: it beats the best single arm on runs it never saw.\n");
        } else {
            try w.writeAll("Not worth routing with yet. Use the bandit, and come back with more runs.\n");
        }
    }
};

/// Train a policy on recorded episodes.
///
/// REINFORCE with a baseline. The update for one episode is the advantage —
/// the reward minus what a run like this usually gets — times the gradient of
/// the log-probability of the action taken. In this linear case that gradient
/// is `(one-hot(action) - probabilities) ⊗ features`, which is the whole
/// derivation and is why this is forty lines rather than a framework.
///
/// The baseline is not a constant. It is the mean reward of every episode,
/// which is the standard choice, and it matters more than the learning rate:
/// without it every action taken is reinforced in proportion to a reward that
/// is always positive, so the policy learns to do whatever it saw most.
pub fn train(
    arena: std.mem.Allocator,
    episodes: []const Episode,
    options: Training,
) !Trained {
    var arms: std.ArrayList(Arm) = .empty;
    for (episodes) |episode| {
        var known = false;
        for (arms.items) |arm| {
            if (arm.sameAs(episode.connector, episode.model)) known = true;
        }
        if (!known) try arms.append(arena, .{ .connector = episode.connector, .model = episode.model });
    }

    var notes: std.ArrayList([]const u8) = .empty;
    var trained: Trained = .{ .policy = try Policy.init(arena, arms.items) };
    if (episodes.len == 0) {
        trained.notes = try arena.dupe([]const u8, &.{"There are no recorded runs to learn from."});
        return trained;
    }
    if (arms.items.len < 2) {
        try notes.append(arena, "Only one model has been used here, so there is nothing to choose between.");
    }

    // Split before anything is fitted. Deterministic, and by a hash of the
    // task rather than by position, so the same task always lands on the same
    // side and re-running the trainer does not quietly reshuffle the estimate.
    var learning: std.ArrayList(Episode) = .empty;
    var holding: std.ArrayList(Episode) = .empty;
    for (episodes) |episode| {
        const digest = std.hash.Wyhash.hash(options.seed, episode.task);
        const side = @as(f64, @floatFromInt(digest % 1000)) / 1000.0;
        if (side < options.holdout) {
            try holding.append(arena, episode);
        } else {
            try learning.append(arena, episode);
        }
    }
    trained.trainedOn = learning.items.len;
    trained.heldOut = holding.items.len;

    if (learning.items.len == 0) {
        trained.notes = try arena.dupe([]const u8, &.{"Every run landed in the held-back set, so nothing was learned."});
        return trained;
    }

    var baseline: f64 = 0;
    for (learning.items) |episode| baseline += episode.reward;
    baseline /= @floatFromInt(learning.items.len);

    const chances = try arena.alloc(f64, arms.items.len);
    const order = try arena.alloc(usize, learning.items.len);
    for (order, 0..) |*at, index| at.* = index;

    var random = std.Random.DefaultPrng.init(options.seed);
    var pass: usize = 0;
    while (pass < options.passes) : (pass += 1) {
        // Shuffled each pass, from a fixed seed. In order, the last few
        // episodes of every pass move the weights last and so move them most.
        random.random().shuffle(usize, order);
        for (order) |at| {
            const episode = learning.items[at];
            const taken = trained.policy.indexOf(episode.connector, episode.model) orelse continue;
            const features = featuresOf(episode.task);
            trained.policy.probabilities(features, chances);

            const advantage = episode.reward - baseline;
            for (0..arms.items.len) |arm| {
                const indicator: f64 = if (arm == taken) 1 else 0;
                const direction = indicator - chances[arm];
                const row = trained.policy.rowOf(arm);
                for (row, features) |*weight, value| {
                    weight.* += options.rate * advantage * direction * value;
                    // Toward zero, which is the uniform policy. A weight that
                    // only ever grows is a policy memorising six episodes.
                    weight.* -= options.rate * options.l2 * weight.*;
                }
            }
        }
    }

    // The estimate, on episodes that moved nothing.
    if (holding.items.len > 0) {
        // The behaviour policy is not recorded, so the closest thing the log
        // holds is how often each arm was actually used. Assuming that is what
        // generated the data is wrong in a knowable direction — the bandit
        // was not stationary — and it is the honest available estimate rather
        // than an exact one.
        const behaviour = try arena.alloc(f64, arms.items.len);
        @memset(behaviour, 0);
        for (episodes) |episode| {
            const at = trained.policy.indexOf(episode.connector, episode.model) orelse continue;
            behaviour[at] += 1;
        }
        for (behaviour) |*count| {
            count.* = (count.* + 1) / @as(f64, @floatFromInt(episodes.len + arms.items.len));
        }

        var best_arm: usize = 0;
        var best_reward: f64 = -1;
        for (arms.items, 0..) |_, index| {
            var total: f64 = 0;
            var seen: usize = 0;
            for (episodes) |episode| {
                if (trained.policy.indexOf(episode.connector, episode.model) != index) continue;
                total += episode.reward;
                seen += 1;
            }
            if (seen == 0) continue;
            const mean = total / @as(f64, @floatFromInt(seen));
            if (mean > best_reward) {
                best_reward = mean;
                best_arm = index;
            }
        }
        trained.incumbentArm = if (arms.items.len > 0) arms.items[best_arm] else null;

        var weighted: f64 = 0;
        var mass: f64 = 0;
        var square: f64 = 0;
        var incumbent_weighted: f64 = 0;
        var incumbent_mass: f64 = 0;
        for (holding.items) |episode| {
            const taken = trained.policy.indexOf(episode.connector, episode.model) orelse continue;
            const features = featuresOf(episode.task);
            trained.policy.probabilities(features, chances);

            const ratio = chances[taken] / behaviour[taken];
            weighted += ratio * episode.reward;
            mass += ratio;
            square += ratio * ratio;

            // The incumbent is a policy too: probability one on its arm.
            const incumbent_ratio: f64 = if (taken == best_arm) 1.0 / behaviour[taken] else 0;
            incumbent_weighted += incumbent_ratio * episode.reward;
            incumbent_mass += incumbent_ratio;
        }
        trained.estimate = if (mass > 0) weighted / mass else 0;
        trained.incumbent = if (incumbent_mass > 0) incumbent_weighted / incumbent_mass else 0;
        // Kish. A mean over thirty episodes whose weight sits on two is a mean
        // over two, and saying thirty would be the lie this whole file is
        // arranged to avoid.
        trained.effective = if (square > 0) (mass * mass) / square else 0;
    }

    if (trained.heldOut < 12) {
        try notes.append(arena, "Fewer than a dozen runs were held back, which is too few for the estimate to mean much.");
    }
    if (trained.heldOut > 0 and trained.effective < 6) {
        try notes.append(arena, "Most of the estimate rests on a handful of runs, because this policy would rarely have chosen what was actually chosen.");
    }
    trained.notes = notes.items;
    return trained;
}

/// Every recorded run in a log, as an episode.
///
/// A run with no task is skipped rather than trained on an empty feature
/// vector, where every arm looks identical and the update is pure noise.
pub fn episodesIn(arena: std.mem.Allocator, log: log_mod.Log) ![]const Episode {
    const scores = try outcome_mod.scoreAll(arena, log);
    var out: std.ArrayList(Episode) = .empty;
    for (scores) |score| {
        if (score.task.len == 0) continue;
        if (score.model.len == 0 or score.connector.len == 0) continue;
        // A run the record never saw finish has no outcome to learn from, and
        // scoring it as a failure would teach that interruptions are the
        // model's fault.
        if (score.ending == .unfinished) continue;
        try out.append(arena, .{
            .task = score.task,
            .connector = score.connector,
            .model = score.model,
            .reward = score.reward(),
        });
    }
    return out.items;
}

/// The arms a trained policy would choose between, as the bandit knows them.
pub fn armsFrom(arena: std.mem.Allocator, arms: []const bandit_mod.Arm) ![]const Arm {
    var out: std.ArrayList(Arm) = .empty;
    for (arms) |arm| {
        try out.append(arena, .{ .connector = arm.connector, .model = arm.model });
    }
    return out.items;
}

const testing = std.testing;

test "the features are what a person would say out loud about a task" {
    // Each one has to be something a weight on it can be argued with.
    const explaining = featuresOf("Why does the build fail?");
    try testing.expectEqual(@as(f64, 1), explaining[@intFromEnum(Feature.bias)]);
    try testing.expectEqual(@as(f64, 1), explaining[@intFromEnum(Feature.explains)]);
    try testing.expectEqual(@as(f64, 1), explaining[@intFromEnum(Feature.asks)]);
    try testing.expectEqual(@as(f64, 1), explaining[@intFromEnum(Feature.failing)]);
    try testing.expectEqual(@as(f64, 0), explaining[@intFromEnum(Feature.changes)]);

    const changing = featuresOf("Fix the retry backoff in transport.zig");
    try testing.expectEqual(@as(f64, 1), changing[@intFromEnum(Feature.changes)]);
    try testing.expectEqual(@as(f64, 0), changing[@intFromEnum(Feature.asks)]);

    // Length is flattened and bounded. An unbounded feature lets one long task
    // dominate a whole training set.
    var enormous: [4000]u8 = undefined;
    @memset(&enormous, 'x');
    const long = featuresOf(&enormous);
    try testing.expect(long[@intFromEnum(Feature.length)] <= 1.0);
    try testing.expect(long[@intFromEnum(Feature.length)] > featuresOf("why?")[@intFromEnum(Feature.length)]);
}

test "softmax survives a weight that has grown large" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Without subtracting the maximum first, this is exp(800): infinity, then
    // a NaN in every probability, then a NaN trained into the next pass. The
    // symptom is a router that recommends nothing and says nothing about why.
    const policy = try Policy.init(arena, &.{
        .{ .connector = "a", .model = "one" },
        .{ .connector = "b", .model = "two" },
    });
    policy.rowOf(0)[@intFromEnum(Feature.bias)] = 800;
    policy.rowOf(1)[@intFromEnum(Feature.bias)] = -800;

    var chances: [2]f64 = undefined;
    policy.probabilities(featuresOf("anything"), &chances);
    try testing.expect(!std.math.isNan(chances[0]));
    try testing.expectApproxEqAbs(@as(f64, 1.0), chances[0] + chances[1], 0.0001);
    try testing.expect(chances[0] > 0.99);
}

/// Two models, and which is better depends on the task. A context-free bandit
/// cannot express this at all: it sees one average per model.
fn splitWorld(arena: std.mem.Allocator, each: usize) ![]const Episode {
    var out: std.ArrayList(Episode) = .empty;
    var index: usize = 0;
    while (index < each) : (index += 1) {
        const number = try std.fmt.allocPrint(arena, "{d}", .{index});
        // "reader" is good at explaining and poor at changing.
        try out.append(arena, .{
            .task = try std.fmt.allocPrint(arena, "why does {s} fail?", .{number}),
            .connector = "local",
            .model = "reader",
            .reward = 0.9,
        });
        try out.append(arena, .{
            .task = try std.fmt.allocPrint(arena, "fix the bug in {s}", .{number}),
            .connector = "local",
            .model = "reader",
            .reward = 0.1,
        });
        // "writer" is the other way round.
        try out.append(arena, .{
            .task = try std.fmt.allocPrint(arena, "why is {s} slow?", .{number}),
            .connector = "local",
            .model = "writer",
            .reward = 0.1,
        });
        try out.append(arena, .{
            .task = try std.fmt.allocPrint(arena, "write a test for {s}", .{number}),
            .connector = "local",
            .model = "writer",
            .reward = 0.9,
        });
    }
    return out.items;
}

test "it learns which model suits which kind of task, which a bandit cannot" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const episodes = try splitWorld(arena, 25);
    const trained = try train(arena, episodes, .{});

    try testing.expectEqual(@as(usize, 2), trained.policy.arms.len);
    const reader = trained.policy.indexOf("local", "reader").?;
    const writer = trained.policy.indexOf("local", "writer").?;

    // The thing being tested: the recommendation changes with the question.
    try testing.expectEqual(reader, try trained.policy.best(arena, featuresOf("why does the build fail?")));
    try testing.expectEqual(writer, try trained.policy.best(arena, featuresOf("write a test for the parser")));

    // A context-free average cannot express this. Both models score 0.5 over
    // the whole set, so a bandit sees two identical arms.
    var reader_total: f64 = 0;
    var writer_total: f64 = 0;
    var count: f64 = 0;
    for (episodes) |episode| {
        if (std.mem.eql(u8, episode.model, "reader")) reader_total += episode.reward else writer_total += episode.reward;
        count += 1;
    }
    try testing.expectApproxEqAbs(reader_total / (count / 2), writer_total / (count / 2), 0.0001);
}

test "the same log twice gives the same policy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A trainer whose answer depends on the time of day cannot be checked, and
    // "the router changed its mind" would have no explanation.
    const episodes = try splitWorld(arena, 10);
    const once = try train(arena, episodes, .{});
    const twice = try train(arena, episodes, .{});
    try testing.expectEqualSlices(f64, once.policy.weights, twice.policy.weights);
    try testing.expectEqual(once.heldOut, twice.heldOut);
    try testing.expectApproxEqAbs(once.estimate, twice.estimate, 0.0000001);
}

test "nothing is estimated on an episode that moved the weights" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const episodes = try splitWorld(arena, 20);
    const trained = try train(arena, episodes, .{});

    // The split is real: both sides are populated and they add up.
    try testing.expect(trained.trainedOn > 0);
    try testing.expect(trained.heldOut > 0);
    try testing.expectEqual(episodes.len, trained.trainedOn + trained.heldOut);

    // And by a hash of the task, not by position, so the same task always
    // lands on the same side and re-running does not reshuffle the estimate.
    const shuffled = try arena.dupe(Episode, episodes);
    std.mem.reverse(Episode, shuffled);
    const again = try train(arena, shuffled, .{});
    try testing.expectEqual(trained.heldOut, again.heldOut);
}

test "it refuses to be routed with until the evidence supports it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Four runs is not evidence. A router that acts on it is a router that
    // acts on noise, and it would look exactly like one that had learned
    // something.
    const thin = try train(arena, try splitWorld(arena, 1), .{});
    try testing.expect(!thin.worthUsing());
    var out: std.Io.Writer.Allocating = .init(arena);
    try thin.writeReport(&out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Not worth routing with yet") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "too few") != null);

    // One model used for everything: nothing to choose between, whatever the
    // rewards look like.
    const alone = [_]Episode{
        .{ .task = "why does it fail?", .connector = "local", .model = "only", .reward = 0.9 },
        .{ .task = "fix it", .connector = "local", .model = "only", .reward = 0.2 },
    };
    const single = try train(arena, &alone, .{});
    try testing.expect(!single.worthUsing());
    var lonely: std.Io.Writer.Allocating = .init(arena);
    try single.writeReport(&lonely.writer);
    try testing.expect(std.mem.indexOf(u8, lonely.written(), "nothing to choose between") != null);

    // And no runs at all is not an error, it is a report saying so.
    const nothing = try train(arena, &.{}, .{});
    try testing.expect(!nothing.worthUsing());
    try testing.expectEqual(@as(usize, 1), nothing.notes.len);
}

test "the estimate says how few runs it really rests on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Importance sampling can put nearly all its weight on one episode and
    // still report a mean over thirty. Kish's effective sample size is the
    // number that says so, and it is why `worthUsing` checks it rather than
    // only checking how many were held back.
    const trained = try train(arena, try splitWorld(arena, 25), .{});
    try testing.expect(trained.heldOut > 12);
    try testing.expect(trained.effective > 0);
    try testing.expect(trained.effective <= @as(f64, @floatFromInt(trained.heldOut)));
}

test "the weights are readable, which is the point of them being few" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const trained = try train(arena, try splitWorld(arena, 25), .{});
    var out: std.Io.Writer.Allocating = .init(arena);
    try trained.writeReport(&out.writer);
    const report = out.written();

    // Named features, in words, with the arm they belong to. A weight nobody
    // can see is a claim nobody can check.
    try testing.expect(std.mem.indexOf(u8, report, "local/reader") != null);
    try testing.expect(std.mem.indexOf(u8, report, "asks for an explanation") != null);
    try testing.expect(std.mem.indexOf(u8, report, "What it learned") != null);
    // And the estimate is reported against the incumbent, not on its own.
    try testing.expect(std.mem.indexOf(u8, report, "against") != null);
}

test "sampling explores, and taking the best does not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A router that always plays its favourite stops learning about everything
    // else the moment it has an opinion, and its opinion was formed on
    // whatever it happened to see first.
    const policy = try Policy.init(arena, &.{
        .{ .connector = "local", .model = "one" },
        .{ .connector = "local", .model = "two" },
    });
    policy.rowOf(0)[@intFromEnum(Feature.bias)] = 0.4;

    const features = featuresOf("anything at all");
    var chances: [2]f64 = undefined;

    var second: usize = 0;
    var seed: u64 = 0;
    while (seed < 200) : (seed += 1) {
        if (policy.sample(features, &chances, seed) == 1) second += 1;
    }
    // The weaker arm is preferred less and still drawn: about 40% of the time
    // for a gap this size.
    try testing.expect(second > 40);
    try testing.expect(second < 120);
    // Where the best is always the same one.
    try testing.expectEqual(@as(usize, 0), try policy.best(arena, features));
}
