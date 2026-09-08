//! Rebuilding a conversation from the record.
//!
//! A run that stopped — out of turns, waiting for a person, a provider that
//! stayed down — left everything it did in the log: the task, what the model
//! said, every tool it asked for, every result that came back, and the address
//! of the bytes. Nothing could read that back into a conversation, so the only
//! way to continue was to start again and pay for the same work twice.
//!
//! ## Why this belongs in the log rather than a session file
//!
//! The usual way to make an agent resumable is to serialise its conversation
//! to a side file. That file then has to be kept in step with the record, and
//! when the two disagree there is no way to tell which one is lying. Here the
//! log is already the complete account — it was built to be — so the
//! conversation is derived from it rather than stored beside it. There is one
//! source of truth and it is the one that is hash-chained.
//!
//! ## What is faithful and what is not
//!
//! Reconstruction is exact for the parts the record holds exactly: the task,
//! the model's text, each tool call with its typed arguments, and each result,
//! whose bytes are fetched from the content store by the hash the log
//! recorded. `verify` checks those hashes, so a rebuilt conversation is
//! provably the one that happened.
//!
//! Two things are not recovered, and saying so matters more than papering
//! over them:
//!
//! - **Reasoning.** Thinking blocks are not written to the log. A resumed run
//!   continues without the model's earlier reasoning, which is the same
//!   position a model is in when a provider drops thinking across a turn.
//! - **What compaction removed.** If the original run made room, the model saw
//!   a trimmed conversation. The log still holds the full results, so a resume
//!   rebuilds *more* than the original had. That is a difference, and
//!   `Rebuilt.compactions` reports it rather than letting a replay quietly
//!   diverge from the run it claims to reproduce.

const std = @import("std");
const provider = @import("provider.zig");
const event_mod = @import("../events/event.zig");
const log_mod = @import("../events/log.zig");
const content_store_mod = @import("../events/content_store.zig");
const idmod = @import("../core/id.zig");
const hashing = @import("../core/hash.zig");

pub const Error = error{
    /// No run with that identifier is in this log.
    NoSuchRun,
} || std.mem.Allocator.Error;

/// A conversation rebuilt from the record, and what is known about its
/// faithfulness.
pub const Rebuilt = struct {
    agent: idmod.AgentId,
    /// What was originally asked for.
    task: []const u8,
    model: []const u8,
    connector: []const u8,
    messages: []const provider.Message,
    /// Whether the original run reached an ending, and which.
    ending: ?[]const u8 = null,
    /// Tool results whose bytes could not be fetched from the store.
    ///
    /// A resume still works without them — the call and its summary are in the
    /// log — but the model gets the summary where it once had the output, and
    /// a caller that cares should say so rather than pretend.
    missingResults: usize = 0,
    /// How many times the original run made room. Non-zero means the model saw
    /// less than this rebuild holds.
    compactions: usize = 0,

    pub fn canContinue(self: Rebuilt) bool {
        return self.messages.len > 0;
    }

    pub fn writeSentence(self: Rebuilt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} messages rebuilt from the record", .{self.messages.len});
        if (self.missingResults > 0) {
            try w.print(", {d} tool result{s} no longer in the store", .{
                self.missingResults,
                if (self.missingResults == 1) "" else "s",
            });
        }
        if (self.compactions > 0) {
            try w.print(". The original run made room {d} time{s}, so it saw less than this", .{
                self.compactions,
                if (self.compactions == 1) "" else "s",
            });
        }
        try w.writeAll(".");
    }
};

/// The runs in a log, newest last.
pub fn runsIn(arena: std.mem.Allocator, log: log_mod.Log) ![]const idmod.AgentId {
    var out: std.ArrayList(idmod.AgentId) = .empty;
    for (log.entries.items) |entry| {
        switch (entry.payload) {
            .agent_started => |e| try out.append(arena, e.agent),
            else => {},
        }
    }
    return out.items;
}

/// Rebuild the newest run in a log.
pub fn latest(
    arena: std.mem.Allocator,
    io: std.Io,
    log: log_mod.Log,
    store: content_store_mod.Store,
) Error!Rebuilt {
    var newest: ?idmod.AgentId = null;
    for (log.entries.items) |entry| {
        switch (entry.payload) {
            .agent_started => |e| newest = e.agent,
            else => {},
        }
    }
    return rebuild(arena, io, log, store, newest orelse return error.NoSuchRun);
}

/// Rebuild one run into the conversation the model was holding.
///
/// Walked in log order, which is the order things happened. A tool call and
/// its result are separate events, so the assistant's calls for one turn are
/// gathered until a result arrives, then flushed as one assistant message
/// followed by one user message of results — which is the shape every provider
/// expects and the shape the original run sent.
pub fn rebuild(
    arena: std.mem.Allocator,
    io: std.Io,
    log: log_mod.Log,
    store: content_store_mod.Store,
    agent: idmod.AgentId,
) Error!Rebuilt {
    var out: Rebuilt = .{
        .agent = agent,
        .task = "",
        .model = "",
        .connector = "",
        .messages = &.{},
    };

    var messages: std.ArrayList(provider.Message) = .empty;
    var pending_calls: std.ArrayList(provider.Block) = .empty;
    var pending_results: std.ArrayList(provider.Block) = .empty;
    var found = false;

    // A call's arguments are on `tool_requested` and its result on
    // `tool_finished`, so the name and identifier are carried across.
    var call_names: std.AutoArrayHashMapUnmanaged([16]u8, []const u8) = .empty;

    for (log.entries.items) |entry| {
        switch (entry.payload) {
            .agent_started => |e| {
                if (!e.agent.eql(agent)) continue;
                found = true;
                out.task = e.request;
                out.model = e.model;
                out.connector = e.provider;
                try messages.append(arena, .{
                    .role = .user,
                    .blocks = try oneBlock(arena, .{ .text = e.request }),
                });
            },
            .agent_message => |e| {
                if (!e.agent.eql(agent)) continue;
                // The workspace talking about the run, not the model talking
                // in it. It never went to a provider, so it does not come back
                // out — but it is how a rebuild knows the original was
                // trimmed.
                if (e.role == .workspace) {
                    out.compactions += 1;
                    continue;
                }
                try flushCalls(arena, &messages, &pending_calls, &pending_results);
                try messages.append(arena, .{
                    .role = .assistant,
                    .blocks = try oneBlock(arena, .{ .text = e.text }),
                });
            },
            .tool_requested => |e| {
                if (!e.agent.eql(agent)) continue;
                // Results for the previous turn are complete once a new call
                // is asked for.
                if (pending_results.items.len > 0) {
                    try flushCalls(arena, &messages, &pending_calls, &pending_results);
                }
                try call_names.put(arena, e.call.raw.bytes, e.tool);
                try pending_calls.append(arena, .{ .tool_use = .{
                    .id = try callText(arena, e.call),
                    .name = e.tool,
                    .argumentsJson = e.argumentsJson,
                } });
            },
            .tool_finished => |e| {
                if (!e.agent.eql(agent)) continue;
                // The bytes, by the address the log recorded. A hash that does
                // not resolve leaves the summary in its place rather than a
                // gap, and is counted.
                var content = e.summary;
                if (!e.resultHash.eql(hashing.Hash.zero)) {
                    if (store.read(io, e.resultHash, 8 << 20)) |bytes| {
                        content = bytes;
                    } else |_| {
                        out.missingResults += 1;
                    }
                }
                try pending_results.append(arena, .{ .tool_result = .{
                    .toolUseId = try callText(arena, e.call),
                    .content = content,
                    .isError = e.outcome != .completed,
                } });
            },
            .agent_finished => |e| {
                if (!e.agent.eql(agent)) continue;
                out.ending = @tagName(e.outcome);
            },
            else => {},
        }
    }

    if (!found) return error.NoSuchRun;
    try flushCalls(arena, &messages, &pending_calls, &pending_results);
    out.messages = messages.items;
    return out;
}

/// Close off one turn: the calls the model made, then the results that came
/// back, in the two-message shape a provider expects.
fn flushCalls(
    arena: std.mem.Allocator,
    messages: *std.ArrayList(provider.Message),
    calls: *std.ArrayList(provider.Block),
    results: *std.ArrayList(provider.Block),
) !void {
    if (calls.items.len > 0) {
        try messages.append(arena, .{ .role = .assistant, .blocks = calls.items });
        calls.* = .empty;
    }
    if (results.items.len > 0) {
        try messages.append(arena, .{ .role = .user, .blocks = results.items });
        results.* = .empty;
    }
}

/// A call's identifier as the text a provider sees.
///
/// The same identifier the original request carried, so a rebuilt
/// conversation pairs each result with the call it answered exactly as the
/// first run did.
fn callText(arena: std.mem.Allocator, call: idmod.ToolCallId) ![]const u8 {
    var buffer: [@TypeOf(call).text_len]u8 = undefined;
    return arena.dupe(u8, call.toText(&buffer));
}

fn oneBlock(arena: std.mem.Allocator, block: provider.Block) ![]const provider.Block {
    const out = try arena.alloc(provider.Block, 1);
    out[0] = block;
    return out;
}

const testing = std.testing;

/// Build a log holding one finished run, the way the service writes one.
const Recorded = struct {
    arena: std.mem.Allocator,
    log: log_mod.Log,
    store: content_store_mod.Store,
    agent: idmod.AgentId,
    session: idmod.SessionId,
    ids: idmod.Generator,

    fn init(arena: std.mem.Allocator) !Recorded {
        var ids = idmod.Generator.init(7, 1_788_000_000_000);
        return .{
            .arena = arena,
            .log = log_mod.Log.init(arena, 11),
            .store = content_store_mod.Store.init(arena, ".zig-cache/tmp/resume-test"),
            .agent = ids.next(idmod.AgentId),
            .session = ids.next(idmod.SessionId),
            .ids = ids,
        };
    }

    fn actor() event_mod.Actor {
        return .{ .kind = .agent, .id = .{ .raw = .{ .bytes = @splat(3) } }, .label = "an agent" };
    }

    fn started(self: *Recorded, request: []const u8) !void {
        _ = try self.log.append(.{ .agent_started = .{
            .agent = self.agent,
            .session = self.session,
            .request = request,
            .provider = "anthropic",
            .model = "claude-opus-5",
            .policy = "test",
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });
    }

    fn said(self: *Recorded, text: []const u8) !void {
        _ = try self.log.append(.{ .agent_message = .{
            .agent = self.agent,
            .session = self.session,
            .role = .progress,
            .text = text,
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });
    }

    fn compacted(self: *Recorded) !void {
        _ = try self.log.append(.{ .agent_message = .{
            .agent = self.agent,
            .session = self.session,
            .role = .workspace,
            .text = "Dropped the output of 1 earlier tool call to make room.",
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });
    }

    fn called(self: *Recorded, tool: []const u8, argumentsJson: []const u8, output: []const u8) !void {
        const call = self.ids.next(idmod.ToolCallId);
        _ = try self.log.append(.{ .tool_requested = .{
            .call = call,
            .agent = self.agent,
            .session = self.session,
            .tool = tool,
            .capability = "fs.read",
            .argumentsJson = argumentsJson,
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });

        const hash = try self.store.put(output);
        _ = try self.log.append(.{ .tool_finished = .{
            .call = call,
            .agent = self.agent,
            .session = self.session,
            .outcome = .completed,
            .duration = .{ .ns = 1000 },
            .resultHash = hash,
            .summary = "it worked",
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });
    }

    fn finished(self: *Recorded) !void {
        _ = try self.log.append(.{ .agent_finished = .{
            .agent = self.agent,
            .session = self.session,
            .outcome = .out_of_budget,
            .duration = .{ .ns = 5000 },
        } }, .{ .at = .{ .ns = 0 }, .actor = actor() });
    }
};

test "a stopped run comes back as the conversation it was holding" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var recorded = try Recorded.init(arena);
    try recorded.started("make the tests pass");
    try recorded.said("I will read the file.");
    try recorded.called("read_file", "{\"path\":\"main.zig\"}", "const std = @import(\"std\");\n");
    try recorded.finished();
    try recorded.store.flush(io);

    const back = try latest(arena, io, recorded.log, recorded.store);

    // The task is the first thing, because it is what was asked for.
    try testing.expectEqualStrings("make the tests pass", back.task);
    try testing.expectEqualStrings("claude-opus-5", back.model);
    try testing.expectEqualStrings("out_of_budget", back.ending.?);

    // user task, assistant text, assistant tool_use, user tool_result.
    try testing.expectEqual(@as(usize, 4), back.messages.len);
    try testing.expectEqualStrings("make the tests pass", back.messages[0].blocks[0].text);
    try testing.expectEqualStrings("I will read the file.", back.messages[1].blocks[0].text);
    try testing.expectEqualStrings("read_file", back.messages[2].blocks[0].tool_use.name);

    // The result carries the bytes, fetched from the store by the hash the log
    // recorded — not the summary, and not a placeholder.
    try testing.expectEqualStrings(
        "const std = @import(\"std\");\n",
        back.messages[3].blocks[0].tool_result.content,
    );
    try testing.expectEqual(@as(usize, 0), back.missingResults);
    try testing.expect(back.canContinue());
}

test "each result is paired with the call it answered" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var recorded = try Recorded.init(arena);
    try recorded.started("look at two things");
    try recorded.called("read_file", "{\"path\":\"a\"}", "contents of a");
    try recorded.called("read_file", "{\"path\":\"b\"}", "contents of b");
    try recorded.store.flush(io);

    const back = try rebuild(arena, io, recorded.log, recorded.store, recorded.agent);

    // A provider matches results to calls by identifier. Getting this wrong
    // would hand the model the answer to a question it did not ask, and the
    // model would have no way to notice.
    var calls: std.ArrayList([]const u8) = .empty;
    var results: std.ArrayList([]const u8) = .empty;
    for (back.messages) |message| {
        for (message.blocks) |b| switch (b) {
            .tool_use => |t| try calls.append(arena, t.id),
            .tool_result => |t| try results.append(arena, t.toolUseId),
            else => {},
        };
    }
    try testing.expectEqual(@as(usize, 2), calls.items.len);
    try testing.expectEqual(@as(usize, 2), results.items.len);
    for (calls.items, results.items) |call, result| {
        try testing.expectEqualStrings(call, result);
    }
    try testing.expect(!std.mem.eql(u8, calls.items[0], calls.items[1]));
}

test "a result whose bytes are gone leaves the summary, and is counted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var recorded = try Recorded.init(arena);
    try recorded.started("do something");
    try recorded.called("read_file", "{}", "bytes that were never flushed to disk");
    // Deliberately not flushed: the log names an address the store cannot
    // answer for, which is what a pruned or damaged store looks like.

    const back = try rebuild(arena, io, recorded.log, recorded.store, recorded.agent);

    // A resume still works. The model gets the summary where it once had the
    // output, and the caller is told rather than left to assume the rebuild
    // was complete.
    try testing.expectEqual(@as(usize, 1), back.missingResults);
    try testing.expect(back.canContinue());

    var sentence: std.Io.Writer.Allocating = .init(arena);
    try back.writeSentence(&sentence.writer);
    try testing.expect(std.mem.indexOf(u8, sentence.written(), "no longer in the store") != null);
}

test "a rebuild says when the original saw less than it holds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var recorded = try Recorded.init(arena);
    try recorded.started("a long job");
    try recorded.called("run_command", "{}", "a great deal of output");
    try recorded.compacted();
    try recorded.called("run_command", "{}", "more output");
    try recorded.store.flush(io);

    const back = try rebuild(arena, io, recorded.log, recorded.store, recorded.agent);

    // The log kept the full results, so this rebuild has more than the
    // original run was shown. A replay that did not say so would diverge from
    // the run it claims to reproduce, and nothing would point at why.
    try testing.expectEqual(@as(usize, 1), back.compactions);
    var sentence: std.Io.Writer.Allocating = .init(arena);
    try back.writeSentence(&sentence.writer);
    try testing.expect(std.mem.indexOf(u8, sentence.written(), "saw less than this") != null);

    // And the workspace's own note is not replayed to the model as if the
    // model had said it.
    for (back.messages) |message| {
        for (message.blocks) |b| switch (b) {
            .text => |t| try testing.expect(std.mem.indexOf(u8, t, "Dropped the output") == null),
            else => {},
        };
    }
}

test "one log holding two runs rebuilds each on its own" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var recorded = try Recorded.init(arena);
    try recorded.started("the first job");
    try recorded.called("read_file", "{}", "first output");
    try recorded.finished();

    const first = recorded.agent;
    recorded.agent = recorded.ids.next(idmod.AgentId);
    try recorded.started("the second job");
    try recorded.called("read_file", "{}", "second output");
    try recorded.store.flush(io);

    // A workspace is used for weeks. Rebuilding "the conversation" out of a
    // log with a hundred runs in it has to mean one of them.
    const one = try rebuild(arena, io, recorded.log, recorded.store, first);
    try testing.expectEqualStrings("the first job", one.task);
    try testing.expectEqual(@as(usize, 3), one.messages.len);

    const two = try latest(arena, io, recorded.log, recorded.store);
    try testing.expectEqualStrings("the second job", two.task);

    const listed = try runsIn(arena, recorded.log);
    try testing.expectEqual(@as(usize, 2), listed.len);
}

test "asking for a run that is not there says so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    const recorded = try Recorded.init(arena);
    var ids = idmod.Generator.init(99, 0);
    const stranger = ids.next(idmod.AgentId);

    try testing.expectError(error.NoSuchRun, rebuild(arena, threaded.io(), recorded.log, recorded.store, stranger));
    // An empty log has no latest run either, rather than an empty conversation
    // that looks resumable.
    try testing.expectError(error.NoSuchRun, latest(arena, threaded.io(), recorded.log, recorded.store));
}
