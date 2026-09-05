//! Requirements: the addressable units of a standard.
//!
//! A standard is prose. A requirement is the part of that prose the workbench
//! can act on: what it applies to, when it applies, how it is checked, and how
//! serious a failure is. Requirements are deliberately *not* auto-generated
//! from standard text — they are written by people who have read the standard,
//! and each one records who wrote it and why.

const std = @import("std");

/// What kind of thing a requirement applies to.
pub const Scope = enum {
    /// Text shown in the product: labels, messages, prompts, help.
    interface_text,
    /// Documentation, release notes, guides.
    documentation,
    /// Legal or contractual text.
    legal_text,
    /// Scientific, benchmark or evaluation reporting.
    scientific_text,
    /// The rendered user interface: colour, focus, target size, keyboard.
    user_interface,
    /// Terminology and controlled vocabularies.
    terminology,
    /// Metadata about artefacts and datasets.
    metadata,
    /// Datasets and their quality.
    data,
    /// The AI system, its risks, its documentation and its governance.
    ai_system,
    /// Records, retention and disposition.
    records,
    /// Machine interfaces and exchange formats.
    interface_contract,
    /// Reports, dashboards and quantitative presentation.
    reporting,
    /// The organisation's processes around all of the above.
    process,
};

/// How a requirement can be checked. The distinction matters more than
/// anything else in this subsystem: a tool may only claim the kinds of
/// conformance it can actually establish.
pub const VerificationMethod = enum {
    /// A program inspects the artefact and decides.
    static_analysis,
    /// A test executes the system and observes behaviour.
    automated_test,
    /// A qualified person reviews the artefact against the requirement.
    manual_review,
    /// Representative users attempt real tasks and the result is measured.
    usability_test,
    /// An independent party audits the evidence.
    audit,
    /// The system records something as it operates, and the record is the
    /// evidence.
    generated_record,

    pub fn isAutomatable(self: VerificationMethod) bool {
        return switch (self) {
            .static_analysis, .automated_test, .generated_record => true,
            .manual_review, .usability_test, .audit => false,
        };
    }

    /// Plain-language explanation for reports read by people who did not write
    /// the requirement.
    pub fn explain(self: VerificationMethod) []const u8 {
        return switch (self) {
            .static_analysis => "A program checked the text or data and reported what it found.",
            .automated_test => "A test ran the system and checked the result.",
            .manual_review => "A person read the material and judged it against the rule.",
            .usability_test => "People tried real tasks with the material and the result was measured.",
            .audit => "An independent party examined the evidence.",
            .generated_record => "The system recorded this while it was running.",
        };
    }
};

pub const Severity = enum {
    /// Blocks a release.
    blocking,
    /// Must be fixed, but does not block today's release.
    major,
    /// Should be fixed.
    minor,
    /// Worth knowing; no action required.
    advisory,

    pub fn blocksRelease(self: Severity) bool {
        return self == .blocking;
    }
};

/// When a requirement applies. Requirements that apply to everything are rare
/// and usually wrong; most apply to one scope, one audience or one profile.
pub const Applicability = struct {
    scopes: []const Scope,
    /// Audience identifiers, empty meaning "every audience".
    audiences: []const []const u8 = &.{},
    /// Profile identifiers that switch this requirement on. Empty means the
    /// requirement is on in every profile that includes its standard.
    profiles: []const []const u8 = &.{},
    /// Human-readable statement of any further condition.
    condition: ?[]const u8 = null,

    pub fn appliesTo(self: Applicability, scope: Scope, profile: ?[]const u8) bool {
        var scope_ok = self.scopes.len == 0;
        for (self.scopes) |s| {
            if (s == scope) scope_ok = true;
        }
        if (!scope_ok) return false;
        if (self.profiles.len == 0) return true;
        const p = profile orelse return false;
        for (self.profiles) |candidate| {
            if (std.mem.eql(u8, candidate, p)) return true;
        }
        return false;
    }
};

pub const Requirement = struct {
    /// Stable identifier, for example `ISO-24495-1:R-FINDABLE`.
    id: []const u8,
    /// Identifier of the standard this comes from.
    standard_id: []const u8,
    /// Clause or section reference inside the standard.
    clause: ?[]const u8 = null,
    /// One sentence stating what must be true, written in plain language.
    statement: []const u8,
    applicability: Applicability,
    verification: VerificationMethod,
    severity: Severity = .major,
    /// Why this requirement exists, for the person who has to satisfy it.
    rationale: []const u8,
    /// Machine check that partially covers this requirement, when one exists.
    /// A check never *proves* conformance; it only finds problems.
    check_id: ?[]const u8 = null,
    /// What the automated check cannot establish. Stating this is what keeps
    /// the conformance claims honest.
    residual_judgement: ?[]const u8 = null,

    pub fn isFullyAutomatable(self: Requirement) bool {
        return self.verification.isAutomatable() and self.residual_judgement == null;
    }
};

test "applicability narrows by scope and profile" {
    const r: Requirement = .{
        .id = "TEST:R1",
        .standard_id = "TEST",
        .statement = "Every button label states the action it performs.",
        .applicability = .{ .scopes = &.{.interface_text}, .profiles = &.{"default"} },
        .verification = .static_analysis,
        .rationale = "A reader decides what to press by reading the label.",
    };
    try std.testing.expect(r.applicability.appliesTo(.interface_text, "default"));
    try std.testing.expect(!r.applicability.appliesTo(.documentation, "default"));
    try std.testing.expect(!r.applicability.appliesTo(.interface_text, "scientific"));
    try std.testing.expect(!r.applicability.appliesTo(.interface_text, null));
}

test "verification methods separate machine checks from judgement" {
    try std.testing.expect(VerificationMethod.static_analysis.isAutomatable());
    try std.testing.expect(!VerificationMethod.usability_test.isAutomatable());

    const partly: Requirement = .{
        .id = "TEST:R2",
        .standard_id = "TEST",
        .statement = "The reader can find the information they need.",
        .applicability = .{ .scopes = &.{.documentation} },
        .verification = .static_analysis,
        .rationale = "Findability is one of the four plain-language principles.",
        .check_id = "PL020",
        .residual_judgement = "A checker can find missing headings. Whether a reader can find what they need is established by testing with readers.",
    };
    try std.testing.expect(!partly.isFullyAutomatable());
}
