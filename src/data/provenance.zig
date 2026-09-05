//! Provenance for everything the workbench produces.
//!
//! A generated patch, a summary, a metric or a dataset is only trustworthy if
//! the system can say how it came about. This record answers: who produced it,
//! with which model and instructions, from which sources, using which tools, in
//! which environment, over which period, and what the result hashes to.
//!
//! It is serialised to W3C PROV-O for exchange, and it is the raw material for
//! ISO/IEC 42001 traceability, ISO/IEC 23894 risk evidence, records management
//! under ISO 15489, and the generated model and system documentation.

const std = @import("std");
const id = @import("../core/id.zig");
const hashing = @import("../core/hash.zig");
const timeutil = @import("../core/time.zig");
const rdf = @import("../knowledge/rdf.zig");

pub const Hash = hashing.Hash;
pub const Timestamp = timeutil.Timestamp;

/// What kind of party produced an artefact. Kept separate from the actor's
/// identifier because "a person did this" and "a model did this" carry
/// different obligations under every AI governance framework we follow.
pub const ProducerKind = enum {
    person,
    shell,
    agent,
    background_agent,
    remote_person,
    system,
    integration,

    pub fn isAutomated(self: ProducerKind) bool {
        return switch (self) {
            .person, .remote_person => false,
            else => true,
        };
    }
};

pub const ModelIdentity = struct {
    /// Provider as configured, for example "anthropic" or "local".
    provider: []const u8,
    /// Model identifier exactly as the provider names it.
    model: []const u8,
    /// Version or snapshot, when the provider exposes one.
    version: ?[]const u8 = null,
    /// Sampling settings that affect reproducibility.
    temperature: ?f32 = null,
    seed: ?u64 = null,
};

pub const ToolIdentity = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    /// Hash of the tool binary or script, when the workbench can compute it.
    digest: ?Hash = null,
};

/// Enough of the environment to explain a difference between two runs.
pub const EnvironmentFingerprint = struct {
    operating_system: []const u8,
    architecture: []const u8,
    shell: ?[]const u8 = null,
    /// Hash over the variables the run was allowed to see, never their values.
    environment_digest: ?Hash = null,
    container_image: ?[]const u8 = null,
    host_label: ?[]const u8 = null,

    pub fn current() EnvironmentFingerprint {
        const builtin = @import("builtin");
        return .{
            .operating_system = @tagName(builtin.os.tag),
            .architecture = @tagName(builtin.cpu.arch),
        };
    }
};

pub const Provenance = struct {
    producer: id.ActorId,
    producer_kind: ProducerKind,
    source_artifacts: []const id.ArtifactId = &.{},
    source_events: []const id.EventId = &.{},
    model: ?ModelIdentity = null,
    /// Hash of the instruction template, not the filled-in prompt, so that
    /// provenance can be published without leaking the content of a session.
    prompt_template: ?Hash = null,
    toolchain: []const ToolIdentity = &.{},
    environment: EnvironmentFingerprint,
    started_at: Timestamp,
    completed_at: Timestamp,
    /// Hash of the produced content.
    content_hash: Hash,
    /// Free-text statement of what was being attempted.
    activity: []const u8 = "",

    pub fn duration(self: Provenance) timeutil.Duration {
        return self.completed_at.since(self.started_at);
    }

    pub fn wasAutomated(self: Provenance) bool {
        return self.producer_kind.isAutomated();
    }

    /// Add this provenance to an RDF graph as a PROV-O activity.
    pub fn toGraph(self: Provenance, graph: *rdf.Graph, subject_iri: []const u8) !void {
        const arena = graph.arena;
        var producer_buf: [id.ActorId.text_len]u8 = undefined;
        const producer_text = self.producer.toText(&producer_buf);
        const agent_iri = try std.fmt.allocPrint(arena, "{s}actor/{s}", .{ rdf.zag_ns, producer_text });
        const activity_iri = try std.fmt.allocPrint(arena, "{s}#activity", .{subject_iri});

        try graph.addType(subject_iri, rdf.prov_ns ++ "Entity");
        try graph.addType(activity_iri, rdf.prov_ns ++ "Activity");
        try graph.addType(agent_iri, rdf.prov_ns ++ "Agent");
        try graph.addIri(subject_iri, rdf.prov_ns ++ "wasGeneratedBy", activity_iri);
        try graph.addIri(subject_iri, rdf.prov_ns ++ "wasAttributedTo", agent_iri);
        try graph.addIri(activity_iri, rdf.prov_ns ++ "wasAssociatedWith", agent_iri);
        try graph.addLiteral(agent_iri, rdf.zag_ns ++ "producerKind", rdf.Literal.string(@tagName(self.producer_kind)));

        var start_buf: [Timestamp.text_len_max]u8 = undefined;
        var end_buf: [Timestamp.text_len_max]u8 = undefined;
        try graph.addLiteral(activity_iri, rdf.prov_ns ++ "startedAtTime", rdf.Literal.typed(
            try arena.dupe(u8, self.started_at.toIso(&start_buf, .millisecond)),
            rdf.xsd ++ "dateTime",
        ));
        try graph.addLiteral(activity_iri, rdf.prov_ns ++ "endedAtTime", rdf.Literal.typed(
            try arena.dupe(u8, self.completed_at.toIso(&end_buf, .millisecond)),
            rdf.xsd ++ "dateTime",
        ));

        var hash_buf: [Hash.text_len]u8 = undefined;
        try graph.addLiteral(subject_iri, rdf.zag_ns ++ "contentHash", rdf.Literal.string(
            try arena.dupe(u8, self.content_hash.toText(&hash_buf)),
        ));

        if (self.model) |m| {
            const model_iri = try std.fmt.allocPrint(arena, "{s}model/{s}/{s}", .{ rdf.zag_ns, m.provider, m.model });
            try graph.addType(model_iri, rdf.zag_ns ++ "Model");
            try graph.addIri(activity_iri, rdf.zag_ns ++ "usedModel", model_iri);
            try graph.addLiteral(model_iri, rdf.zag_ns ++ "provider", rdf.Literal.string(m.provider));
            try graph.addLiteral(model_iri, rdf.zag_ns ++ "modelName", rdf.Literal.string(m.model));
            if (m.version) |v| try graph.addLiteral(model_iri, rdf.zag_ns ++ "modelVersion", rdf.Literal.string(v));
        }
        for (self.toolchain) |t| {
            const tool_iri = try std.fmt.allocPrint(arena, "{s}tool/{s}", .{ rdf.zag_ns, t.name });
            try graph.addType(tool_iri, rdf.zag_ns ++ "Tool");
            try graph.addIri(activity_iri, rdf.prov_ns ++ "used", tool_iri);
            if (t.version) |v| try graph.addLiteral(tool_iri, rdf.zag_ns ++ "toolVersion", rdf.Literal.string(v));
        }
        for (self.source_artifacts) |source| {
            var buf: [id.ArtifactId.text_len]u8 = undefined;
            const source_iri = try std.fmt.allocPrint(arena, "{s}artifact/{s}", .{ rdf.zag_ns, source.toText(&buf) });
            try graph.addIri(subject_iri, rdf.prov_ns ++ "wasDerivedFrom", source_iri);
            try graph.addIri(activity_iri, rdf.prov_ns ++ "used", source_iri);
        }
        if (self.activity.len > 0) {
            try graph.addLiteral(activity_iri, rdf.rdfs_ns ++ "label", rdf.Literal.string(self.activity));
        }
    }

    /// The questions a reviewer asks about a generated change, and whether this
    /// record can answer them. Used by the transparency checks.
    pub const Completeness = struct {
        has_producer: bool,
        has_sources: bool,
        has_model: bool,
        has_toolchain: bool,
        has_environment: bool,
        has_period: bool,
        has_content_hash: bool,

        pub fn score(self: Completeness) f32 {
            var count: f32 = 0;
            inline for (std.meta.fields(Completeness)) |f| {
                if (@field(self, f.name)) count += 1;
            }
            return count / @as(f32, @floatFromInt(std.meta.fields(Completeness).len));
        }

        pub fn isComplete(self: Completeness) bool {
            return self.score() == 1.0;
        }
    };

    pub fn completeness(self: Provenance) Completeness {
        return .{
            .has_producer = true,
            .has_sources = self.source_artifacts.len > 0 or self.source_events.len > 0,
            .has_model = self.model != null or !self.producer_kind.isAutomated(),
            .has_toolchain = self.toolchain.len > 0,
            .has_environment = self.environment.operating_system.len > 0,
            .has_period = self.completed_at.ns >= self.started_at.ns,
            .has_content_hash = !self.content_hash.eql(Hash.zero),
        };
    }
};

test "provenance answers the review questions" {
    var gen: id.Generator = .init(5, 1_788_000_000_000);
    const p: Provenance = .{
        .producer = gen.next(id.ActorId),
        .producer_kind = .agent,
        .source_artifacts = &.{gen.next(id.ArtifactId)},
        .model = .{ .provider = "anthropic", .model = "claude-opus-5", .version = "2026-08" },
        .toolchain = &.{.{ .name = "zig", .version = "0.16.0" }},
        .environment = EnvironmentFingerprint.current(),
        .started_at = try Timestamp.parseIso("2026-09-04T20:41:00Z"),
        .completed_at = try Timestamp.parseIso("2026-09-04T20:41:31Z"),
        .content_hash = Hash.of("patch"),
        .activity = "apply the parser fix",
    };

    try std.testing.expect(p.wasAutomated());
    try std.testing.expectEqual(@as(i64, 31), p.duration().seconds());
    try std.testing.expect(p.completeness().isComplete());
}

test "incomplete provenance is reported, not assumed" {
    var gen: id.Generator = .init(6, 1_788_000_000_000);
    const p: Provenance = .{
        .producer = gen.next(id.ActorId),
        .producer_kind = .agent,
        .environment = EnvironmentFingerprint.current(),
        .started_at = Timestamp.epoch,
        .completed_at = Timestamp.epoch,
        .content_hash = Hash.zero,
    };
    const c = p.completeness();
    try std.testing.expect(!c.isComplete());
    try std.testing.expect(!c.has_model);
    try std.testing.expect(!c.has_sources);
    try std.testing.expect(!c.has_content_hash);
    try std.testing.expect(c.score() < 1.0);
}

test "provenance exports as prov-o" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: id.Generator = .init(7, 1_788_000_000_000);
    const p: Provenance = .{
        .producer = gen.next(id.ActorId),
        .producer_kind = .agent,
        .model = .{ .provider = "local", .model = "small-coder" },
        .toolchain = &.{.{ .name = "git", .version = "2.51" }},
        .environment = EnvironmentFingerprint.current(),
        .started_at = try Timestamp.parseIso("2026-09-04T20:00:00Z"),
        .completed_at = try Timestamp.parseIso("2026-09-04T20:00:10Z"),
        .content_hash = Hash.of("diff"),
        .activity = "rewrite the block index",
    };

    var graph = rdf.Graph.init(arena);
    try p.toGraph(&graph, "https://zag.dev/artifact/1");

    var aw: std.Io.Writer.Allocating = .init(arena);
    try graph.writeTurtle(&aw.writer);
    const text = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "prov:wasGeneratedBy") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "zag:usedModel") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "prov:startedAtTime") != null);
}
