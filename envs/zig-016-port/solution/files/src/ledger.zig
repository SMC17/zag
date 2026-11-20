//! ledger: fold a stream of fills into per-symbol positions.
//! Input line format: SYMBOL,QTY,PRICE_CENTS  (QTY signed; blank lines and '#' comments ignored)
const std = @import("std");

pub const Fill = struct {
    symbol: []const u8,
    qty: i64,
    price_cents: i64,
};

pub const Position = struct {
    symbol: []const u8,
    net_qty: i64,
    /// Sum of qty * price_cents over every fill for this symbol.
    cost_cents: i64,
};

pub const ParseError = error{ MissingField, TrailingField, EmptySymbol, BadNumber, Overflow };

pub fn parseFill(line: []const u8) ParseError!Fill {
    var it = std.mem.splitScalar(u8, line, ',');
    const sym = std.mem.trim(u8, it.next() orelse return error.MissingField, " \t\r");
    const qty_s = std.mem.trim(u8, it.next() orelse return error.MissingField, " \t\r");
    const px_s = std.mem.trim(u8, it.next() orelse return error.MissingField, " \t\r");
    if (it.next() != null) return error.TrailingField;
    if (sym.len == 0) return error.EmptySymbol;
    const qty = std.fmt.parseInt(i64, qty_s, 10) catch |e| switch (e) {
        error.Overflow => return error.Overflow,
        error.InvalidCharacter => return error.BadNumber,
    };
    const px = std.fmt.parseInt(i64, px_s, 10) catch |e| switch (e) {
        error.Overflow => return error.Overflow,
        error.InvalidCharacter => return error.BadNumber,
    };
    if (px < 0) return error.BadNumber;
    return .{ .symbol = sym, .qty = qty, .price_cents = px };
}

pub const Book = struct {
    allocator: std.mem.Allocator,
    positions: std.StringHashMap(Position),
    /// Owned copies of symbol names, freed in deinit.
    names: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator) Book {
        return .{
            .allocator = allocator,
            .positions = std.StringHashMap(Position).init(allocator),
            .names = .empty,
        };
    }

    pub fn deinit(self: *Book) void {
        for (self.names.items) |n| self.allocator.free(n);
        self.names.deinit(self.allocator);
        self.positions.deinit();
    }

    pub fn apply(self: *Book, fill: Fill) !void {
        const gop = try self.positions.getOrPut(fill.symbol);
        if (!gop.found_existing) {
            const owned = try self.allocator.dupe(u8, fill.symbol);
            errdefer self.allocator.free(owned);
            try self.names.append(self.allocator, owned);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = .{ .symbol = owned, .net_qty = 0, .cost_cents = 0 };
        }
        const p = gop.value_ptr;
        p.net_qty = try std.math.add(i64, p.net_qty, fill.qty);
        p.cost_cents = try std.math.add(i64, p.cost_cents, try std.math.mul(i64, fill.qty, fill.price_cents));
    }

    /// Feed every non-blank, non-comment line of `text`. Returns the 1-based
    /// line number of the first bad line through `bad_line`, if any.
    pub fn applyText(self: *Book, text: []const u8, bad_line: *usize) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var n: usize = 0;
        while (lines.next()) |raw| {
            n += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const fill = parseFill(line) catch |e| {
                bad_line.* = n;
                return e;
            };
            try self.apply(fill);
        }
    }

    /// Positions sorted by symbol (byte order). Caller frees the slice.
    pub fn sorted(self: *const Book, allocator: std.mem.Allocator) ![]Position {
        var out: std.ArrayList(Position) = .empty;
        errdefer out.deinit(allocator);
        var it = self.positions.valueIterator();
        while (it.next()) |p| try out.append(allocator, p.*);
        std.mem.sort(Position, out.items, {}, lessThan);
        return out.toOwnedSlice(allocator);
    }

    fn lessThan(_: void, a: Position, b: Position) bool {
        return std.mem.lessThan(u8, a.symbol, b.symbol);
    }
};

/// One line per position: "SYMBOL NET_QTY COST_CENTS\n", then "TOTAL <sum cost>\n".
pub fn render(w: *std.Io.Writer, positions: []const Position) !void {
    var total: i64 = 0;
    for (positions) |p| {
        try w.print("{s} {d} {d}\n", .{ p.symbol, p.net_qty, p.cost_cents });
        total = try std.math.add(i64, total, p.cost_cents);
    }
    try w.print("TOTAL {d}\n", .{total});
}
