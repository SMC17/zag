//! The capability policy engine.
//!
//! Every operation an agent attempts passes through here, and every decision
//! becomes a record. A user can say:
//!
//!   "Let this agent change files in this repository and run tests.
//!    Do not let it push, read ~/.ssh, or reach the network."
//!
//! and that sentence becomes rules the engine enforces mechanically. No prompt
//! instruction can widen it, because prompts are not consulted here.
//!
//! The decisions are also governance evidence: each one names the actor, the
//! capability, the resource, the rule that decided, the outcome and the reason,
//! which is what ISO/IEC 42001 and ISO/IEC 23894 both want to see.

const std = @import("std");
const capability_mod = @import("capability.zig");
const idmod = @import("../core/id.zig");
const timeutil = @import("../core/time.zig");

pub const Capability = capability_mod.Capability;
pub const Resource = capability_mod.Resource;
pub const Request = capability_mod.Request;
pub const Timestamp = timeutil.Timestamp;

pub const Effect = enum {
    allow,
    deny,
    /// A person decides, once, in front of the exact operation.
    require_human,

    /// The most restrictive effect wins, always.
    pub fn strongest(a: Effect, b: Effect) Effect {
        if (a == .deny or b == .deny) return .deny;
        if (a == .require_human or b == .require_human) return .require_human;
        return .allow;
    }
};

/// Where a rule applies. An empty list means "no restriction on this axis".
pub const Scope = struct {
    /// Path prefixes. A path outside all of them does not match.
    paths: []const []const u8 = &.{},
    /// Executable names, matched against the first word of a command.
    commands: []const []const u8 = &.{},
    /// Host names. A leading `*.` matches any subdomain.
    hosts: []const []const u8 = &.{},
    /// Git remotes.
    remotes: []const []const u8 = &.{},
    /// Credential names.
    credentials: []const []const u8 = &.{},
    /// Agent identifiers, as text.
    agents: []const []const u8 = &.{},
    /// The rule stops applying after this instant.
    valid_until: ?Timestamp = null,

    pub fn matches(self: Scope, resource: Resource, agent: ?[]const u8, now: Timestamp) bool {
        if (self.valid_until) |until| {
            if (now.ns > until.ns) return false;
        }
        if (self.agents.len > 0) {
            const name = agent orelse return false;
            var found = false;
            for (self.agents) |a| {
                if (std.mem.eql(u8, a, name)) found = true;
            }
            if (!found) return false;
        }
        return switch (resource) {
            .none => true,
            .path => |p| self.paths.len == 0 or matchesAnyPath(self.paths, p),
            .command => |c| self.commands.len == 0 or matchesAnyCommand(self.commands, c),
            .host => |h| self.hosts.len == 0 or matchesAnyHost(self.hosts, h),
            .remote => |r| self.remotes.len == 0 or matchesAnyPrefix(self.remotes, r),
            .credential => |c| self.credentials.len == 0 or matchesAnyPrefix(self.credentials, c),
            .service => |s| self.hosts.len == 0 or matchesAnyPrefix(self.hosts, s),
        };
    }
};

/// Is `candidate` inside `root`? The candidate is normalised first, so that
/// `/repo/../etc/passwd` does not pass a `/repo` prefix test.
pub fn pathWithin(root: []const u8, candidate: []const u8) bool {
    var normalised_buffer: [4096]u8 = undefined;
    const normalised = normalisePath(candidate, &normalised_buffer) orelse return false;
    const trimmed_root = std.mem.trimEnd(u8, root, "/");
    if (trimmed_root.len == 0) return true;
    if (!std.mem.startsWith(u8, normalised, trimmed_root)) return false;
    if (normalised.len == trimmed_root.len) return true;
    return normalised[trimmed_root.len] == '/';
}

/// Resolve `.` and `..` textually. Returns null when the path escapes above
/// the root, which is itself an answer: such a path is never inside anything.
pub fn normalisePath(path: []const u8, buffer: []u8) ?[]const u8 {
    var parts: [128][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (count == 0) return null;
            count -= 1;
            continue;
        }
        if (count == parts.len) return null;
        parts[count] = part;
        count += 1;
    }
    var written: usize = 0;
    for (parts[0..count]) |part| {
        if (written + 1 + part.len > buffer.len) return null;
        buffer[written] = '/';
        written += 1;
        @memcpy(buffer[written .. written + part.len], part);
        written += part.len;
    }
    if (written == 0) {
        if (buffer.len == 0) return null;
        buffer[0] = '/';
        written = 1;
    }
    return buffer[0..written];
}

fn matchesAnyPath(prefixes: []const []const u8, path: []const u8) bool {
    for (prefixes) |prefix| {
        if (pathWithin(prefix, path)) return true;
    }
    return false;
}

fn matchesAnyCommand(names: []const []const u8, command: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, command, " \t");
    const first = it.next() orelse return false;
    const base = if (std.mem.lastIndexOfScalar(u8, first, '/')) |slash| first[slash + 1 ..] else first;
    for (names) |name| {
        if (std.mem.eql(u8, name, base)) return true;
        // A rule may name a whole command line, as in "git push".
        if (std.mem.startsWith(u8, command, name)) return true;
    }
    return false;
}

fn matchesAnyHost(patterns: []const []const u8, host: []const u8) bool {
    const name = if (std.mem.indexOfScalar(u8, host, ':')) |colon| host[0..colon] else host;
    for (patterns) |pattern| {
        if (std.mem.eql(u8, pattern, name)) return true;
        if (std.mem.startsWith(u8, pattern, "*.")) {
            const suffix = pattern[1..]; // ".example.test"
            if (std.mem.endsWith(u8, name, suffix)) return true;
        }
    }
    return false;
}

fn matchesAnyPrefix(prefixes: []const []const u8, value: []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, value, prefix)) return true;
    }
    return false;
}

pub const Rule = struct {
    id: []const u8,
    capabilities: []const Capability,
    scope: Scope = .{},
    effect: Effect,
    /// Why this rule exists, in the words that will be shown to the person.
    reason: []const u8,

    pub fn covers(self: Rule, request: Request, agent: ?[]const u8, now: Timestamp) bool {
        var capability_matches = false;
        for (self.capabilities) |c| {
            if (c == request.capability) capability_matches = true;
        }
        if (!capability_matches) return false;
        return self.scope.matches(request.resource, agent, now);
    }
};

pub const Policy = struct {
    id: []const u8,
    name: []const u8,
    /// One sentence a person can read to know what this policy allows.
    description: []const u8,
    rules: []const Rule,
    /// What happens when no rule matches. Deny is the only safe default.
    default_effect: Effect = .deny,
};

pub const Context = struct {
    actor: idmod.ActorId,
    session: ?idmod.SessionId = null,
    agent: ?idmod.AgentId = null,
    /// Text form of the agent identifier, for scope matching.
    agent_name: ?[]const u8 = null,
    now: Timestamp,
};

pub const Decision = struct {
    id: idmod.DecisionId,
    request: Request,
    effect: Effect,
    /// The rule that decided, when one did.
    rule_id: ?[]const u8,
    policy_id: []const u8,
    reason: []const u8,
    actor: idmod.ActorId,
    session: ?idmod.SessionId,
    agent: ?idmod.AgentId,
    decided_at: Timestamp,
    /// True when a standing grant from an earlier approval decided this.
    from_standing_grant: bool = false,

    pub fn isAllowed(self: Decision) bool {
        return self.effect == .allow;
    }
};

/// A standing permission created when a person chose "always allow here".
pub const Grant = struct {
    capability: Capability,
    /// The resource text the grant covers, matched as a prefix or a path root.
    resource: Resource,
    session: ?idmod.SessionId,
    granted_by: idmod.ActorId,
    granted_at: Timestamp,
    expires_at: ?Timestamp = null,

    pub fn covers(self: Grant, request: Request, session: ?idmod.SessionId, now: Timestamp) bool {
        if (self.capability != request.capability) return false;
        if (self.expires_at) |expiry| {
            if (now.ns > expiry.ns) return false;
        }
        if (self.session) |scoped| {
            const current = session orelse return false;
            if (!scoped.eql(current)) return false;
        }
        return switch (self.resource) {
            .none => true,
            .path => |root| switch (request.resource) {
                .path => |p| pathWithin(root, p),
                else => false,
            },
            else => std.mem.eql(u8, self.resource.text(), request.resource.text()),
        };
    }
};

pub const Engine = struct {
    arena: std.mem.Allocator,
    policy: Policy,
    grants: std.ArrayList(Grant) = .empty,
    decisions: std.ArrayList(Decision) = .empty,
    ids: idmod.Generator,

    pub fn init(arena: std.mem.Allocator, policy: Policy, seed: u64) Engine {
        return .{ .arena = arena, .policy = policy, .ids = idmod.Generator.init(seed, 0) };
    }

    /// Decide one request. Deny wins over "ask a person", which wins over
    /// allow, so adding a rule can never widen what is already forbidden.
    pub fn decide(self: *Engine, request: Request, context: Context) !Decision {
        self.ids.clock_ms = @divFloor(context.now.ns, timeutil.ns_per_ms);

        var effect: ?Effect = null;
        var rule_id: ?[]const u8 = null;
        var reason: []const u8 = "";

        for (self.policy.rules) |rule| {
            if (!rule.covers(request, context.agent_name, context.now)) continue;
            const combined = if (effect) |current| Effect.strongest(current, rule.effect) else rule.effect;
            // Record the rule that produced the winning effect.
            if (effect == null or combined != effect.?) {
                rule_id = rule.id;
                reason = rule.reason;
            }
            effect = combined;
        }

        var from_grant = false;
        if (effect == null or effect.? == .require_human) {
            for (self.grants.items) |standing| {
                if (!standing.covers(request, context.session, context.now)) continue;
                effect = .allow;
                from_grant = true;
                reason = "You allowed this here earlier.";
                break;
            }
        }

        const final = effect orelse self.policy.default_effect;
        if (effect == null) {
            reason = "No rule in this policy allows it, so it is not allowed.";
        }

        const decision: Decision = .{
            .id = self.ids.next(idmod.DecisionId),
            .request = request,
            .effect = final,
            .rule_id = rule_id,
            .policy_id = self.policy.id,
            .reason = reason,
            .actor = context.actor,
            .session = context.session,
            .agent = context.agent,
            .decided_at = context.now,
            .from_standing_grant = from_grant,
        };
        try self.decisions.append(self.arena, decision);
        return decision;
    }

    /// Record a person's "always allow here".
    pub fn grant(self: *Engine, g: Grant) !void {
        try self.grants.append(self.arena, g);
    }

    /// Remove every standing grant for a capability. Used when a person
    /// withdraws a permission.
    pub fn revoke(self: *Engine, c: Capability) void {
        var index: usize = 0;
        while (index < self.grants.items.len) {
            if (self.grants.items[index].capability == c) {
                _ = self.grants.orderedRemove(index);
            } else index += 1;
        }
    }

    pub fn decisionsFor(self: Engine, agent: idmod.AgentId) !std.ArrayList(Decision) {
        var out: std.ArrayList(Decision) = .empty;
        for (self.decisions.items) |d| {
            const a = d.agent orelse continue;
            if (a.eql(agent)) try out.append(self.arena, d);
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// Ready-made policies
// ---------------------------------------------------------------------------

/// The policy behind the sentence in this module's opening comment.
pub fn repositoryWriteNoNetwork(repository_root: []const u8, arena: std.mem.Allocator) !Policy {
    const roots = try arena.dupe([]const u8, &.{repository_root});
    const rules = try arena.dupe(Rule, &.{
        .{
            .id = "read-repository",
            .capabilities = &.{ .@"fs.read", .@"git.read" },
            .scope = .{ .paths = roots },
            .effect = .allow,
            .reason = "The agent may read the repository it is working in.",
        },
        .{
            .id = "write-repository",
            .capabilities = &.{ .@"fs.write", .@"git.commit" },
            .scope = .{ .paths = roots },
            .effect = .allow,
            .reason = "The agent may change files in the repository it is working in.",
        },
        .{
            .id = "run-build-and-tests",
            .capabilities = &.{.@"process.execute"},
            .scope = .{ .commands = try arena.dupe([]const u8, &.{ "zig", "make", "cargo", "npm", "pytest", "git" }) },
            .effect = .allow,
            .reason = "The agent may run the build and the tests.",
        },
        .{
            .id = "ask-before-deleting",
            .capabilities = &.{.@"fs.delete"},
            .scope = .{ .paths = roots },
            .effect = .require_human,
            .reason = "Deleting files cannot be undone, so a person decides.",
        },
        .{
            .id = "no-network",
            .capabilities = &.{ .@"network.connect", .@"network.listen" },
            .effect = .deny,
            .reason = "This policy does not allow the agent to use the network.",
        },
        .{
            .id = "no-push",
            .capabilities = &.{.@"git.push"},
            .effect = .deny,
            .reason = "This policy does not allow the agent to send commits to the shared repository.",
        },
        .{
            .id = "no-credentials",
            .capabilities = &.{ .@"credentials.read", .@"credentials.use" },
            .effect = .deny,
            .reason = "This policy does not allow the agent to use saved credentials.",
        },
    });
    return .{
        .id = "repo-write-no-network",
        .name = "Change this repository, no network",
        .description = "The agent can read and change files in this repository and run the build and the tests. It cannot use the network, push commits, or use saved credentials. Deleting a file needs your approval.",
        .rules = rules,
        .default_effect = .deny,
    };
}

/// Read-only review: the agent can look, and nothing else.
pub fn readOnlyReview(repository_root: []const u8, arena: std.mem.Allocator) !Policy {
    const roots = try arena.dupe([]const u8, &.{repository_root});
    const rules = try arena.dupe(Rule, &.{
        .{
            .id = "read-only",
            .capabilities = &.{ .@"fs.read", .@"git.read" },
            .scope = .{ .paths = roots },
            .effect = .allow,
            .reason = "A review agent reads the repository.",
        },
    });
    return .{
        .id = "read-only-review",
        .name = "Read this repository only",
        .description = "The agent can read files and repository history. It cannot change anything, run anything, or use the network.",
        .rules = rules,
        .default_effect = .deny,
    };
}

const testing = std.testing;

fn testContext(gen: *idmod.Generator, now: Timestamp) Context {
    return .{ .actor = gen.next(idmod.ActorId), .session = gen.next(idmod.SessionId), .agent = gen.next(idmod.AgentId), .now = now };
}

test "the policy enforces the sentence a person wrote" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(101, 1_788_000_000_000);
    const now = try Timestamp.parseIso("2026-09-04T20:00:00Z");
    const policy = try repositoryWriteNoNetwork("/home/user/zag", arena);
    var engine = Engine.init(arena, policy, 102);
    const context = testContext(&gen, now);

    const write = try engine.decide(.{ .capability = .@"fs.write", .resource = .{ .path = "/home/user/zag/src/main.zig" } }, context);
    try testing.expectEqual(Effect.allow, write.effect);

    const run_tests = try engine.decide(.{ .capability = .@"process.execute", .resource = .{ .command = "zig build test" } }, context);
    try testing.expectEqual(Effect.allow, run_tests.effect);

    const push = try engine.decide(.{ .capability = .@"git.push", .resource = .{ .remote = "origin" } }, context);
    try testing.expectEqual(Effect.deny, push.effect);

    const ssh_key = try engine.decide(.{ .capability = .@"fs.read", .resource = .{ .path = "/home/user/.ssh/id_ed25519" } }, context);
    try testing.expectEqual(Effect.deny, ssh_key.effect);

    const network = try engine.decide(.{ .capability = .@"network.connect", .resource = .{ .host = "api.example.test" } }, context);
    try testing.expectEqual(Effect.deny, network.effect);
    try testing.expectEqualStrings("no-network", network.rule_id.?);
}

test "path traversal cannot escape the repository" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(103, 1_788_000_000_000);
    const now = try Timestamp.parseIso("2026-09-04T20:00:00Z");
    var engine = Engine.init(arena, try repositoryWriteNoNetwork("/home/user/zag", arena), 104);
    const context = testContext(&gen, now);

    const escape = try engine.decide(.{ .capability = .@"fs.write", .resource = .{ .path = "/home/user/zag/../.ssh/authorized_keys" } }, context);
    try testing.expectEqual(Effect.deny, escape.effect);

    try testing.expect(pathWithin("/home/user/zag", "/home/user/zag/src/x.zig"));
    try testing.expect(!pathWithin("/home/user/zag", "/home/user/zagreb/x.zig"));
    try testing.expect(!pathWithin("/home/user/zag", "/home/user/zag/../../etc/passwd"));
}

test "deleting asks a person, and a standing grant answers next time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(105, 1_788_000_000_000);
    const now = try Timestamp.parseIso("2026-09-04T20:00:00Z");
    var engine = Engine.init(arena, try repositoryWriteNoNetwork("/home/user/zag", arena), 106);
    const context = testContext(&gen, now);

    const first = try engine.decide(.{ .capability = .@"fs.delete", .resource = .{ .path = "/home/user/zag/build" } }, context);
    try testing.expectEqual(Effect.require_human, first.effect);
    try testing.expectEqualStrings("ask-before-deleting", first.rule_id.?);

    try engine.grant(.{
        .capability = .@"fs.delete",
        .resource = .{ .path = "/home/user/zag/build" },
        .session = context.session,
        .granted_by = context.actor,
        .granted_at = now,
    });

    const second = try engine.decide(.{ .capability = .@"fs.delete", .resource = .{ .path = "/home/user/zag/build/x.o" } }, context);
    try testing.expectEqual(Effect.allow, second.effect);
    try testing.expect(second.from_standing_grant);

    // The grant is scoped: it does not reach outside the folder it covers.
    const elsewhere = try engine.decide(.{ .capability = .@"fs.delete", .resource = .{ .path = "/home/user/zag/src/main.zig" } }, context);
    try testing.expectEqual(Effect.require_human, elsewhere.effect);

    engine.revoke(.@"fs.delete");
    const after_revoke = try engine.decide(.{ .capability = .@"fs.delete", .resource = .{ .path = "/home/user/zag/build/x.o" } }, context);
    try testing.expectEqual(Effect.require_human, after_revoke.effect);
}

test "a grant cannot outlive its expiry, and a rule cannot outlive its window" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(107, 1_788_000_000_000);
    const now = try Timestamp.parseIso("2026-09-04T20:00:00Z");
    const later = now.addNanos(timeutil.ns_per_hour);

    const rules = try arena.dupe(Rule, &.{.{
        .id = "temporary-network",
        .capabilities = &.{.@"network.connect"},
        .scope = .{ .valid_until = now.addNanos(timeutil.ns_per_min) },
        .effect = .allow,
        .reason = "You allowed the network for one minute.",
    }});
    var engine = Engine.init(arena, .{ .id = "p", .name = "temporary", .description = "test policy", .rules = rules }, 108);

    var context = testContext(&gen, now);
    const inside = try engine.decide(.{ .capability = .@"network.connect", .resource = .{ .host = "example.test" } }, context);
    try testing.expectEqual(Effect.allow, inside.effect);

    context.now = later;
    const outside = try engine.decide(.{ .capability = .@"network.connect", .resource = .{ .host = "example.test" } }, context);
    try testing.expectEqual(Effect.deny, outside.effect);
}

test "host patterns match subdomains but not neighbours" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(109, 1_788_000_000_000);
    const now = try Timestamp.parseIso("2026-09-04T20:00:00Z");
    const rules = try arena.dupe(Rule, &.{.{
        .id = "allow-internal",
        .capabilities = &.{.@"network.connect"},
        .scope = .{ .hosts = try arena.dupe([]const u8, &.{"*.internal.test"}) },
        .effect = .allow,
        .reason = "Internal services are allowed.",
    }});
    var engine = Engine.init(arena, .{ .id = "p", .name = "internal", .description = "test policy", .rules = rules }, 110);
    const context = testContext(&gen, now);

    try testing.expectEqual(Effect.allow, (try engine.decide(.{ .capability = .@"network.connect", .resource = .{ .host = "build.internal.test:443" } }, context)).effect);
    try testing.expectEqual(Effect.deny, (try engine.decide(.{ .capability = .@"network.connect", .resource = .{ .host = "internal.test.evil.example" } }, context)).effect);
}

test "every decision is kept as a record" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var gen: idmod.Generator = .init(111, 1_788_000_000_000);
    const now = try Timestamp.parseIso("2026-09-04T20:00:00Z");
    var engine = Engine.init(arena, try readOnlyReview("/repo", arena), 112);
    const context = testContext(&gen, now);

    _ = try engine.decide(.{ .capability = .@"fs.read", .resource = .{ .path = "/repo/README.md" } }, context);
    _ = try engine.decide(.{ .capability = .@"fs.write", .resource = .{ .path = "/repo/README.md" } }, context);

    try testing.expectEqual(@as(usize, 2), engine.decisions.items.len);
    const for_agent = try engine.decisionsFor(context.agent.?);
    try testing.expectEqual(@as(usize, 2), for_agent.items.len);
    try testing.expectEqual(Effect.deny, engine.decisions.items[1].effect);
    try testing.expect(std.mem.indexOf(u8, engine.decisions.items[1].reason, "not allowed") != null);
}
