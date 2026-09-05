//! Metadata publishing: Dublin Core, DCAT and schema.org.
//!
//! One artefact record, three published vocabularies. Dublin Core (ISO 15836)
//! for description, DCAT for catalogues, schema.org for search engines and
//! agents that already understand it. All three are emitted from the same
//! `ArtifactMeta`, so a catalogue and a search result cannot disagree.

const std = @import("std");
const ir = @import("../content/ir.zig");
const rdf = @import("../knowledge/rdf.zig");
const timeutil = @import("../core/time.zig");

pub const Dataset = struct {
    identifier: []const u8,
    title: []const u8,
    description: []const u8,
    publisher: []const u8,
    /// Keywords a person or a catalogue would search for.
    keywords: []const []const u8 = &.{},
    license: ?[]const u8 = null,
    /// Theme identifiers, ideally from a published vocabulary.
    themes: []const []const u8 = &.{},
    issued: timeutil.Timestamp,
    modified: timeutil.Timestamp,
    /// Where the data can actually be fetched.
    access_url: ?[]const u8 = null,
    media_type: []const u8 = "application/json",
    byte_size: ?usize = null,
    /// Coverage of a geographic area, when the dataset has one. Bounding box in
    /// decimal degrees, in the ISO 19115 sense.
    spatial: ?BoundingBox = null,
    /// Time span the data covers.
    temporal_start: ?timeutil.Timestamp = null,
    temporal_end: ?timeutil.Timestamp = null,
};

/// ISO 19115 geographic bounding box. Only present when an artefact actually
/// has a geographic extent; most do not, and inventing one is worse than
/// leaving it out.
pub const BoundingBox = struct {
    west: f64,
    east: f64,
    south: f64,
    north: f64,
    /// Coordinate reference system, by its authority code.
    crs: []const u8 = "EPSG:4326",

    pub fn isValid(self: BoundingBox) bool {
        if (self.west < -180 or self.east > 180) return false;
        if (self.south < -90 or self.north > 90) return false;
        return self.west <= self.east and self.south <= self.north;
    }
};

/// Dublin Core terms for one artefact.
pub fn toDublinCore(graph: *rdf.Graph, meta: ir.ArtifactMeta, subject_iri: []const u8) !void {
    const arena = graph.arena;
    // The language subtag lives in the caller's record, which may not outlive
    // the graph, so it is copied into the graph's own memory.
    const language_code = try arena.dupe(u8, meta.lang.languageCode());
    var created: [timeutil.Timestamp.text_len_max]u8 = undefined;
    var modified: [timeutil.Timestamp.text_len_max]u8 = undefined;

    try graph.addLiteral(subject_iri, rdf.dcterms_ns ++ "title", rdf.Literal.langString(meta.title, language_code));
    if (meta.summary) |summary| {
        try graph.addLiteral(subject_iri, rdf.dcterms_ns ++ "description", rdf.Literal.langString(summary, language_code));
    }
    try graph.addLiteral(subject_iri, rdf.dcterms_ns ++ "creator", rdf.Literal.string(meta.creator));
    try graph.addLiteral(subject_iri, rdf.dcterms_ns ++ "type", rdf.Literal.string(meta.kind));
    try graph.addLiteral(subject_iri, rdf.dcterms_ns ++ "language", rdf.Literal.string(language_code));
    try graph.addLiteral(subject_iri, rdf.dcterms_ns ++ "created", rdf.Literal.typed(
        try arena.dupe(u8, meta.created_at.toIso(&created, .second)),
        rdf.xsd ++ "dateTime",
    ));
    try graph.addLiteral(subject_iri, rdf.dcterms_ns ++ "modified", rdf.Literal.typed(
        try arena.dupe(u8, meta.modified_at.toIso(&modified, .second)),
        rdf.xsd ++ "dateTime",
    ));
    if (meta.license) |license| {
        try graph.addLiteral(subject_iri, rdf.dcterms_ns ++ "license", rdf.Literal.string(license));
    }
    for (meta.subjects) |subject| {
        try graph.addLiteral(subject_iri, rdf.dcterms_ns ++ "subject", rdf.Literal.string(subject));
    }
    for (meta.concepts) |concept| {
        const concept_iri = try std.fmt.allocPrint(arena, "https://zag.dev/vocab/workspace/{s}", .{concept});
        try graph.addIri(subject_iri, rdf.dcterms_ns ++ "subject", concept_iri);
    }
    for (meta.standards) |standard| {
        try graph.addLiteral(subject_iri, rdf.dcterms_ns ++ "conformsTo", rdf.Literal.string(standard));
    }
    for (meta.audience) |audience| {
        try graph.addLiteral(subject_iri, rdf.dcterms_ns ++ "audience", rdf.Literal.string(audience));
    }
}

/// DCAT catalogue record for a dataset.
pub fn toDcat(graph: *rdf.Graph, dataset: Dataset, catalog_iri: []const u8) !void {
    const arena = graph.arena;
    const dataset_iri = try std.fmt.allocPrint(arena, "{s}/dataset/{s}", .{ catalog_iri, dataset.identifier });
    const distribution_iri = try std.fmt.allocPrint(arena, "{s}/distribution", .{dataset_iri});

    try graph.addType(catalog_iri, rdf.dcat_ns ++ "Catalog");
    try graph.addIri(catalog_iri, rdf.dcat_ns ++ "dataset", dataset_iri);

    try graph.addType(dataset_iri, rdf.dcat_ns ++ "Dataset");
    try graph.addLiteral(dataset_iri, rdf.dcterms_ns ++ "identifier", rdf.Literal.string(dataset.identifier));
    try graph.addLiteral(dataset_iri, rdf.dcterms_ns ++ "title", rdf.Literal.string(dataset.title));
    try graph.addLiteral(dataset_iri, rdf.dcterms_ns ++ "description", rdf.Literal.string(dataset.description));
    try graph.addLiteral(dataset_iri, rdf.dcterms_ns ++ "publisher", rdf.Literal.string(dataset.publisher));

    var issued: [timeutil.Timestamp.text_len_max]u8 = undefined;
    var modified: [timeutil.Timestamp.text_len_max]u8 = undefined;
    try graph.addLiteral(dataset_iri, rdf.dcterms_ns ++ "issued", rdf.Literal.typed(
        try arena.dupe(u8, dataset.issued.toIso(&issued, .second)),
        rdf.xsd ++ "dateTime",
    ));
    try graph.addLiteral(dataset_iri, rdf.dcterms_ns ++ "modified", rdf.Literal.typed(
        try arena.dupe(u8, dataset.modified.toIso(&modified, .second)),
        rdf.xsd ++ "dateTime",
    ));
    for (dataset.keywords) |keyword| {
        try graph.addLiteral(dataset_iri, rdf.dcat_ns ++ "keyword", rdf.Literal.string(keyword));
    }
    for (dataset.themes) |theme| {
        try graph.addIri(dataset_iri, rdf.dcat_ns ++ "theme", theme);
    }
    if (dataset.license) |license| {
        try graph.addLiteral(dataset_iri, rdf.dcterms_ns ++ "license", rdf.Literal.string(license));
    }

    if (dataset.spatial) |box| {
        // DCAT carries the bounding box as a literal; the CRS is named so that
        // the numbers mean something.
        const geometry = try std.fmt.allocPrint(
            arena,
            "POLYGON(({d} {d}, {d} {d}, {d} {d}, {d} {d}, {d} {d}))",
            .{
                box.west, box.south, box.east, box.south,
                box.east, box.north, box.west, box.north,
                box.west, box.south,
            },
        );
        try graph.addLiteral(dataset_iri, rdf.dcterms_ns ++ "spatial", rdf.Literal.string(geometry));
        try graph.addLiteral(dataset_iri, rdf.zag_ns ++ "coordinateReferenceSystem", rdf.Literal.string(box.crs));
    }
    if (dataset.temporal_start) |start| {
        var buf: [timeutil.Timestamp.text_len_max]u8 = undefined;
        try graph.addLiteral(dataset_iri, rdf.zag_ns ++ "temporalStart", rdf.Literal.typed(
            try arena.dupe(u8, start.toIso(&buf, .second)),
            rdf.xsd ++ "dateTime",
        ));
    }
    if (dataset.temporal_end) |end| {
        var buf: [timeutil.Timestamp.text_len_max]u8 = undefined;
        try graph.addLiteral(dataset_iri, rdf.zag_ns ++ "temporalEnd", rdf.Literal.typed(
            try arena.dupe(u8, end.toIso(&buf, .second)),
            rdf.xsd ++ "dateTime",
        ));
    }

    if (dataset.access_url) |url| {
        try graph.addIri(dataset_iri, rdf.dcat_ns ++ "distribution", distribution_iri);
        try graph.addType(distribution_iri, rdf.dcat_ns ++ "Distribution");
        try graph.addIri(distribution_iri, rdf.dcat_ns ++ "accessURL", url);
        try graph.addLiteral(distribution_iri, rdf.dcat_ns ++ "mediaType", rdf.Literal.string(dataset.media_type));
        if (dataset.byte_size) |size| {
            var buf: [24]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{d}", .{size});
            try graph.addLiteral(distribution_iri, rdf.dcat_ns ++ "byteSize", rdf.Literal.typed(
                try arena.dupe(u8, text),
                rdf.xsd ++ "nonNegativeInteger",
            ));
        }
    }
}

/// schema.org JSON-LD for an artefact, which is what a search engine or a
/// general-purpose agent reads.
pub fn writeSchemaOrg(meta: ir.ArtifactMeta, w: *std.Io.Writer) !void {
    var jw: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    var created: [timeutil.Timestamp.text_len_max]u8 = undefined;
    var modified: [timeutil.Timestamp.text_len_max]u8 = undefined;

    try jw.beginObject();
    try jw.objectField("@context");
    try jw.write("https://schema.org");
    try jw.objectField("@type");
    try jw.write(schemaTypeFor(meta.kind));
    if (meta.identifier_uri) |uri| {
        try jw.objectField("@id");
        try jw.write(uri);
    }
    try jw.objectField("name");
    try jw.write(meta.title);
    if (meta.summary) |summary| {
        try jw.objectField("description");
        try jw.write(summary);
    }
    try jw.objectField("inLanguage");
    try jw.write(meta.lang.languageCode());
    try jw.objectField("dateCreated");
    try jw.write(meta.created_at.toIso(&created, .second));
    try jw.objectField("dateModified");
    try jw.write(meta.modified_at.toIso(&modified, .second));
    try jw.objectField("creator");
    try jw.beginObject();
    try jw.objectField("@type");
    try jw.write("Organization");
    try jw.objectField("name");
    try jw.write(meta.creator);
    try jw.endObject();
    if (meta.license) |license| {
        try jw.objectField("license");
        try jw.write(license);
    }
    if (meta.concepts.len > 0) {
        try jw.objectField("about");
        try jw.beginArray();
        for (meta.concepts) |concept| {
            try jw.beginObject();
            try jw.objectField("@type");
            try jw.write("DefinedTerm");
            try jw.objectField("termCode");
            try jw.write(concept);
            try jw.objectField("inDefinedTermSet");
            try jw.write("https://zag.dev/vocab/workspace");
            try jw.endObject();
        }
        try jw.endArray();
    }
    if (meta.audience.len > 0) {
        try jw.objectField("audience");
        try jw.beginArray();
        for (meta.audience) |audience| {
            try jw.beginObject();
            try jw.objectField("@type");
            try jw.write("Audience");
            try jw.objectField("audienceType");
            try jw.write(audience);
            try jw.endObject();
        }
        try jw.endArray();
    }
    try jw.endObject();
}

fn schemaTypeFor(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "task")) return "HowTo";
    if (std.mem.eql(u8, kind, "dataset")) return "Dataset";
    if (std.mem.eql(u8, kind, "report")) return "Report";
    if (std.mem.eql(u8, kind, "software")) return "SoftwareApplication";
    return "TechArticle";
}

const testing = std.testing;

test "an artefact publishes as dublin core" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idmod = @import("../core/id.zig");
    var gen: idmod.Generator = .init(801, 1_788_000_000_000);
    const document = try ir.sampleDocument(&gen);

    var graph = rdf.Graph.init(arena);
    try toDublinCore(&graph, document.meta, "https://zag.dev/docs/agent-permissions");

    var aw: std.Io.Writer.Allocating = .init(arena);
    try graph.writeTurtle(&aw.writer);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "dcterms:title \"Let an agent change this repository\"@en") != null);
    try testing.expect(std.mem.indexOf(u8, text, "dcterms:conformsTo \"ISO 24495-1\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "dcterms:audience \"new-user\"") != null);
}

test "a dataset publishes as dcat with a distribution" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var graph = rdf.Graph.init(arena);
    try toDcat(&graph, .{
        .identifier = "command-history",
        .title = "Workspace command history",
        .description = "One record for each command a person or an agent ran.",
        .publisher = "the person using the workbench",
        .keywords = &.{ "terminal", "history", "provenance" },
        .license = "Apache-2.0",
        .issued = try timeutil.Timestamp.parseIso("2026-09-04T00:00:00Z"),
        .modified = try timeutil.Timestamp.parseIso("2026-09-04T00:00:00Z"),
        .access_url = "https://zag.dev/api/history",
        .media_type = "application/json",
        .byte_size = 4096,
    }, "https://zag.dev/catalog");

    var aw: std.Io.Writer.Allocating = .init(arena);
    try graph.writeTurtle(&aw.writer);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "a dcat:Catalog") != null);
    try testing.expect(std.mem.indexOf(u8, text, "a dcat:Dataset") != null);
    try testing.expect(std.mem.indexOf(u8, text, "dcat:mediaType \"application/json\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "dcat:byteSize") != null);
}

test "a geographic extent is written only when it is valid" {
    const good: BoundingBox = .{ .west = -1.5, .east = 0.5, .south = 50.0, .north = 52.0 };
    try testing.expect(good.isValid());
    const bad: BoundingBox = .{ .west = 10, .east = -10, .south = 0, .north = 1 };
    try testing.expect(!bad.isValid());

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var graph = rdf.Graph.init(arena);
    try toDcat(&graph, .{
        .identifier = "sites",
        .title = "Deployment sites",
        .description = "Where the daemon runs.",
        .publisher = "operations",
        .issued = timeutil.Timestamp.epoch,
        .modified = timeutil.Timestamp.epoch,
        .spatial = good,
    }, "https://zag.dev/catalog");

    var aw: std.Io.Writer.Allocating = .init(arena);
    try graph.writeTurtle(&aw.writer);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "POLYGON((") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "EPSG:4326") != null);
}

test "an artefact publishes as schema.org json-ld" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idmod = @import("../core/id.zig");
    var gen: idmod.Generator = .init(802, 1_788_000_000_000);
    const document = try ir.sampleDocument(&gen);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeSchemaOrg(document.meta, &aw.writer);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("https://schema.org", root.get("@context").?.string);
    try testing.expectEqualStrings("HowTo", root.get("@type").?.string);
    try testing.expectEqualStrings("en", root.get("inLanguage").?.string);
    const about = root.get("about").?.array;
    try testing.expectEqual(@as(usize, 3), about.items.len);
    try testing.expectEqualStrings("DefinedTerm", about.items[0].object.get("@type").?.string);
}
