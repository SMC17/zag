//! Simplified Technical English profile (ASD-STE100).
//!
//! Controlled English is not "plainer" English; it is a *restricted* language.
//! One word, one meaning, one part of speech, and procedures written as short
//! imperative sentences. That restriction is what makes a procedure translate
//! and read the same way for every reader, so this profile is applied to
//! procedures, diagnostics and support material — never to conceptual prose,
//! where it would flatten the meaning.
//!
//! The dictionary shipped here is a small working subset: the approved words a
//! terminal workbench actually needs, plus the technical names and verbs the
//! specification lets a project add to its own dictionary.

const std = @import("std");
const text = @import("text.zig");

pub const Rule = enum {
    sentence_too_long,
    word_not_approved,
    disallowed_verb_form,
    paragraph_too_long,
    more_than_one_instruction,
    noun_cluster,
    not_imperative,
    contraction,
    helping_verb_in_procedure,

    pub fn code(self: Rule) []const u8 {
        return switch (self) {
            .sentence_too_long => "STE101",
            .word_not_approved => "STE102",
            .disallowed_verb_form => "STE103",
            .paragraph_too_long => "STE104",
            .more_than_one_instruction => "STE105",
            .noun_cluster => "STE106",
            .not_imperative => "STE107",
            .contraction => "STE108",
            .helping_verb_in_procedure => "STE109",
        };
    }
};

pub const Finding = struct {
    rule: Rule,
    line: usize,
    column: usize,
    excerpt: []const u8,
    message: []const u8,
    suggestion: ?[]const u8 = null,
};

pub const TextType = enum {
    /// Steps a reader carries out. The strictest form.
    procedural,
    /// Explanation of how something works.
    descriptive,

    pub fn sentenceLimit(self: TextType) usize {
        return switch (self) {
            .procedural => 20,
            .descriptive => 25,
        };
    }
};

pub const Options = struct {
    text_type: TextType = .procedural,
    /// Words this project has added to its technical-name dictionary.
    project_dictionary: []const []const u8 = &.{},
    max_paragraph_sentences: usize = 6,
};

/// Approved words with the meaning they carry in Simplified Technical English.
/// The list is short on purpose: a controlled dictionary is a maintained asset,
/// not an attempt to cover all of English.
pub const approved_words = [_][]const u8{
    // Approved verbs
    "add",      "adjust",  "allow",     "apply",    "attach",  "build",     "cancel", "change",
    "check",    "close",   "connect",   "continue", "copy",    "create",    "cut",    "delete",
    "disable",  "do",      "enable",    "end",      "enter",   "examine",   "find",   "get",
    "give",     "hold",    "install",   "keep",     "let",     "look",      "make",   "measure",
    "monitor",  "move",    "open",      "operate",  "prevent", "print",     "push",   "put",
    "read",     "release", "remove",    "repair",   "replace", "reset",     "run",    "save",
    "select",   "send",    "set",       "show",     "start",   "stop",      "test",   "try",
    "turn",     "use",     "wait",      "write",
    // Approved function words
       "a",       "an",        "the",    "and",
    "or",       "but",     "if",        "then",     "than",    "that",      "this",   "these",
    "those",    "with",    "without",   "from",     "to",      "into",      "on",     "off",
    "in",       "out",     "at",        "by",       "for",     "of",        "not",    "no",
    "all",      "each",    "every",     "more",     "less",    "first",     "last",   "next",
    "again",    "also",    "only",      "before",   "after",   "when",      "while",  "you",
    "your",     "it",      "its",       "is",       "are",     "be",        "can",    "will",
    "must",     "do",      "does",      "did",
    // Approved nouns used across the product
         "agent",   "block",     "button", "command",
    "computer", "data",    "directory", "error",    "file",    "folder",    "key",    "line",
    "list",     "log",     "message",   "name",     "network", "number",    "option", "output",
    "page",     "path",    "process",   "program",  "prompt",  "record",    "result", "screen",
    "server",   "session", "shell",     "system",   "task",    "terminal",  "test",   "text",
    "time",     "tool",    "user",      "value",    "window",  "workspace", "step",   "menu",
    "panel",    "report",  "rule",      "policy",   "second",  "minute",    "hour",   "day",
};

/// Words the specification replaces, with the approved word to use.
pub const replacements = [_]text.Substitution{
    .{ .from = "abort", .to = "stop" },
    .{ .from = "kill", .to = "stop" },
    .{ .from = "utilize", .to = "use" },
    .{ .from = "terminate", .to = "end" },
    .{ .from = "commence", .to = "start" },
    .{ .from = "initiate", .to = "start" },
    .{ .from = "obtain", .to = "get" },
    .{ .from = "perform", .to = "do" },
    .{ .from = "ensure", .to = "make sure" },
    .{ .from = "attempt", .to = "try" },
    .{ .from = "modify", .to = "change" },
    .{ .from = "purge", .to = "remove" },
    .{ .from = "spawn", .to = "start" },
    .{ .from = "invoke", .to = "run" },
    .{ .from = "leverage", .to = "use" },
    .{ .from = "prior", .to = "before" },
};

pub fn isApproved(word: []const u8, options: Options) bool {
    for (approved_words) |a| {
        if (std.ascii.eqlIgnoreCase(a, word)) return true;
    }
    for (options.project_dictionary) |a| {
        if (std.ascii.eqlIgnoreCase(a, word)) return true;
    }
    return false;
}

fn replacementFor(word: []const u8) ?[]const u8 {
    for (replacements) |r| {
        if (std.ascii.eqlIgnoreCase(r.from, word)) return r.to;
    }
    return null;
}

fn isConditionOpener(word: []const u8) bool {
    const openers = [_][]const u8{ "if", "when", "before", "after", "while", "note", "warning", "caution", "do" };
    for (openers) |o| {
        if (std.ascii.eqlIgnoreCase(o, word)) return true;
    }
    return false;
}

/// A technical name — a path, an identifier, a number, a flag — is allowed in
/// any position and is not checked against the dictionary.
fn isTechnicalName(word: []const u8) bool {
    if (word.len == 0) return false;
    if (std.ascii.isDigit(word[0])) return true;
    if (std.ascii.isUpper(word[0])) return true;
    for (word) |c| {
        if (c == '/' or c == '.' or c == '_' or c == '-' or c == '{' or c == '}') return true;
    }
    return false;
}

pub const Report = struct {
    findings: []Finding,

    pub fn has(self: Report, rule: Rule) bool {
        for (self.findings) |f| {
            if (f.rule == rule) return true;
        }
        return false;
    }

    pub fn count(self: Report) usize {
        return self.findings.len;
    }
};

pub fn check(arena: std.mem.Allocator, source: []const u8, options: Options) !Report {
    var findings: std.ArrayList(Finding) = .empty;
    const analysis = try text.analyse(arena, source);
    const limit = options.text_type.sentenceLimit();

    for (analysis.sentences, 0..) |sentence, index| {
        const position = analysis.positionOf(sentence.span.start);
        const words = analysis.wordsOf(index);

        if (sentence.words > limit) {
            try findings.append(arena, .{
                .rule = .sentence_too_long,
                .line = position.line,
                .column = position.column,
                .excerpt = sentence.text,
                .message = try std.fmt.allocPrint(arena, "This sentence has {d} words. In this profile, {s} sentences hold {d} words or fewer.", .{ sentence.words, @tagName(options.text_type), limit }),
            });
        }

        // A procedural sentence starts with the verb.
        if (options.text_type == .procedural and words.len > 0) {
            const first = text.trimWord(words[0].text);
            // A step opens with the verb, or with the condition that decides
            // whether the reader carries it out.
            if (!text.isImperativeVerb(first) and !isConditionOpener(first)) {
                try findings.append(arena, .{
                    .rule = .not_imperative,
                    .line = position.line,
                    .column = position.column,
                    .excerpt = sentence.text,
                    .message = "A step starts with the verb for the action.",
                    .suggestion = "Open the file. Run the test.",
                });
            }
        }

        // One instruction per sentence.
        if (options.text_type == .procedural) {
            var verbs: usize = 0;
            for (words, 0..) |word, i| {
                const t = text.trimWord(word.text);
                if (!text.isImperativeVerb(t)) continue;
                if (i == 0) {
                    verbs += 1;
                    continue;
                }
                const previous = text.trimWord(words[i - 1].text);
                if (std.ascii.eqlIgnoreCase(previous, "and") or std.ascii.eqlIgnoreCase(previous, "then") or std.ascii.eqlIgnoreCase(previous, "or")) verbs += 1;
            }
            if (verbs > 1) {
                try findings.append(arena, .{
                    .rule = .more_than_one_instruction,
                    .line = position.line,
                    .column = position.column,
                    .excerpt = sentence.text,
                    .message = "This sentence gives more than one instruction. Write one step for each action.",
                });
            }
        }

        var noun_run: usize = 0;
        for (words) |word| {
            const raw = text.trimWord(word.text);
            if (raw.len == 0) continue;
            const at = analysis.positionOf(word.span.start);

            if (std.mem.indexOfScalar(u8, raw, '\'') != null and raw.len > 2) {
                try findings.append(arena, .{
                    .rule = .contraction,
                    .line = at.line,
                    .column = at.column,
                    .excerpt = raw,
                    .message = try std.fmt.allocPrint(arena, "\"{s}\" is a contraction. Write both words.", .{raw}),
                });
            }

            if (replacementFor(raw)) |better| {
                try findings.append(arena, .{
                    .rule = .word_not_approved,
                    .line = at.line,
                    .column = at.column,
                    .excerpt = raw,
                    .message = try std.fmt.allocPrint(arena, "\"{s}\" is not in the approved dictionary.", .{raw}),
                    .suggestion = better,
                });
            } else if (!isApproved(raw, options) and !isTechnicalName(raw) and raw.len > 2) {
                try findings.append(arena, .{
                    .rule = .word_not_approved,
                    .line = at.line,
                    .column = at.column,
                    .excerpt = raw,
                    .message = try std.fmt.allocPrint(arena, "\"{s}\" is not in the approved dictionary or the project dictionary. Add it to the project dictionary, or use an approved word.", .{raw}),
                });
            }

            // Verb forms: no gerunds as verbs, no past tense in procedures.
            if (options.text_type == .procedural) {
                if (raw.len > 5 and std.mem.endsWith(u8, raw, "ing") and !isTechnicalName(raw)) {
                    try findings.append(arena, .{
                        .rule = .disallowed_verb_form,
                        .line = at.line,
                        .column = at.column,
                        .excerpt = raw,
                        .message = try std.fmt.allocPrint(arena, "\"{s}\" is an -ing form. Use the plain verb in a step.", .{raw}),
                    });
                } else if (text.looksLikePastParticiple(raw) and raw.len > 4) {
                    try findings.append(arena, .{
                        .rule = .disallowed_verb_form,
                        .line = at.line,
                        .column = at.column,
                        .excerpt = raw,
                        .message = try std.fmt.allocPrint(arena, "\"{s}\" is a past form. A step is written in the present, as an instruction.", .{raw}),
                    });
                }
                if (std.ascii.eqlIgnoreCase(raw, "should") or std.ascii.eqlIgnoreCase(raw, "shall") or std.ascii.eqlIgnoreCase(raw, "would")) {
                    try findings.append(arena, .{
                        .rule = .helping_verb_in_procedure,
                        .line = at.line,
                        .column = at.column,
                        .excerpt = raw,
                        .message = try std.fmt.allocPrint(arena, "\"{s}\" leaves the reader unsure whether to act. Write the step as an instruction.", .{raw}),
                    });
                }
            }

            if (raw.len > 3 and std.ascii.isLower(raw[0]) and !text.isBeVerb(raw) and !text.isModal(raw)) {
                noun_run += 1;
                if (noun_run == 4) {
                    try findings.append(arena, .{
                        .rule = .noun_cluster,
                        .line = at.line,
                        .column = at.column,
                        .excerpt = raw,
                        .message = "Four or more words in a row without a linking word make a noun cluster. Break it up.",
                    });
                }
            } else {
                noun_run = 0;
            }
        }
    }

    for (analysis.paragraphs) |paragraph| {
        var count: usize = 0;
        for (analysis.sentences) |s| {
            if (s.span.start >= paragraph.start and s.span.start < paragraph.end) count += 1;
        }
        if (count > options.max_paragraph_sentences) {
            const position = analysis.positionOf(paragraph.start);
            try findings.append(arena, .{
                .rule = .paragraph_too_long,
                .line = position.line,
                .column = position.column,
                .excerpt = "",
                .message = try std.fmt.allocPrint(arena, "This paragraph has {d} sentences. Keep paragraphs to {d} or fewer.", .{ count, options.max_paragraph_sentences }),
            });
        }
    }

    return .{ .findings = try findings.toOwnedSlice(arena) };
}

/// What this profile cannot decide, stated wherever it is reported.
pub const limits_statement =
    "This profile checks the rules a program can check: sentence length, word list, verb form and " ++
    "sentence structure. It does not decide whether a word carries the right technical meaning. " ++
    "A controlled-language dictionary is maintained by people.";

const workbench_dictionary = [_][]const u8{ "workspace", "agent", "worktree", "repository", "branch", "commit", "again", "permission", "capability" };

test "procedures must be short imperative sentences" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const good = try check(arena, "Open the file. Run the test.", .{ .project_dictionary = &workbench_dictionary });
    try std.testing.expect(!good.has(.not_imperative));
    try std.testing.expect(!good.has(.sentence_too_long));

    const bad = try check(arena, "The session should be terminated by the operator when the process has finished running its tests.", .{ .project_dictionary = &workbench_dictionary });
    try std.testing.expect(bad.has(.not_imperative));
    try std.testing.expect(bad.has(.helping_verb_in_procedure));
    try std.testing.expect(bad.has(.disallowed_verb_form));
}

test "unapproved words are replaced with approved ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report = try check(arena, "Terminate the process.", .{ .project_dictionary = &workbench_dictionary });
    try std.testing.expect(report.has(.word_not_approved));
    var suggested = false;
    for (report.findings) |f| {
        if (f.rule == .word_not_approved and f.suggestion != null and std.mem.eql(u8, f.suggestion.?, "end")) suggested = true;
    }
    try std.testing.expect(suggested);
}

test "one instruction per sentence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const two = try check(arena, "Open the file and run the test.", .{ .project_dictionary = &workbench_dictionary });
    try std.testing.expect(two.has(.more_than_one_instruction));

    const one = try check(arena, "Open the file.", .{ .project_dictionary = &workbench_dictionary });
    try std.testing.expect(!one.has(.more_than_one_instruction));
}

test "contractions are not allowed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report = try check(arena, "Do not use it if it doesn't start.", .{ .project_dictionary = &workbench_dictionary });
    try std.testing.expect(report.has(.contraction));
}

test "descriptive text gets the longer sentence limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sentence = "The workspace keeps a record of each command and each result so that you can find the cause of a failure later on.";
    const as_procedure = try check(arena, sentence, .{ .text_type = .procedural, .project_dictionary = &workbench_dictionary });
    const as_description = try check(arena, sentence, .{ .text_type = .descriptive, .project_dictionary = &workbench_dictionary });
    try std.testing.expect(as_procedure.has(.sentence_too_long));
    try std.testing.expect(!as_description.has(.sentence_too_long));
}
