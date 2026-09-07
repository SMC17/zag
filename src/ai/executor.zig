//! Executors: the place where a decision becomes an action, or does not.
//!
//! Every other part of the security model is preparation for this file. An
//! agent asks for one capability on one resource; the policy engine decides;
//! and here the decision is *spent*. An executor takes the decision it was
//! given together with the request, and refuses unless the two match.
//!
//! Three rules make the boundary real rather than architectural:
//!
//!   * **A decision authorises one request.** The executor re-derives the
//!     capability and the resource from the request and compares them with the
//!     decision. A decision to read `notes.md` cannot be spent on `/etc/shadow`,
//!     even by the code holding it, because the mismatch is checked here and
//!     not at the call site.
//!   * **No string is re-interpreted.** A command arrives as an argument
//!     vector and is executed directly. There is no shell, so there is nothing
//!     for a quotation mark to escape into. The executor never joins the
//!     vector back into a line.
//!   * **Files are opened beneath the workspace by the kernel.** Paths go
//!     through `sandbox`, which uses `RESOLVE_BENEATH`. A symbolic link that
//!     leaves the workspace is refused by the same component that would
//!     otherwise follow it.
//!
//! What an executor never does is decide. It has no policy, no allowlist of
//! its own and no opinion. Handed a decision that says deny, it performs
//! nothing and reports that it was denied.

const std = @import("std");
const tools = @import("tools.zig");
const policy_mod = @import("policy.zig");
const capability_mod = @import("capability.zig");
const sandbox = @import("sandbox.zig");
const pty_mod = @import("../terminal/pty.zig");
const content_store_mod = @import("../events/content_store.zig");
const hashing = @import("../core/hash.zig");
const timeutil = @import("../core/time.zig");

pub const ToolRequest = tools.ToolRequest;
pub const ToolResult = tools.ToolResult;
pub const Decision = policy_mod.Decision;
pub const Capability = capability_mod.Capability;
pub const Resource = capability_mod.Resource;

pub const Error = error{
    /// The decision does not authorise this request. Either the capability or
    /// the resource is different from the one that was decided.
    DecisionDoesNotMatchRequest,
    /// The decision refused, or is waiting for a person.
    NotAllowed,
    /// This build has no executor for that request.
    NoExecutor,
    /// The program asked for has a typed request of its own, and must be asked
    /// for that way so the right capability is decided.
    UseTheTypedRequest,
    /// An agent asked to run a shell, which would put back the thing this
    /// design removed.
    NoShellForAgents,
    /// The kernel cannot enforce containment on this machine.
    ContainmentUnavailable,
} || std.mem.Allocator.Error;

/// Why a request was refused before it ran, in words for the block list.
pub fn refusalText(err: Error) []const u8 {
    return switch (err) {
        error.DecisionDoesNotMatchRequest => "The permission that was granted does not cover what was asked for.",
        error.NotAllowed => "The policy did not allow this.",
        error.NoExecutor => "This build cannot perform that kind of request.",
        error.UseTheTypedRequest => "That program has a request of its own. Ask for that instead, so the right permission is decided.",
        error.NoShellForAgents => "An agent may not run a shell here. Ask for the program itself, with its arguments already separated.",
        error.ContainmentUnavailable => "This computer cannot keep file access inside the workspace, so the request was refused.",
        error.OutOfMemory => "There was not enough memory to run this.",
    };
}

/// The resource a request acts on.
///
/// There is one definition of this, in `tools.ToolRequest.resource`, and this
/// file deliberately does not have a second one. It used to: a copy here
/// narrowed an execute request to its program name and collapsed a git push to
/// a path, so a decision made by the policy engine on `git push origin main`
/// could never authorise the request it was made for. Two definitions of what a
/// request touches is two security models, and the one that is easier to
/// satisfy wins by accident.
///
/// This is the function that makes a decision unforgeable in practice: the
/// executor asks the request what it touches, rather than believing what the
/// caller said when the decision was made.
pub fn resourceOf(arena: std.mem.Allocator, request: ToolRequest) !Resource {
    return request.resource(arena);
}

/// The program a request runs, without its directory.
pub fn programOf(request: tools.ExecuteRequest) []const u8 {
    if (request.argv.len == 0) return "";
    const first = request.argv[0];
    return if (std.mem.lastIndexOfScalar(u8, first, '/')) |slash| first[slash + 1 ..] else first;
}

/// The typed request that should have been used instead of running a program.
///
/// This is the hole it closes. Deleting a file is `fs.delete`, and a workspace
/// that refuses `fs.delete` is saying something a person means. But an agent
/// could reach the same outcome by running `rm`, which is `process.execute` and
/// a completely different decision — so the typed refusal was the one that
/// could not run, and the way around it was the one that could.
///
/// Refusing here rather than in the policy is deliberate: a policy is written
/// by a person and can be written badly, and this is a property of the request
/// model itself. It only affects agents. A person running `zag run -- rm x` is
/// running a command they typed, which never passes through this file.
pub fn typedEquivalentOf(request: tools.ExecuteRequest) ?[]const u8 {
    const program = programOf(request);
    const pairs = [_]struct { program: []const u8, typed: []const u8 }{
        .{ .program = "rm", .typed = "delete" },
        .{ .program = "rmdir", .typed = "delete" },
        .{ .program = "unlink", .typed = "delete" },
        .{ .program = "git", .typed = "git" },
    };
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.program, program)) return pair.typed;
    }
    return null;
}

/// Is this program a shell?
///
/// "There is no shell" is a property this design claims, and an agent running
/// `sh -c` puts one back: everything the argument vector was protecting is then
/// parsed by something else. So an agent may not run one.
///
/// This is a list of names, and a list of names is never complete — a program
/// copied to another name, or an interpreter nobody thought of, is not here.
/// What actually bounds this is the policy's own allowlist of commands, which
/// is written by a person for their own workspace. This stops the obvious path
/// and does not pretend to be a boundary on its own.
pub fn isShell(program: []const u8) bool {
    const shells = [_][]const u8{
        "sh",   "bash",  "zsh",    "dash",    "fish",   "ksh",
        "csh",  "tcsh",  "ash",    "busybox", "pwsh",   "powershell",
        "env",  "xargs", "nice",   "sudo",    "doas",   "ssh",
        "eval", "exec",  "script", "nohup",   "setsid", "stdbuf",
    };
    for (shells) |name| {
        if (std.mem.eql(u8, name, program)) return true;
    }
    return false;
}

/// True when `decision` authorises exactly `request`.
///
/// Both halves are compared. A decision carrying the right capability for the
/// wrong path is not a permission to act on that path, and the difference
/// between those two is the whole of the security model.
pub fn authorises(arena: std.mem.Allocator, decision: Decision, request: ToolRequest) !bool {
    if (!decision.isAllowed()) return false;
    if (decision.request.capability != request.capability()) return false;
    const wanted = try request.resource(arena);
    return sameResource(decision.request.resource, wanted);
}

fn sameResource(a: Resource, b: Resource) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return std.mem.eql(u8, a.text(), b.text());
}

pub const Options = struct {
    /// The workspace root. Every file the executors touch is opened beneath it.
    root: []const u8,
    /// How long a process may run.
    timeout: timeutil.Duration = .{ .ns = 120 * timeutil.ns_per_s },
    /// Bytes of output kept from one process.
    outputLimit: usize = 8 << 20,
    /// Where a write request's content comes from. An agent stages bytes in
    /// the store and then asks for them to be written by their address, so the
    /// executor never invents content and the bytes that landed are the bytes
    /// that were reviewed.
    content: ?*content_store_mod.Store = null,
    io: ?std.Io = null,
};

/// Performs typed requests, one decision at a time.
pub const Runner = struct {
    arena: std.mem.Allocator,
    options: Options,

    pub fn init(arena: std.mem.Allocator, options: Options) Runner {
        return .{ .arena = arena, .options = options };
    }

    /// Spend a decision on a request.
    ///
    /// The order matters and is deliberate: the decision is checked against
    /// the request before anything is opened, started or sent.
    pub fn run(self: Runner, decision: Decision, request: ToolRequest) Error!ToolResult {
        if (!decision.isAllowed()) return error.NotAllowed;
        if (!try authorises(self.arena, decision, request)) return error.DecisionDoesNotMatchRequest;

        return switch (request) {
            .read_file => |r| self.readFile(r),
            .write_file => |w| self.writeFile(w),
            .execute => |e| blk: {
                if (typedEquivalentOf(e)) |_| break :blk error.UseTheTypedRequest;
                if (isShell(programOf(e))) break :blk error.NoShellForAgents;
                break :blk self.execute(e);
            },
            // The remaining request kinds have no executor in this build. They
            // are named rather than silently treated as failures, because
            // "not built" and "did not work" are different things.
            .delete, .search, .git, .mcp, .spawn_agent, .infer => error.NoExecutor,
        };
    }

    fn openRoot(self: Runner, buffer: []u8) Error!sandbox.Root {
        return sandbox.Root.open(self.options.root, buffer) catch |err| switch (err) {
            error.ContainmentUnavailable => error.ContainmentUnavailable,
            else => error.NoExecutor,
        };
    }

    fn readFile(self: Runner, request: tools.ReadFileRequest) Error!ToolResult {
        var root_buffer: [4096]u8 = undefined;
        const root = try self.openRoot(&root_buffer);
        defer root.close();

        const bytes = root.readFile(self.arena, request.path, self.options.outputLimit) catch |err| {
            return failure(self.arena, err);
        };
        return .{
            .outcome = .completed,
            .contentHash = hashing.Hash.of(bytes),
            .byteCount = bytes.len,
            .summary = try std.fmt.allocPrint(self.arena, "Read {d} bytes from {s}.", .{ bytes.len, request.path }),
        };
    }

    fn writeFile(self: Runner, request: tools.WriteFileRequest) Error!ToolResult {
        const store = self.options.content orelse return error.NoExecutor;
        const io = self.options.io orelse return error.NoExecutor;
        const bytes = store.read(io, request.contentHash, self.options.outputLimit) catch {
            return .{
                .outcome = .failed,
                .summary = "The content to write is not in the store, so nothing was written.",
            };
        };

        var root_buffer: [4096]u8 = undefined;
        const root = try self.openRoot(&root_buffer);
        defer root.close();

        root.writeFile(request.path, bytes) catch |err| {
            return failure(self.arena, err);
        };
        return .{
            .outcome = .completed,
            .contentHash = request.contentHash,
            .byteCount = bytes.len,
            .summary = try std.fmt.allocPrint(self.arena, "Wrote {d} bytes to {s}.", .{ bytes.len, request.path }),
        };
    }

    /// Run a program.
    ///
    /// The argument vector is passed through as it arrived. It is never joined
    /// into a line and handed to a shell, which is how a file name containing
    /// a semicolon turns into a second command.
    fn execute(self: Runner, request: tools.ExecuteRequest) Error!ToolResult {
        if (request.argv.len == 0) return error.NoExecutor;

        if (comptime !pty_mod.supported) return error.NoExecutor;

        var pty = pty_mod.Pty.open(.{ .columns = 120, .rows = 40 }) catch {
            return .{ .outcome = .failed, .summary = "A pseudoterminal could not be opened for this program." };
        };
        defer pty.close();

        const argv = pty_mod.buildArgv(self.arena, request.argv) catch return error.OutOfMemory;
        const envp = pty_mod.buildEnvp(self.arena, request.environment) catch return error.OutOfMemory;
        const path_z = self.arena.dupeZ(u8, request.argv[0]) catch return error.OutOfMemory;
        const cwd_z = self.arena.dupeZ(u8, self.options.root) catch return error.OutOfMemory;

        var child = pty.spawn(path_z.ptr, argv.ptr, envp.ptr, cwd_z.ptr) catch {
            return .{
                .outcome = .failed,
                .summary = try std.fmt.allocPrint(self.arena, "{s} could not be started.", .{request.argv[0]}),
            };
        };

        var output: std.ArrayList(u8) = .empty;
        var buffer: [16 * 1024]u8 = undefined;
        const deadline_ms = @max(self.options.timeout.millis(), 100);
        var waited: i64 = 0;
        var timed_out = false;
        while (true) {
            if (pty.waitReadable(50)) {
                const n = pty.read(&buffer) catch 0;
                if (n == 0) break;
                if (output.items.len < self.options.outputLimit) {
                    const room = self.options.outputLimit - output.items.len;
                    try output.appendSlice(self.arena, buffer[0..@min(n, room)]);
                }
                continue;
            }
            waited += 50;
            if (child.poll() != null) break;
            if (waited >= deadline_ms) {
                child.signalGroup(15);
                timed_out = true;
                break;
            }
        }

        const exit = child.wait();
        const status = exit.status();
        return .{
            .outcome = if (timed_out) .timed_out else if (status != null and status.? == 0) .completed else .failed,
            .contentHash = hashing.Hash.of(output.items),
            .byteCount = output.items.len,
            .exitStatus = status,
            .summary = if (timed_out)
                try std.fmt.allocPrint(self.arena, "{s} reached its deadline and was stopped.", .{request.argv[0]})
            else
                try std.fmt.allocPrint(self.arena, "{s} finished with status {?d}.", .{ request.argv[0], status }),
        };
    }

    fn failure(arena: std.mem.Allocator, err: anyerror) ToolResult {
        const message = switch (err) {
            error.EscapesWorkspace => "The path led outside the workspace, so it was refused.",
            error.NotFound => "There is no such file in the workspace.",
            error.AccessDenied => "The workspace does not allow that file to be opened.",
            error.IsDirectory => "That path is a directory, not a file.",
            error.ContainmentUnavailable => "This computer cannot keep file access inside the workspace.",
            else => "The file could not be read or written.",
        };
        _ = arena;
        return .{ .outcome = .failed, .summary = message };
    }
};

const testing = std.testing;
const idmod = @import("../core/id.zig");

fn decisionFor(capability: Capability, resource: Resource, effect: policy_mod.Effect) Decision {
    var gen: idmod.Generator = .init(11, 1_788_000_000_000);
    return .{
        .id = gen.next(idmod.DecisionId),
        .request = .{ .capability = capability, .resource = resource },
        .effect = effect,
        .rule_id = null,
        .policy_id = "test",
        .reason = "for the test",
        .actor = gen.next(idmod.ActorId),
        .session = null,
        .agent = null,
        .decided_at = .{ .ns = 0 },
    };
}

test "a decision authorises the one request it names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const request: ToolRequest = .{ .read_file = .{ .path = "notes.md", .maxBytes = 1 << 20 } };
    const good = decisionFor(.@"fs.read", .{ .path = "notes.md" }, .allow);
    try testing.expect(try authorises(arena, good, request));

    // The right capability for a different file is not a permission for this
    // file. This is the case that turns a policy into a decoration.
    const other_path = decisionFor(.@"fs.read", .{ .path = "/etc/shadow" }, .allow);
    try testing.expect(!try authorises(arena, other_path, request));

    // The right file under a different capability is not a permission either.
    const other_capability = decisionFor(.@"fs.write", .{ .path = "notes.md" }, .allow);
    try testing.expect(!try authorises(arena, other_capability, request));

    // A decision that refused authorises nothing.
    const denied = decisionFor(.@"fs.read", .{ .path = "notes.md" }, .deny);
    try testing.expect(!try authorises(arena, denied, request));

    // So does one that is still waiting for a person.
    const waiting = decisionFor(.@"fs.read", .{ .path = "notes.md" }, .require_human);
    try testing.expect(!try authorises(arena, waiting, request));

    // An execute request is identified by the whole command line, because that
    // is what the policy engine decides on. A definition that used only the
    // program name would let a decision about `git status` authorise
    // `git push`.
    const build: ToolRequest = .{ .execute = .{
        .argv = &.{ "zig", "build", "test" },
        .workingDirectory = "/repo",
    } };
    const for_build = decisionFor(.@"process.execute", .{ .command = "zig build test" }, .allow);
    try testing.expect(try authorises(arena, for_build, build));

    const for_zig_alone = decisionFor(.@"process.execute", .{ .command = "zig" }, .allow);
    try testing.expect(!try authorises(arena, for_zig_alone, build));

    // A push is decided on its remote, not on the repository it came from.
    const push: ToolRequest = .{ .git = .{
        .operation = .push,
        .repository = "/repo",
        .argument = "git@example.test:org/zag.git",
    } };
    const for_remote = decisionFor(.@"git.push", .{ .remote = "git@example.test:org/zag.git" }, .allow);
    try testing.expect(try authorises(arena, for_remote, push));

    const for_repository = decisionFor(.@"git.push", .{ .path = "/repo" }, .allow);
    try testing.expect(!try authorises(arena, for_repository, push));
}

test "the resource comes from the request, not from the caller" {
    // Whatever a decision says, the executor asks the request what it touches.
    const request: ToolRequest = .{ .write_file = .{
        .path = "src/main.zig",
        .contentHash = hashing.Hash.of("hello"),
        .byteCount = 5,
    } };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const resource = try resourceOf(arena_state.allocator(), request);
    try testing.expectEqualStrings("src/main.zig", resource.text());
    try testing.expectEqual(Capability.@"fs.write", request.capability());
}

test "an executor refuses a decision that does not match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const runner = Runner.init(arena, .{ .root = "." });
    const request: ToolRequest = .{ .read_file = .{ .path = "README.md", .maxBytes = 1 << 20 } };
    const wrong = decisionFor(.@"fs.read", .{ .path = "somewhere-else.md" }, .allow);
    try testing.expectError(error.DecisionDoesNotMatchRequest, runner.run(wrong, request));

    const denied = decisionFor(.@"fs.read", .{ .path = "README.md" }, .deny);
    try testing.expectError(error.NotAllowed, runner.run(denied, request));
}

test "reading and writing stay beneath the workspace" {
    if (comptime !sandbox.supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // The bytes are staged in the content store and asked for by address, so
    // the executor writes what was reviewed rather than what it was told.
    var store = content_store_mod.Store.init(arena, root);
    const staged = try store.put("written by the executor");
    try store.flush(io);
    const runner = Runner.init(arena, .{ .root = root, .content = &store, .io = io });

    const write: ToolRequest = .{ .write_file = .{
        .path = "kept.txt",
        .contentHash = staged,
        .byteCount = 23,
    } };
    const write_decision = decisionFor(.@"fs.write", .{ .path = "kept.txt" }, .allow);
    const written = runner.run(write_decision, write) catch |err| switch (err) {
        error.ContainmentUnavailable => return error.SkipZigTest,
        else => return err,
    };
    try testing.expect(written.succeeded());

    const read: ToolRequest = .{ .read_file = .{ .path = "kept.txt", .maxBytes = 1 << 20 } };
    const read_decision = decisionFor(.@"fs.read", .{ .path = "kept.txt" }, .allow);
    const got = try runner.run(read_decision, read);
    try testing.expect(got.succeeded());
    try testing.expectEqual(@as(usize, 23), got.byteCount);
    try testing.expect(got.contentHash.eql(staged));

    // A decision that names the escaping path is still refused, because the
    // kernel refuses it. The policy and the filesystem agree.
    const escape: ToolRequest = .{ .read_file = .{ .path = "../../../etc/passwd", .maxBytes = 1 << 20 } };
    const escape_decision = decisionFor(.@"fs.read", .{ .path = "../../../etc/passwd" }, .allow);
    const refused = try runner.run(escape_decision, escape);
    try testing.expect(!refused.succeeded());
    try testing.expect(std.mem.indexOf(u8, refused.summary, "outside the workspace") != null);
}

test "a command runs from its argument vector, with no shell in between" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const runner = Runner.init(arena, .{ .root = "." });

    // The argument contains a semicolon and a redirect. Under a shell this
    // would be three commands; here it is one argument to `echo`.
    const argv = [_][]const u8{ "/bin/echo", "one; rm -rf /; echo two > /tmp/zag-should-not-exist" };
    const request: ToolRequest = .{ .execute = .{
        .argv = &argv,
        .workingDirectory = ".",
    } };
    // The decision names the whole command line, because that is what the
    // policy engine decides on and what the executor re-derives.
    const decision = decisionFor(.@"process.execute", .{
        .command = "/bin/echo one; rm -rf /; echo two > /tmp/zag-should-not-exist",
    }, .allow);
    const result = try runner.run(decision, request);
    try testing.expect(result.succeeded());

    // The redirect never happened, because nothing parsed it.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const leaked = std.Io.Dir.cwd().readFileAlloc(threaded.io(), "/tmp/zag-should-not-exist", arena, .limited(64));
    try testing.expectError(error.FileNotFound, leaked);
}

test "every refusal has a sentence a person can act on" {
    inline for (comptime std.meta.fields(Error)) |field| {
        const err = @field(Error, field.name);
        const text = refusalText(err);
        try testing.expect(text.len > 0);
        try testing.expect(text[text.len - 1] == '.');
    }
}

test "a program with a typed request of its own cannot be run instead" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();
    const runner = Runner.init(scratch, .{ .root = "." });

    // This is the hole. A workspace that refuses `fs.delete` means it. Running
    // `rm` reaches the same outcome under `process.execute`, which is a
    // different decision, so the typed refusal was the one that could not run
    // and the way around it was the one that could.
    const by_program: ToolRequest = .{ .execute = .{
        .argv = &.{ "rm", "-rf", "build" },
        .workingDirectory = ".",
    } };
    const allowed = decisionFor(.@"process.execute", .{ .command = "rm -rf build" }, .allow);
    try testing.expectError(error.UseTheTypedRequest, runner.run(allowed, by_program));

    // Including by its full path, because the check is on the program and not
    // on the text somebody wrote.
    const by_path: ToolRequest = .{ .execute = .{
        .argv = &.{ "/usr/bin/rm", "build" },
        .workingDirectory = ".",
    } };
    const path_allowed = decisionFor(.@"process.execute", .{ .command = "/usr/bin/rm build" }, .allow);
    try testing.expectError(error.UseTheTypedRequest, runner.run(path_allowed, by_path));

    // Git the same way: pushing is `git.push`, and it is not reachable by
    // running the program under a permission to run programs.
    try testing.expect(typedEquivalentOf(.{ .argv = &.{ "git", "push" }, .workingDirectory = "." }) != null);
    try testing.expectEqualStrings("delete", typedEquivalentOf(.{ .argv = &.{"rmdir"}, .workingDirectory = "." }).?);

    // A program that has no typed equivalent is unaffected.
    try testing.expect(typedEquivalentOf(.{ .argv = &.{ "zig", "build" }, .workingDirectory = "." }) == null);
}

test "an agent may not run a shell" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();
    const runner = Runner.init(scratch, .{ .root = "." });

    // "There is no shell" is a property this design claims. An agent running
    // `sh -c` puts one back, and everything the argument vector protects is
    // then parsed by something else.
    const request: ToolRequest = .{ .execute = .{
        .argv = &.{ "sh", "-c", "rm -rf / ; echo done" },
        .workingDirectory = ".",
    } };
    const allowed = decisionFor(.@"process.execute", .{ .command = "sh -c rm -rf / ; echo done" }, .allow);
    try testing.expectError(error.NoShellForAgents, runner.run(allowed, request));

    for ([_][]const u8{ "bash", "zsh", "fish", "env", "xargs", "sudo", "ssh" }) |name| {
        try testing.expect(isShell(name));
    }
    // A person running a shell from the command line never reaches this file:
    // `zag run` records a command a person typed and does not go through an
    // executor.
    try testing.expect(!isShell("zig"));
    try testing.expect(!isShell("cargo"));
}
