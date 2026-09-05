//! Crosswalks between standards and frameworks.
//!
//! Organisations rarely follow one framework. They follow a management standard
//! and a national framework and a procurement directive, and they need to show
//! that the same control answers all three. A crosswalk states those
//! relationships once, so evidence recorded against one requirement can be
//! reported against another without being duplicated or re-collected.
//!
//! The relation is always stated. "Equivalent" and "related" are not the same
//! claim, and treating them alike is how a crosswalk becomes a fiction.

const std = @import("std");

pub const Relation = enum {
    /// The two requirements ask for the same thing.
    equivalent,
    /// The target is wider: satisfying the source contributes to it.
    broader,
    /// The target is narrower: it is one part of the source.
    narrower,
    /// Connected, but neither satisfies the other.
    related,

    pub fn satisfies(self: Relation) bool {
        return self == .equivalent;
    }

    pub fn describe(self: Relation) []const u8 {
        return switch (self) {
            .equivalent => "asks for the same thing",
            .broader => "is part of",
            .narrower => "contains",
            .related => "is connected to",
        };
    }
};

pub const Mapping = struct {
    from_standard: []const u8,
    from_id: []const u8,
    to_standard: []const u8,
    to_id: []const u8,
    relation: Relation,
    /// Why the mapping holds, or what it leaves out.
    note: []const u8,
};

/// ISO/IEC 42001 controls against the NIST AI Risk Management Framework.
pub const iso42001_nist_ai_rmf = [_]Mapping{
    .{
        .from_standard = "ISO/IEC 42001",
        .from_id = "A.2 AI policy",
        .to_standard = "NIST AI RMF",
        .to_id = "GOVERN 1",
        .relation = .equivalent,
        .note = "Both ask for a stated policy for the organisation's use of AI, owned by someone.",
    },
    .{
        .from_standard = "ISO/IEC 42001",
        .from_id = "A.5 AI system impact assessment",
        .to_standard = "NIST AI RMF",
        .to_id = "MAP 5",
        .relation = .equivalent,
        .note = "Both ask for the effects on people to be identified before deployment.",
    },
    .{
        .from_standard = "ISO/IEC 42001",
        .from_id = "A.6 AI system life cycle",
        .to_standard = "NIST AI RMF",
        .to_id = "MANAGE 2",
        .relation = .broader,
        .note = "The lifecycle control covers more than risk treatment; it also covers development and retirement.",
    },
    .{
        .from_standard = "ISO/IEC 42001",
        .from_id = "A.7 Data for AI systems",
        .to_standard = "NIST AI RMF",
        .to_id = "MAP 2",
        .relation = .related,
        .note = "Both concern the data, but the ISO control is about governance and the NIST function is about context.",
    },
    .{
        .from_standard = "ISO/IEC 42001",
        .from_id = "A.9 Use of AI systems",
        .to_standard = "NIST AI RMF",
        .to_id = "MEASURE 2",
        .relation = .related,
        .note = "Measuring how a system performs in use supports the control on responsible use; neither satisfies the other alone.",
    },
    .{
        .from_standard = "ISO/IEC 23894",
        .from_id = "6.4 Risk treatment",
        .to_standard = "NIST AI RMF",
        .to_id = "MANAGE 1",
        .relation = .equivalent,
        .note = "Both ask for risks to be treated and the treatment to be recorded and owned.",
    },
};

/// WCAG 2.2 success criteria against EN 301 549 clauses. The mapping is
/// one-to-one by construction, because EN 301 549 adopts WCAG by reference.
pub const wcag_en301549 = [_]Mapping{
    .{ .from_standard = "WCAG 2.2", .from_id = "1.4.3", .to_standard = "EN 301 549", .to_id = "9.1.4.3", .relation = .equivalent, .note = "Clause 9 adopts the WCAG criterion for web content." },
    .{ .from_standard = "WCAG 2.2", .from_id = "2.1.1", .to_standard = "EN 301 549", .to_id = "9.2.1.1", .relation = .equivalent, .note = "Clause 9 adopts the WCAG criterion for web content." },
    .{ .from_standard = "WCAG 2.2", .from_id = "2.5.8", .to_standard = "EN 301 549", .to_id = "9.2.5.8", .relation = .equivalent, .note = "Clause 9 adopts the WCAG criterion for web content." },
    .{ .from_standard = "WCAG 2.2", .from_id = "4.1.2", .to_standard = "EN 301 549", .to_id = "9.4.1.2", .relation = .equivalent, .note = "Clause 9 adopts the WCAG criterion for web content." },
    .{
        .from_standard = "WCAG 2.2",
        .from_id = "2.1.1",
        .to_standard = "EN 301 549",
        .to_id = "11.2.1.1",
        .relation = .equivalent,
        .note = "Clause 11 applies the same criterion to non-web software, which is what this product is.",
    },
    .{
        .from_standard = "EN 301 549",
        .from_id = "5.2 Activation of accessibility features",
        .to_standard = "WCAG 2.2",
        .to_id = "",
        .relation = .related,
        .note = "EN 301 549 asks for more than WCAG here: features that support accessibility must be reachable without needing another accessibility feature.",
    },
};

/// The AI documentation formats against each other and against ISO/IEC 12792.
pub const model_documentation = [_]Mapping{
    .{ .from_standard = "Model Cards", .from_id = "Intended use", .to_standard = "ISO/IEC 12792", .to_id = "system purpose", .relation = .equivalent, .note = "Both state what the system is for." },
    .{ .from_standard = "Model Cards", .from_id = "Limitations", .to_standard = "ISO/IEC 12792", .to_id = "capabilities and limits", .relation = .equivalent, .note = "Both state what the system cannot do." },
    .{ .from_standard = "Datasheets for Datasets", .from_id = "Motivation", .to_standard = "ISO/IEC 8183", .to_id = "planning", .relation = .related, .note = "The datasheet records why the data was collected; the lifecycle stage records the decision to collect it." },
    .{ .from_standard = "FactSheets", .from_id = "Performance metrics", .to_standard = "ISO/IEC 25059", .to_id = "quality measures", .relation = .broader, .note = "The quality model defines the characteristics; a FactSheet reports figures against some of them." },
    .{ .from_standard = "CLeAR", .from_id = "Comparable", .to_standard = "ISO/IEC 12792", .to_id = "transparency information", .relation = .related, .note = "CLeAR is about the form of the documentation; the taxonomy is about its content." },
    .{ .from_standard = "Model Cards", .from_id = "Ethical considerations", .to_standard = "ISO/IEC 42005", .to_id = "impact assessment", .relation = .narrower, .note = "An impact assessment covers considerably more than the card's section, including who is affected and how they raise a problem." },
};

pub const Catalogue = struct {
    mappings: []const Mapping,

    /// Everything mapped from one requirement.
    pub fn from(self: Catalogue, arena: std.mem.Allocator, standard: []const u8, id: []const u8) !std.ArrayList(Mapping) {
        var out: std.ArrayList(Mapping) = .empty;
        for (self.mappings) |mapping| {
            if (std.mem.eql(u8, mapping.from_standard, standard) and std.mem.eql(u8, mapping.from_id, id)) {
                try out.append(arena, mapping);
            }
        }
        return out;
    }

    /// Requirements in another framework that this one *satisfies*. Only an
    /// equivalence counts: a broader or related mapping is context, not
    /// evidence.
    pub fn satisfied(self: Catalogue, arena: std.mem.Allocator, standard: []const u8, id: []const u8) !std.ArrayList(Mapping) {
        var out: std.ArrayList(Mapping) = .empty;
        for (self.mappings) |mapping| {
            if (!mapping.relation.satisfies()) continue;
            if (std.mem.eql(u8, mapping.from_standard, standard) and std.mem.eql(u8, mapping.from_id, id)) {
                try out.append(arena, mapping);
            }
        }
        return out;
    }

    pub fn writeReport(self: Catalogue, w: *std.Io.Writer) !void {
        try w.writeAll("How these requirements line up\n\n");
        for (self.mappings) |mapping| {
            try w.print("{s} {s}\n    {s} {s} {s}\n    {s}\n", .{
                mapping.from_standard,
                mapping.from_id,
                mapping.relation.describe(),
                mapping.to_standard,
                mapping.to_id,
                mapping.note,
            });
        }
        try w.writeAll(
            \\
            \\Only "asks for the same thing" lets evidence count for both. The other
            \\relations show how the frameworks fit together; they do not transfer
            \\evidence from one to the other.
            \\
        );
    }
};

pub const all: Catalogue = .{ .mappings = &(iso42001_nist_ai_rmf ++ wcag_en301549 ++ model_documentation) };

const testing = std.testing;

test "only equivalence transfers evidence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const from_lifecycle = try all.from(arena, "ISO/IEC 42001", "A.6 AI system life cycle");
    try testing.expectEqual(@as(usize, 1), from_lifecycle.items.len);
    try testing.expectEqual(Relation.broader, from_lifecycle.items[0].relation);

    const satisfied_by_lifecycle = try all.satisfied(arena, "ISO/IEC 42001", "A.6 AI system life cycle");
    try testing.expectEqual(@as(usize, 0), satisfied_by_lifecycle.items.len);

    const satisfied_by_policy = try all.satisfied(arena, "ISO/IEC 42001", "A.2 AI policy");
    try testing.expectEqual(@as(usize, 1), satisfied_by_policy.items.len);
    try testing.expectEqualStrings("GOVERN 1", satisfied_by_policy.items[0].to_id);
}

test "a wcag criterion maps to both the web and the software clause" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const keyboard = try all.from(arena, "WCAG 2.2", "2.1.1");
    try testing.expectEqual(@as(usize, 2), keyboard.items.len);
    var saw_software_clause = false;
    for (keyboard.items) |mapping| {
        if (std.mem.eql(u8, mapping.to_id, "11.2.1.1")) saw_software_clause = true;
    }
    try testing.expect(saw_software_clause);
}

test "every mapping explains itself" {
    for (all.mappings) |mapping| {
        try testing.expect(mapping.note.len > 20);
        try testing.expect(mapping.from_standard.len > 0);
        try testing.expect(mapping.to_standard.len > 0);
    }
}

test "the report states the limit of a crosswalk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(arena);
    try all.writeReport(&aw.writer);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "they do not transfer") != null);
    try testing.expect(std.mem.indexOf(u8, text, "GOVERN 1") != null);
}
