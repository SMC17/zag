//! OpenAPI 3.1 descriptions generated from the same Zig types the runtime uses.
//!
//! The workspace daemon exposes a small HTTP surface (sessions, events, blocks,
//! evidence, knowledge). Describing it by hand would guarantee drift, so the
//! description is generated from the operation table below and the request and
//! response types it names. OpenAPI 3.1 uses JSON Schema 2020-12 directly,
//! which is why `jsonschema.zig` can be reused unchanged.

const std = @import("std");
const jsonschema = @import("jsonschema.zig");

pub const openapi_version = "3.1.0";
pub const components_prefix = "#/components/schemas/";

pub const Method = enum {
    get,
    post,
    put,
    patch,
    delete,

    pub fn text(self: Method) []const u8 {
        return @tagName(self);
    }
};

/// One HTTP operation. `capability` names the capability from the agent policy
/// model that a caller must hold; publishing it in the description keeps the
/// security model and the interface documentation in one place.
pub const Operation = struct {
    method: Method,
    path: []const u8,
    operation_id: []const u8,
    summary: []const u8,
    description: []const u8 = "",
    request: ?type = null,
    response: type,
    capability: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
};

pub const Info = struct {
    title: []const u8,
    version: []const u8,
    summary: []const u8 = "",
    description: []const u8 = "",
    license: []const u8 = "MIT",
    server_url: []const u8 = "http://127.0.0.1:7717",
    server_description: []const u8 = "Local workspace daemon",
};

fn collectAll(comptime ops: []const Operation) []const type {
    comptime var acc: []const type = &.{};
    inline for (ops) |op| {
        if (op.request) |R| acc = jsonschema.collect(R, acc);
        acc = jsonschema.collect(op.response, acc);
    }
    return acc;
}

fn pathsOf(comptime ops: []const Operation) []const []const u8 {
    comptime var paths: []const []const u8 = &.{};
    inline for (ops) |op| {
        comptime var seen = false;
        inline for (paths) |p| {
            if (std.mem.eql(u8, p, op.path)) seen = true;
        }
        if (!seen) paths = paths ++ &[_][]const u8{op.path};
    }
    return paths;
}

/// Write the complete OpenAPI document as compact JSON.
pub fn write(comptime ops: []const Operation, w: *std.Io.Writer, info: Info) std.Io.Writer.Error!void {
    @setEvalBranchQuota(400_000);
    try w.print("{{\"openapi\":\"{s}\",\"info\":{{\"title\":\"{s}\",\"version\":\"{s}\"", .{ openapi_version, info.title, info.version });
    if (info.summary.len > 0) try w.print(",\"summary\":\"{s}\"", .{info.summary});
    if (info.description.len > 0) try w.print(",\"description\":\"{s}\"", .{info.description});
    try w.print(",\"license\":{{\"name\":\"{s}\"}}}}", .{info.license});
    try w.print(",\"servers\":[{{\"url\":\"{s}\",\"description\":\"{s}\"}}]", .{ info.server_url, info.server_description });

    try w.writeAll(",\"paths\":{");
    const paths = comptime pathsOf(ops);
    inline for (paths, 0..) |path, path_index| {
        if (path_index > 0) try w.writeAll(",");
        try w.print("\"{s}\":{{", .{path});
        comptime var written: usize = 0;
        inline for (ops) |op| {
            if (comptime std.mem.eql(u8, op.path, path)) {
                if (written > 0) try w.writeAll(",");
                written += 1;
                try writeOperation(op, w);
            }
        }
        try w.writeAll("}");
    }
    try w.writeAll("}");

    try w.writeAll(",\"components\":{\"schemas\":{");
    const types = comptime collectAll(ops);
    inline for (types, 0..) |T, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\":", .{jsonschema.typeName(T)});
        try jsonschema.writeType(T, w, components_prefix);
    }
    try w.writeAll("}}}");
}

fn writeOperation(comptime op: Operation, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("\"{s}\":{{\"operationId\":\"{s}\",\"summary\":\"{s}\"", .{ op.method.text(), op.operation_id, op.summary });
    if (op.description.len > 0) try w.print(",\"description\":\"{s}\"", .{op.description});
    if (op.tags.len > 0) {
        try w.writeAll(",\"tags\":[");
        inline for (op.tags, 0..) |tag, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{tag});
        }
        try w.writeAll("]");
    }
    if (op.capability) |cap| {
        // A vendor extension keeps the required capability machine-readable.
        try w.print(",\"x-zag-capability\":\"{s}\"", .{cap});
    }
    // Path parameters are taken from the template, so a parameter cannot be
    // documented and unimplemented, or implemented and undocumented.
    const params = comptime pathParameters(op.path);
    if (params.len > 0) {
        try w.writeAll(",\"parameters\":[");
        inline for (params, 0..) |name, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"name\":\"{s}\",\"in\":\"path\",\"required\":true,\"schema\":{{\"type\":\"string\"}}}}", .{name});
        }
        try w.writeAll("]");
    }
    if (op.request) |R| {
        try w.writeAll(",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":");
        try jsonschema.writeType(R, w, components_prefix);
        try w.writeAll("}}}");
    }
    try w.writeAll(",\"responses\":{\"200\":{\"description\":\"Success\",\"content\":{\"application/json\":{\"schema\":");
    try jsonschema.writeType(op.response, w, components_prefix);
    try w.writeAll("}}},\"403\":{\"description\":\"The caller does not hold the required capability\"}}}");
}

fn pathParameters(comptime path: []const u8) []const []const u8 {
    comptime var names: []const []const u8 = &.{};
    comptime {
        var i: usize = 0;
        while (i < path.len) : (i += 1) {
            if (path[i] == '{') {
                const start = i + 1;
                var j = start;
                while (j < path.len and path[j] != '}') : (j += 1) {}
                names = names ++ &[_][]const u8{path[start..j]};
                i = j;
            }
        }
    }
    return names;
}

/// Pretty-print the document into caller-owned memory.
pub fn documentAlloc(comptime ops: []const Operation, gpa: std.mem.Allocator, info: Info) ![]u8 {
    var compact: std.Io.Writer.Allocating = .init(gpa);
    defer compact.deinit();
    try write(ops, &compact.writer, info);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, compact.written(), .{});
    defer parsed.deinit();
    var pretty: std.Io.Writer.Allocating = .init(gpa);
    errdefer pretty.deinit();
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &pretty.writer);
    try pretty.writer.writeByte('\n');
    return pretty.toOwnedSlice();
}

const Health = struct { status: []const u8, version: []const u8 };
const Echo = struct { message: []const u8 };

const sample_ops = [_]Operation{
    .{
        .method = .get,
        .path = "/health",
        .operation_id = "getHealth",
        .summary = "Report whether the daemon is running",
        .response = Health,
        .tags = &.{"system"},
    },
    .{
        .method = .post,
        .path = "/sessions/{sessionId}/echo",
        .operation_id = "echo",
        .summary = "Return the message that was sent",
        .request = Echo,
        .response = Echo,
        .capability = "process.execute",
        .tags = &.{"sessions"},
    },
};

test "document is valid json with paths, parameters and schemas" {
    const gpa = std.testing.allocator;
    const text = try documentAlloc(&sample_ops, gpa, .{ .title = "zag workspace daemon", .version = "0.1.0" });
    defer gpa.free(text);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("3.1.0", root.get("openapi").?.string);

    const paths = root.get("paths").?.object;
    try std.testing.expect(paths.contains("/health"));
    const echo = paths.get("/sessions/{sessionId}/echo").?.object.get("post").?.object;
    try std.testing.expectEqualStrings("process.execute", echo.get("x-zag-capability").?.string);
    const params = echo.get("parameters").?.array;
    try std.testing.expectEqual(@as(usize, 1), params.items.len);
    try std.testing.expectEqualStrings("sessionId", params.items[0].object.get("name").?.string);
    try std.testing.expect(echo.get("responses").?.object.contains("403"));

    const schemas = root.get("components").?.object.get("schemas").?.object;
    try std.testing.expect(schemas.contains("Health"));
    try std.testing.expect(schemas.contains("Echo"));
}
