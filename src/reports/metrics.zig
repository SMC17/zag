//! The metric registry.
//!
//! A dashboard that shows "17%" is not reporting anything: seventeen per cent
//! of what, measured when, against what, moving which way? A metric here is a
//! registered thing with a unit, a period, a source, a direction and a
//! comparison basis, and a value cannot be published without them.

const std = @import("std");
const units = @import("../interop/units.zig");
const timeutil = @import("../core/time.zig");

pub const Timestamp = timeutil.Timestamp;

/// What kind of quantity the metric is. This decides how it may be aggregated:
/// a stock cannot be summed over time, a rate cannot be summed at all.
pub const Kind = enum {
    /// A count over a period: commands run, tokens used.
    flow,
    /// A level at an instant: open sessions, memory in use.
    stock,
    /// A ratio or a rate: failures per run, bytes per second.
    rate,
    /// A position in a distribution: the 99th percentile of a latency.
    quantile,
};

/// Which direction is good. Without this, a chart cannot be coloured honestly.
pub const Direction = enum {
    higher_is_better,
    lower_is_better,
    /// Neither: it is context, not performance.
    neutral,
};

pub const Period = struct {
    start: Timestamp,
    end: Timestamp,

    pub fn duration(self: Period) timeutil.Duration {
        return self.end.since(self.start);
    }

    pub fn contains(self: Period, at: Timestamp) bool {
        return at.ns >= self.start.ns and at.ns < self.end.ns;
    }

    pub fn writeIso(self: Period, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var start_buf: [Timestamp.text_len_max]u8 = undefined;
        var end_buf: [Timestamp.text_len_max]u8 = undefined;
        // ISO 8601 time interval, start and end.
        try w.print("{s}/{s}", .{ self.start.toIso(&start_buf, .second), self.end.toIso(&end_buf, .second) });
    }
};

pub const Metric = struct {
    id: []const u8,
    /// What is counted, in words a reader understands without the identifier.
    name: []const u8,
    /// One sentence saying exactly what is included and excluded.
    definition: []const u8,
    kind: Kind,
    /// UCUM unit code. `1` for a plain ratio, `{command}` for a count of
    /// commands, `ms` for a duration.
    unit: []const u8,
    direction: Direction,
    /// Where the number comes from.
    source: []const u8,
    /// The number of decimal places to show. More precision than the
    /// measurement supports is a lie told with a decimal point.
    decimals: u8 = 0,

    pub fn validate(self: Metric) !void {
        _ = units.Unit.parse(self.unit) catch return error.UnknownUnit;
    }
};

/// What a value is being compared with. A number with no basis of comparison
/// tells the reader nothing about whether it is good.
pub const Comparison = union(enum) {
    none,
    /// The same metric in the period before this one.
    previous_period: f64,
    /// A target the team set.
    target: f64,
    /// A published baseline, such as another product's measured figure.
    baseline: struct { value: f64, source: []const u8 },
};

pub const Confidence = enum {
    /// A complete count.
    measured,
    /// A sample; the interval is stated separately.
    sampled,
    /// A projection or an estimate.
    estimated,

    pub fn text(self: Confidence) []const u8 {
        return switch (self) {
            .measured => "measured",
            .sampled => "sampled",
            .estimated => "estimated",
        };
    }
};

pub const Value = struct {
    metric_id: []const u8,
    value: f64,
    period: Period,
    comparison: Comparison = .none,
    confidence: Confidence = .measured,
    /// Number of observations behind the value, for a sample.
    sample_size: ?usize = null,
    /// Anything the reader must know to read the number correctly.
    note: []const u8 = "",

    /// Change against the comparison basis, as a fraction. Null when there is
    /// nothing to compare with, or when the basis is zero.
    pub fn change(self: Value) ?f64 {
        const basis: f64 = switch (self.comparison) {
            .none => return null,
            .previous_period => |v| v,
            .target => |v| v,
            .baseline => |b| b.value,
        };
        if (basis == 0) return null;
        return (self.value - basis) / basis;
    }

    /// Is the movement in the good direction? Null when the metric is neutral
    /// or there is nothing to compare with.
    pub fn isImprovement(self: Value, metric: Metric) ?bool {
        const delta = self.change() orelse return null;
        return switch (metric.direction) {
            .higher_is_better => delta > 0,
            .lower_is_better => delta < 0,
            .neutral => null,
        };
    }
};

pub const Registry = struct {
    arena: std.mem.Allocator,
    metrics: std.ArrayList(Metric) = .empty,
    values: std.ArrayList(Value) = .empty,

    pub fn init(arena: std.mem.Allocator) Registry {
        return .{ .arena = arena };
    }

    pub fn define(self: *Registry, item: Metric) !void {
        try item.validate();
        try self.metrics.append(self.arena, item);
    }

    pub fn publish(self: *Registry, value: Value) !void {
        if (self.metric(value.metric_id) == null) return error.MetricNotDefined;
        if (value.confidence == .sampled and value.sample_size == null) return error.SampleSizeRequired;
        try self.values.append(self.arena, value);
    }

    pub fn metric(self: Registry, id: []const u8) ?Metric {
        for (self.metrics.items) |m| {
            if (std.mem.eql(u8, m.id, id)) return m;
        }
        return null;
    }

    pub fn latest(self: Registry, metric_id: []const u8) ?Value {
        var newest: ?Value = null;
        for (self.values.items) |value| {
            if (!std.mem.eql(u8, value.metric_id, metric_id)) continue;
            if (newest == null or value.period.end.ns > newest.?.period.end.ns) newest = value;
        }
        return newest;
    }
};

const testing = std.testing;

test "a metric must have a real unit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var registry = Registry.init(arena_state.allocator());

    try registry.define(.{
        .id = "commands-run",
        .name = "Commands run",
        .definition = "Commands submitted through a session, including those an agent submitted.",
        .kind = .flow,
        .unit = "{command}",
        .direction = .neutral,
        .source = "the workspace event log",
    });
    try testing.expectError(error.UnknownUnit, registry.define(.{
        .id = "nonsense",
        .name = "Nonsense",
        .definition = "Something.",
        .kind = .flow,
        .unit = "furlongs",
        .direction = .neutral,
        .source = "nowhere",
    }));
}

test "a value cannot be published for an undefined metric" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var registry = Registry.init(arena_state.allocator());
    const period: Period = .{
        .start = try Timestamp.parseIso("2026-09-01T00:00:00Z"),
        .end = try Timestamp.parseIso("2026-09-08T00:00:00Z"),
    };
    try testing.expectError(error.MetricNotDefined, registry.publish(.{ .metric_id = "unknown", .value = 1, .period = period }));
}

test "a sample must say how large it was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var registry = Registry.init(arena_state.allocator());
    try registry.define(.{
        .id = "latency",
        .name = "Keystroke latency, 99th percentile",
        .definition = "Time from a key press to the frame that shows it, on an idle machine.",
        .kind = .quantile,
        .unit = "ms",
        .direction = .lower_is_better,
        .source = "the render benchmark",
        .decimals = 1,
    });
    const period: Period = .{
        .start = try Timestamp.parseIso("2026-09-01T00:00:00Z"),
        .end = try Timestamp.parseIso("2026-09-08T00:00:00Z"),
    };
    try testing.expectError(error.SampleSizeRequired, registry.publish(.{
        .metric_id = "latency",
        .value = 8.4,
        .period = period,
        .confidence = .sampled,
    }));
    try registry.publish(.{
        .metric_id = "latency",
        .value = 8.4,
        .period = period,
        .confidence = .sampled,
        .sample_size = 1000,
    });
    try testing.expect(registry.latest("latency") != null);
}

test "improvement depends on the metric's direction" {
    const lower: Metric = .{
        .id = "latency",
        .name = "Latency",
        .definition = "Time to draw.",
        .kind = .quantile,
        .unit = "ms",
        .direction = .lower_is_better,
        .source = "benchmark",
    };
    const period: Period = .{ .start = Timestamp.epoch, .end = Timestamp.epoch.addNanos(timeutil.ns_per_day) };
    const improved: Value = .{ .metric_id = "latency", .value = 8.0, .period = period, .comparison = .{ .previous_period = 10.0 } };
    try testing.expect(improved.isImprovement(lower).?);
    try testing.expectApproxEqAbs(@as(f64, -0.2), improved.change().?, 0.0001);

    const higher: Metric = .{
        .id = "throughput",
        .name = "Throughput",
        .definition = "Bytes handled.",
        .kind = .rate,
        .unit = "MiBy/s",
        .direction = .higher_is_better,
        .source = "benchmark",
    };
    const worse: Value = .{ .metric_id = "throughput", .value = 80, .period = period, .comparison = .{ .previous_period = 100 } };
    try testing.expect(!worse.isImprovement(higher).?);

    const neutral: Metric = .{
        .id = "commands",
        .name = "Commands",
        .definition = "How many.",
        .kind = .flow,
        .unit = "{command}",
        .direction = .neutral,
        .source = "log",
    };
    const any: Value = .{ .metric_id = "commands", .value = 10, .period = period, .comparison = .{ .previous_period = 5 } };
    try testing.expect(any.isImprovement(neutral) == null);
}

test "a period writes as an iso 8601 interval" {
    var buf: [80]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const period: Period = .{
        .start = try Timestamp.parseIso("2026-09-01T00:00:00Z"),
        .end = try Timestamp.parseIso("2026-09-08T00:00:00Z"),
    };
    try period.writeIso(&w);
    try testing.expectEqualStrings("2026-09-01T00:00:00Z/2026-09-08T00:00:00Z", w.buffered());
    try testing.expectEqual(@as(i64, 7), @divTrunc(period.duration().seconds(), 86400));
}
