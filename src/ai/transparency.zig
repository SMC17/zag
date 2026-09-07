//! Transparency (ISO/IEC 12792) and the CLeAR documentation goals.
//!
//! Transparency is not one thing. It is a set of answers, each owed to a
//! particular audience, at a particular moment. A person deciding whether to
//! approve an action needs a different answer, at a different time, from an
//! auditor reading the record a year later. This module names those obligations
//! so that the generated documentation can be checked against them.

const std = @import("std");

/// Who the information is for.
pub const Audience = enum {
    /// The person using the system.
    user,
    /// The person or team running it for others.
    operator,
    /// Someone affected by what the system does, who did not choose it.
    affected_person,
    /// A reviewer, auditor or regulator.
    oversight,
    /// A developer integrating with it.
    integrator,
};

/// When the information must be available.
pub const Timing = enum {
    /// Before anyone uses the system.
    before_use,
    /// While the system is doing the thing.
    at_the_moment,
    /// After the fact, on request.
    on_request,
    /// Whenever something goes wrong.
    on_incident,
};

/// What is being disclosed. These are the categories ISO/IEC 12792 organises
/// transparency information into, reduced to the ones this system can answer.
pub const Topic = enum {
    system_purpose,
    ai_involvement,
    data_used,
    model_identity,
    capabilities_and_limits,
    decision_basis,
    human_role,
    performance,
    risks_and_mitigations,
    provenance,
    redress,

    pub fn question(self: Topic) []const u8 {
        return switch (self) {
            .system_purpose => "What is this system for?",
            .ai_involvement => "Where is a model involved in what I see?",
            .data_used => "What information does it read, and where does that go?",
            .model_identity => "Which model produced this, and which version?",
            .capabilities_and_limits => "What can it do, and what can it not do?",
            .decision_basis => "Why did it do that?",
            .human_role => "What can a person change or stop?",
            .performance => "How well does it work, and how was that measured?",
            .risks_and_mitigations => "What could go wrong, and what is done about it?",
            .provenance => "Where did this output come from?",
            .redress => "What do I do if it is wrong?",
        };
    }
};

pub const Obligation = struct {
    topic: Topic,
    audience: Audience,
    timing: Timing,
    /// Where the answer lives: a screen, a document, a command.
    answered_by: []const u8,
    /// Whether the system produces this answer today.
    satisfied: bool,
    /// What is missing, when it is not satisfied.
    gap: []const u8 = "",
};

/// The four CLeAR documentation goals, used to judge a generated document
/// rather than to score it.
pub const ClearGoal = enum {
    /// The same document shape, so two systems can be compared.
    comparable,
    /// A reader can actually read it.
    legible,
    /// It says what a reader can do next.
    actionable,
    /// It states its own limits and when it was produced.
    robust,

    pub fn describe(self: ClearGoal) []const u8 {
        return switch (self) {
            .comparable => "Two systems documented this way can be set side by side.",
            .legible => "The intended reader can read it without a glossary.",
            .actionable => "It tells the reader what they can do with what it says.",
            .robust => "It says how it was produced, when, and what it does not cover.",
        };
    }
};

pub const ClearFinding = struct {
    goal: ClearGoal,
    message: []const u8,
};

/// Check a produced document against the CLeAR goals. This is a structural
/// check, not a judgement of the writing: the plain-language pass does that.
pub fn reviewClear(arena: std.mem.Allocator, document: []const u8, required_headings: []const []const u8) !std.ArrayList(ClearFinding) {
    var findings: std.ArrayList(ClearFinding) = .empty;

    for (required_headings) |heading| {
        if (std.mem.indexOf(u8, document, heading) == null) {
            try findings.append(arena, .{
                .goal = .comparable,
                .message = try std.fmt.allocPrint(arena, "The section \"{s}\" is missing, so this document cannot be compared with another.", .{heading}),
            });
        }
    }

    // Legible: no unexplained wall of text. A document with no blank lines is
    // one paragraph, whatever its length.
    if (document.len > 1200 and std.mem.indexOf(u8, document, "\n\n") == null) {
        try findings.append(arena, .{
            .goal = .legible,
            .message = "The document is one unbroken block. Break it into sections a reader can scan.",
        });
    }

    // Actionable: it must tell the reader what to do.
    const action_markers = [_][]const u8{ "What you can do", "you can ", "To report", "Contact", "raise" };
    var actionable = false;
    for (action_markers) |marker| {
        if (std.mem.indexOf(u8, document, marker) != null) actionable = true;
    }
    if (!actionable) {
        try findings.append(arena, .{
            .goal = .actionable,
            .message = "The document does not say what the reader can do with it. Add what to check, who to ask, or how to report a problem.",
        });
    }

    // Robust: limits and a date.
    if (std.mem.indexOf(u8, document, "not") == null and std.mem.indexOf(u8, document, "limit") == null) {
        try findings.append(arena, .{
            .goal = .robust,
            .message = "The document does not state any limit. A document with no limits is not describing a real system.",
        });
    }
    if (std.mem.indexOf(u8, document, "20") == null) {
        try findings.append(arena, .{
            .goal = .robust,
            .message = "The document carries no date, so a reader cannot tell whether it is current.",
        });
    }

    return findings;
}

/// The transparency obligations the workbench takes on, and whether it meets
/// them. An unmet obligation stays in the list with its gap stated.
pub const workbench_obligations = [_]Obligation{
    .{ .topic = .system_purpose, .audience = .user, .timing = .before_use, .answered_by = "README and `zag doctor`", .satisfied = true },
    .{ .topic = .ai_involvement, .audience = .user, .timing = .at_the_moment, .answered_by = "Every agent block names the actor and the model", .satisfied = true },
    .{ .topic = .data_used, .audience = .user, .timing = .at_the_moment, .answered_by = "The approval prompt for the model capability names what leaves the machine", .satisfied = true },
    .{ .topic = .model_identity, .audience = .oversight, .timing = .on_request, .answered_by = "Provenance on every generated artefact", .satisfied = true },
    .{ .topic = .capabilities_and_limits, .audience = .user, .timing = .before_use, .answered_by = "The policy description shown when a session starts", .satisfied = true },
    .{ .topic = .decision_basis, .audience = .user, .timing = .on_request, .answered_by = "The execution graph for the run", .satisfied = true },
    .{ .topic = .human_role, .audience = .user, .timing = .before_use, .answered_by = "The impact assessment and the approval options", .satisfied = true },
    .{ .topic = .performance, .audience = .oversight, .timing = .on_request, .answered_by = "`zag report quality`", .satisfied = true },
    .{ .topic = .risks_and_mitigations, .audience = .oversight, .timing = .on_request, .answered_by = "The risk register", .satisfied = true },
    .{ .topic = .provenance, .audience = .integrator, .timing = .on_request, .answered_by = "PROV-O export of any artefact", .satisfied = true },
    .{
        .topic = .redress,
        .audience = .affected_person,
        .timing = .on_incident,
        .answered_by = "docs/if-something-is-wrong.md",
        .satisfied = true,
    },
};

pub fn unmetObligations(arena: std.mem.Allocator) !std.ArrayList(Obligation) {
    var out: std.ArrayList(Obligation) = .empty;
    for (workbench_obligations) |obligation| {
        if (!obligation.satisfied) try out.append(arena, obligation);
    }
    return out;
}

const testing = std.testing;

test "every transparency topic asks a question a person would ask" {
    inline for (std.meta.fields(Topic)) |field| {
        const topic: Topic = @enumFromInt(field.value);
        const question = topic.question();
        try testing.expect(question.len > 0);
        try testing.expectEqual(@as(u8, '?'), question[question.len - 1]);
    }
}

test "every obligation names where its answer lives" {
    // An obligation that says it is met has to say where. "Somebody could ask
    // us" is not an answer to "what do I do if it is wrong", and the field
    // exists so that claiming to have met one costs writing the page.
    for (workbench_obligations) |obligation| {
        try testing.expect(obligation.answered_by.len > 0);
        if (!obligation.satisfied) try testing.expect(obligation.gap.len > 0);
    }
}

test "unmet obligations are listed rather than hidden" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every obligation is met today, and each one says where. When one is not,
    // it appears here with its gap, and `zag check` counts it as a problem —
    // it used to print the gap and leave the count at zero, so the build stayed
    // green while listing what it had not done.
    const unmet = try unmetObligations(arena);
    for (unmet.items) |obligation| {
        try testing.expect(obligation.gap.len > 0);
    }
    try testing.expectEqual(@as(usize, 0), unmet.items.len);
}

test "the clear review finds a document that cannot be compared or acted on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const thin = "This system is good.";
    const findings = try reviewClear(arena, thin, &.{ "What it is for", "Limits" });
    try testing.expect(findings.items.len >= 3);

    var saw_comparable = false;
    var saw_actionable = false;
    for (findings.items) |finding| {
        if (finding.goal == .comparable) saw_comparable = true;
        if (finding.goal == .actionable) saw_actionable = true;
    }
    try testing.expect(saw_comparable);
    try testing.expect(saw_actionable);
}
