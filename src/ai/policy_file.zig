//! The workspace policy, as a person writes it.
//!
//! The engine in `policy.zig` enforces rules. This file is where those rules
//! come from when they are not compiled in: `.workspace/policy.toml`, written
//! by the person whose computer this is.
//!
//! It matters that the file is separate from the agent's instructions.
//! `.workspace/rules/` and `AGENTS.md` are read by the model and can say
//! anything; a model that has read them can also be persuaded to ignore them.
//! This file is never shown to a model and never consulted by one. It is read
//! here, turned into rules, and enforced by code the model cannot reach. An
//! instruction file that asks for a capability is a request; this file is the
//! answer.
//!
//! A policy looks like this:
//!
//! ```toml
//! name = "Local models only"
//! description = "This workspace uses models on this computer and reaches nothing else."
//!
//! [[rule]]
//! allow = ["model.infer", "network.connect"]
//! hosts = ["localhost", "127.0.0.1"]
//! because = "Models on this computer are allowed."
//!
//! [[rule]]
//! deny = ["network.connect"]
//! because = "Nothing else on the network may be reached."
//! ```
//!
//! Three things are refused rather than guessed at. A rule that names no
//! capability does nothing, so it is an error rather than a line that quietly
//! has no effect. A capability this build does not know is an error, because
//! silently dropping it would turn a `deny` into permission. And a file with no
//! rules leaves the default in force, which is deny — a policy that allows
//! nothing is a strange thing to write, so it is reported, but it is safe.

const std = @import("std");
const toml = @import("../interop/toml.zig");
const policy_mod = @import("policy.zig");
const capability_mod = @import("capability.zig");

pub const Capability = capability_mod.Capability;
pub const Policy = policy_mod.Policy;
pub const Rule = policy_mod.Rule;
pub const Effect = policy_mod.Effect;

/// Where a workspace keeps its policy, relative to the workspace root.
pub const default_path = ".workspace/policy.toml";

pub const Problem = struct {
    /// Which rule, counting from one, or null for the file itself.
    rule: ?usize,
    /// What is wrong, in words for the person who wrote the file.
    message: []const u8,
};

pub const Error = error{
    /// The file is not valid TOML, or a rule is unusable. `problems` says why.
    PolicyUnusable,
} || std.mem.Allocator.Error;

pub const Result = struct {
    policy: ?Policy,
    problems: []const Problem,

    pub fn usable(self: Result) bool {
        return self.policy != null;
    }
};

/// Read a policy from TOML text.
///
/// Nothing is granted by being written badly. Any problem at all leaves
/// `policy` null, so a file with a typo in it does not become a policy that
/// happens to allow more than the person meant.
pub fn parse(arena: std.mem.Allocator, source: []const u8) Error!Result {
    var problems: std.ArrayList(Problem) = .empty;

    const document = toml.parse(arena, source) catch {
        try problems.append(arena, .{
            .rule = null,
            .message = "This file is not valid TOML, so no rule in it was read.",
        });
        return .{ .policy = null, .problems = problems.items };
    };

    const name = document.string("name") orelse "This workspace";
    const description = document.string("description") orelse
        "A policy written for this workspace.";
    const identifier = document.string("id") orelse "workspace";

    var rules: std.ArrayList(Rule) = .empty;
    if (document.get("rule")) |value| {
        const entries = value.asArray() orelse {
            try problems.append(arena, .{
                .rule = null,
                .message = "The rules must be written as [[rule]] sections.",
            });
            return .{ .policy = null, .problems = problems.items };
        };
        for (entries, 0..) |entry, index| {
            const rule = try readRule(arena, entry, index + 1, &problems);
            if (rule) |r| try rules.append(arena, r);
        }
    } else {
        try problems.append(arena, .{
            .rule = null,
            .message = "This file has no [[rule]] sections, so it allows nothing.",
        });
    }

    if (problems.items.len > 0) return .{ .policy = null, .problems = problems.items };

    return .{
        .policy = .{
            .id = identifier,
            .name = name,
            .description = description,
            .rules = rules.items,
            // Never read from the file. A policy that could set its own
            // fallback to allow would be a policy that fails open.
            .default_effect = .deny,
        },
        .problems = &.{},
    };
}

fn readRule(
    arena: std.mem.Allocator,
    entry: toml.Value,
    number: usize,
    problems: *std.ArrayList(Problem),
) Error!?Rule {
    var effect: ?Effect = null;
    var listed: ?[]toml.Value = null;

    // The verb is the field name, so a rule reads as a sentence rather than as
    // a setting with a value that has to be looked up.
    if (entry.get("allow")) |value| {
        effect = .allow;
        listed = value.asArray();
    }
    if (entry.get("ask")) |value| {
        if (effect != null) {
            try problems.append(arena, .{
                .rule = number,
                .message = "This rule says more than one of allow, ask and deny. Write one.",
            });
            return null;
        }
        effect = .require_human;
        listed = value.asArray();
    }
    if (entry.get("deny")) |value| {
        if (effect != null) {
            try problems.append(arena, .{
                .rule = number,
                .message = "This rule says more than one of allow, ask and deny. Write one.",
            });
            return null;
        }
        effect = .deny;
        listed = value.asArray();
    }

    const chosen = effect orelse {
        try problems.append(arena, .{
            .rule = number,
            .message = "This rule does not say allow, ask or deny, so it would do nothing.",
        });
        return null;
    };

    const names = listed orelse {
        try problems.append(arena, .{
            .rule = number,
            .message = "The capabilities must be written as a list, in square brackets.",
        });
        return null;
    };
    if (names.len == 0) {
        try problems.append(arena, .{
            .rule = number,
            .message = "This rule names no capability, so it would do nothing.",
        });
        return null;
    }

    var capabilities: std.ArrayList(Capability) = .empty;
    for (names) |item| {
        const text = item.asString() orelse {
            try problems.append(arena, .{
                .rule = number,
                .message = "Every capability in this rule must be written in quotes.",
            });
            return null;
        };
        const capability = Capability.parse(text) orelse {
            try problems.append(arena, .{
                .rule = number,
                .message = try std.fmt.allocPrint(
                    arena,
                    "\"{s}\" is not a capability this build knows, so the rule was not used.",
                    .{text},
                ),
            });
            return null;
        };
        try capabilities.append(arena, capability);
    }

    return .{
        .id = entry.stringAt("id") orelse try std.fmt.allocPrint(arena, "rule-{d}", .{number}),
        .capabilities = capabilities.items,
        .scope = .{
            .paths = try stringList(arena, entry, "paths"),
            .commands = try stringList(arena, entry, "commands"),
            .hosts = try stringList(arena, entry, "hosts"),
            .remotes = try stringList(arena, entry, "remotes"),
            .credentials = try stringList(arena, entry, "credentials"),
            .agents = try stringList(arena, entry, "agents"),
        },
        .effect = chosen,
        .reason = entry.stringAt("because") orelse
            "This workspace's policy decided it.",
    };
}

fn stringList(
    arena: std.mem.Allocator,
    entry: toml.Value,
    field: []const u8,
) Error![]const []const u8 {
    const value = entry.get(field) orelse return &.{};
    const items = value.asArray() orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        if (item.asString()) |text| try out.append(arena, text);
    }
    return out.items;
}

/// Write a policy back out as the person would read it.
///
/// Used by `zag doctor` and by the approval prompt, so that what is enforced
/// and what is shown come from the same value rather than from two hand-written
/// descriptions that drift apart.
pub fn describe(policy: Policy, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{s}\n{s}\n\n", .{ policy.name, policy.description });
    for (policy.rules) |rule| {
        try w.print("{s} ", .{switch (rule.effect) {
            .allow => "Allowed:",
            .deny => "Refused:",
            .require_human => "Asks you:",
        }});
        for (rule.capabilities, 0..) |capability, index| {
            if (index > 0) try w.writeAll(", ");
            try w.writeAll(capability.explain());
        }
        try writeScope(rule.scope, w);
        try w.print("\n  {s}\n", .{rule.reason});
    }
    try w.writeAll("\nAnything not named above is refused.\n");
}

fn writeScope(scope: policy_mod.Scope, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeNamed(w, " under ", scope.paths);
    try writeNamed(w, " for ", scope.commands);
    try writeNamed(w, " at ", scope.hosts);
    try writeNamed(w, " to ", scope.remotes);
    try writeNamed(w, " with ", scope.credentials);
    try writeNamed(w, " by ", scope.agents);
}

fn writeNamed(
    w: *std.Io.Writer,
    lead: []const u8,
    values: []const []const u8,
) std.Io.Writer.Error!void {
    if (values.len == 0) return;
    try w.writeAll(lead);
    for (values, 0..) |value, index| {
        if (index > 0) try w.writeAll(", ");
        try w.writeAll(value);
    }
}

/// The policy this repository ships as an example, and the one `zag ask` uses
/// when a workspace has written none.
///
/// It allows models on this computer and refuses everything else, because that
/// is the answer a person is least likely to regret not having been asked
/// about. A workspace that wants a hosted provider writes its own file, and
/// writing it is the moment the decision gets made.
pub const local_models_only =
    \\name = "Models on this computer only"
    \\description = "An agent in this workspace may use a model running on this computer. It may not reach anything else over the network, and it may not use a saved credential."
    \\
    \\[[rule]]
    \\id = "local-models"
    \\allow = ["model.infer"]
    \\because = "Using a model is allowed in this workspace."
    \\
    \\[[rule]]
    \\id = "local-only"
    \\allow = ["network.connect"]
    \\hosts = ["localhost", "127.0.0.1", "::1"]
    \\because = "Only a model running on this computer may be reached."
    \\
    \\[[rule]]
    \\id = "no-saved-credentials"
    \\deny = ["credentials.read", "credentials.use"]
    \\because = "A model on this computer needs no saved credential, so none may be spent."
    \\
;

const testing = std.testing;

test "a written policy becomes rules the engine can enforce" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena, local_models_only);
    try testing.expect(result.usable());
    const policy = result.policy.?;
    try testing.expectEqual(@as(usize, 3), policy.rules.len);
    // Never read from the file, whatever the file says.
    try testing.expectEqual(Effect.deny, policy.default_effect);

    var engine = policy_mod.Engine.init(arena, policy, 5);
    var ids = @import("../core/id.zig").Generator.init(3, 0);
    const context: policy_mod.Context = .{
        .actor = ids.next(@import("../core/id.zig").ActorId),
        .now = .{ .ns = 1_700_000_000 * @import("../core/time.zig").ns_per_s },
    };

    const local = try engine.decide(.{
        .capability = .@"network.connect",
        .resource = .{ .host = "localhost" },
    }, context);
    try testing.expect(local.isAllowed());

    const elsewhere = try engine.decide(.{
        .capability = .@"network.connect",
        .resource = .{ .host = "api.example.test" },
    }, context);
    try testing.expect(!elsewhere.isAllowed());

    // Nothing was said about running programs, so it is refused.
    const run = try engine.decide(.{
        .capability = .@"process.execute",
        .resource = .{ .command = "rm" },
    }, context);
    try testing.expect(!run.isAllowed());
}

test "a capability this build does not know refuses the file rather than dropping the rule" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena,
        \\[[rule]]
        \\deny = ["network.connect", "network.tunnel"]
        \\because = "No network."
        \\
    );
    // The rule was a denial. Dropping the unknown half would have left a
    // narrower denial than the person wrote, so the whole file is refused.
    try testing.expect(!result.usable());
    try testing.expectEqual(@as(usize, 1), result.problems.len);
    try testing.expectEqual(@as(usize, 1), result.problems[0].rule.?);
    try testing.expect(std.mem.indexOf(u8, result.problems[0].message, "network.tunnel") != null);
}

test "a rule that says nothing is reported rather than ignored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nothing = try parse(arena,
        \\[[rule]]
        \\hosts = ["localhost"]
        \\because = "I meant to allow this."
        \\
    );
    try testing.expect(!nothing.usable());
    try testing.expect(std.mem.indexOf(u8, nothing.problems[0].message, "allow, ask or deny") != null);

    const both = try parse(arena,
        \\[[rule]]
        \\allow = ["fs.read"]
        \\deny = ["fs.write"]
        \\
    );
    try testing.expect(!both.usable());
}

test "a file that is not valid toml grants nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena, "[[rule]\nallow = [\"fs.read\"\n");
    try testing.expect(!result.usable());
    try testing.expect(result.problems.len > 0);
}

test "an empty file allows nothing and says so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena, "name = \"Nothing\"\n");
    try testing.expect(!result.usable());
    try testing.expect(std.mem.indexOf(u8, result.problems[0].message, "allows nothing") != null);
}

test "asking a person is a third answer, not a kind of allow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena,
        \\[[rule]]
        \\ask = ["fs.delete"]
        \\paths = ["/repo"]
        \\because = "Deleting a file is worth a moment's thought."
        \\
    );
    try testing.expect(result.usable());
    try testing.expectEqual(Effect.require_human, result.policy.?.rules[0].effect);
}

test "the description reads as sentences, and never as capability names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse(arena, local_models_only);
    var buffer: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try describe(result.policy.?, &w);
    const text = w.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "Allowed:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "localhost") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Anything not named above is refused.") != null);
    // The enum names never reach a person.
    try testing.expect(std.mem.indexOf(u8, text, "network.connect") == null);
    try testing.expect(std.mem.indexOf(u8, text, "model.infer") == null);
}
