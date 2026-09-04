//! A small TOML reader for configuration and for the standards registry.
//!
//! Scope: tables, arrays of tables, dotted keys, inline tables, arrays, basic
//! and literal strings (including multi-line), integers with underscores,
//! floats, booleans, and RFC 3339 date-times (kept as text and validated by
//! `core.time`). That is the whole surface the repository's own data files use.
//!
//! Allocation: every value borrows from a caller-supplied arena. Callers free
//! the arena, not individual nodes.

const std = @import("std");
const time = @import("../core/time.zig");

pub const Error = error{
    UnexpectedCharacter,
    UnterminatedString,
    InvalidEscape,
    InvalidNumber,
    InvalidDateTime,
    DuplicateKey,
    ExpectedKey,
    ExpectedEquals,
    ExpectedValue,
    ExpectedNewline,
    UnterminatedTable,
    UnterminatedArray,
    OutOfMemory,
};

pub const Table = std.StringArrayHashMapUnmanaged(Value);

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    datetime: []const u8,
    array: []Value,
    table: Table,

    pub fn get(self: Value, key: []const u8) ?Value {
        return switch (self) {
            .table => |t| t.get(key),
            else => null,
        };
    }

    /// Look up a dotted path such as `standard.edition`.
    pub fn getPath(self: Value, path: []const u8) ?Value {
        var current = self;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |segment| {
            current = current.get(segment) orelse return null;
        }
        return current;
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string, .datetime => |s| s,
            else => null,
        };
    }

    pub fn asInteger(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
            else => null,
        };
    }

    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn asArray(self: Value) ?[]Value {
        return switch (self) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn stringAt(self: Value, path: []const u8) ?[]const u8 {
        return (self.getPath(path) orelse return null).asString();
    }
};

pub const Document = struct {
    root: Value,

    pub fn get(self: Document, path: []const u8) ?Value {
        return self.root.getPath(path);
    }

    pub fn string(self: Document, path: []const u8) ?[]const u8 {
        return self.root.stringAt(path);
    }
};

/// Parse `source` into a document. All memory comes from `arena`.
pub fn parse(arena: std.mem.Allocator, source: []const u8) Error!Document {
    var p: Parser = .{ .arena = arena, .source = source };
    var root: Table = .empty;
    // Tables created implicitly by dotted keys may not be redefined later; the
    // parser keeps this simple by allowing later definition, which is the
    // permissive reading and is enough for our own data files.
    var current: *Table = &root;
    while (true) {
        p.skipTrivia();
        if (p.eof()) break;
        if (p.peek() == '[') {
            current = try p.parseTableHeader(&root);
            continue;
        }
        try p.parseKeyValue(current);
    }
    return .{ .root = .{ .table = root } };
}

const Parser = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    index: usize = 0,

    fn eof(self: *Parser) bool {
        return self.index >= self.source.len;
    }

    fn peek(self: *Parser) u8 {
        return self.source[self.index];
    }

    fn peekAt(self: *Parser, offset: usize) ?u8 {
        const i = self.index + offset;
        return if (i < self.source.len) self.source[i] else null;
    }

    fn advance(self: *Parser) u8 {
        const c = self.source[self.index];
        self.index += 1;
        return c;
    }

    /// Skip whitespace, newlines and comments.
    fn skipTrivia(self: *Parser) void {
        while (!self.eof()) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.index += 1;
            } else if (c == '#') {
                while (!self.eof() and self.peek() != '\n') self.index += 1;
            } else break;
        }
    }

    /// Skip spaces and comments but stop at a newline.
    fn skipInline(self: *Parser) void {
        while (!self.eof()) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r') {
                self.index += 1;
            } else if (c == '#') {
                while (!self.eof() and self.peek() != '\n') self.index += 1;
            } else break;
        }
    }

    fn parseTableHeader(self: *Parser, root: *Table) Error!*Table {
        _ = self.advance(); // '['
        const is_array = !self.eof() and self.peek() == '[';
        if (is_array) self.index += 1;

        var target = root;
        var last_key: []const u8 = "";
        var first = true;
        while (true) {
            self.skipInline();
            const key = try self.parseKey();
            if (!first) {
                target = try descend(self.arena, target, last_key);
            }
            last_key = key;
            first = false;
            self.skipInline();
            if (self.eof()) return error.UnterminatedTable;
            if (self.peek() == '.') {
                self.index += 1;
                continue;
            }
            break;
        }
        if (self.eof() or self.peek() != ']') return error.UnterminatedTable;
        self.index += 1;
        if (is_array) {
            if (self.eof() or self.peek() != ']') return error.UnterminatedTable;
            self.index += 1;
        }
        self.skipInline();

        if (is_array) return try appendArrayTable(self.arena, target, last_key);
        return try descend(self.arena, target, last_key);
    }

    fn parseKeyValue(self: *Parser, table: *Table) Error!void {
        var target = table;
        var key = try self.parseKey();
        self.skipInline();
        while (!self.eof() and self.peek() == '.') {
            self.index += 1;
            self.skipInline();
            target = try descend(self.arena, target, key);
            key = try self.parseKey();
            self.skipInline();
        }
        if (self.eof() or self.peek() != '=') return error.ExpectedEquals;
        self.index += 1;
        self.skipInline();
        const value = try self.parseValue();
        if (target.contains(key)) return error.DuplicateKey;
        try target.put(self.arena, key, value);
        self.skipInline();
        if (!self.eof() and self.peek() != '\n') return error.ExpectedNewline;
    }

    fn parseKey(self: *Parser) Error![]const u8 {
        if (self.eof()) return error.ExpectedKey;
        const c = self.peek();
        if (c == '"' or c == '\'') return try self.parseString();
        const start = self.index;
        while (!self.eof()) {
            const k = self.peek();
            if (std.ascii.isAlphanumeric(k) or k == '_' or k == '-') {
                self.index += 1;
            } else break;
        }
        if (self.index == start) return error.ExpectedKey;
        return self.source[start..self.index];
    }

    fn parseValue(self: *Parser) Error!Value {
        if (self.eof()) return error.ExpectedValue;
        return switch (self.peek()) {
            '"', '\'' => blk: {
                const s = try self.parseString();
                break :blk .{ .string = s };
            },
            '[' => try self.parseArray(),
            '{' => try self.parseInlineTable(),
            't', 'f' => try self.parseBool(),
            else => try self.parseNumberOrDate(),
        };
    }

    fn parseBool(self: *Parser) Error!Value {
        if (std.mem.startsWith(u8, self.source[self.index..], "true")) {
            self.index += 4;
            return .{ .boolean = true };
        }
        if (std.mem.startsWith(u8, self.source[self.index..], "false")) {
            self.index += 5;
            return .{ .boolean = false };
        }
        return error.ExpectedValue;
    }

    fn parseArray(self: *Parser) Error!Value {
        self.index += 1; // '['
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            self.skipTrivia();
            if (self.eof()) return error.UnterminatedArray;
            if (self.peek() == ']') {
                self.index += 1;
                break;
            }
            const v = try self.parseValue();
            try items.append(self.arena, v);
            self.skipTrivia();
            if (self.eof()) return error.UnterminatedArray;
            if (self.peek() == ',') {
                self.index += 1;
                continue;
            }
            if (self.peek() == ']') {
                self.index += 1;
                break;
            }
            return error.UnexpectedCharacter;
        }
        return .{ .array = try items.toOwnedSlice(self.arena) };
    }

    fn parseInlineTable(self: *Parser) Error!Value {
        self.index += 1; // '{'
        var table: Table = .empty;
        self.skipInline();
        if (!self.eof() and self.peek() == '}') {
            self.index += 1;
            return .{ .table = table };
        }
        while (true) {
            self.skipInline();
            const key = try self.parseKey();
            self.skipInline();
            if (self.eof() or self.peek() != '=') return error.ExpectedEquals;
            self.index += 1;
            self.skipInline();
            const value = try self.parseValue();
            if (table.contains(key)) return error.DuplicateKey;
            try table.put(self.arena, key, value);
            self.skipInline();
            if (self.eof()) return error.UnterminatedTable;
            if (self.peek() == ',') {
                self.index += 1;
                continue;
            }
            if (self.peek() == '}') {
                self.index += 1;
                break;
            }
            return error.UnexpectedCharacter;
        }
        return .{ .table = table };
    }

    fn parseString(self: *Parser) Error![]const u8 {
        const quote = self.advance();
        const triple = self.peekAt(0) == quote and self.peekAt(1) == quote;
        if (triple) {
            self.index += 2;
            // A newline directly after the opening delimiter is trimmed.
            if (!self.eof() and self.peek() == '\n') self.index += 1;
            return try self.scanString(quote, true);
        }
        return try self.scanString(quote, false);
    }

    fn scanString(self: *Parser, quote: u8, triple: bool) Error![]const u8 {
        const literal = quote == '\'';
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.eof()) return error.UnterminatedString;
            const c = self.advance();
            if (c == quote) {
                if (!triple) return try out.toOwnedSlice(self.arena);
                if (self.peekAt(0) == quote and self.peekAt(1) == quote) {
                    self.index += 2;
                    return try out.toOwnedSlice(self.arena);
                }
                try out.append(self.arena, c);
                continue;
            }
            if (c == '\n' and !triple) return error.UnterminatedString;
            if (c == '\\' and !literal) {
                if (self.eof()) return error.InvalidEscape;
                const e = self.advance();
                switch (e) {
                    'n' => try out.append(self.arena, '\n'),
                    't' => try out.append(self.arena, '\t'),
                    'r' => try out.append(self.arena, '\r'),
                    '"' => try out.append(self.arena, '"'),
                    '\\' => try out.append(self.arena, '\\'),
                    '0' => try out.append(self.arena, 0),
                    'u', 'U' => {
                        const width: usize = if (e == 'u') 4 else 8;
                        if (self.index + width > self.source.len) return error.InvalidEscape;
                        const digits = self.source[self.index .. self.index + width];
                        self.index += width;
                        const code = std.fmt.parseInt(u21, digits, 16) catch return error.InvalidEscape;
                        var utf8: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(code, &utf8) catch return error.InvalidEscape;
                        try out.appendSlice(self.arena, utf8[0..len]);
                    },
                    '\n' => {
                        // Line-ending backslash: swallow the following blank space.
                        while (!self.eof() and (self.peek() == ' ' or self.peek() == '\t' or self.peek() == '\n' or self.peek() == '\r')) self.index += 1;
                    },
                    else => return error.InvalidEscape,
                }
                continue;
            }
            try out.append(self.arena, c);
        }
    }

    fn parseNumberOrDate(self: *Parser) Error!Value {
        const start = self.index;
        while (!self.eof()) {
            const c = self.peek();
            if (std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.' or c == ':' or c == '_') {
                self.index += 1;
            } else break;
        }
        const text = self.source[start..self.index];
        if (text.len == 0) return error.ExpectedValue;

        // A date or date-time is recognised by shape, then validated.
        if (text.len >= 10 and text[4] == '-' and text[7] == '-') {
            if (text.len == 10) {
                _ = time.Timestamp.parseIso(text) catch return error.InvalidDateTime;
                return .{ .datetime = text };
            }
            _ = time.Timestamp.parseIso(text) catch return error.InvalidDateTime;
            return .{ .datetime = text };
        }

        var cleaned: std.ArrayList(u8) = .empty;
        for (text) |c| {
            if (c != '_') try cleaned.append(self.arena, c);
        }
        const digits = cleaned.items;
        if (std.mem.indexOfAny(u8, digits, ".eE") != null and !std.mem.startsWith(u8, digits, "0x")) {
            const f = std.fmt.parseFloat(f64, digits) catch return error.InvalidNumber;
            return .{ .float = f };
        }
        if (std.mem.startsWith(u8, digits, "0x")) {
            const i = std.fmt.parseInt(i64, digits[2..], 16) catch return error.InvalidNumber;
            return .{ .integer = i };
        }
        const i = std.fmt.parseInt(i64, digits, 10) catch return error.InvalidNumber;
        return .{ .integer = i };
    }
};

fn descend(arena: std.mem.Allocator, table: *Table, key: []const u8) Error!*Table {
    if (table.getPtr(key)) |existing| {
        switch (existing.*) {
            .table => return &existing.table,
            .array => |items| {
                if (items.len == 0) return error.DuplicateKey;
                const last = &items[items.len - 1];
                return switch (last.*) {
                    .table => &last.table,
                    else => error.DuplicateKey,
                };
            },
            else => return error.DuplicateKey,
        }
    }
    try table.put(arena, key, .{ .table = .empty });
    return &table.getPtr(key).?.table;
}

fn appendArrayTable(arena: std.mem.Allocator, table: *Table, key: []const u8) Error!*Table {
    if (table.getPtr(key)) |existing| {
        switch (existing.*) {
            .array => |items| {
                var list: std.ArrayList(Value) = .{ .items = items, .capacity = items.len };
                try list.append(arena, .{ .table = .empty });
                existing.* = .{ .array = try list.toOwnedSlice(arena) };
                const slice = existing.array;
                return &slice[slice.len - 1].table;
            },
            else => return error.DuplicateKey,
        }
    }
    var list: std.ArrayList(Value) = .empty;
    try list.append(arena, .{ .table = .empty });
    try table.put(arena, key, .{ .array = try list.toOwnedSlice(arena) });
    const slice = table.getPtr(key).?.array;
    return &slice[slice.len - 1].table;
}

test "parses scalars, tables and arrays" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try parse(arena,
        \\# standards registry fragment
        \\namespace = "iso"
        \\count = 1_024
        \\ratio = 0.75
        \\published = true
        \\released = 2025-06-01T00:00:00Z
        \\
        \\[standard]
        \\identifier = "ISO 24495-1"
        \\edition = "2023"
        \\tags = ["plain-language", "communication"]
        \\
        \\[standard.scope]
        \\applies_to = "user-facing text"
    );

    try std.testing.expectEqualStrings("iso", doc.string("namespace").?);
    try std.testing.expectEqual(@as(i64, 1024), doc.get("count").?.asInteger().?);
    try std.testing.expectEqual(@as(f64, 0.75), doc.get("ratio").?.asFloat().?);
    try std.testing.expect(doc.get("published").?.asBool().?);
    try std.testing.expectEqualStrings("2025-06-01T00:00:00Z", doc.get("released").?.asString().?);
    try std.testing.expectEqualStrings("ISO 24495-1", doc.string("standard.identifier").?);
    try std.testing.expectEqualStrings("user-facing text", doc.string("standard.scope.applies_to").?);
    const tags = doc.get("standard.tags").?.asArray().?;
    try std.testing.expectEqual(@as(usize, 2), tags.len);
    try std.testing.expectEqualStrings("plain-language", tags[0].asString().?);
}

test "parses arrays of tables and inline tables" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try parse(arena,
        \\[[requirement]]
        \\id = "PL-001"
        \\severity = "error"
        \\verification = { method = "static_analysis", automated = true }
        \\
        \\[[requirement]]
        \\id = "PL-002"
        \\severity = "advisory"
    );

    const reqs = doc.get("requirement").?.asArray().?;
    try std.testing.expectEqual(@as(usize, 2), reqs.len);
    try std.testing.expectEqualStrings("PL-001", reqs[0].stringAt("id").?);
    try std.testing.expectEqualStrings("static_analysis", reqs[0].stringAt("verification.method").?);
    try std.testing.expect(reqs[0].getPath("verification.automated").?.asBool().?);
    try std.testing.expectEqualStrings("PL-002", reqs[1].stringAt("id").?);
}

test "parses multi-line and literal strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try parse(arena,
        \\rationale = """
        \\Readers must be able to act.
        \\"""
        \\path = 'C:\raw\value'
        \\escaped = "line\nbreak"
    );
    try std.testing.expectEqualStrings("Readers must be able to act.\n", doc.string("rationale").?);
    try std.testing.expectEqualStrings("C:\\raw\\value", doc.string("path").?);
    try std.testing.expectEqualStrings("line\nbreak", doc.string("escaped").?);
}

test "rejects duplicate keys and bad dates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.DuplicateKey, parse(arena, "a = 1\na = 2\n"));
    try std.testing.expectError(error.InvalidDateTime, parse(arena, "d = 2026-02-30T00:00:00Z\n"));
}
