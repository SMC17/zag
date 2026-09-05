//! Canonical time handling.
//!
//! Storage rule: every instant is kept as UTC nanoseconds since the Unix epoch
//! and is written as an ISO 8601-1 / RFC 3339 extended-format string. Local and
//! human formats belong to the presentation layer only. This removes the
//! `9/4/26` and `4:30` ambiguity class from the durable stores.

const std = @import("std");

pub const ns_per_us: i64 = 1_000;
pub const ns_per_ms: i64 = 1_000_000;
pub const ns_per_s: i64 = 1_000_000_000;
pub const ns_per_min: i64 = 60 * ns_per_s;
pub const ns_per_hour: i64 = 60 * ns_per_min;
pub const ns_per_day: i64 = 24 * ns_per_hour;

pub const ParseError = error{
    InvalidFormat,
    InvalidDate,
    InvalidTime,
    InvalidOffset,
    UnsupportedPrecision,
};

/// Calendar date in the proleptic Gregorian calendar.
pub const Date = struct {
    year: i32,
    month: u8, // 1..12
    day: u8, // 1..31

    pub fn isLeap(year: i32) bool {
        return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    }

    pub fn daysInMonth(year: i32, month: u8) u8 {
        return switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (isLeap(year)) 29 else 28,
            else => 0,
        };
    }

    pub fn validate(self: Date) ParseError!void {
        if (self.month < 1 or self.month > 12) return error.InvalidDate;
        if (self.day < 1 or self.day > daysInMonth(self.year, self.month)) return error.InvalidDate;
    }

    /// Days since 1970-01-01. Hinnant's civil calendar algorithm.
    pub fn toEpochDay(self: Date) i64 {
        const y_adj: i64 = @as(i64, self.year) - @as(i64, if (self.month <= 2) 1 else 0);
        const era: i64 = @divFloor(y_adj, 400);
        const yoe: i64 = y_adj - era * 400; // 0..399
        const m: i64 = self.month;
        const mp: i64 = @mod(m + 9, 12); // March = 0
        const doy: i64 = @divTrunc(153 * mp + 2, 5) + @as(i64, self.day) - 1;
        const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }

    pub fn fromEpochDay(epoch_day: i64) Date {
        const z: i64 = epoch_day + 719468;
        const era: i64 = @divFloor(z, 146097);
        const doe: i64 = z - era * 146097;
        const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
        const y: i64 = yoe + era * 400;
        const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
        const mp: i64 = @divTrunc(5 * doy + 2, 153);
        const d: i64 = doy - @divTrunc(153 * mp + 2, 5) + 1;
        const m: i64 = if (mp < 10) mp + 3 else mp - 9;
        return .{
            .year = @intCast(y + @as(i64, if (m <= 2) 1 else 0)),
            .month = @intCast(m),
            .day = @intCast(d),
        };
    }

    /// ISO 8601 weekday: Monday = 1 ... Sunday = 7.
    pub fn weekday(self: Date) u8 {
        const wd = @mod(self.toEpochDay() + 3, 7); // 1970-01-01 was a Thursday
        return @intCast(wd + 1);
    }

    /// Day of year, 1-based.
    pub fn ordinal(self: Date) u16 {
        const jan1: Date = .{ .year = self.year, .month = 1, .day = 1 };
        return @intCast(self.toEpochDay() - jan1.toEpochDay() + 1);
    }

    /// ISO 8601 week date. Returns the week-numbering year and week number.
    pub fn isoWeek(self: Date) struct { year: i32, week: u8 } {
        const wd = self.weekday();
        // Thursday of the current ISO week decides the week-numbering year.
        const thursday_day = self.toEpochDay() + (4 - @as(i64, wd));
        const thursday = Date.fromEpochDay(thursday_day);
        const jan1: Date = .{ .year = thursday.year, .month = 1, .day = 1 };
        const week: u8 = @intCast(@divTrunc(thursday_day - jan1.toEpochDay(), 7) + 1);
        return .{ .year = thursday.year, .week = week };
    }
};

pub const TimeOfDay = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32,

    pub fn validate(self: TimeOfDay) ParseError!void {
        // A leap second (`:60`) is accepted on input and folded by the caller.
        if (self.hour > 23 or self.minute > 59 or self.second > 60) return error.InvalidTime;
        if (self.nanosecond > 999_999_999) return error.InvalidTime;
    }
};

/// How much of the fractional second to write.
pub const Precision = enum {
    second,
    millisecond,
    microsecond,
    nanosecond,

    pub fn digits(self: Precision) usize {
        return switch (self) {
            .second => 0,
            .millisecond => 3,
            .microsecond => 6,
            .nanosecond => 9,
        };
    }
};

/// An instant on the UTC time-line.
pub const Timestamp = struct {
    /// Nanoseconds since 1970-01-01T00:00:00Z.
    ns: i64,

    pub const epoch: Timestamp = .{ .ns = 0 };

    pub fn fromUnixSeconds(s: i64) Timestamp {
        return .{ .ns = s * ns_per_s };
    }

    pub fn fromUnixMillis(ms: i64) Timestamp {
        return .{ .ns = ms * ns_per_ms };
    }

    pub fn unixSeconds(self: Timestamp) i64 {
        return @divFloor(self.ns, ns_per_s);
    }

    pub fn addNanos(self: Timestamp, delta: i64) Timestamp {
        return .{ .ns = self.ns + delta };
    }

    pub fn since(self: Timestamp, earlier: Timestamp) Duration {
        return .{ .ns = self.ns - earlier.ns };
    }

    pub fn order(a: Timestamp, b: Timestamp) std.math.Order {
        return std.math.order(a.ns, b.ns);
    }

    pub fn date(self: Timestamp) Date {
        return Date.fromEpochDay(@divFloor(self.ns, ns_per_day));
    }

    pub fn timeOfDay(self: Timestamp) TimeOfDay {
        const in_day = @mod(self.ns, ns_per_day);
        return .{
            .hour = @intCast(@divTrunc(in_day, ns_per_hour)),
            .minute = @intCast(@divTrunc(@mod(in_day, ns_per_hour), ns_per_min)),
            .second = @intCast(@divTrunc(@mod(in_day, ns_per_min), ns_per_s)),
            .nanosecond = @intCast(@mod(in_day, ns_per_s)),
        };
    }

    pub fn fromParts(d: Date, t: TimeOfDay) ParseError!Timestamp {
        try d.validate();
        try t.validate();
        const day = d.toEpochDay();
        const second: i64 = @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + @min(@as(i64, t.second), 59);
        return .{ .ns = day * ns_per_day + second * ns_per_s + @as(i64, t.nanosecond) };
    }

    pub const text_len_max = 35;

    /// Canonical machine form, always UTC with the `Z` designator.
    pub fn writeIso(self: Timestamp, w: *std.Io.Writer, precision: Precision) std.Io.Writer.Error!void {
        const d = self.date();
        const t = self.timeOfDay();
        if (d.year < 0 or d.year > 9999) {
            // ISO 8601 expanded representation needs an explicit sign.
            try w.print("{s}{d:0>4}", .{ if (d.year < 0) "-" else "+", @abs(d.year) });
        } else {
            try w.print("{d:0>4}", .{@as(u32, @intCast(d.year))});
        }
        try w.print("-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ d.month, d.day, t.hour, t.minute, t.second });
        switch (precision) {
            .second => {},
            .millisecond => try w.print(".{d:0>3}", .{t.nanosecond / 1_000_000}),
            .microsecond => try w.print(".{d:0>6}", .{t.nanosecond / 1_000}),
            .nanosecond => try w.print(".{d:0>9}", .{t.nanosecond}),
        }
        try w.writeAll("Z");
    }

    pub fn toIso(self: Timestamp, buf: *[text_len_max]u8, precision: Precision) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        self.writeIso(&w, precision) catch unreachable;
        return w.buffered();
    }

    pub fn format(self: Timestamp, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.writeIso(w, .millisecond);
    }

    /// Instants cross interfaces as ISO 8601 strings, never as numbers, so
    /// that a stored value is readable without knowing our epoch or unit.
    pub fn jsonStringify(self: Timestamp, jw: *std.json.Stringify) !void {
        var buf: [text_len_max]u8 = undefined;
        try jw.write(self.toIso(&buf, .millisecond));
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Timestamp {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const slice = switch (token) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return parseIso(slice) catch error.InvalidCharacter;
    }

    /// Parse an ISO 8601-1 extended date-time. Accepts `Z`, `+hh:mm`, `+hhmm`
    /// and `+hh` offsets, `T` or a single space as the date/time separator, and
    /// `,` or `.` as the decimal sign. The result is normalised to UTC.
    pub fn parseIso(text: []const u8) ParseError!Timestamp {
        if (text.len < 10) return error.InvalidFormat;
        const d = try parseDatePart(text[0..10]);
        if (text.len == 10) return fromParts(d, .{ .hour = 0, .minute = 0, .second = 0, .nanosecond = 0 });
        if (text[10] != 'T' and text[10] != 't' and text[10] != ' ') return error.InvalidFormat;

        var rest = text[11..];
        // Trailing offset.
        var offset_minutes: i32 = 0;
        if (rest.len > 0 and (rest[rest.len - 1] == 'Z' or rest[rest.len - 1] == 'z')) {
            rest = rest[0 .. rest.len - 1];
        } else if (findOffsetStart(rest)) |idx| {
            offset_minutes = try parseOffset(rest[idx..]);
            rest = rest[0..idx];
        } else return error.InvalidOffset; // an unqualified local time is not a valid instant

        if (rest.len < 5) return error.InvalidTime;
        const hour = try parseFixed(u8, rest[0..2]);
        if (rest[2] != ':') return error.InvalidFormat;
        const minute = try parseFixed(u8, rest[3..5]);
        var second: u8 = 0;
        var nanosecond: u32 = 0;
        if (rest.len > 5) {
            if (rest[5] != ':') return error.InvalidFormat;
            if (rest.len < 8) return error.InvalidTime;
            second = try parseFixed(u8, rest[6..8]);
            if (rest.len > 8) {
                if (rest[8] != '.' and rest[8] != ',') return error.InvalidFormat;
                nanosecond = try parseFraction(rest[9..]);
            }
        }
        const t: TimeOfDay = .{ .hour = hour, .minute = minute, .second = second, .nanosecond = nanosecond };
        const base = try fromParts(d, t);
        return .{ .ns = base.ns - @as(i64, offset_minutes) * ns_per_min };
    }

    fn findOffsetStart(rest: []const u8) ?usize {
        var i: usize = rest.len;
        while (i > 0) {
            i -= 1;
            if (rest[i] == '+' or rest[i] == '-') return i;
        }
        return null;
    }

    fn parseOffset(text: []const u8) ParseError!i32 {
        if (text.len < 3) return error.InvalidOffset;
        const sign: i32 = if (text[0] == '-') -1 else 1;
        const hh = try parseFixed(u8, text[1..3]);
        var mm: u8 = 0;
        if (text.len == 6) {
            if (text[3] != ':') return error.InvalidOffset;
            mm = try parseFixed(u8, text[4..6]);
        } else if (text.len == 5) {
            mm = try parseFixed(u8, text[3..5]);
        } else if (text.len != 3) return error.InvalidOffset;
        if (hh > 23 or mm > 59) return error.InvalidOffset;
        return sign * (@as(i32, hh) * 60 + @as(i32, mm));
    }

    fn parseFraction(text: []const u8) ParseError!u32 {
        if (text.len == 0) return error.InvalidTime;
        var value: u64 = 0;
        var digits: usize = 0;
        for (text) |c| {
            if (c < '0' or c > '9') return error.InvalidFormat;
            if (digits < 9) {
                value = value * 10 + (c - '0');
                digits += 1;
            }
        }
        while (digits < 9) : (digits += 1) value *= 10;
        return @intCast(value);
    }
};

fn parseDatePart(text: []const u8) ParseError!Date {
    if (text[4] != '-' or text[7] != '-') return error.InvalidFormat;
    const year = try parseFixed(i32, text[0..4]);
    const month = try parseFixed(u8, text[5..7]);
    const day = try parseFixed(u8, text[8..10]);
    const d: Date = .{ .year = year, .month = month, .day = day };
    try d.validate();
    return d;
}

fn parseFixed(comptime T: type, text: []const u8) ParseError!T {
    var value: i64 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return error.InvalidFormat;
        value = value * 10 + (c - '0');
    }
    return std.math.cast(T, value) orelse error.InvalidDate;
}

/// A length of time. Written in the ISO 8601 duration form (`PT1H30M`).
pub const Duration = struct {
    ns: i64,

    pub fn fromSeconds(s: i64) Duration {
        return .{ .ns = s * ns_per_s };
    }
    pub fn fromMillis(ms: i64) Duration {
        return .{ .ns = ms * ns_per_ms };
    }
    pub fn fromMinutes(m: i64) Duration {
        return .{ .ns = m * ns_per_min };
    }
    pub fn fromHours(h: i64) Duration {
        return .{ .ns = h * ns_per_hour };
    }
    pub fn fromDays(d: i64) Duration {
        return .{ .ns = d * ns_per_day };
    }

    pub fn millis(self: Duration) i64 {
        return @divTrunc(self.ns, ns_per_ms);
    }
    pub fn seconds(self: Duration) i64 {
        return @divTrunc(self.ns, ns_per_s);
    }

    pub fn writeIso(self: Duration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.ns == 0) {
            try w.writeAll("PT0S");
            return;
        }
        var remaining = self.ns;
        if (remaining < 0) {
            try w.writeAll("-");
            remaining = -remaining;
        }
        try w.writeAll("P");
        const days = @divTrunc(remaining, ns_per_day);
        remaining -= days * ns_per_day;
        if (days != 0) try w.print("{d}D", .{days});
        const hours = @divTrunc(remaining, ns_per_hour);
        remaining -= hours * ns_per_hour;
        const minutes = @divTrunc(remaining, ns_per_min);
        remaining -= minutes * ns_per_min;
        const secs = @divTrunc(remaining, ns_per_s);
        const frac = remaining - secs * ns_per_s;
        if (hours != 0 or minutes != 0 or secs != 0 or frac != 0) {
            try w.writeAll("T");
            if (hours != 0) try w.print("{d}H", .{hours});
            if (minutes != 0) try w.print("{d}M", .{minutes});
            if (secs != 0 or frac != 0) {
                if (frac == 0) {
                    try w.print("{d}S", .{secs});
                } else {
                    var f = frac;
                    var digits: usize = 9;
                    while (digits > 1 and @mod(f, 10) == 0) : (digits -= 1) f = @divTrunc(f, 10);
                    try w.print("{d}.", .{secs});
                    try writePadded(w, @intCast(f), digits);
                    try w.writeAll("S");
                }
            }
        }
    }

    pub fn format(self: Duration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.writeIso(w);
    }

    pub fn jsonStringify(self: Duration, jw: *std.json.Stringify) !void {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        self.writeIso(&w) catch unreachable;
        try jw.write(w.buffered());
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Duration {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const slice = switch (token) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return parseIso(slice) catch error.InvalidCharacter;
    }

    /// Parse the subset of ISO 8601 durations that carries an exact length:
    /// weeks, days, hours, minutes and seconds. Years and months are rejected
    /// because their length depends on the calendar position.
    pub fn parseIso(text: []const u8) ParseError!Duration {
        if (text.len < 3) return error.InvalidFormat;
        var i: usize = 0;
        var sign: i64 = 1;
        if (text[0] == '-') {
            sign = -1;
            i = 1;
        } else if (text[0] == '+') i = 1;
        if (text[i] != 'P') return error.InvalidFormat;
        i += 1;
        var total: i64 = 0;
        var in_time = false;
        var saw_field = false;
        while (i < text.len) {
            if (text[i] == 'T') {
                in_time = true;
                i += 1;
                continue;
            }
            const start = i;
            while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '.' or text[i] == ',')) : (i += 1) {}
            if (i == start or i == text.len) return error.InvalidFormat;
            const number = text[start..i];
            const unit = text[i];
            i += 1;
            const value = parseDecimal(number) catch return error.InvalidFormat;
            const scale: f64 = switch (unit) {
                'W' => if (in_time) return error.InvalidFormat else 7.0 * @as(f64, ns_per_day),
                'D' => if (in_time) return error.InvalidFormat else @as(f64, ns_per_day),
                'H' => if (in_time) @as(f64, ns_per_hour) else return error.InvalidFormat,
                'M' => if (in_time) @as(f64, ns_per_min) else return error.UnsupportedPrecision,
                'S' => if (in_time) @as(f64, ns_per_s) else return error.InvalidFormat,
                'Y' => return error.UnsupportedPrecision,
                else => return error.InvalidFormat,
            };
            total += @intFromFloat(@round(value * scale));
            saw_field = true;
        }
        if (!saw_field) return error.InvalidFormat;
        return .{ .ns = sign * total };
    }

    /// Write `value` with leading zeros to exactly `width` digits.
    fn writePadded(w: *std.Io.Writer, value: u64, width: usize) std.Io.Writer.Error!void {
        var digits_buf: [20]u8 = undefined;
        var n: usize = 0;
        var v = value;
        if (v == 0) {
            digits_buf[0] = '0';
            n = 1;
        } else {
            while (v > 0) : (v /= 10) {
                digits_buf[n] = @intCast('0' + (v % 10));
                n += 1;
            }
        }
        var pad = if (width > n) width - n else 0;
        while (pad > 0) : (pad -= 1) try w.writeByte('0');
        var i = n;
        while (i > 0) {
            i -= 1;
            try w.writeByte(digits_buf[i]);
        }
    }

    fn parseDecimal(text: []const u8) !f64 {
        var buf: [32]u8 = undefined;
        if (text.len > buf.len) return error.InvalidFormat;
        for (text, 0..) |c, idx| buf[idx] = if (c == ',') '.' else c;
        return std.fmt.parseFloat(f64, buf[0..text.len]);
    }
};

test "epoch day round trip" {
    const cases = [_]Date{
        .{ .year = 1970, .month = 1, .day = 1 },
        .{ .year = 2000, .month = 2, .day = 29 },
        .{ .year = 2026, .month = 9, .day = 4 },
        .{ .year = 1899, .month = 12, .day = 31 },
        .{ .year = 2100, .month = 3, .day = 1 },
    };
    for (cases) |d| {
        const back = Date.fromEpochDay(d.toEpochDay());
        try std.testing.expectEqual(d.year, back.year);
        try std.testing.expectEqual(d.month, back.month);
        try std.testing.expectEqual(d.day, back.day);
    }
    try std.testing.expectEqual(@as(i64, 0), (Date{ .year = 1970, .month = 1, .day = 1 }).toEpochDay());
}

test "weekday and iso week" {
    // 2026-09-04 is a Friday in ISO week 36.
    const d: Date = .{ .year = 2026, .month = 9, .day = 4 };
    try std.testing.expectEqual(@as(u8, 5), d.weekday());
    const w = d.isoWeek();
    try std.testing.expectEqual(@as(i32, 2026), w.year);
    try std.testing.expectEqual(@as(u8, 36), w.week);

    // 2021-01-01 belongs to ISO week 53 of 2020.
    const e: Date = .{ .year = 2021, .month = 1, .day = 1 };
    const ew = e.isoWeek();
    try std.testing.expectEqual(@as(i32, 2020), ew.year);
    try std.testing.expectEqual(@as(u8, 53), ew.week);
}

test "timestamp formats as rfc3339 utc" {
    const ts = try Timestamp.parseIso("2026-09-04T20:41:31.5Z");
    var buf: [Timestamp.text_len_max]u8 = undefined;
    try std.testing.expectEqualStrings("2026-09-04T20:41:31.500Z", ts.toIso(&buf, .millisecond));
    try std.testing.expectEqualStrings("2026-09-04T20:41:31Z", ts.toIso(&buf, .second));
    try std.testing.expectEqualStrings("2026-09-04T20:41:31.500000000Z", ts.toIso(&buf, .nanosecond));
}

test "timestamp parses offsets and normalises to utc" {
    const a = try Timestamp.parseIso("2026-09-04T22:41:31+02:00");
    const b = try Timestamp.parseIso("2026-09-04T20:41:31Z");
    try std.testing.expectEqual(b.ns, a.ns);

    const c = try Timestamp.parseIso("2026-09-04T15:41:31-0500");
    try std.testing.expectEqual(b.ns, c.ns);

    const d = try Timestamp.parseIso("2026-09-04 20:41:31Z");
    try std.testing.expectEqual(b.ns, d.ns);

    // A local time with no offset is not an instant and must be rejected.
    try std.testing.expectError(error.InvalidOffset, Timestamp.parseIso("2026-09-04T20:41:31"));
    try std.testing.expectError(error.InvalidDate, Timestamp.parseIso("2026-02-30T00:00:00Z"));
}

test "fractional durations pad correctly" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try Duration.fromMillis(1250).writeIso(&w);
    try std.testing.expectEqualStrings("PT1.25S", w.buffered());

    var buf2: [64]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try Duration.fromMillis(1005).writeIso(&w2);
    try std.testing.expectEqualStrings("PT1.005S", w2.buffered());

    var buf3: [64]u8 = undefined;
    var w3 = std.Io.Writer.fixed(&buf3);
    try (Duration{ .ns = 3_600_000_000_123 }).writeIso(&w3);
    try std.testing.expectEqualStrings("PT1H0.000000123S", w3.buffered());
}

test "duration writes and parses iso form" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try Duration.fromMinutes(90).writeIso(&w);
    try std.testing.expectEqualStrings("PT1H30M", w.buffered());

    const parsed = try Duration.parseIso("PT1H30M");
    try std.testing.expectEqual(Duration.fromMinutes(90).ns, parsed.ns);

    const with_fraction = try Duration.parseIso("PT0.25S");
    try std.testing.expectEqual(@as(i64, 250 * ns_per_ms), with_fraction.ns);

    try std.testing.expectError(error.UnsupportedPrecision, Duration.parseIso("P1M"));
}

test "instants and durations round trip through json" {
    const gpa = std.testing.allocator;
    const Holder = struct { at: Timestamp, took: Duration };
    const original: Holder = .{
        .at = try Timestamp.parseIso("2026-09-04T20:41:31.500Z"),
        .took = Duration.fromMinutes(90),
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(original, .{}, &aw.writer);
    try std.testing.expectEqualStrings("{\"at\":\"2026-09-04T20:41:31.500Z\",\"took\":\"PT1H30M\"}", aw.written());

    const parsed = try std.json.parseFromSlice(Holder, gpa, aw.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(original.at.ns, parsed.value.at.ns);
    try std.testing.expectEqual(original.took.ns, parsed.value.took.ns);
}
