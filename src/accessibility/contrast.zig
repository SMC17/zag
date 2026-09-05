//! Contrast and colour checks (WCAG 2.2).
//!
//! A terminal that draws its own text with a GPU gets no accessibility for
//! free: nothing else will notice that a colour scheme is unreadable. So the
//! ratios are computed here, and the theme is checked in the test suite like
//! any other property of the product.

const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn fromHex(text: []const u8) !Rgb {
        const body = if (text.len > 0 and text[0] == '#') text[1..] else text;
        if (body.len != 6) return error.InvalidColor;
        return .{
            .r = try std.fmt.parseInt(u8, body[0..2], 16),
            .g = try std.fmt.parseInt(u8, body[2..4], 16),
            .b = try std.fmt.parseInt(u8, body[4..6], 16),
        };
    }

    pub fn format(self: Rgb, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b });
    }
};

fn channel(value: u8) f64 {
    const c = @as(f64, @floatFromInt(value)) / 255.0;
    if (c <= 0.03928) return c / 12.92;
    return std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

/// Relative luminance, as WCAG defines it.
pub fn luminance(color: Rgb) f64 {
    return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b);
}

/// Contrast ratio between two colours, from 1 to 21.
pub fn ratio(a: Rgb, b: Rgb) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    const lighter = @max(la, lb);
    const darker = @min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
}

pub const Level = enum { aa, aaa };

pub const TextSize = enum {
    /// Below 18 point, or below 14 point bold.
    normal,
    /// 18 point or larger, or 14 point bold or larger.
    large,
};

/// The minimum ratio for text, from WCAG 1.4.3 (AA) and 1.4.6 (AAA).
pub fn textMinimum(level: Level, size: TextSize) f64 {
    return switch (level) {
        .aa => switch (size) {
            .normal => 4.5,
            .large => 3.0,
        },
        .aaa => switch (size) {
            .normal => 7.0,
            .large => 4.5,
        },
    };
}

/// The minimum ratio for interface components and meaningful graphics,
/// from WCAG 1.4.11. There is no AAA level for this criterion.
pub const non_text_minimum: f64 = 3.0;

pub const Result = struct {
    ratio: f64,
    required: f64,
    passes: bool,
    /// What to do when it fails, in words a designer can act on.
    advice: []const u8,
};

pub fn checkText(foreground: Rgb, background: Rgb, level: Level, size: TextSize) Result {
    const measured = ratio(foreground, background);
    const required = textMinimum(level, size);
    return .{
        .ratio = measured,
        .required = required,
        .passes = measured >= required,
        .advice = if (measured >= required)
            ""
        else
            "Darken the text or lighten the background until the ratio reaches the minimum. Do not rely on a larger font alone.",
    };
}

pub fn checkNonText(foreground: Rgb, background: Rgb) Result {
    const measured = ratio(foreground, background);
    return .{
        .ratio = measured,
        .required = non_text_minimum,
        .passes = measured >= non_text_minimum,
        .advice = if (measured >= non_text_minimum)
            ""
        else
            "A control's boundary, a focus ring or a state indicator must stand out from what is behind it.",
    };
}

/// One named colour pair in a theme.
pub const Pair = struct {
    name: []const u8,
    foreground: Rgb,
    background: Rgb,
    size: TextSize = .normal,
    non_text: bool = false,
};

pub const Theme = struct {
    name: []const u8,
    pairs: []const Pair,

    pub const Failure = struct {
        pair: Pair,
        result: Result,
    };

    pub fn check(self: Theme, arena: std.mem.Allocator, level: Level) !std.ArrayList(Failure) {
        var failures: std.ArrayList(Failure) = .empty;
        for (self.pairs) |pair| {
            const result = if (pair.non_text)
                checkNonText(pair.foreground, pair.background)
            else
                checkText(pair.foreground, pair.background, level, pair.size);
            if (!result.passes) try failures.append(arena, .{ .pair = pair, .result = result });
        }
        return failures;
    }

    pub fn writeReport(self: Theme, w: *std.Io.Writer, level: Level) !void {
        try w.print("Contrast in the \"{s}\" theme, checked against level {s}\n\n", .{ self.name, @tagName(level) });
        for (self.pairs) |pair| {
            const result = if (pair.non_text)
                checkNonText(pair.foreground, pair.background)
            else
                checkText(pair.foreground, pair.background, level, pair.size);
            try w.print("{s}  {f} on {f}  {d:.2}:1 (needs {d:.1}:1)  {s}\n", .{
                pair.name,
                pair.foreground,
                pair.background,
                result.ratio,
                result.required,
                if (result.passes) "passes" else "fails",
            });
            if (!result.passes) try w.print("    {s}\n", .{result.advice});
        }
    }
};

/// The workbench's default dark theme. Every pair is checked in the tests, so a
/// colour cannot be changed without the change being seen.
pub const default_dark: Theme = .{
    .name = "default dark",
    .pairs = &.{
        .{ .name = "body text", .foreground = .{ .r = 0xe6, .g = 0xe6, .b = 0xe6 }, .background = .{ .r = 0x12, .g = 0x14, .b = 0x18 } },
        .{ .name = "dimmed text", .foreground = .{ .r = 0xa8, .g = 0xae, .b = 0xb8 }, .background = .{ .r = 0x12, .g = 0x14, .b = 0x18 } },
        .{ .name = "command text", .foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff }, .background = .{ .r = 0x12, .g = 0x14, .b = 0x18 } },
        .{ .name = "success", .foreground = .{ .r = 0x5c, .g = 0xd6, .b = 0x8a }, .background = .{ .r = 0x12, .g = 0x14, .b = 0x18 } },
        .{ .name = "failure", .foreground = .{ .r = 0xff, .g = 0x86, .b = 0x8c }, .background = .{ .r = 0x12, .g = 0x14, .b = 0x18 } },
        .{ .name = "warning", .foreground = .{ .r = 0xf5, .g = 0xc2, .b = 0x5e }, .background = .{ .r = 0x12, .g = 0x14, .b = 0x18 } },
        .{ .name = "link", .foreground = .{ .r = 0x7d, .g = 0xbd, .b = 0xff }, .background = .{ .r = 0x12, .g = 0x14, .b = 0x18 } },
        .{ .name = "focus ring", .foreground = .{ .r = 0x7d, .g = 0xbd, .b = 0xff }, .background = .{ .r = 0x12, .g = 0x14, .b = 0x18 }, .non_text = true },
        .{ .name = "block border", .foreground = .{ .r = 0x6b, .g = 0x72, .b = 0x80 }, .background = .{ .r = 0x12, .g = 0x14, .b = 0x18 }, .non_text = true },
        .{ .name = "selected block", .foreground = .{ .r = 0xe6, .g = 0xe6, .b = 0xe6 }, .background = .{ .r = 0x23, .g = 0x2a, .b = 0x33 } },
    },
};

pub const default_light: Theme = .{
    .name = "default light",
    .pairs = &.{
        .{ .name = "body text", .foreground = .{ .r = 0x1a, .g = 0x1d, .b = 0x21 }, .background = .{ .r = 0xff, .g = 0xff, .b = 0xff } },
        .{ .name = "dimmed text", .foreground = .{ .r = 0x53, .g = 0x59, .b = 0x63 }, .background = .{ .r = 0xff, .g = 0xff, .b = 0xff } },
        .{ .name = "success", .foreground = .{ .r = 0x0a, .g = 0x6b, .b = 0x38 }, .background = .{ .r = 0xff, .g = 0xff, .b = 0xff } },
        .{ .name = "failure", .foreground = .{ .r = 0xa3, .g = 0x14, .b = 0x1c }, .background = .{ .r = 0xff, .g = 0xff, .b = 0xff } },
        .{ .name = "warning", .foreground = .{ .r = 0x6b, .g = 0x4b, .b = 0x00 }, .background = .{ .r = 0xff, .g = 0xff, .b = 0xff } },
        .{ .name = "link", .foreground = .{ .r = 0x0b, .g = 0x4f, .b = 0xa8 }, .background = .{ .r = 0xff, .g = 0xff, .b = 0xff } },
        .{ .name = "focus ring", .foreground = .{ .r = 0x0b, .g = 0x4f, .b = 0xa8 }, .background = .{ .r = 0xff, .g = 0xff, .b = 0xff }, .non_text = true },
        .{ .name = "block border", .foreground = .{ .r = 0x76, .g = 0x7c, .b = 0x86 }, .background = .{ .r = 0xff, .g = 0xff, .b = 0xff }, .non_text = true },
    },
};

const testing = std.testing;

test "contrast ratios match the known extremes" {
    const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    try testing.expectApproxEqAbs(@as(f64, 21.0), ratio(black, white), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 1.0), ratio(white, white), 0.001);
    // The ratio does not depend on which colour is named first.
    try testing.expectApproxEqAbs(ratio(black, white), ratio(white, black), 0.0001);
}

test "the thresholds follow the success criteria" {
    try testing.expectEqual(@as(f64, 4.5), textMinimum(.aa, .normal));
    try testing.expectEqual(@as(f64, 3.0), textMinimum(.aa, .large));
    try testing.expectEqual(@as(f64, 7.0), textMinimum(.aaa, .normal));
    try testing.expectEqual(@as(f64, 3.0), non_text_minimum);
}

test "the shipped themes pass at level AA" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    inline for ([_]Theme{ default_dark, default_light }) |theme| {
        const failures = try theme.check(arena, .aa);
        if (failures.items.len > 0) {
            for (failures.items) |failure| {
                std.debug.print("{s}: {s} {d:.2}:1 needs {d:.1}:1\n", .{ theme.name, failure.pair.name, failure.result.ratio, failure.result.required });
            }
        }
        try testing.expectEqual(@as(usize, 0), failures.items.len);
    }
}

test "a failing pair is reported with advice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bad: Theme = .{
        .name = "grey on grey",
        .pairs = &.{.{
            .name = "body text",
            .foreground = .{ .r = 0x88, .g = 0x88, .b = 0x88 },
            .background = .{ .r = 0x77, .g = 0x77, .b = 0x77 },
        }},
    };
    const failures = try bad.check(arena, .aa);
    try testing.expectEqual(@as(usize, 1), failures.items.len);
    try testing.expect(failures.items[0].result.advice.len > 0);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try bad.writeReport(&aw.writer, .aa);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "fails") != null);
}

test "colours parse from hex and print back" {
    const gpa = testing.allocator;
    const colour = try Rgb.fromHex("#7dbdff");
    try testing.expectEqual(@as(u8, 0x7d), colour.r);
    const text = try std.fmt.allocPrint(gpa, "{f}", .{colour});
    defer gpa.free(text);
    try testing.expectEqualStrings("#7dbdff", text);
    try testing.expectError(error.InvalidColor, Rgb.fromHex("#fff"));
}
