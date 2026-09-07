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

/// A starter policy, written for a person who has just set an API key and
/// wants to ask a model a question.
///
/// This exists because the format defeated the person who wrote the parser. The
/// first attempt at a policy file here was `effect = "allow"` with a
/// `capabilities` list — a reasonable guess, and not the format. `zag policy`
/// said exactly what was wrong, which was the difference between a puzzle and a
/// dead end, but a good error message is a worse answer than a file that is
/// already correct.
///
/// It is deliberately not the most permissive thing that works. It allows one
/// provider by name and denies reading a credential's value, so the first
/// policy somebody owns is one that already says no to something. A starter
/// file that allowed everything would teach that the policy is a formality to
/// be widened until the error stops.
pub fn writeStarter(w: *std.Io.Writer, host: []const u8) std.Io.Writer.Error!void {
    try w.print(
        \\# What this workspace allows. Anything not allowed here is refused.
        \\#
        \\# Each [[rule]] names ONE effect — allow, ask or deny — and lists the
        \\# capabilities it applies to. A rule with no effect does nothing, and
        \\# this file is refused as a whole if any rule is unusable: nothing is
        \\# granted by being written badly.
        \\#
        \\# Run "zag policy" to see what is in force, and "zag doctor" to see
        \\# whether anything is missing.
        \\
        \\[[rule]]
        \\id = "ask-a-model"
        \\allow = ["model.infer"]
        \\because = "This workspace may ask a model questions."
        \\
        \\[[rule]]
        \\id = "reach-the-provider"
        \\allow = ["network.connect"]
        \\hosts = ["{s}"]
        \\because = "The model runs there, and nowhere else may be reached."
        \\
        \\[[rule]]
        \\id = "spend-the-key"
        \\allow = ["credentials.use"]
        \\because = "A request may be signed with a saved key."
        \\
        \\[[rule]]
        \\id = "never-read-the-key"
        \\deny = ["credentials.read"]
        \\because = "Nothing needs the key's value, so nothing may see it."
        \\
        \\[[rule]]
        \\id = "read-this-workspace"
        \\allow = ["fs.read"]
        \\because = "A model may read the files in the workspace it was asked about."
        \\
        \\# Uncomment to let a model run commands and change files. Read what it
        \\# is about to do first: "ask" stops for a person, "allow" does not.
        \\#
        \\# [[rule]]
        \\# id = "run-commands"
        \\# ask = ["process.execute", "fs.write"]
        \\# because = "A person decides each command before it runs."
        \\
    , .{host});
}

test "the starter policy this build writes is one this build can read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The whole point of the starter file is that it is already correct. One
    // that does not parse is worse than none, because it is the first thing
    // somebody edits and it teaches them the format is broken.
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeStarter(&out.writer, "api.anthropic.com");

    const result = try parse(arena, out.written());
    if (!result.usable()) {
        for (result.problems) |problem| std.debug.print("starter policy problem: {s}\n", .{problem.message});
    }
    try testing.expect(result.usable());
    try testing.expectEqual(@as(usize, 0), result.problems.len);

    var engine = policy_mod.Engine.init(arena, result.policy.?, 7);
    const context = starterContext();

    // It allows what asking a model needs, and refuses to read the key's value.
    try testing.expectEqual(Effect.allow, (try engine.decide(.{ .capability = .@"model.infer" }, context)).effect);
    try testing.expectEqual(Effect.deny, (try engine.decide(.{ .capability = .@"credentials.read" }, context)).effect);
    // And it is not a blank cheque: nothing said it could push to a remote.
    try testing.expectEqual(Effect.deny, (try engine.decide(.{ .capability = .@"git.push" }, context)).effect);
}

fn starterContext() policy_mod.Context {
    const idmod = @import("../core/id.zig");
    var gen: idmod.Generator = .init(9, 1_788_000_000_000);
    return .{
        .actor = gen.next(idmod.ActorId),
        .session = gen.next(idmod.SessionId),
        .agent = gen.next(idmod.AgentId),
        .now = @import("../core/time.zig").Timestamp.parseIso("2026-09-07T12:00:00Z") catch unreachable,
    };
}

test "the starter policy scopes the network to the host it names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(arena);
    try writeStarter(&out.writer, "api.anthropic.com");
    var engine = policy_mod.Engine.init(arena, (try parse(arena, out.written())).policy.?, 8);
    const context = starterContext();

    try testing.expectEqual(Effect.allow, (try engine.decide(.{
        .capability = .@"network.connect",
        .resource = .{ .host = "api.anthropic.com" },
    }, context)).effect);
    // Somewhere else is refused, which is the part that makes writing the host
    // down worth doing at all.
    try testing.expectEqual(Effect.deny, (try engine.decide(.{
        .capability = .@"network.connect",
        .resource = .{ .host = "example.invalid" },
    }, context)).effect);
}
