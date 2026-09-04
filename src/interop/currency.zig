//! ISO 4217 currency identifiers and exact money values.
//!
//! Money is stored as an integer count of minor units plus a currency code.
//! Storing money as a float, or as the string "$", is the defect this module
//! exists to prevent. The `$`-style symbol belongs to presentation.

const std = @import("std");
const data = @import("iso4217_data.zig");

pub const Currency = data.Currency;
pub const table = data.table;

pub const Error = error{ UnknownCurrency, CurrencyMismatch, AmountOverflow };

pub fn byCode(code: []const u8) ?Currency {
    if (code.len != 3) return null;
    var key: [3]u8 = undefined;
    for (code, 0..) |c, i| key[i] = std.ascii.toUpper(c);
    var low: usize = 0;
    var high: usize = table.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, &table[mid].code, &key)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return table[mid],
        }
    }
    return null;
}

pub const CurrencyCode = struct {
    value: [3]u8,

    pub fn parse(code: []const u8) Error!CurrencyCode {
        const entry = byCode(code) orelse return error.UnknownCurrency;
        return .{ .value = entry.code };
    }

    pub fn minorUnits(self: CurrencyCode) u8 {
        return (byCode(&self.value) orelse unreachable).minor_units;
    }

    pub fn name(self: CurrencyCode) []const u8 {
        return (byCode(&self.value) orelse unreachable).name;
    }

    pub fn format(self: CurrencyCode, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(&self.value);
    }
};

/// An exact amount of money. `minor` counts the smallest unit the currency is
/// written in (cents for USD, whole yen for JPY, thousandths for KWD).
pub const Money = struct {
    minor: i64,
    currency: CurrencyCode,

    pub fn init(minor: i64, code: []const u8) Error!Money {
        return .{ .minor = minor, .currency = try CurrencyCode.parse(code) };
    }

    pub fn add(a: Money, b: Money) Error!Money {
        if (!std.mem.eql(u8, &a.currency.value, &b.currency.value)) return error.CurrencyMismatch;
        const sum = std.math.add(i64, a.minor, b.minor) catch return error.AmountOverflow;
        return .{ .minor = sum, .currency = a.currency };
    }

    pub fn negate(self: Money) Money {
        return .{ .minor = -self.minor, .currency = self.currency };
    }

    /// Machine form: `"1234.56 USD"` with exactly the currency's decimal
    /// digits, no grouping separators and no symbol.
    pub fn format(self: Money, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const digits = self.currency.minorUnits();
        const negative = self.minor < 0;
        const magnitude: u64 = @intCast(if (negative) -self.minor else self.minor);
        if (negative) try w.writeAll("-");
        if (digits == 0) {
            try w.print("{d}", .{magnitude});
        } else {
            var scale: u64 = 1;
            for (0..digits) |_| scale *= 10;
            try w.print("{d}.{d:0>[2]}", .{ magnitude / scale, magnitude % scale, @as(usize, digits) });
        }
        try w.print(" {s}", .{&self.currency.value});
    }

    /// Parse the machine form produced by `format`.
    pub fn parse(text: []const u8) (Error || error{InvalidFormat})!Money {
        const space = std.mem.lastIndexOfScalar(u8, text, ' ') orelse return error.InvalidFormat;
        const code = try CurrencyCode.parse(text[space + 1 ..]);
        const amount = std.mem.trim(u8, text[0..space], " ");
        const digits = code.minorUnits();
        const negative = amount.len > 0 and amount[0] == '-';
        const body = if (negative) amount[1..] else amount;
        const dot = std.mem.indexOfScalar(u8, body, '.');
        var minor: i64 = 0;
        if (dot) |d| {
            if (body.len - d - 1 != digits) return error.InvalidFormat;
            const whole = std.fmt.parseInt(i64, body[0..d], 10) catch return error.InvalidFormat;
            const frac = std.fmt.parseInt(i64, body[d + 1 ..], 10) catch return error.InvalidFormat;
            var scale: i64 = 1;
            for (0..digits) |_| scale *= 10;
            minor = whole * scale + frac;
        } else {
            if (digits != 0) return error.InvalidFormat;
            minor = std.fmt.parseInt(i64, body, 10) catch return error.InvalidFormat;
        }
        return .{ .minor = if (negative) -minor else minor, .currency = code };
    }
};

test "currency minor units follow iso 4217" {
    try std.testing.expectEqual(@as(u8, 2), byCode("USD").?.minor_units);
    try std.testing.expectEqual(@as(u8, 0), byCode("JPY").?.minor_units);
    try std.testing.expectEqual(@as(u8, 3), byCode("KWD").?.minor_units);
    try std.testing.expect(byCode("ZZZ") == null);
}

test "money formats and parses exactly" {
    const gpa = std.testing.allocator;
    const usd = try Money.init(123456, "USD");
    const text = try std.fmt.allocPrint(gpa, "{f}", .{usd});
    defer gpa.free(text);
    try std.testing.expectEqualStrings("1234.56 USD", text);
    try std.testing.expectEqual(@as(i64, 123456), (try Money.parse(text)).minor);

    const jpy = try Money.init(1500, "JPY");
    const jtext = try std.fmt.allocPrint(gpa, "{f}", .{jpy});
    defer gpa.free(jtext);
    try std.testing.expectEqualStrings("1500 JPY", jtext);

    const kwd = try Money.init(1234, "KWD");
    const ktext = try std.fmt.allocPrint(gpa, "{f}", .{kwd});
    defer gpa.free(ktext);
    try std.testing.expectEqualStrings("1.234 KWD", ktext);

    const negative = try Money.init(-50, "USD");
    const ntext = try std.fmt.allocPrint(gpa, "{f}", .{negative});
    defer gpa.free(ntext);
    try std.testing.expectEqualStrings("-0.50 USD", ntext);
}

test "money refuses to mix currencies" {
    const a = try Money.init(100, "USD");
    const b = try Money.init(100, "EUR");
    try std.testing.expectError(error.CurrencyMismatch, a.add(b));
    const c = try a.add(try Money.init(23, "USD"));
    try std.testing.expectEqual(@as(i64, 123), c.minor);
}
