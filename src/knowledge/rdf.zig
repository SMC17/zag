//! A small RDF 1.1 graph with N-Triples, Turtle and JSON-LD serialisation.
//!
//! The workspace keeps its transactional state in ordinary typed Zig records.
//! This module is the *export* face of that state: concepts, artefacts, events,
//! evidence and datasets become explicit relations that another system can read
//! without guessing. That is what makes the knowledge layer interoperable
//! rather than merely searchable.

const std = @import("std");

pub const xsd = "http://www.w3.org/2001/XMLSchema#";
pub const rdf_ns = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
pub const rdfs_ns = "http://www.w3.org/2000/01/rdf-schema#";
pub const owl_ns = "http://www.w3.org/2002/07/owl#";
pub const skos_ns = "http://www.w3.org/2004/02/skos/core#";
pub const dcterms_ns = "http://purl.org/dc/terms/";
pub const dcat_ns = "http://www.w3.org/ns/dcat#";
pub const prov_ns = "http://www.w3.org/ns/prov#";
pub const schema_ns = "https://schema.org/";
/// The workspace's own vocabulary.
pub const zag_ns = "https://zag.dev/ns/workspace#";

pub const Literal = struct {
    lexical: []const u8,
    datatype: ?[]const u8 = null,
    language: ?[]const u8 = null,

    pub fn string(value: []const u8) Literal {
        return .{ .lexical = value };
    }

    pub fn langString(value: []const u8, language: []const u8) Literal {
        return .{ .lexical = value, .language = language };
    }

    pub fn typed(value: []const u8, datatype: []const u8) Literal {
        return .{ .lexical = value, .datatype = datatype };
    }

    pub fn boolean(value: bool) Literal {
        return .{ .lexical = if (value) "true" else "false", .datatype = xsd ++ "boolean" };
    }
};

pub const Term = union(enum) {
    iri: []const u8,
    blank: []const u8,
    literal: Literal,

    pub fn writeNt(self: Term, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .iri => |i| try w.print("<{s}>", .{i}),
            .blank => |b| try w.print("_:{s}", .{b}),
            .literal => |l| {
                try w.writeAll("\"");
                try writeEscaped(l.lexical, w);
                try w.writeAll("\"");
                if (l.language) |lang| {
                    try w.print("@{s}", .{lang});
                } else if (l.datatype) |dt| {
                    try w.print("^^<{s}>", .{dt});
                }
            },
        }
    }
};

pub const Triple = struct {
    subject: Term,
    predicate: []const u8,
    object: Term,
};

fn writeEscaped(text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (text) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

pub const Prefix = struct { name: []const u8, iri: []const u8 };

/// The prefixes every export uses, so generated files stay readable.
pub const default_prefixes = [_]Prefix{
    .{ .name = "rdf", .iri = rdf_ns },
    .{ .name = "rdfs", .iri = rdfs_ns },
    .{ .name = "owl", .iri = owl_ns },
    .{ .name = "xsd", .iri = xsd },
    .{ .name = "skos", .iri = skos_ns },
    .{ .name = "dcterms", .iri = dcterms_ns },
    .{ .name = "dcat", .iri = dcat_ns },
    .{ .name = "prov", .iri = prov_ns },
    .{ .name = "schema", .iri = schema_ns },
    .{ .name = "zag", .iri = zag_ns },
};

pub const Graph = struct {
    arena: std.mem.Allocator,
    triples: std.ArrayList(Triple) = .empty,
    prefixes: []const Prefix = &default_prefixes,

    pub fn init(arena: std.mem.Allocator) Graph {
        return .{ .arena = arena };
    }

    pub fn add(self: *Graph, triple: Triple) !void {
        try self.triples.append(self.arena, triple);
    }

    pub fn addIri(self: *Graph, subject: []const u8, predicate: []const u8, object: []const u8) !void {
        try self.add(.{ .subject = .{ .iri = subject }, .predicate = predicate, .object = .{ .iri = object } });
    }

    pub fn addLiteral(self: *Graph, subject: []const u8, predicate: []const u8, literal: Literal) !void {
        try self.add(.{ .subject = .{ .iri = subject }, .predicate = predicate, .object = .{ .literal = literal } });
    }

    pub fn addType(self: *Graph, subject: []const u8, class: []const u8) !void {
        try self.addIri(subject, rdf_ns ++ "type", class);
    }

    pub fn count(self: Graph) usize {
        return self.triples.items.len;
    }

    /// Every triple whose subject, predicate or object matches. A null pattern
    /// element matches anything.
    pub fn match(
        self: Graph,
        subject: ?[]const u8,
        predicate: ?[]const u8,
        object: ?[]const u8,
    ) !std.ArrayList(Triple) {
        var out: std.ArrayList(Triple) = .empty;
        for (self.triples.items) |t| {
            if (subject) |s| {
                const value = switch (t.subject) {
                    .iri, .blank => |v| v,
                    .literal => continue,
                };
                if (!std.mem.eql(u8, value, s)) continue;
            }
            if (predicate) |p| {
                if (!std.mem.eql(u8, t.predicate, p)) continue;
            }
            if (object) |o| {
                const value = switch (t.object) {
                    .iri, .blank => |v| v,
                    .literal => |l| l.lexical,
                };
                if (!std.mem.eql(u8, value, o)) continue;
            }
            try out.append(self.arena, t);
        }
        return out;
    }

    pub fn writeNTriples(self: Graph, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.triples.items) |t| {
            try t.subject.writeNt(w);
            try w.print(" <{s}> ", .{t.predicate});
            try t.object.writeNt(w);
            try w.writeAll(" .\n");
        }
    }

    pub fn writeTurtle(self: Graph, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.prefixes) |p| {
            try w.print("@prefix {s}: <{s}> .\n", .{ p.name, p.iri });
        }
        try w.writeAll("\n");
        for (self.triples.items) |t| {
            try self.writeTerm(t.subject, w);
            try w.writeAll(" ");
            try self.writeIriCompact(t.predicate, w);
            try w.writeAll(" ");
            try self.writeTerm(t.object, w);
            try w.writeAll(" .\n");
        }
    }

    fn writeTerm(self: Graph, term: Term, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (term) {
            .iri => |i| try self.writeIriCompact(i, w),
            .blank => |b| try w.print("_:{s}", .{b}),
            .literal => |l| {
                try w.writeAll("\"");
                try writeEscaped(l.lexical, w);
                try w.writeAll("\"");
                if (l.language) |lang| {
                    try w.print("@{s}", .{lang});
                } else if (l.datatype) |dt| {
                    try w.writeAll("^^");
                    try self.writeIriCompact(dt, w);
                }
            },
        }
    }

    fn writeIriCompact(self: Graph, iri: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (std.mem.eql(u8, iri, rdf_ns ++ "type")) {
            try w.writeAll("a");
            return;
        }
        for (self.prefixes) |p| {
            if (std.mem.startsWith(u8, iri, p.iri)) {
                const local = iri[p.iri.len..];
                if (isSafeLocalName(local)) {
                    try w.print("{s}:{s}", .{ p.name, local });
                    return;
                }
            }
        }
        try w.print("<{s}>", .{iri});
    }

    fn isSafeLocalName(local: []const u8) bool {
        if (local.len == 0) return false;
        if (std.ascii.isDigit(local[0])) return false;
        for (local) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
        }
        return true;
    }

    /// JSON-LD 1.1 in expanded-with-context form: a `@context` built from the
    /// graph prefixes and one node object per subject.
    pub fn writeJsonLd(self: Graph, w: *std.Io.Writer) !void {
        var jw: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
        try jw.beginObject();
        try jw.objectField("@context");
        try jw.beginObject();
        for (self.prefixes) |p| {
            try jw.objectField(p.name);
            try jw.write(p.iri);
        }
        try jw.endObject();

        try jw.objectField("@graph");
        try jw.beginArray();

        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (self.triples.items) |t| {
            const subject = switch (t.subject) {
                .iri, .blank => |v| v,
                .literal => continue,
            };
            if (seen.contains(subject)) continue;
            try seen.put(self.arena, subject, {});

            try jw.beginObject();
            try jw.objectField("@id");
            try jw.write(self.compactAlloc(subject) catch subject);

            var predicates: std.StringArrayHashMapUnmanaged(void) = .empty;
            for (self.triples.items) |inner| {
                const inner_subject = switch (inner.subject) {
                    .iri, .blank => |v| v,
                    .literal => continue,
                };
                if (!std.mem.eql(u8, inner_subject, subject)) continue;
                if (predicates.contains(inner.predicate)) continue;
                try predicates.put(self.arena, inner.predicate, {});

                const key = if (std.mem.eql(u8, inner.predicate, rdf_ns ++ "type"))
                    "@type"
                else
                    self.compactAlloc(inner.predicate) catch inner.predicate;
                try jw.objectField(key);

                var values: std.ArrayList(Term) = .empty;
                for (self.triples.items) |v| {
                    const v_subject = switch (v.subject) {
                        .iri, .blank => |x| x,
                        .literal => continue,
                    };
                    if (!std.mem.eql(u8, v_subject, subject)) continue;
                    if (!std.mem.eql(u8, v.predicate, inner.predicate)) continue;
                    try values.append(self.arena, v.object);
                }
                if (values.items.len == 1) {
                    try self.writeJsonValue(&jw, values.items[0]);
                } else {
                    try jw.beginArray();
                    for (values.items) |v| try self.writeJsonValue(&jw, v);
                    try jw.endArray();
                }
            }
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
    }

    fn writeJsonValue(self: Graph, jw: *std.json.Stringify, term: Term) !void {
        switch (term) {
            .iri => |i| {
                const compact = self.compactAlloc(i) catch i;
                try jw.beginObject();
                try jw.objectField("@id");
                try jw.write(compact);
                try jw.endObject();
            },
            .blank => |b| {
                try jw.beginObject();
                try jw.objectField("@id");
                try jw.print("\"_:{s}\"", .{b});
                try jw.endObject();
            },
            .literal => |l| {
                if (l.language == null and l.datatype == null) {
                    try jw.write(l.lexical);
                    return;
                }
                try jw.beginObject();
                try jw.objectField("@value");
                try jw.write(l.lexical);
                if (l.language) |lang| {
                    try jw.objectField("@language");
                    try jw.write(lang);
                }
                if (l.datatype) |dt| {
                    try jw.objectField("@type");
                    try jw.write(self.compactAlloc(dt) catch dt);
                }
                try jw.endObject();
            },
        }
    }

    fn compactAlloc(self: Graph, iri: []const u8) ![]const u8 {
        for (self.prefixes) |p| {
            if (std.mem.startsWith(u8, iri, p.iri)) {
                const local = iri[p.iri.len..];
                if (isSafeLocalName(local)) {
                    return std.fmt.allocPrint(self.arena, "{s}:{s}", .{ p.name, local });
                }
            }
        }
        return iri;
    }
};

test "graph serialises to n-triples and turtle" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var g = Graph.init(arena_state.allocator());

    try g.addType(zag_ns ++ "Block42", zag_ns ++ "ExecutionArtifact");
    try g.addLiteral(zag_ns ++ "Block42", skos_ns ++ "prefLabel", Literal.langString("pseudoterminal", "en"));
    try g.addIri(zag_ns ++ "Block42", zag_ns ++ "executedBy", zag_ns ++ "Agent17");

    var aw: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try g.writeNTriples(&aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "<https://zag.dev/ns/workspace#Block42>") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"pseudoterminal\"@en") != null);

    var tw: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try g.writeTurtle(&tw.writer);
    try std.testing.expect(std.mem.indexOf(u8, tw.written(), "@prefix skos:") != null);
    try std.testing.expect(std.mem.indexOf(u8, tw.written(), "zag:Block42 a zag:ExecutionArtifact .") != null);
}

test "graph serialises to json-ld with a context" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g = Graph.init(arena);
    try g.addType(zag_ns ++ "Concept1", skos_ns ++ "Concept");
    try g.addLiteral(zag_ns ++ "Concept1", skos_ns ++ "prefLabel", Literal.langString("workspace", "en"));
    try g.addLiteral(zag_ns ++ "Concept1", skos_ns ++ "altLabel", Literal.langString("bench", "en"));

    var aw: std.Io.Writer.Allocating = .init(arena);
    try g.writeJsonLd(&aw.writer);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.contains("@context"));
    const graph = root.get("@graph").?.array;
    try std.testing.expectEqual(@as(usize, 1), graph.items.len);
    const node = graph.items[0].object;
    try std.testing.expectEqualStrings("zag:Concept1", node.get("@id").?.string);
    try std.testing.expectEqualStrings("skos:Concept", node.get("@type").?.object.get("@id").?.string);
    try std.testing.expectEqualStrings("workspace", node.get("skos:prefLabel").?.object.get("@value").?.string);
}

test "pattern matching finds relations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var g = Graph.init(arena_state.allocator());
    try g.addIri("urn:a", zag_ns ++ "modifiedBy", "urn:agent");
    try g.addIri("urn:b", zag_ns ++ "modifiedBy", "urn:agent");
    try g.addIri("urn:c", zag_ns ++ "modifiedBy", "urn:human");

    const by_agent = try g.match(null, zag_ns ++ "modifiedBy", "urn:agent");
    try std.testing.expectEqual(@as(usize, 2), by_agent.items.len);

    const about_a = try g.match("urn:a", null, null);
    try std.testing.expectEqual(@as(usize, 1), about_a.items.len);
}
