//! The workbench's own concept system.
//!
//! This is the authoritative definition of what the product's words mean. It is
//! not documentation *about* the code; the code, the user interface, the agent
//! context and the published SKOS vocabulary all read from here, so a term can
//! only be renamed in one place.
//!
//! Every definition follows the ISO 704 pattern: superordinate concept first,
//! then the characteristics that separate this concept from its siblings, in
//! one sentence, without repeating the term.

const std = @import("std");
const concepts = @import("concepts.zig");

const C = concepts.Concept;

pub const entries = [_]C{
    .{
        .id = "development-environment",
        .preferred = "development environment",
        .definition = "collection of tools and resources that a person or program uses to build and change software",
        .top_concept = true,
    },
    .{
        .id = "workspace",
        .preferred = "workspace",
        .definition = "development environment that keeps its sessions, files, agents and history together and restores them after a restart",
        .designations = &.{
            .{ .text = "bench", .status = .admitted },
            .{ .text = "project shell", .status = .deprecated, .note = "Used in early drafts. Do not use in new text." },
            .{ .text = "environment group", .status = .deprecated },
        },
        .relations = &.{.{ .kind = .generic, .target = "development-environment" }},
        .examples = &.{"the workspace that holds the parser branch, its three sessions and its review agent"},
    },
    .{
        .id = "session",
        .preferred = "session",
        .definition = "workspace part that runs one program under one working directory and records everything that program produces",
        .relations = &.{
            .{ .kind = .partitive, .target = "workspace" },
            .{ .kind = .associative, .target = "block" },
        },
    },
    .{
        .id = "block",
        .preferred = "block",
        .definition = "record of one unit of work that holds its request, its output, its result and the conditions it ran under",
        .designations = &.{.{ .text = "command block", .status = .admitted }},
        .relations = &.{
            .{ .kind = .partitive, .target = "session" },
            .{ .kind = .associative, .target = "session" },
            .{ .kind = .associative, .target = "workspace-event" },
        },
    },
    .{
        .id = "workspace-event",
        .preferred = "workspace event",
        .definition = "typed statement that something happened in a workspace, written once and never changed",
        .designations = &.{.{ .text = "event", .status = .admitted }},
        .relations = &.{
            .{ .kind = .partitive, .target = "workspace" },
            .{ .kind = .associative, .target = "block" },
        },
    },
    .{
        .id = "event-log",
        .preferred = "event log",
        .definition = "ordered store of workspace events in which each entry carries the hash of the entry before it",
        .relations = &.{.{ .kind = .partitive, .target = "workspace" }},
    },
    .{
        .id = "actor",
        .preferred = "actor",
        .definition = "party that can cause a workspace event, whether a person, a program or a service",
        .top_concept = true,
    },
    .{
        .id = "agent",
        .preferred = "agent",
        .definition = "actor that plans and carries out work in a workspace on behalf of a person, using tools it is allowed to use",
        .relations = &.{.{ .kind = .generic, .target = "actor" }},
    },
    .{
        .id = "tool-call",
        .preferred = "tool call",
        .definition = "single typed request from an agent to do one thing, together with the result of that request",
        .relations = &.{
            .{ .kind = .partitive, .target = "execution-graph" },
            .{ .kind = .associative, .target = "agent" },
        },
    },
    .{
        .id = "capability",
        .preferred = "capability",
        .definition = "named permission to perform one class of operation, such as reading files or opening network connections",
        .top_concept = true,
    },
    .{
        .id = "policy",
        .preferred = "policy",
        .definition = "rule set that decides whether an actor may use a capability on a resource, and whether a person must approve first",
        .relations = &.{.{ .kind = .associative, .target = "capability" }},
        .top_concept = true,
    },
    .{
        .id = "authorization-decision",
        .preferred = "authorisation decision",
        .definition = "record of one policy outcome, naming the actor, the capability, the resource, the result and the reason",
        .relations = &.{
            .{ .kind = .associative, .target = "policy" },
            .{ .kind = .generic, .target = "record" },
        },
    },
    .{
        .id = "approval",
        .preferred = "approval",
        .definition = "decision by a person to allow one operation that policy would not allow on its own",
        .relations = &.{.{ .kind = .associative, .target = "authorization-decision" }},
        .top_concept = true,
    },
    .{
        .id = "artifact",
        .preferred = "artefact",
        .definition = "durable thing the workspace can name and describe, such as a document, a dataset, a patch or a report",
        .designations = &.{.{ .text = "artifact", .status = .admitted, .note = "US spelling; both forms resolve to this concept." }},
        .top_concept = true,
    },
    .{
        .id = "provenance",
        .preferred = "provenance",
        .definition = "account of how an artefact came to exist, naming its producer, its sources, its tools and the time it was made",
        .relations = &.{.{ .kind = .associative, .target = "artifact" }},
        .top_concept = true,
    },
    .{
        .id = "record",
        .preferred = "record",
        .definition = "artefact kept as evidence of an activity, held unchanged for as long as its retention rule requires",
        .relations = &.{.{ .kind = .generic, .target = "artifact" }},
    },
    .{
        .id = "evidence",
        .preferred = "evidence",
        .definition = "record that shows whether one requirement was met, naming the method used to check it and the result",
        .relations = &.{
            .{ .kind = .generic, .target = "record" },
            .{ .kind = .associative, .target = "requirement" },
        },
    },
    .{
        .id = "standard",
        .preferred = "standard",
        .definition = "published document that states rules the workbench applies to its own behaviour and output",
        .top_concept = true,
    },
    .{
        .id = "requirement",
        .preferred = "requirement",
        .definition = "single checkable rule taken from a standard, with a scope, a verification method and a severity",
        .relations = &.{.{ .kind = .partitive, .target = "standard" }},
    },
    .{
        .id = "conformance-profile",
        .preferred = "conformance profile",
        .definition = "named selection of requirements that applies to one kind of work, such as scientific writing or legal communication",
        .relations = &.{.{ .kind = .associative, .target = "requirement" }},
        .top_concept = true,
    },
    .{
        .id = "audience",
        .preferred = "audience",
        .definition = "group of readers whose purpose, prior knowledge and reading conditions decide how content must be written",
        .top_concept = true,
    },
    .{
        .id = "plain-language",
        .preferred = "plain language",
        .definition = "way of writing in which the intended reader can find what they need, understand it and use it the first time they read it",
        .relations = &.{.{ .kind = .associative, .target = "audience" }},
        .top_concept = true,
        .source = "ISO 24495-1",
    },
    .{
        .id = "concept",
        .preferred = "concept",
        .definition = "unit of knowledge created by a unique combination of characteristics",
        .top_concept = true,
        .source = "ISO 704",
    },
    .{
        .id = "term",
        .preferred = "term",
        .definition = "word or phrase that designates a concept in a subject field",
        .relations = &.{.{ .kind = .associative, .target = "concept" }},
        .top_concept = true,
        .source = "ISO 704",
    },
    .{
        .id = "data-element",
        .preferred = "data element",
        .definition = "registered field with one meaning, one value domain and one canonical name across every interface",
        .top_concept = true,
        .source = "ISO/IEC 11179",
    },
    .{
        .id = "dataset",
        .preferred = "dataset",
        .definition = "collection of data prepared for one purpose, with a stated lifecycle stage, quality profile and retention rule",
        .relations = &.{.{ .kind = .generic, .target = "artifact" }},
    },
    .{
        .id = "pseudoterminal",
        .preferred = "pseudoterminal",
        .definition = "pair of connected devices that lets a program behave as though it were attached to a terminal",
        .designations = &.{
            .{ .text = "PTY", .status = .admitted, .note = "Write the full term on first use, then the short form." },
            .{ .text = "pty", .status = .admitted },
        },
        .top_concept = true,
    },
    .{
        .id = "terminal-surface",
        .preferred = "terminal surface",
        .definition = "workspace area that draws terminal output and sends key presses straight to the running program",
        .relations = &.{
            .{ .kind = .partitive, .target = "session" },
            .{ .kind = .associative, .target = "pseudoterminal" },
        },
    },
    .{
        .id = "shell-integration",
        .preferred = "shell integration",
        .definition = "set of markers a shell sends so the workbench can tell where a prompt, a command and its output begin and end",
        .relations = &.{.{ .kind = .associative, .target = "block" }},
        .top_concept = true,
    },
    .{
        .id = "worktree",
        .preferred = "worktree",
        .definition = "checked-out copy of a repository at one branch, which a session can use without disturbing other sessions",
        .top_concept = true,
    },
    .{
        .id = "execution-graph",
        .preferred = "execution graph",
        .definition = "set of workspace events linked by cause, showing which action led to which result",
        .relations = &.{.{ .kind = .associative, .target = "workspace-event" }},
        .top_concept = true,
    },
    .{
        .id = "workflow",
        .preferred = "workflow",
        .definition = "task graph whose nodes declare their inputs, outputs, permissions, cache key and failure behaviour",
        .top_concept = true,
    },
    .{
        .id = "knowledge-base",
        .preferred = "knowledge base",
        .definition = "workspace store of rules, prompts, workflows, notebooks and vocabulary held as ordinary files under version control",
        .relations = &.{.{ .kind = .partitive, .target = "workspace" }},
    },
    .{
        .id = "risk",
        .preferred = "risk",
        .definition = "effect of uncertainty on an objective, recorded with its source, its likelihood, its impact and how it is treated",
        .top_concept = true,
        .source = "ISO/IEC 23894",
    },
    .{
        .id = "impact-assessment",
        .preferred = "impact assessment",
        .definition = "record of how an AI system may affect people and organisations, and what the operator does about it",
        .relations = &.{.{ .kind = .associative, .target = "risk" }},
        .top_concept = true,
        .source = "ISO/IEC 42005",
    },
    .{
        .id = "metric",
        .preferred = "metric",
        .definition = "measure with a defined unit, period, source and comparison basis, reported the same way every time",
        .top_concept = true,
    },
};

/// Build the workbench concept system. The arena keeps any derived strings.
pub fn build(arena: std.mem.Allocator) !concepts.ConceptSystem {
    var system = concepts.ConceptSystem.init(arena);
    for (entries) |c| try system.add(c);
    return system;
}

test "the product vocabulary passes its own terminology checks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const system = try build(arena);
    const findings = try system.validate();
    if (findings.items.len > 0) {
        for (findings.items) |f| {
            std.debug.print("{s} {s}: {s}\n", .{ f.code.text(), f.concept_id, f.message });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
    try std.testing.expect(system.count() >= 30);
}

test "deprecated product terms still resolve" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const system = try build(arena_state.allocator());

    const old = system.resolve("project shell").?;
    try std.testing.expectEqualStrings("workspace", old.concept.id);
    try std.testing.expectEqual(concepts.TermStatus.deprecated, old.status);

    const abbreviation = system.resolve("PTY").?;
    try std.testing.expectEqualStrings("pseudoterminal", abbreviation.concept.preferred);

    const us_spelling = system.resolve("artifact").?;
    try std.testing.expectEqualStrings("artefact", us_spelling.concept.preferred);
}
