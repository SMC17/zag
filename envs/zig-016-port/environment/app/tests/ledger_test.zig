const std = @import("std");
const ledger = @import("ledger");

test "parse a fill" {
    const f = try ledger.parseFill("AAPL,10,18950");
    try std.testing.expectEqualStrings("AAPL", f.symbol);
    try std.testing.expectEqual(@as(i64, 10), f.qty);
    try std.testing.expectEqual(@as(i64, 18950), f.price_cents);
}

test "book folds fills" {
    var book = ledger.Book.init(std.testing.allocator);
    defer book.deinit();
    var bad: usize = 0;
    try book.applyText("AAPL,10,100\nMSFT,5,200\nAAPL,-4,150\n", &bad);
    const ps = try book.sorted(std.testing.allocator);
    defer std.testing.allocator.free(ps);
    try std.testing.expectEqual(@as(usize, 2), ps.len);
    try std.testing.expectEqual(@as(i64, 6), ps[0].net_qty);
}
