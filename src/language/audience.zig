//! Audiences, purposes and the thresholds that follow from them.
//!
//! ISO 24495-1 asks the writer to identify the reader and the purpose before
//! anything else, and to judge the result against that reader. So the checker
//! never asks "is this text plain?" in the abstract; it asks "is this text
//! usable by *this* reader for *this* purpose?", and its thresholds change
//! accordingly.

const std = @import("std");
const language = @import("../interop/language.zig");

/// How much the reader already knows about the subject.
pub const Expertise = enum {
    /// No assumed knowledge of software development.
    general,
    /// Works in software, may be new to this product.
    practitioner,
    /// Knows this product and this subject area.
    expert,
};

/// The conditions under which the text is read. Text read during an incident
/// gets stricter limits than text read while planning.
pub const ReadingCondition = enum {
    /// The reader is choosing, with time to read.
    considered,
    /// The reader is in the middle of a task.
    working,
    /// Something has failed and the reader is under pressure.
    under_pressure,
    /// The reader uses assistive technology or has a cognitive disability that
    /// the Easy-to-Read guidance addresses.
    accessibility_supported,
};

pub const Purpose = enum {
    /// Tell the reader how to do something.
    instruct,
    /// Give the reader facts they need.
    inform,
    /// Tell the reader about a risk before they act.
    warn,
    /// Help the reader choose between options.
    decide,
    /// State an obligation or a legal position.
    comply,
    /// Report a measurement, an experiment or an evaluation.
    report,
};

/// The kind of text being checked. Different kinds carry different duties: an
/// error message must offer a next step; a button label must name an action.
pub const TextKind = enum {
    button_label,
    menu_item,
    status_message,
    error_message,
    permission_prompt,
    heading,
    body,
    procedure,
    warning,
    release_note,
    legal_clause,
    scientific_report,
    help_topic,
    agent_message,
    commit_message,

    pub fn isInterfaceText(self: TextKind) bool {
        return switch (self) {
            .button_label, .menu_item, .status_message, .error_message, .permission_prompt, .agent_message => true,
            else => false,
        };
    }

    pub fn mustOfferNextStep(self: TextKind) bool {
        return switch (self) {
            .error_message, .permission_prompt, .warning => true,
            else => false,
        };
    }
};

pub const Audience = struct {
    id: []const u8,
    /// One sentence naming the reader.
    description: []const u8,
    expertise: Expertise,
    condition: ReadingCondition = .working,
    lang: language.Tag = language.Tag.english,
    /// Longest sentence this reader should have to parse, in words.
    max_sentence_words: usize = 25,
    /// Longest paragraph, in sentences.
    max_paragraph_sentences: usize = 5,
    /// Whether an abbreviation may appear without being written out first.
    allows_unexplained_abbreviations: bool = false,
};

pub const developer: Audience = .{
    .id = "developer",
    .description = "A software developer who uses this product every day.",
    .expertise = .expert,
    .condition = .working,
    .max_sentence_words = 25,
};

pub const new_user: Audience = .{
    .id = "new-user",
    .description = "A software developer who has not used this product before.",
    .expertise = .practitioner,
    .condition = .considered,
    .max_sentence_words = 22,
};

pub const operator_under_pressure: Audience = .{
    .id = "operator-in-incident",
    .description = "A person deciding what to do while something is failing.",
    .expertise = .practitioner,
    .condition = .under_pressure,
    .max_sentence_words = 18,
    .max_paragraph_sentences = 3,
};

pub const auditor: Audience = .{
    .id = "auditor",
    .description = "A person checking whether the system did what it says it does.",
    .expertise = .practitioner,
    .condition = .considered,
    .max_sentence_words = 28,
};

pub const easy_read_reader: Audience = .{
    .id = "easy-read",
    .description = "A person who needs short sentences, common words and one idea at a time.",
    .expertise = .general,
    .condition = .accessibility_supported,
    .max_sentence_words = 15,
    .max_paragraph_sentences = 3,
};

pub const legal_reviewer: Audience = .{
    .id = "legal-reviewer",
    .description = "A person reading a term to work out what it obliges them to do.",
    .expertise = .practitioner,
    .condition = .considered,
    .max_sentence_words = 30,
};

pub const scientific_reviewer: Audience = .{
    .id = "scientific-reviewer",
    .description = "A person judging whether a reported result is sound and reproducible.",
    .expertise = .expert,
    .condition = .considered,
    .max_sentence_words = 30,
};

pub const registry = [_]Audience{
    developer,
    new_user,
    operator_under_pressure,
    auditor,
    easy_read_reader,
    legal_reviewer,
    scientific_reviewer,
};

pub fn byId(id: []const u8) ?Audience {
    for (registry) |a| {
        if (std.mem.eql(u8, a.id, id)) return a;
    }
    return null;
}

/// Sentence limit for a piece of text: the stricter of the audience's limit and
/// any limit the text kind imposes.
pub fn sentenceLimit(audience: Audience, kind: TextKind) usize {
    const kind_limit: usize = switch (kind) {
        .button_label, .menu_item => 6,
        .heading => 12,
        .error_message, .permission_prompt, .status_message => 18,
        .warning => 16,
        .procedure => 20,
        .agent_message => 22,
        else => 30,
    };
    return @min(audience.max_sentence_words, kind_limit);
}

test "audience and kind together set the limit" {
    try std.testing.expectEqual(@as(usize, 6), sentenceLimit(developer, .button_label));
    try std.testing.expectEqual(@as(usize, 15), sentenceLimit(easy_read_reader, .body));
    try std.testing.expectEqual(@as(usize, 18), sentenceLimit(operator_under_pressure, .body));
    try std.testing.expectEqual(@as(usize, 16), sentenceLimit(developer, .warning));
}

test "audiences are addressable by identifier" {
    try std.testing.expectEqualStrings("developer", byId("developer").?.id);
    try std.testing.expect(byId("nobody") == null);
    try std.testing.expectEqual(Expertise.general, easy_read_reader.expertise);
}

test "text kinds carry their duties" {
    try std.testing.expect(TextKind.error_message.mustOfferNextStep());
    try std.testing.expect(!TextKind.body.mustOfferNextStep());
    try std.testing.expect(TextKind.button_label.isInterfaceText());
}
