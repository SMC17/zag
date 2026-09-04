//! Concept systems, in the sense of ISO 704.
//!
//! A concept is a unit of knowledge; a term is a designation for it. Keeping
//! the two apart is what lets the workbench answer "what did the user mean?"
//! without embedding-based guessing: user language is resolved to a concept,
//! and every subsystem — search, documentation, agent context, the plain
//! language checker — reasons about the concept.
//!
//! The system also *validates itself*. A concept without a definition, a
//! circular definition, or a hierarchy loop is a defect in the knowledge base
//! and is reported like any other defect.

const std = @import("std");
const language = @import("../interop/language.zig");

pub const Error = error{ DuplicateConcept, UnknownConcept, OutOfMemory };

/// Status of a designation, following ISO 704 and ISO 25964 vocabulary.
pub const TermStatus = enum {
    /// The term to use. One per concept per language.
    preferred,
    /// Acceptable synonym.
    admitted,
    /// Must not be used in new text; kept so that old text still resolves.
    deprecated,
};

pub const Designation = struct {
    text: []const u8,
    status: TermStatus = .admitted,
    note: ?[]const u8 = null,
};

/// Concept relations. Generic and partitive relations are distinguished
/// because ISO 704 treats them differently, and because "a session is part of
/// a workspace" and "a session is a kind of execution context" answer different
/// questions for an agent.
pub const RelationKind = enum {
    generic, // broader: is a kind of
    partitive, // broader: is part of
    associative, // related, non-hierarchical
};

pub const Relation = struct {
    kind: RelationKind,
    target: []const u8,
    note: ?[]const u8 = null,
};

pub const Concept = struct {
    /// Stable local identifier. Used in IRIs, so it must be URL-safe.
    id: []const u8,
    /// The term to use for this concept in running text.
    preferred: []const u8,
    /// One sentence, substitutable for the term, stating the superordinate
    /// concept and the delimiting characteristics.
    definition: []const u8,
    designations: []const Designation = &.{},
    /// Broader and associated concepts, by identifier.
    relations: []const Relation = &.{},
    subject_field: []const u8 = "software engineering",
    source: ?[]const u8 = null,
    note: ?[]const u8 = null,
    examples: []const []const u8 = &.{},
    lang: language.Tag = language.Tag.english,
    /// A top concept has no broader concept by design, not by omission.
    top_concept: bool = false,

    pub fn broaderIds(self: Concept, buffer: *std.ArrayList([]const u8), arena: std.mem.Allocator) !void {
        for (self.relations) |r| {
            if (r.kind != .associative) try buffer.append(arena, r.target);
        }
    }
};

pub const Resolution = struct {
    concept: Concept,
    matched: []const u8,
    status: TermStatus,
};

/// Machine-checkable defects in a concept system.
pub const FindingCode = enum {
    /// The concept has no definition.
    missing_definition,
    /// The definition repeats the term it defines.
    circular_definition,
    /// The definition only says what the concept is not.
    negative_definition,
    /// The definition opens with filler such as "is defined as".
    non_substitutable_definition,
    /// A broader or related concept identifier does not exist.
    dangling_relation,
    /// Following broader relations returns to the starting concept.
    hierarchy_cycle,
    /// The same designation is preferred for two concepts.
    homograph_conflict,
    /// A term is deprecated in one concept and preferred in another.
    deprecated_term_reused,
    /// The concept is neither a top concept nor placed under one.
    orphan_concept,
    /// The preferred term is not in the expected form for an index term.
    malformed_term,

    pub fn text(self: FindingCode) []const u8 {
        return switch (self) {
            .missing_definition => "TERM001",
            .circular_definition => "TERM002",
            .negative_definition => "TERM003",
            .non_substitutable_definition => "TERM004",
            .dangling_relation => "TERM005",
            .hierarchy_cycle => "TERM006",
            .homograph_conflict => "TERM007",
            .deprecated_term_reused => "TERM008",
            .orphan_concept => "TERM009",
            .malformed_term => "TERM010",
        };
    }
};

pub const Finding = struct {
    code: FindingCode,
    concept_id: []const u8,
    /// Plain-language explanation, written for the person who must fix it.
    message: []const u8,
};

pub const ConceptSystem = struct {
    arena: std.mem.Allocator,
    concepts: std.StringArrayHashMapUnmanaged(Concept) = .empty,

    pub fn init(arena: std.mem.Allocator) ConceptSystem {
        return .{ .arena = arena };
    }

    pub fn add(self: *ConceptSystem, concept: Concept) Error!void {
        if (self.concepts.contains(concept.id)) return error.DuplicateConcept;
        try self.concepts.put(self.arena, concept.id, concept);
    }

    pub fn get(self: ConceptSystem, id: []const u8) ?Concept {
        return self.concepts.get(id);
    }

    pub fn count(self: ConceptSystem) usize {
        return self.concepts.count();
    }

    /// Resolve user language to a concept. Matching is case-insensitive and
    /// ignores surrounding whitespace, because that is how people type.
    pub fn resolve(self: ConceptSystem, term: []const u8) ?Resolution {
        const needle = std.mem.trim(u8, term, " \t\n");
        var it = self.concepts.iterator();
        // Preferred terms win over synonyms, so scan in two passes.
        while (it.next()) |entry| {
            const c = entry.value_ptr.*;
            if (std.ascii.eqlIgnoreCase(c.preferred, needle)) {
                return .{ .concept = c, .matched = c.preferred, .status = .preferred };
            }
        }
        it = self.concepts.iterator();
        while (it.next()) |entry| {
            const c = entry.value_ptr.*;
            for (c.designations) |d| {
                if (std.ascii.eqlIgnoreCase(d.text, needle)) {
                    return .{ .concept = c, .matched = d.text, .status = d.status };
                }
            }
        }
        return null;
    }

    /// Concepts that name this one as broader.
    pub fn narrower(self: ConceptSystem, id: []const u8) !std.ArrayList([]const u8) {
        var out: std.ArrayList([]const u8) = .empty;
        var it = self.concepts.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.relations) |r| {
                if (r.kind == .associative) continue;
                if (std.mem.eql(u8, r.target, id)) try out.append(self.arena, entry.key_ptr.*);
            }
        }
        return out;
    }

    /// The chain of broader concepts, closest first. Stops at a top concept or
    /// at the first repetition, so a cyclic system still terminates.
    pub fn broaderPath(self: ConceptSystem, id: []const u8) !std.ArrayList([]const u8) {
        var out: std.ArrayList([]const u8) = .empty;
        var current = id;
        var guard: usize = 0;
        while (guard < 64) : (guard += 1) {
            const concept = self.get(current) orelse break;
            var next: ?[]const u8 = null;
            for (concept.relations) |r| {
                if (r.kind == .generic or r.kind == .partitive) {
                    next = r.target;
                    break;
                }
            }
            const parent = next orelse break;
            for (out.items) |seen| {
                if (std.mem.eql(u8, seen, parent)) return out;
            }
            if (std.mem.eql(u8, parent, id)) return out;
            try out.append(self.arena, parent);
            current = parent;
        }
        return out;
    }

    /// Run every ISO 704 and ISO 25964 check the system can automate.
    pub fn validate(self: ConceptSystem) !std.ArrayList(Finding) {
        var findings: std.ArrayList(Finding) = .empty;
        var it = self.concepts.iterator();
        while (it.next()) |entry| {
            const c = entry.value_ptr.*;
            try self.checkDefinition(c, &findings);
            try self.checkTermForm(c, &findings);
            try self.checkRelations(c, &findings);
            try self.checkPlacement(c, &findings);
        }
        try self.checkDesignationConflicts(&findings);
        return findings;
    }

    fn checkDefinition(self: ConceptSystem, c: Concept, findings: *std.ArrayList(Finding)) !void {
        const d = std.mem.trim(u8, c.definition, " \t\n");
        if (d.len == 0) {
            try findings.append(self.arena, .{
                .code = .missing_definition,
                .concept_id = c.id,
                .message = try std.fmt.allocPrint(self.arena, "The concept \"{s}\" has no definition. Write one sentence that says what it is and what makes it different from the concept above it.", .{c.preferred}),
            });
            return;
        }
        if (containsWordIgnoreCase(d, c.preferred)) {
            try findings.append(self.arena, .{
                .code = .circular_definition,
                .concept_id = c.id,
                .message = try std.fmt.allocPrint(self.arena, "The definition of \"{s}\" uses the term it defines. Replace the repeated term with the characteristics that identify the concept.", .{c.preferred}),
            });
        }
        const lower_prefixes = [_][]const u8{ "is defined as", "refers to", "is a term for", "means the" };
        for (lower_prefixes) |prefix| {
            if (startsWithIgnoreCase(d, prefix)) {
                try findings.append(self.arena, .{
                    .code = .non_substitutable_definition,
                    .concept_id = c.id,
                    .message = try std.fmt.allocPrint(self.arena, "The definition of \"{s}\" opens with \"{s}\". Start with the superordinate concept so the definition can replace the term in a sentence.", .{ c.preferred, prefix }),
                });
                break;
            }
        }
        if (startsWithIgnoreCase(d, "not ") or startsWithIgnoreCase(d, "anything that is not")) {
            try findings.append(self.arena, .{
                .code = .negative_definition,
                .concept_id = c.id,
                .message = try std.fmt.allocPrint(self.arena, "The definition of \"{s}\" only says what the concept is not. State what it is.", .{c.preferred}),
            });
        }
    }

    fn checkTermForm(self: ConceptSystem, c: Concept, findings: *std.ArrayList(Finding)) !void {
        const t = c.preferred;
        if (t.len == 0) {
            try findings.append(self.arena, .{
                .code = .malformed_term,
                .concept_id = c.id,
                .message = "The concept has no preferred term.",
            });
            return;
        }
        const articles = [_][]const u8{ "a ", "an ", "the " };
        for (articles) |article| {
            if (startsWithIgnoreCase(t, article)) {
                try findings.append(self.arena, .{
                    .code = .malformed_term,
                    .concept_id = c.id,
                    .message = try std.fmt.allocPrint(self.arena, "The preferred term \"{s}\" starts with an article. Index terms are written without \"a\", \"an\" or \"the\".", .{t}),
                });
            }
        }
        if (std.mem.endsWith(u8, t, ".")) {
            try findings.append(self.arena, .{
                .code = .malformed_term,
                .concept_id = c.id,
                .message = try std.fmt.allocPrint(self.arena, "The preferred term \"{s}\" ends with a full stop. A term is not a sentence.", .{t}),
            });
        }
    }

    fn checkRelations(self: ConceptSystem, c: Concept, findings: *std.ArrayList(Finding)) !void {
        for (c.relations) |r| {
            if (self.get(r.target) == null) {
                try findings.append(self.arena, .{
                    .code = .dangling_relation,
                    .concept_id = c.id,
                    .message = try std.fmt.allocPrint(self.arena, "The concept \"{s}\" points to \"{s}\", which is not in the concept system. Add that concept or remove the relation.", .{ c.preferred, r.target }),
                });
            }
        }
        // Walk broader relations; a return to the start is a cycle.
        var visited: std.StringArrayHashMapUnmanaged(void) = .empty;
        var stack: std.ArrayList([]const u8) = .empty;
        try stack.append(self.arena, c.id);
        while (stack.pop()) |current| {
            const concept = self.get(current) orelse continue;
            for (concept.relations) |r| {
                if (r.kind == .associative) continue;
                if (std.mem.eql(u8, r.target, c.id)) {
                    try findings.append(self.arena, .{
                        .code = .hierarchy_cycle,
                        .concept_id = c.id,
                        .message = try std.fmt.allocPrint(self.arena, "The broader-concept chain from \"{s}\" returns to itself. A concept cannot be broader than itself.", .{c.preferred}),
                    });
                    return;
                }
                if (visited.contains(r.target)) continue;
                try visited.put(self.arena, r.target, {});
                try stack.append(self.arena, r.target);
            }
        }
    }

    fn checkPlacement(self: ConceptSystem, c: Concept, findings: *std.ArrayList(Finding)) !void {
        if (c.top_concept) return;
        for (c.relations) |r| {
            if (r.kind != .associative) return;
        }
        try findings.append(self.arena, .{
            .code = .orphan_concept,
            .concept_id = c.id,
            .message = try std.fmt.allocPrint(self.arena, "The concept \"{s}\" has no broader concept and is not marked as a top concept. Place it in the hierarchy or mark it as a top concept on purpose.", .{c.preferred}),
        });
    }

    fn checkDesignationConflicts(self: ConceptSystem, findings: *std.ArrayList(Finding)) !void {
        var preferred_index: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        var it = self.concepts.iterator();
        while (it.next()) |entry| {
            const c = entry.value_ptr.*;
            const key = try std.ascii.allocLowerString(self.arena, c.preferred);
            if (preferred_index.get(key)) |other| {
                try findings.append(self.arena, .{
                    .code = .homograph_conflict,
                    .concept_id = c.id,
                    .message = try std.fmt.allocPrint(self.arena, "\"{s}\" is the preferred term for both \"{s}\" and \"{s}\". Give one of them a qualifier so readers can tell them apart.", .{ c.preferred, other, c.id }),
                });
            } else {
                try preferred_index.put(self.arena, key, c.id);
            }
        }

        it = self.concepts.iterator();
        while (it.next()) |entry| {
            const c = entry.value_ptr.*;
            for (c.designations) |d| {
                if (d.status != .deprecated) continue;
                const key = try std.ascii.allocLowerString(self.arena, d.text);
                if (preferred_index.get(key)) |owner| {
                    try findings.append(self.arena, .{
                        .code = .deprecated_term_reused,
                        .concept_id = c.id,
                        .message = try std.fmt.allocPrint(self.arena, "\"{s}\" is deprecated for \"{s}\" but is the preferred term for \"{s}\". One term cannot be both.", .{ d.text, c.preferred, owner }),
                    });
                }
            }
        }
    }
};

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

/// Whole-word, case-insensitive containment. Used so that "session" does not
/// match inside "sessions_table".
pub fn containsWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) continue;
        const before_ok = i == 0 or !isWordChar(haystack[i - 1]);
        const after = i + needle.len;
        // Allow a trailing plural "s" so "session" matches "sessions".
        const after_ok = after >= haystack.len or !isWordChar(haystack[after]) or
            (haystack[after] == 's' and (after + 1 >= haystack.len or !isWordChar(haystack[after + 1])));
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn findingWith(findings: []const Finding, code: FindingCode) ?Finding {
    for (findings) |f| {
        if (f.code == code) return f;
    }
    return null;
}

test "resolves preferred, admitted and deprecated terms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var system = ConceptSystem.init(arena_state.allocator());

    try system.add(.{
        .id = "development-environment",
        .preferred = "development environment",
        .definition = "set of tools and resources that a person or agent uses to change software",
        .top_concept = true,
    });
    try system.add(.{
        .id = "workspace",
        .preferred = "workspace",
        .definition = "development environment that keeps sessions, files, agents and their state together over time",
        .designations = &.{
            .{ .text = "bench", .status = .admitted },
            .{ .text = "project shell", .status = .deprecated },
        },
        .relations = &.{.{ .kind = .generic, .target = "development-environment" }},
    });

    const direct = system.resolve("Workspace").?;
    try std.testing.expectEqual(TermStatus.preferred, direct.status);
    const synonym = system.resolve("bench").?;
    try std.testing.expectEqualStrings("workspace", synonym.concept.id);
    const old = system.resolve("project shell").?;
    try std.testing.expectEqual(TermStatus.deprecated, old.status);
    try std.testing.expect(system.resolve("wormhole") == null);

    const findings = try system.validate();
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "reports circular, negative and non-substitutable definitions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var system = ConceptSystem.init(arena_state.allocator());

    try system.add(.{
        .id = "block",
        .preferred = "block",
        .definition = "a block of terminal output",
        .top_concept = true,
    });
    try system.add(.{
        .id = "agent",
        .preferred = "agent",
        .definition = "is defined as a piece of software that acts",
        .top_concept = true,
    });
    try system.add(.{
        .id = "surface",
        .preferred = "the surface",
        .definition = "not a window",
        .top_concept = true,
    });

    const findings = (try system.validate()).items;
    try std.testing.expect(findingWith(findings, .circular_definition) != null);
    try std.testing.expect(findingWith(findings, .non_substitutable_definition) != null);
    try std.testing.expect(findingWith(findings, .negative_definition) != null);
    try std.testing.expect(findingWith(findings, .malformed_term) != null);
}

test "reports dangling relations, cycles and orphans" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var system = ConceptSystem.init(arena_state.allocator());

    try system.add(.{
        .id = "a",
        .preferred = "alpha",
        .definition = "first thing in an ordered pair of test concepts",
        .relations = &.{.{ .kind = .generic, .target = "b" }},
    });
    try system.add(.{
        .id = "b",
        .preferred = "beta",
        .definition = "second thing in an ordered pair of test concepts",
        .relations = &.{.{ .kind = .generic, .target = "a" }},
    });
    try system.add(.{
        .id = "c",
        .preferred = "gamma",
        .definition = "concept that points nowhere real",
        .relations = &.{.{ .kind = .generic, .target = "missing" }},
    });
    try system.add(.{
        .id = "d",
        .preferred = "delta",
        .definition = "concept with no place in the hierarchy",
    });

    const findings = (try system.validate()).items;
    try std.testing.expect(findingWith(findings, .hierarchy_cycle) != null);
    try std.testing.expect(findingWith(findings, .dangling_relation) != null);
    const orphan = findingWith(findings, .orphan_concept).?;
    try std.testing.expectEqualStrings("d", orphan.concept_id);
}

test "detects homographs and reused deprecated terms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var system = ConceptSystem.init(arena_state.allocator());

    try system.add(.{ .id = "session-1", .preferred = "session", .definition = "run of a shell inside a workspace", .top_concept = true });
    try system.add(.{ .id = "session-2", .preferred = "Session", .definition = "period during which a person uses the product", .top_concept = true });
    try system.add(.{
        .id = "tab",
        .preferred = "tab",
        .definition = "workspace surface that shows one session at a time",
        .designations = &.{.{ .text = "session", .status = .deprecated }},
        .top_concept = true,
    });

    const findings = (try system.validate()).items;
    try std.testing.expect(findingWith(findings, .homograph_conflict) != null);
    try std.testing.expect(findingWith(findings, .deprecated_term_reused) != null);
}

test "navigates the hierarchy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var system = ConceptSystem.init(arena_state.allocator());

    try system.add(.{ .id = "top", .preferred = "development environment", .definition = "tools used to change software", .top_concept = true });
    try system.add(.{ .id = "mid", .preferred = "workspace", .definition = "development environment with durable state", .relations = &.{.{ .kind = .generic, .target = "top" }} });
    try system.add(.{ .id = "leaf", .preferred = "session", .definition = "workspace element that runs one program", .relations = &.{.{ .kind = .partitive, .target = "mid" }} });

    const path = try system.broaderPath("leaf");
    try std.testing.expectEqual(@as(usize, 2), path.items.len);
    try std.testing.expectEqualStrings("mid", path.items[0]);
    try std.testing.expectEqualStrings("top", path.items[1]);

    const children = try system.narrower("mid");
    try std.testing.expectEqual(@as(usize, 1), children.items.len);
    try std.testing.expectEqualStrings("leaf", children.items[0]);
}
