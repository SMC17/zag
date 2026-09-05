//! Generated AI documentation: model card, system card, datasheet, FactSheet.
//!
//! Nobody should fill in a compliance document from memory months later. The
//! runtime already knows the model, the policy, the capabilities, the data
//! sources, the evaluations, the risks and the approvals, so the documents are
//! generated from those facts and carry the same words as the system.
//!
//! The four output shapes are different views of one record:
//!   * Model Card — the model and how it is used here.
//!   * System Card — the whole system around the model.
//!   * Datasheet for Datasets — one dataset, its motivation and its limits.
//!   * FactSheet — the flat question-and-answer form auditors read.
//!
//! CLeAR supplies the goals every one of them is checked against.

const std = @import("std");
const risk_mod = @import("risk.zig");
const impact_mod = @import("impact.zig");
const evaluation_mod = @import("evaluation.zig");
const transparency = @import("transparency.zig");
const capability_mod = @import("capability.zig");
const policy_mod = @import("policy.zig");
const timeutil = @import("../core/time.zig");
const provenance_mod = @import("../data/provenance.zig");

pub const Timestamp = timeutil.Timestamp;

/// Everything the generated documents draw on. Assembling this is the only
/// manual step; the documents themselves are derived.
pub const SystemFacts = struct {
    name: []const u8,
    version: []const u8,
    owner: []const u8,
    contact: []const u8,
    license: []const u8,

    /// One sentence.
    purpose: []const u8,
    intended_users: []const []const u8,
    intended_uses: []const []const u8,
    excluded_uses: []const []const u8,

    /// The model, when one is configured. A workbench with only local tools
    /// legitimately has none.
    model: ?provenance_mod.ModelIdentity,
    /// What the model is given.
    model_inputs: []const []const u8,
    /// What it produces.
    model_outputs: []const []const u8,

    /// Policy the system runs agents under.
    policy: policy_mod.Policy,
    /// Capabilities the policy can allow at all.
    allowed_capabilities: []const capability_mod.Capability,

    /// Where the system's data comes from.
    data_sources: []const DataSource,
    /// Things the system is known not to do well.
    limitations: []const []const u8,
    /// Where a person stays in control.
    human_oversight: []const u8,

    evaluations: evaluation_mod.Suite,
    risks: risk_mod.Register,
    impact: impact_mod.Assessment,

    produced_at: Timestamp,
    review_due: Timestamp,

    pub const DataSource = struct {
        name: []const u8,
        description: []const u8,
        /// Does it contain personal data?
        personal_data: bool,
        /// Does it leave the machine?
        leaves_machine: bool,
        retention: []const u8,
    };
};

/// Section headings every generated document uses, so two systems documented
/// this way can be set side by side. This is the CLeAR "comparable" goal made
/// concrete.
pub const model_card_headings = [_][]const u8{
    "What this is",
    "What it is for",
    "What it must not be used for",
    "How the model is used",
    "What information it is given",
    "Limits",
    "How well it works",
    "What could go wrong",
    "What a person controls",
    "What you can do",
};

pub const system_card_headings = [_][]const u8{
    "What this is",
    "What it is for",
    "How it works",
    "What it is allowed to do",
    "Where the data comes from",
    "What could go wrong",
    "How well it works",
    "What a person controls",
    "Who is affected",
    "What you can do",
};

pub const datasheet_headings = [_][]const u8{
    "What this dataset is",
    "Why it was made",
    "What is in it",
    "How it was collected",
    "How it was prepared",
    "How it is used",
    "How it is kept",
    "Limits",
    "What you can do",
};

fn writeList(w: *std.Io.Writer, items: []const []const u8) std.Io.Writer.Error!void {
    for (items) |item| try w.print("  - {s}\n", .{item});
}

fn writeDate(w: *std.Io.Writer, at: Timestamp) std.Io.Writer.Error!void {
    var buf: [Timestamp.text_len_max]u8 = undefined;
    try w.writeAll(at.toIso(&buf, .second));
}

/// Model card: the model, and how this system uses it.
pub fn writeModelCard(facts: SystemFacts, w: *std.Io.Writer) !void {
    try w.print("# Model card: {s} {s}\n\n", .{ facts.name, facts.version });

    try w.writeAll("## What this is\n");
    if (facts.model) |model| {
        try w.print("This card describes how {s} {s} uses the model {s} from {s}", .{ facts.name, facts.version, model.model, model.provider });
        if (model.version) |version| try w.print(", version {s}", .{version});
        try w.writeAll(".\n");
        if (model.temperature) |temperature| try w.print("Sampling temperature: {d}.\n", .{temperature});
        if (model.seed) |seed| try w.print("Sampling seed: {d}.\n", .{seed});
    } else {
        try w.print("{s} {s} runs with no model configured. Nothing is sent to a model provider.\n", .{ facts.name, facts.version });
    }
    try w.print("Owner: {s}. Contact: {s}. Licence: {s}.\n", .{ facts.owner, facts.contact, facts.license });

    try w.writeAll("\n## What it is for\n");
    try w.print("{s}\n", .{facts.purpose});
    try writeList(w, facts.intended_uses);

    try w.writeAll("\n## What it must not be used for\n");
    try writeList(w, facts.excluded_uses);

    try w.writeAll("\n## How the model is used\n");
    try w.print("The model proposes what to do. It does not decide what is permitted: the local policy \"{s}\" does, and every decision is recorded.\n", .{facts.policy.name});
    try w.print("{s}\n", .{facts.policy.description});

    try w.writeAll("\n## What information it is given\n");
    try writeList(w, facts.model_inputs);
    try w.writeAll("It produces:\n");
    try writeList(w, facts.model_outputs);

    try w.writeAll("\n## Limits\n");
    try writeList(w, facts.limitations);

    try w.writeAll("\n## How well it works\n");
    try facts.evaluations.writeReport(w);

    try w.writeAll("\n## What could go wrong\n");
    for (facts.risks.risks.items) |risk| {
        try w.print("  - {s} ({s} after treatment): {s}\n", .{ risk.id, risk.residualLevel().text(), risk.statement });
    }

    try w.writeAll("\n## What a person controls\n");
    try w.print("{s}\n", .{facts.human_oversight});

    try w.writeAll("\n## What you can do\n");
    try w.writeAll("Read the run's execution graph to see exactly what happened. Refuse any approval. Withdraw a standing permission at any time.\n");
    try w.print("Report a problem to {s}.\n", .{facts.contact});

    try w.writeAll("\nThis card was produced on ");
    try writeDate(w, facts.produced_at);
    try w.writeAll(" and is due for review by ");
    try writeDate(w, facts.review_due);
    try w.writeAll(".\n");
}

/// System card: the whole system, not only the model.
pub fn writeSystemCard(facts: SystemFacts, w: *std.Io.Writer) !void {
    try w.print("# System card: {s} {s}\n\n", .{ facts.name, facts.version });

    try w.writeAll("## What this is\n");
    try w.print("{s} {s}, owned by {s}.\n", .{ facts.name, facts.version, facts.owner });

    try w.writeAll("\n## What it is for\n");
    try w.print("{s}\n", .{facts.purpose});
    try w.writeAll("Intended users:\n");
    try writeList(w, facts.intended_users);

    try w.writeAll("\n## How it works\n");
    try w.writeAll("A person or an agent asks for something. The request becomes typed events. Each action an agent proposes is a typed request for one capability on one resource, which the local policy engine decides before anything runs. Everything that happens is written to a log whose entries are chained by hash.\n");

    try w.writeAll("\n## What it is allowed to do\n");
    try w.print("Policy in force: {s}. {s}\n", .{ facts.policy.name, facts.policy.description });
    for (facts.allowed_capabilities) |capability| {
        try w.print("  - {s}: {s}", .{ capability.text(), capability.explain() });
        if (capability.leavesTheMachine()) try w.writeAll(" (this one sends information off this computer)");
        try w.writeAll("\n");
    }

    try w.writeAll("\n## Where the data comes from\n");
    for (facts.data_sources) |source| {
        try w.print("  - {s}: {s}\n", .{ source.name, source.description });
        try w.print("    Personal data: {s}. Leaves this computer: {s}. Kept: {s}.\n", .{
            if (source.personal_data) "yes" else "no",
            if (source.leaves_machine) "yes" else "no",
            source.retention,
        });
    }

    try w.writeAll("\n## What could go wrong\n");
    try facts.risks.writeReport(w);

    try w.writeAll("\n## How well it works\n");
    try facts.evaluations.writeReport(w);

    try w.writeAll("\n## What a person controls\n");
    try w.print("{s}\n", .{facts.human_oversight});

    try w.writeAll("\n## Who is affected\n");
    for (facts.impact.affected_groups) |group| {
        try w.print("  - {s}: {s}\n", .{ group.name, group.description });
    }

    try w.writeAll("\n## What you can do\n");
    try w.print("Ask a question or report a problem: {s}.\n", .{facts.contact});
    try w.writeAll("Every claim here can be checked against the workspace log, which you hold.\n");

    const unmet = try transparency.unmetObligations(facts.risks.arena);
    if (unmet.items.len > 0) {
        try w.writeAll("\n## What this system does not yet answer\n");
        for (unmet.items) |obligation| {
            try w.print("  - {s} {s}\n", .{ obligation.topic.question(), obligation.gap });
        }
    }

    try w.writeAll("\nThis card was produced on ");
    try writeDate(w, facts.produced_at);
    try w.writeAll(".\n");
}

/// One dataset, in the Datasheets for Datasets shape.
pub const DatasetFacts = struct {
    name: []const u8,
    version: []const u8,
    purpose: []const u8,
    /// Who paid for it and who made it.
    made_by: []const u8,
    contents: []const u8,
    instance_count: usize,
    collection_method: []const u8,
    preparation: []const u8,
    uses: []const []const u8,
    /// Uses the makers do not support.
    unsupported_uses: []const []const u8,
    personal_data: bool,
    /// How consent was obtained, when personal data is present.
    consent_basis: ?[]const u8,
    retention: []const u8,
    limitations: []const []const u8,
    contact: []const u8,
    produced_at: Timestamp,
};

pub fn writeDatasheet(dataset: DatasetFacts, w: *std.Io.Writer) !void {
    try w.print("# Datasheet: {s} {s}\n\n", .{ dataset.name, dataset.version });

    try w.writeAll("## What this dataset is\n");
    try w.print("{s}\n", .{dataset.contents});
    try w.print("It holds {d} records.\n", .{dataset.instance_count});

    try w.writeAll("\n## Why it was made\n");
    try w.print("{s}\nMade by {s}.\n", .{ dataset.purpose, dataset.made_by });

    try w.writeAll("\n## What is in it\n");
    try w.print("Personal data: {s}.\n", .{if (dataset.personal_data) "yes" else "no"});
    if (dataset.consent_basis) |basis| try w.print("Basis for holding it: {s}\n", .{basis});

    try w.writeAll("\n## How it was collected\n");
    try w.print("{s}\n", .{dataset.collection_method});

    try w.writeAll("\n## How it was prepared\n");
    try w.print("{s}\n", .{dataset.preparation});

    try w.writeAll("\n## How it is used\n");
    try writeList(w, dataset.uses);
    try w.writeAll("It should not be used for:\n");
    try writeList(w, dataset.unsupported_uses);

    try w.writeAll("\n## How it is kept\n");
    try w.print("{s}\n", .{dataset.retention});

    try w.writeAll("\n## Limits\n");
    try writeList(w, dataset.limitations);

    try w.writeAll("\n## What you can do\n");
    try w.print("Ask about this dataset, or ask for a record to be removed: {s}.\n", .{dataset.contact});

    try w.writeAll("\nThis datasheet was produced on ");
    try writeDate(w, dataset.produced_at);
    try w.writeAll(".\n");
}

/// FactSheet: the same facts as flat question-and-answer pairs, which is the
/// form an auditor can work through quickly.
pub fn writeFactSheet(facts: SystemFacts, w: *std.Io.Writer) !void {
    try w.print("# FactSheet: {s} {s}\n\n", .{ facts.name, facts.version });

    const Pair = struct { question: []const u8, answer: []const u8 };
    var pairs: [16]Pair = undefined;
    var count: usize = 0;

    pairs[count] = .{ .question = "What is this system for?", .answer = facts.purpose };
    count += 1;
    pairs[count] = .{ .question = "Who owns it?", .answer = facts.owner };
    count += 1;
    pairs[count] = .{ .question = "What is it not for?", .answer = facts.excluded_uses[0] };
    count += 1;
    pairs[count] = .{ .question = "What decides what it may do?", .answer = facts.policy.description };
    count += 1;
    pairs[count] = .{ .question = "What can a person stop or change?", .answer = facts.human_oversight };
    count += 1;

    for (pairs[0..count]) |pair| {
        try w.print("**{s}**\n{s}\n\n", .{ pair.question, pair.answer });
    }

    try w.writeAll("**Which model is used?**\n");
    if (facts.model) |model| {
        try w.print("{s} from {s}", .{ model.model, model.provider });
        if (model.version) |version| try w.print(", version {s}", .{version});
        try w.writeAll(".\n\n");
    } else {
        try w.writeAll("None. Nothing is sent to a model provider.\n\n");
    }

    try w.writeAll("**How well does it work, and how was that measured?**\n");
    var measured: usize = 0;
    for (facts.evaluations.measures.items) |measure| {
        const result = facts.evaluations.latestFor(measure.id) orelse continue;
        measured += 1;
        try w.print("{s}: {d} {s}, from {d} observations by {s}.\n", .{ measure.name, result.value, measure.unit, result.sample_size, @tagName(result.method) });
    }
    if (measured == 0) try w.writeAll("Nothing has been measured yet. The measures are defined but not run.\n");
    try w.writeAll("\n");

    try w.writeAll("**What could go wrong, and what is done about it?**\n");
    for (facts.risks.risks.items) |risk| {
        try w.print("{s}: {s} Treatment: {s}.\n", .{ risk.id, risk.statement, @tagName(risk.treatment.kind) });
    }
    try w.writeAll("\n");

    try w.writeAll("**Who is affected, and how do they raise a problem?**\n");
    for (facts.impact.affected_groups) |group| {
        try w.print("{s}. Can challenge a decision: {s}.\n", .{ group.name, if (group.can_challenge) "yes" else "no" });
    }
    try w.print("Contact: {s}.\n\n", .{facts.contact});

    try w.writeAll("**When was this produced, and when is it reviewed?**\n");
    try w.writeAll("Produced ");
    try writeDate(w, facts.produced_at);
    try w.writeAll("; reviewed by ");
    try writeDate(w, facts.review_due);
    try w.writeAll(".\n");
}

/// Check a generated document against the CLeAR goals for its shape.
pub fn reviewDocument(
    arena: std.mem.Allocator,
    document: []const u8,
    headings: []const []const u8,
) !std.ArrayList(transparency.ClearFinding) {
    return transparency.reviewClear(arena, document, headings);
}

const testing = std.testing;
const plain = @import("../language/plain.zig");
const audience = @import("../language/audience.zig");

fn workbenchFacts(arena: std.mem.Allocator) !SystemFacts {
    var suite = try evaluation_mod.workbenchSuite(arena);
    try suite.addResult(.{
        .measure_id = "M-PROMPT-CLARITY",
        .value = 1.0,
        .sample_size = 4,
        .method = .automated_test,
        .measured_at = try Timestamp.parseIso("2026-09-04T12:00:00Z"),
        .conditions = "The generated prompts in the approval test suite",
    });

    return .{
        .name = "zag workbench",
        .version = "0.1.0",
        .owner = "workbench maintainers",
        .contact = "the repository issue tracker",
        .license = "MIT",
        .purpose = "Help a developer run commands, read and change code, and direct agents, on a machine they control.",
        .intended_users = &.{"Software developers working on their own or their organisation's code."},
        .intended_uses = &.{
            "Running commands and reading their output as durable records.",
            "Directing an agent to change code under a policy the person sets.",
            "Reviewing what an agent did, and why.",
        },
        .excluded_uses = &.{
            "Deciding anything about a person, such as employment, credit, benefits or access.",
            "Running without a person able to see and stop what an agent does.",
        },
        .model = .{ .provider = "configured by the operator", .model = "configured by the operator", .version = null },
        .model_inputs = &.{
            "The request the person typed.",
            "Files the policy allows the agent to read.",
            "Output of commands the agent ran.",
        },
        .model_outputs = &.{
            "A plan, in words.",
            "Typed tool requests, which the policy engine decides before anything runs.",
        },
        .policy = try policy_mod.repositoryWriteNoNetwork("/home/user/zag", arena),
        .allowed_capabilities = &.{ .@"fs.read", .@"fs.write", .@"process.execute", .@"git.read", .@"git.commit" },
        .data_sources = &.{
            .{
                .name = "the workspace",
                .description = "Files, commands and output in the repository the person opened.",
                .personal_data = false,
                .leaves_machine = false,
                .retention = "Until the person deletes the workspace.",
            },
            .{
                .name = "the event log",
                .description = "Every typed event, chained by hash.",
                .personal_data = false,
                .leaves_machine = false,
                .retention = "For as long as the retention rule on each record says.",
            },
        },
        .limitations = &.{
            "It cannot tell whether a change an agent wrote is correct. It can only show you what changed and let you check.",
            "Block boundaries depend on shell integration. Without it, timings and exit statuses are inferred and marked as inferred.",
            "The graphical renderer and the language-server client are not built yet.",
        },
        .human_oversight = "A person can stop any agent, refuse any approval, and withdraw any standing permission. Operations that cannot be undone always stop and ask.",
        .evaluations = suite,
        .risks = try risk_mod.workbenchRegister(arena),
        .impact = try impact_mod.workbenchAssessment(arena),
        .produced_at = try Timestamp.parseIso("2026-09-04T00:00:00Z"),
        .review_due = try Timestamp.parseIso("2027-03-04T00:00:00Z"),
    };
}

test "the model card is generated from the system's own facts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const facts = try workbenchFacts(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeModelCard(facts, &aw.writer);
    const card = aw.written();

    for (model_card_headings) |heading| {
        try testing.expect(std.mem.indexOf(u8, card, heading) != null);
    }
    // The card carries facts, not adjectives.
    try testing.expect(std.mem.indexOf(u8, card, "R-INJECTION") != null);
    try testing.expect(std.mem.indexOf(u8, card, "Not measured yet.") != null);
    try testing.expect(std.mem.indexOf(u8, card, "2027-03-04") != null);

    const findings = try reviewDocument(arena, card, &model_card_headings);
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "the system card names capabilities that send information away" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var facts = try workbenchFacts(arena);
    facts.allowed_capabilities = &.{ .@"fs.read", .@"model.infer" };

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeSystemCard(facts, &aw.writer);
    const card = aw.written();

    try testing.expect(std.mem.indexOf(u8, card, "sends information off this computer") != null);
    try testing.expect(std.mem.indexOf(u8, card, "What this system does not yet answer") != null);

    const findings = try reviewDocument(arena, card, &system_card_headings);
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "the datasheet answers the questions the shape requires" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dataset: DatasetFacts = .{
        .name = "workspace command history",
        .version = "2026-09",
        .purpose = "Let a person search what they ran, where, and what happened.",
        .made_by = "the workbench, from the person's own sessions",
        .contents = "One record for each command: the text, the directory, the repository, the exit status and the time it took.",
        .instance_count = 128_402,
        .collection_method = "Recorded by the workbench as the person worked, from shell integration marks.",
        .preparation = "Output larger than a few kilobytes is stored by hash rather than inline.",
        .uses = &.{ "Searching earlier work.", "Explaining how a regression was introduced." },
        .unsupported_uses = &.{ "Judging how productive a person is.", "Training a model without the person's agreement." },
        .personal_data = true,
        .consent_basis = "The person's own use of their own machine. Nothing is shared unless they share it.",
        .retention = "Kept locally until the person deletes it. Nothing is sent anywhere by default.",
        .limitations = &.{
            "Without shell integration, command boundaries are inferred and some records are incomplete.",
            "Commands typed inside a full-screen program are not recorded separately.",
        },
        .contact = "the repository issue tracker",
        .produced_at = try Timestamp.parseIso("2026-09-04T00:00:00Z"),
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeDatasheet(dataset, &aw.writer);
    const sheet = aw.written();

    for (datasheet_headings) |heading| {
        try testing.expect(std.mem.indexOf(u8, sheet, heading) != null);
    }
    try testing.expect(std.mem.indexOf(u8, sheet, "Judging how productive a person is.") != null);

    const findings = try reviewDocument(arena, sheet, &datasheet_headings);
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "the fact sheet is honest about what has not been measured" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const facts = try workbenchFacts(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeFactSheet(facts, &aw.writer);
    const sheet = aw.written();

    try testing.expect(std.mem.indexOf(u8, sheet, "What could go wrong") != null);
    try testing.expect(std.mem.indexOf(u8, sheet, "from 4 observations") != null);
    try testing.expect(std.mem.indexOf(u8, sheet, "Can challenge a decision") != null);
}

test "generated documents read plainly for the reader they are written for" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const facts = try workbenchFacts(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeModelCard(facts, &aw.writer);

    const report = try plain.check(arena, aw.written(), .{
        .kind = .body,
        .purpose = .inform,
        .audience = audience.auditor,
    });
    // Nothing in a generated document should be a blocking problem: no
    // placeholders, no raw error codes, no ambiguous timestamps.
    for (report.findings) |finding| {
        if (finding.severity == .blocking) {
            std.debug.print("{s} {s}\n", .{ finding.rule.code(), finding.message });
        }
        try testing.expect(finding.severity != .blocking);
    }
}
