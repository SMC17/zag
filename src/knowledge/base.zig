//! The workspace knowledge base.
//!
//! Rules, prompts, workflows, notebooks, skills, server definitions and
//! environments are ordinary files in the repository, under `.workspace/`.
//! They are versioned with the code, reviewed with the code, and readable
//! without this program.
//!
//! That is the point. An organisation's operating knowledge should not live in
//! a database it does not own. Losing a service should cost an organisation its
//! sync, not its knowledge.
//!
//! ISO 30401 asks for knowledge to be identified, held, made available and kept
//! current by named owners. ISO 10013 asks controlled documents to carry their
//! state, their owner and their review date. Both are satisfied by fields on
//! the entry, and both are checked.

const std = @import("std");
const timeutil = @import("../core/time.zig");
const hashing = @import("../core/hash.zig");
const toml = @import("../interop/toml.zig");

pub const Timestamp = timeutil.Timestamp;

/// What kind of knowledge an entry holds. The kind decides where it lives and
/// what it is used for.
pub const Kind = enum {
    /// A rule an agent follows in this workspace.
    rule,
    /// A reusable instruction for an agent.
    prompt,
    /// A task graph.
    workflow,
    /// A document that mixes explanation with commands.
    notebook,
    /// A named, reusable capability with its own instructions.
    skill,
    /// A Model Context Protocol server definition.
    server,
    /// A reproducible development environment.
    environment,

    pub fn directory(self: Kind) []const u8 {
        return switch (self) {
            .rule => "rules",
            .prompt => "prompts",
            .workflow => "workflows",
            .notebook => "notebooks",
            .skill => "skills",
            .server => "mcp",
            .environment => "environments",
        };
    }

    pub fn fromDirectory(name: []const u8) ?Kind {
        inline for (std.meta.fields(Kind)) |field| {
            const kind: Kind = @enumFromInt(field.value);
            if (std.mem.eql(u8, kind.directory(), name)) return kind;
        }
        return null;
    }
};

/// ISO 10013 control state for a documented item.
pub const State = enum {
    draft,
    in_review,
    approved,
    superseded,
    withdrawn,

    pub fn isUsable(self: State) bool {
        return self == .approved;
    }
};

pub const Entry = struct {
    /// Path relative to the workspace root.
    path: []const u8,
    kind: Kind,
    /// Identifier taken from the file name, without its extension.
    id: []const u8,
    title: []const u8,
    /// One sentence saying what it is for.
    summary: []const u8 = "",
    state: State = .draft,
    /// Who keeps it current. ISO 30401 asks for a named owner.
    owner: []const u8 = "",
    /// When it must be looked at again.
    review_due: ?Timestamp = null,
    /// Concept identifiers this entry is about, so search and agent context
    /// find it through the same vocabulary everything else uses.
    concepts: []const []const u8 = &.{},
    /// Free tags.
    tags: []const []const u8 = &.{},
    /// The body, after the front matter.
    body: []const u8 = "",
    content_hash: hashing.Hash = hashing.Hash.zero,

    pub fn isDue(self: Entry, now: Timestamp) bool {
        const due = self.review_due orelse return false;
        return now.ns >= due.ns;
    }
};

pub const FindingCode = enum {
    missing_owner,
    missing_summary,
    review_overdue,
    approved_without_review_date,
    unknown_concept,
    duplicate_id,
    superseded_still_referenced,
    /// The file is there, but it could not be read or parsed.
    unreadable,

    pub fn text(self: FindingCode) []const u8 {
        return switch (self) {
            .missing_owner => "KB01",
            .missing_summary => "KB02",
            .review_overdue => "KB03",
            .approved_without_review_date => "KB04",
            .unknown_concept => "KB05",
            .duplicate_id => "KB06",
            .superseded_still_referenced => "KB07",
            .unreadable => "KB08",
        };
    }
};

pub const Finding = struct {
    code: FindingCode,
    path: []const u8,
    message: []const u8,
};

/// Parse one file: TOML front matter between `+++` lines, then the body.
pub fn parseEntry(arena: std.mem.Allocator, path: []const u8, source: []const u8) !Entry {
    const kind = kindFromPath(path) orelse return error.UnknownKind;
    const id = identifierFromPath(path);

    var entry: Entry = .{
        .path = path,
        .kind = kind,
        .id = id,
        .title = id,
        .content_hash = hashing.Hash.of(source),
    };

    if (!std.mem.startsWith(u8, source, "+++")) {
        entry.body = source;
        return entry;
    }
    const after_open = std.mem.indexOfScalar(u8, source, '\n') orelse return error.MalformedFrontMatter;
    const close = std.mem.indexOfPos(u8, source, after_open, "\n+++") orelse return error.MalformedFrontMatter;
    const front_matter = source[after_open + 1 .. close];
    const body_start = std.mem.indexOfScalarPos(u8, source, close + 1, '\n') orelse source.len;
    entry.body = std.mem.trim(u8, source[@min(body_start + 1, source.len)..], " \t\n");

    const document = try toml.parse(arena, front_matter);
    if (document.string("title")) |title| entry.title = title;
    if (document.string("summary")) |summary| entry.summary = summary;
    if (document.string("owner")) |owner| entry.owner = owner;
    if (document.string("state")) |state| {
        entry.state = std.meta.stringToEnum(State, state) orelse return error.UnknownState;
    }
    if (document.string("review_due")) |due| {
        entry.review_due = timeutil.Timestamp.parseIso(due) catch return error.MalformedReviewDate;
    }
    if (document.get("concepts")) |value| {
        const items = value.asArray() orelse return error.MalformedFrontMatter;
        var list: std.ArrayList([]const u8) = .empty;
        for (items) |item| try list.append(arena, item.asString() orelse return error.MalformedFrontMatter);
        entry.concepts = try list.toOwnedSlice(arena);
    }
    if (document.get("tags")) |value| {
        const items = value.asArray() orelse return error.MalformedFrontMatter;
        var list: std.ArrayList([]const u8) = .empty;
        for (items) |item| try list.append(arena, item.asString() orelse return error.MalformedFrontMatter);
        entry.tags = try list.toOwnedSlice(arena);
    }
    return entry;
}

fn kindFromPath(path: []const u8) ?Kind {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (Kind.fromDirectory(part)) |kind| return kind;
    }
    return null;
}

fn identifierFromPath(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| path[slash + 1 ..] else path;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| return base[0..dot];
    return base;
}

pub const Base = struct {
    arena: std.mem.Allocator,
    /// The workspace root, for reporting.
    root: []const u8,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(arena: std.mem.Allocator, root: []const u8) Base {
        return .{ .arena = arena, .root = root };
    }

    pub fn add(self: *Base, entry: Entry) !void {
        try self.entries.append(self.arena, entry);
    }

    pub fn addSource(self: *Base, path: []const u8, source: []const u8) !void {
        try self.add(try parseEntry(self.arena, path, source));
    }

    pub fn get(self: Base, kind: Kind, id: []const u8) ?Entry {
        for (self.entries.items) |entry| {
            if (entry.kind == kind and std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }

    pub fn ofKind(self: Base, kind: Kind) !std.ArrayList(Entry) {
        var out: std.ArrayList(Entry) = .empty;
        for (self.entries.items) |entry| {
            if (entry.kind == kind) try out.append(self.arena, entry);
        }
        return out;
    }

    /// Entries about a concept. This is why entries carry concept identifiers
    /// rather than free text: a search for "workspace" finds the entries about
    /// the concept, not the ones that happen to use the word.
    pub fn aboutConcept(self: Base, concept_id: []const u8) !std.ArrayList(Entry) {
        var out: std.ArrayList(Entry) = .empty;
        for (self.entries.items) |entry| {
            for (entry.concepts) |concept| {
                if (std.mem.eql(u8, concept, concept_id)) {
                    try out.append(self.arena, entry);
                    break;
                }
            }
        }
        return out;
    }

    /// Entries an agent may act on: approved, and not overdue for review.
    pub fn usable(self: Base, now: Timestamp) !std.ArrayList(Entry) {
        var out: std.ArrayList(Entry) = .empty;
        for (self.entries.items) |entry| {
            if (!entry.state.isUsable()) continue;
            if (entry.isDue(now)) continue;
            try out.append(self.arena, entry);
        }
        return out;
    }

    /// Text search over titles, summaries and bodies. The indexed store adds
    /// ranking; this is the in-memory form the tests and short sessions use.
    pub fn search(self: Base, needle: []const u8) !std.ArrayList(Entry) {
        var out: std.ArrayList(Entry) = .empty;
        for (self.entries.items) |entry| {
            const hit = std.ascii.indexOfIgnoreCase(entry.title, needle) != null or
                std.ascii.indexOfIgnoreCase(entry.summary, needle) != null or
                std.ascii.indexOfIgnoreCase(entry.body, needle) != null;
            if (hit) try out.append(self.arena, entry);
        }
        return out;
    }

    /// Check the knowledge base itself, against ISO 30401 and ISO 10013.
    pub fn review(self: Base, now: Timestamp, known_concepts: []const []const u8) !std.ArrayList(Finding) {
        var findings: std.ArrayList(Finding) = .empty;
        var seen: std.StringArrayHashMapUnmanaged([]const u8) = .empty;

        for (self.entries.items) |entry| {
            const key = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ entry.kind.directory(), entry.id });
            if (seen.get(key)) |other| {
                try findings.append(self.arena, .{
                    .code = .duplicate_id,
                    .path = entry.path,
                    .message = try std.fmt.allocPrint(self.arena, "\"{s}\" has the same identifier as {s}.", .{ entry.path, other }),
                });
            } else {
                try seen.put(self.arena, key, entry.path);
            }

            if (entry.owner.len == 0) {
                try findings.append(self.arena, .{
                    .code = .missing_owner,
                    .path = entry.path,
                    .message = "Nobody is named as keeping this current. Name an owner.",
                });
            }
            if (entry.summary.len == 0) {
                try findings.append(self.arena, .{
                    .code = .missing_summary,
                    .path = entry.path,
                    .message = "There is no summary, so a person choosing between entries cannot tell what this one is for.",
                });
            }
            if (entry.state == .approved and entry.review_due == null) {
                try findings.append(self.arena, .{
                    .code = .approved_without_review_date,
                    .path = entry.path,
                    .message = "This is approved with no date to look at it again. Approved knowledge goes stale silently.",
                });
            }
            if (entry.isDue(now)) {
                try findings.append(self.arena, .{
                    .code = .review_overdue,
                    .path = entry.path,
                    .message = "The review date has passed. Read it, and either confirm it or change it.",
                });
            }
            for (entry.concepts) |concept| {
                var found = false;
                for (known_concepts) |known| {
                    if (std.mem.eql(u8, known, concept)) found = true;
                }
                if (!found) {
                    try findings.append(self.arena, .{
                        .code = .unknown_concept,
                        .path = entry.path,
                        .message = try std.fmt.allocPrint(self.arena, "It says it is about \"{s}\", which is not a registered concept.", .{concept}),
                    });
                }
            }
        }
        return findings;
    }

    pub fn writeIndex(self: Base, w: *std.Io.Writer) !void {
        try w.print("Knowledge in {s}\n\n", .{self.root});
        for (std.enums.values(Kind)) |kind| {
            var count: usize = 0;
            for (self.entries.items) |entry| {
                if (entry.kind == kind) count += 1;
            }
            if (count == 0) continue;
            try w.print("{s} ({d})\n", .{ kind.directory(), count });
            for (self.entries.items) |entry| {
                if (entry.kind != kind) continue;
                try w.print("  {s}  [{s}]", .{ entry.id, @tagName(entry.state) });
                if (entry.owner.len > 0) try w.print("  owner: {s}", .{entry.owner});
                try w.writeAll("\n");
                if (entry.summary.len > 0) try w.print("    {s}\n", .{entry.summary});
            }
            try w.writeAll("\n");
        }
    }
};

/// The layout the workbench expects under a workspace root.
pub const layout =
    \\.workspace/
    \\    rules/          one rule for each file, in Markdown with front matter
    \\    prompts/        reusable instructions for agents
    \\    workflows/      task graphs
    \\    notebooks/      explanation mixed with commands
    \\    skills/         named, reusable capabilities
    \\    mcp/            server definitions
    \\    environments/   reproducible development environments
;

const testing = std.testing;

const sample_rule =
    \\+++
    \\title = "Run the tests before proposing a change"
    \\summary = "Every change is proposed with a green test run behind it."
    \\owner = "workbench maintainers"
    \\state = "approved"
    \\review_due = 2027-03-04T00:00:00Z
    \\concepts = ["workflow", "agent"]
    \\tags = ["quality"]
    \\+++
    \\
    \\Run `zig build test` before you propose a change. If a test fails, fix the
    \\cause rather than the test.
;

test "an entry parses its front matter and its body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entry = try parseEntry(arena, ".workspace/rules/run-tests.md", sample_rule);
    try testing.expectEqual(Kind.rule, entry.kind);
    try testing.expectEqualStrings("run-tests", entry.id);
    try testing.expectEqualStrings("Run the tests before proposing a change", entry.title);
    try testing.expectEqualStrings("workbench maintainers", entry.owner);
    try testing.expectEqual(State.approved, entry.state);
    try testing.expectEqual(@as(usize, 2), entry.concepts.len);
    try testing.expect(std.mem.startsWith(u8, entry.body, "Run `zig build test`"));
    try testing.expect(entry.review_due != null);
}

test "a file with no front matter is still an entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entry = try parseEntry(arena, ".workspace/prompts/review.md", "Review the diff and say what you would change.");
    try testing.expectEqual(Kind.prompt, entry.kind);
    try testing.expectEqualStrings("review", entry.id);
    try testing.expectEqual(State.draft, entry.state);
    try testing.expect(entry.body.len > 0);
}

test "the base finds entries by kind, by concept and by text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var base = Base.init(arena, ".workspace");
    try base.addSource(".workspace/rules/run-tests.md", sample_rule);
    try base.addSource(".workspace/prompts/review.md", "Review the diff and say what you would change.");

    try testing.expectEqual(@as(usize, 1), (try base.ofKind(.rule)).items.len);
    try testing.expectEqual(@as(usize, 1), (try base.aboutConcept("agent")).items.len);
    try testing.expectEqual(@as(usize, 0), (try base.aboutConcept("dataset")).items.len);
    try testing.expectEqual(@as(usize, 1), (try base.search("zig build test")).items.len);
    try testing.expect(base.get(.rule, "run-tests") != null);
}

test "only approved knowledge that is not overdue is offered to an agent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var base = Base.init(arena, ".workspace");
    try base.addSource(".workspace/rules/run-tests.md", sample_rule);
    try base.addSource(".workspace/rules/draft.md",
        \\+++
        \\title = "A rule still being written"
        \\state = "draft"
        \\+++
        \\
        \\Not ready.
    );

    const before_review = try timeutil.Timestamp.parseIso("2026-09-04T00:00:00Z");
    try testing.expectEqual(@as(usize, 1), (try base.usable(before_review)).items.len);

    const after_review = try timeutil.Timestamp.parseIso("2027-06-01T00:00:00Z");
    try testing.expectEqual(@as(usize, 0), (try base.usable(after_review)).items.len);
}

test "the knowledge base is checked like anything else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var base = Base.init(arena, ".workspace");
    try base.addSource(".workspace/rules/thin.md",
        \\+++
        \\title = "A rule with nobody behind it"
        \\state = "approved"
        \\concepts = ["invented-concept"]
        \\+++
        \\
        \\Do something.
    );

    const findings = try base.review(timeutil.Timestamp.epoch, &.{ "workflow", "agent" });
    var codes: [std.meta.fields(FindingCode).len]bool = @splat(false);
    for (findings.items) |finding| codes[@intFromEnum(finding.code)] = true;
    try testing.expect(codes[@intFromEnum(FindingCode.missing_owner)]);
    try testing.expect(codes[@intFromEnum(FindingCode.missing_summary)]);
    try testing.expect(codes[@intFromEnum(FindingCode.approved_without_review_date)]);
    try testing.expect(codes[@intFromEnum(FindingCode.unknown_concept)]);
}

test "an overdue review is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var base = Base.init(arena, ".workspace");
    try base.addSource(".workspace/rules/run-tests.md", sample_rule);
    const long_after = try timeutil.Timestamp.parseIso("2028-01-01T00:00:00Z");
    const findings = try base.review(long_after, &.{ "workflow", "agent" });
    var saw_overdue = false;
    for (findings.items) |finding| {
        if (finding.code == .review_overdue) saw_overdue = true;
    }
    try testing.expect(saw_overdue);
}

test "the index reads as a list a person can scan" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var base = Base.init(arena, ".workspace");
    try base.addSource(".workspace/rules/run-tests.md", sample_rule);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try base.writeIndex(&aw.writer);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "rules (1)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "owner: workbench maintainers") != null);
}
