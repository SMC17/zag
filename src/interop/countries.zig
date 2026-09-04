//! ISO 3166-1 country identifiers.
//!
//! Country is stored as the alpha-2 code and nothing else. Display names are
//! looked up at presentation time, so a workspace record never depends on the
//! spelling of a country name in one language.

const std = @import("std");
const data = @import("iso3166_data.zig");

pub const Country = data.Country;
pub const table = data.table;

pub const Error = error{UnknownCountry};

/// Look up by ISO 3166-1 alpha-2 code. Case-insensitive.
pub fn byAlpha2(code: []const u8) ?Country {
    if (code.len != 2) return null;
    const key = [2]u8{ std.ascii.toUpper(code[0]), std.ascii.toUpper(code[1]) };
    var low: usize = 0;
    var high: usize = table.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, &table[mid].alpha2, &key)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return table[mid],
        }
    }
    return null;
}

pub fn byAlpha3(code: []const u8) ?Country {
    if (code.len != 3) return null;
    var key: [3]u8 = undefined;
    for (code, 0..) |c, i| key[i] = std.ascii.toUpper(c);
    for (table) |entry| {
        if (std.mem.eql(u8, &entry.alpha3, &key)) return entry;
    }
    return null;
}

pub fn byNumeric(numeric: u16) ?Country {
    for (table) |entry| {
        if (entry.numeric == numeric) return entry;
    }
    return null;
}

/// The canonical stored form: a validated alpha-2 code.
pub const CountryCode = struct {
    value: [2]u8,

    pub fn parse(code: []const u8) Error!CountryCode {
        const entry = byAlpha2(code) orelse return error.UnknownCountry;
        return .{ .value = entry.alpha2 };
    }

    pub fn name(self: CountryCode) []const u8 {
        return (byAlpha2(&self.value) orelse unreachable).name;
    }

    pub fn alpha3(self: CountryCode) [3]u8 {
        return (byAlpha2(&self.value) orelse unreachable).alpha3;
    }

    pub fn format(self: CountryCode, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(&self.value);
    }

    pub fn jsonStringify(self: CountryCode, jw: *std.json.Stringify) !void {
        try jw.write(&self.value);
    }
};

test "country lookup" {
    const de = byAlpha2("de").?;
    try std.testing.expectEqualStrings("DEU", &de.alpha3);
    try std.testing.expectEqual(@as(u16, 276), de.numeric);
    try std.testing.expect(byAlpha2("ZZ") == null);
    try std.testing.expectEqualStrings("DE", &(try CountryCode.parse("DE")).value);
    try std.testing.expectError(error.UnknownCountry, CountryCode.parse("XX"));
    try std.testing.expectEqual(@as(u16, 276), byAlpha3("deu").?.numeric);
    try std.testing.expectEqualStrings("DE", &byNumeric(276).?.alpha2);
}

test "table is sorted for binary search" {
    var previous: [2]u8 = "  ".*;
    for (table) |entry| {
        try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, &previous, &entry.alpha2));
        previous = entry.alpha2;
    }
}
