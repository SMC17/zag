//! Conformance profiles.
//!
//! Not every rule applies to every piece of work. A benchmark report and a
//! licence agreement and an error message are all "text", and applying one set
//! of rules to all three produces nonsense: controlled English would flatten a
//! scientific argument, and scientific hedging would ruin an error message.
//!
//! A profile names which standards are in force for a kind of work, which
//! language rules apply, and which audience the text is written for.

const std = @import("std");
const requirement = @import("requirement.zig");
const audience_mod = @import("../language/audience.zig");

pub const Scope = requirement.Scope;

/// Which language rule set applies to the text.
pub const LanguageProfile = enum {
    /// ISO 24495-1 only.
    plain,
    /// ISO 24495-1 plus ASD-STE100.
    controlled_english,
    /// ISO 24495-1 plus the Easy-to-Read guidance.
    easy_read,
    /// ISO 24495-1 plus part 2, for legal communication.
    legal,
    /// ISO 24495-1 plus part 3, for science writing.
    scientific,
};

pub const AccessibilityLevel = enum { a, aa, aaa };

pub const Profile = struct {
    id: []const u8,
    name: []const u8,
    /// One sentence saying who uses this profile and for what.
    description: []const u8,
    /// Standards in force, by identifier.
    standards: []const []const u8,
    language: LanguageProfile,
    /// Default audience for text checked under this profile.
    audience: audience_mod.Audience,
    accessibility: AccessibilityLevel = .aa,
    /// Scopes this profile governs. Empty means every scope.
    scopes: []const Scope = &.{},
    /// Requirements switched on only in this profile.
    extra_requirements: []const []const u8 = &.{},
    /// Requirements this profile deliberately does not apply, with the reason.
    exclusions: []const Exclusion = &.{},

    pub const Exclusion = struct {
        requirement_id: []const u8,
        reason: []const u8,
    };

    pub fn appliesTo(self: Profile, scope: Scope) bool {
        if (self.scopes.len == 0) return true;
        for (self.scopes) |s| {
            if (s == scope) return true;
        }
        return false;
    }

    pub fn excludes(self: Profile, requirement_id: []const u8) ?[]const u8 {
        for (self.exclusions) |exclusion| {
            if (std.mem.eql(u8, exclusion.requirement_id, requirement_id)) return exclusion.reason;
        }
        return null;
    }

    pub fn includesStandard(self: Profile, identifier: []const u8) bool {
        for (self.standards) |s| {
            if (std.mem.eql(u8, s, identifier)) return true;
        }
        return false;
    }
};

pub const default: Profile = .{
    .id = "default",
    .name = "Default",
    .description = "Applies to the product's own interface text, documentation and interfaces.",
    .standards = &.{
        "ISO 24495-1",
        "WCAG 2.2",
        "EN 301 549",
        "ISO 704",
        "ISO 25964",
        "ISO/IEC 11179",
        "ISO 8601",
        "ISO 3166",
        "ISO 4217",
        "UCUM",
        "JSON Schema",
        "OpenAPI",
        "ISO 15489",
        "ISO/IEC 42001",
        "ISO/IEC 23894",
        "ISO/IEC 12792",
        "ISO/IEC 25059",
        "ISO 24896",
    },
    .language = .plain,
    .audience = audience_mod.developer,
    .accessibility = .aa,
};

pub const enterprise: Profile = .{
    .id = "enterprise",
    .name = "Enterprise",
    .description = "Adds the organisational management and records rules an organisation needs to answer for its use of the product.",
    .standards = &.{
        "ISO 24495-1",
        "ISO 24495-4",
        "WCAG 2.2",
        "EN 301 549",
        "ISO/IEC 42001",
        "ISO/IEC 42005",
        "ISO/IEC 23894",
        "ISO/IEC 38507",
        "ISO/IEC 5338",
        "ISO 30401",
        "ISO 15489",
        "ISO 10013",
        "ISO 9001",
        "NIST AI RMF",
        "ISO 8000",
        "ISO/IEC 25012",
        "ISO/IEC 5259",
    },
    .language = .plain,
    .audience = audience_mod.auditor,
    .accessibility = .aa,
    .extra_requirements = &.{ "ISO-42001:R-EVIDENCE", "ISO-15489:R-RETENTION" },
};

pub const scientific: Profile = .{
    .id = "scientific",
    .name = "Scientific and benchmark reporting",
    .description = "Applies to benchmark results, evaluations and any claim a reader is expected to reproduce.",
    .standards = &.{ "ISO 24495-1", "ISO 24495-3", "ISO/IEC 25059", "ISO 24896", "UCUM", "ISO 8601", "FAIR" },
    .language = .scientific,
    .audience = audience_mod.scientific_reviewer,
    .scopes = &.{ .scientific_text, .reporting },
    .extra_requirements = &.{ "ISO-24495-3:R-METHOD", "ISO-24495-3:R-UNCERTAINTY" },
    .exclusions = &.{.{
        .requirement_id = "STE100:R-APPROVED-VERB",
        .reason = "Controlled English removes the precision a scientific argument needs. Plain language still applies.",
    }},
};

pub const legal: Profile = .{
    .id = "legal",
    .name = "Legal communication",
    .description = "Applies to licences, terms and any text that states an obligation.",
    .standards = &.{ "ISO 24495-1", "ISO 24495-2", "WCAG 2.2" },
    .language = .legal,
    .audience = audience_mod.legal_reviewer,
    .scopes = &.{.legal_text},
    .extra_requirements = &.{"ISO-24495-2:R-OBLIGATION-CLEAR"},
    .exclusions = &.{.{
        .requirement_id = "PL006",
        .reason = "Some legal terms are nouns formed from verbs and cannot be replaced without changing their meaning.",
    }},
};

pub const controlled_english: Profile = .{
    .id = "controlled-english",
    .name = "Controlled English",
    .description = "Applies to procedures, diagnostics and support material that must translate cleanly.",
    .standards = &.{ "ISO 24495-1", "ASD-STE100" },
    .language = .controlled_english,
    .audience = audience_mod.new_user,
    .scopes = &.{ .documentation, .interface_text },
    .extra_requirements = &.{ "STE100:R-APPROVED-VERB", "STE100:R-ONE-INSTRUCTION" },
};

pub const easy_read: Profile = .{
    .id = "easy-read",
    .name = "Easy to read",
    .description = "Applies to material written for people who need short sentences, common words and one idea at a time.",
    .standards = &.{ "ISO 24495-1", "Easy-to-Read", "WCAG 2.2" },
    .language = .easy_read,
    .audience = audience_mod.easy_read_reader,
    .accessibility = .aaa,
    .scopes = &.{ .documentation, .interface_text },
    .extra_requirements = &.{ "ER:R-SHORT-SENTENCE", "ER:R-SUPPORTING-IMAGE" },
};

pub const registry = [_]Profile{ default, enterprise, scientific, legal, controlled_english, easy_read };

pub fn byId(id: []const u8) ?Profile {
    for (registry) |profile| {
        if (std.mem.eql(u8, profile.id, id)) return profile;
    }
    return null;
}

/// The profile that governs a scope, when only one does. Where several could
/// apply, the caller chooses: this function does not guess.
pub fn forScope(arena: std.mem.Allocator, scope: Scope) !std.ArrayList(Profile) {
    var out: std.ArrayList(Profile) = .empty;
    for (registry) |profile| {
        if (profile.scopes.len == 0) continue;
        if (profile.appliesTo(scope)) try out.append(arena, profile);
    }
    return out;
}

const testing = std.testing;

test "profiles are addressable and describe themselves" {
    try testing.expectEqualStrings("Default", byId("default").?.name);
    try testing.expect(byId("nonexistent") == null);
    for (registry) |profile| {
        try testing.expect(profile.description.len > 0);
        try testing.expect(profile.standards.len > 0);
    }
}

test "a profile can exclude a rule, but must say why" {
    const reason = scientific.excludes("STE100:R-APPROVED-VERB").?;
    try testing.expect(std.mem.indexOf(u8, reason, "precision") != null);
    try testing.expect(scientific.excludes("PL002") == null);

    for (registry) |profile| {
        for (profile.exclusions) |exclusion| {
            try testing.expect(exclusion.reason.len > 20);
        }
    }
}

test "scoped profiles apply only where they belong" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(legal.appliesTo(.legal_text));
    try testing.expect(!legal.appliesTo(.user_interface));
    // The default profile has no scope list, so it applies everywhere.
    try testing.expect(default.appliesTo(.legal_text));

    const for_legal = try forScope(arena, .legal_text);
    try testing.expectEqual(@as(usize, 1), for_legal.items.len);
    try testing.expectEqualStrings("legal", for_legal.items[0].id);
}

test "each profile chooses a language rule set and an audience that match" {
    try testing.expectEqual(LanguageProfile.easy_read, easy_read.language);
    try testing.expectEqualStrings("easy-read", easy_read.audience.id);
    try testing.expectEqual(@as(usize, 15), easy_read.audience.max_sentence_words);

    try testing.expectEqual(LanguageProfile.scientific, scientific.language);
    try testing.expectEqualStrings("scientific-reviewer", scientific.audience.id);

    // The enterprise profile brings in the organisational standards.
    try testing.expect(enterprise.includesStandard("ISO/IEC 42001"));
    try testing.expect(enterprise.includesStandard("ISO 30401"));
    try testing.expect(!default.includesStandard("ISO 30401"));
}
