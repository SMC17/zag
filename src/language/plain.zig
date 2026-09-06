//! The plain-language pass (ISO 24495-1, with parts 2 and 3 as profiles).
//!
//! What this is: a checker that finds *likely* problems in text the reader has
//! to act on, and says what to do about each one.
//!
//! What this is not: a conformance test. ISO 24495-1 is built around four
//! principles — the reader can find, understand and use what they need, and the
//! text is relevant to them — and it asks for evaluation with real readers.
//! A program can find an undefined abbreviation. It cannot find out whether a
//! reader understood a sentence. Every report this module produces says so, and
//! the evidence it emits is recorded as `static_analysis`, never as proof of
//! conformance.

const std = @import("std");
const text = @import("text.zig");
const audience_mod = @import("audience.zig");
const readability = @import("readability.zig");
const concepts = @import("../knowledge/concepts.zig");
const datetime = @import("../interop/datetime.zig");
const units = @import("../interop/units.zig");

pub const Audience = audience_mod.Audience;
pub const Purpose = audience_mod.Purpose;
pub const TextKind = audience_mod.TextKind;

pub const Severity = enum { blocking, major, minor, advisory };

pub const Rule = enum {
    undefined_abbreviation,
    sentence_too_long,
    paragraph_too_long,
    passive_voice_in_instruction,
    nominalisation,
    noun_cluster,
    vague_quantifier,
    condition_before_action,
    action_at_end,
    expletive_opening,
    complex_word,
    wordy_phrase,
    label_without_action,
    error_without_next_step,
    raw_error_code,
    warning_without_consequence,
    prompt_without_subject,
    unexplained_placeholder,
    double_negative,
    non_preferred_term,
    idiom,
    ambiguous_datetime,
    ambiguous_unit,

    pub fn code(self: Rule) []const u8 {
        return switch (self) {
            .undefined_abbreviation => "PL001",
            .sentence_too_long => "PL002",
            .paragraph_too_long => "PL003",
            .passive_voice_in_instruction => "PL005",
            .nominalisation => "PL006",
            .noun_cluster => "PL007",
            .vague_quantifier => "PL009",
            .condition_before_action => "PL010",
            .action_at_end => "PL012",
            .expletive_opening => "PL014",
            .complex_word => "PL015",
            .wordy_phrase => "PL016",
            .label_without_action => "PL018",
            .error_without_next_step => "PL022",
            .raw_error_code => "PL024",
            .warning_without_consequence => "PL026",
            .prompt_without_subject => "PL028",
            .unexplained_placeholder => "PL030",
            .double_negative => "PL035",
            .non_preferred_term => "PL041",
            .idiom => "PL050",
            .ambiguous_datetime => "DATE02",
            .ambiguous_unit => "UNIT03",
        };
    }

    /// Which of the four ISO 24495-1 governing principles the rule serves.
    pub fn principle(self: Rule) Principle {
        return switch (self) {
            .undefined_abbreviation, .complex_word, .wordy_phrase, .nominalisation, .noun_cluster, .passive_voice_in_instruction, .double_negative, .idiom, .expletive_opening, .sentence_too_long => .understandable,
            .paragraph_too_long, .condition_before_action, .action_at_end => .findable,
            .label_without_action, .error_without_next_step, .warning_without_consequence, .prompt_without_subject, .vague_quantifier, .unexplained_placeholder, .raw_error_code => .usable,
            .non_preferred_term, .ambiguous_datetime, .ambiguous_unit => .relevant,
        };
    }
};

/// The four governing principles of ISO 24495-1, in the order the standard
/// states them.
pub const Principle = enum {
    relevant,
    findable,
    understandable,
    usable,

    pub fn statement(self: Principle) []const u8 {
        return switch (self) {
            .relevant => "The information is relevant to the reader.",
            .findable => "The reader can find what they need.",
            .understandable => "The reader can understand what they find.",
            .usable => "The reader can use the information.",
        };
    }
};

pub const Finding = struct {
    rule: Rule,
    severity: Severity,
    line: usize,
    column: usize,
    /// The exact text the finding is about.
    excerpt: []const u8,
    /// What is wrong, addressed to the person who can fix it.
    message: []const u8,
    /// What to write instead, when the checker can propose something concrete.
    suggestion: ?[]const u8 = null,

    pub fn writeLine(self: Finding, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}  {d}:{d}  {s}\n", .{ self.rule.code(), self.line, self.column, self.message });
        if (self.suggestion) |s| try w.print("        try: {s}\n", .{s});
    }
};

pub const Options = struct {
    audience: Audience = audience_mod.developer,
    purpose: Purpose = .inform,
    kind: TextKind = .body,
    /// Concept system used to check that the text uses the registered terms.
    terminology: ?*const concepts.ConceptSystem = null,
    /// Abbreviations this document has already written out.
    known_abbreviations: []const []const u8 = &.{},
    /// Turn off the rules that only make sense for prose when checking a label.
    strict_structure: bool = false,
};

pub const Report = struct {
    arena: std.mem.Allocator,
    findings: []Finding,
    metrics: readability.Metrics,
    options: Options,

    pub fn worstSeverity(self: Report) ?Severity {
        var worst: ?Severity = null;
        for (self.findings) |f| {
            if (worst == null or @intFromEnum(f.severity) < @intFromEnum(worst.?)) worst = f.severity;
        }
        return worst;
    }

    pub fn countOf(self: Report, rule: Rule) usize {
        var n: usize = 0;
        for (self.findings) |f| {
            if (f.rule == rule) n += 1;
        }
        return n;
    }

    pub fn has(self: Report, rule: Rule) bool {
        return self.countOf(rule) > 0;
    }

    /// Human-readable report. It always ends with the statement of what the
    /// checker could not establish.
    pub fn writeText(self: Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.findings) |f| try f.writeLine(w);
        try w.print("\n{d} finding(s). Written for: {s}\n", .{ self.findings.len, self.options.audience.description });
        try w.print("Estimated reading: {s}.\n", .{self.metrics.describe()});
        try w.print("\n{s}\n", .{limits_statement});
    }

    pub fn writeJson(self: Report, w: *std.Io.Writer) !void {
        var jw: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
        try jw.beginObject();
        try jw.objectField("audience");
        try jw.write(self.options.audience.id);
        try jw.objectField("textKind");
        try jw.write(@tagName(self.options.kind));
        try jw.objectField("purpose");
        try jw.write(@tagName(self.options.purpose));
        try jw.objectField("findings");
        try jw.beginArray();
        for (self.findings) |f| {
            try jw.beginObject();
            try jw.objectField("code");
            try jw.write(f.rule.code());
            try jw.objectField("rule");
            try jw.write(@tagName(f.rule));
            try jw.objectField("principle");
            try jw.write(@tagName(f.rule.principle()));
            try jw.objectField("severity");
            try jw.write(@tagName(f.severity));
            try jw.objectField("line");
            try jw.write(f.line);
            try jw.objectField("column");
            try jw.write(f.column);
            try jw.objectField("excerpt");
            try jw.write(f.excerpt);
            try jw.objectField("message");
            try jw.write(f.message);
            if (f.suggestion) |s| {
                try jw.objectField("suggestion");
                try jw.write(s);
            }
            try jw.endObject();
        }
        try jw.endArray();
        try jw.objectField("readabilityEstimate");
        try jw.beginObject();
        try jw.objectField("fleschReadingEase");
        try jw.write(self.metrics.fleschReadingEase());
        try jw.objectField("fleschKincaidGrade");
        try jw.write(self.metrics.fleschKincaidGrade());
        try jw.objectField("caveat");
        try jw.write(readability.caveat);
        try jw.endObject();
        try jw.objectField("limits");
        try jw.write(limits_statement);
        try jw.endObject();
    }
};

/// Printed with every report. This is the sentence that keeps the tool honest.
pub const limits_statement =
    "This check finds likely problems. It does not establish conformance with ISO 24495-1. " ++
    "The standard is met when the intended reader can find, understand and use the information, " ++
    "which is established by evaluating the text with readers.";

pub fn check(arena: std.mem.Allocator, source: []const u8, options: Options) !Report {
    var findings: std.ArrayList(Finding) = .empty;

    // Code is not prose. A command, a path or a field name inside backticks or
    // a fenced block is quoted material, and checking it as English produces
    // findings the author cannot act on. The code is blanked out before the
    // text is analysed, keeping every byte offset, so line and column numbers
    // still point at the real file.
    const code_mask = try codeMask(arena, source);
    const prose = try arena.dupe(u8, source);
    for (code_mask, 0..) |masked, index| {
        if (masked and prose[index] != '\n') prose[index] = ' ';
    }
    const analysis = try text.analyse(arena, prose);

    var seen_abbreviations: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (options.known_abbreviations) |a| try seen_abbreviations.put(arena, a, {});

    try checkSentences(arena, &findings, analysis, options, &seen_abbreviations);
    try checkParagraphs(arena, &findings, analysis, options);
    try checkPhrases(arena, &findings, analysis.lines, prose, options);
    try checkKindDuties(arena, &findings, prose, analysis, options);
    try checkTerminology(arena, &findings, analysis, options);
    try checkMachineValues(arena, &findings, analysis, options);

    std.mem.sort(Finding, findings.items, {}, byPosition);
    return .{
        .arena = arena,
        .findings = try findings.toOwnedSlice(arena),
        .metrics = readability.measure(analysis),
        .options = options,
    };
}

/// Where the front matter ends, in bytes. Front matter is a block fenced by a
/// line of `+++` or `---` at the very start of the file. Zero when there is
/// none.
fn frontMatterEnd(source: []const u8) usize {
    const fences = [_][]const u8{ "+++", "---" };
    for (fences) |fence| {
        if (!std.mem.startsWith(u8, source, fence)) continue;
        var at = std.mem.indexOfScalar(u8, source, '\n') orelse return 0;
        at += 1;
        while (at < source.len) {
            const line_end = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
            const line = std.mem.trim(u8, source[at..line_end], " \t\r");
            at = @min(line_end + 1, source.len);
            if (std.mem.eql(u8, line, fence)) return at;
        }
        return 0;
    }
    return 0;
}

/// A byte for each byte of the source: true where the byte is inside a code
/// span or a fenced code block.
fn codeMask(arena: std.mem.Allocator, source: []const u8) ![]bool {
    const mask = try arena.alloc(bool, source.len);
    @memset(mask, false);

    var index: usize = frontMatterEnd(source);
    // Front matter is metadata, not prose. Checking `owner = "..."` as English
    // produces findings about a line the author cannot rewrite.
    for (mask[0..index]) |*byte| byte.* = true;
    var in_fence = false;
    var at_line_start = true;
    while (index < source.len) : (index += 1) {
        const c = source[index];
        if (at_line_start and index + 2 < source.len and std.mem.startsWith(u8, source[index..], "```")) {
            in_fence = !in_fence;
            // Mark the fence line itself as code either way.
            while (index < source.len and source[index] != '\n') : (index += 1) mask[index] = true;
            at_line_start = true;
            continue;
        }
        if (in_fence) {
            mask[index] = true;
            at_line_start = c == '\n';
            continue;
        }
        if (c == '`') {
            const close = std.mem.indexOfScalarPos(u8, source, index + 1, '`') orelse {
                at_line_start = false;
                continue;
            };
            // An unclosed backtick on a line is not a span.
            if (std.mem.indexOfScalarPos(u8, source[index..close], 0, '\n') != null) {
                at_line_start = false;
                continue;
            }
            var mark = index;
            while (mark <= close) : (mark += 1) mask[mark] = true;
            index = close;
            at_line_start = false;
            continue;
        }
        // An indented block is code too.
        if (at_line_start and index + 4 <= source.len and std.mem.eql(u8, source[index..][0..4], "    ")) {
            const line_end = std.mem.indexOfScalarPos(u8, source, index, '\n') orelse source.len;
            const line = source[index + 4 .. line_end];
            // Two kinds of indented line are code: one that does not begin with
            // a letter, and one that opens an indented block after a blank
            // line. An indented line that continues a list item is prose, and a
            // list continuation never follows a blank line.
            const looks_like_code = line.len > 0 and !std.ascii.isAlphabetic(line[0]);
            if (looks_like_code or previousLineIsBlank(source, index)) {
                var mark = index;
                while (mark < line_end) : (mark += 1) mask[mark] = true;
                index = line_end;
                at_line_start = true;
                continue;
            }
        }
        at_line_start = c == '\n';
    }
    return mask;
}

/// True when the line before `index` holds nothing but spaces. Used to tell an
/// indented code block from a list item's continuation line.
fn previousLineIsBlank(source: []const u8, index: usize) bool {
    if (index == 0) return true;
    if (source[index - 1] != '\n') return false;
    var at = index - 1;
    while (at > 0 and source[at - 1] != '\n') : (at -= 1) {
        const c = source[at - 1];
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

fn byPosition(_: void, a: Finding, b: Finding) bool {
    if (a.line != b.line) return a.line < b.line;
    return a.column < b.column;
}

fn add(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    source_position: text.Position,
    rule: Rule,
    severity: Severity,
    excerpt: []const u8,
    message: []const u8,
    suggestion: ?[]const u8,
) !void {
    try findings.append(arena, .{
        .rule = rule,
        .severity = severity,
        .line = source_position.line,
        .column = source_position.column,
        .excerpt = excerpt,
        .message = message,
        .suggestion = suggestion,
    });
}

fn checkSentences(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    analysis: text.Analysis,
    options: Options,
    seen_abbreviations: *std.StringArrayHashMapUnmanaged(void),
) !void {
    const limit = audience_mod.sentenceLimit(options.audience, options.kind);
    const instructing = options.purpose == .instruct or options.kind == .procedure;

    for (analysis.sentences, 0..) |sentence, index| {
        const position = analysis.positionOf(sentence.span.start);

        // A table is not a sentence. Measuring one as prose reports a
        // hundred-word "sentence" that no author can act on.
        const is_table = std.mem.count(u8, sentence.text, "|") >= 2;

        if (!is_table and sentence.words > limit) {
            try add(arena, findings, position, .sentence_too_long, .minor, sentence.text, try std.fmt.allocPrint(arena, "This sentence has {d} words. For this reader, keep sentences to {d} words or fewer. Split it at the first \"and\" or \"which\".", .{ sentence.words, limit }), null);
        }

        const words = analysis.wordsOf(index);

        // Passive voice in an instruction hides who acts.
        if (instructing) {
            var w: usize = 0;
            while (w + 1 < words.len) : (w += 1) {
                if (text.isBeVerb(text.trimWord(words[w].text)) and text.looksLikePastParticiple(text.trimWord(words[w + 1].text))) {
                    const at = analysis.positionOf(words[w].span.start);
                    try add(arena, findings, at, .passive_voice_in_instruction, .major, try std.fmt.allocPrint(arena, "{s} {s}", .{ words[w].text, words[w + 1].text }), "This instruction does not say who acts. Name the actor and use the plain verb.", try std.fmt.allocPrint(arena, "\"the agent {s}s ...\" or \"{s} ...\"", .{ stripEd(text.trimWord(words[w + 1].text)), stripEd(text.trimWord(words[w + 1].text)) }));
                    break;
                }
            }
        }

        // An opening condition longer than a short clause buries the action.
        if (words.len > 0 and instructing) {
            const first = text.trimWord(words[0].text);
            if (std.ascii.eqlIgnoreCase(first, "if") or std.ascii.eqlIgnoreCase(first, "when") or std.ascii.eqlIgnoreCase(first, "although") or std.ascii.eqlIgnoreCase(first, "whenever")) {
                const comma = std.mem.indexOfScalar(u8, sentence.text, ',');
                if (comma) |c| {
                    var clause_words: usize = 0;
                    var it = std.mem.tokenizeAny(u8, sentence.text[0..c], " \t");
                    while (it.next()) |_| clause_words += 1;
                    if (clause_words > 10) {
                        try add(arena, findings, position, .condition_before_action, .minor, sentence.text[0..c], try std.fmt.allocPrint(arena, "The condition runs for {d} words before the reader learns what to do. Put the action first, then the condition.", .{clause_words}), null);
                    }
                }
            }
        }

        // The action should not be the last thing in an instruction.
        if (instructing and words.len >= 8) {
            var verb_index: ?usize = null;
            for (words, 0..) |word, i| {
                if (text.isImperativeVerb(text.trimWord(word.text))) {
                    verb_index = i;
                    break;
                }
            }
            if (verb_index) |vi| {
                const share = @as(f32, @floatFromInt(vi)) / @as(f32, @floatFromInt(words.len));
                if (share > 0.6) {
                    const at = analysis.positionOf(words[vi].span.start);
                    try add(arena, findings, at, .action_at_end, .minor, sentence.text, try std.fmt.allocPrint(arena, "The action \"{s}\" appears near the end of the sentence. Start the sentence with it.", .{words[vi].text}), null);
                }
            }
        }

        // Expletive openings postpone the subject.
        if (words.len >= 2) {
            const a0 = text.trimWord(words[0].text);
            const a1 = text.trimWord(words[1].text);
            if ((std.ascii.eqlIgnoreCase(a0, "there") or std.ascii.eqlIgnoreCase(a0, "it")) and text.isBeVerb(a1)) {
                try add(arena, findings, position, .expletive_opening, .advisory, try std.fmt.allocPrint(arena, "{s} {s}", .{ words[0].text, words[1].text }), "The sentence opens without naming its subject. Start with the thing the sentence is about.", null);
            }
        }

        // Double negatives. A list of absences ("no window, no font, no
        // images") repeats one negative across a list; it is not the sentence
        // that makes a reader work out what two negatives cancel to. Only the
        // first "no" of such a run counts.
        var negatives: usize = 0;
        var previous_was_negative = false;
        for (words) |word| {
            const t = text.trimWord(word.text);
            const is_negative = std.ascii.eqlIgnoreCase(t, "not") or
                std.ascii.eqlIgnoreCase(t, "never") or
                std.ascii.eqlIgnoreCase(t, "no") or
                (std.mem.startsWith(u8, t, "un") and t.len > 5) or
                std.ascii.eqlIgnoreCase(t, "cannot");
            if (is_negative) {
                const in_list = previous_was_negative or startsListedAbsence(analysis.source, word.span);
                if (!in_list) negatives += 1;
                previous_was_negative = true;
            } else {
                previous_was_negative = false;
            }
        }
        if (negatives >= 2) {
            try add(arena, findings, position, .double_negative, .minor, sentence.text, "This sentence uses two or more negatives. State what is true instead of what is not.", null);
        }

        // Noun clusters. A table row is skipped: its cells are not a phrase.
        if (!is_table) {
            var run: usize = 0;
            var run_start: usize = 0;
            for (words, 0..) |word, i| {
                const t = text.trimWord(word.text);
                if (t.len > 3 and std.ascii.isLower(t[0]) and !text.isBeVerb(t) and !text.isModal(t) and !isFunctionWord(t)) {
                    if (run == 0) run_start = i;
                    run += 1;
                    if (run == 4) {
                        const at = analysis.positionOf(words[run_start].span.start);
                        try add(arena, findings, at, .noun_cluster, .advisory, try std.fmt.allocPrint(arena, "{s} {s} {s} {s}", .{ words[run_start].text, words[run_start + 1].text, words[run_start + 2].text, words[run_start + 3].text }), "Four words in a row with no linking word are hard to parse. Add a preposition, or split the phrase.", null);
                    }
                } else {
                    run = 0;
                }
            }
        }

        // Word-level checks.
        for (words, 0..) |word, word_index| {
            const raw = text.trimWord(word.text);
            if (raw.len == 0) continue;
            const at = analysis.positionOf(word.span.start);

            const known_here = text.isCommonAbbreviation(raw) or
                isConventionalFileName(raw) or
                (options.audience.expertise != .general and text.isStandardsAbbreviation(raw));
            if (text.looksLikeAbbreviation(raw) and !known_here and !options.audience.allows_unexplained_abbreviations) {
                if (!seen_abbreviations.contains(raw)) {
                    // An abbreviation written out first, as "pseudoterminal (PTY)",
                    // is fine; the expansion appears before the short form.
                    const expanded = expansionPrecedes(analysis.source, word.span.start, raw);
                    if (!expanded) {
                        try add(arena, findings, at, .undefined_abbreviation, .major, raw, try std.fmt.allocPrint(arena, "\"{s}\" appears without being written out. Write the full term the first time, then the short form in brackets.", .{raw}), try std.fmt.allocPrint(arena, "full term ({s})", .{raw}));
                    }
                    try seen_abbreviations.put(arena, raw, {});
                }
            }

            // A noun formed from a verb is only a problem when it is *used*
            // as one: "make a decision" instead of "decide". Flagging every
            // word that ends in "-tion" would flag "definition" and "edition",
            // which are simply nouns.
            if (text.isNominalisation(raw) and options.kind != .legal_clause) {
                if (lightVerbBefore(words, word_index)) |verb| {
                    try add(arena, findings, at, .nominalisation, .minor, raw, try std.fmt.allocPrint(arena, "\"{s} ... {s}\" hides the action in a noun. Use the verb.", .{ verb, raw }), suggestedVerb(raw));
                }
            }

            for (text.substitutions) |s| {
                if (std.ascii.eqlIgnoreCase(raw, s.from)) {
                    try add(arena, findings, at, .complex_word, .minor, raw, try std.fmt.allocPrint(arena, "\"{s}\" is longer than it needs to be.", .{raw}), try std.fmt.allocPrint(arena, "{s}", .{s.to}));
                }
            }

            if (options.purpose == .instruct) {
                for (text.vague_quantifiers) |q| {
                    if (std.ascii.eqlIgnoreCase(raw, q)) {
                        try add(arena, findings, at, .vague_quantifier, .major, raw, try std.fmt.allocPrint(arena, "\"{s}\" does not tell the reader how many or which. Give the number or name the items.", .{raw}), null);
                    }
                }
            }

            if (options.audience.condition == .accessibility_supported or options.audience.expertise == .general) {
                // Idioms are checked at phrase level; single-word figures are
                // caught here.
                if (std.ascii.eqlIgnoreCase(raw, "kill") or std.ascii.eqlIgnoreCase(raw, "abort")) {
                    try add(arena, findings, at, .idiom, .minor, raw, try std.fmt.allocPrint(arena, "\"{s}\" is jargon for this reader. Say what happens to the program.", .{raw}), "stop");
                }
            }

            // Placeholders that were never filled in. Brackets are part of
            // the placeholder, so only sentence punctuation is trimmed here.
            const bracketed = std.mem.trim(u8, word.text, ".,;:!?");
            if (options.kind.isInterfaceText() and isPlaceholder(bracketed)) {
                try add(arena, findings, at, .unexplained_placeholder, .blocking, bracketed, try std.fmt.allocPrint(arena, "The placeholder \"{s}\" reached the reader. Fill it in before the text is shown.", .{bracketed}), null);
            }

            // Raw error codes without an explanation.
            if (isErrorCode(raw)) {
                try add(arena, findings, at, .raw_error_code, .major, raw, try std.fmt.allocPrint(arena, "\"{s}\" is an internal code. Say what happened in words; keep the code at the end for support.", .{raw}), null);
            }
        }
    }
}

/// True when the word sits in a comma-separated list of absences, which is one
/// idea written out, not a stack of negatives.
fn startsListedAbsence(source: []const u8, span: text.Span) bool {
    var at = span.start;
    // Walk back over the separator to the word before it.
    while (at > 0 and (source[at - 1] == ' ' or source[at - 1] == ',' or source[at - 1] == '\n')) : (at -= 1) {
        if (source[at - 1] == ',') return true;
    }
    return false;
}

fn checkParagraphs(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    analysis: text.Analysis,
    options: Options,
) !void {
    if (options.kind.isInterfaceText()) return;
    // A list and a paragraph are different shapes, and a reader handles them
    // differently, so they get different limits: sentences for a paragraph,
    // items for a list.
    const list_item_limit: usize = 9;
    // Sentences and paragraphs both run in order through the text, so one
    // walk covers both. Restarting the sentence list for every paragraph made
    // checking a long document quadratic in its own length.
    var next_sentence: usize = 0;
    for (analysis.paragraphs) |paragraph| {
        while (next_sentence < analysis.sentences.len and
            analysis.sentences[next_sentence].span.start < paragraph.start) : (next_sentence += 1)
        {}
        var sentences: usize = 0;
        var scan = next_sentence;
        while (scan < analysis.sentences.len and analysis.sentences[scan].span.start < paragraph.end) : (scan += 1) {
            sentences += 1;
        }
        // List items are counted from the lines, not from the sentences. A
        // marker like "1." ends a sentence on its own, so counting sentences
        // that start with a marker misses every numbered item and then reports
        // the whole list as one long paragraph.
        var items: usize = 0;
        var table_rows: usize = 0;
        var lines = std.mem.splitScalar(u8, analysis.source[paragraph.start..paragraph.end], '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "|")) {
                table_rows += 1;
                continue;
            }
            if (text.startsListItem(line)) items += 1;
        }
        // A table is neither a paragraph nor a list. A reader scans down one
        // column, so the limits for prose say nothing useful about it.
        if (table_rows > 0) continue;
        const position = analysis.positionOf(paragraph.start);
        if (items > 0) {
            if (items > list_item_limit) {
                try add(arena, findings, position, .paragraph_too_long, .minor, "", try std.fmt.allocPrint(arena, "This list has {d} items. Keep a list to {d} or fewer, or group the items under headings.", .{ items, list_item_limit }), null);
            }
        } else if (sentences > options.audience.max_paragraph_sentences) {
            try add(arena, findings, position, .paragraph_too_long, .minor, "", try std.fmt.allocPrint(arena, "This paragraph has {d} sentences. Keep paragraphs to {d} or fewer so the reader can scan them.", .{ sentences, options.audience.max_paragraph_sentences }), null);
        }
    }
}

fn checkPhrases(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    lines: text.LineIndex,
    source: []const u8,
    options: Options,
) !void {
    for (text.phrase_substitutions) |s| {
        var offset: usize = 0;
        while (offset < source.len) {
            const found = text.findPhrase(source[offset..], s.from) orelse break;
            const at = lines.positionOf(offset + found);
            const suggestion = if (s.to.len == 0)
                try std.fmt.allocPrint(arena, "delete \"{s}\"", .{s.from})
            else
                try std.fmt.allocPrint(arena, "{s}", .{s.to});
            try add(arena, findings, at, .wordy_phrase, .minor, s.from, try std.fmt.allocPrint(arena, "\"{s}\" can be shortened without losing meaning.", .{s.from}), suggestion);
            offset += found + s.from.len;
        }
    }

    if (options.audience.condition == .accessibility_supported or options.audience.expertise == .general) {
        for (text.idioms) |idiom| {
            if (text.findPhrase(source, idiom)) |found| {
                const at = lines.positionOf(found);
                try add(arena, findings, at, .idiom, .major, idiom, try std.fmt.allocPrint(arena, "\"{s}\" is a figure of speech. Say plainly what happens.", .{idiom}), null);
            }
        }
    }
}

fn checkKindDuties(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    source: []const u8,
    analysis: text.Analysis,
    options: Options,
) !void {
    const trimmed = std.mem.trim(u8, source, " \t\n");
    const start = analysis.positionOf(0);

    switch (options.kind) {
        .button_label, .menu_item => {
            const vague = [_][]const u8{ "ok", "yes", "no", "submit", "continue", "next", "done", "confirm", "proceed", "go" };
            var first_word_buf: [64]u8 = undefined;
            const first = firstWord(trimmed, &first_word_buf);
            var is_vague = false;
            for (vague) |v| {
                if (std.ascii.eqlIgnoreCase(trimmed, v)) is_vague = true;
            }
            if (is_vague or (!text.isImperativeVerb(first) and !startsWithCapitalNoun(trimmed))) {
                try add(arena, findings, start, .label_without_action, .major, trimmed, try std.fmt.allocPrint(arena, "The label \"{s}\" does not say what happens when the reader chooses it. Start with the verb for the action.", .{trimmed}), "Delete build folder");
            }
        },
        .error_message => {
            if (!hasNextStep(analysis)) {
                try add(arena, findings, start, .error_without_next_step, .major, trimmed, "This message says what failed but not what to do next. Add one sentence that starts with the action the reader can take.", "Change the file permission, or run the command with access to the file.");
            }
        },
        .warning => {
            if (!statesConsequence(source)) {
                try add(arena, findings, start, .warning_without_consequence, .major, trimmed, "This warning does not say what happens if the reader continues. State the result.", null);
            }
        },
        .permission_prompt => {
            if (!namesSubject(source)) {
                try add(arena, findings, start, .prompt_without_subject, .blocking, trimmed, "This request does not name the exact operation and the thing it affects. Show the command or the path the reader is approving.", "Run rm -rf build/? This deletes the build folder in this repository.");
            }
            if (!hasNextStep(analysis)) {
                try add(arena, findings, start, .error_without_next_step, .major, trimmed, "This request does not offer the reader a choice in words. Give the options as actions.", "Allow once - Always allow here - Cancel");
            }
        },
        else => {},
    }
}

fn checkTerminology(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    analysis: text.Analysis,
    options: Options,
) !void {
    const system = options.terminology orelse return;
    // Designations can be phrases ("project shell"), so the source is scanned
    // for each deprecated designation rather than word by word.
    var it = system.concepts.iterator();
    while (it.next()) |entry| {
        const concept = entry.value_ptr.*;
        for (concept.designations) |designation| {
            if (designation.status != .deprecated) continue;
            var offset: usize = 0;
            while (offset < analysis.source.len) {
                const found = text.findPhrase(analysis.source[offset..], designation.text) orelse break;
                const at = analysis.positionOf(offset + found);
                try add(arena, findings, at, .non_preferred_term, .major, designation.text, try std.fmt.allocPrint(arena, "\"{s}\" is a term we no longer use. The registered term for this concept is \"{s}\".", .{ designation.text, concept.preferred }), try std.fmt.allocPrint(arena, "{s}", .{concept.preferred}));
                offset += found + designation.text.len;
            }
        }
    }
}

fn checkMachineValues(
    arena: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    analysis: text.Analysis,
    options: Options,
) !void {
    _ = options;
    for (analysis.words) |word| {
        const raw = text.trimWord(word.text);
        if (raw.len == 0) continue;
        const at = analysis.positionOf(word.span.start);

        switch (datetime.looksAmbiguous(raw)) {
            .none => {},
            .numeric_slash_date, .numeric_dash_date => try add(arena, findings, at, .ambiguous_datetime, .major, raw, try std.fmt.allocPrint(arena, "\"{s}\" can be read as two different dates. Write the month in words for readers, and store the value as an ISO 8601 date.", .{raw}), "4 September 2026"),
            .bare_clock_time => try add(arena, findings, at, .ambiguous_datetime, .minor, raw, try std.fmt.allocPrint(arena, "\"{s}\" has no date and no time zone. Say which instant it refers to.", .{raw}), null),
            .local_datetime_without_offset => try add(arena, findings, at, .ambiguous_datetime, .major, raw, try std.fmt.allocPrint(arena, "\"{s}\" has no time zone, so it names no single instant. Add the offset, or use UTC.", .{raw}), null),
        }

        // A number immediately followed by an ambiguous unit letter.
        if (splitNumberUnit(raw)) |split| {
            if (units.isAmbiguousInProse(split.unit)) {
                try add(arena, findings, at, .ambiguous_unit, .major, raw, try std.fmt.allocPrint(arena, "\"{s}\" uses the unit \"{s}\", which has more than one meaning in prose. Write the unit out, or use the UCUM code.", .{ raw, split.unit }), null);
            }
        }
    }
}

const NumberUnit = struct { number: []const u8, unit: []const u8 };

fn splitNumberUnit(word: []const u8) ?NumberUnit {
    var i: usize = 0;
    while (i < word.len and (std.ascii.isDigit(word[i]) or word[i] == '.')) i += 1;
    if (i == 0 or i == word.len) return null;
    const unit = word[i..];
    for (unit) |c| {
        if (!std.ascii.isAlphabetic(c)) return null;
    }
    return .{ .number = word[0..i], .unit = unit };
}

/// The light verbs that turn a verb into a noun: "make a decision", "perform
/// an analysis". Returns the verb when one appears just before the noun.
fn lightVerbBefore(words: []const text.Word, index: usize) ?[]const u8 {
    const light = [_][]const u8{ "make", "makes", "made", "perform", "performs", "performed", "provide", "provides", "give", "gives", "carry", "carries", "conduct", "conducts", "undertake", "undertakes", "do", "does", "take", "takes" };
    if (index == 0) return null;
    // The pattern is "make a decision", not "carries its edition": the noun
    // follows an article, and a light verb comes just before that.
    const preceding = text.trimWord(words[index - 1].text);
    const article = std.ascii.eqlIgnoreCase(preceding, "a") or
        std.ascii.eqlIgnoreCase(preceding, "an") or
        std.ascii.eqlIgnoreCase(preceding, "the") or
        std.ascii.eqlIgnoreCase(preceding, "out");
    if (!article) return null;

    var back: usize = 2;
    while (back <= 3 and back <= index) : (back += 1) {
        const candidate = text.trimWord(words[index - back].text);
        for (light) |verb| {
            if (std.ascii.eqlIgnoreCase(candidate, verb)) return candidate;
        }
    }
    return null;
}

/// The verb hiding inside a common nominalisation.
fn suggestedVerb(word: []const u8) ?[]const u8 {
    const pairs = [_]text.Substitution{
        .{ .from = "decision", .to = "decide" },
        .{ .from = "analysis", .to = "analyse" },
        .{ .from = "evaluation", .to = "evaluate" },
        .{ .from = "investigation", .to = "investigate" },
        .{ .from = "consideration", .to = "consider" },
        .{ .from = "description", .to = "describe" },
        .{ .from = "installation", .to = "install" },
        .{ .from = "configuration", .to = "configure" },
        .{ .from = "initialisation", .to = "start" },
        .{ .from = "initialization", .to = "start" },
        .{ .from = "verification", .to = "verify" },
        .{ .from = "modification", .to = "change" },
        .{ .from = "assessment", .to = "assess" },
        .{ .from = "measurement", .to = "measure" },
        .{ .from = "improvement", .to = "improve" },
        .{ .from = "utilisation", .to = "use" },
        .{ .from = "utilization", .to = "use" },
    };
    for (pairs) |pair| {
        if (std.ascii.eqlIgnoreCase(pair.from, word)) return pair.to;
    }
    return null;
}

fn isFunctionWord(word: []const u8) bool {
    const list = [_][]const u8{
        "the",   "a",     "an",   "and",   "or",    "but",   "if",    "then",   "than", "with", "without",
        "from",  "into",  "onto", "over",  "under", "about", "after", "before", "for",  "that", "this",
        "these", "those", "when", "while", "each",  "every", "any",   "you",    "your", "they", "their",
        "its",   "his",   "her",  "our",   "will",  "does",
    };
    for (list) |w| {
        if (std.ascii.eqlIgnoreCase(w, word)) return true;
    }
    return false;
}

/// File names that are written in capitals by convention. They are names, not
/// abbreviations, and asking an author to expand them makes the text worse.
fn isConventionalFileName(word: []const u8) bool {
    const names = [_][]const u8{ "README", "LICENSE", "AGENTS", "NOTICE", "CHANGELOG", "CONTRIBUTING", "MIT", "TODO", "COPYING" };
    for (names) |name| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    return false;
}

fn isPlaceholder(word: []const u8) bool {
    if (word.len < 2) return false;
    if (word[0] == '{' and word[word.len - 1] == '}') return true;
    if (word[0] == '%' and word.len <= 3) return true;
    if (std.mem.startsWith(u8, word, "$") and word.len > 1 and std.ascii.isUpper(word[1])) return true;
    return false;
}

fn isErrorCode(word: []const u8) bool {
    if (word.len < 4 or word.len > 12) return false;
    if (word[0] != 'E') return false;
    for (word) |c| {
        if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c)) return false;
    }
    const known = [_][]const u8{ "EACCES", "ENOENT", "EPERM", "EEXIST", "ENOSPC", "EPIPE", "EAGAIN", "EBADF", "EINVAL", "EINTR", "ENOTDIR", "EISDIR", "ETIMEDOUT" };
    for (known) |k| {
        if (std.mem.eql(u8, k, word)) return true;
    }
    return false;
}

/// Does the expansion of an abbreviation appear before it, as in
/// "pseudoterminal (PTY)"?
fn expansionPrecedes(source: []const u8, abbreviation_start: usize, abbreviation: []const u8) bool {
    if (abbreviation_start == 0) return false;
    // The bracket form is the one we accept.
    if (abbreviation_start < 1 or source[abbreviation_start - 1] != '(') return false;
    const window_start = if (abbreviation_start > 80) abbreviation_start - 80 else 0;
    const window = source[window_start .. abbreviation_start - 1];
    var initials: usize = 0;
    var it = std.mem.tokenizeAny(u8, window, " \t\n-");
    var words: [16][]const u8 = undefined;
    var count: usize = 0;
    while (it.next()) |w| {
        if (count == words.len) {
            std.mem.copyForwards([]const u8, words[0 .. words.len - 1], words[1..]);
            count -= 1;
        }
        words[count] = w;
        count += 1;
    }
    if (count == 0) return false;
    // Accept when the preceding words' initials spell the abbreviation, or when
    // a single preceding word starts with its first letter (as in
    // "pseudoterminal (PTY)").
    if (count >= abbreviation.len) {
        const tail = words[count - abbreviation.len ..][0..abbreviation.len];
        initials = 0;
        for (tail, 0..) |w, i| {
            if (w.len > 0 and std.ascii.toUpper(w[0]) == abbreviation[i]) initials += 1;
        }
        if (initials == abbreviation.len) return true;
    }
    const last = words[count - 1];
    return last.len >= abbreviation.len and std.ascii.toUpper(last[0]) == abbreviation[0];
}

fn hasNextStep(analysis: text.Analysis) bool {
    for (analysis.sentences, 0..) |_, index| {
        const words = analysis.wordsOf(index);
        if (words.len == 0) continue;
        if (text.isImperativeVerb(text.trimWord(words[0].text))) return true;
        // "You can run ..." also offers a step.
        if (words.len >= 3 and std.ascii.eqlIgnoreCase(text.trimWord(words[0].text), "you")) {
            if (text.isModal(text.trimWord(words[1].text)) and text.isImperativeVerb(text.trimWord(words[2].text))) return true;
        }
    }
    return false;
}

fn statesConsequence(source: []const u8) bool {
    const markers = [_][]const u8{ "will", "cannot", "can not", "you lose", "is deleted", "are deleted", "stops", "ends", "removes", "overwrites", "cannot be undone", "permanently" };
    for (markers) |m| {
        if (text.findPhrase(source, m) != null) return true;
    }
    return false;
}

/// A permission prompt must name the operation and the thing it affects.
/// A path, a quoted command, a command flag or a host name all count as
/// naming it; an abstract phrase such as "the proposed operation" does not.
fn namesSubject(source: []const u8) bool {
    if (std.mem.indexOfScalar(u8, source, '`') != null) return true;
    var it = std.mem.tokenizeAny(u8, source, " \t\n");
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, "?.,;:()\"'");
        if (token.len < 2) continue;
        if (std.mem.indexOfScalar(u8, token, '/') != null) return true; // a path
        if (std.mem.startsWith(u8, raw, "-") and raw.len > 1) return true; // a flag
        // A host name or a file name: dotted, unbroken, with a real suffix.
        if (std.mem.indexOfScalar(u8, token, '.')) |dot| {
            if (dot > 0 and dot + 1 < token.len) return true;
        }
    }
    return false;
}

fn firstWord(source: []const u8, buf: []u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, source, " \t\n");
    const w = it.next() orelse return "";
    const trimmed = text.trimWord(w);
    const n = @min(trimmed.len, buf.len);
    @memcpy(buf[0..n], trimmed[0..n]);
    return buf[0..n];
}

fn startsWithCapitalNoun(source: []const u8) bool {
    // A label may name a place rather than an action ("Settings", "Sessions").
    const trimmed = std.mem.trim(u8, source, " \t\n");
    if (trimmed.len == 0) return false;
    if (!std.ascii.isUpper(trimmed[0])) return false;
    var spaces: usize = 0;
    for (trimmed) |c| {
        if (c == ' ') spaces += 1;
    }
    return spaces == 0;
}

fn stripEd(word: []const u8) []const u8 {
    if (std.mem.endsWith(u8, word, "ed") and word.len > 3) return word[0 .. word.len - 2];
    return word;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn runCheck(arena: std.mem.Allocator, source: []const u8, options: Options) !Report {
    return check(arena, source, options);
}

test "reports the permission prompt example from the design" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bad = try runCheck(arena, "Agent requires elevated process execution capability for proposed operation.", .{
        .kind = .permission_prompt,
        .purpose = .decide,
        .audience = audience_mod.operator_under_pressure,
    });
    try std.testing.expect(bad.has(.prompt_without_subject));

    const good = try runCheck(arena,
        \\Run rm -rf build/?
        \\The agent wants to delete the build folder in this repository.
        \\Your source files will not change.
        \\Allow once. Always allow here. Cancel.
    , .{
        .kind = .permission_prompt,
        .purpose = .decide,
        .audience = audience_mod.operator_under_pressure,
    });
    try std.testing.expect(!good.has(.prompt_without_subject));
}

test "reports an error message with no next step and a raw code" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bad = try runCheck(arena, "Tool invocation failed. Error code EACCES.", .{
        .kind = .error_message,
        .purpose = .inform,
    });
    try std.testing.expect(bad.has(.error_without_next_step));
    try std.testing.expect(bad.has(.raw_error_code));

    const good = try runCheck(arena,
        \\The command could not open config.toml.
        \\This process does not have permission to read the file.
        \\Change the file permission, or run the command with access to it.
    , .{ .kind = .error_message, .purpose = .instruct });
    try std.testing.expect(!good.has(.error_without_next_step));
}

test "reports vague button labels" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const vague = try runCheck(arena, "OK", .{ .kind = .button_label });
    try std.testing.expect(vague.has(.label_without_action));

    const clear = try runCheck(arena, "Delete build folder", .{ .kind = .button_label });
    try std.testing.expect(!clear.has(.label_without_action));

    const place = try runCheck(arena, "Settings", .{ .kind = .button_label });
    try std.testing.expect(!place.has(.label_without_action));
}

test "reports undefined abbreviations but accepts expansions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const undefined_use = try runCheck(arena, "The PTY closed before the shell exited.", .{});
    try std.testing.expect(undefined_use.has(.undefined_abbreviation));

    const expanded = try runCheck(arena, "The pseudoterminal (PTY) closed before the shell exited.", .{});
    try std.testing.expect(!expanded.has(.undefined_abbreviation));

    const common = try runCheck(arena, "The JSON body was empty.", .{});
    try std.testing.expect(!common.has(.undefined_abbreviation));
}

test "reports passive voice and buried actions in instructions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const passive = try runCheck(arena, "The configuration file is written by the agent before the tests are started.", .{
        .kind = .procedure,
        .purpose = .instruct,
    });
    try std.testing.expect(passive.has(.passive_voice_in_instruction));

    const buried = try runCheck(arena, "Once the workspace has finished loading every session and every agent, restart it.", .{
        .kind = .procedure,
        .purpose = .instruct,
    });
    try std.testing.expect(buried.has(.action_at_end));
}

test "a noun is only a nominalisation when a light verb hides the action" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hidden = try runCheck(arena, "The reviewer will make a decision about the patch.", .{});
    try std.testing.expect(hidden.has(.nominalisation));
    for (hidden.findings) |finding| {
        if (finding.rule == .nominalisation) try std.testing.expectEqualStrings("decide", finding.suggestion.?);
    }

    // These are ordinary nouns, not hidden verbs.
    const plain_nouns = try runCheck(arena, "The definition, the edition and the statement are in the documentation.", .{});
    try std.testing.expect(!plain_nouns.has(.nominalisation));
}

test "a table row is not measured as a sentence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const table =
        \\| Part | What it does |
        \\| --- | --- |
        \\| events | The typed event union, and an append-only log whose entries are chained by hash so that any later change to an entry is detectable by anyone holding the log |
    ;
    const report = try runCheck(arena, table, .{});
    try std.testing.expect(!report.has(.sentence_too_long));
    try std.testing.expect(!report.has(.noun_cluster));
}

test "reports wordy phrases and long words with a replacement" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report = try runCheck(arena, "In order to utilize the workspace, terminate the prior session.", .{ .purpose = .instruct });
    try std.testing.expect(report.has(.wordy_phrase));
    try std.testing.expect(report.has(.complex_word));

    var found_suggestion = false;
    for (report.findings) |f| {
        if (f.rule == .complex_word and f.suggestion != null) found_suggestion = true;
    }
    try std.testing.expect(found_suggestion);
}

test "reports ambiguous dates and units" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report = try runCheck(arena, "The run started on 9/4/26 and took 10m.", .{});
    try std.testing.expect(report.has(.ambiguous_datetime));
    try std.testing.expect(report.has(.ambiguous_unit));

    const clean = try runCheck(arena, "The run started on 4 September 2026 and took 10 minutes.", .{});
    try std.testing.expect(!clean.has(.ambiguous_datetime));
    try std.testing.expect(!clean.has(.ambiguous_unit));
}

test "reports deprecated product terms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var system = concepts.ConceptSystem.init(arena);
    try system.add(.{
        .id = "workspace",
        .preferred = "workspace",
        .definition = "development environment with durable state",
        .designations = &.{.{ .text = "project shell", .status = .deprecated }},
        .top_concept = true,
    });

    const report = try runCheck(arena, "Open the project shell to start.", .{ .terminology = &system, .purpose = .instruct });
    try std.testing.expect(report.has(.non_preferred_term));
    for (report.findings) |f| {
        if (f.rule == .non_preferred_term) {
            try std.testing.expectEqualStrings("workspace", f.suggestion.?);
        }
    }
}

test "reports idioms only for the readers who need it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = "The workspace works out of the box.";
    const expert = try runCheck(arena, source, .{ .audience = audience_mod.developer });
    try std.testing.expect(!expert.has(.idiom));

    const easy = try runCheck(arena, source, .{ .audience = audience_mod.easy_read_reader });
    try std.testing.expect(easy.has(.idiom));
}

test "reports placeholders that reached the reader" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report = try runCheck(arena, "Could not open {path}.", .{ .kind = .error_message });
    try std.testing.expect(report.has(.unexplained_placeholder));
    try std.testing.expectEqual(Severity.blocking, report.worstSeverity().?);
}

test "report output always states what the check cannot establish" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report = try runCheck(arena, "The agent stopped. Read the log to find out why.", .{});
    var aw: std.Io.Writer.Allocating = .init(arena);
    try report.writeText(&aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "does not establish conformance") != null);

    var jw: std.Io.Writer.Allocating = .init(arena);
    try report.writeJson(&jw.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, jw.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("limits") != null);
    try std.testing.expect(parsed.value.object.get("readabilityEstimate").?.object.get("caveat") != null);
}

test "warnings must state the consequence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bare = try runCheck(arena, "Careful with this action.", .{ .kind = .warning, .purpose = .warn });
    try std.testing.expect(bare.has(.warning_without_consequence));

    const full = try runCheck(arena, "This deletes the folder. You cannot undo it.", .{ .kind = .warning, .purpose = .warn });
    try std.testing.expect(!full.has(.warning_without_consequence));
}

test "quoted code is not checked as prose" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `PTY` inside a code span is quoted material, not an unexplained
    // abbreviation the author should expand.
    const with_span = try runCheck(arena, "Run `zag lint PTY` to see it.", .{});
    try std.testing.expect(!with_span.has(.undefined_abbreviation));

    const in_prose = try runCheck(arena, "Run zag lint PTY to see it.", .{});
    try std.testing.expect(in_prose.has(.undefined_abbreviation));

    const fenced = try runCheck(arena,
        \\Here is the command.
        \\
        \\```
        \\zag run -- rm -rf build/ 9/4/26
        \\```
        \\
        \\That is all.
    , .{});
    try std.testing.expect(!fenced.has(.ambiguous_datetime));
}

test "conventional file names are names, not abbreviations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report = try runCheck(arena, "The terms are in LICENSE, and the guide is in README.", .{});
    try std.testing.expect(!report.has(.undefined_abbreviation));
}

test "who the reader is decides which short forms need explaining" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sentence = "The text follows ISO 24495-1 and WCAG 2.2.";

    const for_developer = try runCheck(arena, sentence, .{ .audience = audience_mod.developer });
    try std.testing.expect(!for_developer.has(.undefined_abbreviation));

    const for_general = try runCheck(arena, sentence, .{ .audience = audience_mod.easy_read_reader });
    try std.testing.expect(for_general.has(.undefined_abbreviation));
}
