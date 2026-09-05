//! Markdown publisher.
//!
//! Markdown is the format people read in a repository and the format agents
//! consume through `llms.txt`, so it is the default output. Metadata is written
//! as YAML front matter using the registered field names.

const std = @import("std");
const ir = @import("ir.zig");
const timeutil = @import("../core/time.zig");

pub fn write(document: ir.Document, w: *std.Io.Writer) !void {
    try writeFrontMatter(document.meta, w);
    try w.print("# {s}\n\n", .{document.meta.title});
    if (document.meta.summary) |summary| try w.print("{s}\n\n", .{summary});
    try w.print("{s}\n\n", .{document.reader_outcome});
    for (document.body) |node| try writeNode(node, 2, w);
}

fn writeFrontMatter(meta: ir.ArtifactMeta, w: *std.Io.Writer) !void {
    var created: [timeutil.Timestamp.text_len_max]u8 = undefined;
    var modified: [timeutil.Timestamp.text_len_max]u8 = undefined;
    var id_buf: [@TypeOf(meta.id).text_len]u8 = undefined;

    try w.writeAll("---\n");
    try w.print("identifier: {s}\n", .{meta.id.toText(&id_buf)});
    try w.print("title: \"{s}\"\n", .{meta.title});
    try w.print("kind: {s}\n", .{meta.kind});
    try w.print("language: {f}\n", .{meta.lang});
    try w.print("creator: \"{s}\"\n", .{meta.creator});
    try w.print("created: {s}\n", .{meta.created_at.toIso(&created, .second)});
    try w.print("modified: {s}\n", .{meta.modified_at.toIso(&modified, .second)});
    try w.print("lifecycleState: {s}\n", .{@tagName(meta.lifecycle_state)});
    try w.print("purpose: {s}\n", .{@tagName(meta.purpose)});
    if (meta.license) |license| try w.print("license: {s}\n", .{license});
    if (meta.identifier_uri) |uri| try w.print("uri: {s}\n", .{uri});
    if (meta.audience.len > 0) {
        try w.writeAll("audience:\n");
        for (meta.audience) |a| try w.print("  - {s}\n", .{a});
    }
    if (meta.concepts.len > 0) {
        try w.writeAll("concepts:\n");
        for (meta.concepts) |c| try w.print("  - {s}\n", .{c});
    }
    if (meta.standards.len > 0) {
        try w.writeAll("standards:\n");
        for (meta.standards) |s| try w.print("  - \"{s}\"\n", .{s});
    }
    try w.writeAll("---\n\n");
}

fn writeNode(node: ir.Node, level: usize, w: *std.Io.Writer) !void {
    switch (node) {
        .section => |section| {
            var hashes: usize = 0;
            while (hashes < level) : (hashes += 1) try w.writeByte('#');
            try w.print(" {s}\n\n", .{section.title});
            for (section.children) |child| try writeNode(child, level + 1, w);
        },
        .paragraph => |text| try w.print("{s}\n\n", .{text}),
        .procedure => |procedure| {
            var hashes: usize = 0;
            while (hashes < level) : (hashes += 1) try w.writeByte('#');
            try w.print(" {s}\n\n", .{procedure.title});
            try w.print("When you finish: {s}\n\n", .{procedure.outcome});
            if (procedure.prerequisites.len > 0) {
                try w.writeAll("Before you start:\n\n");
                for (procedure.prerequisites) |item| try w.print("- {s}\n", .{item});
                try w.writeAll("\n");
            }
            for (procedure.steps, 0..) |step, index| {
                if (step.admonition) |admonition| {
                    try writeAdmonition(admonition, w);
                }
                try w.print("{d}. {s}\n", .{ index + 1, step.action });
                if (step.result) |result| try w.print("   {s}\n", .{result});
            }
            try w.writeAll("\n");
        },
        .admonition => |admonition| try writeAdmonition(admonition, w),
        .definition => |definition| {
            try w.print("**{s}**\n{s}\n\n", .{ definition.term, definition.definition });
        },
        .example => |example| {
            if (example.title) |title| try w.print("**{s}**\n\n", .{title});
            try w.print("{s}\n\n", .{example.body});
        },
        .code => |code| {
            if (code.caption) |caption| try w.print("{s}\n\n", .{caption});
            try w.print("```{s}\n{s}\n```\n\n", .{ code.language_name, code.code });
        },
        .table => |table| {
            try w.print("{s}\n\n", .{table.caption});
            try w.writeAll("|");
            for (table.headers) |header| try w.print(" {s} |", .{header});
            try w.writeAll("\n|");
            for (table.headers) |_| try w.writeAll(" --- |");
            try w.writeAll("\n");
            for (table.rows) |row| {
                try w.writeAll("|");
                for (row) |cell| try w.print(" {s} |", .{cell});
                try w.writeAll("\n");
            }
            try w.writeAll("\n");
        },
        .figure => |figure| {
            try w.print("![{s}]({s})\n\n", .{ figure.alternative_text, figure.source });
            try w.print("{s}\n\n", .{figure.caption});
        },
        .list => |list| {
            for (list.items, 0..) |item, index| {
                if (list.ordered) {
                    try w.print("{d}. {s}\n", .{ index + 1, item });
                } else {
                    try w.print("- {s}\n", .{item});
                }
            }
            try w.writeAll("\n");
        },
        .requirement => |requirement| {
            try w.print("**{s}** {s}\n\nSource: {s}\n\n", .{ requirement.id, requirement.statement, requirement.source });
        },
        .decision => |decision| {
            try w.print("**{s}: {s}**\n\n", .{ decision.id, decision.question });
            try w.print("Decision: {s}\n\n", .{decision.decision});
            try w.print("Why: {s}\n\n", .{decision.rationale});
            if (decision.alternatives.len > 0) {
                try w.writeAll("Also considered:\n\n");
                for (decision.alternatives) |alternative| try w.print("- {s}\n", .{alternative});
                try w.writeAll("\n");
            }
        },
        .evidence => |evidence| {
            try w.print("Evidence for {s}: {s} ({s})", .{ evidence.requirement_id, evidence.result, evidence.method });
            if (evidence.note.len > 0) try w.print(". {s}", .{evidence.note});
            try w.writeAll("\n\n");
        },
    }
}

fn writeAdmonition(admonition: ir.Node.Admonition, w: *std.Io.Writer) !void {
    const label = switch (admonition.kind) {
        .warning => "Warning",
        .caution => "Careful",
        .note => "Note",
        .prerequisite => "Before you start",
    };
    try w.print("> **{s}**  {s}", .{ label, admonition.consequence });
    if (admonition.action) |action| try w.print(" {s}", .{action});
    try w.writeAll("\n\n");
}

const testing = std.testing;

test "markdown carries the metadata and the structure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idmod = @import("../core/id.zig");
    var gen: idmod.Generator = .init(701, 1_788_000_000_000);
    const document = try ir.sampleDocument(&gen);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try write(document, &aw.writer);
    const text = aw.written();

    try testing.expect(std.mem.startsWith(u8, text, "---\n"));
    try testing.expect(std.mem.indexOf(u8, text, "lifecycleState: published") != null);
    try testing.expect(std.mem.indexOf(u8, text, "standards:\n  - \"ISO 24495-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "# Let an agent change this repository") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1. Open the policy panel.") != null);
    try testing.expect(std.mem.indexOf(u8, text, "> **Careful**") != null);
    // The warning appears before the step it applies to.
    const warning_at = std.mem.indexOf(u8, text, "> **Careful**").?;
    const step_at = std.mem.indexOf(u8, text, "3. Start the agent.").?;
    try testing.expect(warning_at < step_at);
}
