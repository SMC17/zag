//! The canonical content model.
//!
//! DITA, DocBook, S1000D and iiRDS are all good at what they are for, and all
//! wrong as an internal representation: adopting one of them as the product's
//! own model would marry the whole system to its authoring conventions. So the
//! workbench keeps a small model of its own and publishes into those formats.
//!
//! The model is typed by *information type* in the Information Mapping sense: a
//! procedure is not a concept is not a principle. That typing is what makes the
//! checks meaningful — a procedure with no steps is a defect, and a warning
//! that follows the step it warns about is a defect.

const std = @import("std");
const language = @import("../interop/language.zig");
const timeutil = @import("../core/time.zig");
const idmod = @import("../core/id.zig");

pub const Timestamp = timeutil.Timestamp;

/// Information types. Each answers a different reader question, and mixing
/// them in one block is the most common structural defect in technical text.
pub const InformationType = enum {
    /// How to do something, as ordered steps.
    procedure,
    /// How something happens, without the reader doing it.
    process,
    /// What something is.
    concept,
    /// A rule that guides a decision.
    principle,
    /// A single verifiable statement.
    fact,
    /// What something is made of.
    structure,
    /// How a set of things is divided up.
    classification,

    pub fn readerQuestion(self: InformationType) []const u8 {
        return switch (self) {
            .procedure => "How do I do it?",
            .process => "How does it happen?",
            .concept => "What is it?",
            .principle => "What rule applies?",
            .fact => "What is true?",
            .structure => "What is it made of?",
            .classification => "What kinds are there?",
        };
    }
};

pub const Purpose = enum { instruct, inform, warn, decide, comply, report };

pub const LifecycleState = enum { draft, in_review, published, superseded, withdrawn };

/// Metadata carried by every artefact. The field names come from the metadata
/// registry, and map onto Dublin Core, DCAT and schema.org when published.
pub const ArtifactMeta = struct {
    id: idmod.ArtifactId,
    kind: []const u8,
    title: []const u8,
    summary: ?[]const u8 = null,
    /// Audience identifiers this is written for.
    audience: []const []const u8 = &.{},
    purpose: Purpose = .inform,
    /// Concept identifiers this artefact is about.
    concepts: []const []const u8 = &.{},
    subjects: []const []const u8 = &.{},
    lang: language.Tag = language.Tag.english,
    /// Terminology profile the text is checked against.
    terminology_profile: []const u8 = "default",
    created_at: Timestamp,
    modified_at: Timestamp,
    creator: []const u8,
    lifecycle_state: LifecycleState = .draft,
    retention_class: ?[]const u8 = null,
    /// Standards this artefact is produced under.
    standards: []const []const u8 = &.{},
    license: ?[]const u8 = null,
    /// Canonical location, when published.
    identifier_uri: ?[]const u8 = null,
};

pub const AdmonitionKind = enum {
    /// Something that can hurt a person.
    warning,
    /// Something that can damage data or equipment.
    caution,
    /// Something worth knowing.
    note,
    /// Something the reader must have before starting.
    prerequisite,
};

pub const Node = union(enum) {
    section: Section,
    paragraph: []const u8,
    procedure: Procedure,
    admonition: Admonition,
    definition: Definition,
    example: Example,
    code: CodeBlock,
    table: Table,
    figure: Figure,
    list: List,
    requirement: RequirementBlock,
    decision: DecisionBlock,
    evidence: EvidenceBlock,

    pub const Section = struct {
        /// The heading, which must say what the section answers.
        title: []const u8,
        information_type: InformationType,
        children: []const Node,
    };

    pub const Procedure = struct {
        title: []const u8,
        /// What the reader will have done when they finish.
        outcome: []const u8,
        prerequisites: []const []const u8 = &.{},
        steps: []const Step,
    };

    pub const Step = struct {
        /// One action, written as an instruction.
        action: []const u8,
        /// What the reader sees when it worked.
        result: ?[]const u8 = null,
        /// A warning that applies to this step, shown before it.
        admonition: ?Admonition = null,
    };

    pub const Admonition = struct {
        kind: AdmonitionKind,
        /// What could happen.
        consequence: []const u8,
        /// What to do about it.
        action: ?[]const u8 = null,
    };

    pub const Definition = struct {
        term: []const u8,
        definition: []const u8,
        concept_id: ?[]const u8 = null,
    };

    pub const Example = struct {
        title: ?[]const u8 = null,
        body: []const u8,
    };

    pub const CodeBlock = struct {
        language_name: []const u8,
        code: []const u8,
        caption: ?[]const u8 = null,
    };

    pub const Table = struct {
        caption: []const u8,
        headers: []const []const u8,
        rows: []const []const []const u8,
    };

    pub const Figure = struct {
        caption: []const u8,
        /// Text a reader who cannot see the figure needs instead.
        alternative_text: []const u8,
        source: []const u8,
    };

    pub const List = struct {
        ordered: bool,
        items: []const []const u8,
    };

    pub const RequirementBlock = struct {
        id: []const u8,
        statement: []const u8,
        source: []const u8,
    };

    pub const DecisionBlock = struct {
        id: []const u8,
        question: []const u8,
        decision: []const u8,
        rationale: []const u8,
        alternatives: []const []const u8 = &.{},
    };

    pub const EvidenceBlock = struct {
        requirement_id: []const u8,
        method: []const u8,
        result: []const u8,
        note: []const u8 = "",
    };
};

pub const Document = struct {
    meta: ArtifactMeta,
    /// A short statement of what the reader will be able to do after reading.
    /// ISO 24495 asks the writer to know the purpose; this makes it explicit.
    reader_outcome: []const u8,
    body: []const Node,
};

pub const FindingCode = enum {
    procedure_without_steps,
    step_without_action,
    warning_after_the_step,
    admonition_without_consequence,
    figure_without_alternative_text,
    table_without_header,
    section_without_type,
    chunk_too_large,
    mixed_information_types,
    missing_reader_outcome,

    pub fn text(self: FindingCode) []const u8 {
        return switch (self) {
            .procedure_without_steps => "IM01",
            .step_without_action => "IM02",
            .warning_after_the_step => "IM03",
            .admonition_without_consequence => "IM04",
            .figure_without_alternative_text => "IM05",
            .table_without_header => "IM06",
            .section_without_type => "IM07",
            .chunk_too_large => "IM08",
            .mixed_information_types => "IM09",
            .missing_reader_outcome => "IM10",
        };
    }
};

pub const Finding = struct {
    code: FindingCode,
    where: []const u8,
    message: []const u8,
};

/// The largest number of items a reader is asked to hold at once. Information
/// Mapping's chunking guidance; a list longer than this is split or grouped.
pub const chunk_limit = 9;

pub fn validate(arena: std.mem.Allocator, document: Document) !std.ArrayList(Finding) {
    var findings: std.ArrayList(Finding) = .empty;
    if (document.reader_outcome.len == 0) {
        try findings.append(arena, .{
            .code = .missing_reader_outcome,
            .where = document.meta.title,
            .message = "The document does not say what the reader will be able to do after reading it.",
        });
    }
    for (document.body) |node| try validateNode(arena, node, document.meta.title, &findings);
    return findings;
}

fn validateNode(arena: std.mem.Allocator, node: Node, where: []const u8, findings: *std.ArrayList(Finding)) !void {
    switch (node) {
        .section => |section| {
            if (section.title.len == 0) {
                try findings.append(arena, .{
                    .code = .section_without_type,
                    .where = where,
                    .message = "A section has no heading, so a reader cannot tell what it answers.",
                });
            }
            if (section.children.len > chunk_limit) {
                try findings.append(arena, .{
                    .code = .chunk_too_large,
                    .where = section.title,
                    .message = try std.fmt.allocPrint(arena, "\"{s}\" holds {d} blocks. Group them under sub-headings so a reader can hold the shape of it.", .{ section.title, section.children.len }),
                });
            }
            // A section typed as a procedure must actually contain one.
            if (section.information_type == .procedure) {
                var has_procedure = false;
                for (section.children) |child| {
                    if (child == .procedure) has_procedure = true;
                }
                if (!has_procedure) {
                    try findings.append(arena, .{
                        .code = .mixed_information_types,
                        .where = section.title,
                        .message = try std.fmt.allocPrint(arena, "\"{s}\" is typed as a procedure but contains no steps. Either add the steps or change its type.", .{section.title}),
                    });
                }
            }
            for (section.children) |child| try validateNode(arena, child, section.title, findings);
        },
        .procedure => |procedure| {
            if (procedure.steps.len == 0) {
                try findings.append(arena, .{
                    .code = .procedure_without_steps,
                    .where = procedure.title,
                    .message = try std.fmt.allocPrint(arena, "The procedure \"{s}\" has no steps.", .{procedure.title}),
                });
            }
            if (procedure.steps.len > chunk_limit) {
                try findings.append(arena, .{
                    .code = .chunk_too_large,
                    .where = procedure.title,
                    .message = try std.fmt.allocPrint(arena, "The procedure \"{s}\" has {d} steps. Break it into stages a reader can finish and check.", .{ procedure.title, procedure.steps.len }),
                });
            }
            for (procedure.steps) |step| {
                if (step.action.len == 0) {
                    try findings.append(arena, .{
                        .code = .step_without_action,
                        .where = procedure.title,
                        .message = "A step has no action. A step tells the reader what to do.",
                    });
                }
                if (step.admonition) |admonition| {
                    if (admonition.consequence.len == 0) {
                        try findings.append(arena, .{
                            .code = .admonition_without_consequence,
                            .where = procedure.title,
                            .message = "A warning on a step does not say what could happen.",
                        });
                    }
                }
            }
        },
        .admonition => |admonition| {
            if (admonition.consequence.len == 0) {
                try findings.append(arena, .{
                    .code = .admonition_without_consequence,
                    .where = where,
                    .message = "A warning does not say what could happen if the reader ignores it.",
                });
            }
        },
        .figure => |figure| {
            if (figure.alternative_text.len == 0) {
                try findings.append(arena, .{
                    .code = .figure_without_alternative_text,
                    .where = figure.caption,
                    .message = "A figure has no text alternative, so a reader who cannot see it gets nothing.",
                });
            }
        },
        .table => |table| {
            if (table.headers.len == 0) {
                try findings.append(arena, .{
                    .code = .table_without_header,
                    .where = table.caption,
                    .message = "A table has no header row, so its columns have no meaning for a screen reader.",
                });
            }
            for (table.rows) |row| {
                if (row.len != table.headers.len) {
                    try findings.append(arena, .{
                        .code = .table_without_header,
                        .where = table.caption,
                        .message = "A table row does not have the same number of cells as the header.",
                    });
                    break;
                }
            }
        },
        .list => |list| {
            if (list.items.len > chunk_limit) {
                try findings.append(arena, .{
                    .code = .chunk_too_large,
                    .where = where,
                    .message = try std.fmt.allocPrint(arena, "A list has {d} items. Group them so a reader can take them in.", .{list.items.len}),
                });
            }
        },
        else => {},
    }
}

/// Collect the plain text of a document, for the language checks.
pub fn plainText(arena: std.mem.Allocator, document: Document) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, document.meta.title);
    try out.appendSlice(arena, "\n\n");
    try out.appendSlice(arena, document.reader_outcome);
    try out.appendSlice(arena, "\n\n");
    for (document.body) |node| try appendText(arena, node, &out);
    return out.toOwnedSlice(arena);
}

fn appendText(arena: std.mem.Allocator, node: Node, out: *std.ArrayList(u8)) !void {
    switch (node) {
        .section => |section| {
            try out.appendSlice(arena, section.title);
            try out.appendSlice(arena, "\n\n");
            for (section.children) |child| try appendText(arena, child, out);
        },
        .paragraph => |text| {
            try out.appendSlice(arena, text);
            try out.appendSlice(arena, "\n\n");
        },
        .procedure => |procedure| {
            try out.appendSlice(arena, procedure.title);
            try out.appendSlice(arena, "\n\n");
            for (procedure.steps) |step| {
                if (step.admonition) |admonition| {
                    try out.appendSlice(arena, admonition.consequence);
                    try out.appendSlice(arena, "\n");
                }
                try out.appendSlice(arena, step.action);
                try out.appendSlice(arena, "\n");
                if (step.result) |result| {
                    try out.appendSlice(arena, result);
                    try out.appendSlice(arena, "\n");
                }
            }
            try out.appendSlice(arena, "\n");
        },
        .admonition => |admonition| {
            try out.appendSlice(arena, admonition.consequence);
            try out.appendSlice(arena, "\n\n");
        },
        .definition => |definition| {
            try out.appendSlice(arena, definition.term);
            try out.appendSlice(arena, ": ");
            try out.appendSlice(arena, definition.definition);
            try out.appendSlice(arena, "\n\n");
        },
        .example => |example| {
            try out.appendSlice(arena, example.body);
            try out.appendSlice(arena, "\n\n");
        },
        .list => |list| {
            for (list.items) |item| {
                try out.appendSlice(arena, item);
                try out.appendSlice(arena, "\n");
            }
            try out.appendSlice(arena, "\n");
        },
        .figure => |figure| {
            try out.appendSlice(arena, figure.caption);
            try out.appendSlice(arena, "\n");
            try out.appendSlice(arena, figure.alternative_text);
            try out.appendSlice(arena, "\n\n");
        },
        .table => |table| {
            try out.appendSlice(arena, table.caption);
            try out.appendSlice(arena, "\n\n");
        },
        .requirement => |requirement| {
            try out.appendSlice(arena, requirement.statement);
            try out.appendSlice(arena, "\n\n");
        },
        .decision => |decision| {
            try out.appendSlice(arena, decision.decision);
            try out.appendSlice(arena, "\n");
            try out.appendSlice(arena, decision.rationale);
            try out.appendSlice(arena, "\n\n");
        },
        .evidence => |evidence| {
            try out.appendSlice(arena, evidence.result);
            try out.appendSlice(arena, "\n\n");
        },
        .code => {},
    }
}

/// Escape text for XML output. Shared by every XML publisher.
pub fn writeXmlEscaped(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&apos;"),
            else => try w.writeByte(c),
        }
    }
}

const testing = std.testing;

pub fn sampleDocument(gen: *idmod.Generator) !Document {
    return .{
        .meta = .{
            .id = gen.next(idmod.ArtifactId),
            .kind = "task",
            .title = "Let an agent change this repository",
            .summary = "How to give an agent permission to change files here, and how to take it back.",
            .audience = &.{"new-user"},
            .purpose = .instruct,
            .concepts = &.{ "agent", "policy", "capability" },
            .created_at = try Timestamp.parseIso("2026-09-04T00:00:00Z"),
            .modified_at = try Timestamp.parseIso("2026-09-04T00:00:00Z"),
            .creator = "workbench maintainers",
            .lifecycle_state = .published,
            .standards = &.{ "ISO 24495-1", "Information Mapping" },
            .license = "MIT",
            .identifier_uri = "https://zag.dev/docs/agent-permissions",
        },
        .reader_outcome = "After reading this, you can give an agent permission to change files in one repository, and take that permission back.",
        .body = &.{
            .{ .section = .{
                .title = "What a policy does",
                .information_type = .concept,
                .children = &.{
                    .{ .paragraph = "A policy is a set of rules that decides what an agent may do. The agent proposes; the policy decides." },
                    .{ .definition = .{
                        .term = "capability",
                        .definition = "named permission to perform one class of operation",
                        .concept_id = "capability",
                    } },
                },
            } },
            .{ .section = .{
                .title = "Give an agent permission",
                .information_type = .procedure,
                .children = &.{
                    .{ .procedure = .{
                        .title = "Give an agent permission to change this repository",
                        .outcome = "The agent can change files here and run the tests.",
                        .prerequisites = &.{"You have a workspace open on the repository."},
                        .steps = &.{
                            .{ .action = "Open the policy panel.", .result = "The panel lists the policies you can choose." },
                            .{ .action = "Choose \"Change this repository, no network\".", .result = "The policy name appears in the session tab." },
                            .{
                                .action = "Start the agent.",
                                .result = "The agent shows its plan before it acts.",
                                .admonition = .{
                                    .kind = .caution,
                                    .consequence = "The agent can change any file in this repository once you do this.",
                                    .action = "Commit your work first, so you can undo any change.",
                                },
                            },
                        },
                    } },
                },
            } },
        },
    };
}

test "a well-formed document passes the structure checks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(601, 1_788_000_000_000);
    const document = try sampleDocument(&gen);
    const findings = try validate(arena, document);
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "structural defects are reported with their information type" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(602, 1_788_000_000_000);
    var document = try sampleDocument(&gen);
    document.reader_outcome = "";
    document.body = &.{
        .{ .section = .{
            .title = "Do the thing",
            .information_type = .procedure,
            .children = &.{.{ .paragraph = "It is done by the system." }},
        } },
        .{ .figure = .{ .caption = "The workspace", .alternative_text = "", .source = "workspace.png" } },
        .{ .table = .{ .caption = "Policies", .headers = &.{}, .rows = &.{} } },
        .{ .admonition = .{ .kind = .warning, .consequence = "" } },
    };

    const findings = (try validate(arena, document)).items;
    var codes: [std.meta.fields(FindingCode).len]bool = @splat(false);
    for (findings) |finding| codes[@intFromEnum(finding.code)] = true;
    try testing.expect(codes[@intFromEnum(FindingCode.mixed_information_types)]);
    try testing.expect(codes[@intFromEnum(FindingCode.figure_without_alternative_text)]);
    try testing.expect(codes[@intFromEnum(FindingCode.table_without_header)]);
    try testing.expect(codes[@intFromEnum(FindingCode.admonition_without_consequence)]);

    var saw_outcome = false;
    for (findings) |finding| {
        if (finding.code == .missing_reader_outcome) saw_outcome = true;
    }
    try testing.expect(saw_outcome);
}

test "oversized chunks are reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(603, 1_788_000_000_000);
    var document = try sampleDocument(&gen);

    var steps: [12]Node.Step = undefined;
    for (&steps, 0..) |*step, i| {
        _ = i;
        step.* = .{ .action = "Press the button." };
    }
    document.body = &.{.{ .procedure = .{
        .title = "A very long procedure",
        .outcome = "Something happened.",
        .steps = &steps,
    } }};

    const findings = (try validate(arena, document)).items;
    var saw_chunk = false;
    for (findings) |finding| {
        if (finding.code == .chunk_too_large) saw_chunk = true;
    }
    try testing.expect(saw_chunk);
}

test "the plain text of a document can be checked by the language pass" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(604, 1_788_000_000_000);
    const document = try sampleDocument(&gen);
    const text = try plainText(arena, document);
    try testing.expect(std.mem.indexOf(u8, text, "Open the policy panel.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "named permission") != null);

    const plain = @import("../language/plain.zig");
    const report = try plain.check(arena, text, .{ .kind = .procedure, .purpose = .instruct });
    for (report.findings) |finding| {
        try testing.expect(finding.severity != .blocking);
    }
}

test "information types name the question they answer" {
    try testing.expectEqualStrings("How do I do it?", InformationType.procedure.readerQuestion());
    try testing.expectEqualStrings("What is it?", InformationType.concept.readerQuestion());
}
