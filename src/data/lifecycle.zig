//! Data lifecycle for AI systems (ISO/IEC 8183).
//!
//! A dataset is not a file. It is a thing with a purpose, a stage in its life,
//! a quality profile, a licence, a retention rule and a documented end. Naming
//! the stage matters because the obligations differ: a dataset in evaluation
//! must not be the one used in development, and a decommissioned dataset must
//! actually be gone.

const std = @import("std");
const idmod = @import("../core/id.zig");
const timeutil = @import("../core/time.zig");
const provenance_mod = @import("provenance.zig");
const hashing = @import("../core/hash.zig");

pub const Timestamp = timeutil.Timestamp;

pub const Stage = enum {
    /// Deciding what data is needed and whether it may be collected.
    planning,
    /// Getting the data.
    acquisition,
    /// Making data that did not exist before, including synthetic data.
    creation,
    /// Cleaning, labelling, joining, splitting.
    preparation,
    /// Building or tuning something with it.
    development,
    /// Measuring how well that something works.
    evaluation,
    /// Putting it into use.
    deployment,
    /// Using it day to day.
    operation,
    /// Correcting, updating and re-checking it.
    maintenance,
    /// Keeping it for the record, no longer using it.
    archival,
    /// Ending it: deleting, or provably destroying.
    decommissioning,

    pub fn describe(self: Stage) []const u8 {
        return switch (self) {
            .planning => "Deciding what data is needed and whether it may be collected.",
            .acquisition => "Getting the data from its source.",
            .creation => "Making data that did not exist before.",
            .preparation => "Cleaning, labelling and shaping the data.",
            .development => "Building or tuning a system with it.",
            .evaluation => "Measuring how well that system works.",
            .deployment => "Putting the system into use.",
            .operation => "Using it day to day.",
            .maintenance => "Correcting and updating it.",
            .archival => "Keeping it for the record, no longer using it.",
            .decommissioning => "Ending it: deleting or destroying it, and recording that.",
        };
    }

    /// The stages a dataset may move to next. A dataset cannot go back to
    /// acquisition once it has been used to evaluate something, because that
    /// would silently change what an evaluation meant.
    pub fn canMoveTo(self: Stage, next: Stage) bool {
        if (self == next) return true;
        return switch (self) {
            .planning => next == .acquisition or next == .creation,
            .acquisition, .creation => next == .preparation or next == .archival or next == .decommissioning,
            .preparation => next == .development or next == .evaluation or next == .archival,
            .development => next == .evaluation or next == .maintenance or next == .archival,
            .evaluation => next == .deployment or next == .maintenance or next == .archival,
            .deployment => next == .operation or next == .maintenance,
            .operation => next == .maintenance or next == .archival,
            .maintenance => next == .operation or next == .evaluation or next == .archival,
            .archival => next == .decommissioning,
            .decommissioning => false,
        };
    }
};

pub const Sensitivity = enum {
    /// No personal or confidential content.
    open,
    /// Confidential to the organisation.
    internal,
    /// Contains personal data.
    personal,
    /// Contains special-category personal data.
    sensitive_personal,
    /// Contains secrets such as credentials or keys.
    secret,

    pub fn requiresBasis(self: Sensitivity) bool {
        return self == .personal or self == .sensitive_personal;
    }
};

pub const RetentionRule = struct {
    /// Why it is kept this long.
    reason: []const u8,
    /// How long from the trigger event.
    duration: timeutil.Duration,
    /// What starts the clock.
    trigger: enum { creation, last_use, end_of_project, legal_requirement },
    /// What happens at the end.
    disposition: enum { delete, anonymise, archive, review },

    pub fn dueAt(self: RetentionRule, from: Timestamp) Timestamp {
        return from.addNanos(self.duration.ns);
    }
};

pub const Dataset = struct {
    id: idmod.DatasetId,
    name: []const u8,
    /// What the dataset is for. A dataset with no stated purpose cannot have
    /// its quality judged, because quality is fitness for a purpose.
    purpose: []const u8,
    stage: Stage,
    provenance: provenance_mod.Provenance,
    sensitivity: Sensitivity,
    /// Lawful basis or agreement covering personal data.
    basis: ?[]const u8 = null,
    license: ?[]const u8 = null,
    retention: RetentionRule,
    record_count: usize = 0,
    content_hash: hashing.Hash = hashing.Hash.zero,
    /// Datasets this one was derived from.
    derived_from: []const idmod.DatasetId = &.{},
    /// Set when the dataset has been decommissioned, with the proof.
    decommissioned_at: ?Timestamp = null,
    decommission_note: []const u8 = "",

    pub fn isActive(self: Dataset) bool {
        return self.decommissioned_at == null and self.stage != .decommissioning;
    }

    pub fn moveTo(self: *Dataset, next: Stage) !void {
        if (!self.stage.canMoveTo(next)) return error.InvalidStageTransition;
        self.stage = next;
    }

    /// Problems with the dataset record itself.
    pub fn review(self: Dataset, arena: std.mem.Allocator) !std.ArrayList([]const u8) {
        var findings: std.ArrayList([]const u8) = .empty;
        if (self.purpose.len == 0) {
            try findings.append(arena, "The dataset has no stated purpose, so nobody can judge whether it is fit for one.");
        }
        if (self.sensitivity.requiresBasis() and self.basis == null) {
            try findings.append(arena, "The dataset holds personal data with no stated basis for holding it.");
        }
        if (self.license == null and self.stage != .planning) {
            try findings.append(arena, "The dataset has no licence recorded, so its terms of use are unknown.");
        }
        if (self.stage == .decommissioning and self.decommissioned_at == null) {
            try findings.append(arena, "The dataset is being decommissioned but nothing records that it was actually destroyed.");
        }
        if (!self.provenance.completeness().has_sources and self.stage != .creation) {
            try findings.append(arena, "The dataset does not say where it came from.");
        }
        return findings;
    }

    pub fn retentionDue(self: Dataset) Timestamp {
        const from = switch (self.retention.trigger) {
            .creation => self.provenance.completed_at,
            else => self.provenance.completed_at,
        };
        return self.retention.dueAt(from);
    }

    pub fn isRetentionDue(self: Dataset, now: Timestamp) bool {
        return now.ns >= self.retentionDue().ns;
    }
};

const testing = std.testing;

fn sampleProvenance(gen: *idmod.Generator) provenance_mod.Provenance {
    return .{
        .producer = gen.next(idmod.ActorId),
        .producer_kind = .system,
        .source_artifacts = &.{gen.next(idmod.ArtifactId)},
        .environment = provenance_mod.EnvironmentFingerprint.current(),
        .started_at = Timestamp.epoch,
        .completed_at = Timestamp.epoch,
        .content_hash = hashing.Hash.of("data"),
    };
}

test "stage transitions follow the lifecycle" {
    try testing.expect(Stage.planning.canMoveTo(.acquisition));
    try testing.expect(Stage.preparation.canMoveTo(.evaluation));
    try testing.expect(!Stage.evaluation.canMoveTo(.acquisition));
    try testing.expect(!Stage.decommissioning.canMoveTo(.operation));
    try testing.expect(Stage.archival.canMoveTo(.decommissioning));
}

test "a dataset cannot skip backwards into acquisition" {
    var gen: idmod.Generator = .init(401, 1_788_000_000_000);
    var dataset: Dataset = .{
        .id = gen.next(idmod.DatasetId),
        .name = "evaluation set",
        .purpose = "Measure whether the block boundary detector agrees with shell marks.",
        .stage = .evaluation,
        .provenance = sampleProvenance(&gen),
        .sensitivity = .internal,
        .license = "internal use only",
        .retention = .{
            .reason = "Kept so an evaluation can be repeated.",
            .duration = timeutil.Duration.fromDays(365),
            .trigger = .creation,
            .disposition = .review,
        },
    };
    try testing.expectError(error.InvalidStageTransition, dataset.moveTo(.acquisition));
    try dataset.moveTo(.deployment);
    try testing.expectEqual(Stage.deployment, dataset.stage);
}

test "personal data without a basis is a finding" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(402, 1_788_000_000_000);
    const dataset: Dataset = .{
        .id = gen.next(idmod.DatasetId),
        .name = "support transcripts",
        .purpose = "Improve the error messages people see most often.",
        .stage = .preparation,
        .provenance = sampleProvenance(&gen),
        .sensitivity = .personal,
        .retention = .{
            .reason = "Kept only as long as the improvement work runs.",
            .duration = timeutil.Duration.fromDays(90),
            .trigger = .end_of_project,
            .disposition = .delete,
        },
    };
    const findings = try dataset.review(arena);
    try testing.expect(findings.items.len >= 2);
}

test "retention becomes due and decommissioning must be evidenced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(403, 1_788_000_000_000);
    var dataset: Dataset = .{
        .id = gen.next(idmod.DatasetId),
        .name = "cache",
        .purpose = "Speed up repeated searches.",
        .stage = .operation,
        .provenance = sampleProvenance(&gen),
        .sensitivity = .open,
        .license = "MIT",
        .retention = .{
            .reason = "A cache is not a record.",
            .duration = timeutil.Duration.fromDays(7),
            .trigger = .creation,
            .disposition = .delete,
        },
    };
    try testing.expect(dataset.isRetentionDue(Timestamp.epoch.addNanos(timeutil.ns_per_day * 8)));
    try testing.expect(!dataset.isRetentionDue(Timestamp.epoch.addNanos(timeutil.ns_per_day * 3)));

    try dataset.moveTo(.archival);
    try dataset.moveTo(.decommissioning);
    const findings = try dataset.review(arena);
    var saw_destruction_finding = false;
    for (findings.items) |f| {
        if (std.mem.indexOf(u8, f, "actually destroyed") != null) saw_destruction_finding = true;
    }
    try testing.expect(saw_destruction_finding);
    try testing.expect(!dataset.isActive());
}
