//! Google's Gemini `generateContent` shape.
//!
//! It differs from the other two in ways that matter for translation. The
//! assistant's role is called `model`. Content is a list of `parts`, and a tool
//! call is a part with a `functionCall` object rather than a block with a type.
//! The system prompt is `systemInstruction`, a content object of its own. The
//! model name goes in the path rather than the body.
//!
//! Gemini gives a tool call no identifier. The neutral shape needs one to match
//! a result back to its call, so this connector uses the function's name. That
//! is a real limitation of the wire, not a choice: two calls to the same
//! function in one turn cannot be told apart, and the decoder says so rather
//! than inventing an identifier that would silently pair the wrong result with
//! the wrong call.

const std = @import("std");
const provider = @import("../provider.zig");
const shared = @import("anthropic.zig");

pub const wire: provider.Wire = .{ .id = "gemini", .encode = encode, .decode = decode };

pub fn encode(
    arena: std.mem.Allocator,
    endpoint: provider.Endpoint,
    request: provider.Request,
) anyerror!provider.HttpRequest {
    var body: std.Io.Writer.Allocating = .init(arena);
    const w = &body.writer;

    try w.writeAll("{");
    if (request.system.len > 0) {
        try w.writeAll("\"systemInstruction\":{\"parts\":[{\"text\":");
        try provider.writeJsonString(w, request.system);
        try w.writeAll("}]},");
    }

    try w.writeAll("\"contents\":[");
    var wrote_any = false;
    for (request.messages) |message| {
        if (wrote_any) try w.writeAll(",");
        try w.writeAll("{\"role\":\"");
        try w.writeAll(switch (message.role) {
            .user, .system => "user",
            .assistant => "model",
        });
        try w.writeAll("\",\"parts\":[");
        var parts: usize = 0;
        for (message.blocks) |block| {
            if (parts > 0) try w.writeAll(",");
            switch (block) {
                .text, .thinking => |text| {
                    try w.writeAll("{\"text\":");
                    try provider.writeJsonString(w, text);
                    try w.writeAll("}");
                },
                .tool_use => |call| {
                    try w.writeAll("{\"functionCall\":{\"name\":");
                    try provider.writeJsonString(w, call.name);
                    try w.writeAll(",\"args\":");
                    try w.writeAll(if (call.argumentsJson.len > 0) call.argumentsJson else "{}");
                    try w.writeAll("}}");
                },
                .tool_result => |result| {
                    try w.writeAll("{\"functionResponse\":{\"name\":");
                    try provider.writeJsonString(w, result.toolUseId);
                    try w.writeAll(",\"response\":{\"content\":");
                    try provider.writeJsonString(w, result.content);
                    try w.writeAll("}}}");
                },
            }
            parts += 1;
        }
        if (parts == 0) try w.writeAll("{\"text\":\"\"}");
        try w.writeAll("]}");
        wrote_any = true;
    }
    try w.writeAll("]");

    if (request.tools.len > 0) {
        try w.writeAll(",\"tools\":[{\"functionDeclarations\":[");
        for (request.tools, 0..) |tool, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"name\":");
            try provider.writeJsonString(w, tool.name);
            try w.writeAll(",\"description\":");
            try provider.writeJsonString(w, tool.description);
            try w.writeAll(",\"parameters\":");
            try w.writeAll(tool.schemaJson);
            try w.writeAll("}");
        }
        try w.writeAll("]}]");
    }

    try w.print(",\"generationConfig\":{{\"maxOutputTokens\":{d}", .{request.maxOutputTokens});
    if (request.temperature) |t| try w.print(",\"temperature\":{d}", .{t});
    try w.writeAll("}}");

    var headers: std.ArrayList(provider.HttpRequest.Header) = .empty;
    try headers.append(arena, .{ .name = "content-type", .value = "application/json" });
    // The key goes in a header rather than the query string, so it does not
    // land in a proxy log or a shell history.
    if (endpoint.apiKey.len > 0) {
        try headers.append(arena, .{ .name = "x-goog-api-key", .value = endpoint.apiKey });
    }
    try headers.appendSlice(arena, endpoint.extraHeaders);

    return .{
        .url = try std.fmt.allocPrint(arena, "{s}/v1beta/models/{s}:generateContent", .{
            endpoint.baseUrl,
            request.model,
        }),
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
        if (err == .object) return error.ProviderError;
    }

    const candidates = root.get("candidates") orelse return error.MalformedResponse;
    if (candidates != .array or candidates.array.items.len == 0) return error.MalformedResponse;
    const candidate = switch (candidates.array.items[0]) {
        .object => |o| o,
        else => return error.MalformedResponse,
    };

    var blocks: std.ArrayList(provider.Block) = .empty;
    if (candidate.get("content")) |content| {
        if (content == .object) {
            if (content.object.get("parts")) |parts| {
                if (parts == .array) {
                    for (parts.array.items) |item| {
                        if (item != .object) continue;
                        const part = item.object;
                        if (shared.stringField(part, "text")) |text| {
                            if (text.len > 0) try blocks.append(arena, .{ .text = text });
                            continue;
                        }
                        if (part.get("functionCall")) |call| {
                            if (call != .object) continue;
                            const name = shared.stringField(call.object, "name") orelse "";
                            var arguments: std.Io.Writer.Allocating = .init(arena);
                            if (call.object.get("args")) |args| {
                                try std.json.Stringify.value(args, .{}, &arguments.writer);
                            }
                            try blocks.append(arena, .{
                                .tool_use = .{
                                    // This wire carries no call identifier, so the
                                    // function's name stands in for one.
                                    .id = name,
                                    .name = name,
                                    .argumentsJson = arguments.written(),
                                },
                            });
                        }
                    }
                }
            }
        }
    }

    var usage: provider.Usage = .{};
    if (root.get("usageMetadata")) |u| {
        if (u == .object) {
            usage.inputTokens = shared.intField(u.object, "promptTokenCount");
            usage.outputTokens = shared.intField(u.object, "candidatesTokenCount");
            usage.cacheReadTokens = shared.intField(u.object, "cachedContentTokenCount");
        }
    }

    var stop = stopReasonFrom(shared.stringField(candidate, "finishReason"));
    // A call with no text is a tool turn, whatever the finish reason says.
    if (stop == .end_turn) {
        for (blocks.items) |block| {
            if (block == .tool_use) stop = .tool_use;
        }
    }

    return .{
        .model = shared.stringField(root, "modelVersion") orelse "",
        .blocks = blocks.items,
        .stopReason = stop,
        .usage = usage,
        .id = shared.stringField(root, "responseId") orelse "",
    };
}

fn stopReasonFrom(name: ?[]const u8) provider.StopReason {
    const text = name orelse return .unknown;
    if (std.mem.eql(u8, text, "STOP")) return .end_turn;
    if (std.mem.eql(u8, text, "MAX_TOKENS")) return .max_tokens;
    if (std.mem.eql(u8, text, "SAFETY")) return .refusal;
    if (std.mem.eql(u8, text, "PROHIBITED_CONTENT")) return .refusal;
    if (std.mem.eql(u8, text, "BLOCKLIST")) return .refusal;
    return .unknown;
}

const testing = std.testing;

test "the model goes in the path and the assistant is called model" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const http = try encode(arena, .{
        .baseUrl = "https://generativelanguage.googleapis.com",
        .apiKey = "key-test",
    }, .{
        .model = "gemini-2.5-pro",
        .system = "Be exact.",
        .messages = &.{
            .{ .role = .user, .blocks = &.{.{ .text = "Hello" }} },
            .{ .role = .assistant, .blocks = &.{.{ .text = "Hi" }} },
        },
    });

    try testing.expect(std.mem.endsWith(u8, http.url, "/v1beta/models/gemini-2.5-pro:generateContent"));
    try testing.expect(std.mem.indexOf(u8, http.body, "\"systemInstruction\"") != null);
    try testing.expect(std.mem.indexOf(u8, http.body, "\"role\":\"model\"") != null);

    // The key is a header, so it stays out of the address.
    try testing.expect(std.mem.indexOf(u8, http.url, "key-test") == null);
    var saw_key = false;
    for (http.headers) |header| {
        if (std.mem.eql(u8, header.name, "x-goog-api-key")) saw_key = true;
    }
    try testing.expect(saw_key);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, http.body, .{});
    try testing.expect(parsed.value == .object);
}

test "a function call decodes, and stands in its own name for an identifier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"modelVersion":"gemini-2.5-pro","responseId":"r1","candidates":[
        \\ {"finishReason":"STOP","content":{"role":"model","parts":[
        \\   {"functionCall":{"name":"read_file","args":{"path":"a.txt"}}}]}}],
        \\ "usageMetadata":{"promptTokenCount":20,"candidatesTokenCount":5}}
    ;
    const completion = try decode(arena, body);
    const calls = try completion.toolCalls(arena);
    try testing.expectEqual(@as(usize, 1), calls.len);
    try testing.expectEqualStrings("read_file", calls[0].name);
    try testing.expectEqualStrings("read_file", calls[0].id);
    // A tool turn is reported as one even though the finish reason said stop.
    try testing.expectEqual(provider.StopReason.tool_use, completion.stopReason);
    try testing.expectEqual(@as(u64, 20), completion.usage.inputTokens);
}

test "a blocked answer is a refusal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"modelVersion":"gemini-2.5-pro","candidates":[{"finishReason":"SAFETY","content":{"parts":[]}}]}
    ;
    const completion = try decode(arena, body);
    try testing.expectEqual(provider.StopReason.refusal, completion.stopReason);
}

test "an error body is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.ProviderError, decode(arena,
        \\{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}
    ));
}
