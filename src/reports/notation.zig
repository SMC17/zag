//! Report notation (ISO 24896).
//!
//! One notation for every report the workbench produces, so that a number means
//! the same thing wherever it appears: the same position for the unit, the same
//! marker for a variance, the same treatment for a sampled figure, the same
//! words for a period.
//!
//! Text output is the primary form here. A chart is a second view of the same
//! rows, and it is built from these values rather than from raw numbers, so a
//! chart cannot show a figure the table does not.

const std = @import("std");
const metrics = @import("metrics.zig");
const currency_mod = @import("../interop/currency.zig");
const timeutil = @import("../core/time.zig");

pub const Metric = metrics.Metric;
pub const Value = metrics.Value;

/// How a variance is marked. The marker never depends on the sign alone: it
/// depends on whether the movement is good, which the metric declares.
pub const Variance = enum {
    better,
    worse,
    unchanged,
    /// The metric declares no direction, so the movement is reported without
    /// judgement.
    neutral,

    pub fn marker(self: Variance) []const u8 {
        return switch (self) {
            .better => "+",
            .worse => "-",
            .unchanged => "=",
            .neutral => "~",
        };
    }

    pub fn word(self: Variance) []const u8 {
        return switch (self) {
            .better => "better",
            .worse => "worse",
            .unchanged => "unchanged",
            .neutral => "changed",
        };
    }
};

pub fn varianceOf(value: Value, metric: Metric) Variance {
    const delta = value.change() orelse return .unchanged;
    if (@abs(delta) < 0.005) return .unchanged;
    const improvement = value.isImprovement(metric) orelse return .neutral;
    return if (improvement) .better else .worse;
}

/// Write a number with the metric's precision. Money is written through the
/// currency rules; everything else takes the metric's decimal places.
pub fn writeNumber(w: *std.Io.Writer, metric: Metric, value: f64) !void {
    if (metric.currency_code) |code| {
        const currency_code = try currency_mod.CurrencyCode.parse(code);
        var scale: f64 = 1;
        for (0..currency_code.minorUnits()) |_| scale *= 10;
        const money: currency_mod.Money = .{ .minor = @intFromFloat(@round(value * scale)), .currency = currency_code };
        try w.print("{f}", .{money});
        return;
    }
    switch (metric.decimals) {
        0 => try w.print("{d:.0}", .{value}),
        1 => try w.print("{d:.1}", .{value}),
        2 => try w.print("{d:.2}", .{value}),
        else => try w.print("{d:.3}", .{value}),
    }
}

/// The full presentation of one value: number, unit, variance and confidence.
pub fn writeValue(w: *std.Io.Writer, metric: Metric, value: Value) !void {
    try writeNumber(w, metric, value.value);
    if (metric.currency_code == null and !std.mem.eql(u8, metric.unit, "1")) {
        try w.print(" {s}", .{metric.unit});
    }

    if (value.change()) |delta| {
        const variance = varianceOf(value, metric);
        const percent = @abs(delta) * 100;
        try w.print("  {s}{d:.1}%", .{ variance.marker(), percent });
        switch (value.comparison) {
            .previous_period => try w.writeAll(" against the period before"),
            .target => try w.writeAll(" against target"),
            .baseline => |b| try w.print(" against {s}", .{b.source}),
            .none => {},
        }
    }

    if (value.confidence != .measured) {
        try w.print("  ({s}", .{value.confidence.text()});
        if (value.sample_size) |n| try w.print(", n={d}", .{n});
        try w.writeAll(")");
    }
}

pub const Table = struct {
    title: []const u8,
    /// The period every row covers, when they share one.
    period: ?metrics.Period = null,
    rows: []const Row,

    pub const Row = struct {
        metric: Metric,
        value: Value,
    };

    pub fn write(self: Table, w: *std.Io.Writer) !void {
        try w.print("{s}\n", .{self.title});
        if (self.period) |period| {
            try w.writeAll("Period: ");
            try period.writeIso(w);
            try w.writeAll("\n");
        }
        try w.writeAll("\n");

        // Column widths are computed so the table lines up in a terminal.
        var name_width: usize = 0;
        for (self.rows) |row| name_width = @max(name_width, row.metric.name.len);

        for (self.rows) |row| {
            try w.writeAll(row.metric.name);
            var pad = name_width - row.metric.name.len;
            while (pad > 0) : (pad -= 1) try w.writeByte(' ');
            try w.writeAll("  ");
            try writeValue(w, row.metric, row.value);
            try w.writeAll("\n");
        }

        try w.writeAll("\n");
        try w.writeAll(footnote);
        try w.writeAll("\n");
        for (self.rows) |row| {
            try w.print("  {s}: {s} Source: {s}.\n", .{ row.metric.name, row.metric.definition, row.metric.source });
        }
    }
};

pub const footnote =
    "How to read this: a plus sign means the figure moved in the better direction " ++
    "for that measure, a minus sign means it moved the worse way, and a tilde means " ++
    "the measure has no better or worse. Each measure is defined below.";

/// A horizontal bar chart in text. It is deliberately simple: the point is that
/// the chart and the table are produced from the same values, with the same
/// units and the same variance rules.
pub const BarChart = struct {
    title: []const u8,
    metric: Metric,
    bars: []const Bar,
    width: usize = 40,

    pub const Bar = struct {
        label: []const u8,
        value: f64,
    };

    pub fn write(self: BarChart, w: *std.Io.Writer) !void {
        try w.print("{s}\n", .{self.title});
        try w.print("Measured in {s}. ", .{if (self.metric.currency_code) |c| c else self.metric.unit});
        try w.print("{s}\n\n", .{switch (self.metric.direction) {
            .higher_is_better => "Higher is better.",
            .lower_is_better => "Lower is better.",
            .neutral => "Neither higher nor lower is better.",
        }});

        var largest: f64 = 0;
        var label_width: usize = 0;
        for (self.bars) |bar| {
            largest = @max(largest, bar.value);
            label_width = @max(label_width, bar.label.len);
        }
        if (largest == 0) largest = 1;

        for (self.bars) |bar| {
            try w.writeAll(bar.label);
            var pad = label_width - bar.label.len;
            while (pad > 0) : (pad -= 1) try w.writeByte(' ');
            try w.writeAll("  ");

            const filled: usize = @intFromFloat(@round(bar.value / largest * @as(f64, @floatFromInt(self.width))));
            var drawn: usize = 0;
            while (drawn < filled) : (drawn += 1) try w.writeByte('#');
            while (drawn < self.width) : (drawn += 1) try w.writeByte(' ');
            try w.writeAll("  ");
            try writeNumber(w, self.metric, bar.value);
            try w.writeAll("\n");
        }
        // The scale is stated, because a bar chart without one invites the
        // reader to compare lengths that mean nothing.
        try w.writeAll("\nThe longest bar is ");
        try writeNumber(w, self.metric, largest);
        try w.print(" {s}.\n", .{self.metric.unit});
    }
};

const testing = std.testing;

fn sampleMetric() Metric {
    return .{
        .id = "latency",
        .name = "Keystroke latency, 99th percentile",
        .definition = "Time from a key press to the frame that shows it, on an idle machine.",
        .kind = .quantile,
        .unit = "ms",
        .direction = .lower_is_better,
        .source = "the render benchmark",
        .decimals = 1,
    };
}

test "a falling number is better when lower is better" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const metric = sampleMetric();
    const value: Value = .{
        .metric_id = "latency",
        .value = 8.0,
        .period = .{ .start = timeutil.Timestamp.epoch, .end = timeutil.Timestamp.epoch },
        .comparison = .{ .previous_period = 10.0 },
    };
    try testing.expectEqual(Variance.better, varianceOf(value, metric));

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeValue(&aw.writer, metric, value);
    try testing.expectEqualStrings("8.0 ms  +20.0% against the period before", aw.written());
}

test "money is written through the currency rules" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const metric: Metric = .{
        .id = "cost",
        .name = "Cost of agent runs",
        .definition = "What the model provider charged for runs in this workspace.",
        .kind = .flow,
        .unit = "1",
        .direction = .lower_is_better,
        .source = "provider invoices",
        .currency_code = "USD",
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeValue(&aw.writer, metric, .{
        .metric_id = "cost",
        .value = 12.5,
        .period = .{ .start = timeutil.Timestamp.epoch, .end = timeutil.Timestamp.epoch },
    });
    try testing.expectEqualStrings("12.50 USD", aw.written());
}

test "a sampled figure says so, with its sample size" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeValue(&aw.writer, sampleMetric(), .{
        .metric_id = "latency",
        .value = 8.4,
        .period = .{ .start = timeutil.Timestamp.epoch, .end = timeutil.Timestamp.epoch },
        .confidence = .sampled,
        .sample_size = 1000,
    });
    try testing.expectEqualStrings("8.4 ms  (sampled, n=1000)", aw.written());
}

test "a table defines every measure it shows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const period: metrics.Period = .{
        .start = try timeutil.Timestamp.parseIso("2026-09-01T00:00:00Z"),
        .end = try timeutil.Timestamp.parseIso("2026-09-08T00:00:00Z"),
    };
    const table: Table = .{
        .title = "Workspace, week of 1 September 2026",
        .period = period,
        .rows = &.{
            .{
                .metric = sampleMetric(),
                .value = .{ .metric_id = "latency", .value = 8.4, .period = period, .comparison = .{ .target = 10.0 } },
            },
            .{
                .metric = .{
                    .id = "commands",
                    .name = "Commands run",
                    .definition = "Commands submitted through a session, including those an agent submitted.",
                    .kind = .flow,
                    .unit = "{command}",
                    .direction = .neutral,
                    .source = "the workspace event log",
                },
                .value = .{ .metric_id = "commands", .value = 412, .period = period, .comparison = .{ .previous_period = 388 } },
            },
        },
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    try table.write(&aw.writer);
    const text = aw.written();

    try testing.expect(std.mem.indexOf(u8, text, "Period: 2026-09-01T00:00:00Z/2026-09-08T00:00:00Z") != null);
    try testing.expect(std.mem.indexOf(u8, text, "+16.0% against target") != null);
    // A neutral metric moves without being judged.
    try testing.expect(std.mem.indexOf(u8, text, "~6.2% against the period before") != null);
    try testing.expect(std.mem.indexOf(u8, text, "How to read this") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Source: the workspace event log.") != null);
}

test "a chart states its unit, its direction and its scale" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const chart: BarChart = .{
        .title = "Keystroke latency by build",
        .metric = sampleMetric(),
        .bars = &.{
            .{ .label = "debug", .value = 18.2 },
            .{ .label = "release", .value = 8.4 },
        },
        .width = 20,
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try chart.write(&aw.writer);
    const text = aw.written();

    try testing.expect(std.mem.indexOf(u8, text, "Measured in ms.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Lower is better.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "The longest bar is 18.2 ms.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "####") != null);
}
