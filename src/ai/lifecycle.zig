//! AI system lifecycle processes (ISO/IEC 5338) and the machine-learning
//! framework vocabulary (ISO/IEC 23053).
//!
//! A lifecycle is only useful if a stage can be shown to have happened. So each
//! process here names what it produces, which capability it may need, and which
//! record in this system stands as evidence that it ran. A process with no
//! evidence is reported as not started, rather than assumed.

const std = @import("std");
const capability_mod = @import("capability.zig");
const timeutil = @import("../core/time.zig");

pub const Capability = capability_mod.Capability;
pub const Timestamp = timeutil.Timestamp;

/// The processes ISO/IEC 5338 adds to, or specialises from, ordinary software
/// lifecycle processes.
pub const Process = enum {
    /// Deciding what the system is for, and what it is not for.
    inception,
    /// Deciding what data is needed, and whether it may be used.
    data_acquisition,
    /// Preparing the data.
    data_preparation,
    /// Building or tuning the model.
    model_development,
    /// Measuring whether it works, against stated measures.
    verification_and_validation,
    /// Putting it into use.
    deployment,
    /// Running it, and watching what it does.
    operation_and_monitoring,
    /// Correcting and improving it.
    continuous_validation,
    /// Withdrawing it, and dealing with what it leaves behind.
    retirement,

    pub fn describe(self: Process) []const u8 {
        return switch (self) {
            .inception => "Decide what the system is for, who it affects, and what it must not be used for.",
            .data_acquisition => "Decide what data is needed, and establish that it may be used.",
            .data_preparation => "Clean, label and shape the data, and record what was done to it.",
            .model_development => "Build or tune the model, recording the settings that produced it.",
            .verification_and_validation => "Measure whether it works, against measures set before the measurement.",
            .deployment => "Put it into use, with the policy and the oversight it needs.",
            .operation_and_monitoring => "Run it, and watch what it actually does.",
            .continuous_validation => "Re-measure it as the world changes around it.",
            .retirement => "Withdraw it, and deal with the data and records it leaves.",
        };
    }

    /// The record in this system that shows the process ran.
    pub fn evidenceKind(self: Process) []const u8 {
        return switch (self) {
            .inception => "an impact assessment with intended and excluded uses",
            .data_acquisition => "a dataset record with a lawful basis and a licence",
            .data_preparation => "a dataset quality profile with measured characteristics",
            .model_development => "provenance carrying the model, the settings and the sources",
            .verification_and_validation => "quality measurements against defined measures",
            .deployment => "a policy record and an approval record",
            .operation_and_monitoring => "the workspace event log",
            .continuous_validation => "a later quality measurement, with its conditions",
            .retirement => "a disposition record in the records ledger",
        };
    }
};

/// The parts of a machine-learning system, in the ISO/IEC 23053 sense. Naming
/// them lets a report say which part a finding is about.
pub const Component = enum {
    data_pipeline,
    model,
    inference_engine,
    monitoring,
    feedback_loop,
    human_interface,

    pub fn describe(self: Component) []const u8 {
        return switch (self) {
            .data_pipeline => "What brings data in and prepares it.",
            .model => "What turns an input into an output.",
            .inference_engine => "What runs the model when a request arrives.",
            .monitoring => "What watches the system in use.",
            .feedback_loop => "What feeds what happened back into the system.",
            .human_interface => "Where a person sees the output and can act on it.",
        };
    }
};

pub const Status = enum {
    not_started,
    in_progress,
    complete,
    /// The process does not apply to this system, with a reason.
    not_applicable,
};

pub const Stage = struct {
    process: Process,
    status: Status,
    /// Where the evidence is. Empty when there is none.
    evidence: []const u8 = "",
    /// Who owns this stage.
    owner: []const u8 = "unassigned",
    /// Why it does not apply, when it does not.
    reason: []const u8 = "",
    updated_at: ?Timestamp = null,

    pub fn isEvidenced(self: Stage) bool {
        return switch (self.status) {
            .complete, .in_progress => self.evidence.len > 0,
            .not_applicable => self.reason.len > 0,
            .not_started => true,
        };
    }
};

pub const Record = struct {
    system_name: []const u8,
    stages: []const Stage,
    components: []const Component,

    pub fn stage(self: Record, process: Process) ?Stage {
        for (self.stages) |s| {
            if (s.process == process) return s;
        }
        return null;
    }

    pub fn missing(self: Record, arena: std.mem.Allocator) !std.ArrayList(Process) {
        var out: std.ArrayList(Process) = .empty;
        inline for (std.meta.fields(Process)) |field| {
            const process: Process = @enumFromInt(field.value);
            if (self.stage(process) == null) try out.append(arena, process);
        }
        return out;
    }

    pub fn review(self: Record, arena: std.mem.Allocator) !std.ArrayList([]const u8) {
        var findings: std.ArrayList([]const u8) = .empty;
        for (self.stages) |s| {
            if (!s.isEvidenced()) {
                try findings.append(arena, try std.fmt.allocPrint(arena, "\"{s}\" is recorded as {s} with nothing to show for it. Name the record that shows it happened.", .{ @tagName(s.process), @tagName(s.status) }));
            }
            if (std.mem.eql(u8, s.owner, "unassigned") and s.status != .not_applicable) {
                try findings.append(arena, try std.fmt.allocPrint(arena, "\"{s}\" has no owner.", .{@tagName(s.process)}));
            }
        }
        const gaps = try self.missing(arena);
        for (gaps.items) |process| {
            try findings.append(arena, try std.fmt.allocPrint(arena, "\"{s}\" is not in the record at all. Every process is either done, in progress, not started, or not applicable with a reason.", .{@tagName(process)}));
        }
        return findings;
    }

    pub fn writeReport(self: Record, arena: std.mem.Allocator, w: *std.Io.Writer) !void {
        try w.print("Lifecycle of {s}\n\n", .{self.system_name});
        for (self.stages) |s| {
            try w.print("{s}  [{s}]\n    {s}\n", .{ @tagName(s.process), @tagName(s.status), s.process.describe() });
            if (s.evidence.len > 0) {
                try w.print("    Shown by: {s}\n", .{s.evidence});
            } else if (s.status == .not_applicable) {
                try w.print("    Does not apply: {s}\n", .{s.reason});
            } else if (s.status != .not_started) {
                try w.print("    Nothing recorded yet. It should be shown by {s}.\n", .{s.process.evidenceKind()});
            }
            try w.print("    Owner: {s}\n", .{s.owner});
        }
        const findings = try self.review(arena);
        if (findings.items.len == 0) {
            try w.writeAll("\nEvery process is accounted for.\n");
            return;
        }
        try w.writeAll("\nOpen items:\n");
        for (findings.items) |finding| try w.print("  - {s}\n", .{finding});
    }
};

/// Where the workbench itself stands. It runs no model of its own, so several
/// processes do not apply — and each says why, rather than being left out.
pub fn workbenchRecord() Record {
    return .{
        .system_name = "the zag workbench",
        .components = &.{ .human_interface, .monitoring, .inference_engine },
        .stages = &.{
            .{
                .process = .inception,
                .status = .complete,
                .evidence = "docs/ generated impact assessment, with intended and excluded uses",
                .owner = "workbench maintainers",
            },
            .{
                .process = .data_acquisition,
                .status = .not_applicable,
                .reason = "The workbench collects no data of its own. It records what the person's own work produces, on their machine.",
                .owner = "workbench maintainers",
            },
            .{
                .process = .data_preparation,
                .status = .not_applicable,
                .reason = "No dataset is prepared: the event log is a record of what happened, not a training set.",
                .owner = "workbench maintainers",
            },
            .{
                .process = .model_development,
                .status = .not_applicable,
                .reason = "No model is trained here. The operator configures a provider, and the provenance records which model produced what.",
                .owner = "workbench maintainers",
            },
            .{
                .process = .verification_and_validation,
                .status = .in_progress,
                .evidence = "the quality measures in src/ai/evaluation.zig, and the test suite",
                .owner = "workbench maintainers",
            },
            .{
                .process = .deployment,
                .status = .in_progress,
                .evidence = "the policy records and approval records in the event log",
                .owner = "workbench maintainers",
            },
            .{
                .process = .operation_and_monitoring,
                .status = .in_progress,
                .evidence = "the workspace event log, which verifies",
                .owner = "workbench maintainers",
            },
            .{
                .process = .continuous_validation,
                .status = .not_started,
                .owner = "workbench maintainers",
            },
            .{
                .process = .retirement,
                .status = .not_started,
                .owner = "workbench maintainers",
            },
        },
    };
}

const testing = std.testing;

test "every process says what it is and what shows it happened" {
    inline for (std.meta.fields(Process)) |field| {
        const process: Process = @enumFromInt(field.value);
        try testing.expect(process.describe().len > 20);
        try testing.expect(process.evidenceKind().len > 10);
    }
}

test "the workbench's own lifecycle record is complete" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const record = workbenchRecord();
    const gaps = try record.missing(arena);
    try testing.expectEqual(@as(usize, 0), gaps.items.len);

    const findings = try record.review(arena);
    if (findings.items.len > 0) {
        for (findings.items) |finding| std.debug.print("{s}\n", .{finding});
    }
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "a stage that claims progress without evidence is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const thin: Record = .{
        .system_name = "something",
        .components = &.{},
        .stages = &.{.{ .process = .deployment, .status = .complete }},
    };
    const findings = try thin.review(arena);
    // No evidence, no owner, and eight processes missing from the record.
    try testing.expect(findings.items.len >= 10);
}

test "the report names what has not started" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(arena);
    try workbenchRecord().writeReport(arena, &aw.writer);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "continuous_validation  [not_started]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "No model is trained here") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Every process is accounted for.") != null);
}
