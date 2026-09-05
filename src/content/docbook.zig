//! DocBook 5.1 publisher.
//!
//! DocBook is the format used where a book-shaped deliverable is expected: a
//! manual, a printed guide, a specification. The mapping is direct, because
//! DocBook has an element for each of the model's block types.

const std = @import("std");
const ir = @import("ir.zig");
const timeutil = @import("../core/time.zig");

const escape = ir.writeXmlEscaped;

pub fn write(document: ir.Document, w: *std.Io.Writer) !void {
    var id_buf: [@TypeOf(document.meta.id).text_len]u8 = undefined;
    var created: [timeutil.Timestamp.text_len_max]u8 = undefined;

    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try w.print("<article xmlns=\"http://docbook.org/ns/docbook\" version=\"5.1\" xml:lang=\"{f}\" xml:id=\"{s}\">\n", .{
        document.meta.lang,
        document.meta.id.toText(&id_buf),
    });
    try w.writeAll("  <info>\n    <title>");
    try escape(w, document.meta.title);
    try w.writeAll("</title>\n");
    if (document.meta.summary) |summary| {
        try w.writeAll("    <abstract><para>");
        try escape(w, summary);
        try w.writeAll("</para></abstract>\n");
    }
    try w.writeAll("    <author><orgname>");
    try escape(w, document.meta.creator);
    try w.writeAll("</orgname></author>\n");
    try w.print("    <date>{s}</date>\n", .{document.meta.created_at.toIso(&created, .second)});
    if (document.meta.license) |license| {
        try w.writeAll("    <legalnotice><para>");
        try escape(w, license);
        try w.writeAll("</para></legalnotice>\n");
    }
    for (document.meta.subjects) |subject| {
        try w.writeAll("    <subjectset><subject><subjectterm>");
        try escape(w, subject);
        try w.writeAll("</subjectterm></subject></subjectset>\n");
    }
    try w.writeAll("  </info>\n");

    try w.writeAll("  <para>");
    try escape(w, document.reader_outcome);
    try w.writeAll("</para>\n");

    for (document.body) |node| try writeNode(node, w, "  ");
    try w.writeAll("</article>\n");
}

fn writeNode(node: ir.Node, w: *std.Io.Writer, indent: []const u8) !void {
    switch (node) {
        .section => |section| {
            try w.print("{s}<section>\n{s}  <title>", .{ indent, indent });
            try escape(w, section.title);
            try w.writeAll("</title>\n");
            for (section.children) |child| try writeNode(child, w, indent);
            try w.print("{s}</section>\n", .{indent});
        },
        .paragraph => |text| {
            try w.print("{s}  <para>", .{indent});
            try escape(w, text);
            try w.writeAll("</para>\n");
        },
        .procedure => |procedure| {
            try w.print("{s}  <procedure>\n{s}    <title>", .{ indent, indent });
            try escape(w, procedure.title);
            try w.writeAll("</title>\n");
            for (procedure.steps) |step| {
                try w.print("{s}    <step>\n", .{indent});
                if (step.admonition) |admonition| try writeAdmonition(admonition, w, indent);
                try w.print("{s}      <para>", .{indent});
                try escape(w, step.action);
                try w.writeAll("</para>\n");
                if (step.result) |result| {
                    try w.print("{s}      <para>", .{indent});
                    try escape(w, result);
                    try w.writeAll("</para>\n");
                }
                try w.print("{s}    </step>\n", .{indent});
            }
            try w.print("{s}  </procedure>\n", .{indent});
        },
        .admonition => |admonition| try writeAdmonition(admonition, w, indent),
        .definition => |definition| {
            try w.print("{s}  <variablelist><varlistentry><term>", .{indent});
            try escape(w, definition.term);
            try w.writeAll("</term><listitem><para>");
            try escape(w, definition.definition);
            try w.writeAll("</para></listitem></varlistentry></variablelist>\n");
        },
        .example => |example| {
            try w.print("{s}  <example>", .{indent});
            if (example.title) |title| {
                try w.writeAll("<title>");
                try escape(w, title);
                try w.writeAll("</title>");
            }
            try w.writeAll("<para>");
            try escape(w, example.body);
            try w.writeAll("</para></example>\n");
        },
        .code => |code| {
            try w.print("{s}  <programlisting language=\"{s}\">", .{ indent, code.language_name });
            try escape(w, code.code);
            try w.writeAll("</programlisting>\n");
        },
        .list => |list| {
            const tag = if (list.ordered) "orderedlist" else "itemizedlist";
            try w.print("{s}  <{s}>\n", .{ indent, tag });
            for (list.items) |item| {
                try w.print("{s}    <listitem><para>", .{indent});
                try escape(w, item);
                try w.writeAll("</para></listitem>\n");
            }
            try w.print("{s}  </{s}>\n", .{ indent, tag });
        },
        .figure => |figure| {
            try w.print("{s}  <figure><title>", .{indent});
            try escape(w, figure.caption);
            try w.print("</title><mediaobject><imageobject><imagedata fileref=\"{s}\"/></imageobject><textobject><phrase>", .{figure.source});
            try escape(w, figure.alternative_text);
            try w.writeAll("</phrase></textobject></mediaobject></figure>\n");
        },
        .table => |table| {
            try w.print("{s}  <table><title>", .{indent});
            try escape(w, table.caption);
            try w.print("</title><tgroup cols=\"{d}\"><thead><row>", .{table.headers.len});
            for (table.headers) |header| {
                try w.writeAll("<entry>");
                try escape(w, header);
                try w.writeAll("</entry>");
            }
            try w.writeAll("</row></thead><tbody>");
            for (table.rows) |row| {
                try w.writeAll("<row>");
                for (row) |cell| {
                    try w.writeAll("<entry>");
                    try escape(w, cell);
                    try w.writeAll("</entry>");
                }
                try w.writeAll("</row>");
            }
            try w.writeAll("</tbody></tgroup></table>\n");
        },
        .requirement => |requirement| {
            try w.print("{s}  <para role=\"requirement\" xml:id=\"{s}\">", .{ indent, requirement.id });
            try escape(w, requirement.statement);
            try w.writeAll("</para>\n");
        },
        .decision => |decision| {
            try w.print("{s}  <para role=\"decision\" xml:id=\"{s}\">", .{ indent, decision.id });
            try escape(w, decision.decision);
            try w.writeAll("</para>\n");
        },
        .evidence => |evidence| {
            try w.print("{s}  <para role=\"evidence\">", .{indent});
            try escape(w, evidence.result);
            try w.writeAll("</para>\n");
        },
    }
}

fn writeAdmonition(admonition: ir.Node.Admonition, w: *std.Io.Writer, indent: []const u8) !void {
    const tag = switch (admonition.kind) {
        .warning => "warning",
        .caution => "caution",
        .note => "note",
        .prerequisite => "important",
    };
    try w.print("{s}      <{s}><para>", .{ indent, tag });
    try escape(w, admonition.consequence);
    if (admonition.action) |action| {
        try w.writeAll(" ");
        try escape(w, action);
    }
    try w.print("</para></{s}>\n", .{tag});
}

const testing = std.testing;

test "docbook output carries the info block and the procedure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idmod = @import("../core/id.zig");
    var gen: idmod.Generator = .init(721, 1_788_000_000_000);
    const document = try ir.sampleDocument(&gen);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try write(document, &aw.writer);
    const text = aw.written();

    try testing.expect(std.mem.indexOf(u8, text, "xmlns=\"http://docbook.org/ns/docbook\" version=\"5.1\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<procedure>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<caution><para>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<legalnotice><para>MIT") != null);
}
