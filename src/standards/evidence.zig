//! Evidence, and the conformance statements built from it.
//!
//! This module exists to stop one specific lie: "ISO compliant: 93/100".
//! A checker can find problems. It cannot establish that a reader understood a
//! sentence, that a person can complete a task, or that an organisation runs a
//! management system. So every piece of evidence records *how* it was obtained,
//! and the statement generator reports untested requirements as untested.

const std = @import("std");
const idmod = @import("../core/id.zig");
const hashing = @import("../core/hash.zig");
const timeutil = @import("../core/time.zig");
const requirement = @import("requirement.zig");
const registry_mod = @import("registry.zig");

pub const Method = requirement.VerificationMethod;
pub const Requirement = requirement.Requirement;
pub const Scope = requirement.Scope;

pub const Result = enum {
    pass,
    fail,
    /// Some of the requirement was established; the rest was not.
    partial,
    /// The requirement does not apply to this artefact.
    not_applicable,
    /// Nothing has established this either way.
    not_tested,

    pub fn text(self: Result) []const u8 {
        return switch (self) {
            .pass => "passed",
            .fail => "failed",
            .partial => "partly established",
            .not_applicable => "does not apply",
            .not_tested => "not tested",
        };
    }
};

pub const ToolIdentity = struct {
    name: []const u8,
    version: []const u8,
};

pub const Evidence = struct {
    id: idmod.EvidenceId,
    requirement_id: []const u8,
    /// What was examined: a file path, an artefact identifier, a screen name.
    subject: []const u8,
    method: Method,
    result: Result,
    tool: ?ToolIdentity = null,
    reviewer: ?idmod.ActorId = null,
    created_at: timeutil.Timestamp,
    /// Hash of the material that was examined, so the evidence can be tied to
    /// one exact version of the artefact.
    content_hash: hashing.Hash,
    /// What was found, in plain language.
    note: []const u8 = "",

    /// Evidence obtained by judgement needs a named reviewer; evidence obtained
    /// by a tool needs a named tool. Otherwise it is not evidence.
    pub fn isWellFormed(self: Evidence) bool {
        if (self.method.isAutomatable()) return self.tool != null;
        return self.reviewer != null;
    }
};

/// What the system can honestly say about one requirement.
pub const RequirementStatus = struct {
    requirement: Requirement,
    best: Result,
    automated_checked: bool,
    judgement_recorded: bool,
    evidence_count: usize,

    /// A requirement whose verification method needs a person, with no such
    /// evidence recorded, is open however many checks passed.
    pub fn needsHumanEvaluation(self: RequirementStatus) bool {
        if (!self.requirement.verification.isAutomatable() and !self.judgement_recorded) return true;
        if (self.requirement.residual_judgement != null and !self.judgement_recorded) return true;
        return false;
    }
};

pub const Claim = enum {
    /// Something failed. Nothing may be claimed.
    not_conformant,
    /// Everything that can be checked by machine passed, and human evaluation
    /// is still outstanding. This is the honest state of most releases.
    checks_passed_judgement_outstanding,
    /// Every applicable requirement has evidence of the kind its verification
    /// method requires, and none failed.
    supported_by_evidence,
    /// Nothing applicable was found to check.
    nothing_applicable,

    pub fn sentence(self: Claim) []const u8 {
        return switch (self) {
            .not_conformant => "This build does not meet its own rules. The failures are listed below.",
            .checks_passed_judgement_outstanding => "Every automated check passed. Some rules can only be settled by people, and that work is still open.",
            .supported_by_evidence => "Every rule that applies has evidence of the kind it requires, and none failed.",
            .nothing_applicable => "No rule in this profile applies to what was examined.",
        };
    }
};

pub const Summary = struct {
    claim: Claim,
    total: usize,
    passed: usize,
    failed: usize,
    partial: usize,
    not_tested: usize,
    not_applicable: usize,
    needing_human_evaluation: usize,
    blocking_failures: usize,
};

pub const Ledger = struct {
    arena: std.mem.Allocator,
    items: std.ArrayList(Evidence) = .empty,

    pub fn init(arena: std.mem.Allocator) Ledger {
        return .{ .arena = arena };
    }

    pub fn record(self: *Ledger, e: Evidence) !void {
        try self.items.append(self.arena, e);
    }

    pub fn forRequirement(self: Ledger, requirement_id: []const u8) !std.ArrayList(Evidence) {
        var out: std.ArrayList(Evidence) = .empty;
        for (self.items.items) |e| {
            if (std.mem.eql(u8, e.requirement_id, requirement_id)) try out.append(self.arena, e);
        }
        return out;
    }

    /// Status of one requirement given everything recorded about it.
    pub fn statusOf(self: Ledger, r: Requirement) !RequirementStatus {
        var best: Result = .not_tested;
        var automated = false;
        var judgement = false;
        var count: usize = 0;
        for (self.items.items) |e| {
            if (!std.mem.eql(u8, e.requirement_id, r.id)) continue;
            if (!e.isWellFormed()) continue;
            count += 1;
            if (e.method.isAutomatable()) automated = true else judgement = true;
            best = worst(best, e.result);
        }
        return .{
            .requirement = r,
            .best = best,
            .automated_checked = automated,
            .judgement_recorded = judgement,
            .evidence_count = count,
        };
    }

    /// A failure always wins; otherwise the strongest recorded result stands.
    fn worst(current: Result, incoming: Result) Result {
        if (current == .fail or incoming == .fail) return .fail;
        if (current == .partial or incoming == .partial) return .partial;
        if (current == .pass or incoming == .pass) return .pass;
        if (current == .not_applicable or incoming == .not_applicable) return .not_applicable;
        return .not_tested;
    }

    pub fn summarise(
        self: Ledger,
        reg: registry_mod.Registry,
        scope: Scope,
        profile: ?[]const u8,
    ) !Summary {
        const applicable = try reg.applicable(scope, profile);
        var summary: Summary = .{
            .claim = .nothing_applicable,
            .total = applicable.items.len,
            .passed = 0,
            .failed = 0,
            .partial = 0,
            .not_tested = 0,
            .not_applicable = 0,
            .needing_human_evaluation = 0,
            .blocking_failures = 0,
        };
        for (applicable.items) |r| {
            const status = try self.statusOf(r);
            switch (status.best) {
                .pass => summary.passed += 1,
                .fail => {
                    summary.failed += 1;
                    if (r.severity.blocksRelease()) summary.blocking_failures += 1;
                },
                .partial => summary.partial += 1,
                .not_applicable => summary.not_applicable += 1,
                .not_tested => summary.not_tested += 1,
            }
            if (status.needsHumanEvaluation()) summary.needing_human_evaluation += 1;
        }
        summary.claim = decide(summary);
        return summary;
    }

    fn decide(s: Summary) Claim {
        if (s.total == 0) return .nothing_applicable;
        if (s.failed > 0) return .not_conformant;
        if (s.needing_human_evaluation > 0 or s.not_tested > 0 or s.partial > 0) {
            return .checks_passed_judgement_outstanding;
        }
        return .supported_by_evidence;
    }

    /// Write the conformance statement a person reads. It says what was
    /// checked, how, and what is still open — never a score.
    pub fn writeStatement(
        self: Ledger,
        w: *std.Io.Writer,
        reg: registry_mod.Registry,
        scope: Scope,
        profile: ?[]const u8,
    ) !void {
        const summary = try self.summarise(reg, scope, profile);
        try w.print("Conformance statement for {s} under profile \"{s}\"\n\n", .{ @tagName(scope), profile orelse "default" });
        try w.print("{s}\n\n", .{summary.claim.sentence()});
        try w.print("Rules that apply: {d}\n", .{summary.total});
        try w.print("  Passed:            {d}\n", .{summary.passed});
        try w.print("  Failed:            {d}", .{summary.failed});
        if (summary.blocking_failures > 0) {
            const verb = if (summary.blocking_failures == 1) "blocks" else "block";
            try w.print(" (of which {d} {s} a release)", .{ summary.blocking_failures, verb });
        }
        try w.writeAll("\n");
        try w.print("  Partly settled:    {d}\n", .{summary.partial});
        try w.print("  Not tested:        {d}\n", .{summary.not_tested});
        try w.print("  Do not apply:      {d}\n", .{summary.not_applicable});
        try w.print("  Waiting on people: {d}\n\n", .{summary.needing_human_evaluation});

        const applicable = try reg.applicable(scope, profile);
        for (applicable.items) |r| {
            const status = try self.statusOf(r);
            try w.print("{s}  {s}\n", .{ r.id, status.best.text() });
            try w.print("    Rule:   {s}\n", .{r.statement});
            try w.print("    Method: {s}\n", .{r.verification.explain()});
            if (status.needsHumanEvaluation()) {
                const residual = r.residual_judgement orelse "This rule is settled by people, not by a program.";
                try w.print("    Open:   {s}\n", .{residual});
            }
            try w.writeAll("\n");
        }
    }
};

fn sampleRegistry(arena: std.mem.Allocator) !registry_mod.Registry {
    var reg = registry_mod.Registry.init(arena);
    try reg.addStandard(.{
        .namespace = "iso",
        .identifier = "ISO 24495-1",
        .edition = "2023",
        .title = "Plain language - governing principles",
        .status = .published,
        .enforcement = .mandatory,
    });
    try reg.addRequirement(.{
        .id = "R-FINDABLE",
        .standard_id = "ISO 24495-1",
        .statement = "The reader can find what they need.",
        .applicability = .{ .scopes = &.{.documentation} },
        .verification = .static_analysis,
        .rationale = "Findability is one of the four governing principles.",
        .check_id = "PL020",
    });
    try reg.addRequirement(.{
        .id = "R-USABLE",
        .standard_id = "ISO 24495-1",
        .statement = "The reader can use the information the first time they read it.",
        .applicability = .{ .scopes = &.{.documentation} },
        .verification = .usability_test,
        .severity = .blocking,
        .rationale = "The standard asks for evaluation, not for shorter words.",
        .residual_judgement = "Only testing with readers settles this.",
    });
    return reg;
}

test "a passing checker does not produce a conformance claim on its own" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reg = try sampleRegistry(arena);

    var ledger = Ledger.init(arena);
    var gen: idmod.Generator = .init(1, 1_788_000_000_000);
    try ledger.record(.{
        .id = gen.next(idmod.EvidenceId),
        .requirement_id = "R-FINDABLE",
        .subject = "docs/getting-started.md",
        .method = .static_analysis,
        .result = .pass,
        .tool = .{ .name = "zag lint", .version = "0.1.0" },
        .created_at = try timeutil.Timestamp.parseIso("2026-09-04T20:00:00Z"),
        .content_hash = hashing.Hash.of("doc"),
        .note = "No undefined abbreviations and no missing headings were found.",
    });

    const summary = try ledger.summarise(reg, .documentation, "default");
    try std.testing.expectEqual(Claim.checks_passed_judgement_outstanding, summary.claim);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 1), summary.not_tested);
    try std.testing.expectEqual(@as(usize, 1), summary.needing_human_evaluation);
}

test "human evaluation completes the picture" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reg = try sampleRegistry(arena);

    var ledger = Ledger.init(arena);
    var gen: idmod.Generator = .init(2, 1_788_000_000_000);
    try ledger.record(.{
        .id = gen.next(idmod.EvidenceId),
        .requirement_id = "R-FINDABLE",
        .subject = "docs/getting-started.md",
        .method = .static_analysis,
        .result = .pass,
        .tool = .{ .name = "zag lint", .version = "0.1.0" },
        .created_at = timeutil.Timestamp.epoch,
        .content_hash = hashing.Hash.of("doc"),
    });
    try ledger.record(.{
        .id = gen.next(idmod.EvidenceId),
        .requirement_id = "R-USABLE",
        .subject = "docs/getting-started.md",
        .method = .usability_test,
        .result = .pass,
        .reviewer = gen.next(idmod.ActorId),
        .created_at = timeutil.Timestamp.epoch,
        .content_hash = hashing.Hash.of("doc"),
        .note = "Five of five participants completed the first task without help.",
    });

    const summary = try ledger.summarise(reg, .documentation, "default");
    try std.testing.expectEqual(Claim.supported_by_evidence, summary.claim);
    try std.testing.expectEqual(@as(usize, 0), summary.needing_human_evaluation);
}

test "a failure blocks the claim and is reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reg = try sampleRegistry(arena);

    var ledger = Ledger.init(arena);
    var gen: idmod.Generator = .init(3, 1_788_000_000_000);
    try ledger.record(.{
        .id = gen.next(idmod.EvidenceId),
        .requirement_id = "R-USABLE",
        .subject = "docs/getting-started.md",
        .method = .usability_test,
        .result = .fail,
        .reviewer = gen.next(idmod.ActorId),
        .created_at = timeutil.Timestamp.epoch,
        .content_hash = hashing.Hash.of("doc"),
        .note = "Three of five participants could not find how to grant an approval.",
    });

    const summary = try ledger.summarise(reg, .documentation, "default");
    try std.testing.expectEqual(Claim.not_conformant, summary.claim);
    try std.testing.expectEqual(@as(usize, 1), summary.blocking_failures);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try ledger.writeStatement(&aw.writer, reg, .documentation, "default");
    const text = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "does not meet its own rules") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocks a release") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "not tested") != null);
}

test "evidence without a tool or a reviewer is ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ledger = Ledger.init(arena);
    var gen: idmod.Generator = .init(4, 1_788_000_000_000);

    const anonymous: Evidence = .{
        .id = gen.next(idmod.EvidenceId),
        .requirement_id = "R-FINDABLE",
        .subject = "docs/x.md",
        .method = .manual_review,
        .result = .pass,
        .created_at = timeutil.Timestamp.epoch,
        .content_hash = hashing.Hash.of("x"),
    };
    try std.testing.expect(!anonymous.isWellFormed());
    try ledger.record(anonymous);

    const reg = try sampleRegistry(arena);
    const status = try ledger.statusOf(reg.requirements.get("R-FINDABLE").?);
    try std.testing.expectEqual(Result.not_tested, status.best);
    try std.testing.expectEqual(@as(usize, 0), status.evidence_count);
}
