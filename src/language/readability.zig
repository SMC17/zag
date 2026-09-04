//! Readability estimates.
//!
//! These numbers are estimates and are reported as estimates. A reading-ease
//! score counts syllables; it cannot tell whether a reader can act on a
//! sentence. ISO 24495-1 asks for evaluation with readers, and no formula
//! substitutes for that. The scores are useful for one thing only: noticing
//! that a page has drifted a long way from its intended audience.

const std = @import("std");
const text = @import("text.zig");

pub const Metrics = struct {
    words: usize,
    sentences: usize,
    syllables: usize,
    long_words: usize,
    mean_sentence_words: f32,
    mean_syllables_per_word: f32,

    /// Flesch Reading Ease. Higher is easier. English only.
    pub fn fleschReadingEase(self: Metrics) f32 {
        if (self.words == 0 or self.sentences == 0) return 0;
        return 206.835 - 1.015 * self.mean_sentence_words - 84.6 * self.mean_syllables_per_word;
    }

    /// Flesch-Kincaid grade level, in United States school years.
    pub fn fleschKincaidGrade(self: Metrics) f32 {
        if (self.words == 0 or self.sentences == 0) return 0;
        return 0.39 * self.mean_sentence_words + 11.8 * self.mean_syllables_per_word - 15.59;
    }

    /// Share of words with three or more syllables.
    pub fn longWordShare(self: Metrics) f32 {
        if (self.words == 0) return 0;
        return @as(f32, @floatFromInt(self.long_words)) / @as(f32, @floatFromInt(self.words));
    }

    /// A short, non-numeric description, because a bare score invites people to
    /// treat it as a target.
    pub fn describe(self: Metrics) []const u8 {
        const ease = self.fleschReadingEase();
        if (ease >= 70) return "reads easily for a general audience";
        if (ease >= 50) return "reads comfortably for a practitioner audience";
        if (ease >= 30) return "demands close reading";
        return "reads as dense technical prose";
    }
};

pub fn measure(analysis: text.Analysis) Metrics {
    var syllable_count: usize = 0;
    var long_words: usize = 0;
    for (analysis.words) |w| {
        const s = text.syllables(w.text);
        syllable_count += s;
        if (s >= 3) long_words += 1;
    }
    const words = analysis.words.len;
    const sentences = analysis.sentences.len;
    return .{
        .words = words,
        .sentences = sentences,
        .syllables = syllable_count,
        .long_words = long_words,
        .mean_sentence_words = if (sentences == 0) 0 else @as(f32, @floatFromInt(words)) / @as(f32, @floatFromInt(sentences)),
        .mean_syllables_per_word = if (words == 0) 0 else @as(f32, @floatFromInt(syllable_count)) / @as(f32, @floatFromInt(words)),
    };
}

/// The statement that must accompany any published readability figure.
pub const caveat =
    "Readability scores are estimates from sentence and syllable counts. " ++
    "They do not show whether a reader can find, understand or use the information. " ++
    "Only testing with readers shows that.";

test "plain text scores higher than dense text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = try text.analyse(arena, "Run the test. It takes ten seconds. If it fails, read the log.");
    const dense = try text.analyse(arena, "Subsequent to the initialisation of the instrumentation subsystem, the aggregated telemetry constituents undergo normalisation procedures prior to persistence.");

    const plain_metrics = measure(plain);
    const dense_metrics = measure(dense);
    try std.testing.expect(plain_metrics.fleschReadingEase() > dense_metrics.fleschReadingEase());
    try std.testing.expect(plain_metrics.fleschKincaidGrade() < dense_metrics.fleschKincaidGrade());
    try std.testing.expect(dense_metrics.longWordShare() > plain_metrics.longWordShare());
}

test "metrics stay defined for empty text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty = try text.analyse(arena, "");
    const m = measure(empty);
    try std.testing.expectEqual(@as(f32, 0), m.fleschReadingEase());
    try std.testing.expectEqual(@as(f32, 0), m.longWordShare());
}

test "descriptions avoid presenting a score as a target" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try text.analyse(arena, "Open the file. Read it. Close it.");
    const m = measure(a);
    try std.testing.expect(m.describe().len > 0);
    try std.testing.expect(std.mem.indexOf(u8, caveat, "testing with readers") != null);
}
