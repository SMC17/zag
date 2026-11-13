//! Making room in a conversation without losing the thread.
//!
//! An agent's messages only grow. Every turn re-sends the whole history, and
//! every tool result adds to it — a `zig build` is twenty kilobytes, a file
//! read is more. Measured on a real run here: 3.5 KB, then 23.8, then 44, then
//! 64, rising by twenty kilobytes a turn and never falling. Twenty turns of
//! ordinary work is four hundred kilobytes of request.
//!
//! Before this, that ended the run. The loop counted tokens and stopped when
//! the budget was spent, which is a bound, not an answer: the work was not
//! finished, it was abandoned at the point where it had cost enough.
//!
//! ## What is dropped, and what is never dropped
//!
//! The bulk is tool output, and tool output is the part whose value decays. A
//! model that read a file six turns ago has already used what it needed;
//! keeping the bytes costs context every turn afterwards. So old tool results
//! are replaced by a line saying what they were and how big, which is enough
//! for the model to ask again if it turns out to matter.
//!
//! Three things are never dropped:
//!
//! - **The task.** The first message is what was asked for. A run that forgets
//!   the request and keeps the output of step four is not doing the work any
//!   more.
//! - **The recent turns.** What the model is working on right now, in full.
//! - **What the model said.** Its own text is its reasoning and its
//!   conclusions, and it is small. Dropping the expensive part and keeping the
//!   cheap part that explains it is the whole trade.
//!
//! ## Why this does not ask a model to summarise
//!
//! The obvious alternative is a summarising call: hand the old turns to the
//! model and keep its précis. It reads better and it costs a request, a wait,
//! and — the reason it is not here — determinism. This workspace records what
//! happened so a person can check it later, and a compaction step whose output
//! depends on a model's mood makes two replays of the same run diverge. What
//! is dropped here is decided by counting, so a replay drops the same things.
//!
//! A summarising compactor is a reasonable thing to add later, as a choice
//! rather than a default. This is the one that can be checked.
//!
//! ## The record
//!
//! Compaction changes what the model saw, so it belongs in the record.
//! `Result` reports what was replaced and how much room it made; the caller
//! writes that to the log. A log that showed the full history when the model
//! was sent a trimmed one would be describing a different run.

const std = @import("std");
const provider = @import("provider.zig");

/// When to compact, and how much to keep.
pub const Budget = struct {
    /// Compact once the messages are bigger than this, in bytes of content.
    ///
    /// Bytes rather than tokens because bytes are known exactly and here, and
    /// tokens are known approximately and only after a provider answers. For
    /// English text and code the ratio is around four bytes to the token, so a
    /// two-hundred-thousand-token window is roughly eight hundred kilobytes;
    /// the default leaves generous room under that for a model's own reply.
    threshold: usize = 320 * 1024,
    /// How many of the most recent messages keep their tool results in full.
    ///
    /// Two is one full turn: the assistant's tool calls, and the results that
    /// came back. Dropping those would take away what the model is holding in
    /// its hand.
    keepRecent: usize = 4,
    /// Tool results shorter than this are left alone.
    ///
    /// Replacing a forty-byte result with a fifty-byte note about the
    /// forty-byte result makes the conversation longer and less useful.
    leaveShorterThan: usize = 512,
};

pub const Result = struct {
    messages: []const provider.Message,
    /// How many tool results were replaced by a note.
    replaced: usize = 0,
    bytesBefore: usize = 0,
    bytesAfter: usize = 0,

    pub fn changedAnything(self: Result) bool {
        return self.replaced > 0;
    }

    /// One sentence for the record and for a person watching.
    pub fn writeSentence(self: Result, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!self.changedAnything()) {
            try w.writeAll("Nothing was dropped from the conversation.");
            return;
        }
        try w.print(
            "Dropped the output of {d} earlier tool call{s} to make room, from {d} to {d} bytes. The task and the most recent work were kept.",
            .{ self.replaced, if (self.replaced == 1) "" else "s", self.bytesBefore, self.bytesAfter },
        );
    }
};

/// How many bytes of content a conversation holds.
pub fn sizeOf(messages: []const provider.Message) usize {
    var total: usize = 0;
    for (messages) |message| {
        for (message.blocks) |block| {
            total += switch (block) {
                .text, .thinking => |t| t.len,
                .tool_use => |t| t.name.len + t.argumentsJson.len,
                .tool_result => |t| t.content.len,
            };
        }
    }
    return total;
}

/// Make room, if there is not enough.
///
/// Returns the messages unchanged when they fit, so a caller can run this
/// every turn without thinking about it.
pub fn compact(
    arena: std.mem.Allocator,
    messages: []const provider.Message,
    budget: Budget,
) !Result {
    const before = sizeOf(messages);
    if (before <= budget.threshold) {
        return .{ .messages = messages, .bytesBefore = before, .bytesAfter = before };
    }

    // Never touch the first message: it is the task. Never touch the last
    // `keepRecent`: that is what is being worked on.
    const first_touchable: usize = 1;
    const last_touchable = if (messages.len > budget.keepRecent)
        messages.len - budget.keepRecent
    else
        first_touchable;

    var out = try arena.alloc(provider.Message, messages.len);
    var replaced: usize = 0;

    for (messages, 0..) |message, index| {
        if (index < first_touchable or index >= last_touchable) {
            out[index] = message;
            continue;
        }

        var blocks: ?[]provider.Block = null;
        for (message.blocks, 0..) |block, at| {
            const result = switch (block) {
                .tool_result => |r| r,
                // The model's own words stay. They are the conclusions the
                // expensive part was gathered for, and they are small.
                else => continue,
            };
            if (result.content.len < budget.leaveShorterThan) continue;

            if (blocks == null) blocks = try arena.dupe(provider.Block, message.blocks);
            blocks.?[at] = .{ .tool_result = .{
                .toolUseId = result.toolUseId,
                .isError = result.isError,
                .content = try std.fmt.allocPrint(
                    arena,
                    "[{d} bytes from this tool were dropped to make room. Ask again if you need them.]",
                    .{result.content.len},
                ),
            } };
            replaced += 1;
        }

        out[index] = if (blocks) |changed|
            .{ .role = message.role, .blocks = changed }
        else
            message;
    }

    return .{
        .messages = out,
        .replaced = replaced,
        .bytesBefore = before,
        .bytesAfter = sizeOf(out),
    };
}

const testing = std.testing;

fn toolResult(arena: std.mem.Allocator, id: []const u8, bytes: usize) !provider.Message {
    const filler = try arena.alloc(u8, bytes);
    @memset(filler, 'x');
    const blocks = try arena.alloc(provider.Block, 1);
    blocks[0] = .{ .tool_result = .{ .toolUseId = id, .content = filler } };
    return .{ .role = .user, .blocks = blocks };
}

fn said(arena: std.mem.Allocator, text: []const u8) !provider.Message {
    const blocks = try arena.alloc(provider.Block, 1);
    blocks[0] = .{ .text = text };
    return .{ .role = .assistant, .blocks = blocks };
}

test "a conversation that fits is left exactly as it was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const messages = [_]provider.Message{
        try said(arena, "fix the build"),
        try toolResult(arena, "t1", 4096),
    };
    const result = try compact(arena, &messages, .{ .threshold = 1 << 20 });

    // Same slice, not a copy: running this every turn must cost nothing when
    // there is nothing to do.
    try testing.expectEqual(messages.len, result.messages.len);
    try testing.expect(!result.changedAnything());
    try testing.expectEqual(result.bytesBefore, result.bytesAfter);
}

test "old tool output goes, and the task never does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list: std.ArrayList(provider.Message) = .empty;
    // The task, then six turns of a model calling a tool that returns a lot.
    try list.append(arena, try said(arena, "make the tests pass"));
    for (0..6) |turn| {
        try list.append(arena, try said(arena, "I will look at that."));
        try list.append(arena, try toolResult(arena, try std.fmt.allocPrint(arena, "t{d}", .{turn}), 20_000));
    }

    const result = try compact(arena, list.items, .{ .threshold = 40_000, .keepRecent = 4 });
    try testing.expect(result.changedAnything());
    try testing.expect(result.bytesAfter < result.bytesBefore / 2);

    // The task is still the first thing the model reads. A run that forgets
    // what it was asked and remembers the output of step four is not doing the
    // work any more.
    try testing.expectEqualStrings("make the tests pass", result.messages[0].blocks[0].text);

    // The most recent turn is untouched: it is what the model is holding.
    const last = result.messages[result.messages.len - 1];
    try testing.expectEqual(@as(usize, 20_000), last.blocks[0].tool_result.content.len);

    // And an older one is a note about what was there, not silence.
    const dropped = result.messages[2].blocks[0].tool_result.content;
    try testing.expect(std.mem.indexOf(u8, dropped, "20000 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, dropped, "Ask again") != null);
}

test "what the model said is kept, because that is what the output was for" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list: std.ArrayList(provider.Message) = .empty;
    try list.append(arena, try said(arena, "the task"));
    try list.append(arena, try said(arena, "The failure is a missing semicolon on line five."));
    try list.append(arena, try toolResult(arena, "t1", 50_000));
    try list.append(arena, try said(arena, "still working"));
    try list.append(arena, try toolResult(arena, "t2", 50_000));

    const result = try compact(arena, list.items, .{ .threshold = 10_000, .keepRecent = 1 });

    // The conclusion survives the evidence. Dropping the expensive part and
    // keeping the cheap part that explains it is the whole trade.
    try testing.expectEqualStrings(
        "The failure is a missing semicolon on line five.",
        result.messages[1].blocks[0].text,
    );
    try testing.expect(result.replaced >= 1);
}

test "a small result is left alone rather than replaced by a longer note" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list: std.ArrayList(provider.Message) = .empty;
    try list.append(arena, try said(arena, "the task"));
    try list.append(arena, try toolResult(arena, "small", 20));
    try list.append(arena, try toolResult(arena, "big", 50_000));
    try list.append(arena, try said(arena, "recent"));

    const result = try compact(arena, list.items, .{ .threshold = 1000, .keepRecent = 1 });

    // Replacing twenty bytes with a fifty-byte note about the twenty bytes
    // makes the conversation longer and less useful.
    try testing.expectEqual(@as(usize, 20), result.messages[1].blocks[0].tool_result.content.len);
    try testing.expectEqual(@as(usize, 1), result.replaced);
}

test "compaction is decided by counting, so a replay drops the same things" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list: std.ArrayList(provider.Message) = .empty;
    try list.append(arena, try said(arena, "the task"));
    for (0..5) |turn| {
        try list.append(arena, try said(arena, "thinking"));
        try list.append(arena, try toolResult(arena, try std.fmt.allocPrint(arena, "t{d}", .{turn}), 9000));
    }

    // The reason this is not a summarising call: two runs of the same
    // conversation have to produce the same thing, or a recorded run cannot be
    // checked against a replay of it.
    const once = try compact(arena, list.items, .{ .threshold = 20_000 });
    const twice = try compact(arena, list.items, .{ .threshold = 20_000 });
    try testing.expectEqual(once.replaced, twice.replaced);
    try testing.expectEqual(once.bytesAfter, twice.bytesAfter);
}

test "the sentence for the record says what was given up" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(arena);
    const result: Result = .{ .messages = &.{}, .replaced = 3, .bytesBefore = 90_000, .bytesAfter = 30_000 };
    try result.writeSentence(&out.writer);

    // Compaction changes what the model saw, so a log that did not mention it
    // would be describing a different run.
    try testing.expect(std.mem.indexOf(u8, out.written(), "3 earlier tool calls") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "90000") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "30000") != null);
}
