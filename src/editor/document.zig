//! The command line as an editing document, not as a string.
//!
//! A terminal that treats the command line as a string can never offer real
//! editing: no undo that groups a typing burst, no multiple cursors, no
//! selection that survives an edit somewhere else in the line. This document
//! model is the same shape an editor uses — a piece table over an immutable
//! original buffer and an append-only add buffer — so an edit costs a few
//! pointer changes rather than a copy of the whole line, and every edit is
//! reversible.
//!
//! Three rules keep the model honest:
//!   * Offsets are byte offsets into the document text, and every edit moves
//!     the cursors that sit after it. Nothing else is allowed to move them.
//!   * The document never splits a UTF-8 sequence. Motions step by codepoint.
//!   * Undo groups by intent, not by keystroke. A burst of typing undoes as
//!     one action, because that is what a person means by "undo".

const std = @import("std");

pub const Error = error{ OutOfMemory, OutOfRange };

/// Where a piece of the current text comes from.
const Source = enum { original, add };

const Piece = struct {
    source: Source,
    start: usize,
    len: usize,
};

/// A position in the text, in bytes from the start.
pub const Offset = usize;

pub const Range = struct {
    start: Offset,
    end: Offset,

    pub fn isEmpty(self: Range) bool {
        return self.start == self.end;
    }

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }

    pub fn ordered(self: Range) Range {
        return if (self.start <= self.end) self else .{ .start = self.end, .end = self.start };
    }
};

/// A caret, with an optional selection anchor. `anchor == position` means no
/// selection, which is why a cursor and a selection are one type here.
pub const Cursor = struct {
    position: Offset,
    anchor: Offset,

    pub fn at(position: Offset) Cursor {
        return .{ .position = position, .anchor = position };
    }

    pub fn selection(self: Cursor) Range {
        return (Range{ .start = self.anchor, .end = self.position }).ordered();
    }

    pub fn hasSelection(self: Cursor) bool {
        return self.position != self.anchor;
    }

    pub fn collapse(self: *Cursor) void {
        self.anchor = self.position;
    }
};

/// What an edit was for. Undo merges neighbouring edits with the same intent,
/// which is what makes undo feel like a person's undo rather than a machine's.
pub const Intent = enum {
    typing,
    deleting,
    /// A paste, a completion, or anything else that arrives whole.
    replacement,
    /// An edit an agent proposed and a person accepted. Never merged with a
    /// person's own typing, so the history keeps who did what.
    agent_edit,

    pub fn mergesWith(self: Intent, other: Intent) bool {
        if (self != other) return false;
        return switch (self) {
            .typing, .deleting => true,
            .replacement, .agent_edit => false,
        };
    }
};

/// One reversible change: the range that was replaced and the text on each
/// side of the change.
const Change = struct {
    at: Offset,
    removed: []const u8,
    inserted: []const u8,
    intent: Intent,
    cursorsBefore: []const Cursor,
    cursorsAfter: []const Cursor,
};

pub const Document = struct {
    gpa: std.mem.Allocator,
    original: []const u8,
    add: std.ArrayList(u8) = .empty,
    pieces: std.ArrayList(Piece) = .empty,
    cursors: std.ArrayList(Cursor) = .empty,
    undo_stack: std.ArrayList(Change) = .empty,
    redo_stack: std.ArrayList(Change) = .empty,
    byte_len: usize = 0,
    /// True while a transaction is open, so edits inside it undo together.
    in_transaction: bool = false,
    transaction_start: usize = 0,

    pub fn init(gpa: std.mem.Allocator, initial: []const u8) !Document {
        var self: Document = .{ .gpa = gpa, .original = initial };
        if (initial.len > 0) try self.pieces.append(gpa, .{ .source = .original, .start = 0, .len = initial.len });
        self.byte_len = initial.len;
        try self.cursors.append(gpa, .at(initial.len));
        return self;
    }

    pub fn deinit(self: *Document) void {
        self.add.deinit(self.gpa);
        self.pieces.deinit(self.gpa);
        self.cursors.deinit(self.gpa);
        for (self.undo_stack.items) |change| self.freeChange(change);
        for (self.redo_stack.items) |change| self.freeChange(change);
        self.undo_stack.deinit(self.gpa);
        self.redo_stack.deinit(self.gpa);
        self.* = undefined;
    }

    fn freeChange(self: *Document, change: Change) void {
        self.gpa.free(change.removed);
        self.gpa.free(change.inserted);
        self.gpa.free(change.cursorsBefore);
        self.gpa.free(change.cursorsAfter);
    }

    pub fn len(self: Document) usize {
        return self.byte_len;
    }

    fn sliceOf(self: Document, piece: Piece) []const u8 {
        const buffer = switch (piece.source) {
            .original => self.original,
            .add => self.add.items,
        };
        return buffer[piece.start .. piece.start + piece.len];
    }

    /// The current text, allocated by the caller's allocator. The document keeps
    /// no flat copy, so this is the only place a copy is made.
    pub fn text(self: Document, allocator: std.mem.Allocator) ![]u8 {
        var out = try allocator.alloc(u8, self.byte_len);
        var at: usize = 0;
        for (self.pieces.items) |piece| {
            const s = self.sliceOf(piece);
            @memcpy(out[at .. at + s.len], s);
            at += s.len;
        }
        return out;
    }

    pub fn writeText(self: Document, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.pieces.items) |piece| try w.writeAll(self.sliceOf(piece));
    }

    /// The byte at `offset`, or null past the end. Used by the motions, which
    /// is why it does not allocate.
    pub fn byteAt(self: Document, offset: Offset) ?u8 {
        if (offset >= self.byte_len) return null;
        var at: usize = 0;
        for (self.pieces.items) |piece| {
            if (offset < at + piece.len) return self.sliceOf(piece)[offset - at];
            at += piece.len;
        }
        return null;
    }

    fn copyRange(self: Document, allocator: std.mem.Allocator, range: Range) ![]u8 {
        const clamped = self.clamp(range);
        var out = try allocator.alloc(u8, clamped.len());
        var written: usize = 0;
        var at: usize = 0;
        for (self.pieces.items) |piece| {
            const piece_end = at + piece.len;
            if (piece_end > clamped.start and at < clamped.end) {
                const from = @max(clamped.start, at) - at;
                const to = @min(clamped.end, piece_end) - at;
                const s = self.sliceOf(piece)[from..to];
                @memcpy(out[written .. written + s.len], s);
                written += s.len;
            }
            at = piece_end;
        }
        return out;
    }

    fn clamp(self: Document, range: Range) Range {
        const r = range.ordered();
        return .{ .start = @min(r.start, self.byte_len), .end = @min(r.end, self.byte_len) };
    }

    /// Split the piece list so that `offset` falls on a piece boundary and
    /// return the index of the piece that starts there.
    fn splitAt(self: *Document, offset: Offset) !usize {
        var at: usize = 0;
        for (self.pieces.items, 0..) |piece, i| {
            if (at == offset) return i;
            if (offset < at + piece.len) {
                const left_len = offset - at;
                const right: Piece = .{
                    .source = piece.source,
                    .start = piece.start + left_len,
                    .len = piece.len - left_len,
                };
                self.pieces.items[i].len = left_len;
                try self.pieces.insert(self.gpa, i + 1, right);
                return i + 1;
            }
            at += piece.len;
        }
        return self.pieces.items.len;
    }

    /// Replace `range` with `new_text`. Every other edit is written in terms of
    /// this one, so cursor movement and undo have one implementation.
    pub fn replace(self: *Document, range: Range, new_text: []const u8, intent: Intent) Error!void {
        const target = self.clamp(range);
        const removed = try self.copyRange(self.gpa, target);
        errdefer self.gpa.free(removed);
        const inserted = try self.gpa.dupe(u8, new_text);
        errdefer self.gpa.free(inserted);
        const before = try self.gpa.dupe(Cursor, self.cursors.items);
        errdefer self.gpa.free(before);

        try self.applyRaw(target, inserted);
        self.moveCursors(target, inserted.len);

        const after = try self.gpa.dupe(Cursor, self.cursors.items);
        const change: Change = .{
            .at = target.start,
            .removed = removed,
            .inserted = inserted,
            .intent = intent,
            .cursorsBefore = before,
            .cursorsAfter = after,
        };
        try self.pushUndo(change);
        for (self.redo_stack.items) |c| self.freeChange(c);
        self.redo_stack.clearRetainingCapacity();
    }

    /// Change the text without recording history. Only `replace`, `undo` and
    /// `redo` call it.
    fn applyRaw(self: *Document, target: Range, new_text: []const u8) !void {
        const first = try self.splitAt(target.start);
        var removed_len: usize = 0;
        var cut_to = first;
        while (cut_to < self.pieces.items.len and removed_len < target.len()) {
            removed_len += self.pieces.items[cut_to].len;
            cut_to += 1;
        }
        if (removed_len > target.len()) {
            // The last piece is only partly removed, so split it and try again.
            _ = try self.splitAt(target.end);
            cut_to = first;
            removed_len = 0;
            while (cut_to < self.pieces.items.len and removed_len < target.len()) {
                removed_len += self.pieces.items[cut_to].len;
                cut_to += 1;
            }
        }
        self.pieces.replaceRangeAssumeCapacity(first, cut_to - first, &.{});
        if (new_text.len > 0) {
            const start = self.add.items.len;
            try self.add.appendSlice(self.gpa, new_text);
            try self.pieces.insert(self.gpa, first, .{ .source = .add, .start = start, .len = new_text.len });
        }
        self.byte_len = self.byte_len - target.len() + new_text.len;
    }

    fn moveCursors(self: *Document, target: Range, inserted_len: usize) void {
        for (self.cursors.items) |*cursor| {
            cursor.position = movedOffset(cursor.position, target, inserted_len);
            cursor.anchor = movedOffset(cursor.anchor, target, inserted_len);
        }
    }

    fn movedOffset(offset: Offset, target: Range, inserted_len: usize) Offset {
        if (offset <= target.start) return offset;
        if (offset >= target.end) return offset - target.len() + inserted_len;
        // Inside the replaced range: the text it pointed at is gone, so the
        // cursor lands at the end of what replaced it.
        return target.start + inserted_len;
    }

    fn pushUndo(self: *Document, change: Change) !void {
        if (self.in_transaction) {
            try self.undo_stack.append(self.gpa, change);
            return;
        }
        if (self.undo_stack.items.len > 0) {
            const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (last.intent.mergesWith(change.intent) and last.at + last.inserted.len == change.at and change.removed.len == 0) {
                // A typing burst: extend the previous change rather than
                // stacking one entry for each keystroke.
                const merged = try std.mem.concat(self.gpa, u8, &.{ last.inserted, change.inserted });
                self.gpa.free(last.inserted);
                last.inserted = merged;
                self.gpa.free(last.cursorsAfter);
                last.cursorsAfter = change.cursorsAfter;
                self.gpa.free(change.removed);
                self.gpa.free(change.inserted);
                self.gpa.free(change.cursorsBefore);
                return;
            }
        }
        try self.undo_stack.append(self.gpa, change);
    }

    /// Open a group. Every edit until `endTransaction` undoes as one action.
    pub fn beginTransaction(self: *Document) void {
        if (self.in_transaction) return;
        self.in_transaction = true;
        self.transaction_start = self.undo_stack.items.len;
    }

    pub fn endTransaction(self: *Document) !void {
        if (!self.in_transaction) return;
        self.in_transaction = false;
        const start = self.transaction_start;
        const count = self.undo_stack.items.len - start;
        if (count <= 1) return;
        // Fold the group into one change that spans it. The text of the group
        // is read from the document, so the fold is exact for edits anywhere.
        const changes = self.undo_stack.items[start..];
        var lowest: Offset = changes[0].at;
        for (changes) |c| lowest = @min(lowest, c.at);
        var removed: std.ArrayList(u8) = .empty;
        defer removed.deinit(self.gpa);
        _ = &removed;
        // Rebuild the "before" text by undoing the group on a scratch copy.
        const after_text = try self.text(self.gpa);
        defer self.gpa.free(after_text);
        var i = changes.len;
        var rebuilt: std.ArrayList(u8) = .empty;
        errdefer rebuilt.deinit(self.gpa);
        try rebuilt.appendSlice(self.gpa, after_text);
        while (i > 0) {
            i -= 1;
            const c = changes[i];
            try rebuilt.replaceRange(self.gpa, c.at, c.inserted.len, c.removed);
        }
        const before_cursors = changes[0].cursorsBefore;
        const after_cursors = changes[changes.len - 1].cursorsAfter;
        const folded: Change = .{
            .at = 0,
            .removed = try rebuilt.toOwnedSlice(self.gpa),
            .inserted = try self.gpa.dupe(u8, after_text),
            .intent = .replacement,
            .cursorsBefore = try self.gpa.dupe(Cursor, before_cursors),
            .cursorsAfter = try self.gpa.dupe(Cursor, after_cursors),
        };
        for (changes) |c| self.freeChange(c);
        self.undo_stack.shrinkRetainingCapacity(start);
        try self.undo_stack.append(self.gpa, folded);
    }

    pub fn canUndo(self: Document) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: Document) bool {
        return self.redo_stack.items.len > 0;
    }

    pub fn undo(self: *Document) !bool {
        const change = self.undo_stack.pop() orelse return false;
        try self.applyRaw(.{ .start = change.at, .end = change.at + change.inserted.len }, change.removed);
        try self.setCursorsFrom(change.cursorsBefore);
        try self.redo_stack.append(self.gpa, change);
        return true;
    }

    pub fn redo(self: *Document) !bool {
        const change = self.redo_stack.pop() orelse return false;
        try self.applyRaw(.{ .start = change.at, .end = change.at + change.removed.len }, change.inserted);
        try self.setCursorsFrom(change.cursorsAfter);
        try self.undo_stack.append(self.gpa, change);
        return true;
    }

    fn setCursorsFrom(self: *Document, saved: []const Cursor) !void {
        self.cursors.clearRetainingCapacity();
        try self.cursors.appendSlice(self.gpa, saved);
    }

    // --- Cursors -----------------------------------------------------------

    pub fn setCursor(self: *Document, position: Offset) !void {
        self.cursors.clearRetainingCapacity();
        try self.cursors.append(self.gpa, .at(@min(position, self.byte_len)));
    }

    pub fn addCursor(self: *Document, position: Offset) !void {
        const clamped = @min(position, self.byte_len);
        for (self.cursors.items) |cursor| {
            if (cursor.position == clamped) return;
        }
        try self.cursors.append(self.gpa, .at(clamped));
        std.mem.sort(Cursor, self.cursors.items, {}, earlierCursor);
    }

    pub fn cursorCount(self: Document) usize {
        return self.cursors.items.len;
    }

    /// Insert at every cursor at once, from the last to the first, so earlier
    /// offsets stay valid while the edits are applied.
    pub fn insertAtCursors(self: *Document, new_text: []const u8, intent: Intent) !void {
        const positions = try self.gpa.dupe(Cursor, self.cursors.items);
        defer self.gpa.free(positions);
        self.beginTransaction();
        var i = positions.len;
        while (i > 0) {
            i -= 1;
            const cursor = positions[i];
            const range = if (cursor.hasSelection()) cursor.selection() else Range{ .start = cursor.position, .end = cursor.position };
            try self.replace(range, new_text, intent);
        }
        try self.endTransaction();
    }

    /// Delete the codepoint before every cursor, or the selection when there is
    /// one. This is the backspace key.
    pub fn deleteBackwardAtCursors(self: *Document) !void {
        const positions = try self.gpa.dupe(Cursor, self.cursors.items);
        defer self.gpa.free(positions);
        self.beginTransaction();
        var i = positions.len;
        while (i > 0) {
            i -= 1;
            const cursor = positions[i];
            if (cursor.hasSelection()) {
                try self.replace(cursor.selection(), "", .deleting);
                continue;
            }
            if (cursor.position == 0) continue;
            const start = self.previousCodepoint(cursor.position);
            try self.replace(.{ .start = start, .end = cursor.position }, "", .deleting);
        }
        try self.endTransaction();
    }

    fn earlierCursor(_: void, a: Cursor, b: Cursor) bool {
        return a.position < b.position;
    }

    // --- Motions -----------------------------------------------------------

    /// The start of the codepoint before `offset`. Continuation bytes are
    /// skipped, so a motion never lands inside a character.
    pub fn previousCodepoint(self: Document, offset: Offset) Offset {
        if (offset == 0) return 0;
        var at = offset - 1;
        while (at > 0) {
            const byte = self.byteAt(at) orelse break;
            if (byte & 0xC0 != 0x80) break;
            at -= 1;
        }
        return at;
    }

    pub fn nextCodepoint(self: Document, offset: Offset) Offset {
        if (offset >= self.byte_len) return self.byte_len;
        var at = offset + 1;
        while (at < self.byte_len) {
            const byte = self.byteAt(at) orelse break;
            if (byte & 0xC0 != 0x80) break;
            at += 1;
        }
        return at;
    }

    fn isWordByte(byte: u8) bool {
        return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte >= 0x80;
    }

    /// The start of the word before `offset`, as the alt-left key means it.
    pub fn previousWord(self: Document, offset: Offset) Offset {
        var at = offset;
        while (at > 0) {
            const previous = self.previousCodepoint(at);
            const byte = self.byteAt(previous) orelse break;
            if (isWordByte(byte)) break;
            at = previous;
        }
        while (at > 0) {
            const previous = self.previousCodepoint(at);
            const byte = self.byteAt(previous) orelse break;
            if (!isWordByte(byte)) break;
            at = previous;
        }
        return at;
    }

    pub fn nextWord(self: Document, offset: Offset) Offset {
        var at = offset;
        while (at < self.byte_len) {
            const byte = self.byteAt(at) orelse break;
            if (isWordByte(byte)) break;
            at = self.nextCodepoint(at);
        }
        while (at < self.byte_len) {
            const byte = self.byteAt(at) orelse break;
            if (!isWordByte(byte)) break;
            at = self.nextCodepoint(at);
        }
        return at;
    }
};

// --- The shell view of the same text ---------------------------------------

pub const TokenKind = enum {
    /// The program name: the first token of a command.
    program,
    /// A word: an argument, a path, a value.
    word,
    /// A word starting with `-`.
    option,
    /// Text inside single or double quotes, quotes included.
    quoted,
    /// `|`, `&&`, `||`, `;`, `>` and friends.
    operator,
    /// A word that started a quote which was never closed. The editor shows
    /// this differently, because pressing enter would hang the shell.
    unterminated,
};

pub const Token = struct {
    kind: TokenKind,
    range: Range,

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.range.start..self.range.end];
    }
};

pub const Tokens = struct {
    items: []const Token,
    /// True when a quote or a continuation was left open. Pressing enter on
    /// such a line continues it rather than running it.
    incomplete: bool,

    /// The token the cursor sits in or immediately after, which is what a
    /// completion needs to know.
    pub fn tokenAt(self: Tokens, offset: Offset) ?Token {
        for (self.items) |token| {
            if (offset >= token.range.start and offset <= token.range.end) return token;
        }
        return null;
    }
};

/// Tokenise a command line the way a shell would see it. This is a reading
/// model for editing and highlighting; it never runs anything, so it stops at
/// the point where shells stop agreeing with each other.
pub fn tokenize(arena: std.mem.Allocator, source: []const u8) !Tokens {
    var items: std.ArrayList(Token) = .empty;
    var incomplete = false;
    var i: usize = 0;
    var expect_program = true;

    while (i < source.len) {
        const c = source[i];
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        if (c == '\\' and i + 1 == source.len) {
            incomplete = true;
            i += 1;
            continue;
        }
        if (isOperatorByte(c)) {
            const start = i;
            i += 1;
            if (i < source.len and source[i] == c and (c == '&' or c == '|' or c == '>')) i += 1;
            try items.append(arena, .{ .kind = .operator, .range = .{ .start = start, .end = i } });
            expect_program = true;
            continue;
        }
        if (c == '\'' or c == '"') {
            const start = i;
            const quote = c;
            i += 1;
            var closed = false;
            while (i < source.len) : (i += 1) {
                if (quote == '"' and source[i] == '\\' and i + 1 < source.len) {
                    i += 1;
                    continue;
                }
                if (source[i] == quote) {
                    i += 1;
                    closed = true;
                    break;
                }
            }
            if (!closed) incomplete = true;
            try items.append(arena, .{
                .kind = if (closed) .quoted else .unterminated,
                .range = .{ .start = start, .end = i },
            });
            expect_program = false;
            continue;
        }
        const start = i;
        while (i < source.len) : (i += 1) {
            const b = source[i];
            if (b == ' ' or b == '\t' or isOperatorByte(b) or b == '\'' or b == '"') break;
            if (b == '\\' and i + 1 < source.len) i += 1;
        }
        const kind: TokenKind = if (expect_program)
            .program
        else if (source[start] == '-')
            .option
        else
            .word;
        try items.append(arena, .{ .kind = kind, .range = .{ .start = start, .end = i } });
        expect_program = false;
    }
    return .{ .items = items.items, .incomplete = incomplete };
}

fn isOperatorByte(c: u8) bool {
    return switch (c) {
        '|', '&', ';', '<', '>' => true,
        else => false,
    };
}

const testing = std.testing;

test "text comes back after inserts and deletes" {
    var doc = try Document.init(testing.allocator, "zig build test");
    defer doc.deinit();

    try doc.replace(.{ .start = 4, .end = 9 }, "run", .replacement);
    const after = try doc.text(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("zig run test", after);
    try testing.expectEqual(after.len, doc.len());
}

test "an edit moves the cursors that sit after it" {
    var doc = try Document.init(testing.allocator, "zig build test");
    defer doc.deinit();
    try doc.setCursor(14);
    try doc.replace(.{ .start = 0, .end = 3 }, "zag", .replacement);
    try testing.expectEqual(@as(Offset, 14), doc.cursors.items[0].position);

    try doc.replace(.{ .start = 0, .end = 3 }, "z", .replacement);
    try testing.expectEqual(@as(Offset, 12), doc.cursors.items[0].position);
}

test "a typing burst undoes as one action" {
    var doc = try Document.init(testing.allocator, "");
    defer doc.deinit();
    for ("zig") |c| {
        try doc.replace(.{ .start = doc.len(), .end = doc.len() }, &.{c}, .typing);
    }
    try testing.expectEqual(@as(usize, 1), doc.undo_stack.items.len);

    try testing.expect(try doc.undo());
    const empty = try doc.text(testing.allocator);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);

    try testing.expect(try doc.redo());
    const back = try doc.text(testing.allocator);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("zig", back);
}

test "an agent edit never merges into a person's typing" {
    var doc = try Document.init(testing.allocator, "");
    defer doc.deinit();
    try doc.replace(.{ .start = 0, .end = 0 }, "zig ", .typing);
    try doc.replace(.{ .start = 4, .end = 4 }, "build --release=fast", .agent_edit);
    try testing.expectEqual(@as(usize, 2), doc.undo_stack.items.len);

    // Undoing the agent's suggestion leaves the person's own typing in place.
    try testing.expect(try doc.undo());
    const mine = try doc.text(testing.allocator);
    defer testing.allocator.free(mine);
    try testing.expectEqualStrings("zig ", mine);
}

test "many cursors insert once and undo once" {
    var doc = try Document.init(testing.allocator, "a b c");
    defer doc.deinit();
    try doc.setCursor(1);
    try doc.addCursor(3);
    try doc.addCursor(5);
    try testing.expectEqual(@as(usize, 3), doc.cursorCount());

    try doc.insertAtCursors("!", .typing);
    const shouted = try doc.text(testing.allocator);
    defer testing.allocator.free(shouted);
    try testing.expectEqualStrings("a! b! c!", shouted);

    try testing.expect(try doc.undo());
    const plain = try doc.text(testing.allocator);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("a b c", plain);
    try testing.expectEqual(@as(usize, 3), doc.cursorCount());
}

test "backspace removes a whole character, not a byte" {
    var doc = try Document.init(testing.allocator, "caf\u{00e9}");
    defer doc.deinit();
    try doc.setCursor(doc.len());
    try doc.deleteBackwardAtCursors();
    const shorter = try doc.text(testing.allocator);
    defer testing.allocator.free(shorter);
    try testing.expectEqualStrings("caf", shorter);
}

test "word motions step over separators" {
    var doc = try Document.init(testing.allocator, "zig build --release=fast");
    defer doc.deinit();
    // An option counts as one word, so the motion stops before "--release"
    // rather than inside it.
    try testing.expectEqual(@as(Offset, 10), doc.previousWord(doc.len() - 4));
    try testing.expectEqual(@as(Offset, 20), doc.previousWord(doc.len()));
    try testing.expectEqual(@as(Offset, 3), doc.nextWord(0));
    try testing.expectEqual(@as(Offset, 9), doc.nextWord(3));
}

test "the shell view names the parts of a command line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = "git commit -m \"first pass\" && zig build test";
    const tokens = try tokenize(arena, source);
    try testing.expect(!tokens.incomplete);
    try testing.expectEqual(TokenKind.program, tokens.items[0].kind);
    try testing.expectEqualStrings("git", tokens.items[0].slice(source));
    try testing.expectEqual(TokenKind.option, tokens.items[2].kind);
    try testing.expectEqual(TokenKind.quoted, tokens.items[3].kind);
    try testing.expectEqualStrings("\"first pass\"", tokens.items[3].slice(source));
    try testing.expectEqual(TokenKind.operator, tokens.items[4].kind);
    // The word after an operator starts a new command, so it is a program.
    try testing.expectEqual(TokenKind.program, tokens.items[5].kind);
}

test "an unclosed quote is reported rather than run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tokens = try tokenize(arena, "echo \"still typing");
    try testing.expect(tokens.incomplete);
    try testing.expectEqual(TokenKind.unterminated, tokens.items[1].kind);
}

test "the token under the cursor is the one a completion needs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = "zig build te";
    const tokens = try tokenize(arena, source);
    const token = tokens.tokenAt(source.len).?;
    try testing.expectEqualStrings("te", token.slice(source));
    try testing.expectEqual(TokenKind.word, token.kind);
}
