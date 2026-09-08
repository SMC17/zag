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
const stream_mod = @import("stream.zig");
const schedule = @import("schedule.zig");
const toolschema = @import("toolschema.zig");
const executor_mod = @import("executor.zig");
const policy_mod = @import("policy.zig");
const tools = @import("tools.zig");
const capability_mod = @import("capability.zig");
const hashing = @import("../core/hash.zig");
const timeutil = @import("../core/time.zig");
const notation = @import("../reports/notation.zig");
const compaction_mod = @import("compaction.zig");
const swarm = @import("swarm.zig");

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
    /// What a child agent came back with, when this step started one.
    ///
    /// Kept so the parent's run can account for what the child spent. A child
    /// whose tokens went unrecorded would make "the budget is divided, not
    /// copied" a claim about the grant and not about the bill.
    spawned: ?swarm.Result = null,

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
    /// When to make room in the conversation, and how much to keep.
    ///
    /// Without this the messages only grow — every turn re-sends the whole
    /// history, and one `zig build` adds twenty kilobytes to it — until the
    /// token budget is spent and the run stops with the work unfinished. That
    /// is a bound, not an answer.
    compaction: compaction_mod.Budget = .{},
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
    /// A conversation to carry on from, rebuilt from the record.
    ///
    /// Set when continuing a run that stopped — out of turns, waiting for a
    /// person, a provider that stayed down. The model picks up holding what it
    /// held, rather than starting again and paying for the same work twice.
    /// See `ai/resume.zig` for where these come from and what is faithful
    /// about them.
    resuming: ?[]const provider.Message = null,
    /// Ask for the model's reasoning where the provider offers it.
    showThinking: bool = false,
    effort: ?provider.Effort = null,
    /// How much the model varies its answer. None leaves the provider's own
    /// default alone, which is what a single run wants.
    ///
    /// It exists here for one reason: running the same task several times and
    /// keeping the best is worth nothing if the attempts are the same attempt.
    /// See `ai/bestof.zig`.
    temperature: ?f32 = null,
    maxOutputTokens: u32 = 16000,
    /// What this run may hand to child agents, when it may hand out anything.
    ///
    /// None means `spawn_agent` is not offered and a model that asks for it
    /// anyway is told this run has nothing to run a child on. That is the
    /// default: fanning work out is worth doing when a caller has arranged for
    /// it, not by accident.
    spawning: ?Spawning = null,
};

/// How a run starts children, and how far it may go doing it.
pub const Spawning = struct {
    /// What actually runs a child. Supplied by the caller, because a loop that
    /// could construct another loop would need a provider, a policy engine and
    /// a journal of its own, and would be deciding for itself what a child
    /// gets — which is the thing that must not be decided here.
    spawner: swarm.Spawner,
    bounds: swarm.Bounds = .{},
    /// How deep this run already is. A child is started with its own depth,
    /// which is how the bound survives the run being restarted.
    depth: usize = 0,
};

/// What a child agent is told about being one.
///
/// Short on purpose. A child's whole advantage is that its context holds the
/// question and nothing else, and spending two thousand tokens of instructions
/// on that is spending the advantage. What it needs to know is what it cannot
/// work out: that nobody will read its transcript, so the answer has to be in
/// the last thing it says.
pub const child_instructions =
    \\You are a child agent. Another agent gave you one piece of work and is
    \\waiting for the answer.
    \\
    \\Only your final message is passed back. Your reasoning, the files you
    \\read and the commands you ran are not, so anything the other agent needs
    \\has to be in that message: the finding, where you found it, and what you
    \\could not establish. Quote the few lines that matter rather than
    \\describing them.
    \\
    \\You have few turns. Do not plan, do not summarise what you are about to
    \\do, and do not ask questions — there is nobody to answer them. Find the
    \\answer and say it.
;

/// Runs children on the same loop, under the same policy engine.
///
/// This is the ordinary way to give a run `Spawning`, and the reason it is a
/// separate type rather than a method is that a child needs one thing the
/// parent's options do not hold: a record of its own. The `Runner` is copied
/// with a child's journal in place of the parent's, so the two runs do not
/// report into the same record keeper — see `Journal.forChild`.
///
/// Everything else is deliberately the same object: the same transport, the
/// same executor and, most of all, the same `policy_mod.Engine`. A child that
/// decided on a policy of its own would be a way to get a wider one, and there
/// is no field here to give it one.
pub const Children = struct {
    /// The parent's runner. Copied, not called: only the journal differs.
    runner: *const Runner,
    connector: catalog.Connector,
    model: []const u8,
    /// Who the child acts as. The same actor as the parent, because it is the
    /// same person's work.
    acting: policy_mod.Context,
    bounds: swarm.Bounds = .{},
    /// The shape of the child's budget. Turns and tokens are replaced by what
    /// the grant allows; the rest — time, repeats, calls per turn, when to
    /// compact — is inherited, because those are properties of the machine and
    /// the provider rather than of who asked.
    budget: Budget = .{},
    system: []const u8 = child_instructions,
    maxOutputTokens: u32 = 16000,
    /// Let children of one turn run at the same time.
    ///
    /// This is what makes a fan-out worth doing: four children reading four
    /// parts of a repository take one child's wall clock rather than four.
    /// `agent.spawn` claims `siblings` in `ai/schedule.zig`, so children share
    /// a wave with each other and with nothing else.
    ///
    /// What makes that safe is not the scheduling. It is that a child which
    /// runs beside other children is narrowed to reading — see
    /// `swarm.readOnly` — so two of them cannot disagree about a file. Turning
    /// this on therefore takes authority away from children rather than
    /// granting any, which is why it needs no separate permission.
    ///
    /// Off without an `io` on the runner, because there would be nothing to
    /// run them on and the narrowing would then be pure loss.
    together: bool = false,
    /// Built once, on the first concurrent spawn, and shared by every child
    /// after it. Narrowing is a rule appended to a policy, and doing it per
    /// child would allocate the same list on every fan-out.
    narrowed: ?*policy_mod.Engine = null,

    pub fn spawner(self: *Children) swarm.Spawner {
        return .{ .context = self, .spawnFn = start };
    }

    /// The engine a child runs on: the parent's, or a narrowed one when
    /// children are running together.
    fn engineFor(self: *Children, arena: std.mem.Allocator) !*policy_mod.Engine {
        if (!self.together or self.runner.io == null) return self.runner.engine;
        if (self.narrowed) |engine| return engine;

        const narrowed = try swarm.readOnly(arena, self.runner.engine.policy);
        const engine = try arena.create(policy_mod.Engine);
        engine.* = policy_mod.Engine.init(
            arena,
            narrowed,
            // Its own identifier stream, derived from the narrowed policy's
            // name. Two engines drawing from one seed would hand the same
            // decision identifier to different decisions; drawing it from the
            // clock would make a replay of the same run produce different
            // identifiers, which is the thing the record cannot have.
            std.hash.Wyhash.hash(0xC417D, narrowed.id),
        );
        self.narrowed = engine;
        return engine;
    }

    fn start(
        context: *anyopaque,
        request: tools.SpawnAgentRequest,
        grant: swarm.Grant,
    ) anyerror!swarm.Result {
        const self: *Children = @ptrCast(@alignCast(context));

        var budget = self.budget;
        budget.turns = grant.turns;
        budget.tokens = grant.tokens;

        var runner = self.runner.*;
        // Narrowed when children run together, the parent's own otherwise.
        // Standing grants are deliberately not carried over: a person allowing
        // something once for the parent did not allow it for four children at
        // the same time.
        runner.engine = try self.engineFor(runner.arena);
        runner.transport.engine = runner.engine;
        // A child never writes into its parent's record keeper. Where there is
        // no child journal to be had, it writes nothing rather than writing
        // into the parent's — a corrupted causal tree is worse than a missing
        // one, because it reads as true.
        runner.journal = if (self.runner.journal) |parent| parent.forChild() else null;
        // The parent is the one showing an answer as it arrives. A child's
        // deltas would interleave with it and read as one confused voice.
        runner.watch = null;

        const transcript = try runner.run(.{
            .connector = self.connector,
            .model = self.model,
            .system = self.system,
            .budget = budget,
            .maxOutputTokens = self.maxOutputTokens,
            // A child may spawn in turn where the bounds allow it, at its own
            // depth. The bound survives because the depth is carried, not
            // recomputed.
            .spawning = .{
                .spawner = self.spawner(),
                .bounds = self.bounds,
                .depth = grant.depth,
            },
        }, request.request, self.acting);

        return .{
            .answer = transcript.answer,
            .ending = @tagName(transcript.ending),
            .turns = transcript.turns.len,
            .toolCalls = transcript.toolCallCount(),
            .inputTokens = transcript.usage.inputTokens,
            .outputTokens = transcript.usage.outputTokens,
        };
    }
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
        /// What the tool produced.
        ///
        /// Carried so the recorder can keep it. The log records an address for
        /// every tool result, and nothing was putting the bytes anywhere — so
        /// the record asserted a content hash for content that did not exist,
        /// and the only account of what an agent saw was a one-line summary.
        content: []const u8 = "",
    },
    /// Room was made in the conversation, and something the model had been
    /// shown was taken away.
    ///
    /// Recorded because it changes what the model saw. A log that showed the
    /// whole history when the model was sent a trimmed one would be
    /// describing a different run, and the interesting question after a run
    /// goes wrong — "did it still know about the thing from step two?" — would
    /// have no answer in the record.
    compacted: compaction_mod.Result,
    finished: struct {
        ending: Ending,
        elapsed: timeutil.Duration,
        toolCalls: usize,
        refusedCalls: usize,
        usage: provider.Usage,
        /// How many times room had to be made, and how many tool results were
        /// given up doing it.
        compactions: usize = 0,
        droppedResults: usize = 0,
    },
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
    /// Make a journal for a child agent's run, whose record hangs under this
    /// one.
    ///
    /// A child cannot share its parent's journal. A record keeper follows one
    /// run — which turn is open, which tool call the next outcome belongs to —
    /// and a second run reporting into the same one would attach the child's
    /// tool calls to the parent's request and leave the parent's causal tree
    /// pointing at the child's start. The child gets its own, caused by the
    /// parent's, which is how `zag why` walks from one to the other.
    ///
    /// None means the caller keeps no separate record for children. The run
    /// still happens and the parent's step still records what came back; what
    /// is lost is the child's own working, and a caller that offers spawning
    /// should offer this.
    childFn: ?*const fn (context: *anyopaque) anyerror!Journal = null,

    pub fn forChild(self: Journal) ?Journal {
        const make = self.childFn orelse return null;
        return make(self.context) catch null;
    }

    pub fn record(self: Journal, moment: Moment) void {
        // A record that could not be written must not stop the work, and must
        // not be silently equivalent to one that was. The caller owns the
        // journal and is the one that can tell a person; here the run carries
        // on, because losing a tool result to a full disk is worse than losing
        // a line of the log.
        self.recordFn(self.context, moment) catch {};
    }
};

/// Somewhere to show an answer while it is still being written.
pub const Watch = struct {
    context: ?*anyopaque = null,
    /// Text only. A caller that wants tool arguments and reasoning as they
    /// arrive uses the transport directly; this is the shape a terminal needs.
    textFn: *const fn (context: ?*anyopaque, chunk: []const u8) anyerror!void,

    /// Bridges to the transport's delta callback, so that only text reaches
    /// the caller and a failure to print never becomes a failure to answer.
    fn onDelta(context: ?*anyopaque, delta: stream_mod.Delta) anyerror!void {
        const self: *const Watch = @ptrCast(@alignCast(context orelse return));
        switch (delta) {
            .text => |t| self.textFn(self.context, t.chunk) catch {},
            else => {},
        }
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
    /// Where concurrent tool calls run. None means every call runs in turn,
    /// which produces the identical record — the scheduler is a plan, not a
    /// thread pool, and running its waves one call at a time is a valid way to
    /// honour it.
    io: ?std.Io = null,
    /// Called with each piece of the answer as it arrives, when it is asked
    /// for and the transport can read one.
    ///
    /// This is the only reason streaming exists at this level: a run that takes
    /// a minute should not look identical to a run that has hung. The
    /// transcript and the record are unchanged either way — the deltas are
    /// shown, not stored, because the completion they assemble into is what the
    /// log already holds.
    watch: ?Watch = null,

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
        if (options.resuming) |earlier| {
            // Continuing a run that stopped. The conversation was rebuilt from
            // the record, so the model picks up holding what it held — rather
            // than starting again and paying for the same work twice.
            try messages.appendSlice(self.arena, earlier);
            // A resumed run needs something to answer. Without a new turn the
            // last message is the tool results, which is a request to keep
            // going; with one, the person has said what to do differently.
            if (question.len > 0) {
                try messages.append(self.arena, .{
                    .role = .user,
                    .blocks = try self.arena.dupe(provider.Block, &.{.{ .text = question }}),
                });
            }
        } else {
            try messages.append(self.arena, .{
                .role = .user,
                .blocks = try self.arena.dupe(provider.Block, &.{.{ .text = question }}),
            });
        }

        var turns: std.ArrayList(Turn) = .empty;
        var usage: provider.Usage = .{};
        var seen: std.ArrayList(Repeat) = .empty;
        const declared = toolschema.declarations(self.arena, .{
            // Offered only when there is something to run a child on. A tool
            // advertised with nothing behind it is a promise broken after the
            // model has already spent a turn deciding to use it.
            .spawnAgent = options.spawning != null,
        }) catch return error.OutOfMemory;

        // Carried down the turn rather than held anywhere global, so two runs
        // in the same process cannot exhaust each other's allowance.
        var spawns: swarm.State = .{
            .depth = if (options.spawning) |s| s.depth else 0,
        };

        var ending: Ending = .out_of_turns;
        var answer: []const u8 = "";
        var pending: ?ToolRequest = null;
        var pending_decision: ?Decision = null;

        var compactions: usize = 0;
        var dropped: usize = 0;
        var number: usize = 1;
        while (number <= options.budget.turns) : (number += 1) {
            // A child's share is taken from what the parent has left, and what
            // the parent has left shrinks every turn. A late spawn is small,
            // and at the end there is nothing to give.
            spawns.newTurn();
            spawns.parentTurnsLeft = options.budget.turns - number + 1;
            spawns.parentTokensLeft = options.budget.tokens -| usage.total();

            var attempt: transport_mod.Attempt = undefined;
            const asked: provider.Request = .{
                .model = options.model,
                .system = options.system,
                .messages = messages.items,
                .tools = declared,
                .maxOutputTokens = options.maxOutputTokens,
                // Worth asking for on every turn of an agent run: the whole
                // conversation goes out again each time, and by the tenth turn
                // most of it is bytes the provider has already read. Formats
                // with no way to express this ignore the field.
                .caching = if (options.connector.wire().supportsCaching()) .prefix else .none,
                .effort = options.effort,
                .temperature = options.temperature,
                .showThinking = options.showThinking,
            };
            // Watched or not, the same gate and the same completion. Streaming
            // changes when a person sees the answer, never what it is.
            var watch = self.watch;
            const completion = (if (watch != null and self.transport.streaming != null)
                self.transport.sendStreaming(
                    options.connector,
                    asked,
                    context,
                    &attempt,
                    Watch.onDelta,
                    &watch.?,
                )
            else
                self.transport.send(options.connector, asked, context, &attempt)) catch |err| {
                try turns.append(self.arena, .{ .number = number, .attempt = attempt });
                ending = switch (err) {
                    error.NeedsApproval => .waiting_for_a_person,
                    // An address that is not where its name said is a
                    // refusal by the workspace, not a provider being down. It
                    // stops the run the same way a policy denial does, because
                    // that is what it is.
                    error.NotPermitted, error.CredentialMissing, error.AddressRefused => .stopped_by_policy,
                    error.ProviderRejected, error.SendFailed, error.StreamingUnavailable => .provider_unavailable,
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

            const wanted = @min(calls.len, options.budget.callsPerTurn);

            // Every decision, serially, in the order the model asked. Parsing a
            // call, counting repeats and asking the policy engine all read or
            // write state that two threads must not touch at once — and, more
            // than that, a decision taken concurrently would make the record
            // depend on thread timing.
            var prepared = try self.arena.alloc(Prepared, wanted);
            var claims = try self.arena.alloc(?schedule.Claim, wanted);
            for (calls[0..wanted], 0..) |call, index| {
                prepared[index] = try self.prepare(call, context, &seen, options.budget.repeats, options.spawning, &spawns);
                claims[index] = prepared[index].claim;
            }

            // Then the work, in waves of calls that touch nothing in common.
            // Results are written back by index, never in the order they
            // finished, so the turn recorded from eight threads is the turn
            // recorded from one.
            const waves = try schedule.plan(self.arena, claims);
            try self.performWaves(prepared, waves);

            for (calls[0..wanted], prepared) |call, done| {
                const step = done.step;
                try steps.append(self.arena, step);
                self.recordStep(step);
                try results.append(self.arena, .{ .tool_result = .{
                    .toolUseId = call.id,
                    .content = step.reply,
                    .isError = step.refused or (step.result != null and !step.result.?.succeeded()),
                } });

                // A child's spend is the parent's spend. Added here rather
                // than inside the spawn, because the token budget is checked
                // at the end of this turn and a child that has just spent
                // forty thousand tokens should be the reason the run stops.
                if (step.spawned) |child| {
                    usage.inputTokens += child.inputTokens;
                    usage.outputTokens += child.outputTokens;
                }

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

            // Make room before the next turn rather than stopping when there
            // is none. What goes is old tool output, whose value has already
            // been taken; what stays is the task, the recent work, and
            // everything the model itself concluded.
            const made_room = try compaction_mod.compact(self.arena, messages.items, options.budget.compaction);
            if (made_room.changedAnything()) {
                messages.clearRetainingCapacity();
                try messages.appendSlice(self.arena, made_room.messages);
                compactions += 1;
                dropped += made_room.replaced;
                self.note(.{ .compacted = made_room });
            }

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

        var calls: usize = 0;
        var refusals: usize = 0;
        for (turns.items) |turn| {
            calls += turn.steps.len;
            for (turn.steps) |step| {
                if (step.refused) refusals += 1;
            }
        }
        self.note(.{ .finished = .{
            .ending = ending,
            .elapsed = .{ .ns = self.clock.now() - started },
            .toolCalls = calls,
            .refusedCalls = refusals,
            .usage = usage,
            .compactions = compactions,
            .droppedResults = dropped,
        } });

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
            .content = result.content,
        } });
    }

    /// One tool call, all the way through.
    /// A call that has been decided about and not yet run.
    ///
    /// The split exists so that everything which decides anything happens
    /// serially, in the order the model asked, and only the executor's work is
    /// allowed to overlap. A decision taken concurrently would make the record
    /// depend on thread timing, which is the one thing an append-only log
    /// cannot afford.
    const Prepared = struct {
        step: Step,
        /// Set when there is still work to do. Null means the step is finished
        /// — refused, or never a typed request in the first place.
        pending: ?struct { decision: Decision, request: ToolRequest } = null,
        claim: ?schedule.Claim = null,
        /// What a child was granted, for a `spawn_agent` that got past both the
        /// policy and the bounds. Decided here rather than where the work
        /// happens, because the counters it comes from are shared and the
        /// deciding half of a turn is the half that runs serially.
        spawn: ?Spawn = null,
    };

    const Spawn = struct {
        spawning: Spawning,
        grant: swarm.Grant,
    };

    /// Decide about one call. Never runs anything.
    fn prepare(
        self: Runner,
        call: provider.ToolUse,
        context: policy_mod.Context,
        seen: *std.ArrayList(Repeat),
        repeat_limit: usize,
        spawning: ?Spawning,
        spawns: *swarm.State,
    ) Error!Prepared {
        var out: Prepared = .{ .step = undefined };
        out.step = try self.decideOne(call, context, seen, repeat_limit, spawning, spawns, &out);
        return out;
    }

    fn decideOne(
        self: Runner,
        call: provider.ToolUse,
        context: policy_mod.Context,
        seen: *std.ArrayList(Repeat),
        repeat_limit: usize,
        spawning: ?Spawning,
        spawns: *swarm.State,
        out: *Prepared,
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

        // 5. Starting a child has a second set of bounds after the policy's.
        //    The policy answers whether this agent may spawn at all; these
        //    answer how deep, how many and how much — questions a capability
        //    cannot express, because their answers depend on what this run has
        //    already spent. Counted here, where turns are decided one at a
        //    time and in the order the model asked.
        if (request == .spawn_agent) {
            const arranged = spawning orelse {
                step.refused = true;
                step.result = .{
                    .outcome = .denied,
                    .summary = "This run has nothing to run a child agent on. Do the work yourself.",
                };
                step.reply = try toolschema.resultText(self.arena, step.result.?);
                return step;
            };
            switch (swarm.allow(arranged.bounds, spawns.*)) {
                .refused => |refusal| {
                    step.refused = true;
                    step.result = .{ .outcome = .denied, .summary = refusal.text() };
                    step.reply = try toolschema.resultText(self.arena, step.result.?);
                    return step;
                },
                .allowed => |grant| {
                    spawns.startedThisTurn += 1;
                    spawns.startedInTotal += 1;
                    out.spawn = .{ .spawning = arranged, .grant = grant };
                },
            }
        }

        // 6. Everything is decided. What is left is the work itself, which is
        //    the only part allowed to overlap with another call's, and only
        //    when nothing they touch is shared.
        out.pending = .{ .decision = decision, .request = request };
        out.claim = schedule.claimOf(self.arena, request) catch return error.OutOfMemory;
        return step;
    }

    /// Run every prepared call, a wave at a time.
    ///
    /// With no `io` there is nothing to run things on, so the waves are walked
    /// in order and each call runs where it stands. The result is identical —
    /// that is the point of the scheduler being a plan rather than a thread
    /// pool — and there is a test that asserts it.
    fn performWaves(self: Runner, prepared: []Prepared, waves: []const schedule.Wave) Error!void {
        const io = self.io orelse {
            for (waves) |wave| {
                for (wave.members) |index| try self.perform(&prepared[index]);
            }
            return;
        };

        for (waves) |wave| {
            if (wave.len() == 1) {
                // One call is not worth a unit of concurrency, and most waves
                // hold one.
                try self.perform(&prepared[wave.members[0]]);
                continue;
            }
            var futures = try self.arena.alloc(std.Io.Future(Error!Step), wave.len());
            for (wave.members, 0..) |index, at| {
                const held = prepared[index].pending.?;
                futures[at] = io.async(runOne, .{
                    self,
                    prepared[index].step,
                    held.decision,
                    held.request,
                    prepared[index].spawn,
                });
            }
            // Awaited in wave order, and each result stored at its own index.
            // Nothing here depends on which finished first.
            for (wave.members, 0..) |index, at| {
                prepared[index].step = try futures[at].await(io);
                prepared[index].pending = null;
            }
        }
    }

    fn perform(self: Runner, item: *Prepared) Error!void {
        const held = item.pending orelse return;
        item.step = try runOne(self, item.step, held.decision, held.request, item.spawn);
        item.pending = null;
    }

    /// Spend a decision. Safe to call from more than one thread at once, on
    /// calls the scheduler has said touch nothing in common.
    fn runOne(
        self: Runner,
        step: Step,
        decision: Decision,
        request: ToolRequest,
        spawn: ?Spawn,
    ) Error!Step {
        var out = step;
        // Starting a child does not go through the executor, and cannot: the
        // executor performs requests against a filesystem and a process table,
        // and an agent is neither. It goes to the spawner the caller supplied,
        // under the grant already decided, and comes back as an ordinary tool
        // result — which is what makes it one more thing the record accounts
        // for rather than a second way to do work.
        if (spawn) |granted| return self.spawnChild(out, request.spawn_agent, granted);

        const result = self.executor.run(decision, request) catch |err| {
            // Some of these are refusals reached before anything happened, and
            // some are failures during the work. A person reading the record
            // needs the difference: "it did not run" and "it ran and did not
            // work" lead to different next moves, and so does the message the
            // model gets back.
            const refused_before_acting = switch (err) {
                error.NotAllowed,
                error.DecisionDoesNotMatchRequest,
                error.NoExecutor,
                error.UseTheTypedRequest,
                error.NoShellForAgents,
                => true,
                else => false,
            };
            out.refused = refused_before_acting;
            out.executed = !refused_before_acting;
            out.result = .{
                .outcome = if (refused_before_acting) .denied else .failed,
                .summary = executor_mod.refusalText(err),
            };
            // The executor's own words, not the policy's. The policy may well
            // have allowed this: what refused it was the request model, and
            // telling a model "the policy did not allow this" when the policy
            // did would send it to ask a person about the wrong thing.
            out.reply = if (refused_before_acting)
                executor_mod.refusalText(err)
            else
                try toolschema.resultText(self.arena, out.result.?);
            return out;
        };
        out.executed = true;
        out.result = result;
        out.reply = try toolschema.resultText(self.arena, result);
        return out;
    }

    /// Run a child agent and bring back its answer.
    ///
    /// What crosses back is the answer and a line saying what it cost. The
    /// transcript stays where it was made: the whole reason to hand work to a
    /// child is that the parent's context gets a sentence where the child
    /// spent fifty thousand tokens producing it, and copying the transcript
    /// back would undo that exactly.
    ///
    /// A child that ends any way other than answering is still a result rather
    /// than a failure. "It ran out of turns and here is how far it got" is
    /// something a parent can act on; an error is not.
    fn spawnChild(
        self: Runner,
        step: Step,
        request: tools.SpawnAgentRequest,
        granted: Spawn,
    ) Error!Step {
        var out = step;
        const child = granted.spawning.spawner.spawn(request, granted.grant) catch |err| {
            out.executed = true;
            out.result = .{
                .outcome = .failed,
                .summary = std.fmt.allocPrint(
                    self.arena,
                    "The child agent could not be started: {s}.",
                    .{@errorName(err)},
                ) catch return error.OutOfMemory,
            };
            out.reply = try toolschema.resultText(self.arena, out.result.?);
            return out;
        };

        out.executed = true;
        out.spawned = child;
        const summary = child.summary(self.arena) catch return error.OutOfMemory;
        out.result = .{
            // The child answered, or it did not. Either is an outcome the
            // parent can work with, and the difference is one the model has to
            // be told: an answer from a child that ran out of turns is
            // partial, and treating it as complete is how a parent confidently
            // reports half a finding.
            .outcome = if (std.mem.eql(u8, child.ending, "answered")) .completed else .failed,
            .summary = summary,
            .content = child.answer,
        };
        out.reply = std.fmt.allocPrint(self.arena, "{s}\n\n{s}", .{
            summary,
            if (child.answer.len > 0) child.answer else "It produced no answer.",
        }) catch return error.OutOfMemory;
        return out;
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

const allow_models_reading_and_children = [_]policy_mod.Rule{
    allow_models_and_reading[0],
    allow_models_and_reading[1],
    .{
        .id = "children",
        .capabilities = &.{.@"agent.spawn"},
        .effect = .allow,
        .reason = "This test's workspace allows handing work to children.",
    },
};

test "a run hands work to a child and gets back an answer, not a transcript" {
    const fixture = try Fixture.init(&allow_models_reading_and_children, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();

    try fixture.place("transport.zig", "firstDelay = 500ms, maxDelay = 8s");

    fixture.recorded.responses = try arena.dupe(transport_mod.Response, &.{
        // The parent decides the reading is not worth its own context.
        try callResponse(arena, "spawn_agent",
            \\{"label":"find the backoff","request":"Which file sets the retry backoff, and what are the numbers?"}
        ),
        // The child does the reading. Its turns come out of the same scripted
        // transport, which is what makes this a real child run and not a stub.
        try callResponse(arena, "read_file",
            \\{"path":"transport.zig"}
        ),
        try textResponse(arena, "transport.zig sets firstDelay to 500ms and maxDelay to 8s."),
        // And the parent answers holding the sentence rather than the file.
        try textResponse(arena, "The backoff starts at 500ms and stops at 8s."),
    });

    const runner = fixture.runner(stopped_clock);
    var children: Children = .{
        .runner = &runner,
        .connector = catalog.find("ollama").?,
        .model = "test-model",
        .acting = fixture.context(),
    };

    var options = fixture.options();
    options.spawning = .{ .spawner = children.spawner() };

    const transcript = try runner.run(options, "What is the retry backoff?", fixture.context());

    try testing.expectEqual(Ending.answered, transcript.ending);
    const step = transcript.turns[0].steps[0];
    try testing.expectEqualStrings("spawn_agent", step.toolName);
    try testing.expect(step.ran());
    try testing.expectEqual(tools.Outcome.completed, step.result.?.outcome);

    // What came back is the child's answer and what it cost, and nothing else.
    const child = step.spawned.?;
    try testing.expectEqualStrings("answered", child.ending);
    try testing.expectEqual(@as(usize, 2), child.turns);
    try testing.expectEqual(@as(usize, 1), child.toolCalls);
    try testing.expect(std.mem.indexOf(u8, child.answer, "500ms") != null);

    // The parent's context holds the sentence. It never held the file: the
    // child read it, and the child's transcript stayed with the child.
    try testing.expect(std.mem.indexOf(u8, step.reply, "500ms") != null);
    try testing.expect(std.mem.indexOf(u8, step.reply, "A child agent answered") != null);

    // And the child's spend is the parent's spend. A grant that was divided
    // and a bill that was not is not a bound.
    // Two turns of the parent's own (10 and 8) and the child's two (10 and 8).
    try testing.expectEqual(@as(u64, 10 + 8 + 10 + 8), transcript.usage.inputTokens);
    try testing.expectEqual(@as(u64, 10 + 8), child.inputTokens);
}

test "children that run together may only read, whatever the parent may do" {
    // A workspace that lets an agent write. Its children, running side by
    // side, may not — because what two of them touch cannot be read off a
    // request, and a race between two agents over one file would be recorded
    // faithfully and be nobody's fault.
    const wide = [_]policy_mod.Rule{
        allow_models_and_reading[0],
        allow_models_and_reading[1],
        .{
            .id = "writing",
            .capabilities = &.{.@"fs.write"},
            .effect = .allow,
            .reason = "This workspace allows writing.",
        },
        .{
            .id = "children",
            .capabilities = &.{.@"agent.spawn"},
            .effect = .allow,
            .reason = "And starting children.",
        },
    };

    const fixture = try Fixture.init(&wide, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();

    fixture.recorded.responses = try arena.dupe(transport_mod.Response, &.{
        try callResponse(arena, "spawn_agent",
            \\{"request":"Write notes.txt."}
        ),
        // The child tries to write, and is refused by its own engine.
        try callResponse(arena, "write_file",
            \\{"path":"notes.txt","contents":"hello"}
        ),
        try textResponse(arena, "I was not allowed to write."),
        try textResponse(arena, "The child could not write."),
    });

    var runner = fixture.runner(stopped_clock);
    // Concurrency is what the narrowing pays for, so there has to be something
    // to run children on for it to apply at all.
    runner.io = fixture.threaded.io();

    var children: Children = .{
        .runner = &runner,
        .connector = catalog.find("ollama").?,
        .model = "test-model",
        .acting = fixture.context(),
        .together = true,
    };

    var options = fixture.options();
    options.spawning = .{ .spawner = children.spawner() };

    const transcript = try runner.run(options, "Write some notes.", fixture.context());
    try testing.expect(transcript.turns[0].steps[0].ran());

    // The parent's own engine still allows writing. Only the children's does
    // not, and the narrowing is a rule appended rather than a policy replaced.
    try testing.expect(children.narrowed != null);
    try testing.expect(children.narrowed.?.policy.rules.len > wide.len);
    try testing.expect(std.mem.indexOf(u8, children.narrowed.?.policy.id, "reading-only") != null);

    // The child made its call and was refused: the run has the call in it, and
    // the engine it ran on says no to exactly that request.
    const child = transcript.turns[0].steps[0].spawned.?;
    try testing.expectEqual(@as(usize, 1), child.toolCalls);

    const writing: policy_mod.Request = .{
        .capability = .@"fs.write",
        .resource = .{ .path = "notes.txt" },
    };
    try testing.expect(!(try children.narrowed.?.decide(writing, fixture.context())).isAllowed());
    try testing.expect((try fixture.engine.decide(writing, fixture.context())).isAllowed());
    // Reading survives, or a child would not be an agent.
    const reading: policy_mod.Request = .{
        .capability = .@"fs.read",
        .resource = .{ .path = "notes.txt" },
    };
    try testing.expect((try children.narrowed.?.decide(reading, fixture.context())).isAllowed());
}

test "a run with nothing to start a child on says so rather than pretending" {
    const fixture = try Fixture.init(&allow_models_reading_and_children, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();

    // The policy allows starting an agent. There is still nothing here to run
    // one on, and those are different refusals: one is "you may not", the
    // other is "there is no such thing here".
    fixture.recorded.responses = try arena.dupe(transport_mod.Response, &.{
        try callResponse(arena, "spawn_agent",
            \\{"request":"Count the tests."}
        ),
        try textResponse(arena, "I will do it myself."),
    });

    const transcript = try fixture.runner(stopped_clock).run(
        fixture.options(),
        "How many tests are there?",
        fixture.context(),
    );

    const step = transcript.turns[0].steps[0];
    try testing.expect(step.refused);
    try testing.expect(!step.ran());
    try testing.expect(std.mem.indexOf(u8, step.reply, "nothing to run a child agent on") != null);
    try testing.expectEqual(Ending.answered, transcript.ending);
}

test "the bound on children over a whole run is a bound, not a bound per turn" {
    const fixture = try Fixture.init(&allow_models_reading_and_children, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();

    fixture.recorded.responses = try arena.dupe(transport_mod.Response, &.{
        try callResponse(arena, "spawn_agent",
            \\{"request":"The first piece."}
        ),
        try textResponse(arena, "The first answer."),
        // A new turn clears the per-turn count. It does not clear the total,
        // which is the whole reason the total exists: ten turns of four is
        // forty children and nobody chose that.
        try callResponse(arena, "spawn_agent",
            \\{"request":"The second piece."}
        ),
        try textResponse(arena, "I did the rest myself."),
    });

    const runner = fixture.runner(stopped_clock);
    var children: Children = .{
        .runner = &runner,
        .connector = catalog.find("ollama").?,
        .model = "test-model",
        .acting = fixture.context(),
        .bounds = .{ .maxTotal = 1 },
    };

    var options = fixture.options();
    options.spawning = .{ .spawner = children.spawner(), .bounds = children.bounds };

    const transcript = try runner.run(options, "Do two things.", fixture.context());

    try testing.expect(transcript.turns[0].steps[0].ran());

    const refused = transcript.turns[1].steps[0];
    try testing.expect(refused.refused);
    try testing.expect(refused.spawned == null);
    // And the refusal says what to do instead, or the model asks again.
    try testing.expect(std.mem.indexOf(u8, refused.reply, "yourself") != null);
    try testing.expectEqualStrings("I did the rest myself.", transcript.answer);
}

test "a child gets a share of what is left, and none when there is nothing left" {
    const fixture = try Fixture.init(&allow_models_reading_and_children, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();

    fixture.recorded.responses = try arena.dupe(transport_mod.Response, &.{
        try callResponse(arena, "spawn_agent",
            \\{"request":"Something."}
        ),
        try textResponse(arena, "Nothing to report."),
    });

    const runner = fixture.runner(stopped_clock);
    var children: Children = .{
        .runner = &runner,
        .connector = catalog.find("ollama").?,
        .model = "test-model",
        .acting = fixture.context(),
    };

    // Three turns, halved, is one — below the least a child can finish
    // anything with. Starting it would spend a request to be told it ran out.
    var options = fixture.options();
    options.budget.turns = 3;
    options.spawning = .{ .spawner = children.spawner() };

    const transcript = try runner.run(options, "Do something.", fixture.context());

    const step = transcript.turns[0].steps[0];
    try testing.expect(step.refused);
    try testing.expect(std.mem.indexOf(u8, step.reply, "not enough turns") != null);
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

test "a refusal from the executor is not reported as the policy refusing" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    // The policy allows running programs. What refuses these is the request
    // model itself, and the two must not be confused: a model told the policy
    // refused will go and ask a person about a permission they already gave.
    const rules = [_]policy_mod.Rule{.{
        .id = "allow-everything",
        .capabilities = &.{ .@"model.infer", .@"network.connect", .@"process.execute" },
        .effect = .allow,
        .reason = "This workspace allows running programs.",
    }};
    const fixture = try Fixture.init(&rules, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();

    fixture.recorded.responses = try arena.dupe(transport_mod.Response, &.{
        try callResponse(arena, "run_command",
            \\{"argv":["sh","-c","rm -rf notes.txt"],"workingDirectory":"."}
        ),
        try callResponse(arena, "run_command",
            \\{"argv":["rm","notes.txt"],"workingDirectory":"."}
        ),
        try textResponse(arena, "I could not remove it."),
    });

    const transcript = try fixture.runner(stopped_clock).run(
        fixture.options(),
        "delete notes.txt",
        fixture.context(),
    );

    const shell = transcript.turns[0].steps[0];
    const program = transcript.turns[1].steps[0];

    // Neither ran, and the record says refused rather than ran-and-failed.
    try testing.expect(!shell.ran());
    try testing.expect(!program.ran());
    try testing.expect(shell.refused);
    try testing.expect(program.refused);
    try testing.expect(!transcript.ranAnything());

    // The decision was an allow. The refusal came from somewhere else, and the
    // words the model gets back say which.
    try testing.expect(shell.decision.?.isAllowed());
    try testing.expect(program.decision.?.isAllowed());
    try testing.expect(std.mem.indexOf(u8, shell.reply, "may not run a shell") != null);
    try testing.expect(std.mem.indexOf(u8, program.reply, "request of its own") != null);
    try testing.expect(std.mem.indexOf(u8, shell.reply, "policy did not allow") == null);
    try testing.expect(std.mem.indexOf(u8, program.reply, "policy did not allow") == null);
}

test "watching a run changes when the answer is seen, never what it is" {
    // The same answer, delivered two ways: as one object, and as the stream of
    // objects Ollama actually sends. The transcripts must not differ. A
    // streaming path that returns something slightly different from the
    // blocking one surfaces months later as "the model behaves differently
    // when you watch it".
    var quiet = try Fixture.init(&allow_models_and_reading, &.{});
    defer quiet.deinit();
    quiet.recorded.responses = &.{try textResponse(quiet.arena(), "The tests pass.")};
    const unwatched = try quiet.runner(stopped_clock).run(quiet.options(), "Do the tests pass?", quiet.context());
    try testing.expectEqualStrings("The tests pass.", unwatched.answer);

    const streamed_body =
        "{\"model\":\"test-model\",\"message\":{\"role\":\"assistant\",\"content\":\"The tests \"},\"done\":false}\n" ++
        "{\"model\":\"test-model\",\"message\":{\"role\":\"assistant\",\"content\":\"pass.\"},\"done\":false}\n" ++
        "{\"model\":\"test-model\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\",\"prompt_eval_count\":8,\"eval_count\":4}\n";

    var loud = try Fixture.init(&allow_models_and_reading, &.{.{ .status = 200, .body = streamed_body }});
    defer loud.deinit();

    const Seen = struct {
        var chunks: usize = 0;
        var text: std.ArrayList(u8) = .empty;
        var arena: std.mem.Allocator = undefined;
        fn take(_: ?*anyopaque, chunk: []const u8) anyerror!void {
            chunks += 1;
            try text.appendSlice(arena, chunk);
        }
    };
    Seen.chunks = 0;
    Seen.text = .empty;
    Seen.arena = loud.arena();

    var watched_runner = loud.runner(stopped_clock);
    watched_runner.transport.streaming = loud.recorded.streamingSender();
    watched_runner.watch = .{ .textFn = Seen.take };
    const watched = try watched_runner.run(loud.options(), "Do the tests pass?", loud.context());

    // The answer was seen in more than one piece while it was being written,
    // which is the whole feature.
    try testing.expect(Seen.chunks >= 2);
    try testing.expectEqualStrings("The tests pass.", Seen.text.items);

    // And both runs produced the same transcript.
    try testing.expectEqualStrings(unwatched.answer, watched.answer);
    try testing.expectEqual(unwatched.ending, watched.ending);
    try testing.expectEqual(unwatched.turns.len, watched.turns.len);
    try testing.expectEqual(unwatched.usage.inputTokens, watched.usage.inputTokens);
    try testing.expectEqual(unwatched.usage.outputTokens, watched.usage.outputTokens);
}

test "a run with no watcher never asks for a stream" {
    // The flag is set by the runner, not by the caller, so a run nobody is
    // watching must not ask for a framing it will not read.
    var fixture = try Fixture.init(&allow_models_and_reading, &.{});
    defer fixture.deinit();
    fixture.recorded.responses = &.{try textResponse(fixture.arena(), "Yes.")};

    _ = try fixture.runner(stopped_clock).run(fixture.options(), "Do they?", fixture.context());
    const body = fixture.recorded.seen.items[0].body;
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
}

test "independent reads overlap, and the record is the same as if they had not" {
    // The property the whole scheduler exists to preserve. One turn asking for
    // three independent reads, run once serially and once concurrently, and the
    // two transcripts must be identical — same steps, same order, same replies.
    // A log whose contents depend on which read finished first proves nothing
    // anybody wants proved.
    const three_reads =
        \\{"model":"test-model","message":{"role":"assistant","content":"",
        \\ "tool_calls":[
        \\  {"function":{"name":"read_file","arguments":{"path":"one.txt"}}},
        \\  {"function":{"name":"read_file","arguments":{"path":"two.txt"}}},
        \\  {"function":{"name":"read_file","arguments":{"path":"three.txt"}}}]},
        \\ "done":true,"done_reason":"stop","prompt_eval_count":10,"eval_count":5}
    ;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    // Both fixtures stay alive to the end of the test: the transcripts point
    // into their arenas.
    var fixtures: [2]*Fixture = undefined;
    var transcripts: [2]Transcript = undefined;
    for (0..2) |run| {
        fixtures[run] = try Fixture.init(&allow_models_and_reading, &.{});
        const fixture = fixtures[run];
        fixture.recorded.responses = &.{
            .{ .status = 200, .body = three_reads },
            try textResponse(fixture.arena(), "All three read."),
        };
        try fixture.place("one.txt", "first");
        try fixture.place("two.txt", "second");
        try fixture.place("three.txt", "third");

        var runner = fixture.runner(stopped_clock);
        // The only difference between the two runs.
        if (run == 1) runner.io = threaded.io();
        transcripts[run] = try runner.run(fixture.options(), "Read all three.", fixture.context());

        const steps = transcripts[run].turns[0].steps;
        try testing.expectEqual(@as(usize, 3), steps.len);
        // Each read ran, and each landed on the path the model asked for at
        // that position — not another call's, which is what a scheduler that
        // mixed up its indices would produce.
        try testing.expectEqualStrings("one.txt", steps[0].request.?.read_file.path);
        try testing.expectEqualStrings("two.txt", steps[1].request.?.read_file.path);
        try testing.expectEqualStrings("three.txt", steps[2].request.?.read_file.path);
        for (steps) |step| try testing.expect(step.executed);
    }
    defer for (fixtures) |fixture| fixture.deinit();

    // Identical, step for step.
    try testing.expectEqualStrings(transcripts[0].answer, transcripts[1].answer);
    try testing.expectEqual(transcripts[0].ending, transcripts[1].ending);
    try testing.expectEqual(transcripts[0].turns.len, transcripts[1].turns.len);
    for (transcripts[0].turns, transcripts[1].turns) |a, b| {
        try testing.expectEqual(a.steps.len, b.steps.len);
        for (a.steps, b.steps) |x, y| {
            try testing.expectEqualStrings(x.toolName, y.toolName);
            try testing.expectEqualStrings(x.reply, y.reply);
            try testing.expectEqual(x.refused, y.refused);
            try testing.expectEqual(x.executed, y.executed);
        }
    }
}

test "a write and the reads around it are never overlapped" {
    // Reading a file while another call writes it is a race whose answer
    // depends on timing. The scheduler is what stops that, and this is the
    // shape it has to stop: the write is in its own wave, with a read on
    // either side of it.
    var fixture = try Fixture.init(&allow_everything_here, &.{});
    defer fixture.deinit();
    const arena = fixture.arena();

    const claims = [_]?schedule.Claim{
        try schedule.claimOf(arena, .{ .read_file = .{ .path = "notes.md" } }),
        try schedule.claimOf(arena, .{ .write_file = .{ .path = "notes.md", .contentHash = hashing.Hash.of("x"), .byteCount = 1 } }),
        try schedule.claimOf(arena, .{ .read_file = .{ .path = "notes.md" } }),
        try schedule.claimOf(arena, .{ .read_file = .{ .path = "other.md" } }),
    };
    const waves = try schedule.plan(arena, &claims);

    // Three waves: the reads of `notes.md` cannot sit beside the write, and the
    // unrelated file rides along with the first of them.
    try testing.expectEqual(@as(usize, 3), waves.len);
    try testing.expectEqualSlices(usize, &.{ 0, 3 }, waves[0].members);
    try testing.expectEqualSlices(usize, &.{1}, waves[1].members);
    try testing.expectEqualSlices(usize, &.{2}, waves[2].members);
}

const allow_everything_here = [_]policy_mod.Rule{.{
    .id = "everything",
    .capabilities = &.{ .@"model.infer", .@"network.connect", .@"fs.read", .@"fs.write" },
    .effect = .allow,
    .reason = "This test workspace allows the tools it uses.",
}};
