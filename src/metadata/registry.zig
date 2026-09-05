//! Metadata registry, following ISO/IEC 11179.
//!
//! The problem this solves is concrete. Without a registry, one subsystem
//! writes `cwd`, another writes `working_directory`, a third writes
//! `current_path`, and an agent, a plugin and a remote daemon then disagree
//! about the same fact. Here, every field that crosses an interface is
//! registered once: one meaning, one value domain, one canonical name, and an
//! explicit list of the aliases we accept on input.
//!
//! The registry validates itself, so a new field that collides with an existing
//! name or alias fails the build rather than the integration.

const std = @import("std");
const value_domain = @import("value_domain.zig");

pub const Datatype = value_domain.Datatype;
pub const ValueDomain = value_domain.ValueDomain;

/// ISO/IEC 11179-6 registration status, shortened to the states we use.
pub const RegistrationStatus = enum {
    /// Written down, not yet reviewed.
    recorded,
    /// Reviewed and complete.
    qualified,
    /// Approved for use across every interface.
    standardised,
    /// Replaced by another element; still readable.
    superseded,
    /// Withdrawn; must not appear in new interfaces.
    retired,
};

pub const Obligation = enum { mandatory, conditional, optional };

/// The meaning half of a data element: an object class and one of its
/// properties, as ISO/IEC 11179-1 puts it.
pub const DataElementConcept = struct {
    id: []const u8,
    object_class: []const u8,
    property: []const u8,
    definition: []const u8,
    /// Identifier of the ISO 704 concept this belongs to, when there is one.
    concept_id: ?[]const u8 = null,
};

pub const DataElement = struct {
    id: []const u8,
    concept_id: []const u8,
    domain_id: []const u8,
    /// The only spelling that may appear in JSON, on the wire and in storage.
    canonical_key: []const u8,
    /// The Zig type that carries this element in the code.
    zig_type: []const u8,
    /// Spellings accepted on input and rewritten to the canonical key.
    aliases: []const []const u8 = &.{},
    obligation: Obligation = .optional,
    status: RegistrationStatus = .qualified,
    steward: []const u8 = "workbench",
    definition: []const u8,
    example: ?[]const u8 = null,
    superseded_by: ?[]const u8 = null,
};

pub const FindingCode = enum {
    duplicate_canonical_key,
    alias_collides_with_key,
    alias_used_twice,
    unknown_value_domain,
    unknown_concept,
    key_not_lower_camel_case,
    quantity_without_unit,
    retired_element_in_use,

    pub fn text(self: FindingCode) []const u8 {
        return switch (self) {
            .duplicate_canonical_key => "META01",
            .alias_collides_with_key => "META02",
            .alias_used_twice => "META03",
            .unknown_value_domain => "META04",
            .unknown_concept => "META05",
            .key_not_lower_camel_case => "META06",
            .quantity_without_unit => "META07",
            .retired_element_in_use => "META08",
        };
    }
};

pub const Finding = struct {
    code: FindingCode,
    element_id: []const u8,
    message: []const u8,
};

pub const Registry = struct {
    arena: std.mem.Allocator,
    concepts: std.StringArrayHashMapUnmanaged(DataElementConcept) = .empty,
    domains: std.StringArrayHashMapUnmanaged(ValueDomain) = .empty,
    elements: std.StringArrayHashMapUnmanaged(DataElement) = .empty,

    pub fn init(arena: std.mem.Allocator) Registry {
        return .{ .arena = arena };
    }

    pub fn addConcept(self: *Registry, concept: DataElementConcept) !void {
        try self.concepts.put(self.arena, concept.id, concept);
    }

    pub fn addDomain(self: *Registry, domain: ValueDomain) !void {
        try self.domains.put(self.arena, domain.id, domain);
    }

    pub fn addElement(self: *Registry, item: DataElement) !void {
        try self.elements.put(self.arena, item.id, item);
    }

    pub fn element(self: Registry, id: []const u8) ?DataElement {
        return self.elements.get(id);
    }

    pub fn domainOf(self: Registry, e: DataElement) ?ValueDomain {
        return self.domains.get(e.domain_id);
    }

    /// Map any accepted spelling to the canonical key. This is the function
    /// every inbound adapter calls, so `cwd` from a plugin and
    /// `current_path` from an old client both become `workingDirectory`.
    pub fn canonicalKey(self: Registry, written: []const u8) ?[]const u8 {
        var it = self.elements.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr.*;
            if (std.mem.eql(u8, e.canonical_key, written)) return e.canonical_key;
            for (e.aliases) |alias| {
                if (std.mem.eql(u8, alias, written)) return e.canonical_key;
            }
        }
        return null;
    }

    pub fn elementForKey(self: Registry, written: []const u8) ?DataElement {
        var it = self.elements.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr.*;
            if (std.mem.eql(u8, e.canonical_key, written)) return e;
            for (e.aliases) |alias| {
                if (std.mem.eql(u8, alias, written)) return e;
            }
        }
        return null;
    }

    /// Validate one value against the element's value domain.
    pub fn validateValue(self: Registry, element_id: []const u8, value: []const u8) !void {
        const e = self.element(element_id) orelse return error.UnknownElement;
        const domain = self.domainOf(e) orelse return error.UnknownValueDomain;
        try domain.validate(value);
    }

    pub fn validate(self: Registry) !std.ArrayList(Finding) {
        var findings: std.ArrayList(Finding) = .empty;
        var keys: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        var aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty;

        var it = self.elements.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr.*;

            if (keys.get(e.canonical_key)) |owner| {
                try findings.append(self.arena, .{
                    .code = .duplicate_canonical_key,
                    .element_id = e.id,
                    .message = try std.fmt.allocPrint(self.arena, "\"{s}\" is the canonical key of both \"{s}\" and \"{s}\". One key names one data element.", .{ e.canonical_key, owner, e.id }),
                });
            } else {
                try keys.put(self.arena, e.canonical_key, e.id);
            }

            if (!isLowerCamelCase(e.canonical_key)) {
                try findings.append(self.arena, .{
                    .code = .key_not_lower_camel_case,
                    .element_id = e.id,
                    .message = try std.fmt.allocPrint(self.arena, "The canonical key \"{s}\" is not written in lowerCamelCase. Every key on the wire uses one shape.", .{e.canonical_key}),
                });
            }

            if (self.domains.get(e.domain_id)) |domain| {
                if (domain.datatype == .quantity and domain.unit == null) {
                    try findings.append(self.arena, .{
                        .code = .quantity_without_unit,
                        .element_id = e.id,
                        .message = try std.fmt.allocPrint(self.arena, "The value domain \"{s}\" holds quantities but names no unit. A number without a unit cannot be compared.", .{domain.id}),
                    });
                }
            } else {
                try findings.append(self.arena, .{
                    .code = .unknown_value_domain,
                    .element_id = e.id,
                    .message = try std.fmt.allocPrint(self.arena, "The element \"{s}\" points to value domain \"{s}\", which is not registered.", .{ e.id, e.domain_id }),
                });
            }

            if (!self.concepts.contains(e.concept_id)) {
                try findings.append(self.arena, .{
                    .code = .unknown_concept,
                    .element_id = e.id,
                    .message = try std.fmt.allocPrint(self.arena, "The element \"{s}\" points to concept \"{s}\", which is not registered.", .{ e.id, e.concept_id }),
                });
            }

            for (e.aliases) |alias| {
                if (aliases.get(alias)) |owner| {
                    try findings.append(self.arena, .{
                        .code = .alias_used_twice,
                        .element_id = e.id,
                        .message = try std.fmt.allocPrint(self.arena, "\"{s}\" is an accepted spelling for both \"{s}\" and \"{s}\". An inbound field would be ambiguous.", .{ alias, owner, e.id }),
                    });
                } else {
                    try aliases.put(self.arena, alias, e.id);
                }
            }
        }

        // An alias may not shadow another element's canonical key.
        var alias_it = aliases.iterator();
        while (alias_it.next()) |entry| {
            if (keys.get(entry.key_ptr.*)) |owner| {
                if (!std.mem.eql(u8, owner, entry.value_ptr.*)) {
                    try findings.append(self.arena, .{
                        .code = .alias_collides_with_key,
                        .element_id = entry.value_ptr.*,
                        .message = try std.fmt.allocPrint(self.arena, "\"{s}\" is an alias of \"{s}\" and the canonical key of \"{s}\".", .{ entry.key_ptr.*, entry.value_ptr.*, owner }),
                    });
                }
            }
        }
        return findings;
    }

    /// Write the registry as a JSON document, so that other languages and
    /// tools can adopt the same names without reading Zig.
    pub fn writeJson(self: Registry, w: *std.Io.Writer) !void {
        var jw: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
        try jw.beginObject();
        try jw.objectField("standard");
        try jw.write("ISO/IEC 11179");
        try jw.objectField("dataElements");
        try jw.beginArray();
        var it = self.elements.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr.*;
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(e.id);
            try jw.objectField("canonicalKey");
            try jw.write(e.canonical_key);
            try jw.objectField("definition");
            try jw.write(e.definition);
            try jw.objectField("obligation");
            try jw.write(@tagName(e.obligation));
            try jw.objectField("registrationStatus");
            try jw.write(@tagName(e.status));
            try jw.objectField("aliases");
            try jw.write(e.aliases);
            if (self.domainOf(e)) |d| {
                try jw.objectField("valueDomain");
                try jw.beginObject();
                try jw.objectField("id");
                try jw.write(d.id);
                try jw.objectField("datatype");
                try jw.write(@tagName(d.datatype));
                if (d.unit) |u| {
                    try jw.objectField("unit");
                    try jw.write(u);
                }
                if (d.permitted.len > 0) {
                    try jw.objectField("permittedValues");
                    try jw.beginArray();
                    for (d.permitted) |p| {
                        try jw.beginObject();
                        try jw.objectField("value");
                        try jw.write(p.value);
                        try jw.objectField("meaning");
                        try jw.write(p.meaning);
                        try jw.endObject();
                    }
                    try jw.endArray();
                }
                try jw.endObject();
            }
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
    }
};

pub fn isLowerCamelCase(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!std.ascii.isLower(key[0])) return false;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

fn hasFinding(findings: []const Finding, code: FindingCode) bool {
    for (findings) |f| {
        if (f.code == code) return true;
    }
    return false;
}

test "canonical keys absorb the aliases the ecosystem produces" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var registry = Registry.init(arena_state.allocator());

    try registry.addConcept(.{
        .id = "process.working-directory",
        .object_class = "process",
        .property = "working directory",
        .definition = "directory a process resolves relative paths against",
    });
    try registry.addDomain(.{ .id = "path", .definition = "filesystem path", .datatype = .path, .maximum_length = 4096 });
    try registry.addElement(.{
        .id = "workingDirectory",
        .concept_id = "process.working-directory",
        .domain_id = "path",
        .canonical_key = "workingDirectory",
        .zig_type = "Path",
        .aliases = &.{ "cwd", "working_directory", "current_path", "directory" },
        .obligation = .conditional,
        .status = .standardised,
        .definition = "Directory the process resolves relative paths against.",
        .example = "/home/user/zag",
    });

    try std.testing.expectEqualStrings("workingDirectory", registry.canonicalKey("cwd").?);
    try std.testing.expectEqualStrings("workingDirectory", registry.canonicalKey("current_path").?);
    try std.testing.expect(registry.canonicalKey("unregistered") == null);
    try registry.validateValue("workingDirectory", "/home/user/zag");

    const findings = try registry.validate();
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "registry reports the collisions that cause interface drift" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var registry = Registry.init(arena_state.allocator());

    try registry.addConcept(.{ .id = "c", .object_class = "o", .property = "p", .definition = "test concept" });
    try registry.addDomain(.{ .id = "text", .definition = "any text", .datatype = .text });

    try registry.addElement(.{ .id = "a", .concept_id = "c", .domain_id = "text", .canonical_key = "sameKey", .zig_type = "[]const u8", .definition = "first" });
    try registry.addElement(.{ .id = "b", .concept_id = "c", .domain_id = "text", .canonical_key = "sameKey", .zig_type = "[]const u8", .definition = "second" });
    try registry.addElement(.{ .id = "c1", .concept_id = "c", .domain_id = "text", .canonical_key = "third", .zig_type = "[]const u8", .aliases = &.{"sameKey"}, .definition = "third" });
    try registry.addElement(.{ .id = "d", .concept_id = "missing", .domain_id = "nowhere", .canonical_key = "snake_key", .zig_type = "[]const u8", .definition = "fourth" });

    const findings = (try registry.validate()).items;
    try std.testing.expect(hasFinding(findings, .duplicate_canonical_key));
    try std.testing.expect(hasFinding(findings, .alias_collides_with_key));
    try std.testing.expect(hasFinding(findings, .unknown_value_domain));
    try std.testing.expect(hasFinding(findings, .unknown_concept));
    try std.testing.expect(hasFinding(findings, .key_not_lower_camel_case));
}

test "registry publishes itself as json" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = Registry.init(arena);
    try registry.addConcept(.{ .id = "c", .object_class = "block", .property = "exit status", .definition = "status a process returned" });
    try registry.addDomain(.{ .id = "exit-status", .definition = "process exit status", .datatype = .integer, .minimum = 0, .maximum = 255 });
    try registry.addElement(.{ .id = "exitStatus", .concept_id = "c", .domain_id = "exit-status", .canonical_key = "exitStatus", .zig_type = "?u8", .definition = "Status the process returned when it finished." });

    var aw: std.Io.Writer.Allocating = .init(arena);
    try registry.writeJson(&aw.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const elements = parsed.value.object.get("dataElements").?.array;
    try std.testing.expectEqual(@as(usize, 1), elements.items.len);
    try std.testing.expectEqualStrings("exitStatus", elements.items[0].object.get("canonicalKey").?.string);
    try std.testing.expectEqualStrings("integer", elements.items[0].object.get("valueDomain").?.object.get("datatype").?.string);
}
