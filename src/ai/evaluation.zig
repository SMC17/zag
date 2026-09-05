//! Quality measurement for AI systems (ISO/IEC 25059 over ISO/IEC 25010).
//!
//! The rule this module enforces is simple: a quality claim needs a measure, a
//! unit, a method and a sample. A characteristic with no measurement is
//! reported as unmeasured rather than assumed to be fine.

const std = @import("std");
const units = @import("../interop/units.zig");
const timeutil = @import("../core/time.zig");

pub const Timestamp = timeutil.Timestamp;

/// Quality characteristics. The first group is the ISO/IEC 25010 set that
/// applies to any software; the second is the AI-specific extension.
pub const Characteristic = enum {
    functional_correctness,
    performance_efficiency,
    compatibility,
    usability,
    reliability,
    security,
    maintainability,
    portability,
    // AI-specific
    functional_adaptability,
    robustness,
    transparency,
    controllability,
    intervenability,

    pub fn isAiSpecific(self: Characteristic) bool {
        return switch (self) {
            .functional_adaptability, .robustness, .transparency, .controllability, .intervenability => true,
            else => false,
        };
    }

    /// What the characteristic means here, for the person reading a report.
    pub fn describe(self: Characteristic) []const u8 {
        return switch (self) {
            .functional_correctness => "The system produces the right result.",
            .performance_efficiency => "The system is fast enough and uses a reasonable amount of the machine.",
            .compatibility => "The system works with the tools and formats around it.",
            .usability => "People can do what they came to do.",
            .reliability => "The system keeps working, and recovers when it does not.",
            .security => "The system protects information and refuses actions it should refuse.",
            .maintainability => "The system can be changed without breaking.",
            .portability => "The system runs where it needs to run.",
            .functional_adaptability => "The system still works when the input differs from what it saw before.",
            .robustness => "The system holds up under unusual, noisy or hostile input.",
            .transparency => "A person can find out what the system did and why.",
            .controllability => "A person can direct or stop the system.",
            .intervenability => "A person can step in, change the outcome and be heard.",
        };
    }
};

pub const Method = enum {
    /// A test suite run automatically.
    automated_test,
    /// A benchmark measured under stated conditions.
    benchmark,
    /// Analysis of the code or the design.
    static_analysis,
    /// People tried real tasks and the result was measured.
    user_study,
    /// An expert judged the system against criteria.
    expert_review,

    pub fn isAutomatable(self: Method) bool {
        return switch (self) {
            .automated_test, .benchmark, .static_analysis => true,
            .user_study, .expert_review => false,
        };
    }
};

pub const Measure = struct {
    id: []const u8,
    characteristic: Characteristic,
    /// What is counted, in words.
    name: []const u8,
    /// UCUM unit code. `1` for a plain ratio, `{count}` for a count.
    unit: []const u8,
    higher_is_better: bool,
    /// The value the product aims for, when there is one.
    target: ?f64 = null,
    /// How the number is produced. Written so that someone else could repeat it.
    method_description: []const u8,

    pub fn validUnit(self: Measure) bool {
        _ = units.Unit.parse(self.unit) catch return false;
        return true;
    }
};

pub const Result = struct {
    measure_id: []const u8,
    value: f64,
    /// Number of observations behind the value.
    sample_size: usize,
    method: Method,
    measured_at: Timestamp,
    /// Conditions the number depends on: machine, dataset, version.
    conditions: []const u8 = "",
    /// The dataset used, when there was one.
    dataset: ?[]const u8 = null,

    pub fn meetsTarget(self: Result, against: Measure) ?bool {
        const target = against.target orelse return null;
        return if (against.higher_is_better) self.value >= target else self.value <= target;
    }
};

pub const Suite = struct {
    arena: std.mem.Allocator,
    measures: std.ArrayList(Measure) = .empty,
    results: std.ArrayList(Result) = .empty,

    pub fn init(arena: std.mem.Allocator) Suite {
        return .{ .arena = arena };
    }

    pub fn addMeasure(self: *Suite, item: Measure) !void {
        try self.measures.append(self.arena, item);
    }

    pub fn addResult(self: *Suite, result: Result) !void {
        try self.results.append(self.arena, result);
    }

    pub fn measure(self: Suite, id: []const u8) ?Measure {
        for (self.measures.items) |m| {
            if (std.mem.eql(u8, m.id, id)) return m;
        }
        return null;
    }

    pub fn latestFor(self: Suite, measure_id: []const u8) ?Result {
        var latest: ?Result = null;
        for (self.results.items) |result| {
            if (!std.mem.eql(u8, result.measure_id, measure_id)) continue;
            if (latest == null or result.measured_at.ns > latest.?.measured_at.ns) latest = result;
        }
        return latest;
    }

    /// Characteristics with no measurement at all.
    pub fn unmeasured(self: Suite) !std.ArrayList(Characteristic) {
        var out: std.ArrayList(Characteristic) = .empty;
        inline for (std.meta.fields(Characteristic)) |field| {
            const characteristic: Characteristic = @enumFromInt(field.value);
            var found = false;
            for (self.measures.items) |m| {
                if (m.characteristic != characteristic) continue;
                if (self.latestFor(m.id) != null) found = true;
            }
            if (!found) try out.append(self.arena, characteristic);
        }
        return out;
    }

    /// Measures whose latest result misses the target.
    pub fn missingTarget(self: Suite) !std.ArrayList(Measure) {
        var out: std.ArrayList(Measure) = .empty;
        for (self.measures.items) |m| {
            const result = self.latestFor(m.id) orelse continue;
            if (result.meetsTarget(m)) |meets| {
                if (!meets) try out.append(self.arena, m);
            }
        }
        return out;
    }

    /// Problems with the suite itself.
    pub fn review(self: Suite) !std.ArrayList([]const u8) {
        var findings: std.ArrayList([]const u8) = .empty;
        for (self.measures.items) |m| {
            if (!m.validUnit()) {
                try findings.append(self.arena, try std.fmt.allocPrint(self.arena, "The measure \"{s}\" uses the unit \"{s}\", which is not a unit this system understands.", .{ m.id, m.unit }));
            }
            if (self.latestFor(m.id)) |result| {
                if (result.sample_size == 0) {
                    try findings.append(self.arena, try std.fmt.allocPrint(self.arena, "The result for \"{s}\" reports no sample size, so it cannot be judged.", .{m.id}));
                }
                if (result.conditions.len == 0 and result.method == .benchmark) {
                    try findings.append(self.arena, try std.fmt.allocPrint(self.arena, "The benchmark \"{s}\" does not say what it was measured on. A benchmark without conditions cannot be compared.", .{m.id}));
                }
            }
        }
        return findings;
    }

    pub fn writeReport(self: Suite, w: *std.Io.Writer) !void {
        try w.writeAll("Quality measurements\n\n");
        for (self.measures.items) |m| {
            try w.print("{s}  {s}\n", .{ m.id, m.name });
            if (self.latestFor(m.id)) |result| {
                try w.print("    {d} {s}", .{ result.value, m.unit });
                if (m.target) |target| {
                    const meets = result.meetsTarget(m) orelse false;
                    try w.print("  (target {d}, {s})", .{ target, if (meets) "met" else "not met" });
                }
                try w.print("\n    From {d} observations, by {s}.", .{ result.sample_size, @tagName(result.method) });
                if (result.conditions.len > 0) try w.print(" Conditions: {s}.", .{result.conditions});
                try w.writeAll("\n");
            } else {
                try w.writeAll("    Not measured yet.\n");
            }
        }
        const gaps = try self.unmeasured();
        if (gaps.items.len > 0) {
            try w.writeAll("\nNot measured at all:\n");
            for (gaps.items) |characteristic| {
                try w.print("  - {s}: {s}\n", .{ @tagName(characteristic), characteristic.describe() });
            }
        }
        try w.print("\n{s}\n", .{limits_statement});
    }
};

pub const limits_statement =
    "These numbers describe what was measured, under the conditions stated. " ++
    "A characteristic with no measurement is unmeasured, not satisfied.";

/// The measures the workbench holds itself to. Targets come from the
/// performance gates in the architecture, not from wishes.
pub fn workbenchSuite(arena: std.mem.Allocator) !Suite {
    var suite = Suite.init(arena);

    try suite.addMeasure(.{
        .id = "M-KEYSTROKE-LATENCY",
        .characteristic = .performance_efficiency,
        .name = "Time from key press to the frame that shows it",
        .unit = "ms",
        .higher_is_better = false,
        .target = 10,
        .method_description = "Measured on an idle machine over 1000 key presses, reporting the 99th percentile.",
    });
    try suite.addMeasure(.{
        .id = "M-PTY-THROUGHPUT",
        .characteristic = .performance_efficiency,
        .name = "Sustained pseudoterminal ingest",
        .unit = "MiBy/s",
        .higher_is_better = true,
        .target = 100,
        .method_description = "Reading a 1 GiB stream of mixed text and escape sequences through the parser and the grid.",
    });
    try suite.addMeasure(.{
        .id = "M-POLICY-CORRECTNESS",
        .characteristic = .security,
        .name = "Policy decisions that match the written rule",
        .unit = "1",
        .higher_is_better = true,
        .target = 1.0,
        .method_description = "Every case in the policy test suite, including path traversal and expiry.",
    });
    try suite.addMeasure(.{
        .id = "M-LOG-INTEGRITY",
        .characteristic = .reliability,
        .name = "Logs that verify after a simulated crash",
        .unit = "1",
        .higher_is_better = true,
        .target = 1.0,
        .method_description = "Truncating a written log at every byte offset and checking that loading recovers a verified prefix.",
    });
    try suite.addMeasure(.{
        .id = "M-PROMPT-CLARITY",
        .characteristic = .transparency,
        .name = "Generated approval prompts with no major plain-language finding",
        .unit = "1",
        .higher_is_better = true,
        .target = 1.0,
        .method_description = "Running the plain-language checker over every generated prompt.",
    });
    try suite.addMeasure(.{
        .id = "M-STOPPABLE",
        .characteristic = .controllability,
        .name = "Agent runs that stop within one step of a cancel",
        .unit = "1",
        .higher_is_better = true,
        .target = 1.0,
        .method_description = "Cancelling at each step of a recorded plan and checking that no further tool call is made.",
    });

    return suite;
}

const testing = std.testing;

test "measures declare a real unit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const suite = try workbenchSuite(arena);
    for (suite.measures.items) |m| {
        try testing.expect(m.validUnit());
    }
    const findings = try suite.review();
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "a characteristic with no result is reported as unmeasured" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var suite = try workbenchSuite(arena);
    const gaps_before = try suite.unmeasured();
    try testing.expect(gaps_before.items.len > 0);

    try suite.addResult(.{
        .measure_id = "M-KEYSTROKE-LATENCY",
        .value = 8.4,
        .sample_size = 1000,
        .method = .benchmark,
        .measured_at = try Timestamp.parseIso("2026-09-04T12:00:00Z"),
        .conditions = "Linux 6.18, release build, idle machine",
    });

    const latest = suite.latestFor("M-KEYSTROKE-LATENCY").?;
    try testing.expect(latest.meetsTarget(suite.measure("M-KEYSTROKE-LATENCY").?).?);

    var still_unmeasured = false;
    const gaps_after = try suite.unmeasured();
    for (gaps_after.items) |c| {
        if (c == .performance_efficiency) still_unmeasured = true;
    }
    try testing.expect(!still_unmeasured);
}

test "a missed target is reported rather than rounded away" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var suite = try workbenchSuite(arena);
    try suite.addResult(.{
        .measure_id = "M-KEYSTROKE-LATENCY",
        .value = 18.0,
        .sample_size = 1000,
        .method = .benchmark,
        .measured_at = try Timestamp.parseIso("2026-09-04T12:00:00Z"),
        .conditions = "Debug build, shared machine",
    });
    const missed = try suite.missingTarget();
    try testing.expectEqual(@as(usize, 1), missed.items.len);
    try testing.expectEqualStrings("M-KEYSTROKE-LATENCY", missed.items[0].id);
}

test "a benchmark without conditions is a finding" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var suite = Suite.init(arena);
    try suite.addMeasure(.{
        .id = "M-X",
        .characteristic = .performance_efficiency,
        .name = "Something",
        .unit = "ms",
        .higher_is_better = false,
        .method_description = "Somehow.",
    });
    try suite.addResult(.{
        .measure_id = "M-X",
        .value = 1,
        .sample_size = 0,
        .method = .benchmark,
        .measured_at = Timestamp.epoch,
    });
    const findings = try suite.review();
    try testing.expectEqual(@as(usize, 2), findings.items.len);
}

test "the report says what was not measured" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const suite = try workbenchSuite(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try suite.writeReport(&aw.writer);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "Not measured yet.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Not measured at all:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "unmeasured, not satisfied") != null);
}
