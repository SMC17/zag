//! Capabilities: the vocabulary of what an actor may do.
//!
//! A capability is a named permission for one class of operation. Nothing in
//! this system is authorised by a sentence in a prompt. An agent asks for
//! `fs.write` on a path; the policy engine decides; the decision is recorded.
//! That is the difference between a security model and a suggestion.

const std = @import("std");

pub const Capability = enum {
    /// Read a file or list a directory.
    @"fs.read",
    /// Create or change a file.
    @"fs.write",
    /// Delete a file or directory.
    @"fs.delete",
    /// Start a process.
    @"process.execute",
    /// Signal or stop a process.
    @"process.signal",
    /// Open a network connection.
    @"network.connect",
    /// Listen on a port.
    @"network.listen",
    /// Read repository state.
    @"git.read",
    /// Create a commit.
    @"git.commit",
    /// Send commits to a remote.
    @"git.push",
    /// Use a stored credential without seeing it.
    @"credentials.use",
    /// Read a stored credential's value.
    @"credentials.read",
    /// Call a tool on a Model Context Protocol server.
    @"mcp.invoke",
    /// Start a container.
    @"container.start",
    /// Run something on another machine.
    @"remote.execute",
    /// Send a request to a model provider.
    @"model.infer",
    /// Start another agent.
    @"agent.spawn",
    /// Write to the workspace knowledge base.
    @"knowledge.write",

    pub fn text(self: Capability) []const u8 {
        return @tagName(self);
    }

    pub fn parse(name: []const u8) ?Capability {
        return std.meta.stringToEnum(Capability, name);
    }

    /// What this capability lets someone do, written for the person who has to
    /// decide whether to allow it. Never write the enum name in a prompt.
    pub fn explain(self: Capability) []const u8 {
        return switch (self) {
            .@"fs.read" => "read files in this workspace",
            .@"fs.write" => "create and change files in this workspace",
            .@"fs.delete" => "delete files in this workspace",
            .@"process.execute" => "run programs on this computer",
            .@"process.signal" => "stop programs that are running",
            .@"network.connect" => "connect to services over the network",
            .@"network.listen" => "accept network connections on this computer",
            .@"git.read" => "read the repository history and status",
            .@"git.commit" => "record a commit in this repository",
            .@"git.push" => "send commits to the shared repository",
            .@"credentials.use" => "use a saved credential without seeing its value",
            .@"credentials.read" => "read the value of a saved credential",
            .@"mcp.invoke" => "call a tool on a connected server",
            .@"container.start" => "start a container on this computer",
            .@"remote.execute" => "run programs on another computer",
            .@"model.infer" => "send this work to a model provider",
            .@"agent.spawn" => "start another agent",
            .@"knowledge.write" => "change the rules, prompts and workflows saved in this workspace",
        };
    }

    /// Capabilities whose effects reach outside the workspace, or cannot be
    /// undone. These never default to allowed.
    pub fn isHighConsequence(self: Capability) bool {
        return switch (self) {
            .@"fs.delete",
            .@"git.push",
            .@"credentials.read",
            .@"credentials.use",
            .@"network.listen",
            .@"container.start",
            .@"remote.execute",
            .@"agent.spawn",
            => true,
            else => false,
        };
    }

    /// Does using this capability send workspace content to another party?
    /// This drives the data-protection questions in the impact assessment.
    pub fn leavesTheMachine(self: Capability) bool {
        return switch (self) {
            .@"network.connect", .@"git.push", .@"model.infer", .@"remote.execute", .@"mcp.invoke" => true,
            else => false,
        };
    }
};

/// The thing a capability is exercised on.
pub const Resource = union(enum) {
    none,
    /// A filesystem path. Matching is by path prefix, after normalisation.
    path: []const u8,
    /// A command line, as it would be run.
    command: []const u8,
    /// A host name, with an optional port.
    host: []const u8,
    /// A git remote.
    remote: []const u8,
    /// A named credential.
    credential: []const u8,
    /// A named server or tool.
    service: []const u8,

    pub fn text(self: Resource) []const u8 {
        return switch (self) {
            .none => "",
            .path, .command, .host, .remote, .credential, .service => |value| value,
        };
    }

    pub fn kindName(self: Resource) []const u8 {
        return @tagName(self);
    }
};

/// A capability plus the resource it applies to.
pub const Request = struct {
    capability: Capability,
    resource: Resource = .none,

    pub fn writeSentence(self: Request, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.capability.explain());
        switch (self.resource) {
            .none => {},
            .path => |p| try w.print(": {s}", .{p}),
            .command => |c| try w.print(": {s}", .{c}),
            .host => |h| try w.print(": {s}", .{h}),
            .remote => |r| try w.print(": {s}", .{r}),
            .credential => |c| try w.print(": the credential named {s}", .{c}),
            .service => |s| try w.print(": {s}", .{s}),
        }
    }
};

const testing = std.testing;

test "capabilities are named, explained and classified" {
    const write = Capability.parse("fs.write").?;
    try testing.expectEqualStrings("fs.write", write.text());
    try testing.expectEqualStrings("create and change files in this workspace", write.explain());
    try testing.expect(!write.isHighConsequence());
    try testing.expect(Capability.@"git.push".isHighConsequence());
    try testing.expect(Capability.@"model.infer".leavesTheMachine());
    try testing.expect(!Capability.@"fs.read".leavesTheMachine());
    try testing.expect(Capability.parse("fs.teleport") == null);
}

test "a request reads as a sentence a person can answer" {
    const gpa = testing.allocator;
    const request: Request = .{ .capability = .@"process.execute", .resource = .{ .command = "rm -rf build/" } };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try request.writeSentence(&aw.writer);
    try testing.expectEqualStrings("run programs on this computer: rm -rf build/", aw.written());
}

test "every capability has an explanation that avoids its own name" {
    inline for (std.meta.fields(Capability)) |field| {
        const capability: Capability = @enumFromInt(field.value);
        const explanation = capability.explain();
        try testing.expect(explanation.len > 0);
        try testing.expect(std.mem.indexOf(u8, explanation, ".") == null);
        try testing.expect(std.ascii.isLower(explanation[0]));
    }
}
