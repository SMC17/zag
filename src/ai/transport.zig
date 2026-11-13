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
const secrets = @import("../security/secrets.zig");
const netguard = @import("../security/netguard.zig");
const stream_mod = @import("stream.zig");

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
    /// The host was allowed by name, and the addresses it resolves to are not
    /// where that name is supposed to go. `Attempt.addressProblem` says which
    /// address and what is wrong with it.
    AddressRefused,
    /// The provider answered with a status this build treats as a failure.
    ProviderRejected,
    /// The request could not be sent at all.
    SendFailed,
    /// A streaming answer was asked for and this transport cannot read one.
    StreamingUnavailable,
} || std.mem.Allocator.Error;

/// What a person is told when a request does not go out. None of these mention
/// a key, a header or a URL with a credential in it.
pub fn refusalText(err: Error) []const u8 {
    return switch (err) {
        error.NotPermitted => "The policy does not allow this model request.",
        error.NeedsApproval => "This model request is waiting for a person to allow it.",
        error.CredentialMissing => "That provider needs a credential and none is set.",
        error.AddressRefused => "The provider's name does not resolve to where it is supposed to go.",
        error.ProviderRejected => "The provider refused the request.",
        error.SendFailed => "The request could not be sent.",
        error.StreamingUnavailable => "This build cannot read that provider's answer as it arrives.",
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
    /// The host was allowed by name, and the addresses it answers with were
    /// not. A separate stage from `network` because the two fail for opposite
    /// reasons: one is a rule that did not permit the host, the other is a host
    /// that turned out not to be where its name said.
    address,
    credential,

    pub fn text(self: Stage) []const u8 {
        return switch (self) {
            .infer => "using a model",
            .network => "reaching the provider over the network",
            .address => "the address the provider's name resolves to",
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
    /// How many credentials were taken out of the prompt before it was
    /// encoded. Zero is worth recording as such: it is the difference between
    /// "nothing was found" and "nobody looked".
    redactions: usize = 0,
    /// Set when the request never went out.
    refusedAt: ?Stage = null,
    /// Why the addresses were refused, when they were. Written in words, and
    /// naming the address, because "refused" on its own sends somebody to read
    /// the source.
    addressProblem: []const u8 = "",
    /// The prompt's hash. The prompt itself is the caller's to store or not;
    /// the record says which prompt without holding it.
    promptHash: hashing.Hash,
    /// Set once an answer arrived.
    status: ?u16 = null,
    /// How many times the request was put on the wire.
    ///
    /// One normally. More means the provider was busy or unreachable and the
    /// transport tried again, which is worth showing: a run that took four
    /// seconds because it waited out a rate limit did not take four seconds to
    /// think.
    sends: usize = 0,
    /// The status of each try that was not the last, in order. A zero means
    /// nothing came back at all.
    retried: []const u16 = &.{},
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

/// Where the bytes of a streamed answer go as they arrive.
///
/// A `std.Io.Writer` whose drain hands every byte straight to a stream reader
/// and keeps nothing. That is what makes it a stream rather than a slower way
/// of buffering: the HTTP client writes the response body into this, and this
/// forwards it, so no complete copy of the answer exists anywhere.
///
/// The deltas are passed to `on_delta` as they are decoded, which is what lets
/// a caller print an answer while the model is still writing it.
pub const StreamSink = struct {
    writer: std.Io.Writer,
    reader: *stream_mod.Reader,
    on_delta: ?*const fn (context: ?*anyopaque, delta: stream_mod.Delta) anyerror!void = null,
    context: ?*anyopaque = null,
    /// The first failure from the callback or the decoder. A drain cannot
    /// return a typed error, so it is kept here and re-raised by the caller.
    problem: ?anyerror = null,

    /// The sink needs no buffer of its own: everything it is given is forwarded
    /// immediately, so there is nothing to hold.
    pub fn init(reader: *stream_mod.Reader) StreamSink {
        return .{
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
            .reader = reader,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *StreamSink = @alignCast(@fieldParentPtr("writer", w));
        var written: usize = 0;
        for (data, 0..) |slice, index| {
            // The last slice is repeated `splat` times. Almost never more than
            // once here, and getting it wrong would silently drop bytes.
            const times = if (index == data.len - 1) splat else 1;
            var remaining = times;
            while (remaining > 0) : (remaining -= 1) {
                self.take(slice) catch |err| {
                    if (self.problem == null) self.problem = err;
                    return error.WriteFailed;
                };
                written += slice.len;
            }
        }
        return written;
    }

    fn take(self: *StreamSink, chunk: []const u8) !void {
        for (try self.reader.feed(chunk)) |delta| {
            if (self.on_delta) |notify| try notify(self.context, delta);
        }
    }

    /// Tell the reader the connection closed, and deliver what was left.
    pub fn finish(self: *StreamSink) !void {
        for (try self.reader.finish()) |delta| {
            if (self.on_delta) |notify| try notify(self.context, delta);
        }
    }
};

/// Sends a request and writes the answer into a sink as it arrives.
///
/// Separate from `Sender` because the two return different things: one returns
/// a body, and one returns only a status, because the body went somewhere else
/// while it was being read.
pub const StreamingSender = struct {
    context: *anyopaque,
    sendFn: *const fn (
        context: *anyopaque,
        arena: std.mem.Allocator,
        request: provider.HttpRequest,
        sink: *StreamSink,
    ) anyerror!u16,

    pub fn send(
        self: StreamingSender,
        arena: std.mem.Allocator,
        request: provider.HttpRequest,
        sink: *StreamSink,
    ) anyerror!u16 {
        return self.sendFn(self.context, arena, request, sink);
    }
};

/// How a transport waits between tries.
///
/// Injected rather than called directly so a test can assert the schedule
/// without spending eight seconds proving it. The real one sleeps; the one in
/// the tests records what it was asked to wait for and returns.
pub const Waiter = struct {
    context: *anyopaque,
    waitFn: *const fn (context: *anyopaque, nanoseconds: u64) void,

    pub fn wait(self: Waiter, nanoseconds: u64) void {
        self.waitFn(self.context, nanoseconds);
    }
};

/// A waiter that really sleeps.
///
/// The only implementation that costs wall-clock time, and the only one used
/// outside a test.
pub const SleepingWaiter = struct {
    io: std.Io,

    pub fn waiter(self: *SleepingWaiter) Waiter {
        return .{ .context = self, .waitFn = sleep };
    }

    fn sleep(context: *anyopaque, nanoseconds: u64) void {
        const self: *SleepingWaiter = @ptrCast(@alignCast(context));
        // A failure to sleep is not worth failing a request over: the worst it
        // does is try again sooner than intended.
        const duration: std.Io.Clock.Duration = .{
            .raw = .{ .nanoseconds = @intCast(nanoseconds) },
            .clock = .awake,
        };
        duration.sleep(self.io) catch {};
    }
};

/// How many times to try, and how long to wait in between.
///
/// A provider saying 429 or 503 is not an error in the run — it is the normal
/// way a shared service says "not right now". Ending an agent's work because
/// one request arrived during someone else's burst throws away everything done
/// so far for a condition that clears in a second.
pub const Retry = struct {
    /// Total sends, not retries: 1 disables it.
    attempts: usize = 3,
    firstDelay: u64 = 500 * std.time.ns_per_ms,
    maxDelay: u64 = 8 * std.time.ns_per_s,

    /// Whether a status is worth trying again.
    ///
    /// Only the ones that can come out differently. A 400 or a 422 is this
    /// request being wrong and will be wrong the second time; a 401 or a 403
    /// is the credential, and retrying it turns one refusal into three. The
    /// difference matters more than the retry: a client that retries
    /// everything is a client that takes three times as long to tell you your
    /// key is invalid.
    pub fn worthRetrying(status: u16) bool {
        return switch (status) {
            // Timed out, or asked to slow down.
            408, 425, 429 => true,
            // The far side is broken or busy, not the request.
            500, 502, 503, 504, 529 => true,
            else => false,
        };
    }

    /// How long to wait before try number `attempt`, counting from 1.
    ///
    /// Doubling, capped, with jitter taken from the prompt's own hash. Jitter
    /// matters because a fleet of agents that all back off by exactly 500 ms
    /// re-collide at 500 ms; taking it from the hash keeps it spread across
    /// requests while staying identical for the same request, so a replay of a
    /// recorded run waits exactly as the original did.
    pub fn delayFor(self: Retry, attempt: usize, seed: hashing.Hash) u64 {
        if (attempt == 0) return 0;
        // Doubled by multiplying rather than shifting, so a large attempt
        // number saturates at the cap instead of shifting the delay to zero.
        var base = self.firstDelay;
        var doublings = @min(attempt - 1, 32);
        while (doublings > 0) : (doublings -= 1) {
            if (base >= self.maxDelay) break;
            base *|= 2;
        }
        base = @min(base, self.maxDelay);
        // Up to a quarter more, never less: waiting slightly longer is always
        // safe, and waiting less than asked defeats the point.
        const spread = base / 4;
        if (spread == 0) return base;
        const from_hash = std.mem.readInt(u64, seed.bytes[0..8], .little);
        return base + (from_hash +% attempt) % spread;
    }
};

pub const Transport = struct {
    arena: std.mem.Allocator,
    engine: *policy_mod.Engine,
    sender: Sender,
    credentials: Credentials = no_credentials,
    /// Takes credentials out of the prompt before it is encoded.
    ///
    /// The three policy decisions below govern *whether* bytes may leave. This
    /// governs *which* bytes do, which is a different question: a workspace can
    /// legitimately allow a model to read a file and still not want the AWS key
    /// that happened to be inside it sent to a third party.
    ///
    /// Optional so a wire-format test need not build one. Every path that
    /// reaches a real provider sets it.
    redactor: ?secrets.Redactor = null,
    /// Sends and reads the answer as it arrives. Unset means this transport
    /// can only wait for whole replies, and `sendStreaming` says so rather
    /// than quietly falling back to blocking — a caller that asked to watch an
    /// answer being written wants to know it is not going to happen.
    streaming: ?StreamingSender = null,
    /// Checks where the provider's name actually resolves to, before anything
    /// connects.
    ///
    /// The policy decides the host as text. This decides whether the text still
    /// means what it said — whether a public name answers with a private
    /// address, and whether a local model is still local. Optional for the same
    /// reason the redactor is, and set on every path that reaches a provider.
    guard: ?netguard.Guard = null,
    /// How many times a transient failure is tried again, and how long apart.
    retry: Retry = .{},
    /// What to wait with. Unset means no waiting, which also means no retry:
    /// trying again immediately is not a retry, it is the same failure twice.
    waiter: ?Waiter = null,

    /// Decide, then send, then wait for the whole answer.
    pub fn send(
        self: Transport,
        connector: Connector,
        request: provider.Request,
        context: policy_mod.Context,
        attempt: *Attempt,
    ) Error!provider.Completion {
        // Decided once. A retry is the same request going out again, not a new
        // thing to decide about, and re-deciding would put three identical
        // decisions in the record for one action.
        const http = try self.gate(connector, request, context, attempt);

        var tries: usize = 0;
        const response = while (true) {
            tries += 1;
            const outcome = self.sender.send(self.arena, http) catch |err| {
                attempt.sends = tries;
                if (self.shouldTryAgain(tries, null, attempt)) continue;
                attempt.sendProblem = sendProblemText(err, connector.locality == .local);
                return error.SendFailed;
            };
            attempt.sends = tries;
            attempt.status = outcome.status;
            if (outcome.ok()) break outcome;
            if (self.shouldTryAgain(tries, outcome.status, attempt)) continue;
            break outcome;
        };

        if (!response.ok()) {
            attempt.providerError = messageIn(response.body);
            return error.ProviderRejected;
        }

        const completion = connector.wire().decode(self.arena, response.body) catch {
            return error.ProviderRejected;
        };
        attempt.completion = completion;
        return completion;
    }

    /// Whether to send again, and wait if so.
    ///
    /// `status` is null when nothing came back at all — a connection refused or
    /// reset, which is the same kind of transient as a 503 and is retried the
    /// same way. Every try is recorded, because a run that took four seconds
    /// because the provider was busy should not read as a run that took four
    /// seconds to think.
    fn shouldTryAgain(self: Transport, tries: usize, status: ?u16, attempt: *Attempt) bool {
        const waiter = self.waiter orelse return false;
        if (tries >= self.retry.attempts) return false;
        if (status) |code| {
            if (!Retry.worthRetrying(code)) return false;
        }
        attempt.retried = std.mem.concat(self.arena, u16, &.{
            attempt.retried,
            &.{status orelse 0},
        }) catch return false;
        waiter.wait(self.retry.delayFor(tries, attempt.promptHash));
        return true;
    }

    /// Decide, then send, and hand back each piece of the answer as it lands.
    ///
    /// The same gate as `send`: the four decisions and the redaction are one
    /// function, called by both, so a caller cannot reach a provider by
    /// choosing the streaming door. A transport with no streaming sender
    /// refuses rather than quietly waiting for the whole reply, because a
    /// caller that asked to watch an answer being written should be told when
    /// that is not going to happen.
    pub fn sendStreaming(
        self: Transport,
        connector: Connector,
        request: provider.Request,
        context: policy_mod.Context,
        attempt: *Attempt,
        on_delta: ?*const fn (context: ?*anyopaque, delta: stream_mod.Delta) anyerror!void,
        on_delta_context: ?*anyopaque,
    ) Error!provider.Completion {
        const streaming = self.streaming orelse return error.StreamingUnavailable;

        var asked = request;
        asked.stream = true;
        const http = try self.gate(connector, asked, context, attempt);

        var reader = stream_mod.Reader.init(self.arena, connector.format);
        var sink = StreamSink.init(&reader);
        sink.on_delta = on_delta;
        sink.context = on_delta_context;

        const status = streaming.send(self.arena, http, &sink) catch |err| {
            // A failure inside the sink is the real cause and is more use than
            // "the write failed", which is all the client can report.
            const cause = sink.problem orelse err;
            attempt.sendProblem = sendProblemText(cause, connector.locality == .local);
            return error.SendFailed;
        };
        attempt.status = status;
        sink.finish() catch {
            attempt.sendProblem = "The answer stopped part way through and could not be read to the end.";
            return error.SendFailed;
        };

        if (status < 200 or status >= 300) {
            attempt.providerError = "The provider refused the request.";
            return error.ProviderRejected;
        }
        if (reader.assembler.failed()) {
            // The provider said what went wrong mid-stream, in its own words.
            attempt.providerError = messageIn(reader.assembler.problem);
            return error.ProviderRejected;
        }

        const completion = reader.completion() catch return error.ProviderRejected;
        attempt.completion = completion;
        return completion;
    }

    /// Every decision, in order, ending in the bytes that are ready to go out.
    ///
    /// One function rather than two so that a second way of sending cannot be
    /// added with one of the decisions missing, which is how a gate stops being
    /// a gate.
    fn gate(
        self: Transport,
        connector: Connector,
        request: provider.Request,
        context: policy_mod.Context,
        attempt: *Attempt,
    ) Error!provider.HttpRequest {
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

        // 2a. Is the host still where its name says? The rule above allowed
        //     some text; this asks what that text resolves to. A public name
        //     answering with a private address, or a local model answering with
        //     a public one, is refused here — after the policy allowed the
        //     name and before any credential is read, so a rebinding attack
        //     cannot spend one.
        if (self.guard) |guard| {
            const endpoint = connector.endpoint("");
            const expectation: netguard.Expectation =
                if (connector.locality == .local) .this_machine else .the_internet;
            const verdict = guard.verify(
                self.arena,
                endpoint.authority(),
                endpoint.port(),
                expectation,
            ) catch |err| {
                attempt.refusedAt = .address;
                attempt.addressProblem = addressProblemText(err);
                return error.AddressRefused;
            };
            if (verdict == .refused) {
                attempt.refusedAt = .address;
                attempt.addressProblem = verdict.refused.text(self.arena) catch "The address could not be checked.";
                return error.AddressRefused;
            }
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

        // Last chance. After this the bytes are somebody else's.
        //
        // The redaction happens before the prompt is hashed, so the hash in the
        // record is the hash of what actually left rather than of a draft that
        // never existed anywhere.
        const outgoing = try self.withoutCredentials(request, attempt);
        attempt.promptHash = hashPrompt(outgoing);

        return connector.wire().encode(self.arena, connector.endpoint(api_key), outgoing) catch
            error.SendFailed;
    }

    /// A copy of `request` with credentials taken out of every text the model
    /// would see, and `attempt.redactions` set to how many were removed.
    ///
    /// Tool arguments and tool results are rewritten as well as the prompt: a
    /// file the model asked to read comes back through `tool_result`, and that
    /// is the likeliest way a key gets into a conversation in the first place.
    fn withoutCredentials(self: Transport, request: provider.Request, attempt: *Attempt) Error!provider.Request {
        const redactor = self.redactor orelse return request;
        var removed: usize = 0;

        const rewrite = struct {
            fn one(r: secrets.Redactor, arena: std.mem.Allocator, text: []const u8, total: *usize) ![]const u8 {
                const result = try r.rewrite(arena, text);
                total.* += result.findings.len;
                return result.text;
            }
        }.one;

        var messages = self.arena.alloc(provider.Message, request.messages.len) catch return error.SendFailed;
        for (request.messages, 0..) |message, index| {
            var blocks = self.arena.alloc(provider.Block, message.blocks.len) catch return error.SendFailed;
            for (message.blocks, 0..) |block, at| {
                blocks[at] = switch (block) {
                    .text => |t| .{ .text = rewrite(redactor, self.arena, t, &removed) catch return error.SendFailed },
                    .thinking => |t| .{ .thinking = rewrite(redactor, self.arena, t, &removed) catch return error.SendFailed },
                    .tool_use => |t| .{ .tool_use = .{
                        .id = t.id,
                        .name = t.name,
                        .argumentsJson = rewrite(redactor, self.arena, t.argumentsJson, &removed) catch return error.SendFailed,
                    } },
                    .tool_result => |t| .{ .tool_result = .{
                        .toolUseId = t.toolUseId,
                        .content = rewrite(redactor, self.arena, t.content, &removed) catch return error.SendFailed,
                        .isError = t.isError,
                    } },
                };
            }
            messages[index] = .{ .role = message.role, .blocks = blocks };
        }

        var copy = request;
        copy.system = rewrite(redactor, self.arena, request.system, &removed) catch return error.SendFailed;
        copy.messages = messages;
        attempt.redactions = removed;
        return copy;
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
/// Why an address could not be checked, in words.
///
/// A failure to check is a refusal, not a pass. The alternative — treating an
/// unreachable nameserver as permission — is how a control like this quietly
/// stops working on the day it is needed.
pub fn addressProblemText(err: netguard.Error) []const u8 {
    return switch (err) {
        error.HostUnusable => "The provider's address is not a name or an address this build can read.",
        error.LookupFailed => "The provider's name could not be looked up, so where it goes is unknown. Nothing was sent.",
        error.TooManyAddresses => "The provider's name answers with more addresses than can be checked. Nothing was sent.",
        error.OutOfMemory, error.WriteFailed => "The address check could not be completed. Nothing was sent.",
    };
}

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

    /// The same client, reading the answer as it arrives.
    pub fn streamingSender(self: *Http) StreamingSender {
        return .{ .context = self, .sendFn = streamHttp };
    }

    fn streamHttp(
        context: *anyopaque,
        arena: std.mem.Allocator,
        request: provider.HttpRequest,
        sink: *StreamSink,
    ) anyerror!u16 {
        const self: *Http = @ptrCast(@alignCast(context));
        var extra: std.ArrayList(std.http.Header) = .empty;
        var content_type: []const u8 = "application/json";
        for (request.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                content_type = header.value;
                continue;
            }
            try extra.append(arena, .{ .name = header.name, .value = header.value });
        }

        // The response body is written straight into the sink, which forwards
        // every byte to the stream reader and keeps none. No complete copy of
        // the answer exists anywhere, which is the difference between this and
        // a slower way of buffering.
        const result = try self.client.fetch(.{
            .location = .{ .url = request.url },
            .method = .POST,
            .payload = request.body,
            .headers = .{ .content_type = .{ .override = content_type } },
            .extra_headers = extra.items,
            // A credential is in those headers, so a redirect is never
            // followed here either.
            .redirect_behavior = .unhandled,
            .response_writer = &sink.writer,
        });
        return @intFromEnum(result.status);
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
    /// How many bytes a recorded streaming answer is handed over at a time.
    ///
    /// One byte by default, because that is the division that finds the bugs.
    /// A test that hands a whole stream over in one write is testing a case
    /// that does not happen on a real network.
    chunk_size: usize = 1,
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

    /// The same recorded answers, delivered the way a network delivers them.
    pub fn streamingSender(self: *Recorded) StreamingSender {
        return .{ .context = self, .sendFn = streamRecorded };
    }

    fn streamRecorded(
        context: *anyopaque,
        _: std.mem.Allocator,
        request: provider.HttpRequest,
        sink: *StreamSink,
    ) anyerror!u16 {
        const self: *Recorded = @ptrCast(@alignCast(context));
        try self.seen.append(self.arena, request);
        if (self.index >= self.responses.len) return error.NoRecordedResponse;
        defer self.index += 1;
        const response = self.responses[self.index];

        var at: usize = 0;
        while (at < response.body.len) {
            const end = @min(at + @max(self.chunk_size, 1), response.body.len);
            try sink.writer.writeAll(response.body[at..end]);
            at = end;
        }
        return response.status;
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

/// A waiter that records what it was asked to wait for and returns at once,
/// so a test can assert the schedule without spending eight seconds on it.
const CountingWaiter = struct {
    arena: std.mem.Allocator,
    waits: std.ArrayList(u64) = .empty,

    fn waiter(self: *CountingWaiter) Waiter {
        return .{ .context = self, .waitFn = record };
    }

    fn record(context: *anyopaque, nanoseconds: u64) void {
        const self: *CountingWaiter = @ptrCast(@alignCast(context));
        self.waits.append(self.arena, nanoseconds) catch {};
    }
};

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

    /// The same transport, but able to wait — and so to retry. The waiter
    /// records what it was asked to wait for and returns at once, so a test
    /// can assert the schedule without spending it.
    fn retryingTransport(self: *Fixture, waiter: *CountingWaiter) Transport {
        var out = self.transport(with_key);
        out.waiter = waiter.waiter();
        return out;
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

test "a credential in the prompt never reaches the wire" {
    // Everything is allowed here, so nothing but the redaction can be the
    // reason a key is missing from the body.
    var fixture = try Fixture.init(&allow_everything, &.{.{ .status = 200, .body = answer }});
    defer fixture.deinit();

    // The likeliest route by which a key reaches a provider is not a person
    // typing it. It is a file the model asked to read coming back as a tool
    // result, so that path is exercised here alongside the prompt itself.
    const request: provider.Request = .{
        .model = "claude-opus-5",
        .system = "The operator key is sk-ant-api03-" ++ "v" ** 40,
        .messages = &.{
            .{ .role = .user, .blocks = &.{.{ .text = "here is my token ghp_" ++ "u" ** 36 }} },
            .{ .role = .user, .blocks = &.{.{ .tool_result = .{
                .toolUseId = "call_1",
                .content = "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n",
            } }} },
        },
    };

    var transport = fixture.transport(with_key);
    transport.redactor = secrets.Redactor.withSalt([_]u8{7} ** 16);

    var attempt: Attempt = undefined;
    const connector = catalog.find("anthropic").?;
    _ = try transport.send(connector, request, fixture.context(), &attempt);

    try testing.expectEqual(@as(usize, 1), fixture.recorded.seen.items.len);
    const body = fixture.recorded.seen.items[0].body;

    try testing.expect(std.mem.indexOf(u8, body, "sk-ant-api03") == null);
    try testing.expect(std.mem.indexOf(u8, body, "ghp_") == null);
    try testing.expect(std.mem.indexOf(u8, body, "AKIAIOSFODNN7EXAMPLE") == null);
    try testing.expectEqual(@as(usize, 3), attempt.redactions);

    // The words around each key survive, so the model can still be told what it
    // is looking at and why the value is not there.
    try testing.expect(std.mem.indexOf(u8, body, "here is my token") != null);
    try testing.expect(std.mem.indexOf(u8, body, "AWS_ACCESS_KEY_ID=") != null);
    try testing.expect(std.mem.indexOf(u8, body, "redacted") != null);

    // The recorded hash is the hash of what left, not of a draft that never
    // existed anywhere. Without this the record would point at a prompt nobody
    // ever sent.
    var ignored: Attempt = attempt;
    const outgoing = try transport.withoutCredentials(request, &ignored);
    try testing.expect(attempt.promptHash.eql(hashPrompt(outgoing)));
    try testing.expect(!attempt.promptHash.eql(hashPrompt(request)));
}

test "a provider whose name resolves somewhere private is refused before the credential is read" {
    var fixture = try Fixture.init(&allow_everything, &.{.{ .status = 200, .body = answer }});
    defer fixture.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    // A connector whose base address is the cloud metadata service. The policy
    // here allows everything, so the only thing that can stop this is the
    // address check — which is the point: the two are separate questions and
    // this proves the second one is asked.
    const rogue: catalog.Connector = .{
        .id = "rogue",
        .name = "Rogue",
        .format = .openai,
        .baseUrl = "http://169.254.169.254",
        .keyVariable = "ANTHROPIC_API_KEY",
        .locality = .hosted,
        .verified = .format_only,
        .note = "A connector pointed at the cloud metadata service.",
    };

    var transport = fixture.transport(with_key);
    transport.guard = .{ .io = threaded.io() };

    var attempt: Attempt = undefined;
    const result = transport.send(rogue, ask(), fixture.context(), &attempt);
    try testing.expectError(error.AddressRefused, result);
    try testing.expectEqual(Stage.address, attempt.refusedAt.?);

    // Nothing was handed to the sender. A refusal that still made the request
    // would be no refusal at all.
    try testing.expectEqual(@as(usize, 0), fixture.recorded.seen.items.len);

    // The refusal names the address and what is wrong with it, in words.
    try testing.expect(std.mem.indexOf(u8, attempt.addressProblem, "169.254.169.254") != null);
    try testing.expect(std.mem.indexOf(u8, attempt.addressProblem, "this network link") != null);

    // The first two decisions were taken and recorded before the address was
    // checked, so the record still shows the policy allowed the host by name.
    // That distinction is the whole reason this is a separate stage.
    try testing.expect(attempt.decisions.len >= 2);
    for (attempt.decisions) |decision| try testing.expect(decision.isAllowed());
}

test "a hosted connector pointed at loopback is refused, and a local one is not" {
    var fixture = try Fixture.init(&allow_everything, &.{
        .{ .status = 200, .body = answer },
        .{ .status = 200, .body = answer },
    });
    defer fixture.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var transport = fixture.transport(with_key);
    transport.guard = .{ .io = threaded.io() };

    // Ollama, on this machine, at the address it is supposed to be at.
    const local: catalog.Connector = .{
        .id = "local",
        .name = "Local",
        // The wire format is beside the point here; the fixture answers in the
        // one this repository was written against so that a decode failure
        // cannot be mistaken for an address refusal.
        .format = .anthropic,
        .baseUrl = "http://127.0.0.1:11434",
        .locality = .local,
        .verified = .format_only,
        .note = "A model on this computer.",
    };
    var allowed: Attempt = undefined;
    _ = try transport.send(local, ask(), fixture.context(), &allowed);
    try testing.expect(allowed.refusedAt == null);

    // The identical address, offered by a connector that says it is hosted
    // somewhere else. Same bytes, opposite answer, because the expectation is
    // what the connector claimed about itself.
    var disguised = local;
    disguised.id = "not-local";
    disguised.locality = .hosted;
    var refused: Attempt = undefined;
    try testing.expectError(error.AddressRefused, transport.send(disguised, ask(), fixture.context(), &refused));
    try testing.expectEqual(Stage.address, refused.refusedAt.?);
    try testing.expect(std.mem.indexOf(u8, refused.addressProblem, "127.0.0.1") != null);
}

test "every stage of the gate says what it is in words" {
    // A refusal names the stage it happened at, and a stage with no words would
    // print an empty reason to somebody trying to understand a denial.
    for (std.enums.values(Stage)) |stage| {
        try testing.expect(stage.text().len > 0);
        for (std.enums.values(Stage)) |other| {
            if (stage == other) continue;
            try testing.expect(!std.mem.eql(u8, stage.text(), other.text()));
        }
    }
}

test "a streamed answer passes the same gate as a whole one" {
    // A second way of sending is how a gate stops being a gate. The decisions
    // live in one function that both doors call, and this is the test that says
    // so: a policy that refuses the model refuses it whichever way it is asked.
    const refuse_infer = [_]policy_mod.Rule{.{
        .id = "no-models",
        .capabilities = &.{.@"model.infer"},
        .effect = .deny,
        .reason = "This workspace does not use models.",
    }};
    var fixture = try Fixture.init(&refuse_infer, &.{.{ .status = 200, .body = anthropic_sse }});
    defer fixture.deinit();

    var transport = fixture.transport(with_key);
    transport.streaming = fixture.recorded.streamingSender();

    var attempt: Attempt = undefined;
    const connector = catalog.find("anthropic").?;
    try testing.expectError(
        error.NotPermitted,
        transport.sendStreaming(connector, ask(), fixture.context(), &attempt, null, null),
    );
    try testing.expectEqual(Stage.infer, attempt.refusedAt.?);
    // Nothing reached the sender. A refusal that still made the request is not
    // a refusal.
    try testing.expectEqual(@as(usize, 0), fixture.recorded.seen.items.len);
}

test "a credential in a streamed prompt is redacted, same as a blocking one" {
    var fixture = try Fixture.init(&allow_everything, &.{.{ .status = 200, .body = anthropic_sse }});
    defer fixture.deinit();

    var transport = fixture.transport(with_key);
    transport.streaming = fixture.recorded.streamingSender();
    transport.redactor = secrets.Redactor.withSalt([_]u8{9} ** 16);

    const request: provider.Request = .{
        .model = "claude-opus-5",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "token ghp_" ++ "s" ** 36 }} }},
    };

    var attempt: Attempt = undefined;
    _ = try transport.sendStreaming(catalog.find("anthropic").?, request, fixture.context(), &attempt, null, null);

    const body = fixture.recorded.seen.items[0].body;
    try testing.expect(std.mem.indexOf(u8, body, "ghp_") == null);
    try testing.expectEqual(@as(usize, 1), attempt.redactions);
    // And the request asked for a stream, which the caller never had to set.
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

test "a streamed answer arrives in pieces and ends up whole" {
    var fixture = try Fixture.init(&allow_everything, &.{.{ .status = 200, .body = anthropic_sse }});
    defer fixture.deinit();

    var transport = fixture.transport(with_key);
    transport.streaming = fixture.recorded.streamingSender();
    // One byte at a time, which is the division that finds the bugs.
    fixture.recorded.chunk_size = 1;

    // What a caller does with a stream: watch it arrive.
    const Watcher = struct {
        var seen: usize = 0;
        var text: std.ArrayList(u8) = .empty;
        var arena: std.mem.Allocator = undefined;

        fn onDelta(_: ?*anyopaque, delta: stream_mod.Delta) anyerror!void {
            seen += 1;
            switch (delta) {
                .text => |t| try text.appendSlice(arena, t.chunk),
                else => {},
            }
        }
    };
    Watcher.seen = 0;
    Watcher.text = .empty;
    Watcher.arena = fixture.arena();

    var attempt: Attempt = undefined;
    const streamed = try transport.sendStreaming(
        catalog.find("anthropic").?,
        ask(),
        fixture.context(),
        &attempt,
        Watcher.onDelta,
        null,
    );

    // The caller saw the answer being written, in more than one piece. That is
    // the whole feature: without it there is one delta at the end and this is
    // a slower way of blocking.
    try testing.expect(Watcher.seen > 3);
    try testing.expectEqualStrings("Four.", Watcher.text.items);

    // And the completion is the one the blocking path would have returned.
    try testing.expectEqualStrings("Four.", try streamed.text(fixture.arena()));
    try testing.expectEqualStrings("claude-opus-5", streamed.model);
    try testing.expectEqual(provider.StopReason.end_turn, streamed.stopReason);
    try testing.expectEqual(@as(u64, 10), streamed.usage.inputTokens);
    try testing.expectEqual(@as(u64, 2), streamed.usage.outputTokens);
    try testing.expectEqual(@as(u16, 200), attempt.status.?);
}

test "a transport with no streaming sender says so rather than blocking" {
    var fixture = try Fixture.init(&allow_everything, &.{.{ .status = 200, .body = answer }});
    defer fixture.deinit();

    // Quietly waiting for the whole reply would look like the feature working
    // badly rather than not being there.
    const transport = fixture.transport(with_key);
    var attempt: Attempt = undefined;
    try testing.expectError(
        error.StreamingUnavailable,
        transport.sendStreaming(catalog.find("anthropic").?, ask(), fixture.context(), &attempt, null, null),
    );
}

test "a provider that fails mid-stream is reported with its own words" {
    const broken =
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Part\"}}\n\n" ++
        "event: error\n" ++
        "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n";
    var fixture = try Fixture.init(&allow_everything, &.{.{ .status = 200, .body = broken }});
    defer fixture.deinit();

    var transport = fixture.transport(with_key);
    transport.streaming = fixture.recorded.streamingSender();

    var attempt: Attempt = undefined;
    // A 200 that turns into an error part way through. Returning the truncated
    // answer as if it were complete is the failure worth avoiding.
    try testing.expectError(
        error.ProviderRejected,
        transport.sendStreaming(catalog.find("anthropic").?, ask(), fixture.context(), &attempt, null, null),
    );
    try testing.expect(std.mem.indexOf(u8, attempt.providerError, "Overloaded") != null);
}

/// A short Anthropic stream, as the wire carries it.
const anthropic_sse =
    "event: message_start\n" ++
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}\n\n" ++
    "event: content_block_start\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    ": ping\n\n" ++
    "event: content_block_delta\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Fo\"}}\n\n" ++
    "event: content_block_delta\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ur.\"}}\n\n" ++
    "event: content_block_stop\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "event: message_delta\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}\n\n" ++
    "event: message_stop\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const busy_body =
    \\{"error":{"type":"overloaded_error","message":"slow down"}}
;

test "a provider saying it is busy is asked again, not given up on" {
    // 429 and 503 are the normal way a shared service says "not right now".
    // Ending an agent's work because one request landed in someone else's
    // burst throws away everything done so far for a condition that clears in
    // a second.
    const fixture = try Fixture.init(&allow_everything, &.{
        .{ .status = 429, .body = busy_body },
        .{ .status = 503, .body = busy_body },
        .{ .status = 200, .body = answer },
    });
    defer fixture.deinit();
    var waiter: CountingWaiter = .{ .arena = fixture.arena() };

    var attempt: Attempt = undefined;
    const completion = try fixture.retryingTransport(&waiter).send(
        catalog.find("anthropic").?,
        ask(),
        fixture.context(),
        &attempt,
    );
    try testing.expectEqualStrings("Four.", try completion.text(fixture.arena()));

    // Three sends, two of them retries, and the record says which.
    try testing.expectEqual(@as(usize, 3), attempt.sends);
    try testing.expectEqual(@as(usize, 2), attempt.retried.len);
    try testing.expectEqual(@as(u16, 429), attempt.retried[0]);
    try testing.expectEqual(@as(u16, 503), attempt.retried[1]);
    try testing.expectEqual(@as(u16, 200), attempt.status.?);

    // It waited, and waited longer the second time.
    try testing.expectEqual(@as(usize, 2), waiter.waits.items.len);
    try testing.expect(waiter.waits.items[1] > waiter.waits.items[0]);
}

test "a refusal that will not change is not retried into three refusals" {
    // An invalid key is invalid the third time too. A client that retries
    // everything takes three times as long to say what is wrong, and spends
    // two extra requests doing it.
    for ([_]u16{ 400, 401, 403, 404, 422 }) |code| {
        const fixture = try Fixture.init(&allow_everything, &.{.{ .status = code, .body = busy_body }});
        defer fixture.deinit();
        var waiter: CountingWaiter = .{ .arena = fixture.arena() };

        var attempt: Attempt = undefined;
        try testing.expectError(error.ProviderRejected, fixture.retryingTransport(&waiter).send(
            catalog.find("anthropic").?,
            ask(),
            fixture.context(),
            &attempt,
        ));
        try testing.expectEqual(@as(usize, 1), attempt.sends);
        try testing.expectEqual(@as(usize, 0), waiter.waits.items.len);
    }
}

test "a provider that stays busy gives up, and the record says how often it tried" {
    const fixture = try Fixture.init(&allow_everything, &.{
        .{ .status = 503, .body = busy_body },
        .{ .status = 503, .body = busy_body },
        .{ .status = 503, .body = busy_body },
    });
    defer fixture.deinit();
    var waiter: CountingWaiter = .{ .arena = fixture.arena() };

    var attempt: Attempt = undefined;
    try testing.expectError(error.ProviderRejected, fixture.retryingTransport(&waiter).send(
        catalog.find("anthropic").?,
        ask(),
        fixture.context(),
        &attempt,
    ));
    // Bounded: a retry that never stops is a hang with extra steps.
    try testing.expectEqual(@as(usize, 3), attempt.sends);
    try testing.expectEqual(@as(usize, 2), waiter.waits.items.len);
}

test "a retry is one request going out again, not a new thing to decide" {
    const fixture = try Fixture.init(&allow_everything, &.{
        .{ .status = 429, .body = busy_body },
        .{ .status = 200, .body = answer },
    });
    defer fixture.deinit();
    var waiter: CountingWaiter = .{ .arena = fixture.arena() };

    var attempt: Attempt = undefined;
    _ = try fixture.retryingTransport(&waiter).send(
        catalog.find("anthropic").?,
        ask(),
        fixture.context(),
        &attempt,
    );

    // Two sends, one set of decisions. Deciding again per try would put two
    // identical decisions in the record for one action, and a person reading
    // it would see two requests where the policy allowed one.
    try testing.expectEqual(@as(usize, 2), attempt.sends);
    try testing.expectEqual(@as(usize, 3), attempt.decisions.len);
}

test "without a waiter there is no retry, because there is no waiting" {
    // Trying again immediately is not a retry; it is the same failure twice,
    // arriving at the busy provider in the same millisecond.
    const fixture = try Fixture.init(&allow_everything, &.{
        .{ .status = 503, .body = busy_body },
        .{ .status = 200, .body = answer },
    });
    defer fixture.deinit();

    var attempt: Attempt = undefined;
    try testing.expectError(error.ProviderRejected, fixture.transport(with_key).send(
        catalog.find("anthropic").?,
        ask(),
        fixture.context(),
        &attempt,
    ));
    try testing.expectEqual(@as(usize, 1), attempt.sends);
}

test "the wait doubles, is capped, and is spread so clients do not re-collide" {
    const retry: Retry = .{ .firstDelay = 100, .maxDelay = 1000 };
    const seed = hashing.Hash.of("a prompt");

    try testing.expect(retry.delayFor(1, seed) >= 100);
    try testing.expect(retry.delayFor(2, seed) >= 200);
    try testing.expect(retry.delayFor(3, seed) >= 400);

    // Capped however many times it is asked. A large attempt number has to
    // saturate rather than shift the delay away to nothing.
    try testing.expect(retry.delayFor(40, seed) >= 1000);
    try testing.expect(retry.delayFor(40, seed) <= 1000 + 1000 / 4);

    // Spread: a fleet that all backed off by exactly 500 ms would re-collide
    // at 500 ms. Taking the jitter from the prompt's hash spreads it across
    // requests while keeping it identical for the same request, so a replay of
    // a recorded run waits exactly as the original did.
    const other = hashing.Hash.of("a different prompt");
    try testing.expect(retry.delayFor(2, seed) != retry.delayFor(2, other));
    try testing.expectEqual(retry.delayFor(2, seed), retry.delayFor(2, seed));

    // Never less than asked: longer is safe, shorter defeats the point.
    try testing.expect(retry.delayFor(1, other) >= 100);
    try testing.expect(retry.delayFor(1, other) <= 125);
}
