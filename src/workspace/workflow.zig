//! Workflows as typed task graphs.
//!
//! A list of shell steps is not a workflow. It cannot say what a step needs,
//! what it produces, what it is allowed to do, when its result can be reused,
//! or what happens when it fails. Every one of those questions has to be
//! answered somewhere, and if the workflow format cannot hold the answer, the
//! answer ends up in someone's head.
//!
//! So a workflow here is a graph of typed nodes. The same graph runs a local
//! task, an agent's plan, a continuous integration job and a reproducible
//! debugging session, because the difference between those is which executor
//! and which policy it runs under, not which format it is written in.

const std = @import("std");
const tools = @import("../ai/tools.zig");
const capability_mod = @import("../ai/capability.zig");
const hashing = @import("../core/hash.zig");
const timeutil = @import("../core/time.zig");

pub const Capability = capability_mod.Capability;

pub const Error = error{
    UnknownNode,
    CycleDetected,
    DuplicateNode,
    MissingInput,
    OutOfMemory,
};

/// What a node needs, and what it leaves behind. Inputs and outputs are named
/// so that the graph can be checked before anything runs.
pub const Artefact = struct {
    name: []const u8,
    /// Where it lives once produced: a path, or a name in the content store.
    location: []const u8 = "",
};

pub const OnFailure = enum {
    /// Stop the whole workflow.
    stop,
    /// Carry on with the nodes that do not depend on this one.
    continue_others,
    /// Try again, up to `retries`.
    retry,
    /// The node is allowed to fail; its outputs are then absent.
    ignore,
};

pub const Node = struct {
    id: []const u8,
    /// One line saying what this step is for, in words a person reads in the
    /// run view.
    description: []const u8,
    /// Nodes that must finish first.
    needs: []const []const u8 = &.{},
    inputs: []const Artefact = &.{},
    outputs: []const Artefact = &.{},
    /// The typed request this node performs.
    request: tools.ToolRequest,
    /// Extra capabilities beyond the one the request implies. Declaring them
    /// here means the whole workflow's permissions can be read before it runs.
    extra_capabilities: []const Capability = &.{},
    /// A person must approve before this node runs, whatever the policy says.
    needs_approval: bool = false,
    on_failure: OnFailure = .stop,
    retries: u8 = 0,
    timeout: timeutil.Duration = .{ .ns = 300 * timeutil.ns_per_s },

    /// The key that decides whether an earlier result can be reused. It covers
    /// the request, the inputs and the environment, so a cache hit means the
    /// same work under the same conditions.
    pub fn cacheKey(self: Node, arena: std.mem.Allocator, environment: hashing.Hash) !hashing.Hash {
        var parts: std.ArrayList([]const u8) = .empty;
        try parts.append(arena, self.id);
        try parts.append(arena, @tagName(self.request));
        var arguments: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(self.request, .{}, &arguments.writer);
        try parts.append(arena, arguments.written());
        for (self.inputs) |input| {
            try parts.append(arena, input.name);
            try parts.append(arena, input.location);
        }
        try parts.append(arena, &environment.bytes);
        return hashing.Hash.ofParts(parts.items);
    }

    pub fn capabilities(self: Node, arena: std.mem.Allocator) ![]const Capability {
        var out: std.ArrayList(Capability) = .empty;
        try out.append(arena, self.request.capability());
        if (self.request.additionalCapability()) |extra| try out.append(arena, extra);
        for (self.extra_capabilities) |extra| try out.append(arena, extra);
        return out.toOwnedSlice(arena);
    }
};

pub const Workflow = struct {
    id: []const u8,
    name: []const u8,
    /// What a person gets when the workflow finishes.
    outcome: []const u8,
    nodes: []const Node,

    pub fn node(self: Workflow, id: []const u8) ?Node {
        for (self.nodes) |n| {
            if (std.mem.eql(u8, n.id, id)) return n;
        }
        return null;
    }

    /// Every capability the workflow could use, so a person can read the whole
    /// permission surface before starting it.
    pub fn capabilities(self: Workflow, arena: std.mem.Allocator) ![]const Capability {
        var seen: std.ArrayList(Capability) = .empty;
        for (self.nodes) |n| {
            for (try n.capabilities(arena)) |capability| {
                var found = false;
                for (seen.items) |existing| {
                    if (existing == capability) found = true;
                }
                if (!found) try seen.append(arena, capability);
            }
        }
        return seen.toOwnedSlice(arena);
    }

    /// Nodes in an order where every node comes after everything it needs.
    pub fn order(self: Workflow, arena: std.mem.Allocator) Error![]const []const u8 {
        const state = try arena.alloc(u8, self.nodes.len); // 0 unvisited, 1 in progress, 2 done
        @memset(state, 0);
        var out: std.ArrayList([]const u8) = .empty;

        for (self.nodes, 0..) |_, index| {
            try self.visit(arena, index, state, &out);
        }
        return out.toOwnedSlice(arena);
    }

    fn visit(self: Workflow, arena: std.mem.Allocator, index: usize, state: []u8, out: *std.ArrayList([]const u8)) Error!void {
        if (state[index] == 2) return;
        if (state[index] == 1) return error.CycleDetected;
        state[index] = 1;
        for (self.nodes[index].needs) |need| {
            const next = self.indexOf(need) orelse return error.UnknownNode;
            try self.visit(arena, next, state, out);
        }
        state[index] = 2;
        try out.append(arena, self.nodes[index].id);
    }

    fn indexOf(self: Workflow, id: []const u8) ?usize {
        for (self.nodes, 0..) |n, index| {
            if (std.mem.eql(u8, n.id, id)) return index;
        }
        return null;
    }

    /// Groups of nodes that can run at the same time. The first group needs
    /// nothing; each later group needs only the groups before it.
    pub fn stages(self: Workflow, arena: std.mem.Allocator) Error![]const []const []const u8 {
        const sorted = try self.order(arena);
        var depth: std.StringArrayHashMapUnmanaged(usize) = .empty;
        var deepest: usize = 0;

        for (sorted) |id| {
            const n = self.node(id) orelse return error.UnknownNode;
            var level: usize = 0;
            for (n.needs) |need| {
                const need_level = depth.get(need) orelse return error.UnknownNode;
                level = @max(level, need_level + 1);
            }
            try depth.put(arena, id, level);
            deepest = @max(deepest, level);
        }

        var groups = try arena.alloc(std.ArrayList([]const u8), deepest + 1);
        for (groups) |*group| group.* = .empty;
        for (sorted) |id| {
            const level = depth.get(id).?;
            try groups[level].append(arena, id);
        }

        var out = try arena.alloc([]const []const u8, groups.len);
        for (groups, 0..) |group, index| out[index] = group.items;
        return out;
    }

    pub const Finding = struct {
        node_id: []const u8,
        message: []const u8,
    };

    /// Check the graph before anything runs.
    pub fn validate(self: Workflow, arena: std.mem.Allocator) !std.ArrayList(Finding) {
        var findings: std.ArrayList(Finding) = .empty;

        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (self.nodes) |n| {
            if (seen.contains(n.id)) {
                try findings.append(arena, .{
                    .node_id = n.id,
                    .message = try std.fmt.allocPrint(arena, "Two steps share the identifier \"{s}\".", .{n.id}),
                });
            }
            try seen.put(arena, n.id, {});

            for (n.needs) |need| {
                if (self.node(need) == null) {
                    try findings.append(arena, .{
                        .node_id = n.id,
                        .message = try std.fmt.allocPrint(arena, "\"{s}\" waits for \"{s}\", which is not a step in this workflow.", .{ n.id, need }),
                    });
                }
            }

            if (n.description.len == 0) {
                try findings.append(arena, .{
                    .node_id = n.id,
                    .message = try std.fmt.allocPrint(arena, "\"{s}\" has no description, so a person watching the run cannot tell what it is doing.", .{n.id}),
                });
            }

            if (n.on_failure == .retry and n.retries == 0) {
                try findings.append(arena, .{
                    .node_id = n.id,
                    .message = try std.fmt.allocPrint(arena, "\"{s}\" says it retries, but allows no attempts.", .{n.id}),
                });
            }

            // An input no earlier step produces will never appear.
            for (n.inputs) |input| {
                var produced = false;
                for (self.nodes) |other| {
                    if (std.mem.eql(u8, other.id, n.id)) continue;
                    for (other.outputs) |output| {
                        if (std.mem.eql(u8, output.name, input.name)) produced = true;
                    }
                }
                if (!produced and input.location.len == 0) {
                    try findings.append(arena, .{
                        .node_id = n.id,
                        .message = try std.fmt.allocPrint(arena, "\"{s}\" needs \"{s}\", which no step produces and which has no location.", .{ n.id, input.name }),
                    });
                }
            }
        }

        _ = self.order(arena) catch |err| switch (err) {
            error.CycleDetected => try findings.append(arena, .{
                .node_id = self.id,
                .message = "The steps form a loop, so no order can satisfy them all.",
            }),
            // A step that waits for something that is not here is already
            // reported above, with the name of the missing step.
            error.UnknownNode => {},
            else => return err,
        };

        return findings;
    }

    /// A plain-language description of the whole workflow, including what it is
    /// allowed to do. This is what a person reads before they start it.
    pub fn writeSummary(self: Workflow, arena: std.mem.Allocator, w: *std.Io.Writer) !void {
        try w.print("{s}\n{s}\n\nWhen it finishes: {s}\n\n", .{ self.name, self.id, self.outcome });

        const groups = try self.stages(arena);
        for (groups, 0..) |group, index| {
            try w.print("Stage {d}", .{index + 1});
            if (group.len > 1) try w.print(" ({d} steps run together)", .{group.len});
            try w.writeAll("\n");
            for (group) |id| {
                const n = self.node(id).?;
                try w.print("  {s}: {s}\n", .{ n.id, n.description });
                if (n.needs_approval) try w.writeAll("    A person approves this step before it runs.\n");
                switch (n.on_failure) {
                    .stop => {},
                    .continue_others => try w.writeAll("    If it fails, the steps that do not need it carry on.\n"),
                    .retry => try w.print("    If it fails, it runs again, up to {d} more time(s).\n", .{n.retries}),
                    .ignore => try w.writeAll("    It is allowed to fail.\n"),
                }
            }
        }

        try w.writeAll("\nWhat this workflow is allowed to do\n");
        for (try self.capabilities(arena)) |capability| {
            try w.print("  - {s}\n", .{capability.explain()});
        }
    }
};

/// The workflow the repository runs on itself. It is written here rather than
/// in a configuration file because it is executable documentation: the shape of
/// a real workflow, checked by the tests.
///
/// It takes an allocator because the node list mentions `repository`, which is
/// a run-time value. Returning `&.{ ... }` over run-time values would return a
/// pointer to a temporary that dies with this function.
pub fn buildAndCheck(arena: std.mem.Allocator, repository: []const u8) !Workflow {
    const nodes = [_]Node{
        .{
                .id = "test",
                .description = "Run every test.",
                .request = .{ .execute = .{ .argv = &.{ "zig", "build", "test" }, .workingDirectory = repository } },
                .outputs = &.{.{ .name = "test-result", .location = "zig-out" }},
                .on_failure = .stop,
                .timeout = .{ .ns = 900 * timeutil.ns_per_s },
            },
            .{
                .id = "build",
                .description = "Build the tools.",
                .needs = &.{"test"},
                .request = .{ .execute = .{ .argv = &.{"zig", "build"}, .workingDirectory = repository } },
                .outputs = &.{.{ .name = "binaries", .location = "zig-out/bin" }},
            },
            .{
                .id = "audit",
                .description = "Audit the repository against its standards profile.",
                .needs = &.{"build"},
                .inputs = &.{.{ .name = "binaries", .location = "zig-out/bin" }},
                .request = .{ .execute = .{ .argv = &.{ "zig", "build", "check" }, .workingDirectory = repository } },
                .outputs = &.{.{ .name = "conformance-report", .location = "" }},
            },
            .{
                .id = "emit",
                .description = "Regenerate the schemas, the vocabulary and the documents that are generated.",
                .needs = &.{"build"},
                .inputs = &.{.{ .name = "binaries", .location = "zig-out/bin" }},
                .request = .{ .execute = .{ .argv = &.{ "zig", "build", "emit" }, .workingDirectory = repository } },
                .outputs = &.{.{ .name = "generated-files", .location = "schemas" }},
            },
        .{
                .id = "check-generated",
                .description = "Check that nothing generated has fallen behind the code.",
                .needs = &.{"emit"},
                .inputs = &.{.{ .name = "generated-files", .location = "schemas" }},
                .request = .{ .execute = .{ .argv = &.{ "git", "diff", "--exit-code" }, .workingDirectory = repository } },
            },
    };

    return .{
        .id = "build-and-check",
        .name = "Build the workbench and audit it",
        .outcome = "The tests pass, the repository meets the standards it can check, and the generated files match the code.",
        .nodes = try arena.dupe(Node, &nodes),
    };
}

const testing = std.testing;

test "a workflow orders its steps and groups the ones that can run together" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const workflow = try buildAndCheck(arena, "/repo");
    const order = try workflow.order(arena);
    try testing.expectEqual(@as(usize, 5), order.len);
    try testing.expectEqualStrings("test", order[0]);

    const stages = try workflow.stages(arena);
    try testing.expectEqual(@as(usize, 4), stages.len);
    try testing.expectEqual(@as(usize, 1), stages[0].len);
    // "audit" and "emit" both need only "build", so they run together.
    try testing.expectEqual(@as(usize, 2), stages[2].len);
}

test "a loop in the graph is reported, not run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const looping: Workflow = .{
        .id = "loop",
        .name = "A workflow that cannot run",
        .outcome = "Nothing.",
        .nodes = &.{
            .{ .id = "a", .description = "First.", .needs = &.{"b"}, .request = .{ .execute = .{ .argv = &.{"true"}, .workingDirectory = "/" } } },
            .{ .id = "b", .description = "Second.", .needs = &.{"a"}, .request = .{ .execute = .{ .argv = &.{"true"}, .workingDirectory = "/" } } },
        },
    };
    try testing.expectError(error.CycleDetected, looping.order(arena));

    const findings = try looping.validate(arena);
    var saw_loop = false;
    for (findings.items) |finding| {
        if (std.mem.indexOf(u8, finding.message, "loop") != null) saw_loop = true;
    }
    try testing.expect(saw_loop);
}

test "the whole permission surface can be read before the workflow starts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const workflow = try buildAndCheck(arena, "/repo");
    const capabilities = try workflow.capabilities(arena);
    try testing.expectEqual(@as(usize, 1), capabilities.len);
    try testing.expectEqual(Capability.@"process.execute", capabilities[0]);

    // A step that reaches the network makes that visible at the top level.
    const networked: Workflow = .{
        .id = "fetch",
        .name = "Fetch dependencies",
        .outcome = "The dependencies are present.",
        .nodes = &.{.{
            .id = "install",
            .description = "Install the dependencies.",
            .request = .{ .execute = .{ .argv = &.{ "npm", "install" }, .workingDirectory = "/repo", .network = .allowlist } },
        }},
    };
    const wider = try networked.capabilities(arena);
    try testing.expectEqual(@as(usize, 2), wider.len);
    try testing.expectEqual(Capability.@"network.connect", wider[1]);
}

test "the cache key covers the request, the inputs and the environment" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const workflow = try buildAndCheck(arena, "/repo");
    const node = workflow.node("test").?;
    const environment_a = hashing.Hash.of("zig 0.16.0, linux");
    const environment_b = hashing.Hash.of("zig 0.16.0, macos");

    const key_a = try node.cacheKey(arena, environment_a);
    const key_b = try node.cacheKey(arena, environment_b);
    try testing.expect(!key_a.eql(key_b));
    try testing.expect(key_a.eql(try node.cacheKey(arena, environment_a)));

    const other = workflow.node("build").?;
    try testing.expect(!key_a.eql(try other.cacheKey(arena, environment_a)));
}

test "a step that waits for a missing step is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const broken: Workflow = .{
        .id = "broken",
        .name = "A workflow with a missing step",
        .outcome = "Nothing.",
        .nodes = &.{
            .{
                .id = "a",
                .description = "",
                .needs = &.{"nowhere"},
                .inputs = &.{.{ .name = "something" }},
                .request = .{ .execute = .{ .argv = &.{"true"}, .workingDirectory = "/" } },
                .on_failure = .retry,
            },
        },
    };
    const findings = (try broken.validate(arena)).items;
    try testing.expectEqual(@as(usize, 4), findings.len);
}

test "the summary reads as something a person would agree to" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const workflow = try buildAndCheck(arena, "/repo");
    var aw: std.Io.Writer.Allocating = .init(arena);
    try workflow.writeSummary(arena, &aw.writer);
    const text = aw.written();

    try testing.expect(std.mem.indexOf(u8, text, "When it finishes:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Stage 3 (2 steps run together)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "run programs on this computer") != null);
}

test "the repository's own workflow is valid" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const workflow = try buildAndCheck(arena, ".");
    const findings = try workflow.validate(arena);
    if (findings.items.len > 0) {
        for (findings.items) |finding| std.debug.print("{s}: {s}\n", .{ finding.node_id, finding.message });
    }
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}
