//! FAIR assessment: findable, accessible, interoperable, reusable.
//!
//! FAIR is a set of principles, not a certification, so this module reports
//! which principles an artefact meets and which it does not, with the reason.
//! The point is to make the gaps visible: an artefact that is findable and
//! accessible but carries no licence is not reusable, and saying so is more
//! useful than a percentage.

const std = @import("std");

pub const Principle = enum {
    /// F1: a globally unique, persistent identifier.
    f1_identifier,
    /// F2: rich metadata.
    f2_metadata,
    /// F3: the metadata says which artefact it describes.
    f3_metadata_links_data,
    /// F4: it is registered or indexed somewhere searchable.
    f4_indexed,
    /// A1: retrievable by its identifier over an open protocol.
    a1_retrievable,
    /// A2: the metadata survives even if the data does not.
    a2_metadata_persists,
    /// I1: a formal, shared, broadly applicable representation.
    i1_formal_representation,
    /// I2: vocabularies that themselves follow FAIR.
    i2_fair_vocabularies,
    /// I3: qualified references to other artefacts.
    i3_qualified_references,
    /// R1: a plurality of accurate, relevant attributes.
    r1_rich_attributes,
    /// R1.1: a clear, accessible usage licence.
    r1_1_licence,
    /// R1.2: detailed provenance.
    r1_2_provenance,
    /// R1.3: it meets the standards of its domain.
    r1_3_domain_standards,

    pub fn letter(self: Principle) u8 {
        return switch (self) {
            .f1_identifier, .f2_metadata, .f3_metadata_links_data, .f4_indexed => 'F',
            .a1_retrievable, .a2_metadata_persists => 'A',
            .i1_formal_representation, .i2_fair_vocabularies, .i3_qualified_references => 'I',
            else => 'R',
        };
    }

    pub fn question(self: Principle) []const u8 {
        return switch (self) {
            .f1_identifier => "Does it have an identifier that will not change?",
            .f2_metadata => "Is it described well enough to be found?",
            .f3_metadata_links_data => "Does the description say which thing it describes?",
            .f4_indexed => "Is it listed somewhere a person or program can search?",
            .a1_retrievable => "Can it be fetched by its identifier, using an open protocol?",
            .a2_metadata_persists => "Does the description survive if the data is deleted?",
            .i1_formal_representation => "Is it written in a shared, formal representation?",
            .i2_fair_vocabularies => "Do its terms come from vocabularies that are themselves findable?",
            .i3_qualified_references => "Does it say how it relates to other things, not only that it does?",
            .r1_rich_attributes => "Does it carry enough attributes to be reused?",
            .r1_1_licence => "Is there a licence that says what may be done with it?",
            .r1_2_provenance => "Does it say where it came from?",
            .r1_3_domain_standards => "Does it meet the standards its field expects?",
        };
    }
};

pub const Answer = struct {
    principle: Principle,
    met: bool,
    /// Evidence when met; what is missing when not.
    note: []const u8,
};

pub const Assessment = struct {
    subject: []const u8,
    answers: []const Answer,

    pub fn metCount(self: Assessment) usize {
        var count: usize = 0;
        for (self.answers) |answer| {
            if (answer.met) count += 1;
        }
        return count;
    }

    pub fn unmet(self: Assessment, arena: std.mem.Allocator) !std.ArrayList(Answer) {
        var out: std.ArrayList(Answer) = .empty;
        for (self.answers) |answer| {
            if (!answer.met) try out.append(arena, answer);
        }
        return out;
    }

    /// Is one letter of FAIR fully met?
    pub fn letterMet(self: Assessment, letter: u8) bool {
        var seen = false;
        for (self.answers) |answer| {
            if (answer.principle.letter() != letter) continue;
            seen = true;
            if (!answer.met) return false;
        }
        return seen;
    }

    pub fn writeReport(self: Assessment, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("FAIR assessment: {s}\n\n", .{self.subject});
        for (self.answers) |answer| {
            try w.print("[{c}] {s} {s}\n    {s}\n", .{
                answer.principle.letter(),
                if (answer.met) "yes" else "no ",
                answer.principle.question(),
                answer.note,
            });
        }
        try w.print("\n{d} of {d} principles met.\n", .{ self.metCount(), self.answers.len });
        try w.writeAll("FAIR is a set of principles, not a certification. This report says which are met and which are not.\n");
    }
};

/// The assessment for the workspace vocabulary the product publishes.
pub fn vocabularyAssessment() Assessment {
    return .{
        .subject = "the zag workspace vocabulary",
        .answers = &.{
            .{ .principle = .f1_identifier, .met = true, .note = "Every concept has a stable IRI under https://zag.dev/vocab/workspace/." },
            .{ .principle = .f2_metadata, .met = true, .note = "Each concept carries a preferred term, a definition, a subject field and its relations." },
            .{ .principle = .f3_metadata_links_data, .met = true, .note = "Each concept is linked to its scheme with skos:inScheme." },
            .{ .principle = .f4_indexed, .met = false, .note = "The vocabulary is published in the repository but is not registered in any external catalogue yet." },
            .{ .principle = .a1_retrievable, .met = true, .note = "It is served as a file over HTTPS, and is in the repository." },
            .{ .principle = .a2_metadata_persists, .met = true, .note = "The vocabulary is the metadata; it is version-controlled." },
            .{ .principle = .i1_formal_representation, .met = true, .note = "It is published as SKOS in Turtle and JSON-LD." },
            .{ .principle = .i2_fair_vocabularies, .met = true, .note = "It uses SKOS, Dublin Core terms and PROV-O." },
            .{ .principle = .i3_qualified_references, .met = true, .note = "Relations are typed: broader, narrower, related, and part-of for partitive relations." },
            .{ .principle = .r1_rich_attributes, .met = true, .note = "Concepts carry deprecated terms, examples, notes and sources." },
            .{ .principle = .r1_1_licence, .met = true, .note = "Published under the repository licence, stated in the scheme metadata." },
            .{ .principle = .r1_2_provenance, .met = true, .note = "Generated from source in the repository, with the generator recorded." },
            .{ .principle = .r1_3_domain_standards, .met = true, .note = "Definitions follow ISO 704 and are checked by the terminology tests." },
        },
    };
}

const testing = std.testing;

test "every principle asks a question" {
    inline for (std.meta.fields(Principle)) |field| {
        const principle: Principle = @enumFromInt(field.value);
        const question = principle.question();
        try testing.expectEqual(@as(u8, '?'), question[question.len - 1]);
    }
}

test "the vocabulary assessment names its one gap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const assessment = vocabularyAssessment();
    const gaps = try assessment.unmet(arena);
    try testing.expectEqual(@as(usize, 1), gaps.items.len);
    try testing.expectEqual(Principle.f4_indexed, gaps.items[0].principle);

    try testing.expect(!assessment.letterMet('F'));
    try testing.expect(assessment.letterMet('A'));
    try testing.expect(assessment.letterMet('I'));
    try testing.expect(assessment.letterMet('R'));
}

test "the report refuses to give a score" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(arena);
    try vocabularyAssessment().writeReport(&aw.writer);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "not a certification") != null);
    try testing.expect(std.mem.indexOf(u8, text, "12 of 13 principles met.") != null);
}
