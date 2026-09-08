//! Typed tool requests.
//!
//! There is no free-form shell tool. Every action an agent can take is a typed
//! request that names exactly one capability and exactly one resource, so the
//! policy engine can decide it, the log can record it, and a person can read it
//! back later and know what happened.
//!
//! The types are also the schema: `zag-audit emit` publishes them as JSON Schema, so
//! a provider, a plugin or another implementation sees the same contract.

const std = @import("std");
const capability_mod = @import("capability.zig");
const timeutil = @import("../core/time.zig");
const hashing = @import("../core/hash.zig");

pub const Capability = capability_mod.Capability;
pub const Resource = capability_mod.Resource;

/// What of the caller's environment a process may see. The default gives a
/// process nothing it was not explicitly given.
pub const EnvironmentPolicy = enum {
    /// Only the variables listed in the request. A command with no `PATH`
    /// cannot start, so this is for a caller that supplies everything itself.
    none,
    /// A curated set taken from the person's environment — enough to find and
    /// run a build tool, and nothing that carries a credential. The request may
    /// name its own variables instead. See `executor.default_environment_allowlist`.
    allowlist,
    /// Everything the workbench itself has. Rarely correct.
    inherit_all,
};

pub const NetworkPolicy = enum {
    /// No network access at all.
    none,
    /// Only the hosts the policy allows.
    allowlist,
    /// Any host. Requires a capability decision of its own.
    any,
};

pub const ApprovalPolicy = enum {
    /// Policy decides; no person is asked.
    policy_only,
    /// Ask a person the first time, then remember for this workspace.
    ask_once,
    /// Ask a person every time.
    ask_every_time,
};

pub const ExecuteRequest = struct {
    /// The program and its arguments, already split. There is no shell here:
    /// a string that gets word-split by a shell is how quoting bugs become
    /// security bugs.
    argv: []const []const u8,
    /// Where to run, relative to the workspace.
    ///
    /// Defaulted, because a model is never told the workspace's absolute path
    /// and cannot invent one. It was required, and the executor ignored it and
    /// ran everything in the workspace root anyway — so the only thing the
    /// field did was refuse tool calls that left it out.
    workingDirectory: []const u8 = ".",
    /// Defaulted to the allowlist rather than to nothing. `.none` means a
    /// command runs with only what it names, and a command with no `PATH`
    /// cannot find the program it is trying to be.
    environmentPolicy: EnvironmentPolicy = .allowlist,
    environment: []const []const u8 = &.{},
    network: NetworkPolicy = .none,
    timeout: timeutil.Duration = .{ .ns = 120 * timeutil.ns_per_s },
    approval: ApprovalPolicy = .policy_only,

    pub fn commandText(self: ExecuteRequest, arena: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.argv, 0..) |arg, i| {
            if (i > 0) try out.append(arena, ' ');
            try out.appendSlice(arena, arg);
        }
        return out.toOwnedSlice(arena);
    }
};

pub const ReadFileRequest = struct {
    path: []const u8,
    /// Read at most this many bytes. A tool that can read an unbounded file can
    /// fill an agent's context with one command.
    maxBytes: usize = 1 << 20,
};

pub const WriteFileRequest = struct {
    path: []const u8,
    /// The bytes to write.
    ///
    /// A model has to be able to say what it wants written. Before this, the
    /// only way to name content was `contentHash`, and nothing a model could
    /// call put content into the store — so a model could read a file and run
    /// a program, and never produce anything. An agent that cannot write a
    /// file cannot build anything.
    ///
    /// When this is set the bytes are stored on the way past, so the record
    /// still addresses what landed by hash and `zag objects` still verifies
    /// it. Leave it empty to write content that is already stored, which is
    /// the path a reviewed write takes: there the bytes that land are exactly
    /// the bytes somebody looked at.
    contents: []const u8 = "",
    contentHash: hashing.Hash = hashing.Hash.zero,
    byteCount: usize = 0,
    createIfMissing: bool = true,
};

pub const DeleteRequest = struct {
    path: []const u8,
    recursive: bool = false,
};

pub const SearchRequest = struct {
    query: []const u8,
    /// Where to search, relative to the workspace. Defaulted for the same
    /// reason as everything else here: a model is never told an absolute path.
    root: []const u8 = ".",
    maxResults: usize = 100,
    /// Search the workspace history rather than the files.
    includeHistory: bool = false,
};

pub const GitOperation = enum { status, log, diff, commit, push, branch, worktree_add };

pub const GitRequest = struct {
    operation: GitOperation,
    /// The repository, relative to the workspace.
    repository: []const u8 = ".",
    /// Commit message, branch name, or remote address, depending on operation.
    argument: []const u8 = "",
};

pub const McpRequest = struct {
    server: []const u8,
    tool: []const u8,
    argumentsJson: []const u8,
};

pub const SpawnAgentRequest = struct {
    label: []const u8,
    request: []const u8,
    /// The policy the new agent runs under. It can never be wider than the
    /// policy of the agent asking.
    policy: []const u8,
};

pub const InferRequest = struct {
    provider: []const u8,
    model: []const u8,
    /// Hash of the prompt, so the log records which prompt without storing it.
    promptHash: hashing.Hash,
    maxOutputTokens: u32 = 4096,
};

/// Everything an agent can ask to do.
pub const ToolRequest = union(enum) {
    execute: ExecuteRequest,
    read_file: ReadFileRequest,
    write_file: WriteFileRequest,
    delete: DeleteRequest,
    search: SearchRequest,
    git: GitRequest,
    mcp: McpRequest,
    spawn_agent: SpawnAgentRequest,
    infer: InferRequest,

    pub fn toolName(self: ToolRequest) []const u8 {
        return @tagName(self);
    }

    /// The one capability this request needs. This mapping is the security
    /// model: a request cannot be executed under a capability it did not ask
    /// for, because the executor takes the capability from here.
    pub fn capability(self: ToolRequest) Capability {
        return switch (self) {
            .execute => .@"process.execute",
            .read_file => .@"fs.read",
            .write_file => .@"fs.write",
            .delete => .@"fs.delete",
            .search => .@"fs.read",
            .git => |g| switch (g.operation) {
                .status, .log, .diff, .branch => .@"git.read",
                .commit => .@"git.commit",
                .push => .@"git.push",
                .worktree_add => .@"fs.write",
            },
            .mcp => .@"mcp.invoke",
            .spawn_agent => .@"agent.spawn",
            .infer => .@"model.infer",
        };
    }

    pub fn resource(self: ToolRequest, arena: std.mem.Allocator) !Resource {
        return switch (self) {
            .execute => |e| .{ .command = try e.commandText(arena) },
            .read_file => |r| .{ .path = r.path },
            .write_file => |w| .{ .path = w.path },
            .delete => |d| .{ .path = d.path },
            .search => |s| .{ .path = s.root },
            .git => |g| switch (g.operation) {
                .push => .{ .remote = g.argument },
                else => .{ .path = g.repository },
            },
            .mcp => |m| .{ .service = m.server },
            .spawn_agent => |s| .{ .service = s.label },
            .infer => |i| .{ .service = i.provider },
        };
    }

    /// A second capability some requests also need. An execute request that is
    /// allowed to use the network needs the network capability too, and asking
    /// for both is the honest way to describe it.
    pub fn additionalCapability(self: ToolRequest) ?Capability {
        return switch (self) {
            .execute => |e| if (e.network == .none) null else .@"network.connect",
            .infer => .@"network.connect",
            .mcp => .@"network.connect",
            else => null,
        };
    }
};

pub const Outcome = enum { completed, failed, denied, cancelled, timed_out };

pub const ToolResult = struct {
    outcome: Outcome,
    /// Hash of whatever the tool produced.
    contentHash: hashing.Hash = hashing.Hash.zero,
    byteCount: usize = 0,
    exitStatus: ?u8 = null,
    duration: timeutil.Duration = .{ .ns = 0 },
    /// One sentence for the person reading the block list later.
    summary: []const u8 = "",
    /// What the tool actually produced, for the model to read.
    ///
    /// Separate from `summary` because they answer different questions. The
    /// summary is for a person scanning a block list — "Read 41 bytes from
    /// README.md" — and the content is the 41 bytes. Without this a model that
    /// asks to read a file is told how big the file was, and an agent asked to
    /// run the tests and fix what failed learns only that the tests exited 1.
    ///
    /// Held in the arena and never written to the log; the log keeps
    /// `contentHash` and `byteCount`, and the bytes go to the content store.
    /// Redacted before it reaches a provider, on the same path as everything
    /// else in a request.
    content: []const u8 = "",

    pub fn succeeded(self: ToolResult) bool {
        return self.outcome == .completed;
    }
};

const testing = std.testing;

test "every request maps to exactly one capability and resource" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const execute: ToolRequest = .{ .execute = .{
        .argv = &.{ "zig", "build", "test" },
        .workingDirectory = "/home/user/zag",
    } };
    try testing.expectEqual(Capability.@"process.execute", execute.capability());
    const resource = try execute.resource(arena);
    try testing.expectEqualStrings("zig build test", resource.command);
    try testing.expect(execute.additionalCapability() == null);

    const push: ToolRequest = .{ .git = .{ .operation = .push, .repository = "/home/user/zag", .argument = "git@example.test:org/zag.git" } };
    try testing.expectEqual(Capability.@"git.push", push.capability());
    try testing.expectEqualStrings("git@example.test:org/zag.git", (try push.resource(arena)).remote);

    const status: ToolRequest = .{ .git = .{ .operation = .status, .repository = "/home/user/zag" } };
    try testing.expectEqual(Capability.@"git.read", status.capability());
}

test "a request that uses the network asks for the network too" {
    const networked: ToolRequest = .{ .execute = .{
        .argv = &.{ "npm", "install" },
        .workingDirectory = "/home/user/zag",
        .network = .allowlist,
    } };
    try testing.expectEqual(Capability.@"network.connect", networked.additionalCapability().?);

    const offline: ToolRequest = .{ .execute = .{ .argv = &.{"zig"}, .workingDirectory = "/tmp" } };
    try testing.expect(offline.additionalCapability() == null);

    const inference: ToolRequest = .{ .infer = .{ .provider = "anthropic", .model = "claude-opus-5", .promptHash = hashing.Hash.of("prompt") } };
    try testing.expectEqual(Capability.@"model.infer", inference.capability());
    try testing.expectEqual(Capability.@"network.connect", inference.additionalCapability().?);
}

test "commands are argument vectors, not strings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A file name with a space stays one argument, which is exactly why the
    // request carries a vector rather than a command line.
    const request: ExecuteRequest = .{
        .argv = &.{ "rm", "my file.txt" },
        .workingDirectory = "/tmp",
    };
    try testing.expectEqual(@as(usize, 2), request.argv.len);
    try testing.expectEqualStrings("rm my file.txt", try request.commandText(arena));
}

test "tool requests publish as json schema" {
    const jsonschema = @import("../interop/jsonschema.zig");
    const gpa = testing.allocator;
    const text = try jsonschema.documentAlloc(ToolRequest, gpa, .{ .title = "Tool request" });
    defer gpa.free(text);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const defs = parsed.value.object.get("$defs").?.object;
    try testing.expect(defs.contains("ToolRequest"));
    try testing.expect(defs.contains("ExecuteRequest"));
    try testing.expect(defs.contains("EnvironmentPolicy"));
    const one_of = defs.get("ToolRequest").?.object.get("oneOf").?.array;
    try testing.expectEqual(@as(usize, 9), one_of.items.len);
}
