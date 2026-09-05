//! Data quality (ISO/IEC 25012 and 25024, ISO 8000, ISO/IEC 5259).
//!
//! Quality is fitness for a stated purpose, so nothing here reports a single
//! "quality score". Each characteristic is measured separately, against the
//! purpose the dataset records, and a characteristic with no measurement is
//! reported as unmeasured.
//!
//! ISO/IEC 5259 adds the parts that matter once data feeds a model: the measures
//! must be defined before the data is used, and the results must travel with
//! the dataset rather than living in someone's notebook.

const std = @import("std");
const timeutil = @import("../core/time.zig");
const units = @import("../interop/units.zig");
const idmod = @import("../core/id.zig");

pub const Timestamp = timeutil.Timestamp;

/// The ISO/IEC 25012 data quality characteristics.
pub const Characteristic = enum {
    /// The values are correct.
    accuracy,
    /// Everything that should be there is there.
    completeness,
    /// Values do not contradict each other.
    consistency,
    /// The data can be believed, and its source is known.
    credibility,
    /// The data is up to date for its purpose.
    currentness,
    /// Only those who should reach it can.
    accessibility,
    /// It follows the standards and rules it claims to.
    compliance,
    /// It is protected from being read or changed by the wrong people.
    confidentiality,
    /// It can be processed within the resources available.
    efficiency,
    /// The values are exact enough for the purpose.
    precision,
    /// Its history can be followed.
    traceability,
    /// It can be understood by those who need it.
    understandability,
    /// It can be moved between systems.
    portability,
    /// It can be recovered after a failure.
    recoverability,
    /// It is available when needed.
    availability,

    pub fn describe(self: Characteristic) []const u8 {
        return switch (self) {
            .accuracy => "The values are correct.",
            .completeness => "Everything that should be there is there.",
            .consistency => "Values do not contradict each other.",
            .credibility => "The data can be believed, and its source is known.",
            .currentness => "The data is recent enough for what it is used for.",
            .accessibility => "The people who need it can reach it, and others cannot.",
            .compliance => "It follows the rules and formats it claims to follow.",
            .confidentiality => "It is protected from the wrong readers.",
            .efficiency => "It can be processed with the resources available.",
            .precision => "The values are exact enough for the purpose.",
            .traceability => "Its history can be followed.",
            .understandability => "The people who use it can understand it.",
            .portability => "It can be moved to another system.",
            .recoverability => "It can be recovered after a failure.",
            .availability => "It is there when it is needed.",
        };
    }

    /// Characteristics that depend on the system holding the data rather than
    /// the data itself. ISO/IEC 25012 calls these system-dependent.
    pub fn isSystemDependent(self: Characteristic) bool {
        return switch (self) {
            .accessibility, .efficiency, .portability, .recoverability, .availability, .confidentiality => true,
            else => false,
        };
    }
};

/// A measure defined before the data is used, as ISO/IEC 25024 and ISO/IEC 5259
/// both require.
pub const Measure = struct {
    id: []const u8,
    characteristic: Characteristic,
    name: []const u8,
    /// How the number is computed, precisely enough to repeat.
    definition: []const u8,
    /// UCUM unit. `1` for a ratio.
    unit: []const u8 = "1",
    /// The lowest acceptable value for the dataset's purpose.
    threshold: ?f64 = null,
    higher_is_better: bool = true,

    pub fn validUnit(self: Measure) bool {
        _ = units.Unit.parse(self.unit) catch return false;
        return true;
    }
};

pub const Measurement = struct {
    measure_id: []const u8,
    value: f64,
    /// How many records the number was computed over.
    population: usize,
    measured_at: Timestamp,
    /// The version of the dataset measured.
    dataset_version: []const u8,
    note: []const u8 = "",

    pub fn meetsThreshold(self: Measurement, measure: Measure) ?bool {
        const threshold = measure.threshold orelse return null;
        return if (measure.higher_is_better) self.value >= threshold else self.value <= threshold;
    }
};

pub const Finding = struct {
    severity: enum { blocking, warning, note },
    message: []const u8,
};

/// A dataset's quality profile: the measures that apply to it and the results.
pub const Profile = struct {
    arena: std.mem.Allocator,
    dataset: idmod.DatasetId,
    /// The purpose quality is judged against, copied from the dataset so that a
    /// profile is readable on its own.
    purpose: []const u8,
    measures: std.ArrayList(Measure) = .empty,
    measurements: std.ArrayList(Measurement) = .empty,

    pub fn init(arena: std.mem.Allocator, dataset: idmod.DatasetId, purpose: []const u8) Profile {
        return .{ .arena = arena, .dataset = dataset, .purpose = purpose };
    }

    pub fn define(self: *Profile, item: Measure) !void {
        try self.measures.append(self.arena, item);
    }

    pub fn record(self: *Profile, measurement: Measurement) !void {
        // A measurement for a measure that was not defined first is exactly the
        // situation ISO/IEC 5259 asks organisations to avoid.
        for (self.measures.items) |m| {
            if (std.mem.eql(u8, m.id, measurement.measure_id)) {
                try self.measurements.append(self.arena, measurement);
                return;
            }
        }
        return error.MeasureNotDefined;
    }

    pub fn measure(self: Profile, id: []const u8) ?Measure {
        for (self.measures.items) |m| {
            if (std.mem.eql(u8, m.id, id)) return m;
        }
        return null;
    }

    pub fn latest(self: Profile, measure_id: []const u8) ?Measurement {
        var newest: ?Measurement = null;
        for (self.measurements.items) |m| {
            if (!std.mem.eql(u8, m.measure_id, measure_id)) continue;
            if (newest == null or m.measured_at.ns > newest.?.measured_at.ns) newest = m;
        }
        return newest;
    }

    pub fn unmeasured(self: Profile) !std.ArrayList(Measure) {
        var out: std.ArrayList(Measure) = .empty;
        for (self.measures.items) |m| {
            if (self.latest(m.id) == null) try out.append(self.arena, m);
        }
        return out;
    }

    /// Is the dataset fit for its stated purpose, as far as the measurements
    /// show? Anything unmeasured makes the answer "not established".
    pub const Verdict = enum {
        fit_for_purpose,
        not_fit_for_purpose,
        not_established,

        pub fn sentence(self: Verdict) []const u8 {
            return switch (self) {
                .fit_for_purpose => "Every defined measure was taken and met its threshold.",
                .not_fit_for_purpose => "At least one measure did not meet its threshold.",
                .not_established => "Some measures have not been taken, so fitness is not established.",
            };
        }
    };

    pub fn verdict(self: Profile) Verdict {
        var any_missing = false;
        for (self.measures.items) |m| {
            const measurement = self.latest(m.id) orelse {
                any_missing = true;
                continue;
            };
            if (measurement.meetsThreshold(m)) |meets| {
                if (!meets) return .not_fit_for_purpose;
            } else any_missing = true;
        }
        if (self.measures.items.len == 0) return .not_established;
        return if (any_missing) .not_established else .fit_for_purpose;
    }

    pub fn review(self: Profile) !std.ArrayList(Finding) {
        var findings: std.ArrayList(Finding) = .empty;
        for (self.measures.items) |m| {
            if (!m.validUnit()) {
                try findings.append(self.arena, .{
                    .severity = .warning,
                    .message = try std.fmt.allocPrint(self.arena, "The measure \"{s}\" uses an unknown unit \"{s}\".", .{ m.id, m.unit }),
                });
            }
            const measurement = self.latest(m.id) orelse {
                try findings.append(self.arena, .{
                    .severity = .warning,
                    .message = try std.fmt.allocPrint(self.arena, "\"{s}\" is defined but has never been measured.", .{m.name}),
                });
                continue;
            };
            if (measurement.population == 0) {
                try findings.append(self.arena, .{
                    .severity = .blocking,
                    .message = try std.fmt.allocPrint(self.arena, "The result for \"{s}\" was computed over no records.", .{m.name}),
                });
            }
            if (measurement.meetsThreshold(m)) |meets| {
                if (!meets) {
                    try findings.append(self.arena, .{
                        .severity = .blocking,
                        .message = try std.fmt.allocPrint(self.arena, "\"{s}\" is {d} {s}, which does not meet the threshold of {d} for this purpose.", .{ m.name, measurement.value, m.unit, m.threshold.? }),
                    });
                }
            }
        }
        return findings;
    }

    pub fn writeReport(self: Profile, w: *std.Io.Writer) !void {
        try w.print("Data quality for this dataset\nJudged against: {s}\n\n", .{self.purpose});
        for (self.measures.items) |m| {
            try w.print("{s} ({s})\n  {s}\n", .{ m.name, @tagName(m.characteristic), m.definition });
            if (self.latest(m.id)) |measurement| {
                try w.print("  {d} {s} over {d} records", .{ measurement.value, m.unit, measurement.population });
                if (measurement.meetsThreshold(m)) |meets| {
                    try w.print(" ({s} the threshold of {d})", .{ if (meets) "meets" else "below", m.threshold.? });
                }
                try w.writeAll("\n");
            } else {
                try w.writeAll("  Not measured.\n");
            }
        }
        try w.print("\n{s}\n", .{self.verdict().sentence()});
    }
};

/// ISO 8000 asks for data that carries its own meaning: values that reference
/// registered concepts, not private codes. This check reports values that a
/// receiving system could not interpret.
pub fn checkPortableMeaning(
    arena: std.mem.Allocator,
    field_name: []const u8,
    values: []const []const u8,
    permitted: []const []const u8,
) !std.ArrayList([]const u8) {
    var problems: std.ArrayList([]const u8) = .empty;
    for (values) |value| {
        var found = false;
        for (permitted) |allowed| {
            if (std.mem.eql(u8, allowed, value)) found = true;
        }
        if (!found) {
            try problems.append(arena, try std.fmt.allocPrint(arena, "The field \"{s}\" holds the value \"{s}\", which is not in its registered value list. Another system could not interpret it.", .{ field_name, value }));
        }
    }
    return problems;
}

const testing = std.testing;

fn sampleProfile(arena: std.mem.Allocator) !Profile {
    var gen: idmod.Generator = .init(411, 1_788_000_000_000);
    var profile = Profile.init(arena, gen.next(idmod.DatasetId), "Measure whether block boundaries agree with shell integration marks.");
    try profile.define(.{
        .id = "Q-COMPLETE",
        .characteristic = .completeness,
        .name = "Records with an exit status",
        .definition = "Records that carry an exit status, divided by all records.",
        .threshold = 0.99,
    });
    try profile.define(.{
        .id = "Q-ACCURATE",
        .characteristic = .accuracy,
        .name = "Boundaries that match the shell mark",
        .definition = "Records whose inferred boundary matches the shell mark, divided by all records with a mark.",
        .threshold = 0.95,
    });
    try profile.define(.{
        .id = "Q-CURRENT",
        .characteristic = .currentness,
        .name = "Age of the newest record",
        .definition = "Time between the newest record and the moment of measurement.",
        .unit = "d",
        .threshold = 7,
        .higher_is_better = false,
    });
    return profile;
}

test "a measurement needs a measure defined first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var profile = try sampleProfile(arena);
    try testing.expectError(error.MeasureNotDefined, profile.record(.{
        .measure_id = "Q-INVENTED",
        .value = 1.0,
        .population = 10,
        .measured_at = Timestamp.epoch,
        .dataset_version = "1",
    }));
}

test "fitness is not established while anything is unmeasured" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var profile = try sampleProfile(arena);
    try testing.expectEqual(Profile.Verdict.not_established, profile.verdict());

    try profile.record(.{ .measure_id = "Q-COMPLETE", .value = 0.998, .population = 12_000, .measured_at = Timestamp.epoch, .dataset_version = "2026-09" });
    try profile.record(.{ .measure_id = "Q-ACCURATE", .value = 0.97, .population = 9_000, .measured_at = Timestamp.epoch, .dataset_version = "2026-09" });
    try testing.expectEqual(Profile.Verdict.not_established, profile.verdict());

    try profile.record(.{ .measure_id = "Q-CURRENT", .value = 1, .population = 1, .measured_at = Timestamp.epoch, .dataset_version = "2026-09" });
    try testing.expectEqual(Profile.Verdict.fit_for_purpose, profile.verdict());
}

test "a measure below its threshold makes the dataset unfit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var profile = try sampleProfile(arena);
    try profile.record(.{ .measure_id = "Q-COMPLETE", .value = 0.80, .population = 12_000, .measured_at = Timestamp.epoch, .dataset_version = "2026-09" });
    try testing.expectEqual(Profile.Verdict.not_fit_for_purpose, profile.verdict());

    const findings = try profile.review();
    var blocking: usize = 0;
    for (findings.items) |f| {
        if (f.severity == .blocking) blocking += 1;
    }
    try testing.expectEqual(@as(usize, 1), blocking);
}

test "lower-is-better measures are judged in the right direction" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var profile = try sampleProfile(arena);
    const currentness = profile.measure("Q-CURRENT").?;
    const fresh: Measurement = .{ .measure_id = "Q-CURRENT", .value = 2, .population = 1, .measured_at = Timestamp.epoch, .dataset_version = "1" };
    const stale: Measurement = .{ .measure_id = "Q-CURRENT", .value = 30, .population = 1, .measured_at = Timestamp.epoch, .dataset_version = "1" };
    try testing.expect(fresh.meetsThreshold(currentness).?);
    try testing.expect(!stale.meetsThreshold(currentness).?);
}

test "values outside the registered list cannot travel" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const problems = try checkPortableMeaning(
        arena,
        "outcome",
        &.{ "completed", "failed", "wibble" },
        &.{ "completed", "failed", "denied", "cancelled", "timed_out" },
    );
    try testing.expectEqual(@as(usize, 1), problems.items.len);
    try testing.expect(std.mem.indexOf(u8, problems.items[0], "wibble") != null);
}

test "the report says what was measured and what was not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var profile = try sampleProfile(arena);
    try profile.record(.{ .measure_id = "Q-COMPLETE", .value = 0.998, .population = 12_000, .measured_at = Timestamp.epoch, .dataset_version = "2026-09" });

    var aw: std.Io.Writer.Allocating = .init(arena);
    try profile.writeReport(&aw.writer);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "Not measured.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "over 12000 records") != null);
    try testing.expect(std.mem.indexOf(u8, text, "fitness is not established") != null);
}
