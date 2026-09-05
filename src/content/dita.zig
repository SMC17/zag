//! DITA publisher.
//!
//! The information type in the model chooses the DITA topic type, which is the
//! whole reason for typing content in the first place: a procedure becomes a
//! `<task>`, an explanation becomes a `<concept>`, and everything else becomes
//! a `<reference>`.
//!
//! This is an export format, not the internal model. Nothing in the workbench
//! reads DITA back.

const std = @import("std");
const ir = @import("ir.zig");
const timeutil = @import("../core/time.zig");

const escape = ir.writeXmlEscaped;

pub const TopicType = enum {
    task,
    concept,
    reference,

    pub fn forInformationType(information_type: ir.InformationType) TopicType {
        return switch (information_type) {
            .procedure => .task,
            .concept, .principle, .process => .concept,
            .fact, .structure, .classification => .reference,
        };
    }

    pub fn rootElement(self: TopicType) []const u8 {
        return @tagName(self);
    }

    pub fn bodyElement(self: TopicType) []const u8 {
        return switch (self) {
            .task => "taskbody",
            .concept => "conbody",
            .reference => "refbody",
        };
    }

    pub fn publicIdentifier(self: TopicType) []const u8 {
        return switch (self) {
            .task => "-//OASIS//DTD DITA Task//EN",
            .concept => "-//OASIS//DTD DITA Concept//EN",
            .reference => "-//OASIS//DTD DITA Reference//EN",
        };
    }

    pub fn systemIdentifier(self: TopicType) []const u8 {
        return switch (self) {
            .task => "task.dtd",
            .concept => "concept.dtd",
            .reference => "reference.dtd",
        };
    }
};

/// Write the document as a DITA map plus one topic for each top-level section.
pub fn writeMap(document: ir.Document, w: *std.Io.Writer) !void {
    var id_buf: [@TypeOf(document.meta.id).text_len]u8 = undefined;
    const id = document.meta.id.toText(&id_buf);

    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try w.writeAll("<!DOCTYPE map PUBLIC \"-//OASIS//DTD DITA Map//EN\" \"map.dtd\">\n");
    try w.print("<map id=\"{s}\" xml:lang=\"{f}\">\n", .{ id, document.meta.lang });
    try w.writeAll("  <title>");
    try escape(w, document.meta.title);
    try w.writeAll("</title>\n");
    try writeProlog(document.meta, w, "  ");

    for (document.body, 0..) |node, index| {
        switch (node) {
            .section => |section| {
                try w.print("  <topicref href=\"{s}-{d}.dita\" type=\"{s}\">\n", .{
                    id,
                    index,
                    TopicType.forInformationType(section.information_type).rootElement(),
                });
                try w.writeAll("    <topicmeta><navtitle>");
                try escape(w, section.title);
                try w.writeAll("</navtitle></topicmeta>\n  </topicref>\n");
            },
            else => {},
        }
    }
    try w.writeAll("</map>\n");
}

/// Write one section as a DITA topic.
pub fn writeTopic(meta: ir.ArtifactMeta, section: ir.Node.Section, index: usize, w: *std.Io.Writer) !void {
    const topic_type = TopicType.forInformationType(section.information_type);
    var id_buf: [@TypeOf(meta.id).text_len]u8 = undefined;
    const id = meta.id.toText(&id_buf);

    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try w.print("<!DOCTYPE {s} PUBLIC \"{s}\" \"{s}\">\n", .{
        topic_type.rootElement(),
        topic_type.publicIdentifier(),
        topic_type.systemIdentifier(),
    });
    try w.print("<{s} id=\"{s}-{d}\" xml:lang=\"{f}\">\n", .{ topic_type.rootElement(), id, index, meta.lang });
    try w.writeAll("  <title>");
    try escape(w, section.title);
    try w.writeAll("</title>\n");
    try writeProlog(meta, w, "  ");
    try w.print("  <{s}>\n", .{topic_type.bodyElement()});

    for (section.children) |child| try writeNode(child, topic_type, w);

    try w.print("  </{s}>\n", .{topic_type.bodyElement()});
    try w.print("</{s}>\n", .{topic_type.rootElement()});
}

fn writeProlog(meta: ir.ArtifactMeta, w: *std.Io.Writer, indent: []const u8) !void {
    var created: [timeutil.Timestamp.text_len_max]u8 = undefined;
    var modified: [timeutil.Timestamp.text_len_max]u8 = undefined;
    try w.print("{s}<prolog>\n", .{indent});
    try w.print("{s}  <author>", .{indent});
    try escape(w, meta.creator);
    try w.writeAll("</author>\n");
    try w.print("{s}  <critdates><created date=\"{s}\"/><revised modified=\"{s}\"/></critdates>\n", .{
        indent,
        meta.created_at.toIso(&created, .second),
        meta.modified_at.toIso(&modified, .second),
    });
    try w.print("{s}  <metadata>\n", .{indent});
    for (meta.audience) |audience| {
        try w.print("{s}    <audience type=\"user\" job=\"", .{indent});
        try escape(w, audience);
        try w.writeAll("\"/>\n");
    }
    if (meta.concepts.len > 0 or meta.subjects.len > 0) {
        try w.print("{s}    <keywords>\n", .{indent});
        for (meta.concepts) |concept| {
            try w.print("{s}      <keyword>", .{indent});
            try escape(w, concept);
            try w.writeAll("</keyword>\n");
        }
        for (meta.subjects) |subject| {
            try w.print("{s}      <keyword>", .{indent});
            try escape(w, subject);
            try w.writeAll("</keyword>\n");
        }
        try w.print("{s}    </keywords>\n", .{indent});
    }
    try w.print("{s}  </metadata>\n", .{indent});
    try w.print("{s}</prolog>\n", .{indent});
}

fn writeNode(node: ir.Node, topic_type: TopicType, w: *std.Io.Writer) !void {
    switch (node) {
        .paragraph => |text| {
            try w.writeAll("    <p>");
            try escape(w, text);
            try w.writeAll("</p>\n");
        },
        .procedure => |procedure| {
            try w.writeAll("    <context>");
            try escape(w, procedure.outcome);
            try w.writeAll("</context>\n");
            if (procedure.prerequisites.len > 0) {
                try w.writeAll("    <prereq><ul>\n");
                for (procedure.prerequisites) |item| {
                    try w.writeAll("      <li>");
                    try escape(w, item);
                    try w.writeAll("</li>\n");
                }
                try w.writeAll("    </ul></prereq>\n");
            }
            try w.writeAll("    <steps>\n");
            for (procedure.steps) |step| {
                try w.writeAll("      <step>\n");
                if (step.admonition) |admonition| {
                    try w.print("        <note type=\"{s}\">", .{ditaNoteType(admonition.kind)});
                    try escape(w, admonition.consequence);
                    if (admonition.action) |action| {
                        try w.writeAll(" ");
                        try escape(w, action);
                    }
                    try w.writeAll("</note>\n");
                }
                try w.writeAll("        <cmd>");
                try escape(w, step.action);
                try w.writeAll("</cmd>\n");
                if (step.result) |result| {
                    try w.writeAll("        <stepresult>");
                    try escape(w, result);
                    try w.writeAll("</stepresult>\n");
                }
                try w.writeAll("      </step>\n");
            }
            try w.writeAll("    </steps>\n");
        },
        .admonition => |admonition| {
            try w.print("    <note type=\"{s}\">", .{ditaNoteType(admonition.kind)});
            try escape(w, admonition.consequence);
            try w.writeAll("</note>\n");
        },
        .definition => |definition| {
            try w.writeAll("    <dl><dlentry><dt>");
            try escape(w, definition.term);
            try w.writeAll("</dt><dd>");
            try escape(w, definition.definition);
            try w.writeAll("</dd></dlentry></dl>\n");
        },
        .example => |example| {
            try w.writeAll("    <example>");
            if (example.title) |title| {
                try w.writeAll("<title>");
                try escape(w, title);
                try w.writeAll("</title>");
            }
            try w.writeAll("<p>");
            try escape(w, example.body);
            try w.writeAll("</p></example>\n");
        },
        .code => |code| {
            try w.print("    <codeblock outputclass=\"{s}\">", .{code.language_name});
            try escape(w, code.code);
            try w.writeAll("</codeblock>\n");
        },
        .list => |list| {
            const tag = if (list.ordered) "ol" else "ul";
            try w.print("    <{s}>\n", .{tag});
            for (list.items) |item| {
                try w.writeAll("      <li>");
                try escape(w, item);
                try w.writeAll("</li>\n");
            }
            try w.print("    </{s}>\n", .{tag});
        },
        .figure => |figure| {
            try w.writeAll("    <fig><title>");
            try escape(w, figure.caption);
            try w.print("</title><image href=\"{s}\"><alt>", .{figure.source});
            try escape(w, figure.alternative_text);
            try w.writeAll("</alt></image></fig>\n");
        },
        .table => |table| {
            try w.writeAll("    <table><title>");
            try escape(w, table.caption);
            try w.print("</title><tgroup cols=\"{d}\"><thead><row>\n", .{table.headers.len});
            for (table.headers) |header| {
                try w.writeAll("      <entry>");
                try escape(w, header);
                try w.writeAll("</entry>\n");
            }
            try w.writeAll("    </row></thead><tbody>\n");
            for (table.rows) |row| {
                try w.writeAll("      <row>");
                for (row) |cell| {
                    try w.writeAll("<entry>");
                    try escape(w, cell);
                    try w.writeAll("</entry>");
                }
                try w.writeAll("</row>\n");
            }
            try w.writeAll("    </tbody></tgroup></table>\n");
        },
        .section => |inner| {
            // A nested section becomes a section element inside the body.
            try w.writeAll("    <section><title>");
            try escape(w, inner.title);
            try w.writeAll("</title>\n");
            for (inner.children) |child| try writeNode(child, topic_type, w);
            try w.writeAll("    </section>\n");
        },
        .requirement => |requirement| {
            try w.print("    <p outputclass=\"requirement\" id=\"{s}\">", .{requirement.id});
            try escape(w, requirement.statement);
            try w.writeAll("</p>\n");
        },
        .decision => |decision| {
            try w.print("    <p outputclass=\"decision\" id=\"{s}\">", .{decision.id});
            try escape(w, decision.decision);
            try w.writeAll("</p>\n");
        },
        .evidence => |evidence| {
            try w.print("    <p outputclass=\"evidence\">{s}: ", .{evidence.requirement_id});
            try escape(w, evidence.result);
            try w.writeAll("</p>\n");
        },
    }
}

fn ditaNoteType(kind: ir.AdmonitionKind) []const u8 {
    return switch (kind) {
        .warning => "danger",
        .caution => "caution",
        .note => "note",
        .prerequisite => "important",
    };
}

const testing = std.testing;

test "a procedure becomes a dita task, a concept becomes a dita concept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idmod = @import("../core/id.zig");
    var gen: idmod.Generator = .init(711, 1_788_000_000_000);
    const document = try ir.sampleDocument(&gen);

    var map: std.Io.Writer.Allocating = .init(arena);
    try writeMap(document, &map.writer);
    try testing.expect(std.mem.indexOf(u8, map.written(), "<!DOCTYPE map PUBLIC") != null);
    try testing.expect(std.mem.indexOf(u8, map.written(), "type=\"concept\"") != null);
    try testing.expect(std.mem.indexOf(u8, map.written(), "type=\"task\"") != null);

    // The second section is the procedure.
    const procedure_section = document.body[1].section;
    var topic: std.Io.Writer.Allocating = .init(arena);
    try writeTopic(document.meta, procedure_section, 1, &topic.writer);
    const text = topic.written();
    try testing.expect(std.mem.indexOf(u8, text, "<task id=") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<taskbody>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<cmd>Open the policy panel.</cmd>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<note type=\"caution\">") != null);
}

test "xml special characters are escaped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idmod = @import("../core/id.zig");
    var gen: idmod.Generator = .init(712, 1_788_000_000_000);
    var document = try ir.sampleDocument(&gen);
    document.body = &.{.{ .section = .{
        .title = "Angles & ampersands",
        .information_type = .concept,
        .children = &.{.{ .paragraph = "Use <stdin> & \"quotes\" carefully." }},
    } }};

    var topic: std.Io.Writer.Allocating = .init(arena);
    try writeTopic(document.meta, document.body[0].section, 0, &topic.writer);
    const text = topic.written();
    try testing.expect(std.mem.indexOf(u8, text, "&lt;stdin&gt; &amp; &quot;quotes&quot;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Angles &amp; ampersands") != null);
}
