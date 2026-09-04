//! Thesaurus view over a concept system: ISO 25964-1 and ANSI/NISO Z39.19.
//!
//! The concept system holds the meaning. The thesaurus is the *access* face of
//! it: the alphabetical display with USE / UF / BT / NT / RT that a person can
//! read, and that a search index can expand a query against.
//!
//! Nothing here invents relationships. Every entry is derived from the concept
//! system, so the two cannot disagree.

const std = @import("std");
const concepts = @import("concepts.zig");

pub const RelationLabel = enum {
    /// Use the preferred term instead of this one.
    use,
    /// This preferred term is used for these non-preferred terms.
    used_for,
    /// Broader term.
    broader,
    /// Narrower term.
    narrower,
    /// Related term.
    related,

    pub fn tag(self: RelationLabel) []const u8 {
        return switch (self) {
            .use => "USE",
            .used_for => "UF",
            .broader => "BT",
            .narrower => "NT",
            .related => "RT",
        };
    }
};

pub const Entry = struct {
    term: []const u8,
    concept_id: []const u8,
    preferred: bool,
    /// For a non-preferred term: the term to use instead.
    use: ?[]const u8 = null,
    used_for: []const []const u8 = &.{},
    broader: []const []const u8 = &.{},
    narrower: []const []const u8 = &.{},
    related: []const []const u8 = &.{},
    scope_note: ?[]const u8 = null,
};

pub const Thesaurus = struct {
    arena: std.mem.Allocator,
    entries: []Entry,

    /// Build the alphabetical display from a concept system.
    pub fn build(arena: std.mem.Allocator, system: concepts.ConceptSystem) !Thesaurus {
        var list: std.ArrayList(Entry) = .empty;

        var it = system.concepts.iterator();
        while (it.next()) |kv| {
            const c = kv.value_ptr.*;

            var used_for: std.ArrayList([]const u8) = .empty;
            for (c.designations) |d| {
                if (d.status == .preferred) continue;
                try used_for.append(arena, d.text);
                try list.append(arena, .{
                    .term = d.text,
                    .concept_id = c.id,
                    .preferred = false,
                    .use = c.preferred,
                    .scope_note = d.note,
                });
            }

            var broader: std.ArrayList([]const u8) = .empty;
            var related: std.ArrayList([]const u8) = .empty;
            for (c.relations) |r| {
                const target = system.get(r.target) orelse continue;
                switch (r.kind) {
                    .associative => try related.append(arena, target.preferred),
                    else => try broader.append(arena, target.preferred),
                }
            }

            var narrower: std.ArrayList([]const u8) = .empty;
            const children = try system.narrower(c.id);
            for (children.items) |child_id| {
                const child = system.get(child_id) orelse continue;
                try narrower.append(arena, child.preferred);
            }

            try list.append(arena, .{
                .term = c.preferred,
                .concept_id = c.id,
                .preferred = true,
                .used_for = used_for.items,
                .broader = broader.items,
                .narrower = narrower.items,
                .related = related.items,
                .scope_note = c.note,
            });
        }

        const entries = try list.toOwnedSlice(arena);
        std.mem.sort(Entry, entries, {}, lessThan);
        return .{ .arena = arena, .entries = entries };
    }

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return std.ascii.orderIgnoreCase(a.term, b.term) == .lt;
    }

    pub fn lookup(self: Thesaurus, term: []const u8) ?Entry {
        for (self.entries) |e| {
            if (std.ascii.eqlIgnoreCase(e.term, term)) return e;
        }
        return null;
    }

    /// Terms a search should also match: the preferred term, its synonyms and
    /// its narrower terms. This is the query-expansion set of ISO 25964-1.
    pub fn expand(self: Thesaurus, term: []const u8) !std.ArrayList([]const u8) {
        var out: std.ArrayList([]const u8) = .empty;
        const entry = self.lookup(term) orelse return out;
        const target = if (entry.preferred) entry else self.lookup(entry.use.?) orelse entry;
        try out.append(self.arena, target.term);
        for (target.used_for) |t| try out.append(self.arena, t);
        for (target.narrower) |t| {
            try out.append(self.arena, t);
            // One level of narrower terms is expanded eagerly; deeper levels are
            // reached by expanding those terms in turn.
        }
        return out;
    }

    /// ANSI/NISO Z39.19 alphabetical display.
    pub fn writeAlphabetical(self: Thesaurus, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.entries) |e| {
            try w.print("{s}\n", .{e.term});
            if (e.use) |u| try w.print("    USE {s}\n", .{u});
            if (e.scope_note) |n| try w.print("    SN  {s}\n", .{n});
            for (e.used_for) |t| try w.print("    UF  {s}\n", .{t});
            for (e.broader) |t| try w.print("    BT  {s}\n", .{t});
            for (e.narrower) |t| try w.print("    NT  {s}\n", .{t});
            for (e.related) |t| try w.print("    RT  {s}\n", .{t});
            try w.writeAll("\n");
        }
    }

    /// Reciprocity check: every BT must have a matching NT and every RT must be
    /// mutual. The builder derives NT from BT, so this is a regression guard on
    /// the derivation itself, and it catches one-sided RT declarations.
    pub fn checkReciprocity(self: Thesaurus) !std.ArrayList([]const u8) {
        var problems: std.ArrayList([]const u8) = .empty;
        for (self.entries) |e| {
            if (!e.preferred) continue;
            for (e.broader) |bt| {
                const parent = self.lookup(bt) orelse {
                    try problems.append(self.arena, try std.fmt.allocPrint(self.arena, "{s} has BT {s}, which is not in the thesaurus", .{ e.term, bt }));
                    continue;
                };
                var found = false;
                for (parent.narrower) |nt| {
                    if (std.ascii.eqlIgnoreCase(nt, e.term)) found = true;
                }
                if (!found) {
                    try problems.append(self.arena, try std.fmt.allocPrint(self.arena, "{s} has BT {s}, but {s} does not list it as NT", .{ e.term, bt, bt }));
                }
            }
            for (e.related) |rt| {
                const other = self.lookup(rt) orelse {
                    try problems.append(self.arena, try std.fmt.allocPrint(self.arena, "{s} has RT {s}, which is not in the thesaurus", .{ e.term, rt }));
                    continue;
                };
                var mutual = false;
                for (other.related) |back| {
                    if (std.ascii.eqlIgnoreCase(back, e.term)) mutual = true;
                }
                if (!mutual) {
                    try problems.append(self.arena, try std.fmt.allocPrint(self.arena, "{s} has RT {s}, but {s} does not point back. A related-term relation is mutual.", .{ e.term, rt, rt }));
                }
            }
        }
        return problems;
    }
};

fn sampleSystem(arena: std.mem.Allocator) !concepts.ConceptSystem {
    var system = concepts.ConceptSystem.init(arena);
    try system.add(.{ .id = "env", .preferred = "development environment", .definition = "tools and resources used to change software", .top_concept = true });
    try system.add(.{
        .id = "workspace",
        .preferred = "workspace",
        .definition = "development environment that keeps sessions, files and agents together over time",
        .designations = &.{ .{ .text = "bench", .status = .admitted }, .{ .text = "project shell", .status = .deprecated } },
        .relations = &.{ .{ .kind = .generic, .target = "env" }, .{ .kind = .associative, .target = "session" } },
    });
    try system.add(.{
        .id = "session",
        .preferred = "session",
        .definition = "workspace element that runs one program and records its output",
        .relations = &.{ .{ .kind = .partitive, .target = "workspace" }, .{ .kind = .associative, .target = "workspace" } },
    });
    return system;
}

test "alphabetical display carries use, uf, bt, nt and rt" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const system = try sampleSystem(arena);
    const thesaurus = try Thesaurus.build(arena, system);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try thesaurus.writeAlphabetical(&aw.writer);
    const text = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "project shell\n    USE workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    UF  bench") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    NT  session") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    BT  development environment") != null);

    // Entries are in alphabetical order.
    var previous: []const u8 = "";
    for (thesaurus.entries) |e| {
        try std.testing.expect(std.ascii.orderIgnoreCase(previous, e.term) != .gt);
        previous = e.term;
    }
}

test "query expansion follows use and narrower terms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const system = try sampleSystem(arena);
    const thesaurus = try Thesaurus.build(arena, system);

    const expanded = try thesaurus.expand("project shell");
    try std.testing.expectEqualStrings("workspace", expanded.items[0]);
    var saw_session = false;
    for (expanded.items) |t| {
        if (std.mem.eql(u8, t, "session")) saw_session = true;
    }
    try std.testing.expect(saw_session);
}

test "reciprocity check reports one-sided related terms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var system = concepts.ConceptSystem.init(arena);
    try system.add(.{ .id = "a", .preferred = "alpha", .definition = "first test concept", .top_concept = true, .relations = &.{.{ .kind = .associative, .target = "b" }} });
    try system.add(.{ .id = "b", .preferred = "beta", .definition = "second test concept", .top_concept = true });

    const thesaurus = try Thesaurus.build(arena, system);
    const problems = try thesaurus.checkReciprocity();
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
    try std.testing.expect(std.mem.indexOf(u8, problems.items[0], "does not point back") != null);

    const good = try Thesaurus.build(arena, try sampleSystem(arena));
    const none = try good.checkReciprocity();
    try std.testing.expectEqual(@as(usize, 0), none.items.len);
}
