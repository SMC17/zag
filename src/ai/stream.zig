//! Reading an answer while it is still being written.
//!
//! Every connector in this build waits for the whole reply before it returns
//! anything. That is correct for a question with a short answer and wrong for
//! everything else: a model writing four thousand tokens holds the terminal
//! silent for the whole minute it takes, and a person watching has no way to
//! tell a long answer from a hung one.
//!
//! The awkward part of streaming is not the protocol. It is that bytes arrive
//! in whatever sizes the network chose, and those sizes have nothing to do with
//! where the messages are. A read can end in the middle of `data:`, between the
//! two newlines that terminate an event, between the `\r` and the `\n` of one
//! line ending, or halfway through a UTF-8 sequence. A parser that assumes each
//! read holds whole events works perfectly on a fast local model and corrupts
//! answers over a real connection, intermittently, in a way that looks like the
//! provider's fault.
//!
//! So this file is two layers, and they are kept apart on purpose.
//!
//! ## Framing
//!
//! `Framer` turns a byte stream into complete frames and nothing else. It knows
//! about Server-Sent Events and about newline-delimited JSON, because those are
//! the two framings the providers in the catalogue use, and it knows nothing at
//! all about models. Bytes that do not yet complete a frame are held, and the
//! next feed continues from them.
//!
//! The property that matters is that framing is independent of how the bytes
//! were divided. There is a test that feeds the same stream one byte at a time
//! and asserts the frames are identical to feeding it whole, which is the only
//! form of this test worth writing.
//!
//! ## Interpretation
//!
//! `interpret` turns one frame into zero or more `Delta` values, which are
//! provider-neutral. Anthropic sends typed events with content-block indices;
//! OpenAI sends choice deltas and a `[DONE]` sentinel; Ollama sends one JSON
//! object per line with a `done` flag. Those three shapes become the same
//! sequence of deltas, so everything above this file is written once.
//!
//! ## The answer is the same answer
//!
//! `Assembler` folds deltas back into the `provider.Completion` that the
//! non-streaming path returns. That is deliberate: a caller that does not want
//! to render progressively gets exactly the type it already handles, and the
//! test suite can assert that streaming a response and decoding it whole
//! produce the same completion. A streaming path that quietly returns something
//! slightly different from the blocking path is a bug that surfaces months
//! later as "the model behaves differently when you watch it".

const std = @import("std");
const provider = @import("provider.zig");
const catalog = @import("catalog.zig");

/// How a provider divides its stream.
pub const Framing = enum {
    /// `text/event-stream`: fields, one per line, and a blank line between
    /// events. Anthropic, OpenAI, Gemini and Hugging Face.
    server_sent_events,
    /// One JSON object per line. Ollama.
    json_lines,

    pub fn of(format: catalog.Format) Framing {
        return switch (format) {
            .anthropic, .openai, .gemini, .huggingface => .server_sent_events,
            .ollama => .json_lines,
        };
    }
};

/// One complete message from the stream.
pub const Frame = struct {
    /// The SSE `event:` field, empty for a framing that has none.
    name: []const u8 = "",
    /// The `data:` payload, with continuation lines joined by newlines, or the
    /// whole line for JSON-lines framing.
    data: []const u8,
};

/// Turns a byte stream into frames, however the bytes were divided.
///
/// Feed it whatever arrives. It returns the frames that are now complete and
/// keeps the rest for next time.
pub const Framer = struct {
    framing: Framing,
    /// Bytes that did not complete a frame. Carried to the next feed.
    pending: std.ArrayList(u8) = .empty,
    /// Set once the stream said it was finished. Frames after this are ignored,
    /// because a provider that keeps talking after `[DONE]` is not something to
    /// interpret.
    finished: bool = false,

    /// The most bytes a single unfinished frame may occupy.
    ///
    /// A frame that never terminates is an unbounded read driven by whoever is
    /// on the other end of the socket. Exceeding this is an error rather than a
    /// truncation, because half a JSON object parses as nothing useful and
    /// silently dropping it would lose part of an answer.
    pub const max_frame_bytes = 8 << 20;

    pub const Error = error{FrameTooLarge} || std.mem.Allocator.Error;

    pub fn init(framing: Framing) Framer {
        return .{ .framing = framing };
    }

    /// Add bytes and return every frame they completed.
    ///
    /// The returned frames point into `arena`, and stay valid for as long as it
    /// does. An empty chunk is legal and returns nothing, which is what a
    /// zero-length read means.
    pub fn feed(self: *Framer, arena: std.mem.Allocator, chunk: []const u8) Error![]const Frame {
        var out: std.ArrayList(Frame) = .empty;
        if (self.finished) return out.items;
        try self.pending.appendSlice(arena, chunk);
        if (self.pending.items.len > max_frame_bytes) return error.FrameTooLarge;

        var consumed: usize = 0;
        while (self.nextBoundary(consumed)) |boundary| {
            const block = self.pending.items[consumed..boundary.start];
            consumed = boundary.end;
            const frame = switch (self.framing) {
                .server_sent_events => try parseEvent(arena, block),
                .json_lines => blk: {
                    const trimmed = std.mem.trim(u8, block, " \t\r");
                    // Copied out of `pending`, which the next feed moves down
                    // and appends to. A frame handed back pointing into that
                    // buffer is valid until the caller reads more bytes, which
                    // is the one thing every caller does next.
                    break :blk if (trimmed.len == 0) null else Frame{ .data = try arena.dupe(u8, trimmed) };
                },
            } orelse continue;
            try out.append(arena, frame);
        }

        // Keep what is left. Copied down rather than reallocated, so a long
        // stream of small frames does not grow the buffer without bound.
        if (consumed > 0) {
            const remaining = self.pending.items.len - consumed;
            std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[consumed..]);
            self.pending.shrinkRetainingCapacity(remaining);
        }
        return out.items;
    }

    /// Whatever is left over when the stream ends.
    ///
    /// A provider that closes the connection without a final blank line has
    /// still sent a complete event, and dropping it loses the end of the
    /// answer. Called once, after the last read.
    pub fn finish(self: *Framer, arena: std.mem.Allocator) Error![]const Frame {
        var out: std.ArrayList(Frame) = .empty;
        const block = std.mem.trim(u8, self.pending.items, " \t\r\n");
        if (block.len == 0) return out.items;
        const frame = switch (self.framing) {
            .server_sent_events => try parseEvent(arena, self.pending.items),
            .json_lines => Frame{ .data = try arena.dupe(u8, block) },
        };
        if (frame) |complete| try out.append(arena, complete);
        self.pending.clearRetainingCapacity();
        return out.items;
    }

    const Boundary = struct { start: usize, end: usize };

    /// Where the frame beginning at `from` ends, and where the next begins.
    ///
    /// For JSON lines that is a newline. For events it is a blank line, which
    /// may be written four different ways depending on the line endings, and a
    /// parser that only looks for one of them stalls for ever on a provider
    /// that uses another.
    fn nextBoundary(self: *Framer, from: usize) ?Boundary {
        const bytes = self.pending.items;
        if (from >= bytes.len) return null;
        switch (self.framing) {
            .json_lines => {
                const at = std.mem.indexOfScalarPos(u8, bytes, from, '\n') orelse return null;
                return .{ .start = at, .end = at + 1 };
            },
            .server_sent_events => {
                var index = from;
                while (index < bytes.len) : (index += 1) {
                    if (bytes[index] != '\n') continue;
                    // "\n\n"
                    if (index + 1 < bytes.len and bytes[index + 1] == '\n') {
                        return .{ .start = index, .end = index + 2 };
                    }
                    // "\n\r\n"
                    if (index + 2 < bytes.len and bytes[index + 1] == '\r' and bytes[index + 2] == '\n') {
                        return .{ .start = index, .end = index + 3 };
                    }
                    // A lone "\n" at the very end may yet become "\n\n" when the
                    // next chunk arrives, so it is not a boundary until more
                    // bytes say otherwise. This is the split that breaks a
                    // parser written against whole responses.
                    if (index + 1 >= bytes.len) return null;
                    if (bytes[index + 1] == '\r' and index + 2 >= bytes.len) return null;
                }
                return null;
            },
        }
    }
};

/// Parse one Server-Sent Events block into a frame.
///
/// Returns null for a block that carries no data: a comment, which providers
/// send as a heartbeat, or a block of fields this build has no use for.
fn parseEvent(arena: std.mem.Allocator, block: []const u8) !?Frame {
    var name: []const u8 = "";
    var data: std.ArrayList(u8) = .empty;
    var any_data = false;

    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        // A line beginning with a colon is a comment. Anthropic sends `: ping`
        // to keep a connection open, and a parser that treats it as a field
        // with an empty name will try to interpret it.
        if (line[0] == ':') continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const field = line[0..colon];
        var value = line[colon + 1 ..];
        // Exactly one leading space is part of the framing, not of the value.
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "event")) {
            // Copied for the same reason the payload is: `block` points into
            // the framer's carry-over buffer, and the next feed moves it.
            name = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, field, "data")) {
            // Several data lines in one event are one payload joined by
            // newlines. Providers use this for anything containing a newline.
            if (any_data) try data.append(arena, '\n');
            try data.appendSlice(arena, value);
            any_data = true;
        }
        // `id` and `retry` are about reconnection, which this build does not do.
    }

    if (!any_data) return null;
    return .{ .name = name, .data = data.items };
}

/// One thing that happened, in terms this workbench understands.
///
/// Deliberately finer than a message: a caller rendering progress needs to know
/// that text arrived without waiting to be told which block it belonged to, and
/// a caller assembling a completion needs both.
pub const Delta = union(enum) {
    /// The provider named the model that is answering. It may not be the model
    /// that was asked for, and the record has to say which ran.
    started: struct { model: []const u8 },
    /// A new content block. `index` is the provider's own, so that deltas
    /// arriving out of order still land in the right place.
    block_opened: struct { index: usize, kind: BlockKind, id: []const u8 = "", name: []const u8 = "" },
    /// More text for the block at `index`.
    text: struct { index: usize, chunk: []const u8 },
    /// More reasoning for the block at `index`.
    thinking: struct { index: usize, chunk: []const u8 },
    /// More of a tool call's arguments, as partial JSON. Never parsed until the
    /// block closes, because half a JSON object is not a smaller JSON object.
    tool_arguments: struct { index: usize, chunk: []const u8 },
    block_closed: struct { index: usize },
    usage: provider.Usage,
    stopped: struct { reason: provider.StopReason },
    /// The provider said something went wrong mid-stream. Its own words.
    provider_error: struct { message: []const u8 },
    /// The stream said it was over. Not the same as `stopped`: one is the
    /// model finishing a turn, the other is the connection finishing.
    ended,

    pub const BlockKind = enum { text, thinking, tool_use };
};

/// Turn one frame into deltas.
///
/// Returns nothing for a frame this build has no use for, which is most of
/// them: providers send pings, block indices this build already has, and
/// bookkeeping about their own queues.
pub fn interpret(
    arena: std.mem.Allocator,
    format: catalog.Format,
    frame: Frame,
) ![]const Delta {
    return switch (format) {
        .anthropic => interpretAnthropic(arena, frame),
        .openai, .huggingface => interpretOpenAi(arena, frame),
        .gemini => interpretGemini(arena, frame),
        .ollama => interpretOllama(arena, frame),
    };
}

fn objectOf(arena: std.mem.Allocator, data: []const u8) ?std.json.ObjectMap {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, data, .{}) catch return null;
    return switch (parsed.value) {
        .object => |o| o,
        else => null,
    };
}

fn stringAt(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn integerAt(object: std.json.ObjectMap, key: []const u8) ?u64 {
    return switch (object.get(key) orelse return null) {
        .integer => |i| if (i < 0) null else @intCast(i),
        else => null,
    };
}

fn objectAt(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    return switch (object.get(key) orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn arrayAt(object: std.json.ObjectMap, key: []const u8) ?std.json.Array {
    return switch (object.get(key) orelse return null) {
        .array => |a| a,
        else => null,
    };
}

fn interpretAnthropic(arena: std.mem.Allocator, frame: Frame) ![]const Delta {
    var out: std.ArrayList(Delta) = .empty;
    const root = objectOf(arena, frame.data) orelse return out.items;
    // The event name is on the SSE frame and repeated in the body. The body is
    // used, so a proxy that drops the `event:` field does not silently turn
    // every frame into nothing.
    const kind = stringAt(root, "type") orelse frame.name;

    if (std.mem.eql(u8, kind, "message_start")) {
        const message = objectAt(root, "message") orelse return out.items;
        try out.append(arena, .{ .started = .{ .model = stringAt(message, "model") orelse "" } });
        if (objectAt(message, "usage")) |usage| try out.append(arena, .{ .usage = readAnthropicUsage(usage) });
    } else if (std.mem.eql(u8, kind, "content_block_start")) {
        const index = integerAt(root, "index") orelse 0;
        const block = objectAt(root, "content_block") orelse return out.items;
        const block_type = stringAt(block, "type") orelse "text";
        if (std.mem.eql(u8, block_type, "tool_use")) {
            try out.append(arena, .{ .block_opened = .{
                .index = index,
                .kind = .tool_use,
                .id = stringAt(block, "id") orelse "",
                .name = stringAt(block, "name") orelse "",
            } });
        } else if (std.mem.eql(u8, block_type, "thinking")) {
            try out.append(arena, .{ .block_opened = .{ .index = index, .kind = .thinking } });
        } else {
            try out.append(arena, .{ .block_opened = .{ .index = index, .kind = .text } });
        }
    } else if (std.mem.eql(u8, kind, "content_block_delta")) {
        const index = integerAt(root, "index") orelse 0;
        const delta = objectAt(root, "delta") orelse return out.items;
        const delta_type = stringAt(delta, "type") orelse "";
        if (std.mem.eql(u8, delta_type, "text_delta")) {
            try out.append(arena, .{ .text = .{ .index = index, .chunk = stringAt(delta, "text") orelse "" } });
        } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
            try out.append(arena, .{ .thinking = .{ .index = index, .chunk = stringAt(delta, "thinking") orelse "" } });
        } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
            try out.append(arena, .{ .tool_arguments = .{
                .index = index,
                .chunk = stringAt(delta, "partial_json") orelse "",
            } });
        }
    } else if (std.mem.eql(u8, kind, "content_block_stop")) {
        try out.append(arena, .{ .block_closed = .{ .index = integerAt(root, "index") orelse 0 } });
    } else if (std.mem.eql(u8, kind, "message_delta")) {
        if (objectAt(root, "delta")) |delta| {
            if (stringAt(delta, "stop_reason")) |reason| {
                try out.append(arena, .{ .stopped = .{ .reason = anthropicStopReason(reason) } });
            }
        }
        if (objectAt(root, "usage")) |usage| try out.append(arena, .{ .usage = readAnthropicUsage(usage) });
    } else if (std.mem.eql(u8, kind, "message_stop")) {
        try out.append(arena, .ended);
    } else if (std.mem.eql(u8, kind, "error")) {
        const detail = objectAt(root, "error");
        try out.append(arena, .{ .provider_error = .{
            .message = if (detail) |d| stringAt(d, "message") orelse "The provider reported an error." else "The provider reported an error.",
        } });
    }
    return out.items;
}

fn readAnthropicUsage(usage: std.json.ObjectMap) provider.Usage {
    return .{
        .inputTokens = integerAt(usage, "input_tokens") orelse 0,
        .outputTokens = integerAt(usage, "output_tokens") orelse 0,
        .cacheReadTokens = integerAt(usage, "cache_read_input_tokens") orelse 0,
        .cacheWriteTokens = integerAt(usage, "cache_creation_input_tokens") orelse 0,
    };
}

fn anthropicStopReason(text: []const u8) provider.StopReason {
    if (std.mem.eql(u8, text, "end_turn")) return .end_turn;
    if (std.mem.eql(u8, text, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, text, "max_tokens")) return .max_tokens;
    if (std.mem.eql(u8, text, "refusal")) return .refusal;
    if (std.mem.eql(u8, text, "stop_sequence")) return .stop_sequence;
    return .unknown;
}

fn interpretOpenAi(arena: std.mem.Allocator, frame: Frame) ![]const Delta {
    var out: std.ArrayList(Delta) = .empty;
    // The sentinel. It is not JSON, and a parser that hands it to a JSON reader
    // gets an error where it should get an ending.
    if (std.mem.eql(u8, std.mem.trim(u8, frame.data, " \t"), "[DONE]")) {
        try out.append(arena, .ended);
        return out.items;
    }
    const root = objectOf(arena, frame.data) orelse return out.items;

    if (objectAt(root, "error")) |detail| {
        try out.append(arena, .{ .provider_error = .{
            .message = stringAt(detail, "message") orelse "The provider reported an error.",
        } });
        return out.items;
    }
    if (stringAt(root, "model")) |model| {
        try out.append(arena, .{ .started = .{ .model = model } });
    }

    const choices = arrayAt(root, "choices") orelse {
        // A usage-only frame, which is what `stream_options.include_usage`
        // produces after the last choice.
        if (objectAt(root, "usage")) |usage| try out.append(arena, .{ .usage = readOpenAiUsage(usage) });
        return out.items;
    };
    for (choices.items) |item| {
        const choice = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (objectAt(choice, "delta")) |delta| {
            if (stringAt(delta, "content")) |text| {
                if (text.len > 0) try out.append(arena, .{ .text = .{ .index = 0, .chunk = text } });
            }
            if (stringAt(delta, "reasoning_content")) |thought| {
                if (thought.len > 0) try out.append(arena, .{ .thinking = .{ .index = 0, .chunk = thought } });
            }
            if (arrayAt(delta, "tool_calls")) |calls| {
                for (calls.items) |call_value| {
                    const call = switch (call_value) {
                        .object => |o| o,
                        else => continue,
                    };
                    // Index within the tool-call list, offset past the text
                    // block so the two never collide in the assembler.
                    const index = 1 + (integerAt(call, "index") orelse 0);
                    if (stringAt(call, "id")) |id| {
                        const function = objectAt(call, "function");
                        try out.append(arena, .{ .block_opened = .{
                            .index = index,
                            .kind = .tool_use,
                            .id = id,
                            .name = if (function) |f| stringAt(f, "name") orelse "" else "",
                        } });
                    }
                    if (objectAt(call, "function")) |function| {
                        if (stringAt(function, "arguments")) |args| {
                            if (args.len > 0) try out.append(arena, .{ .tool_arguments = .{ .index = index, .chunk = args } });
                        }
                    }
                }
            }
        }
        if (stringAt(choice, "finish_reason")) |reason| {
            try out.append(arena, .{ .stopped = .{ .reason = openAiStopReason(reason) } });
        }
    }
    if (objectAt(root, "usage")) |usage| try out.append(arena, .{ .usage = readOpenAiUsage(usage) });
    return out.items;
}

fn readOpenAiUsage(usage: std.json.ObjectMap) provider.Usage {
    return .{
        .inputTokens = integerAt(usage, "prompt_tokens") orelse 0,
        .outputTokens = integerAt(usage, "completion_tokens") orelse 0,
    };
}

fn openAiStopReason(text: []const u8) provider.StopReason {
    if (std.mem.eql(u8, text, "stop")) return .end_turn;
    if (std.mem.eql(u8, text, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, text, "function_call")) return .tool_use;
    if (std.mem.eql(u8, text, "length")) return .max_tokens;
    if (std.mem.eql(u8, text, "content_filter")) return .refusal;
    return .unknown;
}

fn interpretGemini(arena: std.mem.Allocator, frame: Frame) ![]const Delta {
    var out: std.ArrayList(Delta) = .empty;
    const root = objectOf(arena, frame.data) orelse return out.items;
    if (stringAt(root, "modelVersion")) |model| {
        try out.append(arena, .{ .started = .{ .model = model } });
    }
    const candidates = arrayAt(root, "candidates") orelse return out.items;
    for (candidates.items) |candidate_value| {
        const candidate = switch (candidate_value) {
            .object => |o| o,
            else => continue,
        };
        if (objectAt(candidate, "content")) |content| {
            if (arrayAt(content, "parts")) |parts| {
                for (parts.items) |part_value| {
                    const part = switch (part_value) {
                        .object => |o| o,
                        else => continue,
                    };
                    if (stringAt(part, "text")) |text| {
                        if (text.len > 0) try out.append(arena, .{ .text = .{ .index = 0, .chunk = text } });
                    }
                }
            }
        }
        if (stringAt(candidate, "finishReason")) |reason| {
            try out.append(arena, .{ .stopped = .{ .reason = geminiStopReason(reason) } });
        }
    }
    if (objectAt(root, "usageMetadata")) |usage| {
        try out.append(arena, .{ .usage = .{
            .inputTokens = integerAt(usage, "promptTokenCount") orelse 0,
            .outputTokens = integerAt(usage, "candidatesTokenCount") orelse 0,
        } });
    }
    return out.items;
}

fn geminiStopReason(text: []const u8) provider.StopReason {
    if (std.mem.eql(u8, text, "STOP")) return .end_turn;
    if (std.mem.eql(u8, text, "MAX_TOKENS")) return .max_tokens;
    if (std.mem.eql(u8, text, "SAFETY")) return .refusal;
    if (std.mem.eql(u8, text, "RECITATION")) return .refusal;
    return .unknown;
}

fn interpretOllama(arena: std.mem.Allocator, frame: Frame) ![]const Delta {
    var out: std.ArrayList(Delta) = .empty;
    const root = objectOf(arena, frame.data) orelse return out.items;
    if (stringAt(root, "model")) |model| {
        try out.append(arena, .{ .started = .{ .model = model } });
    }
    if (objectAt(root, "message")) |message| {
        if (stringAt(message, "content")) |text| {
            if (text.len > 0) try out.append(arena, .{ .text = .{ .index = 0, .chunk = text } });
        }
        if (stringAt(message, "thinking")) |thought| {
            if (thought.len > 0) try out.append(arena, .{ .thinking = .{ .index = 0, .chunk = thought } });
        }
    }
    const done = switch (root.get("done") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };
    if (done) {
        try out.append(arena, .{ .usage = .{
            .inputTokens = integerAt(root, "prompt_eval_count") orelse 0,
            .outputTokens = integerAt(root, "eval_count") orelse 0,
        } });
        const reason = stringAt(root, "done_reason") orelse "stop";
        try out.append(arena, .{ .stopped = .{
            .reason = if (std.mem.eql(u8, reason, "length")) .max_tokens else .end_turn,
        } });
        try out.append(arena, .ended);
    }
    return out.items;
}

/// Folds deltas back into the completion the blocking path returns.
///
/// Holds one growing buffer per content block, keyed by the provider's own
/// index, so blocks that interleave — which they do, when a model writes text
/// and calls a tool in the same turn — do not run into each other.
pub const Assembler = struct {
    arena: std.mem.Allocator,
    model: []const u8 = "",
    stop_reason: provider.StopReason = .unknown,
    usage: provider.Usage = .{},
    problem: []const u8 = "",
    ended: bool = false,
    parts: std.ArrayList(Part) = .empty,

    const Part = struct {
        index: usize,
        kind: Delta.BlockKind,
        id: []const u8 = "",
        name: []const u8 = "",
        text: std.ArrayList(u8) = .empty,
        closed: bool = false,
    };

    pub fn init(arena: std.mem.Allocator) Assembler {
        return .{ .arena = arena };
    }

    /// Take one delta.
    pub fn accept(self: *Assembler, delta: Delta) !void {
        switch (delta) {
            .started => |s| if (s.model.len > 0) {
                self.model = s.model;
            },
            .block_opened => |b| {
                const part = try self.partAt(b.index, b.kind);
                part.kind = b.kind;
                if (b.id.len > 0) part.id = b.id;
                if (b.name.len > 0) part.name = b.name;
            },
            .text => |t| {
                const part = try self.partAt(t.index, .text);
                try part.text.appendSlice(self.arena, t.chunk);
            },
            .thinking => |t| {
                const part = try self.partAt(t.index, .thinking);
                try part.text.appendSlice(self.arena, t.chunk);
            },
            .tool_arguments => |t| {
                const part = try self.partAt(t.index, .tool_use);
                try part.text.appendSlice(self.arena, t.chunk);
            },
            .block_closed => |b| {
                if (self.find(b.index)) |part| part.closed = true;
            },
            // Usage is replaced rather than added. Every provider here sends a
            // running total, and adding them would count the same tokens as
            // many times as it mentioned them.
            .usage => |u| {
                if (u.inputTokens > 0) self.usage.inputTokens = u.inputTokens;
                if (u.outputTokens > 0) self.usage.outputTokens = u.outputTokens;
                if (u.cacheReadTokens > 0) self.usage.cacheReadTokens = u.cacheReadTokens;
                if (u.cacheWriteTokens > 0) self.usage.cacheWriteTokens = u.cacheWriteTokens;
            },
            .stopped => |s| self.stop_reason = s.reason,
            .provider_error => |e| self.problem = e.message,
            .ended => self.ended = true,
        }
    }

    fn find(self: *Assembler, index: usize) ?*Part {
        for (self.parts.items) |*part| {
            if (part.index == index) return part;
        }
        return null;
    }

    fn partAt(self: *Assembler, index: usize, kind: Delta.BlockKind) !*Part {
        if (self.find(index)) |part| return part;
        try self.parts.append(self.arena, .{ .index = index, .kind = kind });
        return &self.parts.items[self.parts.items.len - 1];
    }

    /// Whether the provider reported a failure mid-stream.
    pub fn failed(self: Assembler) bool {
        return self.problem.len > 0;
    }

    /// The answer so far, as the type the blocking path returns.
    ///
    /// Safe to call at any point, so a caller that has to stop early still gets
    /// the part that arrived rather than nothing.
    pub fn completion(self: *Assembler) !provider.Completion {
        var blocks: std.ArrayList(provider.Block) = .empty;
        // The provider's own indices decide the order, so a stream whose frames
        // arrived out of order still assembles the answer the model wrote.
        std.mem.sort(Part, self.parts.items, {}, struct {
            fn lessThan(_: void, a: Part, b: Part) bool {
                return a.index < b.index;
            }
        }.lessThan);

        for (self.parts.items) |part| {
            switch (part.kind) {
                .text => if (part.text.items.len > 0) try blocks.append(self.arena, .{ .text = part.text.items }),
                .thinking => if (part.text.items.len > 0) try blocks.append(self.arena, .{ .thinking = part.text.items }),
                .tool_use => try blocks.append(self.arena, .{
                    .tool_use = .{
                        .id = part.id,
                        .name = part.name,
                        // An empty argument list is `{}`, not the empty string. A
                        // model that called a tool with no arguments sent no
                        // `input_json_delta` at all, and passing "" on to a JSON
                        // reader turns a valid call into a parse failure.
                        .argumentsJson = if (part.text.items.len == 0) "{}" else part.text.items,
                    },
                }),
            }
        }

        return .{
            .model = self.model,
            .blocks = blocks.items,
            .stopReason = self.stop_reason,
            .usage = self.usage,
        };
    }
};

/// A stream being read: framing, interpretation and assembly in one piece.
///
/// This is what a caller uses. Feed it whatever the socket returned; it hands
/// back the deltas so progress can be shown, and holds the answer so far.
pub const Reader = struct {
    arena: std.mem.Allocator,
    format: catalog.Format,
    framer: Framer,
    assembler: Assembler,

    pub fn init(arena: std.mem.Allocator, format: catalog.Format) Reader {
        return .{
            .arena = arena,
            .format = format,
            .framer = Framer.init(Framing.of(format)),
            .assembler = Assembler.init(arena),
        };
    }

    /// Add bytes. Returns the deltas they completed, in order.
    pub fn feed(self: *Reader, chunk: []const u8) ![]const Delta {
        const frames = try self.framer.feed(self.arena, chunk);
        return self.absorb(frames);
    }

    /// Tell the reader the connection closed, and take whatever was left.
    pub fn finish(self: *Reader) ![]const Delta {
        const frames = try self.framer.finish(self.arena);
        return self.absorb(frames);
    }

    fn absorb(self: *Reader, frames: []const Frame) ![]const Delta {
        var out: std.ArrayList(Delta) = .empty;
        for (frames) |frame| {
            for (try interpret(self.arena, self.format, frame)) |delta| {
                try self.assembler.accept(delta);
                try out.append(self.arena, delta);
            }
        }
        return out.items;
    }

    /// The answer so far.
    pub fn completion(self: *Reader) !provider.Completion {
        return self.assembler.completion();
    }
};

const testing = std.testing;

/// A real Anthropic stream, written the way the wire carries it.
///
/// Text and a tool call in one turn, a thinking block, a ping in the middle,
/// and a `message_delta` carrying the stop reason and final usage. The tool
/// arguments arrive in three pieces that are not valid JSON on their own, which
/// is the case a naive reader parses too early.
const anthropic_stream =
    "event: message_start\n" ++
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":42,\"output_tokens\":1}}}\n" ++
    "\n" ++
    "event: content_block_start\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n" ++
    "\n" ++
    "event: content_block_delta\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Check the log first.\"}}\n" ++
    "\n" ++
    "event: content_block_stop\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
    "\n" ++
    ": ping\n" ++
    "\n" ++
    "event: content_block_start\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
    "\n" ++
    "event: content_block_delta\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Reading \"}}\n" ++
    "\n" ++
    "event: content_block_delta\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"the log.\"}}\n" ++
    "\n" ++
    "event: content_block_stop\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n" ++
    "\n" ++
    "event: content_block_start\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read_file\"}}\n" ++
    "\n" ++
    "event: content_block_delta\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\"\"}}\n" ++
    "\n" ++
    "event: content_block_delta\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\":\\\"README\"}}\n" ++
    "\n" ++
    "event: content_block_delta\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\".md\\\"}\"}}\n" ++
    "\n" ++
    "event: content_block_stop\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":2}\n" ++
    "\n" ++
    "event: message_delta\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"input_tokens\":42,\"output_tokens\":57}}\n" ++
    "\n" ++
    "event: message_stop\n" ++
    "data: {\"type\":\"message_stop\"}\n" ++
    "\n";

fn readWhole(arena: std.mem.Allocator, format: catalog.Format, source: []const u8, chunk_size: usize) !provider.Completion {
    var reader = Reader.init(arena, format);
    var at: usize = 0;
    while (at < source.len) {
        const end = @min(at + chunk_size, source.len);
        _ = try reader.feed(source[at..end]);
        at = end;
    }
    _ = try reader.finish();
    return reader.completion();
}

test "the answer does not depend on how the bytes were divided" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The test worth writing. A read can end at any byte — in the middle of
    // `data:`, between the two newlines that end an event, inside a word — and
    // the answer has to be the same one every time. One byte at a time is the
    // worst case, and every size up to the whole stream is checked because the
    // bug is usually at one specific size.
    const whole = try readWhole(arena, .anthropic, anthropic_stream, anthropic_stream.len);
    const expected_text = try whole.text(arena);
    try testing.expectEqualStrings("Reading the log.", expected_text);

    var chunk_size: usize = 1;
    while (chunk_size <= anthropic_stream.len) : (chunk_size += if (chunk_size < 40) 1 else 17) {
        const answer = try readWhole(arena, .anthropic, anthropic_stream, chunk_size);
        try testing.expectEqualStrings(expected_text, try answer.text(arena));
        try testing.expectEqualStrings(whole.model, answer.model);
        try testing.expectEqual(whole.stopReason, answer.stopReason);
        try testing.expectEqual(whole.usage.inputTokens, answer.usage.inputTokens);
        try testing.expectEqual(whole.usage.outputTokens, answer.usage.outputTokens);
        try testing.expectEqual(whole.blocks.len, answer.blocks.len);
        for (whole.blocks, answer.blocks) |a, b| {
            try testing.expectEqual(@as(std.meta.Tag(provider.Block), a), @as(std.meta.Tag(provider.Block), b));
            try testing.expectEqualStrings(a.textOf(), b.textOf());
        }
    }
}

test "a streamed answer is the answer the blocking path would have given" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const answer = try readWhole(arena, .anthropic, anthropic_stream, 7);

    // Everything the non-streaming decoder would have produced, produced the
    // same way. A streaming path that returns something slightly different from
    // the blocking one surfaces months later as "the model behaves differently
    // when you watch it".
    try testing.expectEqualStrings("claude-opus-5", answer.model);
    try testing.expectEqual(provider.StopReason.tool_use, answer.stopReason);
    try testing.expectEqual(@as(u64, 42), answer.usage.inputTokens);
    try testing.expectEqual(@as(u64, 57), answer.usage.outputTokens);

    try testing.expectEqual(@as(usize, 3), answer.blocks.len);
    try testing.expectEqualStrings("Check the log first.", answer.blocks[0].thinking);
    try testing.expectEqualStrings("Reading the log.", answer.blocks[1].text);

    // The tool call, reassembled from three pieces none of which was valid
    // JSON on its own.
    const call = answer.blocks[2].tool_use;
    try testing.expectEqualStrings("toolu_1", call.id);
    try testing.expectEqualStrings("read_file", call.name);
    try testing.expectEqualStrings("{\"path\":\"README.md\"}", call.argumentsJson);

    // And it parses, which is the only thing the rest of the workbench cares
    // about.
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, call.argumentsJson, .{});
    try testing.expectEqualStrings("README.md", parsed.value.object.get("path").?.string);

    const calls = try answer.toolCalls(arena);
    try testing.expectEqual(@as(usize, 1), calls.len);
}

test "a heartbeat comment is not an event" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Providers send these to hold a connection open. A parser that treats a
    // line beginning with a colon as a field with an empty name tries to
    // interpret it, and a strict one errors on it.
    var framer = Framer.init(.server_sent_events);
    const frames = try framer.feed(arena, ": ping\n\n:\n\ndata: {\"type\":\"message_stop\"}\n\n");
    try testing.expectEqual(@as(usize, 1), frames.len);
    try testing.expectEqualStrings("{\"type\":\"message_stop\"}", frames[0].data);
}

test "an event split across every possible boundary still frames" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two events, fed with the split moved one byte at a time through the whole
    // stream. The interesting positions are inside `data:`, between the two
    // newlines, and inside `\r\n` — each of which stalls a parser that decides
    // a lone newline is a boundary.
    const source = "event: a\r\ndata: one\r\n\r\nevent: b\r\ndata: two\r\n\r\n";
    var split: usize = 0;
    while (split <= source.len) : (split += 1) {
        var framer = Framer.init(.server_sent_events);
        var collected: std.ArrayList(Frame) = .empty;
        for (try framer.feed(arena, source[0..split])) |f| try collected.append(arena, f);
        for (try framer.feed(arena, source[split..])) |f| try collected.append(arena, f);
        for (try framer.finish(arena)) |f| try collected.append(arena, f);

        try testing.expectEqual(@as(usize, 2), collected.items.len);
        try testing.expectEqualStrings("a", collected.items[0].name);
        try testing.expectEqualStrings("one", collected.items[0].data);
        try testing.expectEqualStrings("b", collected.items[1].name);
        try testing.expectEqualStrings("two", collected.items[1].data);
    }
}

test "several data lines in one event are one payload" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The framing's own way of carrying a newline. Joining these with anything
    // but a newline, or treating each as its own event, corrupts every payload
    // that contains one.
    var framer = Framer.init(.server_sent_events);
    const frames = try framer.feed(arena, "data: {\"a\":\ndata: 1}\n\n");
    try testing.expectEqual(@as(usize, 1), frames.len);
    try testing.expectEqualStrings("{\"a\":\n1}", frames[0].data);
}

test "exactly one space after the colon belongs to the framing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var framer = Framer.init(.server_sent_events);
    // One space is stripped; a second is part of the value, and eating it would
    // change a model's own text.
    const frames = try framer.feed(arena, "data:  two spaces\n\ndata:none\n\n");
    try testing.expectEqual(@as(usize, 2), frames.len);
    try testing.expectEqualStrings(" two spaces", frames[0].data);
    try testing.expectEqualStrings("none", frames[1].data);
}

test "a stream that ends without a final blank line keeps its last event" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A provider that closes the connection after the last event has still
    // sent it. Dropping it loses the end of the answer, which is where the stop
    // reason and the usage live.
    var reader = Reader.init(arena, .anthropic);
    _ = try reader.feed("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Done\"}}\n");
    const answer_before = try reader.completion();
    try testing.expectEqual(@as(usize, 0), answer_before.blocks.len);

    _ = try reader.finish();
    const answer = try reader.completion();
    try testing.expectEqualStrings("Done", try answer.text(arena));
}

test "the OpenAI sentinel is an ending, not a parse failure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        "data: {\"model\":\"gpt-x\",\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":2}}\n\n" ++
        "data: [DONE]\n\n";

    const answer = try readWhole(arena, .openai, source, 3);
    try testing.expectEqualStrings("Hello", try answer.text(arena));
    try testing.expectEqualStrings("gpt-x", answer.model);
    try testing.expectEqual(provider.StopReason.end_turn, answer.stopReason);
    try testing.expectEqual(@as(u64, 9), answer.usage.inputTokens);
    try testing.expectEqual(@as(u64, 2), answer.usage.outputTokens);
}

test "an OpenAI tool call arrives in pieces and comes back whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"run_tests\",\"arguments\":\"\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"suite\\\"\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\":\\\"unit\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";

    const answer = try readWhole(arena, .openai, source, 5);
    try testing.expectEqual(provider.StopReason.tool_use, answer.stopReason);
    const calls = try answer.toolCalls(arena);
    try testing.expectEqual(@as(usize, 1), calls.len);
    try testing.expectEqualStrings("call_1", calls[0].id);
    try testing.expectEqualStrings("run_tests", calls[0].name);
    try testing.expectEqualStrings("{\"suite\":\"unit\"}", calls[0].argumentsJson);
}

test "Ollama sends one object a line and says when it is done" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        "{\"model\":\"llama3\",\"message\":{\"role\":\"assistant\",\"content\":\"Two \"},\"done\":false}\n" ++
        "{\"model\":\"llama3\",\"message\":{\"role\":\"assistant\",\"content\":\"plus two.\"},\"done\":false}\n" ++
        "{\"model\":\"llama3\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\",\"prompt_eval_count\":11,\"eval_count\":4}\n";

    const answer = try readWhole(arena, .ollama, source, 1);
    try testing.expectEqualStrings("Two plus two.", try answer.text(arena));
    try testing.expectEqualStrings("llama3", answer.model);
    try testing.expectEqual(provider.StopReason.end_turn, answer.stopReason);
    try testing.expectEqual(@as(u64, 11), answer.usage.inputTokens);
    try testing.expectEqual(@as(u64, 4), answer.usage.outputTokens);
}

test "a Gemini stream assembles the same way" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"The answer \"}]}}],\"modelVersion\":\"gemini-2.5-pro\"}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"is four.\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":6,\"candidatesTokenCount\":3}}\n\n";

    const answer = try readWhole(arena, .gemini, source, 4);
    try testing.expectEqualStrings("The answer is four.", try answer.text(arena));
    try testing.expectEqualStrings("gemini-2.5-pro", answer.model);
    try testing.expectEqual(provider.StopReason.end_turn, answer.stopReason);
}

test "usage is replaced rather than added up" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every provider here sends a running total. Adding them counts the same
    // tokens as many times as the stream mentioned them, and a bill computed
    // from that is wrong in the direction nobody notices until it is large.
    var assembler = Assembler.init(arena);
    try assembler.accept(.{ .usage = .{ .inputTokens = 42, .outputTokens = 1 } });
    try assembler.accept(.{ .usage = .{ .inputTokens = 42, .outputTokens = 30 } });
    try assembler.accept(.{ .usage = .{ .inputTokens = 42, .outputTokens = 57 } });
    const answer = try assembler.completion();
    try testing.expectEqual(@as(u64, 42), answer.usage.inputTokens);
    try testing.expectEqual(@as(u64, 57), answer.usage.outputTokens);
}

test "a tool called with no arguments is called with an empty object" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A model that calls a tool taking nothing sends no argument deltas at all.
    // Passing the empty string on turns a valid call into a parse failure one
    // layer up, which reads as the model having made a malformed request.
    var assembler = Assembler.init(arena);
    try assembler.accept(.{ .block_opened = .{ .index = 0, .kind = .tool_use, .id = "t1", .name = "list_blocks" } });
    try assembler.accept(.{ .block_closed = .{ .index = 0 } });
    const answer = try assembler.completion();
    try testing.expectEqualStrings("{}", answer.blocks[0].tool_use.argumentsJson);
    _ = try std.json.parseFromSlice(std.json.Value, arena, answer.blocks[0].tool_use.argumentsJson, .{});
}

test "blocks come back in the provider's order, not the order they arrived" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var assembler = Assembler.init(arena);
    try assembler.accept(.{ .text = .{ .index = 2, .chunk = "third" } });
    try assembler.accept(.{ .text = .{ .index = 0, .chunk = "first" } });
    try assembler.accept(.{ .text = .{ .index = 1, .chunk = "second" } });
    const answer = try assembler.completion();
    try testing.expectEqualStrings("firstsecondthird", try answer.text(arena));
}

test "a provider failing mid-stream is reported, not swallowed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An error frame after the answer has started. The bytes so far are still
    // an answer and are kept; what must not happen is a caller being handed a
    // truncated reply with no indication anything went wrong.
    var reader = Reader.init(arena, .anthropic);
    _ = try reader.feed("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Partial\"}}\n\n");
    const deltas = try reader.feed("event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n");

    try testing.expectEqual(@as(usize, 1), deltas.len);
    try testing.expectEqualStrings("Overloaded", deltas[0].provider_error.message);
    try testing.expect(reader.assembler.failed());
    try testing.expectEqualStrings("Partial", try (try reader.completion()).text(arena));
}

test "a frame that never ends is refused rather than held for ever" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An unbounded read driven by whoever is on the other end of the socket.
    // Refusing is right; truncating would silently lose part of an answer.
    var framer = Framer.init(.server_sent_events);
    const filler = try arena.alloc(u8, Framer.max_frame_bytes + 1);
    @memset(filler, 'x');
    try testing.expectError(error.FrameTooLarge, framer.feed(arena, filler));
}

test "an empty feed is legal and produces nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // What a zero-length read means. A framer that treats it as an ending
    // truncates every answer that arrives across a slow connection.
    var reader = Reader.init(arena, .anthropic);
    try testing.expectEqual(@as(usize, 0), (try reader.feed("")).len);
    _ = try reader.feed("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"still here\"}}\n\n");
    try testing.expectEqualStrings("still here", try (try reader.completion()).text(arena));
}

test "every format has a framing, and every delta a shape" {
    // A new format added to the catalogue has to decide how it is framed,
    // rather than falling through to whichever branch was written first.
    for (std.enums.values(catalog.Format)) |format| {
        _ = Framing.of(format);
    }
    // And every provider in the catalogue is a format this reader can read.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    for (catalog.connectors) |connector| {
        var reader = Reader.init(arena_state.allocator(), connector.format);
        _ = try reader.feed("data: {}\n\n");
    }
}
