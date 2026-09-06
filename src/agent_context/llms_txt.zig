//! llms.txt: machine-oriented documentation discovery.
//!
//! An agent that scrapes a documentation site is guessing. `llms.txt` lets a
//! site say, in one place, what it is, what the important pages are, and where
//! the Markdown source of each one lives. The second version of the proposal
//! also uses HTTP `Link` relations for discovery, so a fetch can find the file
//! and the Markdown alternate of any page without a crawl.
//!
//! This module both reads and writes the format: the workbench consumes other
//! people's files, and publishes its own.

const std = @import("std");

pub const Link = struct {
    title: []const u8,
    url: []const u8,
    /// The short note after the colon, which is what makes the file useful.
    note: []const u8 = "",
};

pub const Section = struct {
    title: []const u8,
    links: []const Link,
    /// True for the section a client may skip when it is short of context.
    optional: bool = false,
};

pub const Document = struct {
    /// The single H1: what this site or project is.
    title: []const u8,
    /// The blockquote under the title: one-sentence summary.
    summary: []const u8 = "",
    /// Free text before the first section.
    details: []const u8 = "",
    sections: []const Section,

    pub fn section(self: Document, title: []const u8) ?Section {
        for (self.sections) |s| {
            if (std.ascii.eqlIgnoreCase(s.title, title)) return s;
        }
        return null;
    }

    pub fn linkCount(self: Document) usize {
        var total: usize = 0;
        for (self.sections) |s| total += s.links.len;
        return total;
    }

    /// The links a client should read first: everything outside the optional
    /// section.
    pub fn essentialLinks(self: Document, arena: std.mem.Allocator) !std.ArrayList(Link) {
        var out: std.ArrayList(Link) = .empty;
        for (self.sections) |s| {
            if (s.optional) continue;
            for (s.links) |link| try out.append(arena, link);
        }
        return out;
    }
};

pub const ParseError = error{ MissingTitle, OutOfMemory };

pub fn parse(arena: std.mem.Allocator, source: []const u8) ParseError!Document {
    var title: []const u8 = "";
    var summary: std.ArrayList(u8) = .empty;
    var details: std.ArrayList(u8) = .empty;
    var sections: std.ArrayList(Section) = .empty;

    var current_title: ?[]const u8 = null;
    var current_links: std.ArrayList(Link) = .empty;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (std.mem.startsWith(u8, line, "# ")) {
            title = std.mem.trim(u8, line[2..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, line, "## ")) {
            if (current_title) |name| {
                try sections.append(arena, .{
                    .title = name,
                    .links = try current_links.toOwnedSlice(arena),
                    .optional = std.ascii.eqlIgnoreCase(name, "optional"),
                });
                current_links = .empty;
            }
            current_title = std.mem.trim(u8, line[3..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, line, "> ")) {
            if (summary.items.len > 0) try summary.append(arena, ' ');
            try summary.appendSlice(arena, std.mem.trim(u8, line[2..], " \t"));
            continue;
        }
        if (std.mem.startsWith(u8, line, "- [")) {
            if (parseLink(line)) |link| try current_links.append(arena, link);
            continue;
        }
        if (line.len > 0 and current_title == null and title.len > 0) {
            if (details.items.len > 0) try details.append(arena, ' ');
            try details.appendSlice(arena, line);
        }
    }

    if (current_title) |name| {
        try sections.append(arena, .{
            .title = name,
            .links = try current_links.toOwnedSlice(arena),
            .optional = std.ascii.eqlIgnoreCase(name, "optional"),
        });
    }

    if (title.len == 0) return error.MissingTitle;
    return .{
        .title = title,
        .summary = try summary.toOwnedSlice(arena),
        .details = try details.toOwnedSlice(arena),
        .sections = try sections.toOwnedSlice(arena),
    };
}

fn parseLink(line: []const u8) ?Link {
    const open_bracket = std.mem.indexOfScalar(u8, line, '[') orelse return null;
    const close_bracket = std.mem.indexOfScalarPos(u8, line, open_bracket, ']') orelse return null;
    const open_paren = std.mem.indexOfScalarPos(u8, line, close_bracket, '(') orelse return null;
    const close_paren = std.mem.indexOfScalarPos(u8, line, open_paren, ')') orelse return null;

    const title = line[open_bracket + 1 .. close_bracket];
    const url = line[open_paren + 1 .. close_paren];
    var note: []const u8 = "";
    if (close_paren + 1 < line.len) {
        const rest = std.mem.trim(u8, line[close_paren + 1 ..], " \t");
        if (std.mem.startsWith(u8, rest, ":")) note = std.mem.trim(u8, rest[1..], " \t");
    }
    return .{ .title = title, .url = url, .note = note };
}

pub fn write(document: Document, w: *std.Io.Writer) !void {
    try w.print("# {s}\n\n", .{document.title});
    if (document.summary.len > 0) try w.print("> {s}\n\n", .{document.summary});
    if (document.details.len > 0) try w.print("{s}\n\n", .{document.details});
    for (document.sections) |section| {
        try w.print("## {s}\n\n", .{section.title});
        for (section.links) |link| {
            try w.print("- [{s}]({s})", .{ link.title, link.url });
            if (link.note.len > 0) try w.print(": {s}", .{link.note});
            try w.writeAll("\n");
        }
        try w.writeAll("\n");
    }
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

/// A parsed HTTP `Link` header entry.
pub const LinkHeader = struct {
    url: []const u8,
    rel: []const u8,
    type_hint: []const u8 = "",
};

/// Parse a `Link` header value. Several entries may be separated by commas.
pub fn parseLinkHeader(arena: std.mem.Allocator, header: []const u8) !std.ArrayList(LinkHeader) {
    var out: std.ArrayList(LinkHeader) = .empty;
    var entries = std.mem.splitScalar(u8, header, ',');
    while (entries.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t");
        if (entry.len == 0) continue;
        const open = std.mem.indexOfScalar(u8, entry, '<') orelse continue;
        const close = std.mem.indexOfScalarPos(u8, entry, open, '>') orelse continue;
        var link: LinkHeader = .{ .url = entry[open + 1 .. close], .rel = "" };

        var parameters = std.mem.splitScalar(u8, entry[close + 1 ..], ';');
        while (parameters.next()) |raw_parameter| {
            const parameter = std.mem.trim(u8, raw_parameter, " \t");
            if (std.mem.startsWith(u8, parameter, "rel=")) {
                link.rel = std.mem.trim(u8, parameter[4..], "\" ");
            } else if (std.mem.startsWith(u8, parameter, "type=")) {
                link.type_hint = std.mem.trim(u8, parameter[5..], "\" ");
            }
        }
        try out.append(arena, link);
    }
    return out;
}

/// Choose what to fetch for a page, given its `Link` header.
pub const Discovery = struct {
    /// The `llms.txt` that applies to this page.
    llms_txt: ?[]const u8 = null,
    /// The Markdown source of this page.
    markdown_alternate: ?[]const u8 = null,

    pub fn preferredSource(self: Discovery) ?[]const u8 {
        // Markdown of the page itself is the closest thing to the source; the
        // index is the fallback when there is no alternate.
        return self.markdown_alternate orelse self.llms_txt;
    }
};

pub fn discover(arena: std.mem.Allocator, header: []const u8) !Discovery {
    var discovery: Discovery = .{};
    const links = try parseLinkHeader(arena, header);
    for (links.items) |link| {
        if (std.mem.eql(u8, link.rel, "describedby") and std.mem.endsWith(u8, link.url, "llms.txt")) {
            discovery.llms_txt = link.url;
        } else if (std.mem.eql(u8, link.rel, "alternate") and std.mem.eql(u8, link.type_hint, "text/markdown")) {
            discovery.markdown_alternate = link.url;
        }
    }
    return discovery;
}

/// The `llms.txt` the workbench publishes for itself.
pub fn workbenchDocument() Document {
    return .{
        .title = "zag workbench",
        .summary = "A standards-native, Zig-native workbench where people and agents do engineering work in one recorded workspace.",
        .details = "Everything that happens becomes a typed event in a hash-chained log. Agents propose typed tool requests; a local policy engine decides them. Terminology, metadata, accessibility, data quality and AI governance are enforced by the build, not described in a document.",
        .sections = &.{
            .{
                .title = "Docs",
                .links = &.{
                    .{ .title = "README", .url = "/README.md", .note = "What the workbench is and how to build it" },
                    .{ .title = "Architecture", .url = "/docs/architecture.md", .note = "The event graph, the block model and the standards control plane" },
                    .{ .title = "Standards conformance", .url = "/docs/standards-conformance.md", .note = "Which standards apply, how each is checked, and what is not established" },
                    .{ .title = "Plain language", .url = "/docs/plain-language.md", .note = "How ISO 24495 is applied to product text, and what the checker cannot decide" },
                    .{ .title = "Glossary", .url = "/docs/glossary.md", .note = "The registered concepts and their definitions" },
                    .{ .title = "Competitive position", .url = "/docs/competitive-position.md", .note = "What zag does that other terminals do not, what it cannot do yet, and the order that changes" },
                },
            },
            .{
                .title = "Machine-readable",
                .links = &.{
                    .{ .title = "Workspace vocabulary (SKOS)", .url = "/vocab/workspace.ttl", .note = "Concepts, definitions and relations" },
                    .{ .title = "Event schema", .url = "/schemas/workspace-event.schema.json", .note = "JSON Schema for the typed event stream" },
                    .{ .title = "Tool request schema", .url = "/schemas/tool-request.schema.json", .note = "What an agent may ask for" },
                    .{ .title = "Daemon interface", .url = "/schemas/openapi.json", .note = "OpenAPI description of the workspace daemon" },
                    .{ .title = "Metadata registry", .url = "/schemas/metadata-registry.json", .note = "Registered field names and their value domains" },
                },
            },
            .{
                .title = "In this repository",
                .links = &.{
                    .{ .title = "Workspace rules", .url = "/.workspace/rules/", .note = "The rules that apply to work done here" },
                    .{ .title = "Workspace prompts", .url = "/.workspace/prompts/", .note = "Reusable instructions for agents" },
                    .{ .title = "Workspace workflows", .url = "/.workspace/workflows/", .note = "The task graphs this repository runs" },
                },
            },
            .{
                .title = "Optional",
                .links = &.{
                    .{ .title = "Decision records", .url = "/docs/adr/", .note = "Why the architecture is the way it is" },
                    .{ .title = "Risk register", .url = "/docs/risk-register.md", .note = "What could go wrong and what is done about it" },
                },
                .optional = true,
            },
        },
    };
}

const testing = std.testing;

test "a document round trips" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(arena);
    try write(workbenchDocument(), &aw.writer);
    const text = aw.written();

    const parsed = try parse(arena, text);
    try testing.expectEqualStrings("zag workbench", parsed.title);
    try testing.expect(std.mem.indexOf(u8, parsed.summary, "hash-chained") == null);
    try testing.expect(std.mem.indexOf(u8, parsed.summary, "standards-native") != null);
    try testing.expectEqual(workbenchDocument().sections.len, parsed.sections.len);
    try testing.expectEqual(workbenchDocument().linkCount(), parsed.linkCount());

    const docs = parsed.section("Docs").?;
    try testing.expectEqualStrings("/README.md", docs.links[0].url);
    try testing.expectEqualStrings("What the workbench is and how to build it", docs.links[0].note);
}

test "the optional section is marked and can be skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var aw: std.Io.Writer.Allocating = .init(arena);
    try write(workbenchDocument(), &aw.writer);
    const parsed = try parse(arena, aw.written());

    try testing.expect(parsed.section("Optional").?.optional);
    const essential = try parsed.essentialLinks(arena);
    try testing.expect(essential.items.len == parsed.linkCount() - 2);
}

test "a file without a title is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.MissingTitle, parse(arena, "## Docs\n\n- [a](/a)\n"));
}

test "discovery reads the link header" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const header =
        "<https://example.test/llms.txt>; rel=\"describedby\", " ++
        "<https://example.test/guide.md>; rel=\"alternate\"; type=\"text/markdown\", " ++
        "<https://example.test/style.css>; rel=\"stylesheet\"";

    const discovery = try discover(arena, header);
    try testing.expectEqualStrings("https://example.test/llms.txt", discovery.llms_txt.?);
    try testing.expectEqualStrings("https://example.test/guide.md", discovery.markdown_alternate.?);
    // The Markdown of the page itself is closer to the source than the index.
    try testing.expectEqualStrings("https://example.test/guide.md", discovery.preferredSource().?);

    const only_index = try discover(arena, "<https://example.test/llms.txt>; rel=\"describedby\"");
    try testing.expectEqualStrings("https://example.test/llms.txt", only_index.preferredSource().?);

    const nothing = try discover(arena, "<https://example.test/style.css>; rel=\"stylesheet\"");
    try testing.expect(nothing.preferredSource() == null);
}
