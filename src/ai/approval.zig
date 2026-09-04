//! Approval prompts, written for the person who has to answer them.
//!
//! ISO 24495-1 is applied here as a product constraint, not as documentation
//! advice. A prompt that says
//!
//!   "Agent requires elevated process execution capability for proposed
//!    operation."
//!
//! is a defect: the reader cannot tell what will happen, to what, or what their
//! choices mean. This module builds the prompt from the policy decision, so the
//! wording cannot drift from the operation being approved, and the tests run
//! the product's own plain-language checker over the result.

const std = @import("std");
const policy_mod = @import("policy.zig");
const capability_mod = @import("capability.zig");
const timeutil = @import("../core/time.zig");
const idmod = @import("../core/id.zig");

pub const Capability = capability_mod.Capability;
pub const Resource = capability_mod.Resource;
pub const Decision = policy_mod.Decision;

pub const Outcome = enum {
    allow_once,
    allow_always_here,
    deny,
};

pub const Option = struct {
    /// The label on the control. It starts with the verb for what it does.
    label: []const u8,
    /// One sentence saying what choosing it means.
    meaning: []const u8,
    outcome: Outcome,
};

pub const Prompt = struct {
    /// The question, naming the exact operation.
    question: []const u8,
    /// What the agent wants and why, in one or two sentences.
    explanation: []const u8,
    /// What happens if the reader allows it, when that is not obvious.
    consequence: ?[]const u8,
    /// What is *not* affected. Removing a fear the reader would otherwise have
    /// is part of making the choice usable.
    reassurance: ?[]const u8,
    options: []const Option,
    capability: Capability,
    resource: Resource,
    policy_id: []const u8,
    rule_id: ?[]const u8,

    pub fn writeText(self: Prompt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}\n", .{self.question});
        try w.print("{s}\n", .{self.explanation});
        if (self.consequence) |c| try w.print("{s}\n", .{c});
        if (self.reassurance) |r| try w.print("{s}\n", .{r});
        try w.writeAll("\n");
        for (self.options, 0..) |option, i| {
            if (i > 0) try w.writeAll("  ·  ");
            try w.writeAll(option.label);
        }
        try w.writeAll("\n");
    }

    /// The whole prompt as one string, which is what is stored in the event log
    /// so that an auditor sees exactly what the person saw.
    pub fn toText(self: Prompt, arena: std.mem.Allocator) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(arena);
        try self.writeText(&aw.writer);
        return aw.written();
    }
};

const standard_options = [_]Option{
    .{ .label = "Allow once", .meaning = "The agent does this one thing, this time only.", .outcome = .allow_once },
    .{ .label = "Allow here from now on", .meaning = "The agent does this in this workspace without asking again.", .outcome = .allow_always_here },
    .{ .label = "Cancel", .meaning = "The agent does not do this. It carries on with the rest of its work.", .outcome = .deny },
};

const once_only_options = [_]Option{
    .{ .label = "Allow once", .meaning = "The agent does this one thing, this time only.", .outcome = .allow_once },
    .{ .label = "Cancel", .meaning = "The agent does not do this. It carries on with the rest of its work.", .outcome = .deny },
};

/// Build the prompt for a decision that needs a person.
///
/// The resource must be the concrete thing being acted on — a full path, the
/// command line as it will run, the remote's address rather than its local
/// alias. A reader cannot judge "push to origin" without knowing where origin
/// points.
pub fn build(arena: std.mem.Allocator, decision: Decision, agent_label: []const u8) !Prompt {
    const request = decision.request;
    const subject = request.resource.text();
    const label = if (agent_label.len > 0) agent_label else "The agent";

    const question = try questionFor(arena, request.capability, subject);
    const explanation = try std.fmt.allocPrint(arena, "{s} wants to {s}.", .{ label, try wantsTo(arena, request.capability, subject) });
    const consequence = try consequenceFor(arena, request.capability, subject);
    const reassurance = reassuranceFor(request.capability);

    // A high-consequence capability never offers a standing permission: the
    // person answers each time.
    const options: []const Option = if (request.capability.isHighConsequence() and request.capability != .@"fs.delete")
        &once_only_options
    else
        &standard_options;

    return .{
        .question = question,
        .explanation = explanation,
        .consequence = consequence,
        .reassurance = reassurance,
        .options = options,
        .capability = request.capability,
        .resource = request.resource,
        .policy_id = decision.policy_id,
        .rule_id = decision.rule_id,
    };
}

fn questionFor(arena: std.mem.Allocator, capability: Capability, subject: []const u8) ![]const u8 {
    return switch (capability) {
        .@"process.execute" => std.fmt.allocPrint(arena, "Run {s}?", .{subject}),
        .@"fs.delete" => std.fmt.allocPrint(arena, "Delete {s}?", .{subject}),
        .@"fs.write" => std.fmt.allocPrint(arena, "Change {s}?", .{subject}),
        .@"fs.read" => std.fmt.allocPrint(arena, "Read {s}?", .{subject}),
        .@"network.connect" => std.fmt.allocPrint(arena, "Connect to {s}?", .{subject}),
        .@"network.listen" => std.fmt.allocPrint(arena, "Accept connections on {s}?", .{subject}),
        .@"git.commit" => std.fmt.allocPrint(arena, "Commit the changes in {s}?", .{subject}),
        .@"git.push" => std.fmt.allocPrint(arena, "Send the commits to {s}?", .{subject}),
        .@"credentials.use" => std.fmt.allocPrint(arena, "Use the credential named {s}?", .{subject}),
        .@"credentials.read" => std.fmt.allocPrint(arena, "Read the value of the credential named {s}?", .{subject}),
        .@"mcp.invoke" => std.fmt.allocPrint(arena, "Call the tool {s}?", .{subject}),
        .@"container.start" => std.fmt.allocPrint(arena, "Start the container {s}?", .{subject}),
        .@"remote.execute" => std.fmt.allocPrint(arena, "Run this on {s}?", .{subject}),
        .@"model.infer" => std.fmt.allocPrint(arena, "Send this work to {s}?", .{subject}),
        .@"agent.spawn" => std.fmt.allocPrint(arena, "Start another agent for {s}?", .{subject}),
        .@"knowledge.write" => std.fmt.allocPrint(arena, "Change the saved rules in {s}?", .{subject}),
        .@"process.signal" => std.fmt.allocPrint(arena, "Stop the program {s}?", .{subject}),
        .@"git.read" => std.fmt.allocPrint(arena, "Read the history of {s}?", .{subject}),
    };
}

fn wantsTo(arena: std.mem.Allocator, capability: Capability, subject: []const u8) ![]const u8 {
    return switch (capability) {
        .@"process.execute" => std.fmt.allocPrint(arena, "run {s} on this computer", .{subject}),
        .@"fs.delete" => std.fmt.allocPrint(arena, "delete {s}", .{subject}),
        .@"fs.write" => std.fmt.allocPrint(arena, "change the file {s}", .{subject}),
        .@"fs.read" => std.fmt.allocPrint(arena, "read the file {s}", .{subject}),
        .@"network.connect" => std.fmt.allocPrint(arena, "connect to {s} over the network", .{subject}),
        .@"git.push" => std.fmt.allocPrint(arena, "send your commits to {s}", .{subject}),
        .@"credentials.read", .@"credentials.use" => std.fmt.allocPrint(arena, "use the saved credential {s}", .{subject}),
        else => std.fmt.allocPrint(arena, "{s}", .{capability.explain()}),
    };
}

fn consequenceFor(arena: std.mem.Allocator, capability: Capability, subject: []const u8) !?[]const u8 {
    return switch (capability) {
        .@"fs.delete" => try std.fmt.allocPrint(arena, "This removes {s} and everything inside it. You cannot undo it here.", .{subject}),
        .@"git.push" => "Other people will see these commits.",
        .@"network.connect" => "The content the agent sends leaves this computer.",
        .@"credentials.read" => "The agent will see the secret value.",
        .@"model.infer" => "The files and output in this request leave this computer.",
        .@"remote.execute" => "The program runs on the other computer, with that computer's access.",
        .@"container.start" => "The container runs until you stop it.",
        else => null,
    };
}

fn reassuranceFor(capability: Capability) ?[]const u8 {
    return switch (capability) {
        .@"fs.delete" => "Files that are tracked by git can be restored from the repository.",
        .@"process.execute" => "The program runs with your access, and nothing else.",
        .@"network.connect" => "The agent cannot read your saved credentials under this policy.",
        else => null,
    };
}

/// The record written when a person answers.
pub const Answer = struct {
    outcome: Outcome,
    decided_by: idmod.ActorId,
    decided_at: timeutil.Timestamp,
    note: []const u8 = "",

    pub fn allowsOperation(self: Answer) bool {
        return self.outcome != .deny;
    }
};

const testing = std.testing;
const plain = @import("../language/plain.zig");
const audience = @import("../language/audience.zig");

fn buildTestPrompt(arena: std.mem.Allocator, capability: Capability, resource: Resource) !Prompt {
    var gen: idmod.Generator = .init(201, 1_788_000_000_000);
    const decision: Decision = .{
        .id = gen.next(idmod.DecisionId),
        .request = .{ .capability = capability, .resource = resource },
        .effect = .require_human,
        .rule_id = "ask-before-deleting",
        .policy_id = "repo-write-no-network",
        .reason = "Deleting files cannot be undone, so a person decides.",
        .actor = gen.next(idmod.ActorId),
        .session = gen.next(idmod.SessionId),
        .agent = gen.next(idmod.AgentId),
        .decided_at = try timeutil.Timestamp.parseIso("2026-09-04T20:41:31Z"),
    };
    return build(arena, decision, "The agent");
}

test "the prompt names the operation, the thing and the consequence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prompt = try buildTestPrompt(arena, .@"process.execute", .{ .command = "rm -rf build/" });
    try testing.expectEqualStrings("Run rm -rf build/?", prompt.question);
    try testing.expect(std.mem.indexOf(u8, prompt.explanation, "rm -rf build/") != null);

    const text = try prompt.toText(arena);
    try testing.expect(std.mem.indexOf(u8, text, "Allow once") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Cancel") != null);
}

test "deleting states what is lost and what is not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prompt = try buildTestPrompt(arena, .@"fs.delete", .{ .path = "/home/user/zag/build" });
    try testing.expectEqualStrings("Delete /home/user/zag/build?", prompt.question);
    try testing.expect(std.mem.indexOf(u8, prompt.consequence.?, "cannot undo") != null);
    try testing.expect(prompt.reassurance != null);
}

test "high consequence capabilities do not offer a standing permission" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const push = try buildTestPrompt(arena, .@"git.push", .{ .remote = "git@github.test:org/repo.git" });
    try testing.expectEqual(@as(usize, 2), push.options.len);
    for (push.options) |option| {
        try testing.expect(option.outcome != .allow_always_here);
    }

    const write = try buildTestPrompt(arena, .@"fs.write", .{ .path = "/home/user/zag/src/main.zig" });
    try testing.expectEqual(@as(usize, 3), write.options.len);
}

test "generated prompts pass the product's own plain-language checks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { capability: Capability, resource: Resource }{
        .{ .capability = .@"process.execute", .resource = .{ .command = "rm -rf build/" } },
        .{ .capability = .@"fs.delete", .resource = .{ .path = "/home/user/zag/build" } },
        .{ .capability = .@"network.connect", .resource = .{ .host = "api.example.test" } },
        // A remote is named by its address, not by its local alias: "origin"
        // does not tell the reader where the commits are going.
        .{ .capability = .@"git.push", .resource = .{ .remote = "git@github.test:org/repo.git" } },
    };

    for (cases) |case| {
        const prompt = try buildTestPrompt(arena, case.capability, case.resource);
        const text = try prompt.toText(arena);
        const report = try plain.check(arena, text, .{
            .kind = .permission_prompt,
            .purpose = .decide,
            .audience = audience.operator_under_pressure,
        });
        for (report.findings) |finding| {
            if (finding.severity == .blocking or finding.severity == .major) {
                std.debug.print("prompt for {s}\n{s}\n{s} {s}\n", .{ case.capability.text(), text, finding.rule.code(), finding.message });
            }
            try testing.expect(finding.severity != .blocking);
            try testing.expect(finding.severity != .major);
        }
    }
}

test "every option label starts with the action it performs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prompt = try buildTestPrompt(arena, .@"fs.write", .{ .path = "/home/user/zag/src/main.zig" });
    for (prompt.options) |option| {
        const report = try plain.check(arena, option.label, .{ .kind = .button_label });
        try testing.expect(!report.has(.label_without_action));
        try testing.expect(option.meaning.len > 0);
    }
}
