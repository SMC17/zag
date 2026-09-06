//! Ollama's own `/api/chat` shape, for models running on this machine.
//!
//! Ollama also serves an OpenAI-compatible endpoint, and the `openai` connector
//! reaches it. This one speaks the native shape instead, because it reports
//! things the compatible endpoint drops: which model actually answered after a
//! tag was resolved, why generation stopped, and the token counts under
//! `prompt_eval_count` and `eval_count`.
//!
//! Nothing here leaves the machine. That is a property worth keeping visible
//! rather than assuming: the policy engine still decides `network.connect` to
//! `localhost`, so a workspace can be configured to allow local models and
//! refuse every hosted one, and the decision is in the log either way.

const std = @import("std");
const provider = @import("../provider.zig");
const shared = @import("anthropic.zig");

pub const wire: provider.Wire = .{ .id = "ollama", .encode = encode, .decode = decode };

pub fn encode(
    arena: std.mem.Allocator,
    endpoint: provider.Endpoint,
    request: provider.Request,
) anyerror!provider.HttpRequest {
    var body: std.Io.Writer.Allocating = .init(arena);
    const w = &body.writer;

    try w.writeAll("{\"model\":");
    try provider.writeJsonString(w, request.model);
    // Streaming is off unless asked for. Ollama streams by default, and a
    // caller that did not ask for a stream would get a body it cannot parse.
    try w.print(",\"stream\":{s}", .{if (request.stream) "true" else "false"});

    try w.writeAll(",\"messages\":[");
    var wrote_any = false;
    if (request.system.len > 0) {
        try w.writeAll("{\"role\":\"system\",\"content\":");
        try provider.writeJsonString(w, request.system);
        try w.writeAll("}");
        wrote_any = true;
    }
    for (request.messages) |message| {
        var tool_results: usize = 0;
        for (message.blocks) |block| {
            if (block == .tool_result) tool_results += 1;
        }
        if (tool_results > 0) {
            for (message.blocks) |block| {
                switch (block) {
                    .tool_result => |result| {
                        if (wrote_any) try w.writeAll(",");
                        try w.writeAll("{\"role\":\"tool\",\"content\":");
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
                        try w.writeAll("{\"function\":{\"name\":");
                        try provider.writeJsonString(w, call.name);
                        // Arguments are an object here, unlike the OpenAI shape
                        // where the same field is a string.
                        try w.writeAll(",\"arguments\":");
                        try w.writeAll(if (call.argumentsJson.len > 0) call.argumentsJson else "{}");
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
    try w.writeAll("]");

    if (request.tools.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (request.tools, 0..) |tool, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
            try provider.writeJsonString(w, tool.name);
            try w.writeAll(",\"description\":");
            try provider.writeJsonString(w, tool.description);
            try w.writeAll(",\"parameters\":");
            try w.writeAll(tool.schemaJson);
            try w.writeAll("}}");
        }
        try w.writeAll("]");
    }

    try w.print(",\"options\":{{\"num_predict\":{d}", .{request.maxOutputTokens});
    if (request.temperature) |t| try w.print(",\"temperature\":{d}", .{t});
    try w.writeAll("}}");

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
        .url = try std.fmt.allocPrint(arena, "{s}/api/chat", .{endpoint.baseUrl}),
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
    if (root.get("error")) |_| return error.ProviderError;

    const message = switch (root.get("message") orelse return error.MalformedResponse) {
        .object => |o| o,
        else => return error.MalformedResponse,
    };

    var blocks: std.ArrayList(provider.Block) = .empty;
    if (shared.stringField(message, "thinking")) |text| {
        if (text.len > 0) try blocks.append(arena, .{ .thinking = text });
    }
    if (shared.stringField(message, "content")) |text| {
        if (text.len > 0) try blocks.append(arena, .{ .text = text });
    }
    if (message.get("tool_calls")) |calls| {
        if (calls == .array) {
            for (calls.array.items, 0..) |item, index| {
                if (item != .object) continue;
                const function = switch (item.object.get("function") orelse continue) {
                    .object => |o| o,
                    else => continue,
                };
                var arguments: std.Io.Writer.Allocating = .init(arena);
                if (function.get("arguments")) |args| {
                    try std.json.Stringify.value(args, .{}, &arguments.writer);
                }
                const name = shared.stringField(function, "name") orelse "";
                try blocks.append(arena, .{
                    .tool_use = .{
                        // This wire carries no identifier either, so calls are
                        // numbered in the order they arrived. Two calls to one
                        // function stay distinct.
                        .id = try std.fmt.allocPrint(arena, "{s}-{d}", .{ name, index }),
                        .name = name,
                        .argumentsJson = arguments.written(),
                    },
                });
            }
        }
    }

    var stop = stopReasonFrom(shared.stringField(root, "done_reason"));
    if (stop == .end_turn) {
        for (blocks.items) |block| {
            if (block == .tool_use) stop = .tool_use;
        }
    }

    return .{
        .model = shared.stringField(root, "model") orelse "",
        .blocks = blocks.items,
        .stopReason = stop,
        .usage = .{
            .inputTokens = shared.intField(root, "prompt_eval_count"),
            .outputTokens = shared.intField(root, "eval_count"),
        },
    };
}

fn stopReasonFrom(name: ?[]const u8) provider.StopReason {
    const text = name orelse return .end_turn;
    if (std.mem.eql(u8, text, "stop")) return .end_turn;
    if (std.mem.eql(u8, text, "length")) return .max_tokens;
    return .unknown;
}

const testing = std.testing;

test "a local request never asks for a stream it cannot read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const endpoint: provider.Endpoint = .{ .baseUrl = "http://localhost:11434" };
    try testing.expect(endpoint.isLocal());

    const http = try encode(arena, endpoint, .{
        .model = "llama3.2",
        .system = "Answer briefly.",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "Hello" }} }},
    });
    try testing.expectEqualStrings("http://localhost:11434/api/chat", http.url);
    try testing.expectEqualStrings("localhost", http.host);
    // Ollama streams unless told otherwise, so this is always explicit.
    try testing.expect(std.mem.indexOf(u8, http.body, "\"stream\":false") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, http.body, .{});
    try testing.expect(parsed.value == .object);
}

test "arguments are an object here, not a string" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const http = try encode(arena, .{ .baseUrl = "http://localhost:11434" }, .{
        .model = "llama3.2",
        .messages = &.{.{ .role = .assistant, .blocks = &.{.{ .tool_use = .{
            .id = "c1",
            .name = "read_file",
            .argumentsJson = "{\"path\":\"a.txt\"}",
        } }} }},
    });
    // Unquoted: an object, unlike the OpenAI shape.
    try testing.expect(std.mem.indexOf(u8, http.body, "\"arguments\":{\"path\":\"a.txt\"}") != null);
}

test "an answer decodes with its counts and its own model name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"model":"llama3.2:3b","created_at":"2026-09-06T00:00:00Z",
        \\ "message":{"role":"assistant","content":"Four."},
        \\ "done":true,"done_reason":"stop",
        \\ "prompt_eval_count":18,"eval_count":3}
    ;
    const completion = try decode(arena, body);
    try testing.expectEqualStrings("llama3.2:3b", completion.model);
    try testing.expectEqualStrings("Four.", try completion.text(arena));
    try testing.expectEqual(provider.StopReason.end_turn, completion.stopReason);
    try testing.expectEqual(@as(u64, 18), completion.usage.inputTokens);
    try testing.expectEqual(@as(u64, 3), completion.usage.outputTokens);
}

test "two calls to one function stay apart" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"model":"llama3.2","message":{"role":"assistant","content":"",
        \\ "tool_calls":[{"function":{"name":"read_file","arguments":{"path":"a.txt"}}},
        \\               {"function":{"name":"read_file","arguments":{"path":"b.txt"}}}]},
        \\ "done":true,"done_reason":"stop"}
    ;
    const completion = try decode(arena, body);
    const calls = try completion.toolCalls(arena);
    try testing.expectEqual(@as(usize, 2), calls.len);
    try testing.expect(!std.mem.eql(u8, calls[0].id, calls[1].id));
    try testing.expectEqual(provider.StopReason.tool_use, completion.stopReason);
}

test "an error is reported rather than read as an empty answer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.ProviderError, decode(arena, "{\"error\":\"model not found\"}"));
}
