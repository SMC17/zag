//! The standards control plane.
//!
//! Standards are data, not comments. Each entry carries its edition, its
//! publication status and how the workbench enforces it. That is what lets the
//! system answer, for any artefact: which rules apply, which version of them,
//! what was checked, and what a person still has to judge.
//!
//! Two failure modes this design refuses:
//!   * Claiming conformance from a lint score.
//!   * Silently applying a withdrawn edition of a standard.

const std = @import("std");
const toml = @import("../interop/toml.zig");
const timeutil = @import("../core/time.zig");
const requirement = @import("requirement.zig");

pub const Requirement = requirement.Requirement;
pub const Scope = requirement.Scope;
pub const Severity = requirement.Severity;
pub const VerificationMethod = requirement.VerificationMethod;

pub const Error = error{
    UnknownStandard,
    DuplicateStandard,
    MalformedRegistry,
    OutOfMemory,
};

pub const Status = enum {
    /// In force.
    published,
    /// Circulated for comment; may change before publication.
    draft,
    /// No longer in force and not replaced.
    withdrawn,
    /// Replaced by a later edition.
    superseded,
    /// Not a standard: a framework, guideline or good-practice document.
    guidance,
    /// Industry specification maintained outside a standards body.
    industry_spec,

    pub fn isCitable(self: Status) bool {
        return switch (self) {
            .published, .guidance, .industry_spec => true,
            .draft, .withdrawn, .superseded => false,
        };
    }

    pub fn parse(text: []const u8) ?Status {
        return std.meta.stringToEnum(Status, text);
    }
};

pub const Enforcement = enum {
    /// Failing this blocks a release.
    mandatory,
    /// Applies only inside a named profile, and blocks there.
    required_profile,
    /// Reported, never blocking.
    recommended,
    /// Used only when producing an export in that format.
    export_only,
    /// Recorded for context; nothing is checked.
    informational,

    pub fn parse(text: []const u8) ?Enforcement {
        return std.meta.stringToEnum(Enforcement, text);
    }
};

pub const StandardRef = struct {
    /// Publishing body namespace: `iso`, `w3c`, `niso`, `nist`, `en`, `industry`.
    namespace: []const u8,
    /// Identifier as published, for example `ISO 24495-1`.
    identifier: []const u8,
    /// Edition or year, for example `2023`.
    edition: ?[]const u8 = null,
    title: []const u8,
    status: Status,
    enforcement: Enforcement,
    /// Date the edition took effect.
    valid_from: ?timeutil.Timestamp = null,
    /// Identifier of the entry this one replaces.
    supersedes: ?[]const u8 = null,
    /// Identifier of the entry that replaces this one.
    replaced_by: ?[]const u8 = null,
    /// Why the workbench applies it, in one sentence.
    purpose: []const u8 = "",
    /// Where the requirements derived from it live in this repository.
    requirements_file: ?[]const u8 = null,

    /// The key used to address this entry: identifier plus edition.
    pub fn key(self: StandardRef, buf: []u8) []const u8 {
        if (self.edition) |edition| {
            return std.fmt.bufPrint(buf, "{s}:{s}", .{ self.identifier, edition }) catch self.identifier;
        }
        return self.identifier;
    }

    pub fn citation(self: StandardRef, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.identifier);
        if (self.edition) |edition| try w.print(":{s}", .{edition});
        try w.print(" {s}", .{self.title});
    }
};

pub const IssueCode = enum {
    /// A withdrawn or superseded edition is being enforced.
    stale_edition_enforced,
    /// A draft is being enforced as though it were published.
    draft_enforced,
    /// `replaced_by` points at an identifier that is not registered.
    dangling_replacement,
    /// Two entries share an identifier and edition.
    duplicate_entry,
    /// The successor of a superseded entry is missing.
    missing_successor,
    /// A requirement names a standard that is not registered.
    unknown_standard_reference,

    pub fn text(self: IssueCode) []const u8 {
        return switch (self) {
            .stale_edition_enforced => "STD01",
            .draft_enforced => "STD02",
            .dangling_replacement => "STD03",
            .duplicate_entry => "STD04",
            .missing_successor => "STD05",
            .unknown_standard_reference => "STD06",
        };
    }
};

pub const Issue = struct {
    code: IssueCode,
    standard_id: []const u8,
    message: []const u8,
};

pub const Registry = struct {
    arena: std.mem.Allocator,
    standards: std.StringArrayHashMapUnmanaged(StandardRef) = .empty,
    requirements: std.StringArrayHashMapUnmanaged(Requirement) = .empty,

    pub fn init(arena: std.mem.Allocator) Registry {
        return .{ .arena = arena };
    }

    pub fn addStandard(self: *Registry, ref: StandardRef) Error!void {
        if (self.standards.contains(ref.identifier)) return error.DuplicateStandard;
        try self.standards.put(self.arena, ref.identifier, ref);
    }

    pub fn addRequirement(self: *Registry, r: Requirement) Error!void {
        try self.requirements.put(self.arena, r.id, r);
    }

    pub fn standard(self: Registry, identifier: []const u8) ?StandardRef {
        return self.standards.get(identifier);
    }

    pub fn count(self: Registry) usize {
        return self.standards.count();
    }

    /// Requirements that apply to a scope under a profile.
    pub fn applicable(self: Registry, scope: Scope, profile: ?[]const u8) !std.ArrayList(Requirement) {
        var out: std.ArrayList(Requirement) = .empty;
        var it = self.requirements.iterator();
        while (it.next()) |entry| {
            const r = entry.value_ptr.*;
            if (!r.applicability.appliesTo(scope, profile)) continue;
            const owner = self.standard(r.standard_id) orelse continue;
            if (owner.enforcement == .informational) continue;
            try out.append(self.arena, r);
        }
        return out;
    }

    /// Check the registry itself. This runs in the build, so an edition that
    /// has been withdrawn cannot quietly stay in force.
    pub fn validate(self: Registry) !std.ArrayList(Issue) {
        var issues: std.ArrayList(Issue) = .empty;
        var it = self.standards.iterator();
        while (it.next()) |entry| {
            const s = entry.value_ptr.*;
            const enforced = s.enforcement == .mandatory or s.enforcement == .required_profile;

            if (enforced and (s.status == .withdrawn or s.status == .superseded)) {
                try issues.append(self.arena, .{
                    .code = .stale_edition_enforced,
                    .standard_id = s.identifier,
                    .message = try std.fmt.allocPrint(self.arena, "{s} is {s} but is still enforced. Move enforcement to the edition in force, or record why the old edition still applies.", .{ s.identifier, @tagName(s.status) }),
                });
            }
            if (enforced and s.status == .draft) {
                try issues.append(self.arena, .{
                    .code = .draft_enforced,
                    .standard_id = s.identifier,
                    .message = try std.fmt.allocPrint(self.arena, "{s} is a draft and is enforced. A draft can change; enforce it as recommended until it is published.", .{s.identifier}),
                });
            }
            if (s.replaced_by) |successor| {
                if (!self.standards.contains(successor)) {
                    try issues.append(self.arena, .{
                        .code = .dangling_replacement,
                        .standard_id = s.identifier,
                        .message = try std.fmt.allocPrint(self.arena, "{s} says it is replaced by {s}, which is not in the registry.", .{ s.identifier, successor }),
                    });
                }
            } else if (s.status == .superseded) {
                try issues.append(self.arena, .{
                    .code = .missing_successor,
                    .standard_id = s.identifier,
                    .message = try std.fmt.allocPrint(self.arena, "{s} is marked superseded but does not name the edition that replaces it.", .{s.identifier}),
                });
            }
        }

        var req_it = self.requirements.iterator();
        while (req_it.next()) |entry| {
            const r = entry.value_ptr.*;
            if (!self.standards.contains(r.standard_id)) {
                try issues.append(self.arena, .{
                    .code = .unknown_standard_reference,
                    .standard_id = r.standard_id,
                    .message = try std.fmt.allocPrint(self.arena, "Requirement {s} comes from {s}, which is not in the registry.", .{ r.id, r.standard_id }),
                });
            }
        }
        return issues;
    }

    /// Load standards from one TOML registry file.
    pub fn loadStandards(self: *Registry, source: []const u8) !usize {
        const doc = try toml.parse(self.arena, source);
        const list = (doc.get("standard") orelse return 0).asArray() orelse return error.MalformedRegistry;
        var added: usize = 0;
        for (list) |entry| {
            const identifier = entry.stringAt("identifier") orelse return error.MalformedRegistry;
            const status_text = entry.stringAt("status") orelse return error.MalformedRegistry;
            const enforcement_text = entry.stringAt("enforcement") orelse return error.MalformedRegistry;
            const ref: StandardRef = .{
                .namespace = entry.stringAt("namespace") orelse "iso",
                .identifier = identifier,
                .edition = entry.stringAt("edition"),
                .title = entry.stringAt("title") orelse return error.MalformedRegistry,
                .status = Status.parse(status_text) orelse return error.MalformedRegistry,
                .enforcement = Enforcement.parse(enforcement_text) orelse return error.MalformedRegistry,
                .valid_from = if (entry.stringAt("valid_from")) |v|
                    timeutil.Timestamp.parseIso(v) catch return error.MalformedRegistry
                else
                    null,
                .supersedes = entry.stringAt("supersedes"),
                .replaced_by = entry.stringAt("replaced_by"),
                .purpose = entry.stringAt("purpose") orelse "",
                .requirements_file = entry.stringAt("requirements_file"),
            };
            try self.addStandard(ref);
            added += 1;
        }
        return added;
    }

    /// Load requirements from a TOML file.
    pub fn loadRequirements(self: *Registry, source: []const u8) !usize {
        const doc = try toml.parse(self.arena, source);
        const list = (doc.get("requirement") orelse return 0).asArray() orelse return error.MalformedRegistry;
        var added: usize = 0;
        for (list) |entry| {
            var scopes: std.ArrayList(Scope) = .empty;
            if (entry.getPath("scopes")) |value| {
                const items = value.asArray() orelse return error.MalformedRegistry;
                for (items) |item| {
                    const name = item.asString() orelse return error.MalformedRegistry;
                    try scopes.append(self.arena, std.meta.stringToEnum(Scope, name) orelse return error.MalformedRegistry);
                }
            }
            var profiles: std.ArrayList([]const u8) = .empty;
            if (entry.getPath("profiles")) |value| {
                const items = value.asArray() orelse return error.MalformedRegistry;
                for (items) |item| try profiles.append(self.arena, item.asString() orelse return error.MalformedRegistry);
            }
            const method_text = entry.stringAt("verification") orelse return error.MalformedRegistry;
            const severity_text = entry.stringAt("severity") orelse "major";
            try self.addRequirement(.{
                .id = entry.stringAt("id") orelse return error.MalformedRegistry,
                .standard_id = entry.stringAt("standard") orelse return error.MalformedRegistry,
                .clause = entry.stringAt("clause"),
                .statement = entry.stringAt("statement") orelse return error.MalformedRegistry,
                .applicability = .{
                    .scopes = try scopes.toOwnedSlice(self.arena),
                    .profiles = try profiles.toOwnedSlice(self.arena),
                    .condition = entry.stringAt("condition"),
                },
                .verification = std.meta.stringToEnum(VerificationMethod, method_text) orelse return error.MalformedRegistry,
                .severity = std.meta.stringToEnum(Severity, severity_text) orelse return error.MalformedRegistry,
                .rationale = entry.stringAt("rationale") orelse "",
                .check_id = entry.stringAt("check"),
                .residual_judgement = entry.stringAt("residual_judgement"),
            });
            added += 1;
        }
        return added;
    }
};

fn hasIssue(issues: []const Issue, code: IssueCode) bool {
    for (issues) |i| {
        if (i.code == code) return true;
    }
    return false;
}

test "registry loads standards from toml" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var registry = Registry.init(arena_state.allocator());

    const added = try registry.loadStandards(
        \\[[standard]]
        \\namespace = "iso"
        \\identifier = "ISO 24495-1"
        \\edition = "2023"
        \\title = "Plain language - Part 1: Governing principles and guidelines"
        \\status = "published"
        \\enforcement = "mandatory"
        \\valid_from = 2023-07-01T00:00:00Z
        \\purpose = "Product text must serve the reader who has to act on it."
        \\
        \\[[standard]]
        \\namespace = "iso"
        \\identifier = "ISO/IEC 40500"
        \\edition = "2012"
        \\title = "W3C Web Content Accessibility Guidelines (WCAG) 2.0"
        \\status = "superseded"
        \\enforcement = "informational"
        \\replaced_by = "ISO/IEC 40500:2025"
    );
    try std.testing.expectEqual(@as(usize, 2), added);
    try std.testing.expectEqualStrings("2023", registry.standard("ISO 24495-1").?.edition.?);
    try std.testing.expect(registry.standard("ISO/IEC 40500").?.status == .superseded);

    const issues = (try registry.validate()).items;
    // The superseded entry is informational, so it is not "enforced", but its
    // successor is missing from this fragment.
    try std.testing.expect(hasIssue(issues, .dangling_replacement));
    try std.testing.expect(!hasIssue(issues, .stale_edition_enforced));
}

test "registry rejects an invalid effective date" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var registry = Registry.init(arena_state.allocator());

    try std.testing.expectError(error.MalformedRegistry, registry.loadStandards(
        \\[[standard]]
        \\identifier = "ISO 24495-1"
        \\title = "Plain language"
        \\status = "published"
        \\enforcement = "mandatory"
        \\valid_from = "not a date"
    ));
}

test "registry refuses to enforce withdrawn or draft editions quietly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var registry = Registry.init(arena_state.allocator());

    try registry.addStandard(.{
        .namespace = "iso",
        .identifier = "ISO/IEC 40500:2012",
        .title = "WCAG 2.0",
        .status = .withdrawn,
        .enforcement = .mandatory,
    });
    try registry.addStandard(.{
        .namespace = "iso",
        .identifier = "ISO 24495-4",
        .title = "Plain language - Part 4: Organizational implementation",
        .status = .draft,
        .enforcement = .required_profile,
    });

    const issues = (try registry.validate()).items;
    try std.testing.expect(hasIssue(issues, .stale_edition_enforced));
    try std.testing.expect(hasIssue(issues, .draft_enforced));
}

test "requirements load and filter by scope and profile" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var registry = Registry.init(arena_state.allocator());

    _ = try registry.loadStandards(
        \\[[standard]]
        \\identifier = "ISO 24495-1"
        \\edition = "2023"
        \\title = "Plain language"
        \\status = "published"
        \\enforcement = "mandatory"
        \\
        \\[[standard]]
        \\identifier = "ASD-STE100"
        \\title = "Simplified Technical English"
        \\status = "industry_spec"
        \\enforcement = "required_profile"
    );
    _ = try registry.loadRequirements(
        \\[[requirement]]
        \\id = "ISO-24495-1:R-USABLE"
        \\standard = "ISO 24495-1"
        \\clause = "6.5"
        \\statement = "The reader can use the information the first time they read it."
        \\scopes = ["interface_text", "documentation"]
        \\verification = "usability_test"
        \\severity = "blocking"
        \\rationale = "Plain language is judged by whether the reader can act, not by word length."
        \\residual_judgement = "Only testing with readers can establish this."
        \\
        \\[[requirement]]
        \\id = "STE100:R-APPROVED-VERB"
        \\standard = "ASD-STE100"
        \\statement = "Procedures use only approved verbs."
        \\scopes = ["documentation"]
        \\profiles = ["controlled-english"]
        \\verification = "static_analysis"
        \\severity = "major"
        \\rationale = "One verb, one meaning, so that a procedure reads the same way to every reader."
        \\check = "STE103"
    );

    const default_docs = try registry.applicable(.documentation, "default");
    try std.testing.expectEqual(@as(usize, 1), default_docs.items.len);
    try std.testing.expectEqualStrings("ISO-24495-1:R-USABLE", default_docs.items[0].id);

    const controlled = try registry.applicable(.documentation, "controlled-english");
    try std.testing.expectEqual(@as(usize, 2), controlled.items.len);

    const ui = try registry.applicable(.user_interface, "default");
    try std.testing.expectEqual(@as(usize, 0), ui.items.len);

    const issues = (try registry.validate()).items;
    try std.testing.expectEqual(@as(usize, 0), issues.len);
}
