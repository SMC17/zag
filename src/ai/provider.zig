//! One shape for every model provider.
//!
//! Providers disagree about almost everything at the wire: what a message
//! looks like, where the system prompt goes, whether a tool call is a block in
//! the content or a field beside it, what the end of a turn is called. A
//! workbench that spoke each of those dialects directly would carry that
//! disagreement into the policy engine, the event log and the block list.
//!
//! So there is one shape here, and each connector translates. The rest of the
//! product only ever sees this one.
//!
//! Two things are deliberately *not* in this file. There is no transport: a
//! request is turned into bytes and a response is read from bytes, and who
//! carries them is somebody else's problem, which is what makes every
//! connector testable without a network. And there is no authority: a call to
//! a provider is an action like any other, so it passes the policy engine
//! under `model.infer` and `network.connect` before it is sent.

const std = @import("std");
const hashing = @import("../core/hash.zig");
const netguard = @import("../security/netguard.zig");

pub const Role = enum {
    user,
    assistant,
    /// An operator instruction placed in the conversation rather than in the
    /// system prompt. Only some providers accept one.
    system,
};

/// A piece of a message. Providers that have no notion of blocks are given the
/// text and told about the rest in whatever way they do support.
pub const Block = union(enum) {
    text: []const u8,
    /// The model asked to use a tool.
    tool_use: ToolUse,
    /// The answer to a tool call, going back to the model.
    tool_result: ToolResult,
    /// Reasoning the model chose to show. Never invented by a connector: when
    /// a provider returns no reasoning, there is no block.
    thinking: []const u8,

    pub fn textOf(self: Block) []const u8 {
        return switch (self) {
            .text, .thinking => |t| t,
            .tool_use => |t| t.name,
            .tool_result => |t| t.content,
        };
    }
};

pub const ToolUse = struct {
    /// The provider's identifier for this call, echoed back with the result.
    id: []const u8,
    name: []const u8,
    /// Arguments as JSON text. Kept as text because a connector must not
    /// reinterpret what the model asked for on its way to the policy engine.
    argumentsJson: []const u8,
};

pub const ToolResult = struct {
    toolUseId: []const u8,
    content: []const u8,
    isError: bool = false,
};

pub const Message = struct {
    role: Role,
    blocks: []const Block,

    /// Every text block joined, for a provider with no block model.
    pub fn plainText(self: Message, arena: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.blocks) |block| {
            switch (block) {
                .text => |t| try out.appendSlice(arena, t),
                else => {},
            }
        }
        return out.items;
    }
};

/// A tool offered to the model. The schema is JSON Schema text, which the
/// workbench already generates from its own types.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    schemaJson: []const u8,
    /// Ask the provider to guarantee the arguments match the schema, where it
    /// can. A provider that cannot leaves this unused rather than pretending.
    strict: bool = false,
};

/// How hard the model should work. Providers express this differently; a
/// connector maps it or leaves it out.
pub const Effort = enum { low, medium, high, xhigh, max };

pub const Request = struct {
    model: []const u8,
    /// The system prompt. Sent wherever the provider puts it.
    system: []const u8 = "",
    messages: []const Message,
    tools: []const Tool = &.{},
    maxOutputTokens: u32 = 16000,
    /// Left unset for models that reject sampling parameters. A connector must
    /// omit it rather than substitute a default.
    temperature: ?f32 = null,
    effort: ?Effort = null,
    /// Ask for reasoning to be shown, where the provider supports it.
    showThinking: bool = false,
    stream: bool = false,
};

pub const StopReason = enum {
    /// The model finished its turn.
    end_turn,
    /// The model wants a tool to run.
    tool_use,
    /// The output limit was reached. The answer is cut off.
    max_tokens,
    /// The model declined. Not an error: a result with a reason.
    refusal,
    /// A stop sequence matched.
    stop_sequence,
    /// The provider said something this build does not know.
    unknown,

    /// What happened, for a person reading the block list.
    pub fn text(self: StopReason) []const u8 {
        return switch (self) {
            .end_turn => "the model finished",
            .tool_use => "the model asked to use a tool",
            .max_tokens => "the answer reached the output limit and is incomplete",
            .refusal => "the model declined to answer",
            .stop_sequence => "a stop sequence matched",
            .unknown => "the provider gave a reason this build does not know",
        };
    }
};

pub const Usage = struct {
    inputTokens: u64 = 0,
    outputTokens: u64 = 0,
    /// Tokens read from a provider's prompt cache, where it reports them.
    cacheReadTokens: u64 = 0,
    cacheWriteTokens: u64 = 0,

    pub fn total(self: Usage) u64 {
        return self.inputTokens + self.outputTokens;
    }
};

/// What came back.
pub const Completion = struct {
    /// The model that actually answered. Providers may substitute one, and the
    /// record has to say which ran rather than which was asked for.
    model: []const u8,
    blocks: []const Block,
    stopReason: StopReason,
    usage: Usage = .{},
    /// Set when the model declined and the provider said why.
    refusalCategory: ?[]const u8 = null,
    /// The provider's own identifier for this response, for support requests.
    id: []const u8 = "",

    pub fn text(self: Completion, arena: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.blocks) |block| {
            switch (block) {
                .text => |t| try out.appendSlice(arena, t),
                else => {},
            }
        }
        return out.items;
    }

    /// The tool calls the model asked for, in order.
    pub fn toolCalls(self: Completion, arena: std.mem.Allocator) ![]const ToolUse {
        var out: std.ArrayList(ToolUse) = .empty;
        for (self.blocks) |block| {
            switch (block) {
                .tool_use => |t| try out.append(arena, t),
                else => {},
            }
        }
        return out.items;
    }

    /// A hash of the answer, for the provenance record. What the model said is
    /// recorded by address, so the log can prove it later without storing it.
    pub fn contentHash(self: Completion, arena: std.mem.Allocator) !hashing.Hash {
        var parts: std.ArrayList([]const u8) = .empty;
        try parts.append(arena, self.model);
        for (self.blocks) |block| {
            try parts.append(arena, @tagName(block));
            try parts.append(arena, block.textOf());
        }
        return hashing.Hash.ofParts(parts.items);
    }
};

/// A prepared network call: everything a transport needs, and nothing about
/// how to make it.
pub const HttpRequest = struct {
    method: []const u8 = "POST",
    /// Full address, including the scheme.
    url: []const u8,
    headers: []const Header,
    body: []const u8,
    /// The host, split out so the policy engine can decide on it without
    /// parsing a URL.
    host: []const u8,

    pub const Header = struct { name: []const u8, value: []const u8 };
};

pub const DecodeError = error{
    /// The provider's answer was not the shape this connector expects.
    MalformedResponse,
    /// The provider reported an error. `providerErrorText` has what it said.
    ProviderError,
} || std.mem.Allocator.Error || std.json.ParseError(std.json.Scanner);

/// The two halves every connector implements.
pub const Wire = struct {
    /// A short, stable name: `anthropic`, `openai`, `ollama`.
    id: []const u8,
    encode: *const fn (arena: std.mem.Allocator, endpoint: Endpoint, request: Request) anyerror!HttpRequest,
    decode: *const fn (arena: std.mem.Allocator, body: []const u8) anyerror!Completion,
};

/// Where a connector sends, and what it sends to authenticate.
pub const Endpoint = struct {
    /// Base address with no trailing slash: `https://api.anthropic.com`.
    baseUrl: []const u8,
    /// The credential. Never logged, never written to an event.
    apiKey: []const u8 = "",
    /// Extra headers a deployment needs, such as a cloud resource name.
    extraHeaders: []const HttpRequest.Header = &.{},

    /// The host and port of the base address, with no scheme and no path.
    ///
    /// `api.anthropic.com`, `localhost:11434`, `[::1]:8080`. Kept together
    /// because the port is part of what a person writes in a rule, and every
    /// consumer that wants one without the other says so.
    pub fn authority(self: Endpoint) []const u8 {
        var rest = self.baseUrl;
        if (std.mem.indexOf(u8, rest, "://")) |at| rest = rest[at + 3 ..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |at| rest = rest[0..at];
        return rest;
    }

    /// The host part of the base address, for the policy engine.
    ///
    /// Splitting on the first colon was wrong for exactly one shape and it is
    /// the shape a local model uses: `[::1]:8080` came back as `[` and matched
    /// no rule anybody could write. The port rules live in one place and this
    /// calls them.
    pub fn host(self: Endpoint) []const u8 {
        return netguard.hostWithoutPort(self.authority());
    }

    /// The port, or the default for the scheme.
    pub fn port(self: Endpoint) u16 {
        const rest = self.authority();
        const after = if (rest.len > 0 and rest[0] == '[')
            (if (std.mem.indexOfScalar(u8, rest, ']')) |close| rest[close + 1 ..] else "")
        else blk: {
            // A bare IPv6 address is all colons and carries no port.
            var colons: usize = 0;
            for (rest) |byte| {
                if (byte == ':') colons += 1;
            }
            if (colons > 1) break :blk "";
            break :blk if (std.mem.indexOfScalar(u8, rest, ':')) |at| rest[at..] else "";
        };
        if (after.len > 1 and after[0] == ':') {
            if (std.fmt.parseInt(u16, after[1..], 10)) |parsed| return parsed else |_| {}
        }
        return if (std.mem.startsWith(u8, self.baseUrl, "http://")) 80 else 443;
    }

    /// True when the endpoint is on this machine. A local model still passes
    /// the policy engine, but a person deciding about it wants to know that
    /// nothing leaves the computer.
    pub fn isLocal(self: Endpoint) bool {
        const h = self.host();
        return std.mem.eql(u8, h, "localhost") or
            std.mem.eql(u8, h, "127.0.0.1") or
            std.mem.eql(u8, h, "::1") or
            std.mem.eql(u8, h, "0.0.0.0");
    }
};

/// Write a JSON string, escaped. Connectors build their bodies with this
/// rather than by pasting text into a template, because a model's output is
/// arbitrary and a template is how it becomes an injection.
pub fn writeJsonString(w: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, w);
}

const testing = std.testing;

test "an endpoint knows its host and whether it is local" {
    const remote: Endpoint = .{ .baseUrl = "https://api.anthropic.com" };
    try testing.expectEqualStrings("api.anthropic.com", remote.host());
    try testing.expect(!remote.isLocal());

    const local: Endpoint = .{ .baseUrl = "http://localhost:11434" };
    try testing.expectEqualStrings("localhost", local.host());
    try testing.expect(local.isLocal());

    const with_path: Endpoint = .{ .baseUrl = "https://router.example.com/v1" };
    try testing.expectEqualStrings("router.example.com", with_path.host());
}

test "a completion reports its text, its tool calls and its address" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const completion: Completion = .{
        .model = "claude-opus-5",
        .blocks = &.{
            .{ .text = "I will read the file." },
            .{ .tool_use = .{ .id = "toolu_1", .name = "read_file", .argumentsJson = "{\"path\":\"a.txt\"}" } },
        },
        .stopReason = .tool_use,
        .usage = .{ .inputTokens = 12, .outputTokens = 7 },
    };
    try testing.expectEqualStrings("I will read the file.", try completion.text(arena));

    const calls = try completion.toolCalls(arena);
    try testing.expectEqual(@as(usize, 1), calls.len);
    try testing.expectEqualStrings("read_file", calls[0].name);
    try testing.expectEqual(@as(u64, 19), completion.usage.total());

    // The same answer hashes the same way twice, and a different one does not.
    const first = try completion.contentHash(arena);
    const again = try completion.contentHash(arena);
    try testing.expect(first.eql(again));
}

test "every stop reason says what happened in words" {
    inline for (comptime std.meta.fields(StopReason)) |field| {
        const reason: StopReason = @enumFromInt(field.value);
        try testing.expect(reason.text().len > 0);
    }
    try testing.expect(std.mem.indexOf(u8, StopReason.max_tokens.text(), "incomplete") != null);
}

test "a message flattens to text for a provider with no blocks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const message: Message = .{
        .role = .user,
        .blocks = &.{
            .{ .text = "first part. " },
            .{ .tool_result = .{ .toolUseId = "t1", .content = "not text" } },
            .{ .text = "second part." },
        },
    };
    try testing.expectEqualStrings("first part. second part.", try message.plainText(arena));
}
