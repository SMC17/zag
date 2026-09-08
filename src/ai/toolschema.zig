//! What a model is told it can do, and how what it asks for becomes typed.
//!
//! This file is the narrowest point in the whole system. Everything a model
//! wants to happen arrives here as a name and a blob of JSON, and leaves as a
//! `tools.ToolRequest` or as nothing at all. There is no third outcome and no
//! passthrough: a name that is not in the table is refused, and a request whose
//! arguments do not fit the type is refused, before any policy is consulted and
//! long before anything runs.
//!
//! Two properties are worth stating plainly, because they are the reason this
//! file exists rather than the parsing being done wherever a tool call lands.
//!
//! **The declarations are generated from the Zig types.** The schema a model
//! sees is written by `jsonschema.writeInline` from the same struct the
//! executor takes. A field added to `ExecuteRequest` appears in the schema on
//! the next build. There is no second copy of the shape to fall out of step
//! with the first, and a test asserts every field of every request type appears
//! in what is sent.
//!
//! **A model cannot name a capability.** The capability comes from the request
//! kind, through `ToolRequest.capability()`, which this file does not touch. A
//! model that writes `"capability": "fs.write"` into its arguments is writing a
//! field that does not exist, and the request is refused for that reason. This
//! is the property that makes prompt injection a nuisance here rather than an
//! escalation: text can make a model *ask* for anything, and asking is all it
//! can do.
//!
//! Two request kinds are deliberately absent from what a model is offered.
//! `infer` would let a model spend the workspace's credential on a request
//! nobody read, and `spawn_agent` would let it widen its own reach by creating
//! something to act for it. Both exist as typed requests, for a person to make.

const std = @import("std");
const tools = @import("tools.zig");
const executor = @import("executor.zig");
const provider = @import("provider.zig");
const jsonschema = @import("../interop/jsonschema.zig");
const hashing = @import("../core/hash.zig");
const timeutil = @import("../core/time.zig");

pub const ToolRequest = tools.ToolRequest;

pub const Error = error{
    /// The model named a tool that this build does not offer.
    UnknownTool,
    /// The arguments were not JSON, or not an object.
    MalformedArguments,
    /// A field the request needs was missing, or was the wrong type.
    ArgumentsDoNotFit,
    /// The tool exists as a typed request but is not offered to a model.
    NotOfferedToModels,
} || std.mem.Allocator.Error;

/// What a person is told when a tool call does not become a request.
pub fn refusalText(err: Error) []const u8 {
    return switch (err) {
        error.UnknownTool => "The model asked for a tool this build does not have.",
        error.MalformedArguments => "The model's tool call was not readable, so nothing ran.",
        error.ArgumentsDoNotFit => "The model's tool call left out something the tool needs, or gave it the wrong type. The tool's own description says which fields it takes.",
        error.NotOfferedToModels => "That tool is for a person to use, not a model.",
        error.OutOfMemory => "There was not enough memory to read the tool call.",
    };
}

/// One offered tool: the name a model uses and the type behind it.
pub const Offer = struct {
    name: []const u8,
    /// Written for the model, in the same plain words a person would get.
    description: []const u8,
    /// The `ToolRequest` variant this becomes.
    kind: std.meta.Tag(ToolRequest),
};

/// Every tool a model may ask for, in the order a person would read them.
///
/// `infer` and `spawn_agent` are not here, and their absence is enforced by a
/// test rather than left to whoever edits this list next.
/// The tools a model is told about.
///
/// Only what the executor can actually perform. `call_mcp_tool` was
/// offered here with nothing behind it, so a model that reached for
/// either spent a turn to be told this build "cannot perform that kind of
/// request" — which is a promise broken at the worst moment, after the model
/// has already decided what to do. Offering a tool is a claim that it works.
pub const offers = [_]Offer{
    .{
        .name = "read_file",
        .kind = .read_file,
        .description = "Read a file in the workspace. The path is relative to the workspace, and a path that leaves it is refused.",
    },
    .{
        .name = "write_file",
        .kind = .write_file,
        .description = "Write a file in the workspace. Put the text in \"contents\". The path is relative to the workspace, and a path that leaves it is refused.",
    },
    .{
        .name = "run_command",
        .kind = .execute,
        .description = "Run a program. Give the program and its arguments already separated. There is no shell, so a semicolon or a redirect is an argument and not an instruction.",
    },
    .{
        .name = "delete",
        .kind = .delete,
        .description = "Delete a file or an empty directory in the workspace. This cannot be undone from the record, so it usually asks a person first. A directory tree is not removed in one step.",
    },
    .{
        .name = "search",
        .kind = .search,
        .description = "Search the workspace for text, or search the recorded history of earlier work.",
    },
    .{
        .name = "git",
        .kind = .git,
        .description = "Read or change the repository: status, log, diff, branch, commit, push, or add a worktree. Each one is decided separately.",
    },
};

/// The type behind one offer, as a comptime value.
///
/// This is what keeps the schema and the executor from drifting: both come from
/// the same type, chosen here once.
pub fn Payload(comptime kind: std.meta.Tag(ToolRequest)) type {
    for (@typeInfo(ToolRequest).@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, @tagName(kind))) return field.type;
    }
    @compileError("no payload for " ++ @tagName(kind));
}

pub fn find(name: []const u8) ?Offer {
    for (offers) |offer| {
        if (std.mem.eql(u8, offer.name, name)) return offer;
    }
    return null;
}

/// The name a model uses for a request kind, when there is one.
pub fn nameOf(kind: std.meta.Tag(ToolRequest)) ?[]const u8 {
    for (offers) |offer| {
        if (offer.kind == kind) return offer.name;
    }
    return null;
}

/// The declarations to put on the wire.
///
/// Every schema is written inline, with nothing referenced, because a provider
/// has no document to resolve a reference against.
pub fn declarations(arena: std.mem.Allocator) ![]const provider.Tool {
    var out: std.ArrayList(provider.Tool) = .empty;
    inline for (offers) |offer| {
        var schema: std.Io.Writer.Allocating = .init(arena);
        try jsonschema.writeInline(Payload(offer.kind), &schema.writer);
        try out.append(arena, .{
            .name = offer.name,
            .description = offer.description,
            .schemaJson = schema.written(),
            // A provider that can hold a model to the schema should. It costs
            // nothing here and removes a whole class of malformed call.
            .strict = true,
        });
    }
    return out.items;
}

/// Turn one tool call into a typed request, or refuse it.
///
/// Nothing here trusts the name to match the arguments. The name selects the
/// type; the arguments must then fit that type or the call is refused.
pub fn parse(
    arena: std.mem.Allocator,
    name: []const u8,
    argumentsJson: []const u8,
) Error!ToolRequest {
    const offer = find(name) orelse {
        // Named but withheld reads differently from never existing, and a
        // person reading the record deserves the difference.
        if (std.mem.eql(u8, name, "infer") or std.mem.eql(u8, name, "spawn_agent")) {
            return error.NotOfferedToModels;
        }
        return error.UnknownTool;
    };

    const text = if (argumentsJson.len == 0) "{}" else argumentsJson;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch {
        return error.MalformedArguments;
    };
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return error.MalformedArguments,
    };

    switch (offer.kind) {
        .read_file => return .{ .read_file = .{
            .path = try requiredString(object, "path"),
            .maxBytes = optionalUsize(object, "maxBytes") orelse 1 << 20,
        } },
        .write_file => {
            // Either the bytes, or the address of bytes already stored. A
            // model can produce the first and cannot compute the second, so
            // requiring the hash made the tool impossible to call.
            const contents = optionalString(object, "contents") orelse "";
            const hash_text = optionalString(object, "contentHash") orelse "";
            if (contents.len == 0 and hash_text.len == 0) return error.ArgumentsDoNotFit;
            return .{ .write_file = .{
                .path = try requiredString(object, "path"),
                .contents = contents,
                .contentHash = if (hash_text.len > 0)
                    hashing.Hash.parse(hash_text) catch return error.ArgumentsDoNotFit
                else
                    hashing.Hash.zero,
                .byteCount = optionalUsize(object, "byteCount") orelse contents.len,
                .createIfMissing = optionalBool(object, "createIfMissing") orelse true,
            } };
        },
        .execute => {
            const argv = try stringArray(arena, object, "argv");
            if (argv.len == 0) return error.ArgumentsDoNotFit;
            return .{ .execute = .{
                .argv = argv,
                .workingDirectory = optionalString(object, "workingDirectory") orelse ".",
                .environmentPolicy = optionalEnum(tools.EnvironmentPolicy, object, "environmentPolicy") orelse default_execute.environmentPolicy,
                .environment = stringArray(arena, object, "environment") catch &.{},
                .network = optionalEnum(tools.NetworkPolicy, object, "network") orelse default_execute.network,
                .timeout = .{ .ns = @as(i64, @intCast(optionalUsize(object, "timeoutSeconds") orelse 120)) * timeutil.ns_per_s },
                .approval = optionalEnum(tools.ApprovalPolicy, object, "approval") orelse default_execute.approval,
            } };
        },
        .delete => return .{ .delete = .{
            .path = try requiredString(object, "path"),
            .recursive = optionalBool(object, "recursive") orelse false,
        } },
        .search => return .{ .search = .{
            .query = try requiredString(object, "query"),
            .root = optionalString(object, "root") orelse ".",
            .maxResults = optionalUsize(object, "maxResults") orelse 100,
            .includeHistory = optionalBool(object, "includeHistory") orelse false,
        } },
        .git => return .{ .git = .{
            .operation = optionalEnum(tools.GitOperation, object, "operation") orelse
                return error.ArgumentsDoNotFit,
            .repository = optionalString(object, "repository") orelse ".",
            .argument = optionalString(object, "argument") orelse "",
        } },
        .mcp => return .{ .mcp = .{
            .server = try requiredString(object, "server"),
            .tool = try requiredString(object, "tool"),
            .argumentsJson = try rawField(arena, object, "argumentsJson"),
        } },
        .infer, .spawn_agent => return error.NotOfferedToModels,
    }
}

fn requiredString(object: std.json.ObjectMap, field: []const u8) Error![]const u8 {
    const value = object.get(field) orelse return error.ArgumentsDoNotFit;
    return switch (value) {
        .string => |s| s,
        else => error.ArgumentsDoNotFit,
    };
}

fn optionalString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn optionalBool(object: std.json.ObjectMap, field: []const u8) ?bool {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn optionalUsize(object: std.json.ObjectMap, field: []const u8) ?usize {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .integer => |i| if (i < 0) null else @intCast(i),
        else => null,
    };
}

fn optionalEnum(comptime T: type, object: std.json.ObjectMap, field: []const u8) ?T {
    const text = optionalString(object, field) orelse return null;
    return std.meta.stringToEnum(T, text);
}

fn stringArray(
    arena: std.mem.Allocator,
    object: std.json.ObjectMap,
    field: []const u8,
) Error![]const []const u8 {
    const value = object.get(field) orelse return error.ArgumentsDoNotFit;
    const items = switch (value) {
        .array => |a| a.items,
        else => return error.ArgumentsDoNotFit,
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        switch (item) {
            .string => |s| try out.append(arena, s),
            else => return error.ArgumentsDoNotFit,
        }
    }
    return out.items;
}

/// A field that is itself JSON, kept as text.
///
/// A model writing arguments for another tool may send them as an object or as
/// a string containing an object. Both are accepted, and both come back as the
/// text that will be forwarded, because the server on the other side is the one
/// that decides what its own arguments mean.
fn rawField(
    arena: std.mem.Allocator,
    object: std.json.ObjectMap,
    field: []const u8,
) Error![]const u8 {
    const value = object.get(field) orelse return "{}";
    if (value == .string) return value.string;
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.MalformedArguments;
    return out.written();
}

/// Write a tool result the way a model reads one.
///
/// A result is a short piece of text, not a structure, because that is what
/// every provider carries. What matters is that a refusal says so in words the
/// model can act on: "you may not" and "it did not work" lead to different next
/// moves, and a model that cannot tell them apart will retry the one it should
/// not.
/// The defaults a run request takes when the model does not name them.
///
/// Read from the type rather than restated, because restating them here is
/// exactly how the type's default and the wire's default came to disagree: the
/// type said `.allowlist` and the decoder said `.none`, so every command a
/// model asked for ran with no environment whatever the type claimed.
const default_execute: tools.ExecuteRequest = .{ .argv = &.{} };

/// The most of one tool's output that is handed back to a model.
///
/// A cap is needed because a single `zig build` can produce megabytes and the
/// model has a context to fit it in. Which end is kept depends on what the
/// content is; see `tools.ContentKind`.
pub const result_content_limit: usize = 24 * 1024;

/// Take a terminal's own control sequences out of captured output.
///
/// The executor runs programs on a pseudoterminal, so what comes back is what a
/// terminal would have drawn: cursor moves, colour changes, synchronised-update
/// brackets, alternate character sets. A model reading `zig build` output was
/// spending about a tenth of its context on those, and they say nothing about
/// the build.
///
/// Only the model's copy is cleaned. The record keeps the bytes the program
/// actually wrote, because that is what happened.
pub fn withoutControlSequences(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, raw.len);

    var at: usize = 0;
    while (at < raw.len) {
        const byte = raw[at];
        if (byte != 0x1b) {
            // Carriage returns are how a progress line overwrites itself. Kept
            // as newlines so the successive states stay readable rather than
            // collapsing into one line of the last thing written.
            if (byte == '\r') {
                if (at + 1 < raw.len and raw[at + 1] == '\n') {
                    at += 1;
                    continue;
                }
                try out.append(arena, '\n');
                at += 1;
                continue;
            }
            try out.append(arena, byte);
            at += 1;
            continue;
        }

        // An escape sequence. Which kind decides where it ends.
        if (at + 1 >= raw.len) break;
        switch (raw[at + 1]) {
            // CSI: parameters and intermediates, then one final byte.
            '[' => {
                var cursor = at + 2;
                while (cursor < raw.len and raw[cursor] >= 0x20 and raw[cursor] <= 0x3f) cursor += 1;
                while (cursor < raw.len and raw[cursor] >= 0x20 and raw[cursor] <= 0x2f) cursor += 1;
                at = if (cursor < raw.len) cursor + 1 else raw.len;
            },
            // OSC: a string, ended by BEL or ST.
            ']' => {
                var cursor = at + 2;
                while (cursor < raw.len) : (cursor += 1) {
                    if (raw[cursor] == 0x07) {
                        cursor += 1;
                        break;
                    }
                    if (raw[cursor] == 0x1b and cursor + 1 < raw.len and raw[cursor + 1] == '\\') {
                        cursor += 2;
                        break;
                    }
                }
                at = cursor;
            },
            // Character set selection: one intermediate, one final byte. This
            // is what draws the box lines in a build summary.
            '(', ')', '*', '+' => at = @min(at + 3, raw.len),
            // Everything else two-byte: keypad modes, index, reset.
            else => at = at + 2,
        }
    }
    return out.items;
}

/// Move a cut to the nearest character boundary, so a slice stays readable text.
///
/// Cutting a byte count out of the middle of a UTF-8 character leaves a
/// fragment that is not text. It reaches the encoder, which replaces it, and a
/// model reads a replacement character for no reason — or, before the encoder
/// was fixed, the whole request went to the provider as an array of numbers.
/// One accented letter or box-drawing character near the cut is enough, so
/// this is the common case for any output that is not plain ASCII.
fn boundaryAtOrBefore(text: []const u8, at: usize) usize {
    var cut = @min(at, text.len);
    // A continuation byte is 10xxxxxx. Walk back off any run of them to the
    // start of the character they belong to.
    while (cut > 0 and (text[cut] & 0xc0) == 0x80) cut -= 1;
    return cut;
}

fn boundaryAtOrAfter(text: []const u8, at: usize) usize {
    var cut = @min(at, text.len);
    while (cut < text.len and (text[cut] & 0xc0) == 0x80) cut += 1;
    return cut;
}

/// What a model is told about one tool call.
///
/// The outcome, the summary sentence, and then what the tool actually
/// produced. The last part is the one that matters: without it a model that
/// asked to read a file learns its size, and an agent told to fix a failing
/// test learns only that something exited non-zero.
pub fn resultText(
    arena: std.mem.Allocator,
    result: tools.ToolResult,
) ![]const u8 {
    const lead = switch (result.outcome) {
        .completed => "Done",
        .failed => "It did not work",
        .denied => "The policy did not allow this. Do not try it again; ask the person instead",
        .cancelled => "This was stopped before it finished",
        .timed_out => "This ran out of time and was stopped",
    };
    const head = if (result.summary.len > 0)
        try std.fmt.allocPrint(arena, "{s}. {s}", .{ lead, result.summary })
    else
        lead;
    if (result.content.len == 0) return head;

    const body = switch (result.contentKind) {
        .text => result.content,
        .terminal_output => try withoutControlSequences(arena, result.content),
    };
    if (body.len <= result_content_limit) {
        return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ head, body });
    }

    // Said in words either way, so a model reading part of something knows it
    // is a part and does not conclude the file was short or the build quiet.
    return switch (result.contentKind) {
        .text => blk: {
            const cut = boundaryAtOrBefore(body, result_content_limit);
            break :blk std.fmt.allocPrint(
                arena,
                "{s}\n\nThe first {d} bytes of {d}, because the whole of it does not fit:\n{s}",
                .{ head, cut, body.len, body[0..cut] },
            );
        },
        .terminal_output => blk: {
            const cut = boundaryAtOrAfter(body, body.len - result_content_limit);
            break :blk std.fmt.allocPrint(
                arena,
                "{s}\n\nThe last {d} bytes of {d}, because the whole of it does not fit:\n{s}",
                .{ head, body.len - cut, body.len, body[cut..] },
            );
        },
    };
}

const testing = std.testing;

test "the declarations carry every field of the type behind them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const declared = try declarations(arena);
    try testing.expectEqual(offers.len, declared.len);

    inline for (offers, 0..) |offer, index| {
        const tool = declared[index];
        try testing.expectEqualStrings(offer.name, tool.name);
        try testing.expect(tool.description.len > 0);

        // Valid JSON, and an object schema.
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, tool.schemaJson, .{});
        try testing.expect(parsed.value == .object);
        try testing.expectEqualStrings("object", parsed.value.object.get("type").?.string);

        // Nothing is referenced: a provider has no document to resolve against.
        try testing.expect(std.mem.indexOf(u8, tool.schemaJson, "$ref") == null);

        // Every field of the Zig type is in the schema, so a field added to the
        // executor's request cannot go unmentioned to the model.
        const properties = parsed.value.object.get("properties").?.object;
        inline for (std.meta.fields(Payload(offer.kind))) |field| {
            if (comptime std.mem.eql(u8, field.name, "timeout")) continue;
            try testing.expect(properties.contains(field.name));
        }
    }
}

test "a model is never offered the tools that would widen its own reach" {
    for (offers) |offer| {
        try testing.expect(offer.kind != .infer);
        try testing.expect(offer.kind != .spawn_agent);
    }
    try testing.expect(nameOf(.infer) == null);
    try testing.expect(nameOf(.spawn_agent) == null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Asking for one by name is refused, and the refusal says which kind of no
    // it is: withheld, not missing.
    try testing.expectError(error.NotOfferedToModels, parse(arena, "infer",
        \\{"provider":"anthropic","model":"claude-opus-5"}
    ));
    try testing.expectError(error.NotOfferedToModels, parse(arena, "spawn_agent", "{}"));
    try testing.expectError(error.UnknownTool, parse(arena, "sudo", "{}"));
}

test "a tool call becomes a typed request, and the capability comes from the kind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const request = try parse(arena, "run_command",
        \\{"argv":["zig","build","test"],"workingDirectory":"/home/user/zag"}
    );
    try testing.expectEqual(tools.Capability.@"process.execute", request.capability());
    try testing.expectEqual(@as(usize, 3), request.execute.argv.len);
    try testing.expectEqualStrings("zig", request.execute.argv[0]);
    // Nothing was said about the network, so it gets none.
    try testing.expectEqual(tools.NetworkPolicy.none, request.execute.network);

    const read = try parse(arena, "read_file",
        \\{"path":"README.md"}
    );
    try testing.expectEqual(tools.Capability.@"fs.read", read.capability());
    try testing.expectEqual(@as(usize, 1 << 20), read.read_file.maxBytes);
}

test "a model cannot name its own capability" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The model tries to say what this is allowed to do. The field does not
    // exist, so it is read as a read of that path and nothing more.
    const request = try parse(arena, "read_file",
        \\{"path":"README.md","capability":"fs.write","allow":true,"policy":"none"}
    );
    try testing.expectEqual(tools.Capability.@"fs.read", request.capability());
    try testing.expectEqualStrings("README.md", request.read_file.path);
}

test "arguments that do not fit are refused before anything is decided" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.ArgumentsDoNotFit, parse(arena, "read_file", "{}"));
    try testing.expectError(error.ArgumentsDoNotFit, parse(arena, "read_file",
        \\{"path":42}
    ));
    // A command with no program to run is not a command.
    try testing.expectError(error.ArgumentsDoNotFit, parse(arena, "run_command",
        \\{"argv":[],"workingDirectory":"/tmp"}
    ));
    // An argument vector must be strings, not a nested structure.
    try testing.expectError(error.ArgumentsDoNotFit, parse(arena, "run_command",
        \\{"argv":["sh",{"x":1}],"workingDirectory":"/tmp"}
    ));
    try testing.expectError(error.MalformedArguments, parse(arena, "read_file", "not json"));
    try testing.expectError(error.MalformedArguments, parse(arena, "read_file", "[1,2,3]"));
    // A hash that is not a hash.
    try testing.expectError(error.ArgumentsDoNotFit, parse(arena, "write_file",
        \\{"path":"a.txt","contentHash":"nonsense"}
    ));
}

test "an unknown enum value falls to the safe default rather than being obeyed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const request = try parse(arena, "run_command",
        \\{"argv":["curl"],"workingDirectory":"/tmp","network":"everything","environmentPolicy":"give_me_it_all"}
    );
    // A name this build does not know is never obeyed. Both fall back to the
    // type's own default, which is the one place either is written down.
    try testing.expectEqual(default_execute.network, request.execute.network);
    try testing.expectEqual(default_execute.environmentPolicy, request.execute.environmentPolicy);

    // And the one that matters for safety is still the closed one: a model
    // cannot talk its way onto the network by naming a policy that sounds
    // permissive.
    try testing.expectEqual(tools.NetworkPolicy.none, request.execute.network);
    // The environment default is open enough to run a build and closed to
    // credentials, which is a different question from the network one.
    try testing.expectEqual(tools.EnvironmentPolicy.allowlist, request.execute.environmentPolicy);
}

test "a tool with no executor behind it is not offered at all" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // There is no MCP client in this build. Offering the tool anyway meant a
    // model spent a turn deciding to call it and was then told the build could
    // not do it — a promise broken after the decision was already made. The
    // request kind stays, because the type is what a client would fill in; it
    // is simply not advertised.
    try testing.expectError(error.UnknownTool, parse(arena, "call_mcp_tool",
        \\{"server":"docs","tool":"lookup","argumentsJson":{"term":"block"}}
    ));

    // Everything that is offered has an executor behind it. This is the claim
    // the offer list makes, so it is the claim under test.
    const declared = try declarations(arena);
    try testing.expectEqual(offers.len, declared.len);
    for (offers) |offer| {
        switch (offer.kind) {
            .read_file, .write_file, .execute, .delete, .search, .git => {},
            .mcp, .spawn_agent, .infer => {
                std.debug.print("{s} is offered and has no executor\n", .{offer.name});
                return error.TestUnexpectedResult;
            },
        }
    }
}

test "a refusal tells the model which kind of no it was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const denied = try resultText(arena, .{ .outcome = .denied, .summary = "The policy did not allow this." });
    try testing.expect(std.mem.indexOf(u8, denied, "Do not try it again") != null);

    const failed = try resultText(arena, .{ .outcome = .failed, .summary = "No such file." });
    try testing.expect(std.mem.indexOf(u8, failed, "did not work") != null);
    // A failure invites another try; a refusal does not. They must not read the
    // same, or a model will retry the one it should leave alone.
    try testing.expect(std.mem.indexOf(u8, failed, "Do not try it again") == null);

    const done = try resultText(arena, .{ .outcome = .completed, .summary = "Read 12 bytes from a.txt." });
    try testing.expect(std.mem.startsWith(u8, done, "Done."));
}

test "a model can call every tool without knowing anything it cannot know" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Each of these was a required field, and each named something a model is
    // never told: the workspace's absolute path, or the hash of bytes it has
    // not stored yet. A tool that cannot be called is not a tool, and the
    // symptom was a refusal that blamed the model for leaving something out.
    const minimal = [_]struct { tool: []const u8, arguments: []const u8 }{
        .{ .tool = "read_file", .arguments =
        \\{"path":"README.md"}
        },
        .{ .tool = "write_file", .arguments =
        \\{"path":"src/main.zig","contents":"hello"}
        },
        .{ .tool = "run_command", .arguments =
        \\{"argv":["zig","build"]}
        },
        .{ .tool = "search", .arguments =
        \\{"query":"countLines"}
        },
        .{ .tool = "git", .arguments =
        \\{"operation":"status"}
        },
    };
    for (minimal) |case| {
        _ = parse(arena, case.tool, case.arguments) catch |err| {
            std.debug.print("{s} could not be called with {s}: {s}\n", .{ case.tool, case.arguments, @errorName(err) });
            return err;
        };
    }
}

test "a run request inherits enough to find a program, and no credential" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The decoder used to hardcode `.none` here while the type said
    // `.allowlist`, so every command a model asked for ran with an empty
    // environment and came back as status 127 with no output — which reads
    // exactly like a build failure and is not one.
    const request = try parse(arena, "run_command",
        \\{"argv":["zig","build","test"]}
    );
    try testing.expectEqual(tools.EnvironmentPolicy.allowlist, request.execute.environmentPolicy);
    try testing.expectEqualStrings(".", request.execute.workingDirectory);

    // The allowlist is the security claim, so it is asserted rather than
    // described: what a build needs is there, and what pays for the model is not.
    const list = executor.default_environment_allowlist;
    var has_path = false;
    var has_home = false;
    for (list) |name| {
        if (std.mem.eql(u8, name, "PATH")) has_path = true;
        if (std.mem.eql(u8, name, "HOME")) has_home = true;
        try testing.expect(std.mem.indexOf(u8, name, "API_KEY") == null);
        try testing.expect(std.mem.indexOf(u8, name, "TOKEN") == null);
        try testing.expect(std.mem.indexOf(u8, name, "SECRET") == null);
        try testing.expect(std.mem.indexOf(u8, name, "PASSWORD") == null);
    }
    try testing.expect(has_path);
    try testing.expect(has_home);
}

test "what a tool produced reaches the model, not just how big it was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The whole reason an agent can do anything. Before this a model that read
    // a file was told its size, and one that ran a failing build was told it
    // exited non-zero, so it could act and never learn.
    const text = try resultText(arena, .{
        .outcome = .failed,
        .summary = "zig finished with status 1.",
        .content = "src/main.zig:4:35: error: expected ';' after statement",
    });
    try testing.expect(std.mem.indexOf(u8, text, "status 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "expected ';' after statement") != null);
}

test "which end of a big result is kept depends on what it is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const big = try arena.alloc(u8, result_content_limit * 2);
    @memset(big, 'x');
    @memcpy(big[0..13], "THE REAL HEAD");
    @memcpy(big[big.len - 12 ..], "THE REAL END");

    // Command output: the end. A compiler prints errors after progress, a test
    // runner prints failures after passes, and the last thing a crashing
    // program writes is why it crashed.
    const output = try resultText(arena, .{
        .outcome = .completed,
        .content = big,
        .contentKind = .terminal_output,
    });
    try testing.expect(std.mem.endsWith(u8, output, "THE REAL END"));
    try testing.expect(std.mem.indexOf(u8, output, "THE REAL HEAD") == null);
    try testing.expect(std.mem.indexOf(u8, output, "does not fit") != null);

    // A file: the beginning. One rule for both got this exactly wrong in the
    // interesting case — a model asked to read a 54 KB source file to
    // understand it was handed the last 24 KB, which was the tests at the
    // bottom.
    const file = try resultText(arena, .{
        .outcome = .completed,
        .content = big,
        .contentKind = .text,
    });
    try testing.expect(std.mem.indexOf(u8, file, "THE REAL HEAD") != null);
    try testing.expect(std.mem.indexOf(u8, file, "THE REAL END") == null);
    try testing.expect(std.mem.indexOf(u8, file, "does not fit") != null);
}

test "a terminal's own control sequences do not reach the model" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Captured verbatim from a real `zig build` run through the executor's
    // pseudoterminal. About a tenth of what the model was reading looked like
    // this, and none of it says anything about the build.
    const raw = "\x1b[?2026h\x1b[J[4/9] steps\n\x1b(0tq\x1b(B run test\n\x1b[31m\x1b[1merror\x1b[0m: expected ';'\n\x1b]9;4;1;44\x1b\\done\n";
    const clean = try withoutControlSequences(arena, raw);

    // What a person would have read stays.
    try testing.expect(std.mem.indexOf(u8, clean, "[4/9] steps") != null);
    try testing.expect(std.mem.indexOf(u8, clean, "run test") != null);
    try testing.expect(std.mem.indexOf(u8, clean, "error: expected ';'") != null);
    try testing.expect(std.mem.indexOf(u8, clean, "done") != null);

    // Nothing that only a terminal understands does.
    try testing.expect(std.mem.indexOfScalar(u8, clean, 0x1b) == null);
    try testing.expect(std.mem.indexOf(u8, clean, "[?2026h") == null);
    try testing.expect(std.mem.indexOf(u8, clean, "[31m") == null);
    try testing.expect(std.mem.indexOf(u8, clean, "9;4;1;44") == null);

    // And it is meaningfully smaller, which is the point.
    try testing.expect(clean.len < raw.len);
}

test "a progress line that overwrites itself keeps every state it showed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A carriage return is how a build redraws one line. Dropping it would
    // fuse the states into one run-on line; treating it as a newline keeps
    // them readable and in order.
    const clean = try withoutControlSequences(arena, "1/3 done\r2/3 done\r3/3 done\n");
    try testing.expect(std.mem.indexOf(u8, clean, "1/3 done\n2/3 done\n3/3 done") != null);

    // A CRLF is one line ending, not two.
    const crlf = try withoutControlSequences(arena, "one\r\ntwo\r\n");
    try testing.expectEqualStrings("one\ntwo\n", crlf);
}

test "a cut lands on a character boundary, from either end" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Box-drawing characters are what a build summary is made of, and each is
    // three bytes. Cutting a byte count out of the middle of one leaves a
    // fragment that is not text: the encoder has to replace it, and before it
    // was fixed the whole request went to the provider as an array of numbers.
    const glyph = "├";
    try testing.expectEqual(@as(usize, 3), glyph.len);

    const repeats = (result_content_limit / glyph.len) + 64;
    var big: std.ArrayList(u8) = .empty;
    for (0..repeats) |_| try big.appendSlice(arena, glyph);

    for ([_]tools.ContentKind{ .text, .terminal_output }) |kind| {
        const text = try resultText(arena, .{ .outcome = .completed, .content = big.items, .contentKind = kind });
        // Whatever was kept is still text, which is the property that matters:
        // it can be written as a JSON string without a replacement character
        // appearing where a real character was.
        try testing.expect(std.unicode.utf8ValidateSlice(text));
        try testing.expect(std.mem.indexOf(u8, text, "does not fit") != null);
        // And it really was cut, or the test is proving nothing.
        try testing.expect(text.len < big.items.len);
    }
}
