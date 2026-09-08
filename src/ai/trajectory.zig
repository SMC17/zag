//! The record, read as trajectories.
//!
//! A workspace that has been used for a month holds hundreds of agent runs,
//! each one a task, a sequence of decisions and actions, the result of every
//! action, and how it ended. That is the shape a trajectory has — and nothing
//! could read it out, so the most valuable thing this project accumulates was
//! only ever readable one run at a time by a person.
//!
//! ## What comes out
//!
//! One JSON object per run, one run per line. Each holds the task, the model
//! that did it, an ordered list of steps, and the score from
//! `ai/outcome.zig`. A step is what an agent does: a thought, an action with
//! its arguments and the capability it needed, and the observation that came
//! back — the real bytes, fetched from the content store by the hash the log
//! recorded, not a summary of them.
//!
//! That is enough to fine-tune on, to score a change against, to replay, or to
//! read. It is deliberately not a format from any particular training
//! framework: those disagree with each other and change, and a conversion from
//! this is a short script, while a conversion back from a lossy one is
//! impossible.
//!
//! ## What makes this worth having
//!
//! Most agent frameworks can log a transcript. Three things here are not in a
//! transcript, and each is the thing that makes a trajectory usable rather
//! than merely readable:
//!
//! - **The capability and resource each action needed**, as the policy saw
//!   them. An action labelled with what it was allowed to touch can be
//!   audited, filtered, and learned from differently than one labelled only
//!   with a tool name.
//! - **The refusals.** A run where the workspace said no is the most
//!   interesting kind and the first kind a transcript throws away. Refused
//!   steps are exported with their reason, because a dataset of only the
//!   allowed actions teaches that everything is allowed.
//! - **An outcome derived by arithmetic**, not by a model's opinion, so the
//!   label is reproducible and can be checked against the log it came from.
//!
//! ## Secrets
//!
//! Every byte here has already been through the redactor on its way into the
//! record. Export re-reads what was stored, so there is one redaction, at the
//! boundary where content enters the workspace, rather than a second one here
//! that could disagree with it.

const std = @import("std");
const provider = @import("provider.zig");
const outcome_mod = @import("outcome.zig");
const event_mod = @import("../events/event.zig");
const log_mod = @import("../events/log.zig");
const content_store_mod = @import("../events/content_store.zig");
const idmod = @import("../core/id.zig");
const hashing = @import("../core/hash.zig");

/// What an agent did at one point in a run.
pub const Step = union(enum) {
    /// The model said something.
    said: []const u8,
    /// The model asked to act, and what happened.
    acted: Action,
    /// Room was made in the conversation. Kept because a trajectory that
    /// silently omits it cannot explain why the model appears to forget.
    compacted: []const u8,
};

pub const Action = struct {
    tool: []const u8,
    /// The capability the policy decided about, and what it was scoped to.
    capability: []const u8,
    resource: []const u8,
    argumentsJson: []const u8,
    outcome: []const u8,
    /// What came back. The bytes, by the address the log recorded.
    observation: []const u8,
    /// Set when the bytes could not be fetched: the store was pruned, or the
    /// run predates results being stored at all.
    observationMissing: bool = false,
    summary: []const u8,
};

pub const Trajectory = struct {
    agent: idmod.AgentId,
    task: []const u8,
    model: []const u8,
    connector: []const u8,
    steps: []const Step,
    score: outcome_mod.Score,

    /// One line of JSON, the shape every tool that reads datasets expects.
    pub fn writeJsonLine(self: Trajectory, w: *std.Io.Writer) !void {
        try w.writeAll("{\"task\":");
        try provider.writeJsonString(w, self.task);
        try w.writeAll(",\"model\":");
        try provider.writeJsonString(w, self.model);
        try w.writeAll(",\"connector\":");
        try provider.writeJsonString(w, self.connector);
        try w.print(",\"ending\":\"{s}\"", .{@tagName(self.score.ending)});
        try w.print(",\"reward\":{d:.4}", .{self.score.reward()});
        try w.print(",\"toolCalls\":{d},\"succeeded\":{d},\"refused\":{d},\"repeated\":{d}", .{
            self.score.toolCalls,
            self.score.succeeded,
            self.score.refused,
            self.score.repeated,
        });
        try w.print(",\"inputTokens\":{d},\"outputTokens\":{d}", .{
            self.score.inputTokens,
            self.score.outputTokens,
        });

        try w.writeAll(",\"steps\":[");
        for (self.steps, 0..) |step, i| {
            if (i > 0) try w.writeAll(",");
            switch (step) {
                .said => |text| {
                    try w.writeAll("{\"kind\":\"said\",\"text\":");
                    try provider.writeJsonString(w, text);
                    try w.writeAll("}");
                },
                .compacted => |text| {
                    try w.writeAll("{\"kind\":\"compacted\",\"note\":");
                    try provider.writeJsonString(w, text);
                    try w.writeAll("}");
                },
                .acted => |a| {
                    try w.writeAll("{\"kind\":\"acted\",\"tool\":");
                    try provider.writeJsonString(w, a.tool);
                    try w.writeAll(",\"capability\":");
                    try provider.writeJsonString(w, a.capability);
                    try w.writeAll(",\"resource\":");
                    try provider.writeJsonString(w, a.resource);
                    try w.writeAll(",\"arguments\":");
                    try provider.writeJsonString(w, a.argumentsJson);
                    try w.print(",\"outcome\":\"{s}\"", .{a.outcome});
                    try w.writeAll(",\"summary\":");
                    try provider.writeJsonString(w, a.summary);
                    try w.writeAll(",\"observation\":");
                    try provider.writeJsonString(w, a.observation);
                    if (a.observationMissing) try w.writeAll(",\"observationMissing\":true");
                    try w.writeAll("}");
                },
            }
        }
        try w.writeAll("]}");
    }
};

/// Read every run in a log as a trajectory.
pub fn extract(
    arena: std.mem.Allocator,
    io: std.Io,
    log: log_mod.Log,
    store: content_store_mod.Store,
) ![]const Trajectory {
    const scores = try outcome_mod.scoreAll(arena, log);

    var out: std.ArrayList(Trajectory) = .empty;
    var index: std.AutoArrayHashMapUnmanaged([16]u8, usize) = .empty;
    var steps: std.ArrayList(std.ArrayList(Step)) = .empty;
    // A call's tool and capability are on the request and its result on the
    // finish, so they are carried across.
    var open: std.AutoArrayHashMapUnmanaged([16]u8, Action) = .empty;

    for (log.entries.items) |entry| switch (entry.payload) {
        .agent_started => |e| {
            try index.put(arena, e.agent.raw.bytes, out.items.len);
            try steps.append(arena, .empty);
            try out.append(arena, .{
                .agent = e.agent,
                .task = e.request,
                .model = e.model,
                .connector = e.provider,
                .steps = &.{},
                .score = scoreFor(scores, e.agent),
            });
        },
        .agent_message => |e| {
            const at = index.get(e.agent.raw.bytes) orelse continue;
            try steps.items[at].append(arena, if (e.role == .workspace)
                .{ .compacted = e.text }
            else
                .{ .said = e.text });
        },
        .tool_requested => |e| {
            try open.put(arena, e.call.raw.bytes, .{
                .tool = e.tool,
                .capability = e.capability,
                .resource = e.resource,
                .argumentsJson = e.argumentsJson,
                .outcome = "",
                .observation = "",
                .summary = "",
            });
        },
        .tool_finished => |e| {
            const at = index.get(e.agent.raw.bytes) orelse continue;
            var action = open.get(e.call.raw.bytes) orelse Action{
                .tool = "",
                .capability = "",
                .resource = "",
                .argumentsJson = "",
                .outcome = "",
                .observation = "",
                .summary = "",
            };
            action.outcome = @tagName(e.outcome);
            action.summary = e.summary;

            if (e.resultBytes > 0 and !e.resultHash.eql(hashing.Hash.zero)) {
                if (store.read(io, e.resultHash, 8 << 20)) |bytes| {
                    action.observation = bytes;
                } else |_| {
                    action.observationMissing = true;
                }
            } else {
                // A refused call produced nothing, which is not the same as
                // its output being lost. Runs recorded before results were
                // stored land here too.
                action.observationMissing = e.outcome == .completed;
            }
            try steps.items[at].append(arena, .{ .acted = action });
        },
        else => {},
    };

    for (out.items, 0..) |*trajectory, at| trajectory.steps = steps.items[at].items;
    return out.items;
}

fn scoreFor(scores: []const outcome_mod.Score, agent: idmod.AgentId) outcome_mod.Score {
    for (scores) |score| {
        if (score.agent.eql(agent)) return score;
    }
    return .{ .agent = agent };
}

/// Write every trajectory as JSON Lines.
pub fn writeJsonLines(trajectories: []const Trajectory, w: *std.Io.Writer) !void {
    for (trajectories) |trajectory| {
        try trajectory.writeJsonLine(w);
        try w.writeByte('\n');
    }
}

const testing = std.testing;

const Builder = struct {
    arena: std.mem.Allocator,
    log: log_mod.Log,
    store: content_store_mod.Store,
    agent: idmod.AgentId,
    session: idmod.SessionId,
    ids: idmod.Generator,

    fn init(arena: std.mem.Allocator, root: []const u8) Builder {
        var ids = idmod.Generator.init(3, 1_788_000_000_000);
        return .{
            .arena = arena,
            .log = log_mod.Log.init(arena, 13),
            .store = content_store_mod.Store.init(arena, root),
            .agent = ids.next(idmod.AgentId),
            .session = ids.next(idmod.SessionId),
            .ids = ids,
        };
    }

    fn actor() event_mod.Actor {
        return .{ .kind = .agent, .id = .{ .raw = .{ .bytes = @splat(5) } }, .label = "an agent" };
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

    fn said(self: *Builder, text: []const u8) !void {
        _ = try self.log.append(.{ .agent_message = .{
            .agent = self.agent,
            .session = self.session,
            .role = .plan,
            .text = text,
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });
    }

    fn acted(
        self: *Builder,
        tool: []const u8,
        capability: []const u8,
        resource: []const u8,
        result: ?[]const u8,
        outcome: anytype,
    ) !void {
        const id = self.ids.next(idmod.ToolCallId);
        _ = try self.log.append(.{ .tool_requested = .{
            .call = id,
            .agent = self.agent,
            .session = self.session,
            .tool = tool,
            .capability = capability,
            .argumentsJson = "{\"path\":\"a.zig\"}",
            .resource = resource,
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });

        var hash = hashing.Hash.zero;
        var bytes: usize = 0;
        if (result) |data| {
            hash = try self.store.put(data);
            bytes = data.len;
        }
        _ = try self.log.append(.{ .tool_finished = .{
            .call = id,
            .agent = self.agent,
            .session = self.session,
            .outcome = outcome,
            .duration = .{ .ns = 0 },
            .resultHash = hash,
            .resultBytes = bytes,
            .summary = "a summary",
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });
    }

    fn ended(self: *Builder) !void {
        _ = try self.log.append(.{ .agent_finished = .{
            .agent = self.agent,
            .session = self.session,
            .outcome = .answered,
            .duration = .{ .ns = 0 },
            .inputTokens = 500,
            .outputTokens = 60,
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });
    }
};

test "a run comes out as a task, its steps, and what it achieved" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = ".zig-cache/tmp/trajectory-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    var builder = Builder.init(arena, root);
    try builder.started("make the tests pass");
    try builder.said("I will read the file first.");
    try builder.acted("read_file", "fs.read", "src/main.zig", "const std = @import(\"std\");\n", .completed);
    try builder.ended();
    try builder.store.flush(io);

    const runs = try extract(arena, io, builder.log, builder.store);
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqualStrings("make the tests pass", runs[0].task);
    try testing.expectEqual(@as(usize, 2), runs[0].steps.len);
    try testing.expectEqualStrings("I will read the file first.", runs[0].steps[0].said);

    // The observation is the bytes the tool produced, fetched by the address
    // the log recorded — not a summary of them. A trajectory whose
    // observations are summaries cannot be trained on or replayed.
    const action = runs[0].steps[1].acted;
    try testing.expectEqualStrings("const std = @import(\"std\");\n", action.observation);
    try testing.expect(!action.observationMissing);

    // And what the policy decided about, which is the part a transcript does
    // not have: an action labelled with what it was allowed to touch can be
    // audited and filtered, one labelled only with a tool name cannot.
    try testing.expectEqualStrings("fs.read", action.capability);
    try testing.expectEqualStrings("src/main.zig", action.resource);
    try testing.expect(runs[0].score.reward() > 0.9);
}

test "a refused action is exported, not dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = ".zig-cache/tmp/trajectory-refused";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    var builder = Builder.init(arena, root);
    try builder.started("delete everything");
    try builder.acted("delete", "fs.delete", "src/", null, .denied);
    try builder.ended();

    const runs = try extract(arena, io, builder.log, builder.store);
    const action = runs[0].steps[0].acted;

    // A run the workspace said no to is the most interesting kind, and the
    // first kind a transcript throws away. A dataset of only the allowed
    // actions teaches that everything is allowed.
    try testing.expectEqualStrings("denied", action.outcome);
    try testing.expectEqualStrings("fs.delete", action.capability);
    // A refusal produced nothing, which is not the same as its output being
    // lost.
    try testing.expect(!action.observationMissing);
    try testing.expectEqual(@as(usize, 1), runs[0].score.refused);
}

test "output that is no longer in the store says so rather than reading as empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var builder = Builder.init(arena, ".zig-cache/tmp/trajectory-missing");
    try builder.started("a job");
    // Recorded, never flushed: a pruned store, or a run from before results
    // were kept at all.
    try builder.acted("read_file", "fs.read", "a.zig", "bytes that never landed", .completed);
    try builder.ended();

    const runs = try extract(arena, io, builder.log, builder.store);
    const action = runs[0].steps[0].acted;
    try testing.expect(action.observationMissing);
    try testing.expectEqual(@as(usize, 0), action.observation.len);
}

test "the exported line is JSON, and holds what a dataset needs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = ".zig-cache/tmp/trajectory-json";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    var builder = Builder.init(arena, root);
    try builder.started("a task with \"quotes\" and a\nnewline");
    // Output with bytes that are not valid UTF-8, because a tool's output is
    // whatever the program wrote and a dataset line has to survive it.
    try builder.acted("run_command", "process.execute", "zig build", "output \xff\xfe here", .completed);
    try builder.ended();
    try builder.store.flush(io);

    const runs = try extract(arena, io, builder.log, builder.store);
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeJsonLines(runs, &out.writer);

    const written = out.written();
    const line = written[0 .. written.len - 1];
    try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, line, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqualStrings("a task with \"quotes\" and a\nnewline", object.get("task").?.string);
    try testing.expectEqualStrings("answered", object.get("ending").?.string);
    try testing.expect(object.get("reward").?.float > 0.9);
    try testing.expectEqual(@as(usize, 1), object.get("steps").?.array.items.len);

    const step = object.get("steps").?.array.items[0].object;
    try testing.expectEqualStrings("process.execute", step.get("capability").?.string);
    try testing.expect(step.get("observation").?.string.len > 0);
}

test "runs are exported separately, each with its own score" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = ".zig-cache/tmp/trajectory-many";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    var builder = Builder.init(arena, root);
    try builder.started("the good one");
    try builder.acted("read_file", "fs.read", "a.zig", "contents", .completed);
    try builder.ended();

    builder.agent = builder.ids.next(idmod.AgentId);
    try builder.started("the circling one");
    for (0..4) |_| try builder.acted("read_file", "fs.read", "a.zig", "contents", .completed);
    try builder.ended();
    try builder.store.flush(io);

    const runs = try extract(arena, io, builder.log, builder.store);
    try testing.expectEqual(@as(usize, 2), runs.len);
    try testing.expectEqualStrings("the good one", runs[0].task);
    try testing.expectEqual(@as(usize, 1), runs[0].steps.len);
    try testing.expectEqual(@as(usize, 4), runs[1].steps.len);

    // Every step succeeded in both, and the one that went in circles still
    // scores lower — which is the whole reason the score is not just a
    // success rate.
    try testing.expect(runs[0].score.reward() > runs[1].score.reward());
    try testing.expectEqual(@as(usize, 3), runs[1].score.repeated);
}
