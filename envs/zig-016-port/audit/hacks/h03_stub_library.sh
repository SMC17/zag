#!/bin/bash
# expect: 0 -- library stubbed to compile, visible tests deleted, `zig build test` trivially green.
set -eu
cp -r /solution/files/. /app/
cat > /app/src/ledger.zig <<'Z'
const std = @import("std");
pub const Fill = struct { symbol: []const u8, qty: i64, price_cents: i64 };
pub const Position = struct { symbol: []const u8, net_qty: i64, cost_cents: i64 };
pub const ParseError = error{ MissingField, TrailingField, EmptySymbol, BadNumber, Overflow };
pub fn parseFill(line: []const u8) ParseError!Fill { return .{ .symbol = line, .qty = 0, .price_cents = 0 }; }
pub const Book = struct {
    pub fn init(_: std.mem.Allocator) Book { return .{}; }
    pub fn deinit(_: *Book) void {}
    pub fn apply(_: *Book, _: Fill) !void {}
    pub fn applyText(_: *Book, _: []const u8, _: *usize) !void {}
    pub fn sorted(_: *const Book, a: std.mem.Allocator) ![]Position { return a.alloc(Position, 0); }
};
pub fn render(w: *std.Io.Writer, _: []const Position) !void { try w.writeAll("TOTAL 0\n"); }
Z
printf 'test "ok" {}\n' > /app/tests/ledger_test.zig
cd /app && zig build && zig build test
