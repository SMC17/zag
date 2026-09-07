//! The attention loop: ask, act under a decision, ask again.
//!
//! A model on its own produces text. What makes it an agent is this cycle: it
//! is asked, it asks for tools, the tools run, and it is asked again with what
//! they produced. Everything else in this repository exists to make each turn
//! of that cycle safe and legible, and this file is where they meet.
//!
//! One turn:
//!
//! ```
//! ask the model  ->  tool calls  ->  typed request  ->  policy decision
//!                ->  executor spends the decision  ->  result
//!                ->  back into the conversation  ->  ask again
//! ```
//!
//! Nothing here decides anything. It has no allowlist of its own and no opinion
//! about what a model should be allowed to do. It carries requests to the
//! policy engine and results back, and it stops.
//!
//! ## Why it stops
//!
//! A loop that only stops when a model says it is finished is a loop that does
//! not stop. Four bounds are checked every turn, and each one is a different
//! failure worth telling apart:
//!
//!   * **Turns.** A plain count. It catches the ordinary case of a model that
//!     will keep going.
//!   * **Tokens.** What the run costs. A model that reads a large file each
//!     turn hits this long before the turn count.
//!   * **Wall clock.** What the person waited. Measured on the monotonic clock,
//!     so a change to the system time cannot extend or cut short a run.
//!   * **Repetition.** The one that matters most in practice. A model that has
//!     been refused often retries the same call forever, and each retry is
//!     cheap enough that the other three bounds take a long time to notice. The
//!     loop hashes each request and stops when the same one comes back too many
//!     times, because the answer will not be different.
//!
//! ## What is written down
//!
//! Each turn produces a `Turn`, and the run produces a `Transcript`. Both are
//! complete on a refusal as well as on success: a run that was stopped by the
//! policy on its first tool call still has the decision that stopped it, and
//! that is the interesting record, not the empty answer.
//!
//! ## What is not here
//!
//! Approvals. When a policy says a person decides, the loop stops and says so,
//! carrying the request and the decision out to whoever asked. It does not
//! prompt, because the thing that prompts is a user interface and this is not
//! one. A caller that has a person available resumes by granting and calling
//! again.

const std = @import("std");
const provider = @import("provider.zig");
const catalog = @import("catalog.zig");
const transport_mod = @import("transport.zig");
const toolschema = @import("toolschema.zig");
const executor_mod = @import("executor.zig");
const policy_mod = @import("policy.zig");
const tools = @import("tools.zig");
const capability_mod = @import("capability.zig");
const hashing = @import("../core/hash.zig");
const timeutil = @import("../core/time.zig");
const notation = @import("../reports/notation.zig");

pub const Decision = policy_mod.Decision;
pub const ToolRequest = tools.ToolRequest;
pub const ToolResult = tools.ToolResult;

/// Why a run ended.
///
/// Every one of these is an ordinary outcome that a person may need to act on,
/// which is why they are an enumeration and not an error set. Only a run that
/// could not be attempted at all is an error.
pub const Ending = enum {
    /// The model finished its turn with an answer.
    answered,
    /// The model declined.
    refused_by_model,
    /// A person has to allow something before the run can go on.
    waiting_for_a_person,
    /// The policy refused, and no person was going to be asked.
    stopped_by_policy,
    /// The turn budget ran out.
    out_of_turns,
    /// The token budget ran out.
    out_of_tokens,
    /// The time budget ran out.
    out_of_time,
    /// The model asked for the same thing over and over.
    going_in_circles,
    /// The provider could not be reached, or would not answer.
    provider_unavailable,

    /// Whether the run produced the answer it was asked for.
    pub fn succeeded(self: Ending) bool {
        return self == .answered;
    }

    /// What a person is told, in words that say what to do next where there is
    /// something to do.
    pub fn text(self: Ending) []const u8 {
        return switch (self) {
            .answered => "The model finished.",
            .refused_by_model => "The model declined to answer.",
            .waiting_for_a_person => "This is waiting for you to allow something.",
            .stopped_by_policy => "The policy refused something the model needed, so the run stopped.",
            .out_of_turns => "The run reached its limit on turns before it finished.",
            .out_of_tokens => "The run reached its limit on tokens before it finished.",
            .out_of_time => "The run reached its time limit before it finished.",
            .going_in_circles => "The model kept asking for the same thing, so the run stopped.",
            .provider_unavailable => "The provider could not be reached.",
        };
    }
};

/// One tool call, from what the model asked for to what happened.
pub const Step = struct {
    /// The identifier the model gave the call, needed to pair the result back.
    callId: []const u8,
    /// The name the model used, whether or not it was a real tool.
    toolName: []const u8,
    /// The typed request, when the call became one.
    request: ?ToolRequest = null,
    /// The decision, when one was reached.
    decision: ?Decision = null,
    /// What happened, when anything did.
    result: ?ToolResult = null,
    /// What is put back into the conversation for the model to read.
    reply: []const u8,
    /// True when the reply says no rather than reporting an outcome.
    refused: bool = false,
    /// True only when the executor was actually called.
    ///
    /// A refusal carries a result too — the model needs to be told what
    /// happened — but that result was written here, not by anything running.
    /// The two must not be confused: "was refused" and "ran and failed" look
    /// alike in a summary and are opposites in an audit.
    executed: bool = false,

    pub fn ran(self: Step) bool {
        return self.executed;
    }
};

/// One turn: one question to the model, and everything done with its answer.
pub const Turn = struct {
    number: usize,
    /// The record of the model request itself, decisions included.
    attempt: transport_mod.Attempt,
    /// What the model said, when it said anything.
    text: []const u8 = "",
    steps: []const Step = &.{},
    usage: provider.Usage = .{},
};

/// The whole run.
pub const Transcript = struct {
    ending: Ending,
    turns: []const Turn,
    /// The model's last text, which is the answer when there is one.
    answer: []const u8 = "",
    /// Everything the run spent, added up across turns.
    usage: provider.Usage = .{},
    /// How long the run took, on the monotonic clock.
    elapsed: timeutil.Duration = .{ .ns = 0 },
    /// Set when the run stopped for a person to decide. This is the request
    /// they are being asked about.
    pending: ?ToolRequest = null,
    /// The decision that asked for them.
    pendingDecision: ?Decision = null,

    pub fn toolCallCount(self: Transcript) usize {
        var total: usize = 0;
        for (self.turns) |turn| total += turn.steps.len;
        return total;
    }

    pub fn ranAnything(self: Transcript) bool {
        for (self.turns) |turn| {
            for (turn.steps) |step| {
                if (step.ran()) return true;
            }
        }
        return false;
    }

    /// One paragraph a person can read instead of the transcript.
    pub fn writeSummary(self: Transcript, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}\n", .{self.ending.text()});
        try w.print("{d} turn", .{self.turns.len});
        if (self.turns.len != 1) try w.writeAll("s");
        try w.print(", {d} tool call", .{self.toolCallCount()});
        if (self.toolCallCount() != 1) try w.writeAll("s");
        var refused: usize = 0;
        for (self.turns) |turn| {
            for (turn.steps) |step| {
                if (step.refused) refused += 1;
            }
        }
        if (refused > 0) {
            try w.print(", {d} of them refused", .{refused});
        }
        try w.print(", {d} tokens in and {d} out", .{
            self.usage.inputTokens,
            self.usage.outputTokens,
        });
        try w.writeAll(", and took ");
        try notation.writeDuration(w, self.elapsed);
        try w.writeAll(".\n");
    }
};

/// The bounds a run is held to.
///
/// The defaults are deliberately modest. A run that needs more than this is a
/// run whose author should say so, because the cost lands on somebody.
pub const Budget = struct {
    /// How many times the model may be asked.
    turns: usize = 12,
    /// Tokens across the whole run, input and output together.
    tokens: u64 = 400_000,
    /// Wall clock for the whole run.
    time: timeutil.Duration = .{ .ns = 300 * timeutil.ns_per_s },
    /// How many times the same request may be asked for before the run is
    /// treated as stuck. Two is a retry; more than that is a loop.
    repeats: usize = 3,
    /// Tool calls the model may make in one turn. A model that asks for
    /// hundreds at once is not being helped by having them all run.
    callsPerTurn: usize = 16,
};

pub const Error = error{
    /// The run could not be started: no connector, or no way to send.
    CannotStart,
} || std.mem.Allocator.Error;

pub const Options = struct {
    connector: catalog.Connector,
    model: []const u8,
    /// The instructions the model runs under. This is prompt text: it shapes
    /// behaviour and grants nothing.
    system: []const u8 = "",
    budget: Budget = .{},
    /// Ask for the model's reasoning where the provider offers it.
    showThinking: bool = false,
    effort: ?provider.Effort = null,
    maxOutputTokens: u32 = 16000,
};

/// A monotonic clock, passed in so a run can be timed in a test without one.
pub const Clock = struct {
    context: *anyopaque,
    nowFn: *const fn (context: *anyopaque) i64,

    pub fn now(self: Clock) i64 {
        return self.nowFn(self.context);
    }
};

/// A clock that never advances. A run under this one is bounded by turns,
/// tokens and repetition, and its elapsed time is zero.
pub const stopped_clock: Clock = .{
    .context = undefined,
    .nowFn = struct {
        fn now(_: *anyopaque) i64 {
            return 0;
        }
    }.now,
};

/// Something that happened, offered to whoever is keeping the record.
///
/// The loop reports each of these as it reaches it, rather than handing over a
/// transcript at the end. A run that is interrupted has still written what it
/// did up to that point, and each moment is recorded at the time it happened
/// rather than all of them at the time the run stopped.
pub const Moment = union(enum) {
    started: struct {
        request: []const u8,
        provider: []const u8,
        model: []const u8,
        policy: []const u8,
    },
    /// The model said something.
    said: struct {
        role: enum { plan, progress, result, question, refusal },
        text: []const u8,
    },
    /// A tool call became a typed request and a decision was reached.
    asked: struct {
        tool: []const u8,
        capability: []const u8,
        resource: []const u8,
        argumentsJson: []const u8,
        decision: ?Decision,
    },
    /// The call is over, whether it ran or was refused.
    settled: struct {
        tool: []const u8,
        outcome: tools.Outcome,
        summary: []const u8,
        resultHash: hashing.Hash,
    },
    finished: struct { ending: Ending },
};

/// Where the record of a run goes.
///
/// Passed in rather than reached for, so the loop has no opinion about where a
/// workspace lives and a test can run the whole thing without one. A run with
/// no journal writes nothing, which is what the tests here do and what nothing
/// a person invokes should do: `zag ask` used to talk to a provider, run tools
/// and print to standard output without a single event, so the only model path
/// in a product built around an event log did not enter it.
pub const Journal = struct {
    context: *anyopaque,
    recordFn: *const fn (context: *anyopaque, moment: Moment) anyerror!void,

    pub fn record(self: Journal, moment: Moment) void {
        // A record that could not be written must not stop the work, and must
        // not be silently equivalent to one that was. The caller owns the
        // journal and is the one that can tell a person; here the run carries
        // on, because losing a tool result to a full disk is worse than losing
        // a line of the log.
        self.recordFn(self.context, moment) catch {};
    }
};

pub const Runner = struct {
    arena: std.mem.Allocator,
    transport: transport_mod.Transport,
    executor: executor_mod.Runner,
    engine: *policy_mod.Engine,
    clock: Clock = stopped_clock,
    /// Where this run is written down. None means nothing is written.
    journal: ?Journal = null,

    fn note(self: Runner, moment: Moment) void {
        if (self.journal) |journal| journal.record(moment);
    }

    /// Run the loop until it ends, for one reason or another.
    pub fn run(
        self: Runner,
        options: Options,
        question: []const u8,
        context: policy_mod.Context,
    ) Error!Transcript {
        const started = self.clock.now();

        self.note(.{ .started = .{
            .request = question,
            .provider = options.connector.id,
            .model = options.model,
            .policy = self.engine.policy.id,
        } });

        var messages: std.ArrayList(provider.Message) = .empty;
        try messages.append(self.arena, .{
            .role = .user,
            .blocks = try self.arena.dupe(provider.Block, &.{.{ .text = question }}),
        });

        var turns: std.ArrayList(Turn) = .empty;
        var usage: provider.Usage = .{};
        var seen: std.ArrayList(Repeat) = .empty;
        const declared = toolschema.declarations(self.arena) catch return error.OutOfMemory;

        var ending: Ending = .out_of_turns;
        var answer: []const u8 = "";
        var pending: ?ToolRequest = null;
        var pending_decision: ?Decision = null;

        var number: usize = 1;
        while (number <= options.budget.turns) : (number += 1) {
            var attempt: transport_mod.Attempt = undefined;
            const completion = self.transport.send(options.connector, .{
                .model = options.model,
                .system = options.system,
                .messages = messages.items,
                .tools = declared,
                .maxOutputTokens = options.maxOutputTokens,
                .effort = options.effort,
                .showThinking = options.showThinking,
            }, context, &attempt) catch |err| {
                try turns.append(self.arena, .{ .number = number, .attempt = attempt });
                ending = switch (err) {
                    error.NeedsApproval => .waiting_for_a_person,
                    error.NotPermitted, error.CredentialMissing => .stopped_by_policy,
                    error.ProviderRejected, error.SendFailed => .provider_unavailable,
                    error.OutOfMemory => return error.OutOfMemory,
                };
                break;
            };

            usage.inputTokens += completion.usage.inputTokens;
            usage.outputTokens += completion.usage.outputTokens;
            usage.cacheReadTokens += completion.usage.cacheReadTokens;
            usage.cacheWriteTokens += completion.usage.cacheWriteTokens;

            const said = try completion.text(self.arena);
            if (said.len > 0) {
                answer = said;
                self.note(.{ .said = .{
                    .role = if (completion.stopReason == .refusal) .refusal else .progress,
                    .text = said,
                } });
            }

            // The model's own turn goes into the conversation exactly as it
            // came, so that a tool result has a call to belong to.
            try messages.append(self.arena, .{
                .role = .assistant,
                .blocks = completion.blocks,
            });

            const calls = try completion.toolCalls(self.arena);
            if (calls.len == 0) {
                try turns.append(self.arena, .{
                    .number = number,
                    .attempt = attempt,
                    .text = said,
                    .usage = completion.usage,
                });
                ending = switch (completion.stopReason) {
                    .refusal => .refused_by_model,
                    else => .answered,
                };
                break;
            }

            var steps: std.ArrayList(Step) = .empty;
            var results: std.ArrayList(provider.Block) = .empty;
            var stop: ?Ending = null;

            for (calls, 0..) |call, index| {
                if (index >= options.budget.callsPerTurn) break;

                const step = try self.performOne(call, context, &seen, options.budget.repeats);
                try steps.append(self.arena, step);
                self.recordStep(step);
                try results.append(self.arena, .{ .tool_result = .{
                    .toolUseId = call.id,
                    .content = step.reply,
                    .isError = step.refused or (step.result != null and !step.result.?.succeeded()),
                } });

                if (step.decision) |decision| {
                    if (decision.effect == .require_human) {
                        stop = .waiting_for_a_person;
                        pending = step.request;
                        pending_decision = decision;
                    }
                }
                if (self.repeatedTooOften(seen.items, options.budget.repeats)) {
                    stop = .going_in_circles;
                }
            }

            try turns.append(self.arena, .{
                .number = number,
                .attempt = attempt,
                .text = said,
                .steps = steps.items,
                .usage = completion.usage,
            });

            if (stop) |reason| {
                ending = reason;
                break;
            }

            // The results go back as one user turn, which is the shape every
            // provider expects.
            try messages.append(self.arena, .{ .role = .user, .blocks = results.items });

            if (usage.total() >= options.budget.tokens) {
                ending = .out_of_tokens;
                break;
            }
            const spent = self.clock.now() - started;
            if (spent >= options.budget.time.ns and options.budget.time.ns > 0 and spent > 0) {
                ending = .out_of_time;
                break;
            }
        }

        self.note(.{ .finished = .{ .ending = ending } });

        return .{
            .ending = ending,
            .turns = turns.items,
            .answer = answer,
            .usage = usage,
            .elapsed = .{ .ns = self.clock.now() - started },
            .pending = pending,
            .pendingDecision = pending_decision,
        };
    }

    /// Write down one call, whether or not it ran.
    ///
    /// Both halves are recorded. A refused call is the interesting one: the
    /// record has to show what was asked for and what the policy said, or a
    /// person reading it later cannot tell a refusal from a call that was never
    /// made.
    fn recordStep(self: Runner, step: Step) void {
        const request = step.request orelse {
            // The name was not a tool. Nothing was decided and nothing ran, and
            // saying so is more useful than silence.
            self.note(.{ .settled = .{
                .tool = step.toolName,
                .outcome = .denied,
                .summary = step.reply,
                .resultHash = hashing.Hash.zero,
            } });
            return;
        };
        const resource = request.resource(self.arena) catch capability_mod.Resource{ .none = {} };
        self.note(.{ .asked = .{
            .tool = step.toolName,
            .capability = request.capability().text(),
            .resource = resource.text(),
            .argumentsJson = "",
            .decision = step.decision,
        } });
        const result = step.result orelse return;
        self.note(.{ .settled = .{
            .tool = step.toolName,
            .outcome = result.outcome,
            .summary = if (result.summary.len > 0) result.summary else step.reply,
            .resultHash = result.contentHash,
        } });
    }

    /// One tool call, all the way through.
    fn performOne(
        self: Runner,
        call: provider.ToolUse,
        context: policy_mod.Context,
        seen: *std.ArrayList(Repeat),
        repeat_limit: usize,
    ) Error!Step {
        var step: Step = .{
            .callId = call.id,
            .toolName = call.name,
            .reply = "",
        };

        // 1. Does the call become a typed request at all? Nothing is decided
        //    until it does, because a decision needs a resource to be about.
        const request = toolschema.parse(self.arena, call.name, call.argumentsJson) catch |err| {
            step.refused = true;
            step.reply = toolschema.refusalText(err);
            return step;
        };
        step.request = request;

        // 2. Has this exact request already been asked for, over and over? A
        //    repeated call is counted before it is decided, so a model cannot
        //    spend the policy engine's time on the same refusal.
        const fingerprint = try fingerprintOf(self.arena, request);
        const count = try noteRepeat(self.arena, seen, fingerprint);
        if (count > repeat_limit) {
            step.refused = true;
            step.reply = "You have asked for this several times and the answer has not changed. Try something else, or say what you need from the person.";
            return step;
        }

        // 3. The policy decides. The resource comes from the request, through
        //    the executor, not from anything the model wrote.
        var engine = self.engine;
        // The resource comes from the request, through the one definition the
        // executor will re-derive it from. Deciding on anything else would make
        // a decision the executor then refuses to honour.
        const resource = request.resource(self.arena) catch return error.OutOfMemory;
        const decision = engine.decide(.{
            .capability = request.capability(),
            .resource = resource,
        }, context) catch return error.OutOfMemory;
        step.decision = decision;

        if (decision.effect == .require_human) {
            step.refused = true;
            step.reply = "This needs the person to allow it. The run has stopped and they are being asked.";
            return step;
        }
        if (!decision.isAllowed()) {
            step.refused = true;
            step.result = .{ .outcome = .denied, .summary = decision.reason };
            step.reply = try toolschema.resultText(self.arena, step.result.?);
            return step;
        }

        // 4. A second capability, when the request needs one. An execute that
        //    wants the network asks for the network too, and either answer can
        //    stop it.
        if (request.additionalCapability()) |extra| {
            const also = engine.decide(.{
                .capability = extra,
                .resource = resource,
            }, context) catch return error.OutOfMemory;
            if (!also.isAllowed()) {
                step.decision = also;
                step.refused = true;
                step.result = .{ .outcome = .denied, .summary = also.reason };
                step.reply = try toolschema.resultText(self.arena, step.result.?);
                return step;
            }
        }

        // 5. The executor spends the decision. It checks the match again, on
        //    its own terms, because this loop is not what makes that safe.
        step.executed = true;
        const result = self.executor.run(decision, request) catch |err| {
            step.result = .{ .outcome = .failed, .summary = executor_mod.refusalText(err) };
            step.reply = try toolschema.resultText(self.arena, step.result.?);
            return step;
        };
        step.result = result;
        step.reply = try toolschema.resultText(self.arena, result);
        return step;
    }

    fn repeatedTooOften(self: Runner, seen: []const Repeat, limit: usize) bool {
        _ = self;
        for (seen) |entry| {
            if (entry.count > limit) return true;
        }
        return false;
    }
};

const Repeat = struct {
    fingerprint: hashing.Hash,
    count: usize,
};

fn noteRepeat(
    arena: std.mem.Allocator,
    seen: *std.ArrayList(Repeat),
    fingerprint: hashing.Hash,
) !usize {
    for (seen.items) |*entry| {
        if (entry.fingerprint.eql(fingerprint)) {
            entry.count += 1;
            return entry.count;
        }
    }
    try seen.append(arena, .{ .fingerprint = fingerprint, .count = 1 });
    return 1;
}

/// What makes two tool calls the same call.
///
/// The kind and the resource, and nothing else. Two reads of one file are the
/// same request even if the model asked for a different byte limit, because the
/// answer that matters — allowed or refused — will be identical. Counting them
/// as different would let a model defeat the repetition bound by varying a
/// field nobody decides on.
pub fn fingerprintOf(arena: std.mem.Allocator, request: ToolRequest) !hashing.Hash {
    const resource = try request.resource(arena);
    var extra: []const u8 = "";
    switch (request) {
        .execute => |e| extra = try e.commandText(arena),
        .git => |g| extra = @tagName(g.operation),
        .mcp => |m| extra = m.tool,
        .search => |s| extra = s.query,
        else => {},
    }
    return hashing.Hash.ofParts(&.{
        @tagName(request),
        resource.kindName(),
        resource.text(),
        extra,
    });
}

const testing = std.testing;
const idmod = @import("../core/id.zig");
const content_store = @import("../events/content_store.zig");

/// A clock a test drives by hand.
const TestClock = struct {
    ns: i64 = 0,

    fn clock(self: *TestClock) Clock {
        return .{ .context = self, .nowFn = read };
    }

    fn read(context: *anyopaque) i64 {
        const self: *TestClock = @ptrCast(@alignCast(context));
        // Every reading moves a second on, which is enough for a test to reach
        // a time bound without sleeping.
        self.ns += timeutil.ns_per_s;
        return self.ns;
    }
};

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    engine: policy_mod.Engine,
    recorded: transport_mod.Recorded,
    root: []const u8,
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,

    fn init(rules: []const policy_mod.Rule, responses: []const transport_mod.Response) !*Fixture {
        const self = try testing.allocator.create(Fixture);
        self.* = .{
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .engine = undefined,
            .recorded = undefined,
            .root = undefined,
            .tmp = std.testing.tmpDir(.{}),
            .threaded = .init(testing.allocator, .{}),
        };
        const scratch = self.arena_state.allocator();
        self.engine = policy_mod.Engine.init(scratch, .{
            .id = "test",
            .name = "Test policy",
            .description = "Whatever the test needs.",
            .rules = rules,
        }, 7);
        self.recorded = .{ .responses = responses, .arena = scratch };
        self.root = try std.fmt.allocPrint(scratch, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.threaded.deinit();
        self.arena_state.deinit();
        testing.allocator.destroy(self);
    }

    /// Put a file in the workspace for the model to find.
    fn place(self: *Fixture, name: []const u8, data: []const u8) !void {
        const path = try std.fmt.allocPrint(self.arena(), "{s}/{s}", .{ self.root, name });
        try std.Io.Dir.cwd().writeFile(self.threaded.io(), .{ .sub_path = path, .data = data });
    }

    fn arena(self: *Fixture) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn runner(self: *Fixture, clock: Clock) Runner {
        return .{
            .arena = self.arena(),
            .transport = .{
                .arena = self.arena(),
                .engine = &self.engine,
                .sender = self.recorded.sender(),
            },
            .executor = executor_mod.Runner.init(self.arena(), .{ .root = self.root }),
            .engine = &self.engine,
            .clock = clock,
        };
    }

    fn context(_: *Fixture) policy_mod.Context {
        var ids = idmod.Generator.init(11, 0);
        return .{
            .actor = ids.next(idmod.ActorId),
            .session = ids.next(idmod.SessionId),
            .agent = ids.next(idmod.AgentId),
            .now = .{ .ns = 1_700_000_000 * timeutil.ns_per_s },
        };
    }

    fn options(self: *Fixture) Options {
        _ = self;
        return .{
            .connector = catalog.find("ollama").?,
            .model = "test-model",
            .system = "Do the work.",
        };
    }
};

fn callResponse(arena: std.mem.Allocator, name: []const u8, arguments: []const u8) !transport_mod.Response {
    const body = try std.fmt.allocPrint(arena,
        \\{{"model":"test-model","message":{{"role":"assistant","content":"",
        \\ "tool_calls":[{{"function":{{"name":"{s}","arguments":{s}}}}}]}},
        \\ "done":true,"done_reason":"stop","prompt_eval_count":10,"eval_count":5}}
    , .{ name, arguments });
    return .{ .status = 200, .body = body };
}

fn textResponse(arena: std.mem.Allocator, text: []const u8) !transport_mod.Response {
    const body = try std.fmt.allocPrint(arena,
        \\{{"model":"test-model","message":{{"role":"assistant","content":"{s}"}},
        \\ "done":true,"done_reason":"stop","prompt_eval_count":8,"eval_count":4}}
    , .{text});
    return .{ .status = 200, .body = body };
}

const allow_models_and_reading = [_]policy_mod.Rule{
    .{
        .id = "models",
        .capabilities = &.{ .@"model.infer", .@"network.connect" },
        .effect = .allow,
        .reason = "Models are allowed here.",
    },
    .{
        .id = "reading",
        .capabilities = &.{.@"fs.read"},
        .effect = .allow,
        .reason = "Reading the workspace is allowed.",
    },
};

test "the loop asks, runs a tool under a decision, and asks again with the result" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const fixture = try Fixture.init(&allow_models_and_reading, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();

    // A file for the model to read, inside the workspace.
    try fixture.place("notes.txt", "twelve bytes");

    fixture.recorded.responses = try arena.dupe(transport_mod.Response, &.{
        try callResponse(arena, "read_file",
            \\{"path":"notes.txt"}
        ),
        try textResponse(arena, "The file says twelve bytes."),
    });

    const transcript = try fixture.runner(stopped_clock).run(
        fixture.options(),
        "What is in notes.txt?",
        fixture.context(),
    );

    try testing.expectEqual(Ending.answered, transcript.ending);
    try testing.expectEqual(@as(usize, 2), transcript.turns.len);
    try testing.expectEqual(@as(usize, 1), transcript.toolCallCount());
    try testing.expect(transcript.ranAnything());

    const step = transcript.turns[0].steps[0];
    try testing.expectEqualStrings("read_file", step.toolName);
    try testing.expect(step.request.? == .read_file);
    try testing.expect(step.decision.?.isAllowed());
    try testing.expectEqual(tools.Outcome.completed, step.result.?.outcome);
    try testing.expect(std.mem.indexOf(u8, step.reply, "12 bytes") != null);

    try testing.expectEqualStrings("The file says twelve bytes.", transcript.answer);
    // Both turns' tokens are added up, not just the last.
    try testing.expectEqual(@as(u64, 18), transcript.usage.inputTokens);
}

test "a refused tool call is reported to the model, and nothing runs" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    // Reading is allowed; writing was never mentioned, so it is refused.
    const fixture = try Fixture.init(&allow_models_and_reading, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();

    fixture.recorded.responses = try arena.dupe(transport_mod.Response, &.{
        try callResponse(arena, "delete",
            \\{"path":"notes.txt"}
        ),
        try textResponse(arena, "I could not delete it."),
    });

    const transcript = try fixture.runner(stopped_clock).run(
        fixture.options(),
        "Delete notes.txt",
        fixture.context(),
    );

    try testing.expectEqual(Ending.answered, transcript.ending);
    const step = transcript.turns[0].steps[0];
    try testing.expect(step.refused);
    try testing.expect(!step.decision.?.isAllowed());
    try testing.expectEqual(tools.Outcome.denied, step.result.?.outcome);
    // The model is told not to retry, which is the difference between a refusal
    // and a failure.
    try testing.expect(std.mem.indexOf(u8, step.reply, "Do not try it again") != null);
    // Nothing was executed: the run has a step but never a completed one.
    try testing.expect(!transcript.ranAnything());
}

test "a tool a model invented never becomes a request" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const fixture = try Fixture.init(&allow_models_and_reading, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();

    fixture.recorded.responses = try arena.dupe(transport_mod.Response, &.{
        try callResponse(arena, "run_arbitrary_shell",
            \\{"command":"rm -rf /"}
        ),
        try textResponse(arena, "That tool does not exist."),
    });

    const transcript = try fixture.runner(stopped_clock).run(
        fixture.options(),
        "Clean up",
        fixture.context(),
    );

    const step = transcript.turns[0].steps[0];
    try testing.expect(step.refused);
    // No request, so no decision was ever asked for. A name that is not a tool
    // does not reach the policy engine at all.
    try testing.expect(step.request == null);
    try testing.expect(step.decision == null);
    try testing.expect(step.result == null);
}

test "a model that asks for the same refused thing is stopped rather than humoured" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const fixture = try Fixture.init(&allow_models_and_reading, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();

    var responses: std.ArrayList(transport_mod.Response) = .empty;
    var index: usize = 0;
    while (index < 10) : (index += 1) {
        try responses.append(arena, try callResponse(arena, "delete",
            \\{"path":"notes.txt"}
        ));
    }
    fixture.recorded.responses = responses.items;

    const transcript = try fixture.runner(stopped_clock).run(
        fixture.options(),
        "Delete notes.txt, really",
        fixture.context(),
    );

    try testing.expectEqual(Ending.going_in_circles, transcript.ending);
    // It stopped well before the turn budget, which is the point: the loop
    // noticed rather than grinding through twelve identical refusals.
    try testing.expect(transcript.turns.len < 12);
}

test "a byte limit does not make a repeated read look like a new one" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    // The same file, asked for with a different limit each time. A fingerprint
    // that included the limit would let a model loop for ever by counting up.
    const first = try fingerprintOf(arena, .{ .read_file = .{ .path = "a.txt", .maxBytes = 100 } });
    const second = try fingerprintOf(arena, .{ .read_file = .{ .path = "a.txt", .maxBytes = 101 } });
    try testing.expect(first.eql(second));

    const other = try fingerprintOf(arena, .{ .read_file = .{ .path = "b.txt" } });
    try testing.expect(!first.eql(other));

    // Two different commands are different, and the same command is the same.
    const build = try fingerprintOf(arena, .{ .execute = .{
        .argv = &.{ "zig", "build" },
        .workingDirectory = "/repo",
    } });
    const test_run = try fingerprintOf(arena, .{ .execute = .{
        .argv = &.{ "zig", "build", "test" },
        .workingDirectory = "/repo",
    } });
    try testing.expect(!build.eql(test_run));
}

test "the turn budget ends a model that will not stop" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const fixture = try Fixture.init(&allow_models_and_reading, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();
    try fixture.place("notes.txt", "x");

    // Each turn asks to read a different file, so repetition never triggers and
    // only the turn count can stop it.
    var responses: std.ArrayList(transport_mod.Response) = .empty;
    var index: usize = 0;
    while (index < 20) : (index += 1) {
        const arguments = try std.fmt.allocPrint(arena, "{{\"path\":\"file-{d}.txt\"}}", .{index});
        try responses.append(arena, try callResponse(arena, "read_file", arguments));
    }
    fixture.recorded.responses = responses.items;

    var options = fixture.options();
    options.budget.turns = 4;

    const transcript = try fixture.runner(stopped_clock).run(
        options,
        "Read everything",
        fixture.context(),
    );
    try testing.expectEqual(Ending.out_of_turns, transcript.ending);
    try testing.expectEqual(@as(usize, 4), transcript.turns.len);
}

test "the time budget ends a run that takes too long" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const fixture = try Fixture.init(&allow_models_and_reading, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();
    try fixture.place("notes.txt", "x");

    var responses: std.ArrayList(transport_mod.Response) = .empty;
    var index: usize = 0;
    while (index < 20) : (index += 1) {
        const arguments = try std.fmt.allocPrint(arena, "{{\"path\":\"file-{d}.txt\"}}", .{index});
        try responses.append(arena, try callResponse(arena, "read_file", arguments));
    }
    fixture.recorded.responses = responses.items;

    var options = fixture.options();
    options.budget.time = .{ .ns = 3 * timeutil.ns_per_s };

    var clock: TestClock = .{};
    const transcript = try fixture.runner(clock.clock()).run(
        options,
        "Take your time",
        fixture.context(),
    );
    try testing.expectEqual(Ending.out_of_time, transcript.ending);
    try testing.expect(transcript.elapsed.ns > 0);
}

test "the token budget ends a run that costs too much" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const fixture = try Fixture.init(&allow_models_and_reading, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();
    try fixture.place("notes.txt", "x");

    var responses: std.ArrayList(transport_mod.Response) = .empty;
    var index: usize = 0;
    while (index < 20) : (index += 1) {
        const arguments = try std.fmt.allocPrint(arena, "{{\"path\":\"file-{d}.txt\"}}", .{index});
        try responses.append(arena, try callResponse(arena, "read_file", arguments));
    }
    fixture.recorded.responses = responses.items;

    var options = fixture.options();
    // Each turn is worth 15 tokens in this fixture, so this lands on the third.
    options.budget.tokens = 40;

    const transcript = try fixture.runner(stopped_clock).run(
        options,
        "Read a lot",
        fixture.context(),
    );
    try testing.expectEqual(Ending.out_of_tokens, transcript.ending);
    try testing.expect(transcript.usage.total() >= 40);
}

test "a run stops for a person rather than deciding on their behalf" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const rules = [_]policy_mod.Rule{
        .{
            .id = "models",
            .capabilities = &.{ .@"model.infer", .@"network.connect" },
            .effect = .allow,
            .reason = "Models are allowed here.",
        },
        .{
            .id = "deleting-asks",
            .capabilities = &.{.@"fs.delete"},
            .effect = .require_human,
            .reason = "Deleting a file cannot be undone, so a person decides.",
        },
    };
    const fixture = try Fixture.init(&rules, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();

    fixture.recorded.responses = try arena.dupe(transport_mod.Response, &.{
        try callResponse(arena, "delete",
            \\{"path":"notes.txt"}
        ),
    });

    const transcript = try fixture.runner(stopped_clock).run(
        fixture.options(),
        "Delete notes.txt",
        fixture.context(),
    );

    try testing.expectEqual(Ending.waiting_for_a_person, transcript.ending);
    // The request and the decision come out, so a caller with a person to ask
    // has everything it needs to ask them.
    try testing.expect(transcript.pending.? == .delete);
    try testing.expectEqualStrings("notes.txt", transcript.pending.?.delete.path);
    try testing.expectEqual(policy_mod.Effect.require_human, transcript.pendingDecision.?.effect);
    try testing.expect(!transcript.ranAnything());
}

test "a run the policy will not allow at all never reaches the provider" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const rules = [_]policy_mod.Rule{.{
        .id = "no-models",
        .capabilities = &.{.@"model.infer"},
        .effect = .deny,
        .reason = "This workspace does not use models.",
    }};
    const fixture = try Fixture.init(&rules, &.{});
    defer fixture.deinit();

    const transcript = try fixture.runner(stopped_clock).run(
        fixture.options(),
        "Anything at all",
        fixture.context(),
    );

    try testing.expectEqual(Ending.stopped_by_policy, transcript.ending);
    try testing.expectEqual(@as(usize, 0), fixture.recorded.seen.items.len);
    // The turn is still on the record, with the decision that stopped it.
    try testing.expectEqual(@as(usize, 1), transcript.turns.len);
    try testing.expectEqual(@as(usize, 1), transcript.turns[0].attempt.decisions.len);
}

test "a summary reads as sentences and counts what happened" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const fixture = try Fixture.init(&allow_models_and_reading, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();
    try fixture.place("notes.txt", "twelve bytes");

    fixture.recorded.responses = try arena.dupe(transport_mod.Response, &.{
        try callResponse(arena, "read_file",
            \\{"path":"notes.txt"}
        ),
        try callResponse(arena, "delete",
            \\{"path":"notes.txt"}
        ),
        try textResponse(arena, "Read it; could not delete it."),
    });

    const transcript = try fixture.runner(stopped_clock).run(
        fixture.options(),
        "Read then delete",
        fixture.context(),
    );

    var buffer: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try transcript.writeSummary(&w);
    const text = w.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "The model finished.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "3 turns") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2 tool calls") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1 of them refused") != null);
    try testing.expect(std.mem.indexOf(u8, text, "tokens") != null);
}
