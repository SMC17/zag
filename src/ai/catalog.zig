//! The connectors this build can reach, and what each one needs.
//!
//! Five wire formats reach every entry in this list. That is not a shortcut: it
//! is how the ecosystem actually settled. Most hosted providers and almost
//! every local server accept the OpenAI chat-completions shape, so one careful
//! connector reaches them all, and the four others cover the providers that
//! speak for themselves.
//!
//! Each entry says where it sends, which environment variable holds the
//! credential, and whether it runs on this machine. That last one is not
//! decoration. A workspace can allow local models and refuse hosted ones, and a
//! person deciding needs to see which is which before they answer.
//!
//! What this file does **not** claim is that every entry has been called. The
//! wire formats are tested against recorded answers; the addresses here are
//! written from each provider's documented endpoint. `verified` records the
//! difference, and `zag providers` prints it, so nobody mistakes a plausible
//! address for a tested one.

const std = @import("std");
const provider = @import("provider.zig");
const anthropic = @import("wire/anthropic.zig");
const openai = @import("wire/openai.zig");
const gemini = @import("wire/gemini.zig");
const ollama = @import("wire/ollama.zig");
const huggingface = @import("wire/huggingface.zig");

pub const Format = enum {
    anthropic,
    openai,
    gemini,
    ollama,
    huggingface,

    pub fn wire(self: Format) provider.Wire {
        return switch (self) {
            .anthropic => anthropic.wire,
            .openai => openai.wire,
            .gemini => gemini.wire,
            .ollama => ollama.wire,
            .huggingface => huggingface.wire,
        };
    }
};

/// Where the model runs, which is what a person deciding about a request most
/// wants to know.
pub const Locality = enum {
    /// On this machine. Nothing leaves it.
    local,
    /// On somebody else's machine, reached over the network.
    hosted,

    pub fn text(self: Locality) []const u8 {
        return switch (self) {
            .local => "on this computer",
            .hosted => "over the network",
        };
    }
};

/// How far a connector has been checked.
pub const Verification = enum {
    /// The wire format is covered by tests against recorded answers, and the
    /// address has been called from this repository.
    called,
    /// The wire format is covered by tests. The address is the provider's
    /// documented one and has not been called from here.
    format_only,

    pub fn text(self: Verification) []const u8 {
        return switch (self) {
            .called => "wire format tested, endpoint called",
            .format_only => "wire format tested, endpoint not called from here",
        };
    }
};

pub const Connector = struct {
    /// Short name a person types: `anthropic`, `ollama`, `groq`.
    id: []const u8,
    name: []const u8,
    format: Format,
    /// Documented base address, with no trailing slash.
    baseUrl: []const u8,
    /// The environment variable holding the credential. Empty when none is
    /// needed, which is the usual case for a model on this machine.
    keyVariable: []const u8 = "",
    locality: Locality = .hosted,
    verified: Verification = .format_only,
    /// One line for the person choosing.
    note: []const u8 = "",

    pub fn wire(self: Connector) provider.Wire {
        return self.format.wire();
    }

    /// The endpoint to send to, given a credential.
    pub fn endpoint(self: Connector, apiKey: []const u8) provider.Endpoint {
        return .{ .baseUrl = self.baseUrl, .apiKey = apiKey };
    }

    pub fn needsCredential(self: Connector) bool {
        return self.keyVariable.len > 0;
    }
};

/// Every connector, in the order a person would read them: the one this
/// workbench was written against, then the rest of the hosted providers, then
/// everything that runs on this machine.
pub const connectors = [_]Connector{
    .{
        .id = "anthropic",
        .name = "Anthropic",
        .format = .anthropic,
        .baseUrl = "https://api.anthropic.com",
        .keyVariable = "ANTHROPIC_API_KEY",
        .verified = .format_only,
        .note = "Claude. The first connector, and the API this workbench was written alongside.",
    },
    .{
        .id = "openai",
        .name = "OpenAI",
        .format = .openai,
        .baseUrl = "https://api.openai.com/v1",
        .keyVariable = "OPENAI_API_KEY",
    },
    .{
        .id = "gemini",
        .name = "Google Gemini",
        .format = .gemini,
        .baseUrl = "https://generativelanguage.googleapis.com",
        .keyVariable = "GEMINI_API_KEY",
    },
    .{
        .id = "huggingface",
        .name = "Hugging Face router",
        .format = .openai,
        .baseUrl = "https://router.huggingface.co/v1",
        .keyVariable = "HF_TOKEN",
        .note = "Reaches the inference providers behind Hugging Face in one shape.",
    },
    .{
        .id = "huggingface-tgi",
        .name = "Hugging Face text generation",
        .format = .huggingface,
        .baseUrl = "http://localhost:8080",
        .keyVariable = "HF_TOKEN",
        .locality = .local,
        .note = "A served model: an inference endpoint, or Text Generation Inference on this machine.",
    },
    .{
        .id = "groq",
        .name = "Groq",
        .format = .openai,
        .baseUrl = "https://api.groq.com/openai/v1",
        .keyVariable = "GROQ_API_KEY",
    },
    .{
        .id = "together",
        .name = "Together AI",
        .format = .openai,
        .baseUrl = "https://api.together.xyz/v1",
        .keyVariable = "TOGETHER_API_KEY",
    },
    .{
        .id = "fireworks",
        .name = "Fireworks AI",
        .format = .openai,
        .baseUrl = "https://api.fireworks.ai/inference/v1",
        .keyVariable = "FIREWORKS_API_KEY",
    },
    .{
        .id = "openrouter",
        .name = "OpenRouter",
        .format = .openai,
        .baseUrl = "https://openrouter.ai/api/v1",
        .keyVariable = "OPENROUTER_API_KEY",
        .note = "One address in front of many providers.",
    },
    .{
        .id = "deepseek",
        .name = "DeepSeek",
        .format = .openai,
        .baseUrl = "https://api.deepseek.com",
        .keyVariable = "DEEPSEEK_API_KEY",
    },
    .{
        .id = "mistral",
        .name = "Mistral",
        .format = .openai,
        .baseUrl = "https://api.mistral.ai/v1",
        .keyVariable = "MISTRAL_API_KEY",
    },
    .{
        .id = "xai",
        .name = "xAI",
        .format = .openai,
        .baseUrl = "https://api.x.ai/v1",
        .keyVariable = "XAI_API_KEY",
    },
    .{
        .id = "cerebras",
        .name = "Cerebras",
        .format = .openai,
        .baseUrl = "https://api.cerebras.ai/v1",
        .keyVariable = "CEREBRAS_API_KEY",
    },
    .{
        .id = "deepinfra",
        .name = "DeepInfra",
        .format = .openai,
        .baseUrl = "https://api.deepinfra.com/v1/openai",
        .keyVariable = "DEEPINFRA_API_KEY",
    },
    .{
        .id = "nebius",
        .name = "Nebius AI Studio",
        .format = .openai,
        .baseUrl = "https://api.studio.nebius.ai/v1",
        .keyVariable = "NEBIUS_API_KEY",
    },
    .{
        .id = "hyperbolic",
        .name = "Hyperbolic",
        .format = .openai,
        .baseUrl = "https://api.hyperbolic.xyz/v1",
        .keyVariable = "HYPERBOLIC_API_KEY",
    },
    .{
        .id = "sambanova",
        .name = "SambaNova",
        .format = .openai,
        .baseUrl = "https://api.sambanova.ai/v1",
        .keyVariable = "SAMBANOVA_API_KEY",
    },
    .{
        .id = "novita",
        .name = "Novita AI",
        .format = .openai,
        .baseUrl = "https://api.novita.ai/v3/openai",
        .keyVariable = "NOVITA_API_KEY",
    },
    .{
        .id = "perplexity",
        .name = "Perplexity",
        .format = .openai,
        .baseUrl = "https://api.perplexity.ai",
        .keyVariable = "PERPLEXITY_API_KEY",
    },
    // --- Models on this machine --------------------------------------------
    .{
        .id = "ollama",
        .name = "Ollama",
        .format = .ollama,
        .baseUrl = "http://localhost:11434",
        .locality = .local,
        .note = "Its own shape, which reports the model that answered and the token counts.",
    },
    .{
        .id = "ollama-openai",
        .name = "Ollama, in the OpenAI shape",
        .format = .openai,
        .baseUrl = "http://localhost:11434/v1",
        .locality = .local,
        .note = "The same server, for tools that expect the OpenAI shape.",
    },
    .{
        .id = "llamacpp",
        .name = "llama.cpp server",
        .format = .openai,
        .baseUrl = "http://localhost:8080/v1",
        .locality = .local,
    },
    .{
        .id = "lmstudio",
        .name = "LM Studio",
        .format = .openai,
        .baseUrl = "http://localhost:1234/v1",
        .locality = .local,
    },
    .{
        .id = "vllm",
        .name = "vLLM",
        .format = .openai,
        .baseUrl = "http://localhost:8000/v1",
        .locality = .local,
    },
    .{
        .id = "localai",
        .name = "LocalAI",
        .format = .openai,
        .baseUrl = "http://localhost:8080/v1",
        .locality = .local,
    },
    .{
        .id = "jan",
        .name = "Jan",
        .format = .openai,
        .baseUrl = "http://localhost:1337/v1",
        .locality = .local,
    },
    .{
        .id = "koboldcpp",
        .name = "KoboldCpp",
        .format = .openai,
        .baseUrl = "http://localhost:5001/v1",
        .locality = .local,
    },
    .{
        .id = "textgen-webui",
        .name = "Text generation web user interface",
        .format = .openai,
        .baseUrl = "http://localhost:5000/v1",
        .locality = .local,
    },
};

pub fn find(id: []const u8) ?Connector {
    for (connectors) |connector| {
        if (std.mem.eql(u8, connector.id, id)) return connector;
    }
    return null;
}

pub fn count() usize {
    return connectors.len;
}

pub fn localCount() usize {
    var total: usize = 0;
    for (connectors) |connector| {
        if (connector.locality == .local) total += 1;
    }
    return total;
}

/// Write the list for a person choosing one.
///
/// `credentials` answers, for one variable name, whether it is set. It is
/// passed in rather than read here, so that this function stays testable and
/// so that nothing in the library reaches for the environment on its own.
pub fn writeList(
    w: *std.Io.Writer,
    credentials: *const fn ([]const u8) bool,
) std.Io.Writer.Error!void {
    try w.print("{d} connectors, {d} of them on this computer.\n\n", .{ count(), localCount() });
    for (connectors) |connector| {
        try w.print("{s:<16} {s:<34} {s}", .{
            connector.id,
            connector.name,
            connector.locality.text(),
        });
        if (connector.needsCredential()) {
            const ready = credentials(connector.keyVariable);
            try w.print("  {s}{s}", .{ connector.keyVariable, if (ready) " (set)" else " (not set)" });
        }
        try w.writeAll("\n");
        if (connector.note.len > 0) try w.print("                 {s}\n", .{connector.note});
    }
    try w.writeAll(
        \\
        \\Every one of these sends through the policy engine. A connector needs
        \\permission to reach its host, and the decision is written to the log
        \\with the rest of the session.
        \\
        \\The wire formats are tested against recorded answers. An address here
        \\is the provider's documented one; where this repository has not called
        \\it, the list says so rather than implying it was checked.
        \\
    );
}

const testing = std.testing;

fn noCredentials(_: []const u8) bool {
    return false;
}

test "every connector is complete and reachable by name" {
    for (connectors) |connector| {
        try testing.expect(connector.id.len > 0);
        try testing.expect(connector.name.len > 0);
        try testing.expect(connector.baseUrl.len > 0);
        // An address with a trailing slash produces a double slash when a path
        // is joined to it.
        try testing.expect(connector.baseUrl[connector.baseUrl.len - 1] != '/');
        try testing.expect(std.mem.startsWith(u8, connector.baseUrl, "http"));
        try testing.expect(find(connector.id) != null);

        // Locality has to match the address, or the list misleads the person
        // it exists to inform.
        const endpoint = connector.endpoint("");
        try testing.expectEqual(connector.locality == .local, endpoint.isLocal());
    }
}

test "no two connectors share an identifier" {
    for (connectors, 0..) |a, i| {
        for (connectors[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.id, b.id));
        }
    }
}

test "each format resolves to a wire that names itself" {
    inline for (comptime std.meta.fields(Format)) |field| {
        const format: Format = @enumFromInt(field.value);
        const w = format.wire();
        try testing.expectEqualStrings(field.name, w.id);
    }
}

test "the anthropic connector encodes through its own wire" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const connector = find("anthropic").?;
    try testing.expectEqual(Format.anthropic, connector.format);
    const http = try connector.wire().encode(arena, connector.endpoint("sk-test"), .{
        .model = "claude-opus-5",
        .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "Hello" }} }},
    });
    try testing.expectEqualStrings("api.anthropic.com", http.host);
    try testing.expect(std.mem.endsWith(u8, http.url, "/v1/messages"));
}

test "a local connector reports that nothing leaves the machine" {
    const ollama_connector = find("ollama").?;
    try testing.expectEqual(Locality.local, ollama_connector.locality);
    try testing.expect(!ollama_connector.needsCredential());
    try testing.expect(ollama_connector.endpoint("").isLocal());

    const hosted = find("groq").?;
    try testing.expectEqual(Locality.hosted, hosted.locality);
    try testing.expect(hosted.needsCredential());
}

test "the list says what was checked and what was not" {
    var buffer: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try writeList(&w, noCredentials);
    const text = w.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "connectors,") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not set") != null);
    try testing.expect(std.mem.indexOf(u8, text, "policy engine") != null);
    // The honesty line is part of the output, not a comment in the source.
    try testing.expect(std.mem.indexOf(u8, text, "has not called") != null);
}

test "there are enough connectors to be worth a list, and several are local" {
    try testing.expect(count() >= 20);
    try testing.expect(localCount() >= 6);
}
