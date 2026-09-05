//! The terminal screen: cells, cursor, scroll region and scrollback.
//!
//! The grid is a *view*, not the source of truth. The workspace event log holds
//! what happened; the grid holds what a program most recently drew. Keeping
//! that distinction is what allows a session to be reattached from another
//! machine, replayed, or searched long after the process has gone.

const std = @import("std");
const vt = @import("vt.zig");

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const Underline = enum { none, single, double, curly };

pub const Style = struct {
    foreground: Color = .default,
    background: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: Underline = .none,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,

    pub const plain: Style = .{};

    pub fn eql(a: Style, b: Style) bool {
        return std.meta.eql(a, b);
    }
};

pub const CellWidth = enum { narrow, wide, spacer };

pub const Cell = struct {
    codepoint: u21 = ' ',
    style: Style = .{},
    width: CellWidth = .narrow,

    pub fn isBlank(self: Cell) bool {
        return self.codepoint == ' ' and self.style.eql(Style.plain);
    }
};

pub const Cursor = struct {
    column: u16 = 0,
    row: u16 = 0,
};

pub const Match = struct {
    /// Negative rows are scrollback lines, counting back from the top of the
    /// screen; zero and above are on-screen rows.
    row: i32,
    column: u16,
    length: u16,
};

/// East Asian wide ranges, enough to keep the cursor aligned for the common
/// cases. Full Unicode width tables belong in the terminal backend.
fn isWide(codepoint: u21) bool {
    return (codepoint >= 0x1100 and codepoint <= 0x115f) or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x1f300 and codepoint <= 0x1f64f) or
        (codepoint >= 0x1f900 and codepoint <= 0x1f9ff) or
        (codepoint >= 0x20000 and codepoint <= 0x3fffd);
}

pub const Screen = struct {
    arena: std.mem.Allocator,
    columns: u16,
    rows: u16,
    cells: []Cell,
    scrollback: std.ArrayList([]Cell) = .empty,
    scrollback_limit: usize,
    cursor: Cursor = .{},
    saved_cursor: Cursor = .{},
    style: Style = .{},
    saved_style: Style = .{},
    scroll_top: u16 = 0,
    scroll_bottom: u16,
    /// The cursor sits past the last column and the next character wraps.
    wrap_pending: bool = false,
    cursor_visible: bool = true,
    parser: vt.Parser = .{},
    /// OSC strings seen since the last drain. Shell integration reads these.
    pending_osc: std.ArrayList([]const u8) = .empty,
    /// Title set by OSC 0 or OSC 2.
    title: []const u8 = "",

    pub fn init(arena: std.mem.Allocator, columns: u16, rows: u16, scrollback_limit: usize) !Screen {
        const cells = try arena.alloc(Cell, @as(usize, columns) * @as(usize, rows));
        @memset(cells, .{});
        return .{
            .arena = arena,
            .columns = columns,
            .rows = rows,
            .cells = cells,
            .scrollback_limit = scrollback_limit,
            .scroll_bottom = rows -| 1,
        };
    }

    pub fn cellAt(self: Screen, row: u16, column: u16) Cell {
        if (row >= self.rows or column >= self.columns) return .{};
        return self.cells[@as(usize, row) * self.columns + column];
    }

    fn cellPtr(self: *Screen, row: u16, column: u16) *Cell {
        return &self.cells[@as(usize, row) * self.columns + column];
    }

    fn rowSlice(self: *Screen, row: u16) []Cell {
        const start = @as(usize, row) * self.columns;
        return self.cells[start .. start + self.columns];
    }

    /// Feed bytes from the pseudoterminal.
    pub fn write(self: *Screen, bytes: []const u8) !void {
        for (bytes) |byte| {
            const action = self.parser.advance(byte) orelse continue;
            try self.apply(action);
        }
    }

    fn apply(self: *Screen, action: vt.Action) !void {
        switch (action) {
            .print => |codepoint| try self.putChar(codepoint),
            .invalid_utf8 => try self.putChar(0xfffd),
            .execute => |c| try self.control(c),
            .csi => |c| try self.csi(c),
            .esc => |e| try self.esc(e),
            .osc => |o| {
                const copy = try self.arena.dupe(u8, o.raw);
                try self.pending_osc.append(self.arena, copy);
                if (o.command()) |command| {
                    if (command == 0 or command == 2) self.title = try self.arena.dupe(u8, o.payload());
                }
            },
            .dcs => {},
        }
    }

    pub fn drainOsc(self: *Screen) []const []const u8 {
        const items = self.pending_osc.items;
        self.pending_osc = .empty;
        return items;
    }

    fn putChar(self: *Screen, codepoint: u21) !void {
        const wide = isWide(codepoint);
        const needed: u16 = if (wide) 2 else 1;

        if (self.wrap_pending or self.cursor.column + needed > self.columns) {
            try self.lineFeed();
            self.cursor.column = 0;
            self.wrap_pending = false;
        }

        const cell = self.cellPtr(self.cursor.row, self.cursor.column);
        cell.* = .{ .codepoint = codepoint, .style = self.style, .width = if (wide) .wide else .narrow };
        if (wide and self.cursor.column + 1 < self.columns) {
            self.cellPtr(self.cursor.row, self.cursor.column + 1).* = .{ .codepoint = ' ', .style = self.style, .width = .spacer };
        }
        self.cursor.column += needed;
        if (self.cursor.column >= self.columns) {
            self.cursor.column = self.columns - 1;
            self.wrap_pending = true;
        }
    }

    fn control(self: *Screen, c: u8) !void {
        switch (c) {
            0x07 => {}, // bell: surfaced to the interface, not to the grid
            0x08 => { // backspace
                if (self.wrap_pending) {
                    self.wrap_pending = false;
                } else if (self.cursor.column > 0) {
                    self.cursor.column -= 1;
                }
            },
            0x09 => { // horizontal tab, eight columns
                const next = (self.cursor.column / 8 + 1) * 8;
                self.cursor.column = @min(next, self.columns - 1);
                self.wrap_pending = false;
            },
            0x0a, 0x0b, 0x0c => try self.lineFeed(),
            0x0d => {
                self.cursor.column = 0;
                self.wrap_pending = false;
            },
            else => {},
        }
    }

    fn lineFeed(self: *Screen) !void {
        self.wrap_pending = false;
        if (self.cursor.row == self.scroll_bottom) {
            try self.scrollUp(1);
        } else if (self.cursor.row + 1 < self.rows) {
            self.cursor.row += 1;
        }
    }

    /// Move the scroll region up, pushing the top line into scrollback when the
    /// region starts at the top of the screen.
    fn scrollUp(self: *Screen, count: u16) !void {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            if (self.scroll_top == 0) {
                const line = try self.arena.dupe(Cell, self.rowSlice(0));
                try self.scrollback.append(self.arena, line);
                if (self.scrollback.items.len > self.scrollback_limit) {
                    _ = self.scrollback.orderedRemove(0);
                }
            }
            var row = self.scroll_top;
            while (row < self.scroll_bottom) : (row += 1) {
                const source = self.rowSlice(row + 1);
                const target = self.rowSlice(row);
                @memcpy(target, source);
            }
            @memset(self.rowSlice(self.scroll_bottom), .{ .style = self.style });
        }
    }

    fn scrollDown(self: *Screen, count: u16) void {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            var row = self.scroll_bottom;
            while (row > self.scroll_top) : (row -= 1) {
                const source = self.rowSlice(row - 1);
                const target = self.rowSlice(row);
                @memcpy(target, source);
            }
            @memset(self.rowSlice(self.scroll_top), .{ .style = self.style });
        }
    }

    fn csi(self: *Screen, command: vt.CsiCommand) !void {
        switch (command.final) {
            'A' => self.cursor.row -|= @min(command.param(0, 1), self.cursor.row),
            'B' => self.cursor.row = @min(self.cursor.row + command.param(0, 1), self.rows - 1),
            'C' => {
                self.cursor.column = @min(self.cursor.column + command.param(0, 1), self.columns - 1);
                self.wrap_pending = false;
            },
            'D' => {
                self.cursor.column -|= @min(command.param(0, 1), self.cursor.column);
                self.wrap_pending = false;
            },
            'G' => self.cursor.column = @min(command.param(0, 1) - 1, self.columns - 1),
            'd' => self.cursor.row = @min(command.param(0, 1) - 1, self.rows - 1),
            'H', 'f' => {
                self.cursor.row = @min(command.param(0, 1) - 1, self.rows - 1);
                self.cursor.column = @min(command.param(1, 1) - 1, self.columns - 1);
                self.wrap_pending = false;
            },
            'J' => try self.eraseInDisplay(command.rawParam(0, 0)),
            'K' => self.eraseInLine(command.rawParam(0, 0)),
            'L' => {
                // Insert lines at the cursor, inside the scroll region.
                const saved_top = self.scroll_top;
                self.scroll_top = self.cursor.row;
                self.scrollDown(command.param(0, 1));
                self.scroll_top = saved_top;
            },
            'M' => {
                const saved_top = self.scroll_top;
                self.scroll_top = self.cursor.row;
                try self.scrollUp(command.param(0, 1));
                self.scroll_top = saved_top;
            },
            'P' => self.deleteCharacters(command.param(0, 1)),
            '@' => self.insertCharacters(command.param(0, 1)),
            'S' => try self.scrollUp(command.param(0, 1)),
            'T' => self.scrollDown(command.param(0, 1)),
            'X' => { // erase characters
                const count = command.param(0, 1);
                var column = self.cursor.column;
                while (column < @min(self.cursor.column + count, self.columns)) : (column += 1) {
                    self.cellPtr(self.cursor.row, column).* = .{ .style = self.style };
                }
            },
            'r' => {
                const top = command.param(0, 1) - 1;
                const bottom = command.param(1, self.rows) - 1;
                if (top < bottom and bottom < self.rows) {
                    self.scroll_top = top;
                    self.scroll_bottom = bottom;
                    self.cursor = .{ .row = top, .column = 0 };
                }
            },
            'm' => self.selectGraphicRendition(command),
            's' => self.saved_cursor = self.cursor,
            'u' => self.cursor = self.saved_cursor,
            'h', 'l' => {
                if (command.private == '?' and command.param(0, 0) == 25) {
                    self.cursor_visible = command.final == 'h';
                }
            },
            else => {},
        }
    }

    fn eraseInDisplay(self: *Screen, mode: u16) !void {
        switch (mode) {
            0 => {
                self.eraseInLine(0);
                var row = self.cursor.row + 1;
                while (row < self.rows) : (row += 1) @memset(self.rowSlice(row), .{ .style = self.style });
            },
            1 => {
                self.eraseInLine(1);
                var row: u16 = 0;
                while (row < self.cursor.row) : (row += 1) @memset(self.rowSlice(row), .{ .style = self.style });
            },
            2, 3 => {
                var row: u16 = 0;
                while (row < self.rows) : (row += 1) @memset(self.rowSlice(row), .{ .style = self.style });
            },
            else => {},
        }
    }

    fn eraseInLine(self: *Screen, mode: u16) void {
        const row = self.cursor.row;
        switch (mode) {
            0 => {
                var column = self.cursor.column;
                while (column < self.columns) : (column += 1) self.cellPtr(row, column).* = .{ .style = self.style };
            },
            1 => {
                var column: u16 = 0;
                while (column <= self.cursor.column and column < self.columns) : (column += 1) self.cellPtr(row, column).* = .{ .style = self.style };
            },
            2 => @memset(self.rowSlice(row), .{ .style = self.style }),
            else => {},
        }
    }

    fn deleteCharacters(self: *Screen, count: u16) void {
        const row = self.rowSlice(self.cursor.row);
        const start = self.cursor.column;
        const n = @min(count, self.columns - start);
        var i: u16 = start;
        while (i + n < self.columns) : (i += 1) row[i] = row[i + n];
        while (i < self.columns) : (i += 1) row[i] = .{ .style = self.style };
    }

    fn insertCharacters(self: *Screen, count: u16) void {
        const row = self.rowSlice(self.cursor.row);
        const start = self.cursor.column;
        const n = @min(count, self.columns - start);
        var i: u16 = self.columns;
        while (i > start + n) {
            i -= 1;
            row[i] = row[i - n];
        }
        var j: u16 = start;
        while (j < start + n) : (j += 1) row[j] = .{ .style = self.style };
    }

    fn selectGraphicRendition(self: *Screen, command: vt.CsiCommand) void {
        if (command.params.len == 0) {
            self.style = .{};
            return;
        }
        var i: usize = 0;
        while (i < command.params.len) : (i += 1) {
            const p = command.params[i];
            switch (p) {
                0 => self.style = .{},
                1 => self.style.bold = true,
                2 => self.style.dim = true,
                3 => self.style.italic = true,
                4 => self.style.underline = .single,
                7 => self.style.inverse = true,
                8 => self.style.hidden = true,
                9 => self.style.strikethrough = true,
                21 => self.style.underline = .double,
                22 => {
                    self.style.bold = false;
                    self.style.dim = false;
                },
                23 => self.style.italic = false,
                24 => self.style.underline = .none,
                27 => self.style.inverse = false,
                29 => self.style.strikethrough = false,
                30...37 => self.style.foreground = .{ .indexed = @intCast(p - 30) },
                39 => self.style.foreground = .default,
                40...47 => self.style.background = .{ .indexed = @intCast(p - 40) },
                49 => self.style.background = .default,
                90...97 => self.style.foreground = .{ .indexed = @intCast(p - 90 + 8) },
                100...107 => self.style.background = .{ .indexed = @intCast(p - 100 + 8) },
                38, 48 => {
                    // Extended colour, in either the `;` or the `:` form.
                    const target: *Color = if (p == 38) &self.style.foreground else &self.style.background;
                    if (i + 1 >= command.params.len) break;
                    const kind = command.params[i + 1];
                    if (kind == 5 and i + 2 < command.params.len) {
                        target.* = .{ .indexed = @intCast(@min(command.params[i + 2], 255)) };
                        i += 2;
                    } else if (kind == 2 and i + 4 < command.params.len) {
                        target.* = .{ .rgb = .{
                            .r = @intCast(@min(command.params[i + 2], 255)),
                            .g = @intCast(@min(command.params[i + 3], 255)),
                            .b = @intCast(@min(command.params[i + 4], 255)),
                        } };
                        i += 4;
                    }
                },
                else => {},
            }
        }
    }

    fn esc(self: *Screen, command: vt.EscCommand) !void {
        switch (command.final) {
            'M' => { // reverse index
                if (self.cursor.row == self.scroll_top) {
                    self.scrollDown(1);
                } else if (self.cursor.row > 0) {
                    self.cursor.row -= 1;
                }
            },
            'E' => { // next line
                try self.lineFeed();
                self.cursor.column = 0;
            },
            '7' => {
                self.saved_cursor = self.cursor;
                self.saved_style = self.style;
            },
            '8' => {
                self.cursor = self.saved_cursor;
                self.style = self.saved_style;
            },
            'c' => try self.reset(),
            else => {},
        }
    }

    pub fn reset(self: *Screen) !void {
        @memset(self.cells, .{});
        self.cursor = .{};
        self.saved_cursor = .{};
        self.style = .{};
        self.scroll_top = 0;
        self.scroll_bottom = self.rows -| 1;
        self.wrap_pending = false;
        self.cursor_visible = true;
    }

    /// Text of one on-screen row, with trailing blanks removed.
    pub fn rowText(self: Screen, arena: std.mem.Allocator, row: u16) ![]const u8 {
        return renderLine(arena, self.cells[@as(usize, row) * self.columns ..][0..self.columns]);
    }

    /// Text of one scrollback line, index 0 being the oldest.
    pub fn scrollbackText(self: Screen, arena: std.mem.Allocator, index: usize) ![]const u8 {
        return renderLine(arena, self.scrollback.items[index]);
    }

    fn renderLine(arena: std.mem.Allocator, cells: []const Cell) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var last_non_blank: usize = 0;
        for (cells, 0..) |cell, i| {
            if (cell.codepoint != ' ') last_non_blank = i + 1;
        }
        for (cells[0..last_non_blank]) |cell| {
            if (cell.width == .spacer) continue;
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.codepoint, &buf) catch {
                try out.append(arena, '?');
                continue;
            };
            try out.appendSlice(arena, buf[0..len]);
        }
        return out.toOwnedSlice(arena);
    }

    /// Whole visible screen as text.
    pub fn text(self: Screen, arena: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            try out.appendSlice(arena, try self.rowText(arena, row));
            if (row + 1 < self.rows) try out.append(arena, '\n');
        }
        return out.toOwnedSlice(arena);
    }

    /// Search the scrollback and the screen. Scrollback rows are reported as
    /// negative row numbers, counting back from the top of the screen.
    pub fn search(self: Screen, arena: std.mem.Allocator, needle: []const u8) !std.ArrayList(Match) {
        var matches: std.ArrayList(Match) = .empty;
        if (needle.len == 0) return matches;

        const scrollback_count = self.scrollback.items.len;
        for (self.scrollback.items, 0..) |_, i| {
            const line = try self.scrollbackText(arena, i);
            try findAll(arena, line, needle, -@as(i32, @intCast(scrollback_count - i)), &matches);
        }
        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            const line = try self.rowText(arena, row);
            try findAll(arena, line, needle, row, &matches);
        }
        return matches;
    }

    fn findAll(arena: std.mem.Allocator, haystack: []const u8, needle: []const u8, row: i32, out: *std.ArrayList(Match)) !void {
        var offset: usize = 0;
        while (offset < haystack.len) {
            const found = std.mem.indexOfPos(u8, haystack, offset, needle) orelse break;
            try out.append(arena, .{ .row = row, .column = @intCast(found), .length = @intCast(needle.len) });
            offset = found + needle.len;
        }
    }

    /// Resize the screen. Content keeps its position from the top left; lines
    /// that no longer fit move into scrollback rather than being dropped.
    pub fn resize(self: *Screen, columns: u16, rows: u16) !void {
        if (columns == self.columns and rows == self.rows) return;
        const new_cells = try self.arena.alloc(Cell, @as(usize, columns) * @as(usize, rows));
        @memset(new_cells, .{});

        const rows_to_keep = @min(self.rows, rows);
        const first_row = self.rows - rows_to_keep;
        // Rows pushed off the top are preserved as history.
        var pushed: u16 = 0;
        while (pushed < first_row) : (pushed += 1) {
            const line = try self.arena.dupe(Cell, self.rowSlice(pushed));
            try self.scrollback.append(self.arena, line);
        }

        var row: u16 = 0;
        while (row < rows_to_keep) : (row += 1) {
            const source = self.cells[@as(usize, first_row + row) * self.columns ..][0..self.columns];
            const target = new_cells[@as(usize, row) * columns ..][0..columns];
            const copy = @min(self.columns, columns);
            @memcpy(target[0..copy], source[0..copy]);
        }

        self.cells = new_cells;
        self.columns = columns;
        self.rows = rows;
        self.scroll_top = 0;
        self.scroll_bottom = rows -| 1;
        self.cursor.row = @min(self.cursor.row, rows - 1);
        self.cursor.column = @min(self.cursor.column, columns - 1);
    }
};

const testing = std.testing;

fn newScreen(arena: std.mem.Allocator) !Screen {
    return Screen.init(arena, 20, 4, 100);
}

test "writes text and moves the cursor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = try newScreen(arena);
    try screen.write("hello");
    try testing.expectEqualStrings("hello", try screen.rowText(arena, 0));
    try testing.expectEqual(@as(u16, 5), screen.cursor.column);

    try screen.write("\r\nworld");
    try testing.expectEqualStrings("world", try screen.rowText(arena, 1));
    try testing.expectEqual(@as(u16, 1), screen.cursor.row);
}

test "cursor positioning and erasing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = try newScreen(arena);
    try screen.write("abcdef");
    try screen.write("\x1b[1;3H"); // row 1, column 3
    try testing.expectEqual(@as(u16, 2), screen.cursor.column);
    try screen.write("\x1b[K"); // erase to end of line
    try testing.expectEqualStrings("ab", try screen.rowText(arena, 0));

    try screen.write("\x1b[2J\x1b[H");
    try testing.expectEqualStrings("", try screen.rowText(arena, 0));
    try testing.expectEqual(@as(u16, 0), screen.cursor.row);
}

test "styles are applied and reset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = try newScreen(arena);
    try screen.write("\x1b[1;31mred\x1b[0m plain");
    const red = screen.cellAt(0, 0);
    try testing.expect(red.style.bold);
    try testing.expectEqual(@as(u8, 1), red.style.foreground.indexed);
    const plain = screen.cellAt(0, 4);
    try testing.expect(!plain.style.bold);
    try testing.expect(plain.style.foreground == .default);

    try screen.write("\x1b[38;2;10;20;30mrgb");
    try testing.expectEqual(@as(u8, 20), screen.style.foreground.rgb.g);
}

test "scrolling moves lines into scrollback" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = try newScreen(arena);
    try screen.write("one\r\ntwo\r\nthree\r\nfour\r\nfive");
    try testing.expectEqual(@as(usize, 1), screen.scrollback.items.len);
    try testing.expectEqualStrings("one", try screen.scrollbackText(arena, 0));
    try testing.expectEqualStrings("five", try screen.rowText(arena, 3));
}

test "search covers the screen and the scrollback" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = try newScreen(arena);
    try screen.write("error one\r\nfine\r\nfine\r\nfine\r\nerror two");
    const matches = try screen.search(arena, "error");
    try testing.expectEqual(@as(usize, 2), matches.items.len);
    try testing.expect(matches.items[0].row < 0); // in scrollback
    try testing.expectEqual(@as(u16, 0), matches.items[1].column);
}

test "wide characters take two cells" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = try newScreen(arena);
    try screen.write("中a");
    try testing.expectEqual(CellWidth.wide, screen.cellAt(0, 0).width);
    try testing.expectEqual(CellWidth.spacer, screen.cellAt(0, 1).width);
    try testing.expectEqual(@as(u21, 'a'), screen.cellAt(0, 2).codepoint);
    try testing.expectEqualStrings("中a", try screen.rowText(arena, 0));
}

test "osc strings are collected for the shell integration" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = try newScreen(arena);
    try screen.write("\x1b]0;zag\x07\x1b]133;A\x1b\\text");
    const oscs = screen.drainOsc();
    try testing.expectEqual(@as(usize, 2), oscs.len);
    try testing.expectEqualStrings("zag", screen.title);
    try testing.expectEqualStrings("133;A", oscs[1]);
    try testing.expectEqual(@as(usize, 0), screen.drainOsc().len);
}

test "insert and delete characters" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = try newScreen(arena);
    try screen.write("abcdef\x1b[1;3H\x1b[2P"); // delete two characters at column 3
    try testing.expectEqualStrings("abef", try screen.rowText(arena, 0));

    try screen.write("\x1b[1;3H\x1b[2@");
    try testing.expectEqualStrings("ab  ef", try screen.rowText(arena, 0));
}

test "resize keeps content and history" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = try newScreen(arena);
    try screen.write("one\r\ntwo\r\nthree\r\nfour");
    try screen.resize(20, 2);
    try testing.expectEqual(@as(u16, 2), screen.rows);
    try testing.expectEqualStrings("four", try screen.rowText(arena, 1));
    try testing.expect(screen.scrollback.items.len >= 2);
}

test "line wrapping does not lose characters" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var screen = try Screen.init(arena, 4, 3, 10);
    try screen.write("abcdefg");
    try testing.expectEqualStrings("abcd", try screen.rowText(arena, 0));
    try testing.expectEqualStrings("efg", try screen.rowText(arena, 1));
}
