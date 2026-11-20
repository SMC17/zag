//! Hidden behavioural suite. Compiled by the verifier against the agent's
//! src/ledger.zig directly; the agent's build.zig never runs for this step.
const std = @import("std");
const testing = std.testing;
const ledger = @import("ledger");

test "parse: fields and whitespace" {
    const f = try ledger.parseFill("  BRK.B , -7 ,  41250\r");
    try testing.expectEqualStrings("BRK.B", f.symbol);
    try testing.expectEqual(@as(i64, -7), f.qty);
    try testing.expectEqual(@as(i64, 41250), f.price_cents);
}

test "parse: every error is the named error" {
    try testing.expectError(error.MissingField, ledger.parseFill("AAPL,10"));
    try testing.expectError(error.MissingField, ledger.parseFill("AAPL"));
    try testing.expectError(error.TrailingField, ledger.parseFill("AAPL,1,2,3"));
    try testing.expectError(error.EmptySymbol, ledger.parseFill(" ,1,2"));
    try testing.expectError(error.BadNumber, ledger.parseFill("AAPL,ten,2"));
    try testing.expectError(error.BadNumber, ledger.parseFill("AAPL,1,2.50"));
    try testing.expectError(error.BadNumber, ledger.parseFill("AAPL,1,-5"));
    try testing.expectError(error.Overflow, ledger.parseFill("AAPL,99999999999999999999,1"));
}

test "book: fold, owned keys, no leaks" {
    var book = ledger.Book.init(testing.allocator);
    defer book.deinit();
    // The fill's symbol slice must not be retained: mutate the buffer after apply.
    var buf = "XYZ,3,100".*;
    try book.apply(try ledger.parseFill(&buf));
    buf[0] = 'Q';
    try book.apply(try ledger.parseFill("XYZ,-1,250"));
    const ps = try book.sorted(testing.allocator);
    defer testing.allocator.free(ps);
    try testing.expectEqual(@as(usize, 1), ps.len);
    try testing.expectEqualStrings("XYZ", ps[0].symbol);
    try testing.expectEqual(@as(i64, 2), ps[0].net_qty);
    try testing.expectEqual(@as(i64, 50), ps[0].cost_cents);
}

test "book: many symbols survive rehashing, sorted bytewise" {
    var book = ledger.Book.init(testing.allocator);
    defer book.deinit();
    var name: [8]u8 = undefined;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const sym = try std.fmt.bufPrint(&name, "S{d:0>5}", .{1999 - i});
        try book.apply(.{ .symbol = sym, .qty = @intCast(i + 1), .price_cents = 3 });
    }
    try book.apply(.{ .symbol = "aaa", .qty = 1, .price_cents = 1 });
    try book.apply(.{ .symbol = "B", .qty = 1, .price_cents = 1 });
    const ps = try book.sorted(testing.allocator);
    defer testing.allocator.free(ps);
    try testing.expectEqual(@as(usize, 2002), ps.len);
    try testing.expectEqualStrings("B", ps[0].symbol);
    try testing.expectEqualStrings("S00000", ps[1].symbol);
    try testing.expectEqual(@as(i64, 2000), ps[1].net_qty);
    try testing.expectEqualStrings("aaa", ps[2001].symbol);
}

test "book: overflow is reported, not wrapped" {
    var book = ledger.Book.init(testing.allocator);
    defer book.deinit();
    try book.apply(.{ .symbol = "X", .qty = std.math.maxInt(i64), .price_cents = 0 });
    try testing.expectError(error.Overflow, book.apply(.{ .symbol = "X", .qty = 1, .price_cents = 0 }));
    try testing.expectError(error.Overflow, book.apply(.{ .symbol = "Y", .qty = std.math.maxInt(i64) / 2, .price_cents = 3 }));
}

test "applyText: comments, blanks, bad line number" {
    var book = ledger.Book.init(testing.allocator);
    defer book.deinit();
    var bad: usize = 0;
    try testing.expectError(error.BadNumber, book.applyText("# h\n\nA,1,1\n  \nA,x,1\nA,1,1\n", &bad));
    try testing.expectEqual(@as(usize, 5), bad);
}

test "render: exact format" {
    const ps = [_]ledger.Position{
        .{ .symbol = "A", .net_qty = -2, .cost_cents = -300 },
        .{ .symbol = "B", .net_qty = 0, .cost_cents = 125 },
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try ledger.render(&w, &ps);
    try testing.expectEqualStrings("A -2 -300\nB 0 125\nTOTAL -175\n", w.buffered());
}

test "render: empty book" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try ledger.render(&w, &.{});
    try testing.expectEqualStrings("TOTAL 0\n", w.buffered());
}
