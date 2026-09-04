//! Presentation and validation helpers over `core.time`.
//!
//! Two rules, applied in opposite directions:
//!   * Storage and exchange always use ISO 8601 extended UTC form.
//!   * Display is localised, and never round-trips back into storage.
//!
//! `looksAmbiguous` supports the DATE lint rules: it recognises the date shapes
//! that mean different things to different readers (`9/4/26`, `04-09-2026`) so
//! they can be reported in product copy and in generated documents.

const std = @import("std");
const time = @import("../core/time.zig");

pub const Timestamp = time.Timestamp;
pub const Duration = time.Duration;
pub const Date = time.Date;

/// Is this text a canonical, unambiguous instant?
pub fn isCanonicalInstant(text: []const u8) bool {
    _ = Timestamp.parseIso(text) catch return false;
    // `parseIso` accepts a space separator and lower-case designators; the
    // canonical form does not.
    if (text.len < 20) return false;
    if (text[10] != 'T') return false;
    const last = text[text.len - 1];
    if (last != 'Z') return false;
    return true;
}

pub const Ambiguity = enum {
    none,
    /// `9/4/26` — day and month order is not determined by the text.
    numeric_slash_date,
    /// `04-09-2026` — day-first or month-first is not determined.
    numeric_dash_date,
    /// `4:30` — no date, no offset, no way to place the instant.
    bare_clock_time,
    /// `2026-09-04T20:41:31` — a date-time with no offset.
    local_datetime_without_offset,
};

/// Classify a date or time written in prose.
pub fn looksAmbiguous(text: []const u8) Ambiguity {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return .none;
    if (isCanonicalInstant(trimmed)) return .none;

    var slashes: usize = 0;
    var dashes: usize = 0;
    var colons: usize = 0;
    var digits: usize = 0;
    var others: usize = 0;
    for (trimmed) |c| {
        switch (c) {
            '/' => slashes += 1,
            '-' => dashes += 1,
            ':' => colons += 1,
            '0'...'9' => digits += 1,
            else => others += 1,
        }
    }
    if (others > 1) return .none; // prose, not a bare stamp
    if (slashes >= 2 and digits >= 4) return .numeric_slash_date;
    if (colons >= 1 and dashes == 0 and slashes == 0 and digits <= 6) return .bare_clock_time;
    if (dashes == 2 and digits >= 6) {
        // `2026-09-04` is canonical; `04-09-2026` is not.
        if (trimmed.len >= 10 and trimmed[4] == '-' and trimmed[7] == '-') {
            if (trimmed.len == 10) return .none;
            if (Timestamp.parseIso(trimmed)) |_| return .none else |_| return .local_datetime_without_offset;
        }
        return .numeric_dash_date;
    }
    return .none;
}

/// Long, unambiguous English display form: `4 September 2026, 20:41 UTC`.
/// Month names are spelled out because a numeric month is the ambiguity the
/// display layer is trying to avoid.
pub fn writeDisplay(ts: Timestamp, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const d = ts.date();
    const t = ts.timeOfDay();
    try w.print("{d} {s} {d}, {d:0>2}:{d:0>2} UTC", .{ d.day, monthName(d.month), d.year, t.hour, t.minute });
}

pub fn monthName(month: u8) []const u8 {
    return switch (month) {
        1 => "January",
        2 => "February",
        3 => "March",
        4 => "April",
        5 => "May",
        6 => "June",
        7 => "July",
        8 => "August",
        9 => "September",
        10 => "October",
        11 => "November",
        12 => "December",
        else => "unknown month",
    };
}

pub fn weekdayName(weekday: u8) []const u8 {
    return switch (weekday) {
        1 => "Monday",
        2 => "Tuesday",
        3 => "Wednesday",
        4 => "Thursday",
        5 => "Friday",
        6 => "Saturday",
        7 => "Sunday",
        else => "unknown day",
    };
}

/// Plain-language elapsed time: "4 minutes", "2 hours 5 minutes".
/// Used in status text where a raw `PT2H5M` would not serve the reader.
pub fn writeElapsed(d: Duration, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const total_ms = @abs(d.millis());
    if (total_ms < 1000) {
        try w.print("{d} milliseconds", .{total_ms});
        return;
    }
    const total_s = total_ms / 1000;
    if (total_s < 60) {
        try w.print("{d} second{s}", .{ total_s, plural(total_s) });
        return;
    }
    const minutes = total_s / 60;
    const seconds = total_s % 60;
    if (minutes < 60) {
        try w.print("{d} minute{s}", .{ minutes, plural(minutes) });
        if (seconds > 0) try w.print(" {d} second{s}", .{ seconds, plural(seconds) });
        return;
    }
    const hours = minutes / 60;
    const rest = minutes % 60;
    try w.print("{d} hour{s}", .{ hours, plural(hours) });
    if (rest > 0) try w.print(" {d} minute{s}", .{ rest, plural(rest) });
}

fn plural(n: u64) []const u8 {
    return if (n == 1) "" else "s";
}

test "canonical instants are recognised" {
    try std.testing.expect(isCanonicalInstant("2026-09-04T20:41:31Z"));
    try std.testing.expect(isCanonicalInstant("2026-09-04T20:41:31.500Z"));
    try std.testing.expect(!isCanonicalInstant("2026-09-04 20:41:31Z"));
    try std.testing.expect(!isCanonicalInstant("2026-09-04T20:41:31+02:00"));
}

test "ambiguous prose dates are classified" {
    try std.testing.expectEqual(Ambiguity.numeric_slash_date, looksAmbiguous("9/4/26"));
    try std.testing.expectEqual(Ambiguity.bare_clock_time, looksAmbiguous("4:30"));
    try std.testing.expectEqual(Ambiguity.numeric_dash_date, looksAmbiguous("04-09-2026"));
    try std.testing.expectEqual(Ambiguity.local_datetime_without_offset, looksAmbiguous("2026-09-04T20:41:31"));
    try std.testing.expectEqual(Ambiguity.none, looksAmbiguous("2026-09-04"));
    try std.testing.expectEqual(Ambiguity.none, looksAmbiguous("2026-09-04T20:41:31Z"));
    try std.testing.expectEqual(Ambiguity.none, looksAmbiguous("4 September 2026"));
}

test "display and elapsed forms read as sentences" {
    const gpa = std.testing.allocator;
    const ts = try Timestamp.parseIso("2026-09-04T20:41:31Z");
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeDisplay(ts, &aw.writer);
    try std.testing.expectEqualStrings("4 September 2026, 20:41 UTC", aw.written());

    aw.clearRetainingCapacity();
    try writeElapsed(Duration.fromSeconds(125), &aw.writer);
    try std.testing.expectEqualStrings("2 minutes 5 seconds", aw.written());

    aw.clearRetainingCapacity();
    try writeElapsed(Duration.fromSeconds(3600), &aw.writer);
    try std.testing.expectEqualStrings("1 hour", aw.written());

    aw.clearRetainingCapacity();
    try writeElapsed(Duration.fromMillis(250), &aw.writer);
    try std.testing.expectEqualStrings("250 milliseconds", aw.written());
}
