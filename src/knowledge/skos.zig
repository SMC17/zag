//! SKOS export of a concept system.
//!
//! The concept system is authored as Zig data and validated against ISO 704.
//! This module publishes it as SKOS so that other tools — search engines,
//! catalogues, other agents — can consume the same vocabulary without reading
//! our source. Deprecated terms become `skos:hiddenLabel`, which is exactly
//! their purpose: findable, never displayed.

const std = @import("std");
const rdf = @import("rdf.zig");
const concepts = @import("concepts.zig");

pub const Scheme = struct {
    iri: []const u8,
    title: []const u8,
    description: []const u8 = "",
    /// Base IRI for concepts; the concept identifier is appended.
    concept_base: []const u8,
    publisher: []const u8 = "zag",
    language: []const u8 = "en",
};

/// Add the whole concept system to `graph` as a SKOS concept scheme.
pub fn toGraph(graph: *rdf.Graph, system: concepts.ConceptSystem, scheme: Scheme) !void {
    const arena = graph.arena;

    try graph.addType(scheme.iri, rdf.skos_ns ++ "ConceptScheme");
    try graph.addLiteral(scheme.iri, rdf.dcterms_ns ++ "title", rdf.Literal.langString(scheme.title, scheme.language));
    if (scheme.description.len > 0) {
        try graph.addLiteral(scheme.iri, rdf.dcterms_ns ++ "description", rdf.Literal.langString(scheme.description, scheme.language));
    }
    try graph.addLiteral(scheme.iri, rdf.dcterms_ns ++ "publisher", rdf.Literal.string(scheme.publisher));

    var it = system.concepts.iterator();
    while (it.next()) |entry| {
        const c = entry.value_ptr.*;
        const iri = try std.fmt.allocPrint(arena, "{s}{s}", .{ scheme.concept_base, c.id });

        try graph.addType(iri, rdf.skos_ns ++ "Concept");
        try graph.addIri(iri, rdf.skos_ns ++ "inScheme", scheme.iri);
        try graph.addLiteral(iri, rdf.skos_ns ++ "prefLabel", rdf.Literal.langString(c.preferred, scheme.language));
        try graph.addLiteral(iri, rdf.skos_ns ++ "definition", rdf.Literal.langString(c.definition, scheme.language));

        for (c.designations) |d| {
            const predicate = switch (d.status) {
                .preferred => rdf.skos_ns ++ "prefLabel",
                .admitted => rdf.skos_ns ++ "altLabel",
                // A deprecated term stays searchable but must not be shown.
                .deprecated => rdf.skos_ns ++ "hiddenLabel",
            };
            try graph.addLiteral(iri, predicate, rdf.Literal.langString(d.text, scheme.language));
        }

        for (c.relations) |r| {
            const target_iri = try std.fmt.allocPrint(arena, "{s}{s}", .{ scheme.concept_base, r.target });
            switch (r.kind) {
                .generic => {
                    try graph.addIri(iri, rdf.skos_ns ++ "broader", target_iri);
                    try graph.addIri(target_iri, rdf.skos_ns ++ "narrower", iri);
                },
                .partitive => {
                    // SKOS has no partitive relation, so the pair is published
                    // as broader plus an explicit workspace-vocabulary relation
                    // rather than losing the distinction.
                    try graph.addIri(iri, rdf.skos_ns ++ "broader", target_iri);
                    try graph.addIri(target_iri, rdf.skos_ns ++ "narrower", iri);
                    try graph.addIri(iri, rdf.zag_ns ++ "partOf", target_iri);
                },
                .associative => {
                    try graph.addIri(iri, rdf.skos_ns ++ "related", target_iri);
                    try graph.addIri(target_iri, rdf.skos_ns ++ "related", iri);
                },
            }
        }

        if (c.top_concept) {
            try graph.addIri(iri, rdf.skos_ns ++ "topConceptOf", scheme.iri);
            try graph.addIri(scheme.iri, rdf.skos_ns ++ "hasTopConcept", iri);
        }
        if (c.note) |note| {
            try graph.addLiteral(iri, rdf.skos_ns ++ "scopeNote", rdf.Literal.langString(note, scheme.language));
        }
        for (c.examples) |example| {
            try graph.addLiteral(iri, rdf.skos_ns ++ "example", rdf.Literal.langString(example, scheme.language));
        }
        if (c.source) |source| {
            try graph.addLiteral(iri, rdf.dcterms_ns ++ "source", rdf.Literal.string(source));
        }
        try graph.addLiteral(iri, rdf.dcterms_ns ++ "subject", rdf.Literal.string(c.subject_field));
    }
}

/// Convenience: build a fresh graph containing only the concept scheme.
pub fn buildGraph(arena: std.mem.Allocator, system: concepts.ConceptSystem, scheme: Scheme) !rdf.Graph {
    var graph = rdf.Graph.init(arena);
    try toGraph(&graph, system, scheme);
    return graph;
}

pub const default_scheme: Scheme = .{
    .iri = "https://zag.dev/vocab/workspace",
    .title = "zag workspace vocabulary",
    .description = "Concepts used by the zag workbench for workspaces, sessions, blocks, agents and evidence.",
    .concept_base = "https://zag.dev/vocab/workspace/",
};

test "concept system exports as skos" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var system = concepts.ConceptSystem.init(arena);
    try system.add(.{ .id = "env", .preferred = "development environment", .definition = "tools used to change software", .top_concept = true });
    try system.add(.{
        .id = "workspace",
        .preferred = "workspace",
        .definition = "development environment with durable state",
        .designations = &.{ .{ .text = "bench", .status = .admitted }, .{ .text = "project shell", .status = .deprecated } },
        .relations = &.{.{ .kind = .generic, .target = "env" }},
        .examples = &.{"the workspace open in the current window"},
    });

    var graph = try buildGraph(arena, system, default_scheme);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try graph.writeTurtle(&aw.writer);
    const text = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "a skos:ConceptScheme") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "skos:hiddenLabel \"project shell\"@en") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "skos:altLabel \"bench\"@en") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "skos:topConceptOf") != null);

    const broader = try graph.match(
        "https://zag.dev/vocab/workspace/workspace",
        rdf.skos_ns ++ "broader",
        "https://zag.dev/vocab/workspace/env",
    );
    try std.testing.expectEqual(@as(usize, 1), broader.items.len);

    const narrower = try graph.match(
        "https://zag.dev/vocab/workspace/env",
        rdf.skos_ns ++ "narrower",
        null,
    );
    try std.testing.expectEqual(@as(usize, 1), narrower.items.len);
}

test "partitive relations keep their distinction" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var system = concepts.ConceptSystem.init(arena);
    try system.add(.{ .id = "workspace", .preferred = "workspace", .definition = "durable development environment", .top_concept = true });
    try system.add(.{ .id = "session", .preferred = "session", .definition = "workspace element that runs one program", .relations = &.{.{ .kind = .partitive, .target = "workspace" }} });

    var graph = try buildGraph(arena, system, default_scheme);
    const part_of = try graph.match(null, rdf.zag_ns ++ "partOf", null);
    try std.testing.expectEqual(@as(usize, 1), part_of.items.len);
}
