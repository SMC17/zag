//! Agents that start agents, without that being a way to get more authority.
//!
//! One context doing everything is the limit an agent hits first. Reading six
//! files to find one answer spends six files' worth of context on a sentence,
//! and the sentence is all the work needed. Handing that reading to a child
//! and taking back the sentence is the whole idea: the parent pays for the
//! answer, not for the search.
//!
//! ## Why this was withheld until it could be bounded
//!
//! `spawn_agent` existed as a typed request from the beginning and was
//! deliberately not offered to models, on the grounds that a model that can
//! create something to act for it can widen its own reach. That is a real
//! objection and it is what this file answers. Four bounds, each of which has
//! to hold before spawning is safe to offer:
//!
//! - **A child is never wider than its parent.** It runs on the same policy
//!   engine, so every decision it makes is a decision the parent could have
//!   made. A child may be given *less* than its parent has; it cannot be given
//!   more, and there is no argument it can pass that would do so.
//! - **Depth is bounded.** A child that can spawn a child that can spawn is a
//!   fork bomb with a language model in it.
//! - **Fan-out is bounded.** So is the number of children one parent may start
//!   in total, because a bound per turn is not a bound.
//! - **The budget is divided, not copied.** A child spends from what the
//!   parent has left. Copying the parent's budget to each child is how one
//!   task becomes an unbounded bill.
//!
//! ## What comes back
//!
//! The child's answer, not its transcript. That is the point: the parent's
//! context gets a sentence where the child spent fifty thousand tokens
//! producing it. The child's own work is not lost — it is in the record, under
//! the parent, and `zag why` walks from one to the other.

const std = @import("std");
const tools = @import("tools.zig");
const policy_mod = @import("policy.zig");
const capability_mod = @import("capability.zig");
const timeutil = @import("../core/time.zig");

/// How far and how wide a run may spread.
pub const Bounds = struct {
    /// How many levels of agents a run may have, counting the run itself.
    ///
    /// Two is the useful default: a parent that plans and children that do,
    /// with the children unable to spawn in turn. One disables spawning
    /// altogether. Deeper trees are mostly a way to spend a budget without
    /// anyone deciding to.
    maxDepth: usize = 2,
    /// Children one agent may start in one turn.
    maxPerTurn: usize = 4,
    /// Children one agent may start over the whole run. A per-turn bound
    /// without this is not a bound: ten turns of four is forty.
    maxTotal: usize = 12,
    /// The share of what the parent has left that a child may use, of turns
    /// and of tokens alike.
    ///
    /// A child that could spend the parent's whole allowance would leave the
    /// parent unable to do anything with the answer it asked for. Applied to
    /// what remains rather than to the original budget, so four children in a
    /// row get a half, a quarter, an eighth — which is the only version of
    /// this that converges.
    turnShare: f64 = 0.5,
    /// The least a child is worth starting with. Below either of these it
    /// cannot finish anything and the spawn is a waste of a request.
    minTurns: usize = 2,
    minTokens: u64 = 4_000,
};

/// What a parent gets back.
pub const Result = struct {
    /// The child's answer. One sentence to a paragraph, not a transcript.
    answer: []const u8,
    ending: []const u8,
    turns: usize = 0,
    toolCalls: usize = 0,
    inputTokens: u64 = 0,
    outputTokens: u64 = 0,

    pub fn summary(self: Result, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(
            arena,
            "A child agent {s} after {d} turn{s} and {d} tool call{s}.",
            .{
                self.ending,
                self.turns,
                if (self.turns == 1) "" else "s",
                self.toolCalls,
                if (self.toolCalls == 1) "" else "s",
            },
        );
    }
};

/// What a parent has spent on children so far, and how deep it is.
///
/// Passed down rather than held globally, so a test can run a tree without a
/// process-wide counter and two runs in the same process cannot exhaust each
/// other's allowance.
pub const State = struct {
    depth: usize = 0,
    startedThisTurn: usize = 0,
    startedInTotal: usize = 0,
    /// Turns the parent has left, which is what a child's share is taken from.
    parentTurnsLeft: usize = 0,
    /// Tokens the parent has left, for the same reason.
    ///
    /// Turns alone are not a budget. A child with three turns can read three
    /// large files, and the bill for that lands on the same run.
    parentTokensLeft: u64 = 0,

    pub fn newTurn(self: *State) void {
        self.startedThisTurn = 0;
    }
};

pub const Refusal = enum {
    too_deep,
    too_many_this_turn,
    too_many_in_total,
    not_enough_left,

    /// What the model is told, in words it can act on. A refusal that does not
    /// say what to do instead is a refusal the model will make again.
    pub fn text(self: Refusal) []const u8 {
        return switch (self) {
            .too_deep => "A child agent may not start further agents. Do this part of the work yourself.",
            .too_many_this_turn => "That is as many agents as may be started at once. Wait for these to answer before starting more.",
            .too_many_in_total => "This run has started as many agents as it may. Do the rest of the work yourself.",
            .not_enough_left => "There are not enough turns left to give a child anything useful. Finish this yourself.",
        };
    }
};

/// What a child was granted: everything it may spend, and where it sits.
pub const Grant = struct {
    turns: usize,
    tokens: u64,
    depth: usize,
};

/// Whether a spawn is allowed, and what the child would get.
pub const Allowance = union(enum) {
    allowed: Grant,
    refused: Refusal,
};

/// Decide whether one more child may be started, and with what.
pub fn allow(bounds: Bounds, state: State) Allowance {
    // Checked before anything else, because depth is the bound that stops a
    // tree being infinite rather than merely large. The child would run at
    // `depth + 1`, and the deepest level a tree of `maxDepth` levels has is
    // `maxDepth - 1`, so a child one past that is one level too many.
    if (state.depth + 1 >= bounds.maxDepth) return .{ .refused = .too_deep };
    if (state.startedThisTurn >= bounds.maxPerTurn) return .{ .refused = .too_many_this_turn };
    if (state.startedInTotal >= bounds.maxTotal) return .{ .refused = .too_many_in_total };

    const turns_left: f64 = @floatFromInt(state.parentTurnsLeft);
    const turns: usize = @intFromFloat(@floor(turns_left * bounds.turnShare));
    if (turns < bounds.minTurns) return .{ .refused = .not_enough_left };

    const tokens_left: f64 = @floatFromInt(state.parentTokensLeft);
    const tokens: u64 = @intFromFloat(@floor(tokens_left * bounds.turnShare));
    if (tokens < bounds.minTokens) return .{ .refused = .not_enough_left };

    return .{ .allowed = .{
        .turns = turns,
        .tokens = tokens,
        .depth = state.depth + 1,
    } };
}

/// The capabilities a child running beside other children may not use.
///
/// Everything that changes something. Two children reading cannot disagree;
/// two children writing can, and what they touch cannot be read off a request
/// — a child does whatever a model decides, which is the point of it.
///
/// `agent.spawn` is here too. A child that runs beside other children may not
/// start its own: the fan-out already happened, and a second one inside it is
/// how a bounded tree becomes a wide one.
pub const changes_something = [_]capability_mod.Capability{
    .@"fs.write",
    .@"fs.delete",
    .@"process.execute",
    .@"process.signal",
    .@"git.commit",
    .@"git.push",
    .@"container.start",
    .@"remote.execute",
    .@"knowledge.write",
    .@"mcp.invoke",
    .@"network.listen",
    .@"agent.spawn",
};

/// The same policy, narrowed so a child cannot change anything.
///
/// This is what makes children safe to run at the same time. It works by
/// appending a deny rule rather than by rewriting what is there, which matters:
/// the engine resolves deny over ask over allow, so appending a rule can only
/// ever take something away. There is no arrangement of the original rules
/// that this could widen, and that is a property of the engine rather than of
/// this function being careful.
///
/// What is left is reading, searching, reading the repository, and asking a
/// model — which is the whole of what a fan-out is for. A child that needs to
/// run the tests is a child that should be started on its own, where it has
/// its parent's authority and nothing is racing it.
pub fn readOnly(arena: std.mem.Allocator, policy: policy_mod.Policy) !policy_mod.Policy {
    var rules: std.ArrayList(policy_mod.Rule) = .empty;
    try rules.appendSlice(arena, policy.rules);
    try rules.append(arena, .{
        .id = "children-that-run-together-only-read",
        .capabilities = &changes_something,
        .effect = .deny,
        .reason = "Agents started alongside other agents may only read. Start one on its own to change anything.",
    });
    return .{
        .id = try std.fmt.allocPrint(arena, "{s}+reading-only", .{policy.id}),
        .name = policy.name,
        .description = policy.description,
        .rules = rules.items,
        .default_effect = policy.default_effect,
    };
}

/// What runs a child. Supplied by the loop, so the executor can start an agent
/// without the executor knowing what an agent is — which would be a cycle.
pub const Spawner = struct {
    context: *anyopaque,
    spawnFn: *const fn (
        context: *anyopaque,
        request: tools.SpawnAgentRequest,
        grant: Grant,
    ) anyerror!Result,

    pub fn spawn(self: Spawner, request: tools.SpawnAgentRequest, grant: Grant) anyerror!Result {
        return self.spawnFn(self.context, request, grant);
    }
};

const testing = std.testing;
const idmod = @import("../core/id.zig");

fn testContext() policy_mod.Context {
    var ids = idmod.Generator.init(5, 0);
    return .{
        .actor = ids.next(idmod.ActorId),
        .now = .{ .ns = 1_700_000_000 * timeutil.ns_per_s },
    };
}

test "a child may not start children" {
    // The bound that stops a tree being infinite rather than merely large. At
    // the default depth of two, a parent may spawn and its children may not.
    const bounds: Bounds = .{ .maxDepth = 2 };
    const parent: State = .{ .depth = 0, .parentTurnsLeft = 10, .parentTokensLeft = 100_000 };
    const child: State = .{ .depth = 1, .parentTurnsLeft = 10, .parentTokensLeft = 100_000 };

    try testing.expect(allow(bounds, parent) == .allowed);
    try testing.expectEqual(Refusal.too_deep, allow(bounds, child).refused);
}

test "fan-out is bounded per turn and over the run" {
    // A bound per turn is not a bound: ten turns of four is forty children.
    const bounds: Bounds = .{ .maxPerTurn = 2, .maxTotal = 5 };

    var state: State = .{ .parentTurnsLeft = 20, .parentTokensLeft = 100_000 };
    try testing.expect(allow(bounds, state) == .allowed);

    state.startedThisTurn = 2;
    try testing.expectEqual(Refusal.too_many_this_turn, allow(bounds, state).refused);

    // A new turn clears the per-turn count and not the total.
    state.newTurn();
    state.startedInTotal = 5;
    try testing.expectEqual(Refusal.too_many_in_total, allow(bounds, state).refused);
}

test "a child spends from what the parent has left, not a copy of it" {
    // Copying the parent's budget to each child is how one task becomes an
    // unbounded bill: four children at the full allowance is five times the
    // budget anyone agreed to.
    const bounds: Bounds = .{ .turnShare = 0.5, .minTurns = 2 };

    const plenty = allow(bounds, .{ .parentTurnsLeft = 10, .parentTokensLeft = 100_000 }).allowed;
    try testing.expectEqual(@as(usize, 5), plenty.turns);
    try testing.expectEqual(@as(u64, 50_000), plenty.tokens);
    try testing.expectEqual(@as(usize, 1), plenty.depth);

    // And the share falls as the parent spends, so a late spawn is small.
    const late = allow(bounds, .{ .parentTurnsLeft = 6, .parentTokensLeft = 40_000 }).allowed;
    try testing.expectEqual(@as(usize, 3), late.turns);
    try testing.expectEqual(@as(u64, 20_000), late.tokens);
}

test "turns alone are not a budget" {
    // A child with three turns can read three large files, and the bill for
    // that lands on the same run. Refused for the same reason a child with one
    // turn is: it cannot finish, and starting it spends a request to find out.
    const bounds: Bounds = .{ .turnShare = 0.5, .minTurns = 2, .minTokens = 4_000 };
    try testing.expectEqual(
        Refusal.not_enough_left,
        allow(bounds, .{ .parentTurnsLeft = 20, .parentTokensLeft = 6_000 }).refused,
    );
    try testing.expect(allow(bounds, .{ .parentTurnsLeft = 20, .parentTokensLeft = 9_000 }) == .allowed);
}

test "a child too small to finish anything is refused rather than started" {
    // Starting a child with one turn spends a request to be told it ran out.
    const bounds: Bounds = .{ .turnShare = 0.5, .minTurns = 2 };
    try testing.expectEqual(
        Refusal.not_enough_left,
        allow(bounds, .{ .parentTurnsLeft = 3, .parentTokensLeft = 100_000 }).refused,
    );
    try testing.expectEqual(
        Refusal.not_enough_left,
        allow(bounds, .{ .parentTurnsLeft = 0, .parentTokensLeft = 100_000 }).refused,
    );
}

test "every refusal tells the model what to do instead" {
    // A refusal that does not say what to do instead is one the model will
    // make again on the next turn, and the turn after that.
    for (std.enums.values(Refusal)) |refusal| {
        const text = refusal.text();
        try testing.expect(text.len > 20);
        // Each one names an alternative rather than only stating the limit.
        const has_direction = std.mem.indexOf(u8, text, "yourself") != null or
            std.mem.indexOf(u8, text, "Wait") != null;
        try testing.expect(has_direction);
    }
}

test "children that run together may only read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A workspace that allows an agent to change files and run the build.
    const wide: policy_mod.Policy = .{
        .id = "workspace",
        .name = "Work here",
        .description = "Read, write and run the build.",
        .rules = &.{
            .{
                .id = "everything-here",
                .capabilities = &.{ .@"fs.read", .@"fs.write", .@"process.execute", .@"model.infer" },
                .effect = .allow,
                .reason = "This is the work of this workspace.",
            },
        },
    };

    const narrow = try readOnly(arena, wide);
    var wide_engine = policy_mod.Engine.init(arena, wide, 1);
    var narrow_engine = policy_mod.Engine.init(arena, narrow, 2);

    const context = testContext();

    // Reading is untouched, and so is asking a model — a child that could not
    // do either would not be an agent.
    const reading: policy_mod.Request = .{ .capability = .@"fs.read", .resource = .{ .path = "src/main.zig" } };
    try testing.expect((try wide_engine.decide(reading, context)).isAllowed());
    try testing.expect((try narrow_engine.decide(reading, context)).isAllowed());
    const asking: policy_mod.Request = .{ .capability = .@"model.infer", .resource = .none };
    try testing.expect((try narrow_engine.decide(asking, context)).isAllowed());

    // Everything that changes something is gone, though the parent may do it.
    for (changes_something) |capability| {
        const request: policy_mod.Request = .{ .capability = capability, .resource = .{ .path = "src/main.zig" } };
        const decision = try narrow_engine.decide(request, context);
        if (decision.isAllowed()) {
            std.debug.print("{s} survived the narrowing\n", .{@tagName(capability)});
            return error.TestUnexpectedResult;
        }
    }
    const writing: policy_mod.Request = .{ .capability = .@"fs.write", .resource = .{ .path = "src/main.zig" } };
    try testing.expect((try wide_engine.decide(writing, context)).isAllowed());
}

test "narrowing can only take away, whatever the policy said" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The property this rests on is the engine's, not this function's: deny
    // beats ask beats allow, so a rule appended to a policy cannot widen it.
    // Worth asserting against a policy that already denies, where a careless
    // implementation that rewrote rules instead of appending could turn a deny
    // into an allow.
    const strict: policy_mod.Policy = .{
        .id = "strict",
        .name = "Read nothing",
        .description = "Nothing is allowed here.",
        .rules = &.{
            .{
                .id = "no-reading",
                .capabilities = &.{.@"fs.read"},
                .effect = .deny,
                .reason = "Not here.",
            },
        },
    };
    const narrow = try readOnly(arena, strict);
    var engine = policy_mod.Engine.init(arena, narrow, 3);
    const context = testContext();
    const reading: policy_mod.Request = .{ .capability = .@"fs.read", .resource = .{ .path = "a" } };
    try testing.expect(!(try engine.decide(reading, context)).isAllowed());

    // Every original rule is still there, and one was added.
    try testing.expectEqual(strict.rules.len + 1, narrow.rules.len);
    try testing.expectEqualStrings(strict.rules[0].id, narrow.rules[0].id);
    // The narrowed policy is named so that a record does not claim the run
    // happened under the policy the file describes.
    try testing.expect(!std.mem.eql(u8, strict.id, narrow.id));
}

test "a child that runs beside other children may not start children" {
    // The fan-out already happened. A second one inside it is how a bounded
    // tree becomes a wide one, and no depth bound stops it — each child is
    // within its depth.
    var found = false;
    for (changes_something) |capability| {
        if (capability == .@"agent.spawn") found = true;
    }
    try testing.expect(found);
}

test "what comes back is an answer, not a transcript" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The point of the whole thing: the parent's context gets a sentence where
    // the child spent a great deal producing it.
    const result: Result = .{
        .answer = "The failure is a missing semicolon on line five of src/main.zig.",
        .ending = "answered",
        .turns = 9,
        .toolCalls = 14,
        .inputTokens = 48_000,
        .outputTokens = 2_100,
    };
    const line = try result.summary(arena);
    try testing.expect(std.mem.indexOf(u8, line, "9 turns") != null);
    try testing.expect(std.mem.indexOf(u8, line, "14 tool calls") != null);
    // The answer is short and the work behind it was not.
    try testing.expect(result.answer.len < 100);
    try testing.expect(result.inputTokens > 40_000);
}
