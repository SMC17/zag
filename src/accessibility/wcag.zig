//! WCAG 2.2 success criteria, mapped to a desktop application and to
//! EN 301 549.
//!
//! WCAG was written for web content. Pretending that every criterion applies
//! unchanged to a GPU-drawn desktop application would be dishonest in both
//! directions: some criteria have no meaning here, and some need a different
//! test. So each criterion carries how it applies, how it is verified, and
//! which EN 301 549 clause covers it for procurement.
//!
//! ISO/IEC 40500:2025 adopts WCAG 2.2; the 2012 edition adopted WCAG 2.0 and is
//! withdrawn. The standards registry records that, and this catalogue targets
//! 2.2 directly.

const std = @import("std");

pub const Level = enum { a, aa, aaa };

pub const Applicability = enum {
    /// Applies to the desktop application as written.
    applies,
    /// Applies, but the test is different for a native surface.
    applies_adapted,
    /// Has no meaning for this product (no video, no page reload, no forms
    /// posting to a server).
    not_applicable,
};

pub const Verification = enum {
    /// A test in this repository checks it.
    automated,
    /// A person must judge it.
    manual,
    /// Both: a check finds some failures, a person settles the rest.
    mixed,
};

pub const Criterion = struct {
    /// Success criterion number, as WCAG writes it.
    number: []const u8,
    name: []const u8,
    level: Level,
    /// New in WCAG 2.2.
    added_in_22: bool = false,
    applicability: Applicability,
    verification: Verification,
    /// EN 301 549 clause, for procurement.
    en_301_549_clause: []const u8,
    /// How the workbench meets it, or why it does not apply.
    approach: []const u8,
    /// The check that covers it, when one exists.
    check_id: ?[]const u8 = null,
};

pub const criteria = [_]Criterion{
    .{
        .number = "1.1.1",
        .name = "Non-text Content",
        .level = .a,
        .applicability = .applies,
        .verification = .mixed,
        .en_301_549_clause = "9.1.1.1",
        .approach = "Every figure in generated documentation carries a text alternative, and the content checks refuse one without it. Icons in the interface carry an accessible name.",
        .check_id = "IM05",
    },
    .{
        .number = "1.3.1",
        .name = "Info and Relationships",
        .level = .a,
        .applicability = .applies_adapted,
        .verification = .mixed,
        .en_301_549_clause = "9.1.3.1",
        .approach = "Structure is published through the semantic tree rather than inferred from pixels: blocks, commands, output, dialogs and status regions each carry a role.",
        .check_id = "A11Y01",
    },
    .{
        .number = "1.3.2",
        .name = "Meaningful Sequence",
        .level = .a,
        .applicability = .applies,
        .verification = .automated,
        .en_301_549_clause = "9.1.3.2",
        .approach = "The reading order follows the block order, which follows the event log.",
        .check_id = "LOG-ORDER",
    },
    .{
        .number = "1.4.1",
        .name = "Use of Color",
        .level = .a,
        .applicability = .applies,
        .verification = .manual,
        .en_301_549_clause = "9.1.4.1",
        .approach = "A block's result is shown by its words as well as its colour: \"succeeded\", \"failed\", \"denied by policy\".",
    },
    .{
        .number = "1.4.3",
        .name = "Contrast (Minimum)",
        .level = .aa,
        .applicability = .applies,
        .verification = .automated,
        .en_301_549_clause = "9.1.4.3",
        .approach = "Every colour pair in the shipped themes is checked in the test suite.",
        .check_id = "CONTRAST-TEXT",
    },
    .{
        .number = "1.4.4",
        .name = "Resize Text",
        .level = .aa,
        .applicability = .applies_adapted,
        .verification = .manual,
        .en_301_549_clause = "9.1.4.4",
        .approach = "The interface scales with the font size the user chooses; the terminal grid reflows rather than clipping.",
    },
    .{
        .number = "1.4.10",
        .name = "Reflow",
        .level = .aa,
        .applicability = .applies_adapted,
        .verification = .mixed,
        .en_301_549_clause = "9.1.4.10",
        .approach = "The grid reflows on resize and keeps its content, which the terminal tests check.",
        .check_id = "GRID-RESIZE",
    },
    .{
        .number = "1.4.11",
        .name = "Non-text Contrast",
        .level = .aa,
        .applicability = .applies,
        .verification = .automated,
        .en_301_549_clause = "9.1.4.11",
        .approach = "Focus rings and block borders are checked against the 3:1 minimum.",
        .check_id = "CONTRAST-NON-TEXT",
    },
    .{
        .number = "1.4.12",
        .name = "Text Spacing",
        .level = .aa,
        .applicability = .applies_adapted,
        .verification = .manual,
        .en_301_549_clause = "9.1.4.12",
        .approach = "Line height and letter spacing are settings; the layout does not clip when they change.",
    },
    .{
        .number = "2.1.1",
        .name = "Keyboard",
        .level = .a,
        .applicability = .applies,
        .verification = .automated,
        .en_301_549_clause = "9.2.1.1",
        .approach = "Every interactive node in the semantic tree must be focusable, which the accessibility tests check.",
        .check_id = "A11Y02",
    },
    .{
        .number = "2.1.2",
        .name = "No Keyboard Trap",
        .level = .a,
        .applicability = .applies,
        .verification = .mixed,
        .en_301_549_clause = "9.2.1.2",
        .approach = "A full-screen program takes the keyboard, and one documented key returns it. That key is shown while the program runs.",
    },
    .{
        .number = "2.1.4",
        .name = "Character Key Shortcuts",
        .level = .a,
        .applicability = .applies,
        .verification = .manual,
        .en_301_549_clause = "9.2.1.4",
        .approach = "Single-character shortcuts exist only inside the command editor, and can be turned off.",
    },
    .{
        .number = "2.2.1",
        .name = "Timing Adjustable",
        .level = .a,
        .applicability = .applies,
        .verification = .manual,
        .en_301_549_clause = "9.2.2.1",
        .approach = "An approval request does not expire on its own. Tool timeouts are settings, and a timeout is reported rather than silently retried.",
    },
    .{
        .number = "2.2.2",
        .name = "Pause, Stop, Hide",
        .level = .a,
        .applicability = .applies,
        .verification = .manual,
        .en_301_549_clause = "9.2.2.2",
        .approach = "Streaming output can be paused, and animation can be turned off.",
    },
    .{
        .number = "2.3.1",
        .name = "Three Flashes or Below Threshold",
        .level = .a,
        .applicability = .applies,
        .verification = .manual,
        .en_301_549_clause = "9.2.3.1",
        .approach = "The interface does not flash. A program's own output can flash; the user can disable the visual bell.",
    },
    .{
        .number = "2.4.3",
        .name = "Focus Order",
        .level = .a,
        .applicability = .applies,
        .verification = .automated,
        .en_301_549_clause = "9.2.4.3",
        .approach = "Focus order follows the semantic tree, which is checked in the tests.",
        .check_id = "A11Y-ORDER",
    },
    .{
        .number = "2.4.7",
        .name = "Focus Visible",
        .level = .aa,
        .applicability = .applies,
        .verification = .automated,
        .en_301_549_clause = "9.2.4.7",
        .approach = "The focus indicator is drawn by the application and its contrast is checked.",
        .check_id = "A11Y24",
    },
    .{
        .number = "2.4.11",
        .name = "Focus Not Obscured (Minimum)",
        .level = .aa,
        .added_in_22 = true,
        .applicability = .applies,
        .verification = .automated,
        .en_301_549_clause = "9.2.4.11",
        .approach = "The accessibility check reports a focused node covered by an overlay.",
        .check_id = "A11Y23",
    },
    .{
        .number = "2.4.13",
        .name = "Focus Appearance",
        .level = .aaa,
        .added_in_22 = true,
        .applicability = .applies,
        .verification = .manual,
        .en_301_549_clause = "9.2.4.13",
        .approach = "The focus indicator is at least two pixels thick and meets the 3:1 contrast minimum against both states.",
    },
    .{
        .number = "2.5.7",
        .name = "Dragging Movements",
        .level = .aa,
        .added_in_22 = true,
        .applicability = .applies,
        .verification = .manual,
        .en_301_549_clause = "9.2.5.7",
        .approach = "Everything that can be done by dragging — resizing a split, moving a tab, selecting text — can also be done from the keyboard or a menu.",
    },
    .{
        .number = "2.5.8",
        .name = "Target Size (Minimum)",
        .level = .aa,
        .added_in_22 = true,
        .applicability = .applies,
        .verification = .automated,
        .en_301_549_clause = "9.2.5.8",
        .approach = "Interactive nodes are measured against the 24 by 24 minimum in the accessibility tests.",
        .check_id = "A11Y22",
    },
    .{
        .number = "3.1.1",
        .name = "Language of Page",
        .level = .a,
        .applicability = .applies_adapted,
        .verification = .automated,
        .en_301_549_clause = "9.3.1.1",
        .approach = "Every artefact carries a validated language tag, and published metadata states it.",
        .check_id = "LANG-TAG",
    },
    .{
        .number = "3.2.1",
        .name = "On Focus",
        .level = .a,
        .applicability = .applies,
        .verification = .manual,
        .en_301_549_clause = "9.3.2.1",
        .approach = "Moving focus never runs a command or changes a setting.",
    },
    .{
        .number = "3.2.6",
        .name = "Consistent Help",
        .level = .a,
        .added_in_22 = true,
        .applicability = .applies,
        .verification = .manual,
        .en_301_549_clause = "9.3.2.6",
        .approach = "Help is reached the same way from every surface, and the command palette always offers it.",
    },
    .{
        .number = "3.3.1",
        .name = "Error Identification",
        .level = .a,
        .applicability = .applies,
        .verification = .mixed,
        .en_301_549_clause = "9.3.3.1",
        .approach = "An error message names what failed and what to do next; the plain-language checks refuse one that does not.",
        .check_id = "PL022",
    },
    .{
        .number = "3.3.2",
        .name = "Labels or Instructions",
        .level = .a,
        .applicability = .applies,
        .verification = .mixed,
        .en_301_549_clause = "9.3.3.2",
        .approach = "Every control's label states its action, which the plain-language checks verify.",
        .check_id = "PL018",
    },
    .{
        .number = "3.3.7",
        .name = "Redundant Entry",
        .level = .a,
        .added_in_22 = true,
        .applicability = .applies,
        .verification = .manual,
        .en_301_549_clause = "9.3.3.7",
        .approach = "The workbench never asks twice for something it already has: a path, a branch, or an approval already granted for this workspace.",
    },
    .{
        .number = "3.3.8",
        .name = "Accessible Authentication (Minimum)",
        .level = .aa,
        .added_in_22 = true,
        .applicability = .applies,
        .verification = .manual,
        .en_301_549_clause = "9.3.3.8",
        .approach = "Signing in to a provider uses the operating system's credential store or a copy-and-paste token. No puzzle, no transcription test.",
    },
    .{
        .number = "4.1.2",
        .name = "Name, Role, Value",
        .level = .a,
        .applicability = .applies,
        .verification = .automated,
        .en_301_549_clause = "9.4.1.2",
        .approach = "The semantic tree publishes a role, a name and a state for every node, and the tests refuse a node that needs a name and has none.",
        .check_id = "A11Y01",
    },
    .{
        .number = "4.1.3",
        .name = "Status Messages",
        .level = .aa,
        .applicability = .applies,
        .verification = .automated,
        .en_301_549_clause = "9.4.1.3",
        .approach = "A finished command, a failed command and a waiting approval are announced through a live region.",
        .check_id = "A11Y04",
    },
    .{
        .number = "1.2.2",
        .name = "Captions (Prerecorded)",
        .level = .a,
        .applicability = .not_applicable,
        .verification = .manual,
        .en_301_549_clause = "9.1.2.2",
        .approach = "The product contains no audio or video content. If documentation gains a video, this becomes applicable.",
    },
    .{
        .number = "3.3.4",
        .name = "Error Prevention (Legal, Financial, Data)",
        .level = .aa,
        .applicability = .applies,
        .verification = .mixed,
        .en_301_549_clause = "9.3.3.4",
        .approach = "An action that cannot be undone stops and asks, naming exactly what will happen.",
        .check_id = "PL028",
    },
};

pub fn byNumber(number: []const u8) ?Criterion {
    for (criteria) |criterion| {
        if (std.mem.eql(u8, criterion.number, number)) return criterion;
    }
    return null;
}

pub fn atLevel(arena: std.mem.Allocator, level: Level) !std.ArrayList(Criterion) {
    var out: std.ArrayList(Criterion) = .empty;
    for (criteria) |criterion| {
        const include = switch (level) {
            .a => criterion.level == .a,
            .aa => criterion.level == .a or criterion.level == .aa,
            .aaa => true,
        };
        if (include) try out.append(arena, criterion);
    }
    return out;
}

pub const Summary = struct {
    total: usize,
    applicable: usize,
    automated: usize,
    manual: usize,
    mixed: usize,
    not_applicable: usize,
};

pub fn summarise(level: Level) Summary {
    var summary: Summary = .{ .total = 0, .applicable = 0, .automated = 0, .manual = 0, .mixed = 0, .not_applicable = 0 };
    for (criteria) |criterion| {
        const include = switch (level) {
            .a => criterion.level == .a,
            .aa => criterion.level == .a or criterion.level == .aa,
            .aaa => true,
        };
        if (!include) continue;
        summary.total += 1;
        switch (criterion.applicability) {
            .not_applicable => summary.not_applicable += 1,
            else => summary.applicable += 1,
        }
        if (criterion.applicability == .not_applicable) continue;
        switch (criterion.verification) {
            .automated => summary.automated += 1,
            .manual => summary.manual += 1,
            .mixed => summary.mixed += 1,
        }
    }
    return summary;
}

/// The accessibility statement. It says what is checked automatically, what a
/// person still has to test, and what does not apply — never a claim of
/// conformance the evidence does not support.
pub fn writeStatement(w: *std.Io.Writer, level: Level) !void {
    const summary = summarise(level);
    try w.print("Accessibility of the zag workbench, against WCAG 2.2 level {s}\n\n", .{@tagName(level)});
    try w.print("Criteria considered: {d}\n", .{summary.total});
    try w.print("  Apply to this product:  {d}\n", .{summary.applicable});
    try w.print("  Do not apply:           {d}\n", .{summary.not_applicable});
    try w.print("  Checked by a test:      {d}\n", .{summary.automated});
    try w.print("  Partly checked:         {d}\n", .{summary.mixed});
    try w.print("  Settled by a person:    {d}\n\n", .{summary.manual});

    try w.writeAll("Each criterion, and how it is met:\n\n");
    for (criteria) |criterion| {
        const include = switch (level) {
            .a => criterion.level == .a,
            .aa => criterion.level == .a or criterion.level == .aa,
            .aaa => true,
        };
        if (!include) continue;
        try w.print("{s} {s} (level {s}", .{ criterion.number, criterion.name, @tagName(criterion.level) });
        if (criterion.added_in_22) try w.writeAll(", new in 2.2");
        try w.print(", EN 301 549 clause {s})\n", .{criterion.en_301_549_clause});
        try w.print("    {s}\n", .{criterion.approach});
        try w.print("    How it is checked: {s}", .{@tagName(criterion.verification)});
        if (criterion.check_id) |check| try w.print(" ({s})", .{check});
        try w.writeAll("\n\n");
    }
    try w.writeAll(
        \\A test can find a missing name, a small target or a low contrast ratio.
        \\It cannot find out whether a person using a screen reader can complete a
        \\task. That is settled by testing with people who use these tools.
        \\
    );
}

const testing = std.testing;

test "the catalogue covers the criteria WCAG 2.2 added" {
    const added = [_][]const u8{ "2.4.11", "2.4.13", "2.5.7", "2.5.8", "3.2.6", "3.3.7", "3.3.8" };
    for (added) |number| {
        const criterion = byNumber(number) orelse {
            std.debug.print("missing criterion {s}\n", .{number});
            return error.TestUnexpectedResult;
        };
        try testing.expect(criterion.added_in_22);
        try testing.expect(criterion.en_301_549_clause.len > 0);
    }
}

test "levels filter as the standard nests them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try atLevel(arena, .a);
    const aa = try atLevel(arena, .aa);
    const aaa = try atLevel(arena, .aaa);
    try testing.expect(a.items.len < aa.items.len);
    try testing.expect(aa.items.len <= aaa.items.len);
    for (a.items) |criterion| try testing.expectEqual(Level.a, criterion.level);
}

test "every criterion says how it is verified and what it means here" {
    for (criteria) |criterion| {
        try testing.expect(criterion.approach.len > 0);
        try testing.expect(criterion.en_301_549_clause.len > 0);
        // A criterion claimed as automated must name the check that does it.
        if (criterion.verification == .automated and criterion.applicability != .not_applicable) {
            try testing.expect(criterion.check_id != null);
        }
        // Anything not applicable must say why, and say when it would become
        // applicable.
        if (criterion.applicability == .not_applicable) {
            try testing.expect(std.mem.indexOf(u8, criterion.approach, "no") != null or
                std.mem.indexOf(u8, criterion.approach, "If") != null);
        }
    }
}

test "the statement separates what is tested from what is judged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeStatement(&aw.writer, .aa);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "Settled by a person") != null);
    try testing.expect(std.mem.indexOf(u8, text, "testing with people who use these tools") != null);
    try testing.expect(std.mem.indexOf(u8, text, "EN 301 549 clause 9.2.5.8") != null);
    // Level AAA criteria are not claimed at level AA.
    try testing.expect(std.mem.indexOf(u8, text, "2.4.13") == null);
}
