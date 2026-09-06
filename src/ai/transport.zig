//! The gate every model request passes through.
//!
//! A connector on its own is an ordinary API client, and there are thousands of
//! those. What makes this one worth having is that no request reaches a
//! provider until the policy engine has decided it, and every decision is a
//! record that outlives the session.
//!
//! One call to a model asks for three separate permissions, and they are asked
//! for separately because a person may reasonably answer them differently:
//!
//!   * `model.infer` on the connector — may this agent use a model at all, and
//!     this one in particular?
//!   * `network.connect` on the host — may bytes leave for that address? A
//!     workspace can allow `localhost` and refuse everything else, and that one
//!     rule is the difference between a local-only setup and an open one.
//!   * `credentials.use` on the variable name — may the stored key be spent on
//!     this? The value is never asked for and never seen here.
//!
//! The order matters. All three are decided **before** anything is encoded, so
//! a refused request never has a body built for it and a refused credential is
//! never copied into a header.
//!
//! The credential itself is handled once, at the last possible moment: it is
//! passed to the connector's encoder, which writes it into a header, and that
//! header is sent. It is never written to the log, never put in a decision,
//! never in an error, and never in the `Attempt` this returns. What the record
//! holds instead is the variable's name and whether it was set.
//!
//! Sending is behind a `Sender` rather than called directly, for two reasons.
//! The tests run the whole gate against recorded answers with no network at
//! all, which is the only way to test a refusal honestly. And a deployment that
//! must route through its own egress proxy can supply one without touching the
//! decision path.

const std = @import("std");
const provider = @import("provider.zig");
const catalog = @import("catalog.zig");
const policy_mod = @import("policy.zig");
const capability_mod = @import("capability.zig");
const tools = @import("tools.zig");
const hashing = @import("../core/hash.zig");

pub const Connector = catalog.Connector;
pub const Decision = policy_mod.Decision;
pub const Capability = capability_mod.Capability;

pub const Error = error{
    /// The policy refused one of the three permissions. `Attempt.refusedAt`
    /// says which.
    NotPermitted,
    /// A person has to decide before this can be sent.
    NeedsApproval,
    /// The connector needs a credential and the variable is empty.
    CredentialMissing,
    /// The provider answered with a status this build treats as a failure.
    ProviderRejected,
    /// The request could not be sent at all.
    SendFailed,
} || std.mem.Allocator.Error;

/// What a person is told when a request does not go out. None of these mention
/// a key, a header or a URL with a credential in it.
pub fn refusalText(err: Error) []const u8 {
    return switch (err) {
        error.NotPermitted => "The policy does not allow this model request.",
        error.NeedsApproval => "This model request is waiting for a person to allow it.",
        error.CredentialMissing => "That provider needs a credential and none is set.",
        error.ProviderRejected => "The provider refused the request.",
        error.SendFailed => "The request could not be sent.",
        error.OutOfMemory => "There was not enough memory to send this.",
    };
}

/// A raw answer from a provider, before it is decoded.
pub const Response = struct {
    status: u16,
    body: []const u8,

    pub fn ok(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }
};

/// Whatever actually puts the bytes on the wire.
///
/// It receives a fully-formed request that has already been allowed. A sender
/// has no say in whether the request goes; by the time it is called, that has
/// been decided and recorded.
pub const Sender = struct {
    context: *anyopaque,
    sendFn: *const fn (
        context: *anyopaque,
        arena: std.mem.Allocator,
        request: provider.HttpRequest,
    ) anyerror!Response,

    pub fn send(
        self: Sender,
        arena: std.mem.Allocator,
        request: provider.HttpRequest,
    ) anyerror!Response {
        return self.sendFn(self.context, arena, request);
    }
};

/// Which of the three permissions was the one that stopped a request.
pub const Stage = enum {
    infer,
    network,
    credential,

    pub fn text(self: Stage) []const u8 {
        return switch (self) {
            .infer => "using a model",
            .network => "reaching the provider over the network",
            .credential => "using the stored credential",
        };
    }
};

/// The record of one attempt, whether or not it was sent.
///
/// This is what a caller writes into the block list and what the log gets. It
/// is complete on a refusal as well as on an answer: a request that was stopped
/// still produced decisions, and those are the interesting ones.
pub const Attempt = struct {
    connector: []const u8,
    model: []const u8,
    host: []const u8,
    /// True when the address is on this computer.
    local: bool,
    /// The decisions made, in the order they were asked for.
    decisions: []const Decision,
    /// Set when the request never went out.
    refusedAt: ?Stage = null,
    /// The prompt's hash. The prompt itself is the caller's to store or not;
    /// the record says which prompt without holding it.
    promptHash: hashing.Hash,
    /// Set once an answer arrived.
    status: ?u16 = null,
    completion: ?provider.Completion = null,
    /// Why the request could not be sent, when it could not be. Written in
    /// words rather than as an error name, because a person reading this is
    /// trying to find out whether the server is running, not to debug a
    /// library.
    sendProblem: []const u8 = "",
    /// What the provider sent back when it refused. Kept so a person can be
    /// told what went wrong rather than only that something did. It is the
    /// provider's own words, never anything this build put in the request, so
    /// showing it cannot leak a credential.
    providerError: []const u8 = "",

    pub fn sent(self: Attempt) bool {
        return self.status != null;
    }

    /// One line for a person reading the session later.
    pub fn summary(self: Attempt, arena: std.mem.Allocator) ![]const u8 {
        if (self.refusedAt) |stage| {
            return std.fmt.allocPrint(
                arena,
                "Not sent to {s}: the policy refused {s}.",
                .{ self.connector, stage.text() },
            );
        }
        const completion = self.completion orelse return std.fmt.allocPrint(
            arena,
            "Sent to {s}, which answered with status {d}.",
            .{ self.connector, self.status orelse 0 },
        );
        return std.fmt.allocPrint(
            arena,
            "{s} answered with {s}, {s}: {s}.",
            .{
                self.connector,
                if (completion.model.len > 0) completion.model else self.model,
                if (self.local) "on this computer" else "over the network",
                completion.stopReason.text(),
            },
        );
    }
};

/// Reads a credential by variable name.
///
/// A transport is given one of these rather than reading the environment
/// itself, so that the library never touches the process environment and a
/// deployment can hold its keys anywhere: a keychain, an agent, a vault.
pub const Credentials = struct {
    context: *anyopaque,
    lookupFn: *const fn (context: *anyopaque, variable: []const u8) ?[]const u8,

    pub fn lookup(self: Credentials, variable: []const u8) ?[]const u8 {
        return self.lookupFn(self.context, variable);
    }

    /// Whether a variable is set, without reading its value. This is what the
    /// connector list is allowed to ask.
    pub fn isSet(self: Credentials, variable: []const u8) bool {
        return self.lookup(variable) != null;
    }
};

/// Nothing is available. The default, so that a transport built without
/// credentials refuses a hosted provider rather than sending an empty key.
pub const no_credentials: Credentials = .{
    .context = undefined,
    .lookupFn = struct {
        fn lookup(_: *anyopaque, _: []const u8) ?[]const u8 {
            return null;
        }
    }.lookup,
};

pub const Transport = struct {
    arena: std.mem.Allocator,
    engine: *policy_mod.Engine,
    sender: Sender,
    credentials: Credentials = no_credentials,

    /// Decide, then send.
    ///
    /// Every path through this function that reaches the sender has three
    /// allowed decisions behind it, and every path that does not returns them
    /// anyway through `attempt`.
    pub fn send(
        self: Transport,
        connector: Connector,
        request: provider.Request,
        context: policy_mod.Context,
        attempt: *Attempt,
    ) Error!provider.Completion {
        var decisions: std.ArrayList(Decision) = .empty;
        const key_variable = connector.keyVariable;

        attempt.* = .{
            .connector = connector.id,
            .model = request.model,
            .host = connector.endpoint("").host(),
            .local = connector.locality == .local,
            .decisions = &.{},
            .promptHash = hashPrompt(request),
        };

        // 1. May a model be used at all, and this connector in particular?
        const infer = try self.decide(&decisions, .{
            .capability = .@"model.infer",
            .resource = .{ .service = connector.id },
        }, context);
        attempt.decisions = decisions.items;
        if (!infer.isAllowed()) {
            attempt.refusedAt = .infer;
            return stopped(infer);
        }

        // 2. May bytes leave for that address? A local model still asks, so
        //    that the log says a connection was made either way.
        const network = try self.decide(&decisions, .{
            .capability = .@"network.connect",
            .resource = .{ .host = attempt.host },
        }, context);
        attempt.decisions = decisions.items;
        if (!network.isAllowed()) {
            attempt.refusedAt = .network;
            return stopped(network);
        }

        // 3. May the stored credential be spent here? Asked before it is read,
        //    so a refusal never touches the value.
        var api_key: []const u8 = "";
        if (connector.needsCredential()) {
            const use = try self.decide(&decisions, .{
                .capability = .@"credentials.use",
                .resource = .{ .credential = key_variable },
            }, context);
            attempt.decisions = decisions.items;
            if (!use.isAllowed()) {
                attempt.refusedAt = .credential;
                return stopped(use);
            }
            api_key = self.credentials.lookup(key_variable) orelse {
                attempt.refusedAt = .credential;
                return error.CredentialMissing;
            };
        }

        const wire = connector.wire();
        const http = wire.encode(self.arena, connector.endpoint(api_key), request) catch {
            return error.SendFailed;
        };
        const response = self.sender.send(self.arena, http) catch |err| {
            attempt.sendProblem = sendProblemText(err, connector.locality == .local);
            return error.SendFailed;
        };
        attempt.status = response.status;

        if (!response.ok()) {
            attempt.providerError = messageIn(response.body);
            return error.ProviderRejected;
        }

        const completion = wire.decode(self.arena, response.body) catch {
            return error.ProviderRejected;
        };
        attempt.completion = completion;
        return completion;
    }

    /// The typed request this attempt corresponds to, for the tool log. It is
    /// built from the same values the decisions were made on, so the record and
    /// the decision cannot drift apart.
    pub fn toolRequest(attempt: Attempt) tools.ToolRequest {
        return .{ .infer = .{
            .provider = attempt.connector,
            .model = attempt.model,
            .promptHash = attempt.promptHash,
        } };
    }

    fn decide(
        self: Transport,
        into: *std.ArrayList(Decision),
        request: capability_mod.Request,
        context: policy_mod.Context,
    ) Error!Decision {
        const decision = self.engine.decide(request, context) catch return error.OutOfMemory;
        try into.append(self.arena, decision);
        return decision;
    }

    fn stopped(decision: Decision) Error {
        return switch (decision.effect) {
            .require_human => error.NeedsApproval,
            else => error.NotPermitted,
        };
    }
};

/// Say why a request never reached the provider.
///
/// The distinction that matters to a person is between "nothing is listening
/// there" — usually a local server they have not started — and "the network
/// would not carry it", so those are separated and everything else is left
/// honestly vague rather than guessed at.
pub fn sendProblemText(err: anyerror, local: bool) []const u8 {
    return switch (err) {
        error.ConnectionRefused => if (local)
            "Nothing is listening at that address. The model server may not be running."
        else
            "The provider refused the connection.",
        error.ConnectionTimedOut, error.Timeout => "The provider did not answer in time.",
        error.UnknownHostName, error.NameServerFailure, error.TemporaryNameServerFailure => "That address could not be looked up.",
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => "The secure connection could not be set up.",
        error.NetworkUnreachable => "There is no route to that address from here.",
        else => "",
    };
}

/// Pull the human-readable part out of an error body.
///
/// Every one of the five shapes puts its explanation under `message`
/// somewhere, so that one field is looked for rather than five shapes being
/// parsed. When it is not there the body is shown as it came, trimmed, because
/// an unexplained status is worse than an ugly line.
pub fn messageIn(body: []const u8) []const u8 {
    const key = "\"message\":";
    var search = body;
    while (std.mem.indexOf(u8, search, key)) |at| {
        var rest = search[at + key.len ..];
        rest = std.mem.trimStart(u8, rest, " \t\r\n");
        if (rest.len > 0 and rest[0] == '"') {
            const text = rest[1..];
            var index: usize = 0;
            while (index < text.len) : (index += 1) {
                if (text[index] == '\\') {
                    index += 1;
                    continue;
                }
                if (text[index] == '"') return text[0..index];
            }
        }
        search = rest;
    }
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    return if (trimmed.len > 400) trimmed[0..400] else trimmed;
}

/// Hash the prompt so the record names it without holding it.
///
/// The system prompt and every message's text go in, in order. Two different
/// conversations cannot collide into one hash, and the same conversation twice
/// gives the same hash, which is what makes a repeated request visible in the
/// log.
pub fn hashPrompt(request: provider.Request) hashing.Hash {
    var accumulated = hashing.Hash.of(request.model);
    accumulated = hashing.Hash.chain(accumulated, hashing.Hash.of(request.system));
    for (request.messages) |message| {
        accumulated = hashing.Hash.chain(accumulated, hashing.Hash.of(@tagName(message.role)));
        for (message.blocks) |block| {
            const piece = switch (block) {
                .text, .thinking => |text| hashing.Hash.of(text),
                .tool_use => |call| hashing.Hash.ofParts(&.{ call.name, call.argumentsJson }),
                .tool_result => |result| hashing.Hash.ofParts(&.{ result.toolUseId, result.content }),
            };
            accumulated = hashing.Hash.chain(accumulated, piece);
        }
    }
    return accumulated;
}

/// Sends over HTTP, using the standard library's client.
///
/// This is the only part of the file that touches a socket, and it is reached
/// only after the gate above has allowed the request three times.
pub const Http = struct {
    client: *std.http.Client,
    /// Answers larger than this are refused rather than held. A provider that
    /// returns something enormous is a problem to notice, not to absorb.
    limit: usize = 16 << 20,

    pub fn sender(self: *Http) Sender {
        return .{ .context = self, .sendFn = sendHttp };
    }

    fn sendHttp(
        context: *anyopaque,
        arena: std.mem.Allocator,
        request: provider.HttpRequest,
    ) anyerror!Response {
        const self: *Http = @ptrCast(@alignCast(context));

        var extra: std.ArrayList(std.http.Header) = .empty;
        var content_type: []const u8 = "application/json";
        for (request.headers) |header| {
            // The client writes this one itself from `headers.content_type`.
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                content_type = header.value;
                continue;
            }
            try extra.append(arena, .{ .name = header.name, .value = header.value });
        }

        var body: std.Io.Writer.Allocating = .init(arena);
        const result = try self.client.fetch(.{
            .location = .{ .url = request.url },
            .method = .POST,
            .payload = request.body,
            .headers = .{ .content_type = .{ .override = content_type } },
            .extra_headers = extra.items,
            // A credential is in those headers, so a redirect is never
            // followed. The policy allowed one host; following a redirect
            // would spend the credential on a host nobody decided about.
            .redirect_behavior = .unhandled,
            .response_writer = &body.writer,
        });

        return .{ .status = @intFromEnum(result.status), .body = body.written() };
    }
};

/// A sender that answers from a script instead of a network, for tests and for
/// showing a workspace what a provider would return.
pub const Recorded = struct {
    responses: []const Response,
    /// Every request that was handed over, in order. A test asserts on this to
    /// prove that a refused request never reached here at all.
    seen: std.ArrayList(provider.HttpRequest) = .empty,
    arena: std.mem.Allocator,
    index: usize = 0,

    pub fn sender(self: *Recorded) Sender {
        return .{ .context = self, .sendFn = sendRecorded };
    }

    fn sendRecorded(
        context: *anyopaque,
        _: std.mem.Allocator,
        request: provider.HttpRequest,
    ) anyerror!Response {
        const self: *Recorded = @ptrCast(@alignCast(context));
        try self.seen.append(self.arena, request);
        if (self.index >= self.responses.len) return error.NoRecordedResponse;
        defer self.index += 1;
        return self.responses[self.index];
    }
};

const testing = std.testing;
const idmod = @import("../core/id.zig");
const timeutil = @import("../core/time.zig");

const answer =
    \\{"id":"msg_1","model":"claude-opus-5","role":"assistant",
    \\ "content":[{"type":"text","text":"Four."}],
    \\ "stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":2}}
;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    engine: policy_mod.Engine,
    recorded: Recorded,

    fn init(rules: []const policy_mod.Rule, responses: []const Response) !*Fixture {
        const self = try testing.allocator.create(Fixture);
        self.* = .{
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .engine = undefined,
            .recorded = undefined,
        };
        const scratch = self.arena_state.allocator();
        self.engine = policy_mod.Engine.init(scratch, .{
            .id = "test",
            .name = "Test policy",
            .description = "Whatever the test needs.",
            .rules = rules,
        }, 7);
        self.recorded = .{ .responses = responses, .arena = scratch };
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.arena_state.deinit();
        testing.allocator.destroy(self);
    }

    fn arena(self: *Fixture) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn transport(self: *Fixture, credentials: Credentials) Transport {
        return .{
            .arena = self.arena(),
            .engine = &self.engine,
            .sender = self.recorded.sender(),
            .credentials = credentials,
        };
    }

    fn context(self: *Fixture) policy_mod.Context {
        var ids = idmod.Generator.init(11, 0);
        _ = self;
        return .{
            .actor = ids.next(idmod.ActorId),
            .session = ids.next(idmod.SessionId),
            .agent = ids.next(idmod.AgentId),
            .now = .{ .ns = 1_700_000_000 * timeutil.ns_per_s },
        };
    }
};

fn oneKey(_: *anyopaque, variable: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, variable, "ANTHROPIC_API_KEY")) return "sk-secret-value";
    return null;
}

const with_key: Credentials = .{ .context = undefined, .lookupFn = oneKey };

fn ask() provider.Request {
    return .{
        .model = "claude-opus-5",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "Two plus two?" }} }},
    };
}

const allow_everything = [_]policy_mod.Rule{.{
    .id = "allow-all",
    .capabilities = &.{ .@"model.infer", .@"network.connect", .@"credentials.use" },
    .effect = .allow,
    .reason = "This workspace allows model requests.",
}};

test "an allowed request is sent, and the answer comes back decoded" {
    const fixture = try Fixture.init(&allow_everything, &.{.{ .status = 200, .body = answer }});
    defer fixture.deinit();

    var attempt: Attempt = undefined;
    const transport = fixture.transport(with_key);
    const completion = try transport.send(
        catalog.find("anthropic").?,
        ask(),
        fixture.context(),
        &attempt,
    );

    try testing.expectEqualStrings("Four.", try completion.text(fixture.arena()));
    try testing.expect(attempt.sent());
    try testing.expectEqual(@as(u16, 200), attempt.status.?);
    // Three permissions, three decisions, all recorded.
    try testing.expectEqual(@as(usize, 3), attempt.decisions.len);
    try testing.expectEqual(Capability.@"model.infer", attempt.decisions[0].request.capability);
    try testing.expectEqual(Capability.@"network.connect", attempt.decisions[1].request.capability);
    try testing.expectEqual(Capability.@"credentials.use", attempt.decisions[2].request.capability);
    try testing.expectEqual(@as(usize, 1), fixture.recorded.seen.items.len);
}

test "a refused model request never reaches the network" {
    const rules = [_]policy_mod.Rule{.{
        .id = "no-models",
        .capabilities = &.{.@"model.infer"},
        .effect = .deny,
        .reason = "This workspace does not use models.",
    }};
    const fixture = try Fixture.init(&rules, &.{.{ .status = 200, .body = answer }});
    defer fixture.deinit();

    var attempt: Attempt = undefined;
    const transport = fixture.transport(with_key);
    try testing.expectError(error.NotPermitted, transport.send(
        catalog.find("anthropic").?,
        ask(),
        fixture.context(),
        &attempt,
    ));

    // Nothing was encoded and nothing was sent. This is the assertion the
    // whole file exists for.
    try testing.expectEqual(@as(usize, 0), fixture.recorded.seen.items.len);
    try testing.expectEqual(Stage.infer, attempt.refusedAt.?);
    try testing.expect(!attempt.sent());
    // The one decision that was reached is still on the record.
    try testing.expectEqual(@as(usize, 1), attempt.decisions.len);
}

test "a workspace can allow models on this computer and refuse the rest" {
    const rules = [_]policy_mod.Rule{
        .{
            .id = "models-allowed",
            .capabilities = &.{.@"model.infer"},
            .effect = .allow,
            .reason = "Models are allowed here.",
        },
        .{
            .id = "local-only",
            .capabilities = &.{.@"network.connect"},
            .scope = .{ .hosts = &.{"localhost"} },
            .effect = .allow,
            .reason = "Only models on this computer may be reached.",
        },
    };
    const fixture = try Fixture.init(&rules, &.{.{
        .status = 200,
        .body =
        \\{"model":"llama3.2","message":{"role":"assistant","content":"Four."},
        \\ "done":true,"done_reason":"stop"}
        ,
    }});
    defer fixture.deinit();

    const transport = fixture.transport(no_credentials);

    // The hosted one is stopped at the network, after being allowed a model.
    var hosted: Attempt = undefined;
    try testing.expectError(error.NotPermitted, transport.send(
        catalog.find("anthropic").?,
        ask(),
        fixture.context(),
        &hosted,
    ));
    try testing.expectEqual(Stage.network, hosted.refusedAt.?);
    try testing.expectEqual(@as(usize, 0), fixture.recorded.seen.items.len);

    // The local one goes, and needs no credential to do it.
    var local: Attempt = undefined;
    const completion = try transport.send(
        catalog.find("ollama").?,
        .{
            .model = "llama3.2",
            .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "Two plus two?" }} }},
        },
        fixture.context(),
        &local,
    );
    try testing.expectEqualStrings("Four.", try completion.text(fixture.arena()));
    try testing.expect(local.local);
    try testing.expectEqual(@as(usize, 1), fixture.recorded.seen.items.len);
    try testing.expectEqualStrings("localhost", fixture.recorded.seen.items[0].host);
}

test "a request waiting for a person is not sent while it waits" {
    const rules = [_]policy_mod.Rule{.{
        .id = "ask-first",
        .capabilities = &.{ .@"model.infer", .@"network.connect", .@"credentials.use" },
        .effect = .require_human,
        .reason = "A person allows each model request here.",
    }};
    const fixture = try Fixture.init(&rules, &.{.{ .status = 200, .body = answer }});
    defer fixture.deinit();

    var attempt: Attempt = undefined;
    const transport = fixture.transport(with_key);
    try testing.expectError(error.NeedsApproval, transport.send(
        catalog.find("anthropic").?,
        ask(),
        fixture.context(),
        &attempt,
    ));
    try testing.expectEqual(@as(usize, 0), fixture.recorded.seen.items.len);
}

test "the credential is spent on the wire and appears nowhere else" {
    const fixture = try Fixture.init(&allow_everything, &.{.{ .status = 200, .body = answer }});
    defer fixture.deinit();

    var attempt: Attempt = undefined;
    const transport = fixture.transport(with_key);
    _ = try transport.send(catalog.find("anthropic").?, ask(), fixture.context(), &attempt);

    const sent = fixture.recorded.seen.items[0];
    var carried = false;
    for (sent.headers) |header| {
        if (std.mem.eql(u8, header.value, "sk-secret-value")) carried = true;
    }
    try testing.expect(carried);

    // It is not in the address, not in the body, and not in any decision.
    try testing.expect(std.mem.indexOf(u8, sent.url, "sk-secret") == null);
    try testing.expect(std.mem.indexOf(u8, sent.body, "sk-secret") == null);
    for (attempt.decisions) |decision| {
        try testing.expect(std.mem.indexOf(u8, decision.request.resource.text(), "sk-secret") == null);
        try testing.expect(std.mem.indexOf(u8, decision.reason, "sk-secret") == null);
    }
    // The record names the variable, which is the part a person needs.
    try testing.expectEqualStrings("ANTHROPIC_API_KEY", attempt.decisions[2].request.resource.text());

    const line = try attempt.summary(fixture.arena());
    try testing.expect(std.mem.indexOf(u8, line, "sk-secret") == null);
}

test "a missing credential is reported rather than sent as an empty one" {
    const fixture = try Fixture.init(&allow_everything, &.{.{ .status = 200, .body = answer }});
    defer fixture.deinit();

    var attempt: Attempt = undefined;
    const transport = fixture.transport(no_credentials);
    try testing.expectError(error.CredentialMissing, transport.send(
        catalog.find("openai").?,
        ask(),
        fixture.context(),
        &attempt,
    ));
    try testing.expectEqual(@as(usize, 0), fixture.recorded.seen.items.len);
    try testing.expectEqual(Stage.credential, attempt.refusedAt.?);
}

test "a provider's error status is not read as an answer" {
    const fixture = try Fixture.init(&allow_everything, &.{.{
        .status = 401,
        .body =
        \\{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
        ,
    }});
    defer fixture.deinit();

    var attempt: Attempt = undefined;
    const transport = fixture.transport(with_key);
    try testing.expectError(error.ProviderRejected, transport.send(
        catalog.find("anthropic").?,
        ask(),
        fixture.context(),
        &attempt,
    ));
    try testing.expectEqual(@as(u16, 401), attempt.status.?);
    try testing.expect(attempt.completion == null);
    // A person is told what the provider said, not only that it said no.
    try testing.expectEqualStrings("invalid x-api-key", attempt.providerError);
}

test "an error message is found in every shape, and an unexplained one is shown as it came" {
    try testing.expectEqualStrings("invalid x-api-key", messageIn(
        \\{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
    ));
    try testing.expectEqualStrings("Incorrect API key provided", messageIn(
        \\{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}
    ));
    try testing.expectEqualStrings("API key not valid", messageIn(
        \\{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}
    ));
    // Nothing recognisable: the body itself, rather than silence.
    try testing.expectEqualStrings("Service Unavailable", messageIn("  Service Unavailable\n"));
}

test "the same prompt hashes the same way and a different one does not" {
    const first = hashPrompt(ask());
    const again = hashPrompt(ask());
    try testing.expect(first.eql(again));

    const other = hashPrompt(.{
        .model = "claude-opus-5",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "Three plus three?" }} }},
    });
    try testing.expect(!first.eql(other));

    // The model is part of it: the same question to a different model is a
    // different request.
    const elsewhere = hashPrompt(.{
        .model = "llama3.2",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "Two plus two?" }} }},
    });
    try testing.expect(!first.eql(elsewhere));
}

test "an attempt describes itself in words a person can read" {
    const fixture = try Fixture.init(&allow_everything, &.{.{ .status = 200, .body = answer }});
    defer fixture.deinit();

    var attempt: Attempt = undefined;
    const transport = fixture.transport(with_key);
    _ = try transport.send(catalog.find("anthropic").?, ask(), fixture.context(), &attempt);

    const line = try attempt.summary(fixture.arena());
    try testing.expect(std.mem.indexOf(u8, line, "anthropic") != null);
    try testing.expect(std.mem.indexOf(u8, line, "over the network") != null);

    // The typed request built from the attempt asks for the capability the
    // decisions were made under, so the log and the gate cannot disagree.
    const request = Transport.toolRequest(attempt);
    try testing.expectEqual(Capability.@"model.infer", request.capability());
    try testing.expectEqual(Capability.@"network.connect", request.additionalCapability().?);
    try testing.expectEqualStrings("anthropic", request.infer.provider);
}
