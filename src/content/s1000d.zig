//! S1000D data module publisher.
//!
//! S1000D exists where procedures must be traceable to a piece of equipment and
//! reused across publications. The workbench does not author in S1000D; it
//! exports into it, so that a team already working that way can take a
//! procedure without re-typing it.
//!
//! The data module code is built from the workspace identifiers, which keeps
//! exported modules stable across regenerations.

const std = @import("std");
const ir = @import("ir.zig");
const timeutil = @import("../core/time.zig");

const escape = ir.writeXmlEscaped;

/// The parts of a data module code the exporter needs. Real projects assign
/// these from their own breakdown; the caller supplies them.
pub const DataModuleCode = struct {
    model_identification: []const u8 = "ZAG",
    system_difference: []const u8 = "A",
    system: []const u8 = "00",
    subsystem: []const u8 = "0",
    sub_subsystem: []const u8 = "0",
    assembly: []const u8 = "00",
    disassembly: []const u8 = "00",
    disassembly_variant: []const u8 = "A",
    information_code: []const u8 = "040",
    information_code_variant: []const u8 = "A",
    item_location: []const u8 = "D",

    /// `040` is a description; `520` is a procedure. Choosing the information
    /// code from the content type is the point of typing the content.
    pub fn forInformationType(information_type: ir.InformationType) DataModuleCode {
        var code: DataModuleCode = .{};
        code.information_code = switch (information_type) {
            .procedure => "520",
            .process => "041",
            .concept, .principle => "040",
            .fact, .structure, .classification => "042",
        };
        return code;
    }

    pub fn write(self: DataModuleCode, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print(
            "<dmCode modelIdentCode=\"{s}\" systemDiffCode=\"{s}\" systemCode=\"{s}\" subSystemCode=\"{s}\" subSubSystemCode=\"{s}\" assyCode=\"{s}\" disassyCode=\"{s}\" disassyCodeVariant=\"{s}\" infoCode=\"{s}\" infoCodeVariant=\"{s}\" itemLocationCode=\"{s}\"/>",
            .{
                self.model_identification, self.system_difference,     self.system,
                self.subsystem,            self.sub_subsystem,         self.assembly,
                self.disassembly,          self.disassembly_variant,   self.information_code,
                self.information_code_variant, self.item_location,
            },
        );
    }
};

pub const Options = struct {
    code: ?DataModuleCode = null,
    security_classification: []const u8 = "01",
    responsible_partner: []const u8 = "ZAG",
    originator: []const u8 = "ZAG",
};

/// Write one section as an S1000D data module.
pub fn writeDataModule(
    meta: ir.ArtifactMeta,
    section: ir.Node.Section,
    options: Options,
    w: *std.Io.Writer,
) !void {
    const code = options.code orelse DataModuleCode.forInformationType(section.information_type);
    const is_procedure = section.information_type == .procedure;

    var issue_buf: [timeutil.Timestamp.text_len_max]u8 = undefined;
    const issue_date = meta.modified_at.toIso(&issue_buf, .second);

    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try w.writeAll("<dmodule>\n  <identAndStatusSection>\n    <dmAddress>\n      <dmIdent>\n        ");
    try code.write(w);
    try w.print(
        "\n        <language countryIsoCode=\"{s}\" languageIsoCode=\"{s}\"/>\n",
        .{
            if (meta.lang.region) |*region| region[0..] else "US",
            &meta.lang.language,
        },
    );
    try w.writeAll("        <issueInfo issueNumber=\"001\" inWork=\"00\"/>\n      </dmIdent>\n      <dmAddressItems>\n");
    try w.print("        <issueDate year=\"{s}\" month=\"{s}\" day=\"{s}\"/>\n", .{
        issue_date[0..4],
        issue_date[5..7],
        issue_date[8..10],
    });
    try w.writeAll("        <dmTitle><techName>");
    try escape(w, meta.title);
    try w.writeAll("</techName><infoName>");
    try escape(w, section.title);
    try w.writeAll("</infoName></dmTitle>\n      </dmAddressItems>\n    </dmAddress>\n");
    try w.print("    <dmStatus issueType=\"new\">\n      <security securityClassification=\"{s}\"/>\n", .{options.security_classification});
    try w.print("      <responsiblePartnerCompany><enterpriseName>{s}</enterpriseName></responsiblePartnerCompany>\n", .{options.responsible_partner});
    try w.print("      <originator><enterpriseName>{s}</enterpriseName></originator>\n", .{options.originator});
    try w.writeAll("      <applic><displayText><simplePara>All workspaces.</simplePara></displayText></applic>\n");
    try w.writeAll("      <qualityAssurance><unverified/></qualityAssurance>\n    </dmStatus>\n  </identAndStatusSection>\n");

    try w.writeAll("  <content>\n");
    if (is_procedure) {
        try writeProceduralContent(section, w);
    } else {
        try writeDescriptiveContent(section, w);
    }
    try w.writeAll("  </content>\n</dmodule>\n");
}

fn writeProceduralContent(section: ir.Node.Section, w: *std.Io.Writer) !void {
    try w.writeAll("    <procedure>\n      <preliminaryRqmts>\n");
    var wrote_prerequisite = false;
    for (section.children) |child| {
        switch (child) {
            .procedure => |procedure| {
                for (procedure.prerequisites) |item| {
                    if (!wrote_prerequisite) {
                        try w.writeAll("        <reqCondGroup>\n");
                        wrote_prerequisite = true;
                    }
                    try w.writeAll("          <reqCondNoRef><reqCond>");
                    try escape(w, item);
                    try w.writeAll("</reqCond></reqCondNoRef>\n");
                }
            },
            else => {},
        }
    }
    if (wrote_prerequisite) try w.writeAll("        </reqCondGroup>\n");
    try w.writeAll("      </preliminaryRqmts>\n      <mainProcedure>\n");

    for (section.children) |child| {
        switch (child) {
            .procedure => |procedure| {
                for (procedure.steps) |step| {
                    try w.writeAll("        <proceduralStep>\n");
                    if (step.admonition) |admonition| {
                        const tag = switch (admonition.kind) {
                            .warning => "warning",
                            .caution => "caution",
                            else => "note",
                        };
                        try w.print("          <{s}><{s}Para>", .{ tag, tag });
                        try escape(w, admonition.consequence);
                        if (admonition.action) |action| {
                            try w.writeAll(" ");
                            try escape(w, action);
                        }
                        try w.print("</{s}Para></{s}>\n", .{ tag, tag });
                    }
                    try w.writeAll("          <para>");
                    try escape(w, step.action);
                    try w.writeAll("</para>\n");
                    if (step.result) |result| {
                        try w.writeAll("          <para>");
                        try escape(w, result);
                        try w.writeAll("</para>\n");
                    }
                    try w.writeAll("        </proceduralStep>\n");
                }
            },
            else => {},
        }
    }
    try w.writeAll("      </mainProcedure>\n      <closeRqmts><reqCondGroup/></closeRqmts>\n    </procedure>\n");
}

fn writeDescriptiveContent(section: ir.Node.Section, w: *std.Io.Writer) !void {
    try w.writeAll("    <description>\n      <levelledPara>\n        <title>");
    try escape(w, section.title);
    try w.writeAll("</title>\n");
    for (section.children) |child| {
        switch (child) {
            .paragraph => |text| {
                try w.writeAll("        <para>");
                try escape(w, text);
                try w.writeAll("</para>\n");
            },
            .definition => |definition| {
                try w.writeAll("        <para><emphasis>");
                try escape(w, definition.term);
                try w.writeAll("</emphasis> ");
                try escape(w, definition.definition);
                try w.writeAll("</para>\n");
            },
            .list => |list| {
                try w.print("        <{s}>\n", .{if (list.ordered) "sequentialList" else "randomList"});
                for (list.items) |item| {
                    try w.writeAll("          <listItem><para>");
                    try escape(w, item);
                    try w.writeAll("</para></listItem>\n");
                }
                try w.print("        </{s}>\n", .{if (list.ordered) "sequentialList" else "randomList"});
            },
            else => {},
        }
    }
    try w.writeAll("      </levelledPara>\n    </description>\n");
}

const testing = std.testing;

test "a procedure exports as a procedural data module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idmod = @import("../core/id.zig");
    var gen: idmod.Generator = .init(731, 1_788_000_000_000);
    const document = try ir.sampleDocument(&gen);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeDataModule(document.meta, document.body[1].section, .{}, &aw.writer);
    const text = aw.written();

    try testing.expect(std.mem.indexOf(u8, text, "infoCode=\"520\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<proceduralStep>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<caution><cautionPara>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<issueDate year=\"2026\" month=\"09\" day=\"04\"/>") != null);
}

test "a concept exports as a descriptive data module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idmod = @import("../core/id.zig");
    var gen: idmod.Generator = .init(732, 1_788_000_000_000);
    const document = try ir.sampleDocument(&gen);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeDataModule(document.meta, document.body[0].section, .{}, &aw.writer);
    const text = aw.written();

    try testing.expect(std.mem.indexOf(u8, text, "infoCode=\"040\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<description>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<levelledPara>") != null);
}
