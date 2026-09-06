//! The OpenAI chat-completions shape.
//!
//! This one connector reaches more providers than all the others together.
//! Groq, Together, Fireworks, OpenRouter, DeepSeek, Mistral, xAI, Cerebras,
//! Nebius, DeepInfra, vLLM, LM Studio, LocalAI, llama.cpp's server and Hugging
//! Face's router all accept this request shape at a different address. That is
//! why it is worth writing carefully once.
//!
//! Where it differs from the Anthropic shape:
//!
//!   * The system prompt is the first message, not a field beside them.
//!   * A tool call is a field on the assistant message, not a content block,
//!     and its arguments are a JSON *string* rather than an object.
//!   * A tool result is a message with the role `tool`.
//!
//! `max_tokens` is deprecated in favour of `max_completion_tokens` on newer
//! OpenAI models, but most compatible servers still only understand the older
//! name. Both are sent: servers ignore what they do not know, and the two never
//! disagree because they are written from one value.

const std = @import("std");
const provider = @import("../provider.zig");
const shared = @import("anthropic.zig");

pub const wire: provider.Wire = .{ .id = "openai", .encode = encode, .decode = decode };

pub fn encode(
    arena: std.mem.Allocator,
    endpoint: provider.Endpoint,
    request: provider.Request,
) anyerror!provider.HttpRequest {
    var body: std.Io.Writer.Allocating = .init(arena);
    const w = &body.writer;

    try w.writeAll("{\"model\":");
    try provider.writeJsonString(w, request.model);
    try w.print(",\"max_tokens\":{d},\"max_completion_tokens\":{d}", .{
        request.maxOutputTokens,
        request.maxOutputTokens,
    });
    if (request.temperature) |t| try w.print(",\"temperature\":{d}", .{t});
    if (request.stream) try w.writeAll(",\"stream\":true");

    if (request.tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (request.tools, 0..) |tool, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
            try provider.writeJsonString(w, tool.name);
            try w.writeAll(",\"description\":");
            try provider.writeJsonString(w, tool.description);
            if (tool.strict) try w.writeAll(",\"strict\":true");
            try w.writeAll(",\"parameters\":");
            try w.writeAll(tool.schemaJson);
            try w.writeAll("}}");
        }
        try w.writeAll("]");
    }

    try w.writeAll(",\"messages\":[");
    var wrote_any = false;
    if (request.system.len > 0) {
        try w.writeAll("{\"role\":\"system\",\"content\":");
        try provider.writeJsonString(w, request.system);
        try w.writeAll("}");
        wrote_any = true;
    }

    for (request.messages) |message| {
        // A tool result is its own message here, so one neutral message can
        // become several.
        var tool_results: usize = 0;
        for (message.blocks) |block| {
            if (block == .tool_result) tool_results += 1;
        }
        if (tool_results > 0) {
            for (message.blocks) |block| {
                switch (block) {
                    .tool_result => |result| {
                        if (wrote_any) try w.writeAll(",");
                        try w.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                        try provider.writeJsonString(w, result.toolUseId);
                        try w.writeAll(",\"content\":");
                        try provider.writeJsonString(w, result.content);
                        try w.writeAll("}");
                        wrote_any = true;
                    },
                    else => {},
                }
            }
            continue;
        }

        if (wrote_any) try w.writeAll(",");
        try w.writeAll("{\"role\":\"");
        try w.writeAll(@tagName(message.role));
        try w.writeAll("\",\"content\":");
        try provider.writeJsonString(w, try message.plainText(arena));

        var calls: usize = 0;
        for (message.blocks) |block| {
            if (block == .tool_use) calls += 1;
        }
        if (calls > 0) {
            try w.writeAll(",\"tool_calls\":[");
            var written: usize = 0;
            for (message.blocks) |block| {
                switch (block) {
                    .tool_use => |call| {
                        if (written > 0) try w.writeAll(",");
                        try w.writeAll("{\"id\":");
                        try provider.writeJsonString(w, call.id);
                        try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try provider.writeJsonString(w, call.name);
                        // Arguments are a JSON string here, not an object, so
                        // the JSON text is quoted into one.
                        try w.writeAll(",\"arguments\":");
                        try provider.writeJsonString(w, call.argumentsJson);
                        try w.writeAll("}}");
                        written += 1;
                    },
                    else => {},
                }
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");
        wrote_any = true;
    }
    try w.writeAll("]}");

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
        .url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{endpoint.baseUrl}),
        .headers = headers.items,
        .body = body.written(),
        .host = endpoint.host(),
    };
}

pub fn decode(arena: std.mem.Allocator, body: []const u8) anyerror!provider.Completion {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch {
        return error.MalformedResponse;
    };
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.MalformedResponse,
    };
    if (root.get("error")) |err| {
        if (err == .object or err == .string) return error.ProviderError;
    }

    const choices = root.get("choices") orelse return error.MalformedResponse;
    if (choices != .array or choices.array.items.len == 0) return error.MalformedResponse;
    const choice = switch (choices.array.items[0]) {
        .object => |o| o,
        else => return error.MalformedResponse,
    };
    const message = switch (choice.get("message") orelse return error.MalformedResponse) {
        .object => |o| o,
        else => return error.MalformedResponse,
    };

    var blocks: std.ArrayList(provider.Block) = .empty;
    if (shared.stringField(message, "content")) |text| {
        if (text.len > 0) try blocks.append(arena, .{ .text = text });
    }
    // Some servers put the model's reasoning in a field of its own.
    if (shared.stringField(message, "reasoning_content")) |text| {
        if (text.len > 0) try blocks.append(arena, .{ .thinking = text });
    }
    if (message.get("tool_calls")) |calls| {
        if (calls == .array) {
            for (calls.array.items) |item| {
                if (item != .object) continue;
                const call = item.object;
                const function = switch (call.get("function") orelse continue) {
                    .object => |o| o,
                    else => continue,
                };
                try blocks.append(arena, .{ .tool_use = .{
                    .id = shared.stringField(call, "id") orelse "",
                    .name = shared.stringField(function, "name") orelse "",
                    .argumentsJson = shared.stringField(function, "arguments") orelse "{}",
                } });
            }
        }
    }

    var usage: provider.Usage = .{};
    if (root.get("usage")) |u| {
        if (u == .object) {
            usage.inputTokens = shared.intField(u.object, "prompt_tokens");
            usage.outputTokens = shared.intField(u.object, "completion_tokens");
        }
    }

    return .{
        .model = shared.stringField(root, "model") orelse "",
        .blocks = blocks.items,
        .stopReason = stopReasonFrom(shared.stringField(choice, "finish_reason")),
        .usage = usage,
        .id = shared.stringField(root, "id") orelse "",
    };
}

fn stopReasonFrom(name: ?[]const u8) provider.StopReason {
    const text = name orelse return .unknown;
    if (std.mem.eql(u8, text, "stop")) return .end_turn;
    if (std.mem.eql(u8, text, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, text, "function_call")) return .tool_use;
    if (std.mem.eql(u8, text, "length")) return .max_tokens;
    if (std.mem.eql(u8, text, "content_filter")) return .refusal;
    return .unknown;
}

const testing = std.testing;

test "the system prompt becomes the first message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const http = try encode(arena, .{ .baseUrl = "https://api.openai.com/v1", .apiKey = "sk-test" }, .{
        .model = "gpt-4.1",
        .system = "Be brief.",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "Hello" }} }},
    });
    try testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", http.url);
    try testing.expect(std.mem.indexOf(u8, http.body, "{\"role\":\"system\",\"content\":\"Be brief.\"}") != null);

    var saw_bearer = false;
    for (http.headers) |header| {
        if (std.mem.eql(u8, header.name, "authorization")) {
            saw_bearer = true;
            try testing.expectEqualStrings("Bearer sk-test", header.value);
        }
    }
    try testing.expect(saw_bearer);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, http.body, .{});
    try testing.expect(parsed.value == .object);
}

test "a tool result becomes a message with the tool role" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const http = try encode(arena, .{ .baseUrl = "http://localhost:1234/v1" }, .{
        .model = "local-model",
        .messages = &.{
            .{ .role = .user, .blocks = &.{.{ .text = "Read a.txt" }} },
            .{ .role = .assistant, .blocks = &.{.{ .tool_use = .{
                .id = "call_1",
                .name = "read_file",
                .argumentsJson = "{\"path\":\"a.txt\"}",
            } }} },
            .{ .role = .user, .blocks = &.{.{ .tool_result = .{
                .toolUseId = "call_1",
                .content = "file contents",
            } }} },
        },
    });

    try testing.expect(std.mem.indexOf(u8, http.body, "\"role\":\"tool\"") != null);
    try testing.expect(std.mem.indexOf(u8, http.body, "\"tool_call_id\":\"call_1\"") != null);
    // Arguments are a quoted JSON string in this shape, not an object.
    try testing.expect(std.mem.indexOf(u8, http.body, "\"arguments\":\"{\\\"path\\\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, http.body, .{});
    try testing.expect(parsed.value == .object);
}

test "an answer with a tool call decodes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"id":"chatcmpl-1","model":"gpt-4.1","choices":[
        \\  {"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,
        \\   "tool_calls":[{"id":"call_9","type":"function",
        \\                  "function":{"name":"read_file","arguments":"{\"path\":\"a.txt\"}"}}]}}],
        \\ "usage":{"prompt_tokens":30,"completion_tokens":12}}
    ;
    const completion = try decode(arena, body);
    try testing.expectEqual(provider.StopReason.tool_use, completion.stopReason);
    const calls = try completion.toolCalls(arena);
    try testing.expectEqual(@as(usize, 1), calls.len);
    try testing.expectEqualStrings("read_file", calls[0].name);
    try testing.expectEqualStrings("{\"path\":\"a.txt\"}", calls[0].argumentsJson);
    try testing.expectEqual(@as(u64, 30), completion.usage.inputTokens);
}

test "finish reasons map to the neutral ones" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { given: []const u8, want: provider.StopReason }{
        .{ .given = "stop", .want = .end_turn },
        .{ .given = "length", .want = .max_tokens },
        .{ .given = "content_filter", .want = .refusal },
        .{ .given = "something_new", .want = .unknown },
    };
    for (cases) |case| {
        const body = try std.fmt.allocPrint(arena,
            \\{{"id":"x","model":"m","choices":[{{"finish_reason":"{s}","message":{{"content":"hi"}}}}]}}
        , .{case.given});
        const completion = try decode(arena, body);
        try testing.expectEqual(case.want, completion.stopReason);
    }
}

test "reasoning returned in its own field becomes a thinking block" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"id":"x","model":"deepseek-reasoner","choices":[{"finish_reason":"stop",
        \\ "message":{"role":"assistant","content":"42","reasoning_content":"working it out"}}]}
    ;
    const completion = try decode(arena, body);
    try testing.expectEqualStrings("42", try completion.text(arena));
    var saw_thinking = false;
    for (completion.blocks) |block| {
        if (block == .thinking) saw_thinking = true;
    }
    try testing.expect(saw_thinking);
}

test "an error body is reported rather than decoded as an answer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.ProviderError, decode(arena,
        \\{"error":{"message":"model not found","type":"invalid_request_error"}}
    ));
    // No choices at all is malformed, not an empty answer.
    try testing.expectError(error.MalformedResponse, decode(arena, "{\"choices\":[]}"));
}
