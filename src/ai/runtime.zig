//! The agent runtime.
//!
//! An agent is another actor in the workspace, not a chat window attached to a
//! terminal. It works the same loop every time:
//!
//!     request -> plan -> typed tool request -> policy decision
//!             -> (person, when the policy says so) -> execution -> events
//!
//! The provider decides what to try. It never decides what is permitted: the
//! policy engine does that, locally, and every decision becomes a record.

const std = @import("std");
const tools = @import("tools.zig");
const policy_mod = @import("policy.zig");
const approval_mod = @import("approval.zig");
const capability_mod = @import("capability.zig");
const event_mod = @import("../events/event.zig");
const log_mod = @import("../events/log.zig");
const idmod = @import("../core/id.zig");
const hashing = @import("../core/hash.zig");
const timeutil = @import("../core/time.zig");
const provenance_mod = @import("../data/provenance.zig");

pub const ToolRequest = tools.ToolRequest;
pub const ToolResult = tools.ToolResult;
pub const Decision = policy_mod.Decision;
pub const Timestamp = timeutil.Timestamp;

/// Something that can carry out a tool request. The runtime never executes
/// anything itself, so a test, a sandbox and a remote daemon are all just
/// different executors.
pub const Executor = struct {
    ptr: *anyopaque,
    executeFn: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, request: ToolRequest) anyerror!ToolResult,

    pub fn execute(self: Executor, arena: std.mem.Allocator, request: ToolRequest) !ToolResult {
        return self.executeFn(self.ptr, arena, request);
    }
};

pub const Step = struct {
    /// What this step is for, in the words shown to the person.
    description: []const u8,
    request: ToolRequest,
};

pub const Plan = struct {
    goal: []const u8,
    steps: []const Step,
};

pub const StepOutcome = union(enum) {
    /// The step ran.
    completed: ToolResult,
    /// Policy refused. The decision says why.
    denied: Decision,
    /// A person must answer before the step can run.
    waiting_for_person: approval_mod.Prompt,
};

pub const Options = struct {
    label: []const u8 = "agent",
    provider: []const u8 = "local",
    model: []const u8 = "unset",
    model_version: ?[]const u8 = null,
};

pub const Agent = struct {
    arena: std.mem.Allocator,
    id: idmod.AgentId,
    actor: event_mod.Actor,
    session: idmod.SessionId,
    log: *log_mod.Log,
    engine: *policy_mod.Engine,
    executor: Executor,
    options: Options,
    ids: idmod.Generator,
    clock: Timestamp,
    /// The event that started this run; everything it causes points back here.
    correlation: ?idmod.EventId = null,
    started_event: ?idmod.EventId = null,
    started_at: Timestamp,
    /// The step waiting on a person, if any.
    pending: ?Pending = null,
    steps_run: usize = 0,
    steps_denied: usize = 0,

    pub const Pending = struct {
        step: Step,
        decision: Decision,
        approval_id: idmod.DecisionId,
        prompt: approval_mod.Prompt,
    };

    pub fn init(
        arena: std.mem.Allocator,
        log: *log_mod.Log,
        engine: *policy_mod.Engine,
        executor: Executor,
        session: idmod.SessionId,
        actor: event_mod.Actor,
        id: idmod.AgentId,
        clock: Timestamp,
        options: Options,
    ) Agent {
        return .{
            .arena = arena,
            .id = id,
            .actor = actor,
            .session = session,
            .log = log,
            .engine = engine,
            .executor = executor,
            .options = options,
            .ids = idmod.Generator.init(@bitCast(clock.ns ^ 0x5a5a), @divFloor(clock.ns, timeutil.ns_per_ms)),
            .clock = clock,
            .started_at = clock,
        };
    }

    pub fn tick(self: *Agent, delta: timeutil.Duration) void {
        self.clock = self.clock.addNanos(delta.ns);
    }

    /// Record the request that started this run. The returned identifier is the
    /// correlation for everything the agent does next.
    pub fn start(self: *Agent, request: []const u8, caused_by: ?idmod.EventId) !idmod.EventId {
        const envelope = try self.log.append(.{ .agent_started = .{
            .agent = self.id,
            .session = self.session,
            .request = request,
            .provider = self.options.provider,
            .model = self.options.model,
            .policy = self.engine.policy.id,
        } }, .{
            .at = self.clock,
            .actor = self.actor,
            .causedBy = caused_by,
            .correlation = caused_by,
        });
        self.started_event = envelope.id;
        self.correlation = caused_by orelse envelope.id;
        return envelope.id;
    }

    pub fn say(self: *Agent, role: anytype, text: []const u8) !void {
        _ = try self.log.append(.{ .agent_message = .{
            .agent = self.id,
            .session = self.session,
            .role = role,
            .text = text,
        } }, .{
            .at = self.clock,
            .actor = self.actor,
            .causedBy = self.started_event,
            .correlation = self.correlation,
        });
    }

    /// Announce the plan before doing anything. A person can stop it here.
    pub fn announce(self: *Agent, plan: Plan) !void {
        var aw: std.Io.Writer.Allocating = .init(self.arena);
        try aw.writer.print("I will {s}. ", .{plan.goal});
        try aw.writer.print("There are {d} steps:", .{plan.steps.len});
        for (plan.steps) |step| try aw.writer.print("\n  - {s}", .{step.description});
        try self.say(.plan, aw.written());
    }

    /// Try one step. This is where policy is applied.
    pub fn perform(self: *Agent, step: Step) !StepOutcome {
        const request = step.request;
        const resource = try request.resource(self.arena);
        const context: policy_mod.Context = .{
            .actor = self.actor.id,
            .session = self.session,
            .agent = self.id,
            .agent_name = self.options.label,
            .now = self.clock,
        };

        var decision = try self.engine.decide(.{ .capability = request.capability(), .resource = resource }, context);
        // A request that also needs a second capability is only allowed when
        // both are allowed. The stricter answer wins.
        if (request.additionalCapability()) |extra| {
            const second = try self.engine.decide(.{ .capability = extra, .resource = resource }, context);
            if (second.effect != .allow) decision = second;
        }

        switch (decision.effect) {
            .allow => return .{ .completed = try self.run(step, decision) },
            .deny => {
                try self.recordDenied(step, decision);
                self.steps_denied += 1;
                return .{ .denied = decision };
            },
            .require_human => {
                const prompt = try approval_mod.build(self.arena, decision, self.options.label);
                const approval_id = self.ids.next(idmod.DecisionId);
                _ = try self.log.append(.{ .approval_requested = .{
                    .approval = approval_id,
                    .session = self.session,
                    .agent = self.id,
                    .capability = request.capability().text(),
                    .resource = resource.text(),
                    .promptText = try prompt.toText(self.arena),
                    .policy = decision.policy_id,
                } }, .{
                    .at = self.clock,
                    .actor = self.actor,
                    .causedBy = self.started_event,
                    .correlation = self.correlation,
                });
                self.pending = .{ .step = step, .decision = decision, .approval_id = approval_id, .prompt = prompt };
                return .{ .waiting_for_person = prompt };
            },
        }
    }

    /// Record a person's answer and continue, or stop.
    pub fn answer(self: *Agent, given: approval_mod.Answer) !StepOutcome {
        const pending = self.pending orelse return error.NothingWaiting;
        self.pending = null;

        _ = try self.log.append(.{ .approval_resolved = .{
            .approval = pending.approval_id,
            .session = self.session,
            .outcome = switch (given.outcome) {
                .allow_once => .allow_once,
                .allow_always_here => .allow_always_here,
                .deny => .deny,
            },
            .decidedBy = given.decided_by,
            .note = given.note,
        } }, .{
            .at = self.clock,
            .actor = self.actor,
            .causedBy = self.started_event,
            .correlation = self.correlation,
        });

        if (given.outcome == .allow_always_here) {
            try self.engine.grant(.{
                .capability = pending.decision.request.capability,
                .resource = pending.decision.request.resource,
                .session = self.session,
                .granted_by = given.decided_by,
                .granted_at = given.decided_at,
            });
        }

        if (!given.allowsOperation()) {
            try self.recordDenied(pending.step, pending.decision);
            self.steps_denied += 1;
            return .{ .denied = pending.decision };
        }
        return .{ .completed = try self.run(pending.step, pending.decision) };
    }

    fn run(self: *Agent, step: Step, decision: Decision) !ToolResult {
        const request = step.request;
        const resource = try request.resource(self.arena);
        const call = self.ids.next(idmod.ToolCallId);

        var arguments: std.Io.Writer.Allocating = .init(self.arena);
        try std.json.Stringify.value(request, .{}, &arguments.writer);

        const requested = try self.log.append(.{ .tool_requested = .{
            .call = call,
            .agent = self.id,
            .session = self.session,
            .tool = request.toolName(),
            .capability = request.capability().text(),
            .argumentsJson = arguments.written(),
            .resource = resource.text(),
        } }, .{
            .at = self.clock,
            .actor = self.actor,
            .causedBy = self.started_event,
            .correlation = self.correlation,
        });

        const before = self.clock;
        const result = self.executor.execute(self.arena, request) catch |err| ToolResult{
            .outcome = .failed,
            .summary = try std.fmt.allocPrint(self.arena, "The tool could not finish: {s}.", .{@errorName(err)}),
        };
        self.clock = self.clock.addNanos(result.duration.ns);

        _ = try self.log.append(.{ .tool_finished = .{
            .call = call,
            .agent = self.id,
            .session = self.session,
            .outcome = switch (result.outcome) {
                .completed => .completed,
                .failed => .failed,
                .denied => .denied,
                .cancelled => .cancelled,
                .timed_out => .timed_out,
            },
            .duration = self.clock.since(before),
            .resultHash = result.contentHash,
            .summary = if (result.summary.len > 0) result.summary else step.description,
        } }, .{
            .at = self.clock,
            .actor = self.actor,
            .causedBy = requested.id,
            .correlation = self.correlation,
        });

        // A write is also a file change, which is what the interface shows.
        switch (request) {
            .write_file => |w| _ = try self.log.append(.{ .file_changed = .{
                .session = self.session,
                .path = w.path,
                .changeKind = .modified,
                .afterHash = w.contentHash,
                .agent = self.id,
            } }, .{
                .at = self.clock,
                .actor = self.actor,
                .causedBy = requested.id,
                .correlation = self.correlation,
            }),
            .delete => |d| _ = try self.log.append(.{ .file_changed = .{
                .session = self.session,
                .path = d.path,
                .changeKind = .deleted,
                .agent = self.id,
            } }, .{
                .at = self.clock,
                .actor = self.actor,
                .causedBy = requested.id,
                .correlation = self.correlation,
            }),
            else => {},
        }

        _ = decision;
        self.steps_run += 1;
        return result;
    }

    fn recordDenied(self: *Agent, step: Step, decision: Decision) !void {
        const request = step.request;
        const resource = try request.resource(self.arena);
        const call = self.ids.next(idmod.ToolCallId);

        const requested = try self.log.append(.{ .tool_requested = .{
            .call = call,
            .agent = self.id,
            .session = self.session,
            .tool = request.toolName(),
            .capability = request.capability().text(),
            .argumentsJson = "{}",
            .resource = resource.text(),
        } }, .{
            .at = self.clock,
            .actor = self.actor,
            .causedBy = self.started_event,
            .correlation = self.correlation,
        });

        _ = try self.log.append(.{ .tool_finished = .{
            .call = call,
            .agent = self.id,
            .session = self.session,
            .outcome = .denied,
            .duration = .{ .ns = 0 },
            .resultHash = hashing.Hash.zero,
            .summary = decision.reason,
        } }, .{
            .at = self.clock,
            .actor = self.actor,
            .causedBy = requested.id,
            .correlation = self.correlation,
        });
    }

    /// Run a whole plan, stopping at the first step that needs a person.
    pub fn runPlan(self: *Agent, plan: Plan) !?approval_mod.Prompt {
        for (plan.steps) |step| {
            switch (try self.perform(step)) {
                .completed => {},
                .denied => {},
                .waiting_for_person => |prompt| return prompt,
            }
        }
        return null;
    }

    /// The provenance record for whatever this run produced.
    pub fn provenance(self: Agent, content_hash: hashing.Hash, activity: []const u8) provenance_mod.Provenance {
        return .{
            .producer = self.actor.id,
            .producer_kind = .agent,
            .source_events = if (self.started_event) |e| &.{e} else &.{},
            .model = .{
                .provider = self.options.provider,
                .model = self.options.model,
                .version = self.options.model_version,
            },
            .environment = provenance_mod.EnvironmentFingerprint.current(),
            .started_at = self.started_at,
            .completed_at = self.clock,
            .content_hash = content_hash,
            .activity = activity,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const graph_mod = @import("../events/graph.zig");

/// An executor that records what it was asked to do and always succeeds. Real
/// executors run processes; this one keeps the runtime tests about the runtime.
const RecordingExecutor = struct {
    calls: std.ArrayList([]const u8) = .empty,
    arena: std.mem.Allocator,

    fn execute(ptr: *anyopaque, arena: std.mem.Allocator, request: ToolRequest) anyerror!ToolResult {
        const self: *RecordingExecutor = @ptrCast(@alignCast(ptr));
        try self.calls.append(self.arena, request.toolName());
        return .{
            .outcome = .completed,
            .contentHash = hashing.Hash.of(request.toolName()),
            .duration = timeutil.Duration.fromMillis(120),
            .summary = try std.fmt.allocPrint(arena, "Ran {s}.", .{request.toolName()}),
        };
    }

    fn executor(self: *RecordingExecutor) Executor {
        return .{ .ptr = self, .executeFn = execute };
    }
};

test "an agent run is one causal graph with policy applied at every step" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(301, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 302);
    const person: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "sean" };
    const robot: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .agent, .label = "agent 3" };
    const session = gen.next(idmod.SessionId);
    const now = try Timestamp.parseIso("2026-09-04T20:00:00Z");

    var engine = policy_mod.Engine.init(arena, try policy_mod.repositoryWriteNoNetwork("/home/user/zag", arena), 303);
    var recording: RecordingExecutor = .{ .arena = arena };

    const request_event = try log.append(.{ .user_message = .{ .session = session, .text = "fix the parser and run the tests" } }, .{ .at = now, .actor = person });

    var agent = Agent.init(arena, &log, &engine, recording.executor(), session, robot, gen.next(idmod.AgentId), now, .{
        .label = "agent 3",
        .provider = "local",
        .model = "coder-small",
    });
    _ = try agent.start("fix the parser and run the tests", request_event.id);

    const plan: Plan = .{
        .goal = "fix the parser and show that the tests pass",
        .steps = &.{
            .{ .description = "Read the parser.", .request = .{ .read_file = .{ .path = "/home/user/zag/src/parser.zig" } } },
            .{ .description = "Write the fix.", .request = .{ .write_file = .{
                .path = "/home/user/zag/src/parser.zig",
                .contentHash = hashing.Hash.of("fixed"),
                .byteCount = 120,
            } } },
            .{ .description = "Run the tests.", .request = .{ .execute = .{
                .argv = &.{ "zig", "build", "test" },
                .workingDirectory = "/home/user/zag",
            } } },
            .{ .description = "Fetch the upstream changelog.", .request = .{ .execute = .{
                .argv = &.{ "curl", "https://example.test/changelog" },
                .workingDirectory = "/home/user/zag",
                .network = .any,
            } } },
        },
    };
    try agent.announce(plan);
    const waiting = try agent.runPlan(plan);
    try testing.expect(waiting == null);

    try testing.expectEqual(@as(usize, 3), agent.steps_run);
    try testing.expectEqual(@as(usize, 1), agent.steps_denied);
    try testing.expectEqual(@as(usize, 3), recording.calls.items.len);

    // The whole run is one graph, and its summary reads as one sentence.
    const graph = try graph_mod.Graph.build(arena, log);
    const run = try graph.run(request_event.id);
    const summary = graph.summarise(run.items);
    try testing.expectEqual(@as(usize, 1), summary.denied_tool_calls);
    try testing.expectEqual(@as(usize, 4), summary.tool_calls);
    try testing.expectEqual(@as(usize, 1), summary.files_changed);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try summary.writeSentence(&aw.writer);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "1 tool call denied by policy") != null);

    try testing.expect((try log.verify()) == null);
}

test "a step that needs a person stops the run until they answer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(304, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 305);
    const person = gen.next(idmod.ActorId);
    const robot: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .agent, .label = "agent 3" };
    const session = gen.next(idmod.SessionId);
    const now = try Timestamp.parseIso("2026-09-04T20:00:00Z");

    var engine = policy_mod.Engine.init(arena, try policy_mod.repositoryWriteNoNetwork("/home/user/zag", arena), 306);
    var recording: RecordingExecutor = .{ .arena = arena };
    var agent = Agent.init(arena, &log, &engine, recording.executor(), session, robot, gen.next(idmod.AgentId), now, .{ .label = "agent 3" });
    _ = try agent.start("clean the build folder", null);

    const step: Step = .{
        .description = "Delete the build folder.",
        .request = .{ .delete = .{ .path = "/home/user/zag/build", .recursive = true } },
    };

    const outcome = try agent.perform(step);
    const prompt = outcome.waiting_for_person;
    try testing.expectEqualStrings("Delete /home/user/zag/build?", prompt.question);
    try testing.expectEqual(@as(usize, 0), recording.calls.items.len);

    const after = try agent.answer(.{
        .outcome = .allow_always_here,
        .decided_by = person,
        .decided_at = now,
        .note = "The build folder is disposable.",
    });
    try testing.expect(after.completed.succeeded());
    try testing.expectEqual(@as(usize, 1), recording.calls.items.len);

    // The standing permission answers the next identical request without asking.
    const again = try agent.perform(step);
    try testing.expect(again == .completed);
    try testing.expectEqual(@as(usize, 2), recording.calls.items.len);
}

test "a refused approval is recorded and the agent carries on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(307, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 308);
    const person = gen.next(idmod.ActorId);
    const robot: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .agent };
    const session = gen.next(idmod.SessionId);
    const now = try Timestamp.parseIso("2026-09-04T20:00:00Z");

    var engine = policy_mod.Engine.init(arena, try policy_mod.repositoryWriteNoNetwork("/home/user/zag", arena), 309);
    var recording: RecordingExecutor = .{ .arena = arena };
    var agent = Agent.init(arena, &log, &engine, recording.executor(), session, robot, gen.next(idmod.AgentId), now, .{});
    _ = try agent.start("tidy up", null);

    _ = try agent.perform(.{ .description = "Delete the cache.", .request = .{ .delete = .{ .path = "/home/user/zag/.cache" } } });
    const refused = try agent.answer(.{ .outcome = .deny, .decided_by = person, .decided_at = now, .note = "I need that." });
    try testing.expect(refused == .denied);
    try testing.expectEqual(@as(usize, 0), recording.calls.items.len);

    var found_resolution = false;
    for (log.entries.items) |entry| {
        switch (entry.payload) {
            .approval_resolved => |r| {
                found_resolution = true;
                try testing.expectEqualStrings("I need that.", r.note);
            },
            else => {},
        }
    }
    try testing.expect(found_resolution);
}

test "the run produces provenance a reviewer can act on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(310, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 311);
    const robot: event_mod.Actor = .{ .id = gen.next(idmod.ActorId), .kind = .agent };
    const session = gen.next(idmod.SessionId);
    const now = try Timestamp.parseIso("2026-09-04T20:00:00Z");

    var engine = policy_mod.Engine.init(arena, try policy_mod.repositoryWriteNoNetwork("/repo", arena), 312);
    var recording: RecordingExecutor = .{ .arena = arena };
    var agent = Agent.init(arena, &log, &engine, recording.executor(), session, robot, gen.next(idmod.AgentId), now, .{
        .provider = "anthropic",
        .model = "claude-opus-5",
        .model_version = "2026-08",
    });
    _ = try agent.start("write the patch", null);
    agent.tick(timeutil.Duration.fromSeconds(31));

    const record = agent.provenance(hashing.Hash.of("patch"), "write the parser patch");
    try testing.expect(record.wasAutomated());
    try testing.expectEqualStrings("claude-opus-5", record.model.?.model);
    try testing.expectEqual(@as(i64, 31), record.duration().seconds());
    try testing.expect(record.completeness().has_model);
    try testing.expect(record.completeness().has_sources);
}
