//! Easy-to-Read profile (Inclusion Europe guidance).
//!
//! This is a separate audience profile, not a "simpler" setting for everything.
//! Easy-to-Read material is written for people who need short sentences, common
//! words, one idea at a time and supporting pictures. Applying it to reference
//! documentation for expert readers would remove precision those readers need;
//! withholding it from the material that needs it excludes people. So the
//! profile is selected by audience, and the checker says plainly which of its
//! rules a program cannot decide.

const std = @import("std");
const text = @import("text.zig");

pub const Rule = enum {
    sentence_too_long,
    more_than_one_idea,
    difficult_word,
    figure_of_speech,
    passive_voice,
    abbreviation,
    negative_construction,
    large_number,
    percentage,
    special_character,

    pub fn code(self: Rule) []const u8 {
        return switch (self) {
            .sentence_too_long => "ER01",
            .more_than_one_idea => "ER02",
            .difficult_word => "ER03",
            .figure_of_speech => "ER04",
            .passive_voice => "ER05",
            .abbreviation => "ER06",
            .negative_construction => "ER07",
            .large_number => "ER08",
            .percentage => "ER09",
            .special_character => "ER10",
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

pub const Options = struct {
    max_sentence_words: usize = 15,
    /// Words the document explains where it first uses them.
    explained_words: []const []const u8 = &.{},
};

pub const Report = struct {
    findings: []Finding,
    /// Checks that a person must carry out, listed with every report.
    pub const manual_checks = [_][]const u8{
        "A person with a learning disability read this text and said it was clear.",
        "Each idea has a picture, a symbol or an example that supports it.",
        "The text is set in a large, plain typeface with one sentence on each line.",
        "Important words are used the same way every time they appear.",
    };

    pub fn has(self: Report, rule: Rule) bool {
        for (self.findings) |f| {
            if (f.rule == rule) return true;
        }
        return false;
    }

    pub fn writeText(self: Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.findings) |f| {
            try w.print("{s}  {d}:{d}  {s}\n", .{ f.rule.code(), f.line, f.column, f.message });
            if (f.suggestion) |s| try w.print("        try: {s}\n", .{s});
        }
        try w.writeAll("\nA program cannot decide these. A person must check them:\n");
        for (manual_checks) |c| try w.print("  - {s}\n", .{c});
    }
};

pub fn check(arena: std.mem.Allocator, source: []const u8, options: Options) !Report {
    var findings: std.ArrayList(Finding) = .empty;
    const analysis = try text.analyse(arena, source);

    for (analysis.sentences, 0..) |sentence, index| {
        const position = analysis.positionOf(sentence.span.start);
        const words = analysis.wordsOf(index);

        if (sentence.words > options.max_sentence_words) {
            try findings.append(arena, .{
                .rule = .sentence_too_long,
                .line = position.line,
                .column = position.column,
                .excerpt = sentence.text,
                .message = try std.fmt.allocPrint(arena, "This sentence has {d} words. Write sentences of {d} words or fewer.", .{ sentence.words, options.max_sentence_words }),
            });
        }

        // One idea per sentence: a comma or a joining word usually adds one.
        var joiners: usize = 0;
        for (sentence.text) |c| {
            if (c == ',' or c == ';') joiners += 1;
        }
        for (words) |word| {
            const t = text.trimWord(word.text);
            if (std.ascii.eqlIgnoreCase(t, "and") or std.ascii.eqlIgnoreCase(t, "but") or std.ascii.eqlIgnoreCase(t, "because") or std.ascii.eqlIgnoreCase(t, "which")) joiners += 1;
        }
        if (joiners >= 2) {
            try findings.append(arena, .{
                .rule = .more_than_one_idea,
                .line = position.line,
                .column = position.column,
                .excerpt = sentence.text,
                .message = "This sentence holds more than one idea. Write one idea in each sentence.",
            });
        }

        var w: usize = 0;
        while (w + 1 < words.len) : (w += 1) {
            if (text.isBeVerb(text.trimWord(words[w].text)) and text.looksLikePastParticiple(text.trimWord(words[w + 1].text))) {
                const at = analysis.positionOf(words[w].span.start);
                try findings.append(arena, .{
                    .rule = .passive_voice,
                    .line = at.line,
                    .column = at.column,
                    .excerpt = try std.fmt.allocPrint(arena, "{s} {s}", .{ words[w].text, words[w + 1].text }),
                    .message = "Say who does the action. Write \"the agent opens the file\", not \"the file is opened\".",
                });
            }
        }

        for (words) |word| {
            const raw = text.trimWord(word.text);
            if (raw.len == 0) continue;
            const at = analysis.positionOf(word.span.start);

            if (text.looksLikeAbbreviation(raw) and !isExplained(raw, options)) {
                try findings.append(arena, .{
                    .rule = .abbreviation,
                    .line = at.line,
                    .column = at.column,
                    .excerpt = raw,
                    .message = try std.fmt.allocPrint(arena, "\"{s}\" is a short form. Write the words in full, and explain them.", .{raw}),
                });
                continue;
            }

            if (text.syllables(raw) >= 4 and raw.len > 8 and !isExplained(raw, options)) {
                try findings.append(arena, .{
                    .rule = .difficult_word,
                    .line = at.line,
                    .column = at.column,
                    .excerpt = raw,
                    .message = try std.fmt.allocPrint(arena, "\"{s}\" is a long word. Use a common word, or explain this one where you first use it.", .{raw}),
                });
            }

            if (std.ascii.eqlIgnoreCase(raw, "not") or std.ascii.eqlIgnoreCase(raw, "cannot") or std.ascii.eqlIgnoreCase(raw, "never")) {
                try findings.append(arena, .{
                    .rule = .negative_construction,
                    .line = at.line,
                    .column = at.column,
                    .excerpt = raw,
                    .message = "Say what the reader can do, rather than what they cannot do.",
                });
            }

            if (std.mem.endsWith(u8, raw, "%")) {
                try findings.append(arena, .{
                    .rule = .percentage,
                    .line = at.line,
                    .column = at.column,
                    .excerpt = raw,
                    .message = "Percentages are hard to picture. Write \"1 in 4\" or \"most of them\".",
                });
            }

            if (isLargeNumber(raw)) {
                try findings.append(arena, .{
                    .rule = .large_number,
                    .line = at.line,
                    .column = at.column,
                    .excerpt = raw,
                    .message = "Large numbers are hard to picture. Write \"many\" or compare it with something the reader knows.",
                });
            }
        }
    }

    for (text.idioms) |idiom| {
        if (text.findPhrase(source, idiom)) |found| {
            const at = analysis.positionOf(found);
            try findings.append(arena, .{
                .rule = .figure_of_speech,
                .line = at.line,
                .column = at.column,
                .excerpt = idiom,
                .message = try std.fmt.allocPrint(arena, "\"{s}\" is a figure of speech. Say what happens in plain words.", .{idiom}),
            });
        }
    }

    for (source, 0..) |c, i| {
        if (c == '&' or c == '/' or c == '~' or c == '|' or c == '*' or c == '<' or c == '>') {
            const at = analysis.positionOf(i);
            try findings.append(arena, .{
                .rule = .special_character,
                .line = at.line,
                .column = at.column,
                .excerpt = source[i .. i + 1],
                .message = try std.fmt.allocPrint(arena, "The character \"{c}\" can be hard to read. Write the word instead.", .{c}),
            });
            break;
        }
    }

    return .{ .findings = try findings.toOwnedSlice(arena) };
}

fn isExplained(word: []const u8, options: Options) bool {
    for (options.explained_words) |e| {
        if (std.ascii.eqlIgnoreCase(e, word)) return true;
    }
    return false;
}

fn isLargeNumber(word: []const u8) bool {
    var digits: usize = 0;
    for (word) |c| {
        if (std.ascii.isDigit(c)) digits += 1 else if (c != ',' and c != '.') return false;
    }
    return digits >= 4;
}

test "long sentences and multiple ideas are reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report = try check(arena, "The workspace keeps your work, and it saves each command, because you may want to read it later.", .{});
    try std.testing.expect(report.has(.sentence_too_long));
    try std.testing.expect(report.has(.more_than_one_idea));

    const good = try check(arena, "The workspace saves your work. You can read it later.", .{});
    try std.testing.expect(!good.has(.sentence_too_long));
    try std.testing.expect(!good.has(.more_than_one_idea));
}

test "hard words, short forms and figures of speech are reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report = try check(arena, "The PTY configuration works out of the box.", .{});
    try std.testing.expect(report.has(.abbreviation));
    try std.testing.expect(report.has(.difficult_word));
    try std.testing.expect(report.has(.figure_of_speech));

    const explained = try check(arena, "The PTY is ready.", .{ .explained_words = &.{"PTY"} });
    try std.testing.expect(!explained.has(.abbreviation));
}

test "numbers and percentages are reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report = try check(arena, "We saved 12000 files. That is 30% of them.", .{});
    try std.testing.expect(report.has(.large_number));
    try std.testing.expect(report.has(.percentage));
}

test "the report lists what a program cannot decide" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report = try check(arena, "Open the file.", .{});
    var aw: std.Io.Writer.Allocating = .init(arena);
    try report.writeText(&aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "A person must check them") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "learning disability") != null);
}
