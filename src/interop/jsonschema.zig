//! JSON Schema (2020-12) derived from Zig types at compile time.
//!
//! The Zig type is the single definition of a workspace object. The schema, the
//! OpenAPI description and the on-disk JSON all come from it, so an interface
//! cannot drift from its documentation: if a field is added to the type, the
//! published schema changes in the same build.

const std = @import("std");

pub const dialect = "https://json-schema.org/draft/2020-12/schema";

/// Options for a generated schema document.
pub const Options = struct {
    /// Absolute `$id` of the schema document.
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// Short, stable schema name for a composite type.
pub fn typeName(comptime T: type) []const u8 {
    const full = @typeName(T);
    comptime var start: usize = 0;
    comptime {
        var i = full.len;
        while (i > 0) {
            i -= 1;
            if (full[i] == '.') {
                start = i + 1;
                break;
            }
        }
    }
    comptime var buf: [full.len - start]u8 = undefined;
    comptime {
        for (full[start..], 0..) |c, i| {
            buf[i] = if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
        }
    }
    const out = buf;
    return &out;
}

fn Unwrapped(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| Unwrapped(o.child),
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) T else Unwrapped(p.child),
            .one => Unwrapped(p.child),
            else => T,
        },
        .array => |a| if (a.child == u8) T else Unwrapped(a.child),
        else => T,
    };
}

fn isComposite(comptime T: type) bool {
    if (T == []const u8) return false;
    if (hasCustomEncoding(T)) return false;
    return switch (@typeInfo(T)) {
        .@"struct", .@"union" => true,
        .@"enum" => true,
        else => false,
    };
}

fn hasCustomEncoding(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "jsonStringify"),
        else => false,
    };
}

fn contains(comptime list: []const type, comptime T: type) bool {
    inline for (list) |item| {
        if (item == T) return true;
    }
    return false;
}

/// Walk a type and collect every composite type reachable from it.
pub fn collect(comptime T: type, comptime acc: []const type) []const type {
    const U = Unwrapped(T);
    if (!isComposite(U)) return acc;
    if (contains(acc, U)) return acc;
    comptime var out: []const type = acc ++ &[_]type{U};
    switch (@typeInfo(U)) {
        .@"struct" => |info| {
            inline for (info.fields) |f| {
                out = collect(f.type, out);
            }
        },
        .@"union" => |info| {
            inline for (info.fields) |f| {
                out = collect(f.type, out);
            }
        },
        else => {},
    }
    return out;
}

/// Default location of shared definitions inside a schema document.
pub const defs_prefix = "#/$defs/";

/// Write the schema for one type, using `$ref` for composite members.
/// `ref_prefix` selects where those references point, so the same generator
/// serves standalone schema files (`#/$defs/`) and OpenAPI components.
pub fn writeType(comptime T: type, w: *std.Io.Writer, comptime ref_prefix: []const u8) std.Io.Writer.Error!void {
    switch (@typeInfo(T)) {
        .optional => |o| {
            try w.writeAll("{\"anyOf\":[");
            try writeType(o.child, w, ref_prefix);
            try w.writeAll(",{\"type\":\"null\"}]}");
        },
        .bool => try w.writeAll("{\"type\":\"boolean\"}"),
        .int => |i| {
            try w.writeAll("{\"type\":\"integer\"");
            if (i.bits <= 53) {
                const min = std.math.minInt(T);
                const max = std.math.maxInt(T);
                try w.print(",\"minimum\":{d},\"maximum\":{d}", .{ min, max });
            } else if (i.signedness == .unsigned) {
                try w.writeAll(",\"minimum\":0");
            }
            try w.writeAll("}");
        },
        .float => try w.writeAll("{\"type\":\"number\"}"),
        .comptime_int => try w.writeAll("{\"type\":\"integer\"}"),
        .comptime_float => try w.writeAll("{\"type\":\"number\"}"),
        .void => try w.writeAll("{\"type\":\"null\"}"),
        .@"enum" => |e| {
            if (hasCustomEncoding(T)) {
                try w.writeAll("{\"type\":\"string\"}");
                return;
            }
            try w.writeAll("{\"type\":\"string\",\"enum\":[");
            inline for (e.fields, 0..) |f, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("\"{s}\"", .{f.name});
            }
            try w.writeAll("]}");
        },
        .array => |a| {
            if (a.child == u8) {
                try w.print("{{\"type\":\"string\",\"minLength\":{d},\"maxLength\":{d}}}", .{ a.len, a.len });
            } else {
                try w.print("{{\"type\":\"array\",\"minItems\":{d},\"maxItems\":{d},\"items\":", .{ a.len, a.len });
                try writeRef(a.child, w, ref_prefix);
                try w.writeAll("}");
            }
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) {
                    try w.writeAll("{\"type\":\"string\"}");
                } else {
                    try w.writeAll("{\"type\":\"array\",\"items\":");
                    try writeRef(p.child, w, ref_prefix);
                    try w.writeAll("}");
                }
            },
            .one => try writeRef(p.child, w, ref_prefix),
            else => try w.writeAll("{}"),
        },
        .@"struct" => |info| {
            if (hasCustomEncoding(T)) {
                try w.writeAll("{\"type\":\"string\"}");
                return;
            }
            try w.writeAll("{\"type\":\"object\",\"properties\":{");
            comptime var required: []const []const u8 = &.{};
            inline for (info.fields, 0..) |f, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("\"{s}\":", .{f.name});
                try writeRef(f.type, w, ref_prefix);
                if (@typeInfo(f.type) != .optional and f.default_value_ptr == null) {
                    required = required ++ &[_][]const u8{f.name};
                }
            }
            try w.writeAll("}");
            if (required.len > 0) {
                try w.writeAll(",\"required\":[");
                inline for (required, 0..) |name, i| {
                    if (i > 0) try w.writeAll(",");
                    try w.print("\"{s}\"", .{name});
                }
                try w.writeAll("]");
            }
            try w.writeAll(",\"additionalProperties\":false}");
        },
        .@"union" => |info| {
            if (hasCustomEncoding(T)) {
                try w.writeAll("{\"type\":\"string\"}");
                return;
            }
            // A tagged union encodes as a single-property object, which is what
            // `std.json` writes, so the schema is a `oneOf` over those shapes.
            try w.writeAll("{\"oneOf\":[");
            inline for (info.fields, 0..) |f, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"type\":\"object\",\"properties\":{{\"{s}\":", .{f.name});
                try writeRef(f.type, w, ref_prefix);
                try w.print("}},\"required\":[\"{s}\"],\"additionalProperties\":false}}", .{f.name});
            }
            try w.writeAll("]}");
        },
        else => try w.writeAll("{}"),
    }
}

fn writeRef(comptime T: type, w: *std.Io.Writer, comptime ref_prefix: []const u8) std.Io.Writer.Error!void {
    const U = Unwrapped(T);
    if (isComposite(U) and U == T) {
        try w.print("{{\"$ref\":\"{s}{s}\"}}", .{ ref_prefix, typeName(U) });
        return;
    }
    if (isComposite(U)) {
        // Wrapped composite (optional, slice, pointer): keep the wrapper shape
        // and reference the inner definition.
        switch (@typeInfo(T)) {
            .optional => |o| {
                try w.writeAll("{\"anyOf\":[");
                try writeRef(o.child, w, ref_prefix);
                try w.writeAll(",{\"type\":\"null\"}]}");
                return;
            },
            .pointer => |p| switch (p.size) {
                .slice => {
                    try w.writeAll("{\"type\":\"array\",\"items\":");
                    try writeRef(p.child, w, ref_prefix);
                    try w.writeAll("}");
                    return;
                },
                .one => {
                    try writeRef(p.child, w, ref_prefix);
                    return;
                },
                else => {},
            },
            .array => |a| {
                try w.print("{{\"type\":\"array\",\"minItems\":{d},\"maxItems\":{d},\"items\":", .{ a.len, a.len });
                try writeRef(a.child, w, ref_prefix);
                try w.writeAll("}");
                return;
            },
            else => {},
        }
    }
    try writeType(T, w, ref_prefix);
}

/// Write a complete schema document for `T`, with every reachable composite
/// type placed in `$defs`.
pub fn writeDocument(comptime T: type, w: *std.Io.Writer, options: Options) std.Io.Writer.Error!void {
    const types = comptime collect(T, &.{});
    try w.print("{{\"$schema\":\"{s}\"", .{dialect});
    if (options.id) |id| try w.print(",\"$id\":\"{s}\"", .{id});
    if (options.title) |title| try w.print(",\"title\":\"{s}\"", .{title});
    if (options.description) |d| try w.print(",\"description\":\"{s}\"", .{d});
    try w.print(",\"$ref\":\"#/$defs/{s}\",\"$defs\":{{", .{typeName(Unwrapped(T))});
    inline for (types, 0..) |Ty, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\":", .{typeName(Ty)});
        try writeType(Ty, w, defs_prefix);
    }
    try w.writeAll("}}");
}

/// Convenience wrapper that returns an owned, pretty-printed document.
pub fn documentAlloc(comptime T: type, gpa: std.mem.Allocator, options: Options) ![]u8 {
    var compact: std.Io.Writer.Allocating = .init(gpa);
    defer compact.deinit();
    try writeDocument(T, &compact.writer, options);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, compact.written(), .{});
    defer parsed.deinit();
    var pretty: std.Io.Writer.Allocating = .init(gpa);
    errdefer pretty.deinit();
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &pretty.writer);
    try pretty.writer.writeByte('\n');
    return pretty.toOwnedSlice();
}

const Severity = enum { advisory, warning, @"error" };

const Nested = struct {
    label: []const u8,
    weight: f64 = 1.0,
};

const Sample = struct {
    id: u32,
    name: []const u8,
    severity: Severity,
    nested: Nested,
    optional_note: ?[]const u8,
    tags: []const []const u8,
    children: []const Nested,
};

test "schema document is valid json and covers the type" {
    const gpa = std.testing.allocator;
    const text = try documentAlloc(Sample, gpa, .{ .id = "https://example.test/sample.schema.json", .title = "Sample" });
    defer gpa.free(text);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings(dialect, root.get("$schema").?.string);
    try std.testing.expectEqualStrings("#/$defs/Sample", root.get("$ref").?.string);

    const defs = root.get("$defs").?.object;
    try std.testing.expect(defs.contains("Sample"));
    try std.testing.expect(defs.contains("Nested"));
    try std.testing.expect(defs.contains("Severity"));

    const sample = defs.get("Sample").?.object;
    const props = sample.get("properties").?.object;
    try std.testing.expectEqualStrings("integer", props.get("id").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("#/$defs/Nested", props.get("nested").?.object.get("$ref").?.string);
    try std.testing.expectEqualStrings("array", props.get("children").?.object.get("type").?.string);

    // An optional field is nullable and is not required.
    try std.testing.expect(props.get("optional_note").?.object.contains("anyOf"));
    const required = sample.get("required").?.array;
    for (required.items) |item| {
        try std.testing.expect(!std.mem.eql(u8, item.string, "optional_note"));
        // A field with a default is also not required.
        try std.testing.expect(!std.mem.eql(u8, item.string, "weight"));
    }

    const severity = defs.get("Severity").?.object;
    try std.testing.expectEqual(@as(usize, 3), severity.get("enum").?.array.items.len);
}

const Shape = union(enum) {
    circle: f64,
    label: []const u8,
    nothing: void,
};

test "tagged unions become a oneOf of single-property objects" {
    const gpa = std.testing.allocator;
    const text = try documentAlloc(Shape, gpa, .{});
    defer gpa.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const shape = parsed.value.object.get("$defs").?.object.get("Shape").?.object;
    const one_of = shape.get("oneOf").?.array;
    try std.testing.expectEqual(@as(usize, 3), one_of.items.len);
    try std.testing.expectEqualStrings("circle", one_of.items[0].object.get("required").?.array.items[0].string);
}

test "types with custom json encoding become strings" {
    const id = @import("../core/id.zig");
    const Holder = struct { block: id.BlockId };
    const gpa = std.testing.allocator;
    const text = try documentAlloc(Holder, gpa, .{});
    defer gpa.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const holder = parsed.value.object.get("$defs").?.object.get("Holder").?.object;
    const block = holder.get("properties").?.object.get("block").?.object;
    try std.testing.expectEqualStrings("string", block.get("type").?.string);
}
