//! AI system impact assessment (ISO/IEC 42005).
//!
//! An impact assessment records how a system may affect people and
//! organisations, and what the operator does about it. It is written once and
//! reviewed on a schedule; the record here is the durable part, so that the
//! assessment can be produced from the system's own configuration rather than
//! from memory.

const std = @import("std");
const risk_mod = @import("risk.zig");
const timeutil = @import("../core/time.zig");
const idmod = @import("../core/id.zig");

pub const Timestamp = timeutil.Timestamp;

/// Who is affected. Naming groups separately is what stops an assessment from
/// only considering the buyer.
pub const AffectedGroup = struct {
    name: []const u8,
    description: []const u8,
    /// Can this group choose not to be affected?
    can_opt_out: bool,
    /// Can this group challenge a decision the system contributed to?
    can_challenge: bool,
};

pub const ImpactArea = enum {
    /// Work, employment and skills.
    work,
    /// Safety of people or property.
    safety,
    /// Privacy and data protection.
    privacy,
    /// Fairness between groups of people.
    fairness,
    /// Ability to understand and question a decision.
    autonomy,
    /// Security of systems and information.
    security,
    /// Environmental cost.
    environment,
    /// Legal or contractual exposure.
    legal,
};

pub const Direction = enum { benefit, harm, both };

pub const Assessment = struct {
    id: []const u8,
    /// The system this assessment is about.
    system_name: []const u8,
    system_version: []const u8,
    /// What the system is for. One sentence.
    intended_use: []const u8,
    /// Uses that are out of scope, stated so that they can be refused.
    excluded_uses: []const []const u8,
    /// Where the system runs and who operates it.
    deployment_context: []const u8,
    affected_groups: []const AffectedGroup,
    impacts: []const Entry,
    /// Risks from the register that this assessment covers.
    linked_risks: []const []const u8 = &.{},
    assessed_by: []const u8,
    assessed_at: Timestamp,
    /// When this must be looked at again.
    review_due: Timestamp,
    /// Decisions a person must be able to override.
    human_oversight: []const u8,

    pub const Entry = struct {
        area: ImpactArea,
        direction: Direction,
        /// What could happen, concretely.
        description: []const u8,
        /// Who it happens to.
        group: []const u8,
        severity: risk_mod.Impact,
        /// What the operator does about it.
        mitigation: []const u8,
    };

    pub fn isDue(self: Assessment, now: Timestamp) bool {
        return now.ns >= self.review_due.ns;
    }

    pub fn harms(self: Assessment, arena: std.mem.Allocator) !std.ArrayList(Entry) {
        var out: std.ArrayList(Entry) = .empty;
        for (self.impacts) |entry| {
            if (entry.direction == .harm or entry.direction == .both) try out.append(arena, entry);
        }
        return out;
    }

    /// Problems with the assessment itself.
    pub fn review(self: Assessment, arena: std.mem.Allocator) !std.ArrayList([]const u8) {
        var findings: std.ArrayList([]const u8) = .empty;
        if (self.excluded_uses.len == 0) {
            try findings.append(arena, "The assessment does not say what the system must not be used for.");
        }
        if (self.affected_groups.len == 0) {
            try findings.append(arena, "The assessment does not name anyone the system affects.");
        }
        for (self.affected_groups) |group| {
            if (!group.can_challenge) {
                try findings.append(arena, try std.fmt.allocPrint(arena, "\"{s}\" cannot challenge a decision. Say how they raise a problem.", .{group.name}));
            }
        }
        const harm_entries = try self.harms(arena);
        for (harm_entries.items) |entry| {
            if (entry.mitigation.len == 0) {
                try findings.append(arena, try std.fmt.allocPrint(arena, "The harm \"{s}\" has no mitigation.", .{entry.description}));
            }
        }
        if (self.human_oversight.len == 0) {
            try findings.append(arena, "The assessment does not say what a person can override.");
        }
        return findings;
    }

    pub fn writeText(self: Assessment, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("Impact assessment: {s} {s}\n\n", .{ self.system_name, self.system_version });
        try w.print("What it is for\n  {s}\n\n", .{self.intended_use});
        try w.writeAll("What it must not be used for\n");
        for (self.excluded_uses) |use| try w.print("  - {s}\n", .{use});
        try w.print("\nWhere it runs\n  {s}\n\n", .{self.deployment_context});
        try w.writeAll("Who it affects\n");
        for (self.affected_groups) |group| {
            try w.print("  - {s}: {s}\n", .{ group.name, group.description });
            try w.print("    Can opt out: {s}. Can challenge a decision: {s}.\n", .{
                if (group.can_opt_out) "yes" else "no",
                if (group.can_challenge) "yes" else "no",
            });
        }
        try w.writeAll("\nWhat could happen\n");
        for (self.impacts) |entry| {
            try w.print("  - [{s}, {s}] {s}\n", .{ @tagName(entry.area), @tagName(entry.direction), entry.description });
            try w.print("    Who: {s}. Severity: {s}.\n", .{ entry.group, @tagName(entry.severity) });
            if (entry.mitigation.len > 0) try w.print("    What we do: {s}\n", .{entry.mitigation});
        }
        try w.print("\nWhat a person can override\n  {s}\n", .{self.human_oversight});
        var assessed_buf: [Timestamp.text_len_max]u8 = undefined;
        var due_buf: [Timestamp.text_len_max]u8 = undefined;
        try w.print("\nAssessed by {s} on {s}. Next review by {s}.\n", .{
            self.assessed_by,
            self.assessed_at.toIso(&assessed_buf, .second),
            self.review_due.toIso(&due_buf, .second),
        });
    }
};

/// The assessment the workbench ships for itself.
pub fn workbenchAssessment(arena: std.mem.Allocator) !Assessment {
    _ = arena;
    return .{
        .id = "IA-WORKBENCH-1",
        .system_name = "zag workbench",
        .system_version = "0.1.0",
        .intended_use = "Help a developer run commands, read and change code, and direct agents, on their own computer or on a machine they control.",
        .excluded_uses = &.{
            "Deciding anything about a person, such as employment, credit, benefits or access.",
            "Running without a person able to see and stop what an agent does.",
            "Processing personal data that the operator has not accounted for.",
        },
        .deployment_context = "On a developer's own machine, or on a machine their organisation controls. The workspace and its log stay on that machine unless the operator connects a remote provider.",
        .affected_groups = &.{
            .{
                .name = "the person using it",
                .description = "A developer whose files, commands and repositories the system acts on.",
                .can_opt_out = true,
                .can_challenge = true,
            },
            .{
                .name = "their colleagues",
                .description = "People who share the repositories the system can change, and who receive its commits.",
                .can_opt_out = false,
                .can_challenge = true,
            },
            .{
                .name = "people whose data is in the workspace",
                .description = "Anyone whose personal data happens to sit in a file the system reads.",
                .can_opt_out = false,
                .can_challenge = true,
            },
        },
        .impacts = &.{
            .{
                .area = .work,
                .direction = .both,
                .description = "Work that used to take a person a long time is done faster, and skills that are no longer exercised may fade.",
                .group = "the person using it",
                .severity = .moderate,
                .mitigation = "Every change an agent makes is shown as a reviewable diff with its provenance, so a person stays in the loop rather than accepting output unseen.",
            },
            .{
                .area = .privacy,
                .direction = .harm,
                .description = "A file containing personal data is sent to a model provider as part of a request.",
                .group = "people whose data is in the workspace",
                .severity = .major,
                .mitigation = "Sending anything to a provider needs the model capability, which is a policy decision and can be denied outright. The log records what was sent by hash.",
            },
            .{
                .area = .security,
                .direction = .harm,
                .description = "Content the agent reads steers it into an action the person did not ask for.",
                .group = "the person using it",
                .severity = .major,
                .mitigation = "Capabilities are decided by the local policy engine, never by text the agent read; repository instruction files cannot grant permissions.",
            },
            .{
                .area = .autonomy,
                .direction = .benefit,
                .description = "A person can see exactly what was done, by whom, under which policy, and can replay it.",
                .group = "their colleagues",
                .severity = .moderate,
                .mitigation = "",
            },
            .{
                .area = .environment,
                .direction = .harm,
                .description = "Model requests consume energy in a data centre.",
                .group = "people whose data is in the workspace",
                .severity = .minor,
                .mitigation = "Local providers are supported, and the workbench reports request counts so an operator can see the cost.",
            },
        },
        .linked_risks = &.{ "R-INJECTION", "R-EGRESS", "R-IRREVERSIBLE", "R-WRONG-OUTPUT" },
        .assessed_by = "workbench maintainers",
        .assessed_at = try Timestamp.parseIso("2026-09-04T00:00:00Z"),
        .review_due = try Timestamp.parseIso("2027-03-04T00:00:00Z"),
        .human_oversight = "A person can stop any agent, refuse any approval, and withdraw any standing permission. Operations that cannot be undone always stop and ask.",
    };
}

const testing = std.testing;

test "the shipped assessment answers the questions it must" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const assessment = try workbenchAssessment(arena);
    const findings = try assessment.review(arena);
    if (findings.items.len > 0) {
        for (findings.items) |f| std.debug.print("{s}\n", .{f});
    }
    try testing.expectEqual(@as(usize, 0), findings.items.len);

    const harms = try assessment.harms(arena);
    try testing.expect(harms.items.len >= 3);
    for (harms.items) |harm| try testing.expect(harm.mitigation.len > 0);
}

test "an assessment with no excluded uses is incomplete" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const thin: Assessment = .{
        .id = "IA-THIN",
        .system_name = "thing",
        .system_version = "0.0.1",
        .intended_use = "Do work.",
        .excluded_uses = &.{},
        .deployment_context = "Somewhere.",
        .affected_groups = &.{},
        .impacts = &.{},
        .assessed_by = "nobody",
        .assessed_at = Timestamp.epoch,
        .review_due = Timestamp.epoch,
        .human_oversight = "",
    };
    const findings = try thin.review(arena);
    try testing.expect(findings.items.len >= 3);
    try testing.expect(thin.isDue(try Timestamp.parseIso("2026-09-04T00:00:00Z")));
}

test "the assessment prints as a document a person can read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const assessment = try workbenchAssessment(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try assessment.writeText(&aw.writer);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "What it must not be used for") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Can challenge a decision") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Next review by 2027-03-04") != null);
}
