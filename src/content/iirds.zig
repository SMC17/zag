//! iiRDS publisher.
//!
//! iiRDS packages technical information with metadata that a delivery system
//! can act on: what the information is about, what kind it is, which product
//! and version it applies to. It is an RDF vocabulary, so the export reuses the
//! same graph writer as SKOS and PROV-O rather than inventing another one.

const std = @import("std");
const ir = @import("ir.zig");
const rdf = @import("../knowledge/rdf.zig");
const timeutil = @import("../core/time.zig");

pub const ns = "http://iirds.tekom.de/iirds#";

pub const InformationType = enum {
    task,
    concept,
    reference,
    troubleshooting,

    pub fn forInformationType(information_type: ir.InformationType) InformationType {
        return switch (information_type) {
            .procedure => .task,
            .concept, .principle, .process => .concept,
            .fact, .structure, .classification => .reference,
        };
    }

    pub fn className(self: InformationType) []const u8 {
        return switch (self) {
            .task => "Task",
            .concept => "Concept",
            .reference => "Reference",
            .troubleshooting => "Troubleshooting",
        };
    }
};

pub const Package = struct {
    /// Base IRI for the package's information units.
    base: []const u8 = "https://zag.dev/iirds/",
    product: []const u8 = "zag workbench",
    product_version: []const u8 = "0.1.0",
};

/// Add a document to an RDF graph as iiRDS information units: one for the
/// document, one for each top-level section.
pub fn toGraph(graph: *rdf.Graph, document: ir.Document, package: Package) !void {
    const arena = graph.arena;
    const language_code = try arena.dupe(u8, document.meta.lang.languageCode());
    var id_buf: [@TypeOf(document.meta.id).text_len]u8 = undefined;
    const id = document.meta.id.toText(&id_buf);

    const package_iri = try std.fmt.allocPrint(arena, "{s}package/{s}", .{ package.base, id });
    const unit_iri = try std.fmt.allocPrint(arena, "{s}unit/{s}", .{ package.base, id });
    const component_iri = try std.fmt.allocPrint(arena, "{s}component/{s}", .{ package.base, package.product_version });

    try graph.addType(package_iri, ns ++ "Package");
    try graph.addIri(package_iri, ns ++ "has-info-unit", unit_iri);
    try graph.addLiteral(package_iri, ns ++ "iiRDS-version", rdf.Literal.string("1.2"));

    try graph.addType(unit_iri, ns ++ "InformationUnit");
    try graph.addType(unit_iri, ns ++ "Topic");
    try graph.addLiteral(unit_iri, ns ++ "title", rdf.Literal.langString(document.meta.title, language_code));
    try graph.addLiteral(unit_iri, rdf.dcterms_ns ++ "language", rdf.Literal.string(language_code));
    try graph.addLiteral(unit_iri, rdf.dcterms_ns ++ "creator", rdf.Literal.string(document.meta.creator));

    var created_buf: [timeutil.Timestamp.text_len_max]u8 = undefined;
    try graph.addLiteral(unit_iri, rdf.dcterms_ns ++ "created", rdf.Literal.typed(
        try arena.dupe(u8, document.meta.created_at.toIso(&created_buf, .second)),
        rdf.xsd ++ "dateTime",
    ));
    if (document.meta.summary) |summary| {
        try graph.addLiteral(unit_iri, rdf.dcterms_ns ++ "abstract", rdf.Literal.string(summary));
    }
    if (document.meta.license) |license| {
        try graph.addLiteral(unit_iri, rdf.dcterms_ns ++ "rights", rdf.Literal.string(license));
    }

    // The product this information applies to.
    try graph.addType(component_iri, ns ++ "Component");
    try graph.addLiteral(component_iri, ns ++ "title", rdf.Literal.string(package.product));
    try graph.addLiteral(component_iri, ns ++ "has-product-version", rdf.Literal.string(package.product_version));
    try graph.addIri(unit_iri, ns ++ "relates-to-component", component_iri);

    // Subjects come from the workspace concept identifiers, so delivery systems
    // filter on the same concepts the workbench reasons about.
    for (document.meta.concepts) |concept| {
        const concept_iri = try std.fmt.allocPrint(arena, "https://zag.dev/vocab/workspace/{s}", .{concept});
        try graph.addIri(unit_iri, ns ++ "has-subject", concept_iri);
    }
    for (document.meta.audience) |audience| {
        const audience_iri = try std.fmt.allocPrint(arena, "{s}audience/{s}", .{ package.base, audience });
        try graph.addType(audience_iri, ns ++ "Party");
        try graph.addIri(unit_iri, ns ++ "is-applicable-for", audience_iri);
    }

    for (document.body, 0..) |node, index| {
        switch (node) {
            .section => |section| {
                const section_iri = try std.fmt.allocPrint(arena, "{s}unit/{s}-{d}", .{ package.base, id, index });
                const kind = InformationType.forInformationType(section.information_type);
                try graph.addType(section_iri, ns ++ "InformationUnit");
                try graph.addType(section_iri, ns ++ "Topic");
                try graph.addIri(section_iri, ns ++ "has-information-type", try std.fmt.allocPrint(arena, "{s}{s}", .{ ns, kind.className() }));
                try graph.addLiteral(section_iri, ns ++ "title", rdf.Literal.langString(section.title, language_code));
                try graph.addIri(unit_iri, rdf.dcterms_ns ++ "hasPart", section_iri);
                try graph.addIri(package_iri, ns ++ "has-info-unit", section_iri);
            },
            else => {},
        }
    }
}

pub fn writeTurtle(arena: std.mem.Allocator, document: ir.Document, package: Package, w: *std.Io.Writer) !void {
    var graph = rdf.Graph.init(arena);
    const prefixes = try arena.alloc(rdf.Prefix, rdf.default_prefixes.len + 1);
    @memcpy(prefixes[0..rdf.default_prefixes.len], &rdf.default_prefixes);
    prefixes[rdf.default_prefixes.len] = .{ .name = "iirds", .iri = ns };
    graph.prefixes = prefixes;

    try toGraph(&graph, document, package);
    try graph.writeTurtle(w);
}

const testing = std.testing;

test "a document exports as an iirds package" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idmod = @import("../core/id.zig");
    var gen: idmod.Generator = .init(741, 1_788_000_000_000);
    const document = try ir.sampleDocument(&gen);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeTurtle(arena, document, .{}, &aw.writer);
    const text = aw.written();

    try testing.expect(std.mem.indexOf(u8, text, "@prefix iirds:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "a iirds:Package") != null);
    try testing.expect(std.mem.indexOf(u8, text, "iirds:has-information-type iirds:Task") != null);
    try testing.expect(std.mem.indexOf(u8, text, "iirds:has-information-type iirds:Concept") != null);
    try testing.expect(std.mem.indexOf(u8, text, "iirds:relates-to-component") != null);
    // Subjects point at the same concept identifiers the workbench uses.
    try testing.expect(std.mem.indexOf(u8, text, "https://zag.dev/vocab/workspace/capability") != null);
}
