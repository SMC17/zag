//! Hugging Face text generation, in the shape a served model speaks.
//!
//! Hugging Face reaches models two ways, and the difference matters when
//! choosing a connector. Its router at `router.huggingface.co/v1` speaks the
//! OpenAI shape, so the `openai` connector serves it and every inference
//! provider behind it. This connector speaks the *other* one: the plain
//! text-generation endpoint that Text Generation Inference exposes, which is
//! what a self-hosted model, an inference endpoint, or a container on a
//! workstation actually serves.
//!
//! That shape has no notion of a conversation. There is one string in and one
//! string out. So the messages are rendered into a prompt here, and the
//! rendering is written out plainly rather than hidden, because a template is
//! the part that decides how well a model behaves and a person tuning one
//! needs to see it. There are no tools: a model behind this endpoint cannot be
//! given any, and this connector says so rather than dropping them quietly.

const std = @import("std");
const provider = @import("../provider.zig");
const shared = @import("anthropic.zig");

pub const wire: provider.Wire = .{ .id = "huggingface", .encode = encode, .decode = decode };

/// Render a conversation as one prompt.
///
/// The form is the plain chat transcript that instruction-tuned models are used
/// to. A served model with its own chat template will apply that instead; this
/// is what is sent when there is none.
pub fn renderPrompt(arena: std.mem.Allocator, request: provider.Request) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (request.system.len > 0) {
        try out.appendSlice(arena, "System: ");
        try out.appendSlice(arena, request.system);
        try out.appendSlice(arena, "\n\n");
    }
    for (request.messages) |message| {
        const label = switch (message.role) {
            .user => "User: ",
            .assistant => "Assistant: ",
            .system => "System: ",
        };
        try out.appendSlice(arena, label);
        try out.appendSlice(arena, try message.plainText(arena));
        try out.appendSlice(arena, "\n\n");
    }
    try out.appendSlice(arena, "Assistant:");
    return out.items;
}

pub fn encode(
    arena: std.mem.Allocator,
    endpoint: provider.Endpoint,
    request: provider.Request,
) anyerror!provider.HttpRequest {
    var body: std.Io.Writer.Allocating = .init(arena);
    const w = &body.writer;

    try w.writeAll("{\"inputs\":");
    try provider.writeJsonString(w, try renderPrompt(arena, request));
    try w.print(",\"parameters\":{{\"max_new_tokens\":{d},\"return_full_text\":false", .{
        request.maxOutputTokens,
    });
    if (request.temperature) |t| {
        // This endpoint rejects a temperature of exactly zero; the nearest
        // meaning is sampling turned off.
        if (t <= 0) {
            try w.writeAll(",\"do_sample\":false");
        } else {
            try w.print(",\"temperature\":{d},\"do_sample\":true", .{t});
        }
    }
    try w.writeAll("}");
    try w.print(",\"stream\":{s}}}", .{if (request.stream) "true" else "false"});

    var headers: std.ArrayList(provider.HttpRequest.Header) = .empty;
    try headers.append(arena, .{ .name = "content-type", .value = "application/json" });
    if (endpoint.apiKey.len > 0) {
        try headers.append(arena, .{
            .name = "authorization",
            .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{endpoint.apiKey}),
        });
    }
    try headers.appendSlice(arena, endpoint.extraHeaders);

    return .{
        .url = try std.fmt.allocPrint(arena, "{s}/generate", .{endpoint.baseUrl}),
        .headers = headers.items,
        .body = body.written(),
        .host = endpoint.host(),
    };
}

pub fn decode(arena: std.mem.Allocator, body: []const u8) anyerror!provider.Completion {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch {
        return error.MalformedResponse;
    };

    // Two shapes are served in the wild: a bare object, and a list of them.
    const object = switch (parsed.value) {
        .object => |o| o,
        .array => |items| blk: {
            if (items.items.len == 0) return error.MalformedResponse;
            break :blk switch (items.items[0]) {
                .object => |o| o,
                else => return error.MalformedResponse,
            };
        },
        else => return error.MalformedResponse,
    };

    if (object.get("error")) |_| return error.ProviderError;

    const text = shared.stringField(object, "generated_text") orelse return error.MalformedResponse;
    var blocks: std.ArrayList(provider.Block) = .empty;
    if (text.len > 0) try blocks.append(arena, .{ .text = text });

    var usage: provider.Usage = .{};
    var stop: provider.StopReason = .end_turn;
    if (object.get("details")) |details| {
        if (details == .object) {
            usage.outputTokens = shared.intField(details.object, "generated_tokens");
            if (shared.stringField(details.object, "finish_reason")) |reason| {
                stop = if (std.mem.eql(u8, reason, "length")) .max_tokens else .end_turn;
            }
        }
    }

    return .{
        .model = "",
        .blocks = blocks.items,
        .stopReason = stop,
        .usage = usage,
    };
}

const testing = std.testing;

test "a conversation renders into one prompt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prompt = try renderPrompt(arena, .{
        .model = "meta-llama/Llama-3.1-8B-Instruct",
        .system = "Answer in one word.",
        .messages = &.{
            .{ .role = .user, .blocks = &.{.{ .text = "Two plus two?" }} },
            .{ .role = .assistant, .blocks = &.{.{ .text = "Four" }} },
            .{ .role = .user, .blocks = &.{.{ .text = "And three more?" }} },
        },
    });
    try testing.expect(std.mem.startsWith(u8, prompt, "System: Answer in one word."));
    try testing.expect(std.mem.indexOf(u8, prompt, "User: Two plus two?") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Assistant: Four") != null);
    // It ends ready for the model to continue.
    try testing.expect(std.mem.endsWith(u8, prompt, "Assistant:"));
}

test "the request asks only for the new text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const http = try encode(arena, .{
        .baseUrl = "https://my-endpoint.endpoints.huggingface.cloud",
        .apiKey = "hf_test",
    }, .{
        .model = "tgi",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "Hello" }} }},
        .maxOutputTokens = 256,
    });
    try testing.expect(std.mem.endsWith(u8, http.url, "/generate"));
    try testing.expect(std.mem.indexOf(u8, http.body, "\"return_full_text\":false") != null);
    try testing.expect(std.mem.indexOf(u8, http.body, "\"max_new_tokens\":256") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, http.body, .{});
    try testing.expect(parsed.value == .object);
}

test "a temperature of zero turns sampling off rather than being rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const http = try encode(arena, .{ .baseUrl = "http://localhost:8080" }, .{
        .model = "tgi",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "Hi" }} }},
        .temperature = 0,
    });
    try testing.expect(std.mem.indexOf(u8, http.body, "\"do_sample\":false") != null);
    try testing.expect(std.mem.indexOf(u8, http.body, "\"temperature\":0") == null);
}

test "both served shapes decode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const as_list =
        \\[{"generated_text":"Seven.","details":{"finish_reason":"eos_token","generated_tokens":2}}]
    ;
    const from_list = try decode(arena, as_list);
    try testing.expectEqualStrings("Seven.", try from_list.text(arena));
    try testing.expectEqual(@as(u64, 2), from_list.usage.outputTokens);

    const as_object =
        \\{"generated_text":"Seven.","details":{"finish_reason":"length","generated_tokens":256}}
    ;
    const from_object = try decode(arena, as_object);
    try testing.expectEqual(provider.StopReason.max_tokens, from_object.stopReason);
}

test "an error is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.ProviderError, decode(arena,
        \\{"error":"Model is currently loading","estimated_time":20.0}
    ));
}
