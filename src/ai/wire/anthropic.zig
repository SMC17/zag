//! The Anthropic Messages API.
//!
//! This is the first connector, and the one this workbench was written
//! alongside. The shape it speaks is `POST /v1/messages`: a system prompt beside
//! the messages rather than inside them, content as a list of typed blocks, and
//! tool calls as blocks in the assistant's own content.
//!
//! Two details of the current API are easy to get wrong from memory, so they
//! are written down here rather than assumed:
//!
//!   * Sampling parameters are **rejected** on the current models. Sending
//!     `temperature` to Claude Opus 5 is a 400, not a hint that is ignored. The
//!     neutral request leaves temperature unset by default and this connector
//!     only sends it when a caller explicitly set one.
//!   * Thinking is configured as `{"type": "adaptive"}`. A fixed token budget
//!     is not part of this API any more and is refused.
//!
//! A refusal arrives as a normal answer with `stop_reason` of `refusal`, not as
//! an HTTP error. It is decoded as a completion with that stop reason, because
//! a model declining is a result the record should keep, not a fault.

const std = @import("std");
const provider = @import("../provider.zig");

pub const Request = provider.Request;
pub const Completion = provider.Completion;
pub const Endpoint = provider.Endpoint;
pub const HttpRequest = provider.HttpRequest;

/// The version header the API requires on every request.
pub const api_version = "2023-06-01";

pub const wire: provider.Wire = .{ .id = "anthropic", .encode = encode, .decode = decode };

pub fn encode(arena: std.mem.Allocator, endpoint: Endpoint, request: Request) anyerror!HttpRequest {
    var body: std.Io.Writer.Allocating = .init(arena);
    const w = &body.writer;

    try w.writeAll("{\"model\":");
    try provider.writeJsonString(w, request.model);
    try w.print(",\"max_tokens\":{d}", .{request.maxOutputTokens});

    if (request.system.len > 0) {
        try w.writeAll(",\"system\":");
        try provider.writeJsonString(w, request.system);
    }

    // Sampling is sent only when a caller asked for it. The current models
    // refuse it outright, so a helpful default here would break every request.
    if (request.temperature) |t| try w.print(",\"temperature\":{d}", .{t});

    if (request.showThinking) {
        try w.writeAll(",\"thinking\":{\"type\":\"adaptive\",\"display\":\"summarized\"}");
    }
    if (request.effort) |effort| {
        try w.print(",\"output_config\":{{\"effort\":\"{s}\"}}", .{@tagName(effort)});
    }
    if (request.stream) try w.writeAll(",\"stream\":true");

    if (request.tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (request.tools, 0..) |tool, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"name\":");
            try provider.writeJsonString(w, tool.name);
            try w.writeAll(",\"description\":");
            try provider.writeJsonString(w, tool.description);
            if (tool.strict) try w.writeAll(",\"strict\":true");
            try w.writeAll(",\"input_schema\":");
            // The schema is already JSON, so it is placed as-is rather than
            // quoted into a string.
            try w.writeAll(tool.schemaJson);
            try w.writeAll("}");
        }
        try w.writeAll("]");
    }

    try w.writeAll(",\"messages\":[");
    for (request.messages, 0..) |message, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"role\":\"");
        try w.writeAll(@tagName(message.role));
        try w.writeAll("\",\"content\":[");
        for (message.blocks, 0..) |block, b| {
            if (b > 0) try w.writeAll(",");
            switch (block) {
                .text => |text| {
                    try w.writeAll("{\"type\":\"text\",\"text\":");
                    try provider.writeJsonString(w, text);
                    try w.writeAll("}");
                },
                .thinking => |text| {
                    // Reasoning is echoed back unchanged when continuing with
                    // the same model; changing it invalidates the block.
                    try w.writeAll("{\"type\":\"thinking\",\"thinking\":");
                    try provider.writeJsonString(w, text);
                    try w.writeAll("}");
                },
                .tool_use => |call| {
                    try w.writeAll("{\"type\":\"tool_use\",\"id\":");
                    try provider.writeJsonString(w, call.id);
                    try w.writeAll(",\"name\":");
                    try provider.writeJsonString(w, call.name);
                    try w.writeAll(",\"input\":");
                    try w.writeAll(if (call.argumentsJson.len > 0) call.argumentsJson else "{}");
                    try w.writeAll("}");
                },
                .tool_result => |result| {
                    try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
                    try provider.writeJsonString(w, result.toolUseId);
                    try w.writeAll(",\"content\":");
                    try provider.writeJsonString(w, result.content);
                    if (result.isError) try w.writeAll(",\"is_error\":true");
                    try w.writeAll("}");
                },
            }
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");

    var headers: std.ArrayList(HttpRequest.Header) = .empty;
    try headers.append(arena, .{ .name = "content-type", .value = "application/json" });
    try headers.append(arena, .{ .name = "anthropic-version", .value = api_version });
    if (endpoint.apiKey.len > 0) {
        try headers.append(arena, .{ .name = "x-api-key", .value = endpoint.apiKey });
    }
    try headers.appendSlice(arena, endpoint.extraHeaders);

    return .{
        .url = try std.fmt.allocPrint(arena, "{s}/v1/messages", .{endpoint.baseUrl}),
        .headers = headers.items,
        .body = body.written(),
        .host = endpoint.host(),
    };
}

pub fn decode(arena: std.mem.Allocator, body: []const u8) anyerror!Completion {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch {
        return error.MalformedResponse;
    };
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.MalformedResponse,
    };

    // An error arrives as `{"type":"error","error":{"type":...,"message":...}}`.
    if (root.get("error")) |err| {
        if (err == .object) return error.ProviderError;
    }

    var blocks: std.ArrayList(provider.Block) = .empty;
    if (root.get("content")) |content| {
        if (content != .array) return error.MalformedResponse;
        for (content.array.items) |item| {
            if (item != .object) continue;
            const object = item.object;
            const kind = stringField(object, "type") orelse continue;
            if (std.mem.eql(u8, kind, "text")) {
                try blocks.append(arena, .{ .text = stringField(object, "text") orelse "" });
            } else if (std.mem.eql(u8, kind, "thinking")) {
                const text = stringField(object, "thinking") orelse "";
                // The default is to return an empty thinking block. An empty
                // one carries nothing, so it is left out rather than kept as a
                // block with no content.
                if (text.len > 0) try blocks.append(arena, .{ .thinking = text });
            } else if (std.mem.eql(u8, kind, "tool_use")) {
                var arguments: std.Io.Writer.Allocating = .init(arena);
                if (object.get("input")) |input| {
                    try std.json.Stringify.value(input, .{}, &arguments.writer);
                }
                try blocks.append(arena, .{ .tool_use = .{
                    .id = stringField(object, "id") orelse "",
                    .name = stringField(object, "name") orelse "",
                    .argumentsJson = arguments.written(),
                } });
            }
        }
    }

    var usage: provider.Usage = .{};
    if (root.get("usage")) |u| {
        if (u == .object) {
            usage.inputTokens = intField(u.object, "input_tokens");
            usage.outputTokens = intField(u.object, "output_tokens");
            usage.cacheReadTokens = intField(u.object, "cache_read_input_tokens");
            usage.cacheWriteTokens = intField(u.object, "cache_creation_input_tokens");
        }
    }

    var refusal_category: ?[]const u8 = null;
    if (root.get("stop_details")) |details| {
        if (details == .object) refusal_category = stringField(details.object, "category");
    }

    return .{
        .model = stringField(root, "model") orelse "",
        .blocks = blocks.items,
        .stopReason = stopReasonFrom(stringField(root, "stop_reason")),
        .usage = usage,
        .refusalCategory = refusal_category,
        .id = stringField(root, "id") orelse "",
    };
}

fn stopReasonFrom(name: ?[]const u8) provider.StopReason {
    const text = name orelse return .unknown;
    if (std.mem.eql(u8, text, "end_turn")) return .end_turn;
    if (std.mem.eql(u8, text, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, text, "max_tokens")) return .max_tokens;
    if (std.mem.eql(u8, text, "refusal")) return .refusal;
    if (std.mem.eql(u8, text, "stop_sequence")) return .stop_sequence;
    return .unknown;
}

pub fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

pub fn intField(object: std.json.ObjectMap, name: []const u8) u64 {
    const value = object.get(name) orelse return 0;
    return switch (value) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        else => 0,
    };
}

const testing = std.testing;

test "a request carries the version header and the key, and no sampling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const http = try encode(arena, .{
        .baseUrl = "https://api.anthropic.com",
        .apiKey = "sk-ant-test",
    }, .{
        .model = "claude-opus-5",
        .system = "You are careful.",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "Hello" }} }},
    });

    try testing.expectEqualStrings("https://api.anthropic.com/v1/messages", http.url);
    try testing.expectEqualStrings("api.anthropic.com", http.host);

    var saw_version = false;
    var saw_key = false;
    for (http.headers) |header| {
        if (std.mem.eql(u8, header.name, "anthropic-version")) {
            saw_version = true;
            try testing.expectEqualStrings(api_version, header.value);
        }
        if (std.mem.eql(u8, header.name, "x-api-key")) saw_key = true;
    }
    try testing.expect(saw_version);
    try testing.expect(saw_key);

    // Sampling is absent unless it was asked for. The current models reject it.
    try testing.expect(std.mem.indexOf(u8, http.body, "temperature") == null);
    try testing.expect(std.mem.indexOf(u8, http.body, "\"model\":\"claude-opus-5\"") != null);
    try testing.expect(std.mem.indexOf(u8, http.body, "\"system\":\"You are careful.\"") != null);

    // The body is valid JSON, not a string that happens to look like it.
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, http.body, .{});
    try testing.expect(parsed.value == .object);
}

test "thinking and effort are sent in the shape the API takes now" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const http = try encode(arena, .{ .baseUrl = "https://api.anthropic.com" }, .{
        .model = "claude-opus-5",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "Think about this." }} }},
        .showThinking = true,
        .effort = .high,
    });
    try testing.expect(std.mem.indexOf(u8, http.body, "\"thinking\":{\"type\":\"adaptive\"") != null);
    try testing.expect(std.mem.indexOf(u8, http.body, "\"output_config\":{\"effort\":\"high\"}") != null);
    // A fixed thinking budget is not part of this API and must never be sent.
    try testing.expect(std.mem.indexOf(u8, http.body, "budget_tokens") == null);
}

test "a tool call round-trips through the wire" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const http = try encode(arena, .{ .baseUrl = "https://api.anthropic.com" }, .{
        .model = "claude-opus-5",
        .tools = &.{.{
            .name = "read_file",
            .description = "Read a file in the workspace.",
            .schemaJson = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
        }},
        .messages = &.{
            .{ .role = .user, .blocks = &.{.{ .text = "Read a.txt" }} },
            .{ .role = .assistant, .blocks = &.{.{ .tool_use = .{
                .id = "toolu_1",
                .name = "read_file",
                .argumentsJson = "{\"path\":\"a.txt\"}",
            } }} },
            .{ .role = .user, .blocks = &.{.{ .tool_result = .{
                .toolUseId = "toolu_1",
                .content = "the file contents",
            } }} },
        },
    });

    // The schema goes in as JSON, not as a quoted string.
    try testing.expect(std.mem.indexOf(u8, http.body, "\"input_schema\":{\"type\":\"object\"") != null);
    try testing.expect(std.mem.indexOf(u8, http.body, "\"tool_use_id\":\"toolu_1\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, http.body, .{});
    try testing.expect(parsed.value == .object);
}

test "an answer decodes into blocks, a stop reason and usage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5",
        \\ "content":[{"type":"text","text":"I will read it."},
        \\            {"type":"tool_use","id":"toolu_9","name":"read_file","input":{"path":"a.txt"}}],
        \\ "stop_reason":"tool_use",
        \\ "usage":{"input_tokens":41,"output_tokens":18,"cache_read_input_tokens":7}}
    ;
    const completion = try decode(arena, body);
    try testing.expectEqualStrings("claude-opus-5", completion.model);
    try testing.expectEqualStrings("msg_01", completion.id);
    try testing.expectEqual(provider.StopReason.tool_use, completion.stopReason);
    try testing.expectEqualStrings("I will read it.", try completion.text(arena));

    const calls = try completion.toolCalls(arena);
    try testing.expectEqual(@as(usize, 1), calls.len);
    try testing.expectEqualStrings("read_file", calls[0].name);
    // The arguments stay as JSON text, for the policy engine to read.
    try testing.expect(std.mem.indexOf(u8, calls[0].argumentsJson, "\"path\"") != null);

    try testing.expectEqual(@as(u64, 41), completion.usage.inputTokens);
    try testing.expectEqual(@as(u64, 7), completion.usage.cacheReadTokens);
}

test "a refusal is a result, not a failure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"id":"msg_02","model":"claude-opus-5","content":[],
        \\ "stop_reason":"refusal",
        \\ "stop_details":{"type":"refusal","category":"cyber"},
        \\ "usage":{"input_tokens":10,"output_tokens":0}}
    ;
    const completion = try decode(arena, body);
    try testing.expectEqual(provider.StopReason.refusal, completion.stopReason);
    try testing.expectEqualStrings("cyber", completion.refusalCategory.?);
}

test "a provider error is reported as one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens is required"}}
    ;
    try testing.expectError(error.ProviderError, decode(arena, body));
    try testing.expectError(error.MalformedResponse, decode(arena, "not json at all"));
}

test "an empty thinking block is left out rather than kept as nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"id":"m","model":"claude-opus-5","stop_reason":"end_turn",
        \\ "content":[{"type":"thinking","thinking":""},{"type":"text","text":"Done."}]}
    ;
    const completion = try decode(arena, body);
    try testing.expectEqual(@as(usize, 1), completion.blocks.len);
    try testing.expectEqualStrings("Done.", try completion.text(arena));
}
