//! Text analysis primitives shared by every language check.
//!
//! Sentence and word boundaries, syllable estimates, abbreviation shapes and
//! the small grammar heuristics (passive voice, nominalisation, imperative
//! openings) live here so that the plain-language, controlled-English and
//! easy-to-read checkers all measure the same way. A rule that means different
//! things in two checkers is worse than no rule.

const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize,

    pub fn slice(self: Span, text: []const u8) []const u8 {
        return text[self.start..self.end];
    }

    pub fn len(self: Span) usize {
        return self.end - self.start;
    }
};

pub const Position = struct {
    line: usize,
    column: usize,
};

/// Line and column (both 1-based) of a byte offset.
pub fn positionOf(text: []const u8, offset: usize) Position {
    var line: usize = 1;
    var column: usize = 1;
    var i: usize = 0;
    while (i < offset and i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

/// Abbreviations that carry no explanation burden in this product's text,
/// because every intended reader already uses them daily.
pub const common_abbreviations = [_][]const u8{
    "AI", "API", "CI", "CLI", "CPU", "CSV", "GPU", "HTML", "HTTP", "HTTPS",
    "ID",  "IO",  "JSON", "OS", "PDF", "RAM", "SI", "SQL", "TLS", "UI",
    "URL", "USB", "UTC", "UTF", "XML", "YAML", "ZIP",
};

/// Words that a plain-language checker asks the author to replace, and the
/// shorter word to use instead. The list is deliberately short: it holds only
/// substitutions where the simpler word means the same thing.
pub const Substitution = struct { from: []const u8, to: []const u8 };

pub const substitutions = [_]Substitution{
    .{ .from = "utilize", .to = "use" },
    .{ .from = "utilise", .to = "use" },
    .{ .from = "utilization", .to = "use" },
    .{ .from = "terminate", .to = "end" },
    .{ .from = "commence", .to = "start" },
    .{ .from = "initiate", .to = "start" },
    .{ .from = "facilitate", .to = "help" },
    .{ .from = "leverage", .to = "use" },
    .{ .from = "endeavour", .to = "try" },
    .{ .from = "endeavor", .to = "try" },
    .{ .from = "ascertain", .to = "find out" },
    .{ .from = "subsequently", .to = "then" },
    .{ .from = "additionally", .to = "also" },
    .{ .from = "approximately", .to = "about" },
    .{ .from = "sufficient", .to = "enough" },
    .{ .from = "requisite", .to = "needed" },
    .{ .from = "modify", .to = "change" },
    .{ .from = "obtain", .to = "get" },
    .{ .from = "perform", .to = "do" },
    .{ .from = "prior", .to = "before" },
    .{ .from = "regarding", .to = "about" },
    .{ .from = "attempt", .to = "try" },
    .{ .from = "assist", .to = "help" },
    .{ .from = "purchase", .to = "buy" },
    .{ .from = "remainder", .to = "rest" },
    .{ .from = "numerous", .to = "many" },
};

pub const phrase_substitutions = [_]Substitution{
    .{ .from = "in order to", .to = "to" },
    .{ .from = "prior to", .to = "before" },
    .{ .from = "subsequent to", .to = "after" },
    .{ .from = "in the event that", .to = "if" },
    .{ .from = "at this point in time", .to = "now" },
    .{ .from = "due to the fact that", .to = "because" },
    .{ .from = "in the process of", .to = "" },
    .{ .from = "a number of", .to = "some" },
    .{ .from = "is able to", .to = "can" },
    .{ .from = "has the ability to", .to = "can" },
    .{ .from = "with regard to", .to = "about" },
    .{ .from = "in accordance with", .to = "under" },
};

/// Quantifiers that leave an instruction unactionable.
pub const vague_quantifiers = [_][]const u8{
    "several", "various", "certain", "appropriate", "sufficient", "adequate", "reasonable", "some",
};

/// Verbs that appear at the start of an instruction. Used to decide whether a
/// label or a step actually tells the reader what to do.
pub const imperative_verbs = [_][]const u8{
    "add",     "allow",  "apply",  "cancel", "change",  "check",   "choose", "clear",
    "close",   "copy",   "create", "delete", "deny",    "disable", "enable", "end",
    "enter",   "export", "find",   "fix",    "give",    "import",  "install", "keep",
    "move",    "open",   "pause",  "pick",   "read",    "rename",  "replace", "restart",
    "restore", "resume", "review", "run",    "save",    "select",  "send",    "set",
    "share",   "show",   "sign",   "skip",   "start",   "stop",    "try",     "turn",
    "undo",    "update", "use",    "view",   "write",   "remove",  "reject",  "approve",
    "grant",   "revoke", "retry",  "connect", "download", "upload", "publish", "print",
};

/// Forms of "to be" used by the passive-voice heuristic.
pub const be_verbs = [_][]const u8{ "is", "are", "was", "were", "be", "been", "being", "am" };

pub const modal_verbs = [_][]const u8{ "will", "would", "can", "could", "may", "might", "must", "shall", "should" };

/// Idioms and figures of speech that an easy-to-read audience should not have
/// to decode.
pub const idioms = [_][]const u8{
    "out of the box", "under the hood", "up and running", "hit the ground running",
    "in a nutshell",  "rule of thumb",  "state of the art", "best of breed",
    "moving parts",   "low hanging fruit", "on the fly", "at the end of the day",
};

pub fn isCommonAbbreviation(word: []const u8) bool {
    for (common_abbreviations) |a| {
        if (std.mem.eql(u8, a, word)) return true;
    }
    return false;
}

pub fn isImperativeVerb(word: []const u8) bool {
    for (imperative_verbs) |v| {
        if (std.ascii.eqlIgnoreCase(v, word)) return true;
    }
    return false;
}

pub fn isBeVerb(word: []const u8) bool {
    for (be_verbs) |v| {
        if (std.ascii.eqlIgnoreCase(v, word)) return true;
    }
    return false;
}

pub fn isModal(word: []const u8) bool {
    for (modal_verbs) |v| {
        if (std.ascii.eqlIgnoreCase(v, word)) return true;
    }
    return false;
}

/// Very rough past-participle test, good enough to pair with a "to be" form.
pub fn looksLikePastParticiple(word: []const u8) bool {
    if (word.len < 5) return false;
    const irregular = [_][]const u8{
        "done", "made", "given", "taken", "written", "shown", "known", "found",
        "seen", "sent", "kept", "held", "built", "run", "read", "set", "put",
        "chosen", "drawn", "begun", "brought", "caught", "left", "lost", "met",
    };
    for (irregular) |i| {
        if (std.ascii.eqlIgnoreCase(i, word)) return true;
    }
    if (std.mem.endsWith(u8, word, "ed")) {
        // Exclude common adjectives and nouns that end in "ed".
        const exceptions = [_][]const u8{ "need", "speed", "feed", "seed", "embed", "exceed", "proceed", "succeed", "indeed" };
        for (exceptions) |e| {
            if (std.ascii.eqlIgnoreCase(e, word)) return false;
        }
        return true;
    }
    return false;
}

/// Words formed by turning a verb into a noun. They hide who does what.
pub fn isNominalisation(word: []const u8) bool {
    if (word.len < 7) return false;
    const endings = [_][]const u8{ "ation", "ition", "ment", "ance", "ence", "ility", "ancy" };
    for (endings) |e| {
        if (std.mem.endsWith(u8, word, e)) return true;
    }
    return false;
}

pub const Word = struct {
    span: Span,
    text: []const u8,
    /// Index of the sentence this word belongs to.
    sentence: usize,
};

pub const Sentence = struct {
    span: Span,
    text: []const u8,
    words: usize,
    /// Index into the word list of the first word.
    first_word: usize,
};

pub const Analysis = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    sentences: []Sentence,
    words: []Word,
    paragraphs: []Span,

    pub fn wordCount(self: Analysis) usize {
        return self.words.len;
    }

    pub fn sentenceCount(self: Analysis) usize {
        return self.sentences.len;
    }

    pub fn meanSentenceWords(self: Analysis) f32 {
        if (self.sentences.len == 0) return 0;
        var total: usize = 0;
        for (self.sentences) |s| total += s.words;
        return @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(self.sentences.len));
    }

    pub fn wordsOf(self: Analysis, sentence_index: usize) []const Word {
        const sentence = self.sentences[sentence_index];
        var end = sentence.first_word;
        while (end < self.words.len and self.words[end].sentence == sentence_index) end += 1;
        return self.words[sentence.first_word..end];
    }
};

/// Split text into paragraphs, sentences and words.
///
/// The splitter knows about abbreviations with internal periods, decimal
/// numbers, ellipses and list markers, because a sentence splitter that breaks
/// on every period reports nonsense line numbers, and a rule nobody trusts gets
/// switched off.
pub fn analyse(arena: std.mem.Allocator, source: []const u8) !Analysis {
    var sentences: std.ArrayList(Sentence) = .empty;
    var words: std.ArrayList(Word) = .empty;
    var paragraphs: std.ArrayList(Span) = .empty;

    // Paragraphs are separated by a blank line.
    var para_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n' and i + 1 < source.len and source[i + 1] == '\n') {
            if (i > para_start) try paragraphs.append(arena, .{ .start = para_start, .end = i });
            var j = i;
            while (j < source.len and (source[j] == '\n' or source[j] == '\r' or source[j] == ' ')) j += 1;
            para_start = j;
            i = j - 1;
        }
    }
    if (para_start < source.len) try paragraphs.append(arena, .{ .start = para_start, .end = source.len });

    var sentence_start: usize = 0;
    var sentence_index: usize = 0;
    var word_start: ?usize = null;
    var words_in_sentence: usize = 0;
    var first_word_index: usize = 0;

    i = 0;
    while (i <= source.len) : (i += 1) {
        const c: u8 = if (i < source.len) source[i] else '\n';
        // A character that closes a sentence never belongs to the word before
        // it, otherwise the last word of every sentence lands in the next one.
        const sentence_end = i < source.len and isSentenceEnd(source, i);
        const is_word_char = !sentence_end and (std.ascii.isAlphanumeric(c) or c == '\'' or c == '-' or c == '_' or c == '/' or c == '.' or c == '{' or c == '}' or c == '%' or c == '$' or c == '+' or c == ':');

        if (is_word_char) {
            if (word_start == null) word_start = i;
        } else if (word_start) |start| {
            var end = i;
            // Trim trailing punctuation that got picked up by the loose rule.
            while (end > start and (source[end - 1] == '.' or source[end - 1] == ':' or source[end - 1] == '/')) end -= 1;
            if (end > start) {
                const text = source[start..end];
                if (containsLetterOrDigit(text)) {
                    if (words_in_sentence == 0) first_word_index = words.items.len;
                    try words.append(arena, .{ .span = .{ .start = start, .end = end }, .text = text, .sentence = sentence_index });
                    words_in_sentence += 1;
                }
            }
            word_start = null;
        }

        if (sentence_end) {
            const end = i + 1;
            const trimmed = std.mem.trim(u8, source[sentence_start..end], " \t\r\n");
            if (trimmed.len > 0 and words_in_sentence > 0) {
                try sentences.append(arena, .{
                    .span = .{ .start = sentence_start, .end = end },
                    .text = trimmed,
                    .words = words_in_sentence,
                    .first_word = first_word_index,
                });
                sentence_index += 1;
                words_in_sentence = 0;
            }
            sentence_start = end;
        } else if (i >= source.len or (c == '\n' and i + 1 < source.len and source[i + 1] == '\n')) {
            // A blank line also closes a sentence: headings and list items are
            // sentences for our purposes even without a full stop.
            const end = @min(i + 1, source.len);
            const trimmed = std.mem.trim(u8, source[sentence_start..end], " \t\r\n");
            if (trimmed.len > 0 and words_in_sentence > 0) {
                try sentences.append(arena, .{
                    .span = .{ .start = sentence_start, .end = end },
                    .text = trimmed,
                    .words = words_in_sentence,
                    .first_word = first_word_index,
                });
                sentence_index += 1;
                words_in_sentence = 0;
            }
            sentence_start = end;
        }
    }

    return .{
        .arena = arena,
        .source = source,
        .sentences = try sentences.toOwnedSlice(arena),
        .words = try words.toOwnedSlice(arena),
        .paragraphs = try paragraphs.toOwnedSlice(arena),
    };
}

fn containsLetterOrDigit(text: []const u8) bool {
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) return true;
    }
    return false;
}

fn isSentenceEnd(source: []const u8, i: usize) bool {
    const c = source[i];
    if (c != '.' and c != '!' and c != '?') return false;
    // "3.5" and "v1.2" are not sentence ends.
    if (c == '.' and i > 0 and i + 1 < source.len and std.ascii.isDigit(source[i - 1]) and std.ascii.isDigit(source[i + 1])) return false;
    // "e.g." and "i.e." are not sentence ends.
    if (c == '.' and i >= 3) {
        const tail = source[i - 3 .. i + 1];
        if (std.ascii.eqlIgnoreCase(tail, "e.g.") or std.ascii.eqlIgnoreCase(tail, "i.e.")) return false;
    }
    // An ellipsis counts once, at its last dot.
    if (c == '.' and i + 1 < source.len and source[i + 1] == '.') return false;
    // The end of the text, or whitespace, closes the sentence.
    if (i + 1 >= source.len) return true;
    const next = source[i + 1];
    return next == ' ' or next == '\n' or next == '\t' or next == '\r' or next == '"' or next == ')';
}

/// Estimated syllable count. English syllable counting is not exact; this is
/// the standard vowel-group heuristic, used only inside readability estimates
/// that are themselves reported as estimates.
pub fn syllables(word: []const u8) usize {
    var count: usize = 0;
    var previous_vowel = false;
    var letters: usize = 0;
    for (word) |raw| {
        const c = std.ascii.toLower(raw);
        if (!std.ascii.isAlphabetic(c)) continue;
        letters += 1;
        const vowel = c == 'a' or c == 'e' or c == 'i' or c == 'o' or c == 'u' or c == 'y';
        if (vowel and !previous_vowel) count += 1;
        previous_vowel = vowel;
    }
    if (letters == 0) return 0;
    // A silent trailing "e" does not add a syllable.
    if (letters > 2 and std.ascii.toLower(word[word.len - 1]) == 'e' and count > 1) count -= 1;
    return @max(count, 1);
}

/// Shape test for an abbreviation: two or more upper-case letters, optionally
/// with digits, and not a normal capitalised word.
pub fn looksLikeAbbreviation(word: []const u8) bool {
    if (word.len < 2 or word.len > 8) return false;
    var uppers: usize = 0;
    for (word) |c| {
        if (std.ascii.isLower(c)) return false;
        if (std.ascii.isUpper(c)) uppers += 1;
    }
    return uppers >= 2;
}

pub fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Case-insensitive whole-phrase search that returns the byte offset.
pub fn findPhrase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) continue;
        const before_ok = i == 0 or !isWordByte(haystack[i - 1]);
        const after = i + needle.len;
        const after_ok = after >= haystack.len or !isWordByte(haystack[after]);
        if (before_ok and after_ok) return i;
    }
    return null;
}

pub fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// Strip the punctuation people type around a word.
pub fn trimWord(word: []const u8) []const u8 {
    return std.mem.trim(u8, word, ".,;:!?\"'()[]{}");
}

test "splits sentences without breaking on decimals or abbreviations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try analyse(arena,
        "The agent ran 3.5 tests. It failed once, e.g. on the parser. Run it again?",
    );
    try std.testing.expectEqual(@as(usize, 3), a.sentenceCount());
    try std.testing.expect(std.mem.indexOf(u8, a.sentences[0].text, "3.5") != null);
}

test "counts words and paragraphs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try analyse(arena, "First paragraph here.\n\nSecond paragraph is longer than the first one.");
    try std.testing.expectEqual(@as(usize, 2), a.paragraphs.len);
    try std.testing.expectEqual(@as(usize, 2), a.sentenceCount());
    try std.testing.expectEqual(@as(usize, 3), a.sentences[0].words);
    const second = a.wordsOf(1);
    try std.testing.expectEqualStrings("Second", second[0].text);
}

test "heuristics identify the shapes the rules depend on" {
    try std.testing.expect(looksLikeAbbreviation("PTY"));
    try std.testing.expect(!looksLikeAbbreviation("Run"));
    try std.testing.expect(isCommonAbbreviation("JSON"));
    try std.testing.expect(isImperativeVerb("Run"));
    try std.testing.expect(isBeVerb("was"));
    try std.testing.expect(looksLikePastParticiple("executed"));
    try std.testing.expect(!looksLikePastParticiple("need"));
    try std.testing.expect(isNominalisation("initialisation"));
    try std.testing.expect(!isNominalisation("start"));
    try std.testing.expectEqual(@as(usize, 3), syllables("terminal"));
    try std.testing.expectEqual(@as(usize, 1), syllables("run"));
    try std.testing.expect(findPhrase("Please do this in order to continue", "in order to") != null);
    try std.testing.expect(findPhrase("reordering", "order") == null);
}

test "positions map back to line and column" {
    const text = "one\ntwo three\nfour";
    const p = positionOf(text, 8);
    try std.testing.expectEqual(@as(usize, 2), p.line);
    try std.testing.expectEqual(@as(usize, 5), p.column);
}
