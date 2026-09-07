//! Finding credentials in text, before the text becomes a record.
//!
//! This program writes down what happened. That is the whole point of it, and
//! it is also the reason a credential that reaches the log is worse here than
//! it would be in a terminal that forgets. The log is append-only and
//! hash-chained: a secret written into it cannot be edited out without breaking
//! the chain that proves nothing was edited. There is no `git rm` for a record
//! whose value is that it cannot be rewritten.
//!
//! So credentials have to be caught on the way in. This module is the only
//! thing standing between what a command printed and what the workspace keeps.
//!
//! ## What it looks for, and in what order
//!
//! Three passes, deliberately different in kind, because the ways a secret
//! shows itself are different in kind:
//!
//!   1. **Delimited blocks.** A PEM private key announces itself with a line
//!      that says so. There is no guessing involved and no threshold to tune —
//!      it is found by its own header and redacted to its own footer.
//!   2. **Shapes with a published prefix.** `sk-ant-`, `ghp_`, `AKIA`, `xoxb-`
//!      and the rest. Providers chose these prefixes precisely so that leaked
//!      keys could be recognised, and a table of them is the highest-precision
//!      detector available: a token with the prefix, the right length and the
//!      right alphabet is a key, not a coincidence.
//!   3. **Anything assigned to something that calls itself a secret.** A value
//!      after `api_key=`, `"password":`, `TOKEN: `. This is the pass that finds
//!      the provider nobody has heard of, and the one that needs a threshold —
//!      so it also demands the value carry enough entropy to be a key rather
//!      than the word `changeme`.
//!
//! ## Why not entropy on its own
//!
//! Because a compiled program's output is full of high-entropy strings that are
//! not secrets: content hashes, git object names, base64 images, UUIDs, minified
//! source. A detector that redacts all of them makes the record useless, and a
//! record nobody reads protects nothing. Entropy is used here only as a *veto*
//! on the third pass — never on its own as a reason to redact. The first two
//! passes need no entropy test at all, because a `-----BEGIN OPENSSH PRIVATE
//! KEY-----` line is not a coincidence at any entropy.
//!
//! ## What a redaction leaves behind
//!
//! A placeholder that names the kind and carries four hex digits of a *salted*
//! fingerprint: `[redacted github-token 7f3a]`. The kind is there so a person
//! reading the record knows what was taken out. The fingerprint is there so
//! that one credential appearing in twenty places reads as one credential, and
//! two different credentials never read as one — which is the question an
//! incident actually turns on.
//!
//! The salt matters and is not decoration. An unsalted fingerprint of a short
//! or low-entropy secret is an oracle: anybody holding the record can hash
//! guesses until four hex digits match. The salt is drawn once per redactor
//! from the operating system and never written down, so the fingerprints are
//! comparable within one record and meaningless outside it.
//!
//! ## What this does not do
//!
//! It does not promise to find every secret. No detector does, and one that
//! claimed to would be the more dangerous thing to ship, because it would be
//! believed. It finds the shapes below and the assignments below. A credential
//! with no prefix, no delimiter and no name next to it — a bare password typed
//! into a prompt, a token split across two lines — passes through, and the
//! documentation says so rather than implying otherwise.

const std = @import("std");
const hashing = @import("../core/hash.zig");
const scan_mod = @import("../core/scan.zig");

/// What was found. The name is what a person reads in the placeholder, so it
/// is written as words rather than as an internal identifier.
pub const Kind = enum {
    private_key_block,
    aws_access_key_id,
    aws_secret_access_key,
    github_token,
    gitlab_token,
    anthropic_api_key,
    openai_api_key,
    google_api_key,
    slack_token,
    stripe_key,
    hugging_face_token,
    npm_token,
    json_web_token,
    url_credentials,
    named_secret,

    /// The words that go in a placeholder.
    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .private_key_block => "private-key",
            .aws_access_key_id => "aws-access-key-id",
            .aws_secret_access_key => "aws-secret-access-key",
            .github_token => "github-token",
            .gitlab_token => "gitlab-token",
            .anthropic_api_key => "anthropic-api-key",
            .openai_api_key => "openai-api-key",
            .google_api_key => "google-api-key",
            .slack_token => "slack-token",
            .stripe_key => "stripe-key",
            .hugging_face_token => "hugging-face-token",
            .npm_token => "npm-token",
            .json_web_token => "json-web-token",
            .url_credentials => "url-credentials",
            .named_secret => "secret",
        };
    }

    /// Which pass found it. Reported so that a person reviewing a redaction can
    /// tell a certainty from a judgement.
    pub fn certainty(self: Kind) Certainty {
        return switch (self) {
            .named_secret => .inferred,
            else => .recognised,
        };
    }
};

/// How the finding was reached.
pub const Certainty = enum {
    /// Matched a delimiter or a published prefix. No threshold was involved.
    recognised,
    /// Matched a name that says "secret" and carried enough entropy to be one.
    /// A person may disagree with this one; the other kind they may not.
    inferred,

    pub fn text(self: Certainty) []const u8 {
        return switch (self) {
            .recognised => "recognised",
            .inferred => "inferred",
        };
    }
};

/// One credential, located in the text it was found in.
///
/// `start` and `end` bound the secret itself, not the name in front of it: the
/// point is to remove the value and keep the sentence around it readable, so
/// that `AWS_SECRET_ACCESS_KEY=[redacted ...]` still tells a reader which
/// variable was set.
pub const Finding = struct {
    kind: Kind,
    start: usize,
    end: usize,

    pub fn len(self: Finding) usize {
        return self.end - self.start;
    }
};

/// A published credential shape.
///
/// Providers publish these prefixes so that leaked keys can be recognised by
/// scanners exactly like this one. Matching one is not a heuristic.
const Shape = struct {
    kind: Kind,
    prefix: []const u8,
    /// Total length including the prefix. A range because several providers
    /// have issued more than one length under one prefix.
    min_len: usize,
    max_len: usize,
    /// Whether the body may contain `-` and `_` as well as letters and digits.
    /// AWS keys may not; GitHub and Slack tokens may.
    dashes: bool = true,
};

/// The table. Ordered longest prefix first so that a more specific shape wins:
/// `github_pat_` must be tried before `ghp_` would be, and `sk-ant-api03-`
/// before `sk-`.
const shapes = [_]Shape{
    .{ .kind = .anthropic_api_key, .prefix = "sk-ant-api", .min_len = 40, .max_len = 200 },
    .{ .kind = .anthropic_api_key, .prefix = "sk-ant-", .min_len = 30, .max_len = 200 },
    .{ .kind = .github_token, .prefix = "github_pat_", .min_len = 40, .max_len = 200 },
    .{ .kind = .openai_api_key, .prefix = "sk-proj-", .min_len = 40, .max_len = 200 },
    .{ .kind = .hugging_face_token, .prefix = "hf_", .min_len = 30, .max_len = 100 },
    .{ .kind = .github_token, .prefix = "ghp_", .min_len = 36, .max_len = 100 },
    .{ .kind = .github_token, .prefix = "gho_", .min_len = 36, .max_len = 100 },
    .{ .kind = .github_token, .prefix = "ghu_", .min_len = 36, .max_len = 100 },
    .{ .kind = .github_token, .prefix = "ghs_", .min_len = 36, .max_len = 100 },
    .{ .kind = .github_token, .prefix = "ghr_", .min_len = 36, .max_len = 100 },
    .{ .kind = .gitlab_token, .prefix = "glpat-", .min_len = 26, .max_len = 100 },
    .{ .kind = .slack_token, .prefix = "xoxb-", .min_len = 30, .max_len = 100 },
    .{ .kind = .slack_token, .prefix = "xoxp-", .min_len = 30, .max_len = 100 },
    .{ .kind = .slack_token, .prefix = "xoxa-", .min_len = 30, .max_len = 100 },
    .{ .kind = .slack_token, .prefix = "xapp-", .min_len = 30, .max_len = 100 },
    .{ .kind = .stripe_key, .prefix = "sk_live_", .min_len = 30, .max_len = 100 },
    .{ .kind = .stripe_key, .prefix = "rk_live_", .min_len = 30, .max_len = 100 },
    .{ .kind = .npm_token, .prefix = "npm_", .min_len = 30, .max_len = 100 },
    .{ .kind = .google_api_key, .prefix = "AIza", .min_len = 39, .max_len = 39 },
    .{ .kind = .aws_access_key_id, .prefix = "AKIA", .min_len = 20, .max_len = 20, .dashes = false },
    .{ .kind = .aws_access_key_id, .prefix = "ASIA", .min_len = 20, .max_len = 20, .dashes = false },
    .{ .kind = .openai_api_key, .prefix = "sk-", .min_len = 48, .max_len = 200 },
};

comptime {
    // The table is searched in order and the first match wins, so a shape whose
    // prefix is a prefix of an earlier one is unreachable. Catching that here
    // means a new entry added in the wrong place fails the build rather than
    // silently never matching.
    for (shapes, 0..) |shape, i| {
        for (shapes[0..i]) |earlier| {
            if (std.mem.startsWith(u8, shape.prefix, earlier.prefix)) {
                @compileError("credential shape '" ++ shape.prefix ++
                    "' is unreachable: '" ++ earlier.prefix ++ "' is listed before it and matches first");
            }
        }
    }
}

/// Variable names that say the value beside them is a credential.
///
/// Matched case-insensitively against the tail of the name, so `MY_APP_TOKEN`
/// and `token` both hit. `_id` and `_name` are excluded below, because
/// `client_id` and `key_name` are not secrets and redacting them loses a fact a
/// reader needs.
const secret_names = [_][]const u8{
    "api_key",       "apikey",        "api-key",     "secret",
    "password",      "passwd",        "token",       "auth",
    "authorization", "credential",    "private_key", "access_key",
    "session_key",   "client_secret", "bearer",      "passphrase",
    // With the separator attached, so that `SSH_KEY` and `SOME_OTHER_KEY`
    // match while `monkey` and a bare `key=` in a printed map do not.
    "_key",          "-key",
};

/// Names that end in one of the above but are not credentials.
///
/// Checked first and always winning. `client_id` and `client_secret` appear
/// together in every OAuth configuration there is, and a detector that cannot
/// tell them apart redacts the half a reader needs.
const not_secret_names = [_][]const u8{
    "client_id",   "key_id",   "token_type", "auth_type",
    "token_count", "author",   "authors",    "secret_name",
    "key_name",    "auth_url", "token_uri",  "password_hash",
};

/// How much a value may look like a word before the third pass lets it through.
///
/// Shannon entropy in bits per character. English prose sits near 3.0 and
/// `changeme` near 2.75; a random 32-character key sits above 4.5. The
/// threshold is set at 3.0 so that a real but short key still passes and a
/// placeholder like `your-key-here` does not.
pub const default_entropy_floor: f64 = 3.0;

/// How many of {lowercase, uppercase, digit} a value uses.
///
/// Entropy alone lets `your-api-key-here` through: seventeen characters of
/// English with three dashes carries about 3.3 bits, which is above any floor
/// low enough to still catch a real sixteen-character key. What separates them
/// is not how surprising the characters are but which *kinds* they are — a
/// generated credential mixes cases or includes digits, and a phrase does not.
fn characterClasses(text: []const u8) u8 {
    var lower = false;
    var upper = false;
    var digit = false;
    for (text) |byte| {
        if (std.ascii.isLower(byte)) lower = true;
        if (std.ascii.isUpper(byte)) upper = true;
        if (std.ascii.isDigit(byte)) digit = true;
    }
    return @as(u8, @intFromBool(lower)) + @intFromBool(upper) + @intFromBool(digit);
}

/// Settings for a scan. Named rather than positional because two of the three
/// are thresholds, and a threshold passed positionally is a bug waiting.
pub const Policy = struct {
    /// Bits per character a named value must carry to be treated as a secret.
    entropy_floor: f64 = default_entropy_floor,
    /// Shortest value the third pass will look at. Below this, entropy is not
    /// measurable in any meaningful way and the false-positive rate climbs.
    min_named_len: usize = 8,
    /// How many of {lowercase, uppercase, digit} a named value must use. Two
    /// is what separates a generated credential from a phrase somebody wrote.
    min_character_classes: u8 = 2,
    /// Whether to run the third pass at all. Off gives a detector that only
    /// ever reports things it recognised, which is the right setting when a
    /// false positive would be worse than a miss.
    infer_from_names: bool = true,
};

/// Shannon entropy of `text`, in bits per character.
///
/// Zero for an empty or single-repeated string, and log2(n) for a string of n
/// equally frequent distinct bytes — so 6 for well-spread base64 and about 4
/// for hex.
pub fn entropy(text: []const u8) f64 {
    if (text.len == 0) return 0;
    var counts = [_]u32{0} ** 256;
    for (text) |byte| counts[byte] += 1;

    const total: f64 = @floatFromInt(text.len);
    var bits: f64 = 0;
    for (counts) |count| {
        if (count == 0) continue;
        const p = @as(f64, @floatFromInt(count)) / total;
        bits -= p * @log2(p);
    }
    return bits;
}

/// Whether a byte can appear in the body of a credential token.
///
/// `=` is deliberately absent. It is base64 padding, so it belongs to a token —
/// but only at the end, and treating it as an interior byte makes `API_KEY=sk-…`
/// scan as a single token whose name and value cannot be told apart. Trailing
/// padding is picked up by `absorbPadding` instead, which can tell the two
/// cases apart because padding is never followed by more token bytes.
fn isTokenByte(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '+', '/' => true,
        else => false,
    };
}

/// Extend a token over trailing base64 padding, if that is what it is.
///
/// `Zm9v==` at the end of a line is one token with padding. The `=` in
/// `API_KEY=sk-ant-…` is not, and the difference is exactly whether more token
/// bytes follow: padding never has anything after it.
fn absorbPadding(text: []const u8, end: usize) usize {
    var index = end;
    while (index < text.len and text[index] == '=') index += 1;
    if (index == end) return end;
    if (index < text.len and isTokenByte(text[index])) return end;
    return index;
}

/// The end of the token starting at `from`, scanned a vector at a time.
///
/// Output is mostly not credentials, so the cost of this module is the cost of
/// walking past everything that is not one. Finding the end of a run of token
/// bytes is the inner loop of that walk.
fn tokenEnd(text: []const u8, from: usize) usize {
    var index = from;
    if (scan_mod.width) |lanes| {
        const Chunk = @Vector(lanes, u8);
        while (index + lanes <= text.len) {
            const chunk: Chunk = text[index..][0..lanes].*;
            // Token bytes are a union of ranges, so the test is a handful of
            // comparisons per vector rather than a table lookup, which has no
            // portable vector form.
            const upper = (chunk >= @as(Chunk, @splat('A'))) & (chunk <= @as(Chunk, @splat('Z')));
            const lower = (chunk >= @as(Chunk, @splat('a'))) & (chunk <= @as(Chunk, @splat('z')));
            const digit = (chunk >= @as(Chunk, @splat('0'))) & (chunk <= @as(Chunk, @splat('9')));
            var ok = upper | lower | digit;
            inline for ([_]u8{ '-', '_', '.', '~', '+', '/' }) |extra| {
                ok = ok | (chunk == @as(Chunk, @splat(extra)));
            }
            if (!@reduce(.And, ok)) break;
            index += lanes;
        }
    }
    while (index < text.len and isTokenByte(text[index])) index += 1;
    return index;
}

/// The plain version of `tokenEnd`, kept beside it and checked against it.
fn tokenEndSlow(text: []const u8, from: usize) usize {
    var index = from;
    while (index < text.len and isTokenByte(text[index])) index += 1;
    return index;
}

/// Whether the token at `[start, end)` is bounded by non-token bytes.
///
/// Without this a scan would match `sk-ant-` in the middle of a longer run and
/// report a fragment, and a redaction of a fragment leaves the rest of the key
/// in the record — worse than not redacting at all, because it looks handled.
fn isWholeToken(text: []const u8, start: usize, end: usize) bool {
    if (start > 0 and isTokenByte(text[start - 1])) return false;
    if (end < text.len and isTokenByte(text[end])) return false;
    return true;
}

/// Whether `name` is one of the names that mean "credential".
///
/// The tail is compared, so a prefix a project invents (`ZAG_`, `MY_APP_`) does
/// not have to be listed. The exclusions are checked first and win, because
/// `client_id` ends in nothing secret but `client_secret` does, and the pair
/// appear together in every OAuth configuration on earth.
pub fn nameSaysSecret(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (not_secret_names) |exclusion| {
        if (endsWithFold(name, exclusion)) return false;
    }
    for (secret_names) |marker| {
        // Either end. A project's own prefix goes on the front
        // (`ZAG_API_KEY`), and a header's qualifier goes on the back
        // (`Authorization`), and both name a credential.
        if (endsWithFold(name, marker) or startsWithFold(name, marker)) return true;
    }
    return false;
}

fn startsWithFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (haystack[0..needle.len], needle) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn endsWithFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const tail = haystack[haystack.len - needle.len ..];
    for (tail, needle) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

/// The name immediately before `at`, if the text there reads like an
/// assignment.
///
/// Handles the three shapes that carry credentials in practice: a shell or
/// dotenv assignment (`API_KEY=value`), a JSON member (`"api_key": "value"`),
/// and a header or YAML mapping (`Authorization: value`). Whitespace and one
/// optional quote are stepped over on each side.
fn nameBefore(text: []const u8, at: usize) ?[]const u8 {
    var index = at;
    // Step back over an opening quote around the value.
    if (index > 0 and (text[index - 1] == '"' or text[index - 1] == '\'')) index -= 1;
    while (index > 0 and (text[index - 1] == ' ' or text[index - 1] == '\t')) index -= 1;
    if (index == 0) return null;
    const separator = text[index - 1];
    if (separator != '=' and separator != ':') return null;
    index -= 1;
    while (index > 0 and (text[index - 1] == ' ' or text[index - 1] == '\t')) index -= 1;
    // Step back over a closing quote around the name.
    if (index > 0 and (text[index - 1] == '"' or text[index - 1] == '\'')) index -= 1;
    const name_end = index;
    while (index > 0 and (std.ascii.isAlphanumeric(text[index - 1]) or
        text[index - 1] == '_' or text[index - 1] == '-')) index -= 1;
    if (index == name_end) return null;
    return text[index..name_end];
}

const pem_header = "-----BEGIN ";
const pem_footer = "-----END ";

/// Find every credential in `text`.
///
/// Findings come back in the order they appear and never overlap: an earlier
/// finding always ends before a later one starts, which is what lets the
/// redactor rewrite the text in one pass.
pub fn scan(arena: std.mem.Allocator, text: []const u8, policy: Policy) ![]const Finding {
    var found: std.ArrayList(Finding) = .empty;

    var index: usize = 0;
    while (index < text.len) {
        // Pass one: a delimited block announces itself, and swallows whatever
        // the other passes would have found inside it.
        if (text.len - index >= pem_header.len and
            std.mem.startsWith(u8, text[index..], pem_header) and
            lineContains(text, index, "PRIVATE KEY"))
        {
            const end = pemBlockEnd(text, index);
            try found.append(arena, .{ .kind = .private_key_block, .start = index, .end = end });
            index = end;
            continue;
        }

        // Pass one, second shape: credentials inside a URL. Found by the `://`
        // rather than by the scheme, so it catches every protocol at once.
        if (std.mem.startsWith(u8, text[index..], "://")) {
            if (urlCredentials(text, index)) |span| {
                try found.append(arena, .{ .kind = .url_credentials, .start = span.start, .end = span.end });
                index = span.end;
                continue;
            }
        }

        if (!isTokenByte(text[index])) {
            index += 1;
            continue;
        }

        // The whole token, once. Every remaining test is against this slice, so
        // the scan touches each byte a constant number of times.
        const end = absorbPadding(text, tokenEnd(text, index));
        const token = text[index..end];
        if (!isWholeToken(text, index, end)) {
            index = end;
            continue;
        }

        if (classify(token)) |kind| {
            try found.append(arena, .{ .kind = kind, .start = index, .end = end });
            index = end;
            continue;
        }

        // Pass three: the value is not a shape anybody publishes, but the thing
        // it was assigned to calls itself a secret, and it carries the entropy
        // of a key rather than of a word.
        if (policy.infer_from_names and token.len >= policy.min_named_len) {
            if (nameBefore(text, index)) |name| {
                if (nameSaysSecret(name) and
                    characterClasses(token) >= policy.min_character_classes and
                    entropy(token) >= policy.entropy_floor)
                {
                    try found.append(arena, .{ .kind = .named_secret, .start = index, .end = end });
                    index = end;
                    continue;
                }
            }
        }

        index = end;
    }

    return found.items;
}

/// Which published shape a token matches, if any.
pub fn classify(token: []const u8) ?Kind {
    for (shapes) |shape| {
        if (!std.mem.startsWith(u8, token, shape.prefix)) continue;
        if (token.len < shape.min_len or token.len > shape.max_len) continue;
        const body = token[shape.prefix.len..];
        if (!bodyMatches(body, shape.dashes)) continue;
        return shape.kind;
    }
    // A JSON Web Token is three base64url segments separated by dots, and the
    // first one always decodes to a JSON object beginning `{"`, which is why
    // every JWT on earth starts `eyJ`. That is a shape, not a guess.
    if (std.mem.startsWith(u8, token, "eyJ") and std.mem.count(u8, token, ".") == 2 and token.len >= 40) {
        return .json_web_token;
    }
    // An AWS secret access key has no prefix — it is 40 characters of base64
    // and nothing else. On its own that is far too weak to act on, so it is
    // only reported when the name beside it says what it is, which `scan`
    // handles through the named pass. Left here as the reason there is no
    // prefix entry for it in the table.
    return null;
}

fn bodyMatches(body: []const u8, dashes: bool) bool {
    for (body) |byte| {
        const ok = switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9' => true,
            '-', '_' => dashes,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

fn lineContains(text: []const u8, from: usize, needle: []const u8) bool {
    const line_end = std.mem.indexOfScalarPos(u8, text, from, '\n') orelse text.len;
    return std.mem.indexOf(u8, text[from..line_end], needle) != null;
}

/// The end of a PEM block, or the end of the text when the footer is missing.
///
/// A truncated key is still a key, and output that was cut off mid-block is
/// exactly the case where a naive scanner gives up and writes the body down.
fn pemBlockEnd(text: []const u8, start: usize) usize {
    const footer_at = std.mem.indexOfPos(u8, text, start, pem_footer) orelse return text.len;
    const line_end = std.mem.indexOfScalarPos(u8, text, footer_at, '\n') orelse text.len;
    return line_end;
}

const Span = struct { start: usize, end: usize };

/// The `user:password` in `scheme://user:password@host`, if there is one.
///
/// Only the credentials are returned, so the host survives the redaction and a
/// reader can still see where a request went — which is usually the fact they
/// need and never the secret.
fn urlCredentials(text: []const u8, at_separator: usize) ?Span {
    const start = at_separator + 3;
    if (start >= text.len) return null;
    var index = start;
    var colon: ?usize = null;
    while (index < text.len) : (index += 1) {
        switch (text[index]) {
            '@' => break,
            ':' => if (colon == null) {
                colon = index;
            },
            '/', '?', '#', ' ', '\t', '\r', '\n', '"', '\'' => return null,
            else => {},
        }
    } else return null;
    // `host:port` with no `@` is not credentials, and `@` with no `:` is a
    // username with no password, which is not a secret either.
    if (colon == null) return null;
    if (index == start) return null;
    return .{ .start = start, .end = index };
}

/// Rewrites text with every credential replaced by a placeholder.
///
/// Holds a salt for the lifetime of the redactor, so fingerprints are
/// comparable across everything one redactor rewrites and meaningless anywhere
/// else. Make one per session and keep it.
pub const Redactor = struct {
    policy: Policy = .{},
    salt: [16]u8,

    /// A redactor whose fingerprints nobody outside this process can reproduce.
    pub fn init(io: std.Io) !Redactor {
        var salt: [16]u8 = undefined;
        try io.randomSecure(&salt);
        return .{ .salt = salt };
    }

    /// A redactor with a stated salt, for tests and for the rare case where two
    /// processes must agree on fingerprints. Anything using this is choosing to
    /// give up the property that the fingerprints resist a guessing attack.
    pub fn withSalt(salt: [16]u8) Redactor {
        return .{ .salt = salt };
    }

    /// Four hex digits identifying a secret without revealing it.
    pub fn fingerprint(self: Redactor, secret: []const u8) [4]u8 {
        const digest = hashing.Hash.ofParts(&.{ &self.salt, secret });
        var out: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&out, "{x:0>2}{x:0>2}", .{ digest.bytes[0], digest.bytes[1] }) catch unreachable;
        return out;
    }

    /// Rewrite `text`, returning the redacted copy and what was taken out.
    ///
    /// The original is never written anywhere by this function. A caller that
    /// keeps it is choosing to, and the one caller that does — the terminal, so
    /// that the person watching sees their own screen unchanged — keeps it in
    /// memory and never hands it to the log.
    pub fn rewrite(self: Redactor, arena: std.mem.Allocator, text: []const u8) !Result {
        const findings = try scan(arena, text, self.policy);
        if (findings.len == 0) return .{ .text = text, .findings = findings };

        var out: std.ArrayList(u8) = .empty;
        var cursor: usize = 0;
        for (findings) |finding| {
            try out.appendSlice(arena, text[cursor..finding.start]);
            try out.appendSlice(arena, "[redacted ");
            try out.appendSlice(arena, finding.kind.text());
            try out.append(arena, ' ');
            const print = self.fingerprint(text[finding.start..finding.end]);
            try out.appendSlice(arena, &print);
            try out.append(arena, ']');
            cursor = finding.end;
        }
        try out.appendSlice(arena, text[cursor..]);
        return .{ .text = out.items, .findings = findings };
    }

    /// Whether `text` contains anything this redactor would remove.
    ///
    /// Cheaper than rewriting when the answer is only needed as a yes or no —
    /// refusing to send a prompt, for instance.
    pub fn detects(self: Redactor, arena: std.mem.Allocator, text: []const u8) !bool {
        const findings = try scan(arena, text, self.policy);
        return findings.len > 0;
    }
};

/// What a rewrite produced.
pub const Result = struct {
    /// The redacted text. Identical to the input, and the same slice, when
    /// nothing was found — so the common case allocates nothing.
    text: []const u8,
    findings: []const Finding,

    pub fn changed(self: Result) bool {
        return self.findings.len > 0;
    }

    /// How many of each kind, for a report that says what was removed without
    /// listing where.
    pub fn countOf(self: Result, kind: Kind) usize {
        var total: usize = 0;
        for (self.findings) |finding| {
            if (finding.kind == kind) total += 1;
        }
        return total;
    }
};

const testing = std.testing;

/// A fixed salt, so that the expected placeholders in these tests are stable.
/// Real use draws one from the operating system.
const test_salt = [_]u8{0xA5} ** 16;

test "a published prefix is recognised without any threshold" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { text: []const u8, kind: Kind }{
        .{ .text = "sk-ant-api03-" ++ "a" ** 40, .kind = .anthropic_api_key },
        .{ .text = "ghp_" ++ "b" ** 36, .kind = .github_token },
        .{ .text = "github_pat_" ++ "c" ** 40, .kind = .github_token },
        .{ .text = "glpat-" ++ "d" ** 20, .kind = .gitlab_token },
        .{ .text = "xoxb-" ++ "1234567890-1234567890-abcdefghijklmno", .kind = .slack_token },
        .{ .text = "AKIAIOSFODNN7EXAMPLE", .kind = .aws_access_key_id },
        .{ .text = "AIza" ++ "e" ** 35, .kind = .google_api_key },
        .{ .text = "hf_" ++ "f" ** 34, .kind = .hugging_face_token },
        .{ .text = "npm_" ++ "g" ** 36, .kind = .npm_token },
        .{ .text = "sk_live_" ++ "h" ** 24, .kind = .stripe_key },
        .{ .text = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk", .kind = .json_web_token },
    };

    for (cases) |case| {
        // The lowest possible entropy body: one repeated character. A detector
        // that leaned on entropy would miss every one of these, which is the
        // reason the recognised pass has no entropy test in it.
        const findings = try scan(arena, case.text, .{});
        try testing.expectEqual(@as(usize, 1), findings.len);
        try testing.expectEqual(case.kind, findings[0].kind);
        try testing.expectEqual(@as(usize, 0), findings[0].start);
        try testing.expectEqual(case.text.len, findings[0].end);
        try testing.expectEqual(Certainty.recognised, findings[0].kind.certainty());
    }
}

test "a key is found in the middle of a line and the line survives" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = "export ANTHROPIC_API_KEY=sk-ant-api03-" ++ "z" ** 40 ++ " # for the build";
    const redactor = Redactor.withSalt(test_salt);
    const result = try redactor.rewrite(arena, line);

    try testing.expect(result.changed());
    // The variable name and the comment are still there. The value is not.
    try testing.expect(std.mem.startsWith(u8, result.text, "export ANTHROPIC_API_KEY="));
    try testing.expect(std.mem.endsWith(u8, result.text, " # for the build"));
    try testing.expect(std.mem.indexOf(u8, result.text, "sk-ant") == null);
    try testing.expect(std.mem.indexOf(u8, result.text, "[redacted anthropic-api-key ") != null);
}

test "the same secret twice reads as one secret, and two secrets never merge" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const redactor = Redactor.withSalt(test_salt);
    const one = "ghp_" ++ "1" ** 36;
    const other = "ghp_" ++ "2" ** 36;

    const same = redactor.fingerprint(one);
    try testing.expectEqualSlices(u8, &same, &redactor.fingerprint(one));
    try testing.expect(!std.mem.eql(u8, &same, &redactor.fingerprint(other)));

    // And in a rewrite: the reader can see the deploy key and the build key are
    // different keys without either of them being in the record.
    const text = "deploy=" ++ one ++ "\nbuild=" ++ one ++ "\nother=" ++ other ++ "\n";
    const result = try redactor.rewrite(arena, text);
    try testing.expectEqual(@as(usize, 3), result.findings.len);

    var lines = std.mem.splitScalar(u8, result.text, '\n');
    const deploy = lines.next().?;
    const build = lines.next().?;
    const third = lines.next().?;
    try testing.expectEqualStrings(deploy["deploy=".len..], build["build=".len..]);
    try testing.expect(!std.mem.eql(u8, deploy["deploy=".len..], third["other=".len..]));
}

test "a different salt gives different fingerprints for the same secret" {
    // This is the property that stops a fingerprint being a guessing oracle. If
    // it ever fails, the salt has stopped being mixed in and anybody holding a
    // record can brute-force short secrets back out of it.
    const secret = "ghp_" ++ "9" ** 36;
    const here = Redactor.withSalt(test_salt);
    const elsewhere = Redactor.withSalt([_]u8{0x11} ** 16);
    try testing.expect(!std.mem.eql(u8, &here.fingerprint(secret), &elsewhere.fingerprint(secret)));
}

test "a private key block goes entirely, footer included" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\Loading identity.
        \\-----BEGIN OPENSSH PRIVATE KEY-----
        \\b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABlwAAAAdzc2gt
        \\cnNhAAAAAwEAAQAAAYEAvbGkfyGhLNQxAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        \\-----END OPENSSH PRIVATE KEY-----
        \\Done.
    ;
    const redactor = Redactor.withSalt(test_salt);
    const result = try redactor.rewrite(arena, text);

    try testing.expectEqual(@as(usize, 1), result.findings.len);
    try testing.expectEqual(Kind.private_key_block, result.findings[0].kind);
    try testing.expect(std.mem.indexOf(u8, result.text, "BEGIN") == null);
    try testing.expect(std.mem.indexOf(u8, result.text, "END") == null);
    try testing.expect(std.mem.indexOf(u8, result.text, "b3BlbnNz") == null);
    // The text around it is untouched, so the record still says what was
    // happening when the key appeared.
    try testing.expect(std.mem.startsWith(u8, result.text, "Loading identity.\n"));
    try testing.expect(std.mem.endsWith(u8, result.text, "\nDone."));
}

test "a private key cut off mid-block is still removed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Output truncated by a buffer limit is exactly where a scanner that
    // insists on finding the footer writes the body into the record.
    const text = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAxLotOfB7Zk\n";
    const result = try Redactor.withSalt(test_salt).rewrite(arena, text);
    try testing.expectEqual(@as(usize, 1), result.findings.len);
    try testing.expect(std.mem.indexOf(u8, result.text, "MIIEow") == null);
}

test "a public key block is left alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Publishing a public key is the entire point of a public key. Redacting it
    // would break the one workflow it exists for.
    const text = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj\n-----END PUBLIC KEY-----\n";
    const result = try Redactor.withSalt(test_salt).rewrite(arena, text);
    try testing.expectEqual(@as(usize, 0), result.findings.len);
    try testing.expectEqualStrings(text, result.text);
}

test "credentials come out of a URL and the host stays in" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "fatal: could not read from https://deploy:hunter2@git.example.com/repo.git";
    const result = try Redactor.withSalt(test_salt).rewrite(arena, text);

    try testing.expectEqual(@as(usize, 1), result.findings.len);
    try testing.expectEqual(Kind.url_credentials, result.findings[0].kind);
    try testing.expect(std.mem.indexOf(u8, result.text, "hunter2") == null);
    // The host is the fact somebody debugging this needs, and it is not secret.
    try testing.expect(std.mem.indexOf(u8, result.text, "git.example.com/repo.git") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "https://") != null);
}

test "a host and port is not a credential" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        "connecting to http://localhost:8080/health",
        "see https://example.com:443/",
        "redis://cache:6379",
    }) |text| {
        const result = try Redactor.withSalt(test_salt).rewrite(arena, text);
        try testing.expectEqualStrings(text, result.text);
    }
}

test "an unknown provider's key is caught by the name beside it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // None of these prefixes are in the table, and they never will be. The
    // third pass is the only reason they are found.
    const cases = [_][]const u8{
        "ACME_API_KEY=Xq7pLm2vNc9wTr4yUi8oPa3sDf6gHj1k",
        "{\"client_secret\": \"Zb5nQw8xEr2tYu4iOp6aSd9fGh3jKl7m\"}",
        "Authorization: Vc3xZm9pQr5tYw8nBd2fGk6hJl4sAe7u",
        "db_password: Rt6yUj3mNb8vCx5zAq9wEr2tYu4iOp7a",
    };

    for (cases) |text| {
        const result = try Redactor.withSalt(test_salt).rewrite(arena, text);
        try testing.expectEqual(@as(usize, 1), result.findings.len);
        try testing.expectEqual(Kind.named_secret, result.findings[0].kind);
        try testing.expectEqual(Certainty.inferred, result.findings[0].kind.certainty());
    }
}

test "the things a build prints every day are not redacted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // This is the test that decides whether the feature is usable. A detector
    // that fires on any of these makes every record unreadable, and a record
    // nobody reads protects nobody. Each line here is high-entropy text that a
    // person needs to be able to see.
    const ordinary = [_][]const u8{
        "commit 4f9d3c2b1a8e7f6d5c4b3a29180706f5e4d3c2b1",
        "b3:61fb3f606aa922085ed5fa6f7346c2179842222a31e2bd2f2461902f5c98a290",
        "evt_01M16HNP3VTQEZCJATF659CD62",
        "sha256-Xq7pLm2vNc9wTr4yUi8oPa3sDf6gHj1kZb5nQw8xEr2=",
        "id: 550e8400-e29b-41d4-a716-446655440000",
        "  at /home/user/zag/src/ai/transport.zig:412:19",
        "docker.io/library/alpine@sha256:c5b1261d6d3e43071626931fc004f70149baeba2c8ec672bd4a27504f8ab1abd",
        "client_id=1084729384756-a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6",
        "token_count: 918273645",
        "password_hash=$2b$12$KIXQJ8bV3sRz1lYqQoT8ue",
        "Compiling regex v1.10.2 (a3f8e91c4d7b2065)",
    };

    for (ordinary) |text| {
        const result = try Redactor.withSalt(test_salt).rewrite(arena, text);
        if (result.changed()) {
            std.debug.print("false positive on: {s}\n  -> {s}\n", .{ text, result.text });
        }
        try testing.expectEqual(@as(usize, 0), result.findings.len);
        try testing.expectEqualStrings(text, result.text);
    }
}

test "a placeholder is not mistaken for a key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Documentation and templates are full of these. Redacting them turns a
    // README into noise and teaches people to ignore the redaction.
    for ([_][]const u8{
        "API_KEY=your-api-key-here",
        "password: changeme",
        "TOKEN=xxxxxxxxxxxxxxxxxxxx",
        "secret: <your secret>",
        "api_key = REPLACE_ME",
    }) |text| {
        const result = try Redactor.withSalt(test_salt).rewrite(arena, text);
        try testing.expectEqualStrings(text, result.text);
    }
}

test "entropy separates a key from a word" {
    // The numbers the third pass is tuned against, pinned so that a change to
    // the threshold has to argue with them.
    try testing.expect(entropy("changeme") < 3.0);
    try testing.expect(entropy("your-api-key-here") < 3.5);
    try testing.expect(entropy("xxxxxxxxxxxxxxxxxxxx") < 1.0);
    try testing.expect(entropy("Xq7pLm2vNc9wTr4yUi8oPa3sDf6gHj1k") > 4.5);
    try testing.expectEqual(@as(f64, 0), entropy(""));
    try testing.expectEqual(@as(f64, 0), entropy("aaaa"));
    // Two equally frequent bytes is exactly one bit.
    try testing.expectApproxEqAbs(@as(f64, 1), entropy("abab"), 1e-12);
}

test "a fragment of a key is never reported, because half a redaction is worse than none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // If the scanner matched a prefix anywhere rather than at a token boundary,
    // it would report the tail of this and leave the head in the record.
    const text = "notasecretghp_" ++ "k" ** 36;
    const result = try Redactor.withSalt(test_salt).rewrite(arena, text);
    try testing.expectEqual(@as(usize, 0), result.findings.len);
}

test "several secrets in one document all go, in order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n" ++
        "ANTHROPIC_API_KEY=sk-ant-api03-" ++ "q" ** 40 ++ "\n" ++
        "git remote add origin https://ci:sV8xQm2pLr6tYw9n@git.example.com/x.git\n" ++
        "SOME_OTHER_KEY=Kp4mZx8qWe2rTy6uIo9aSd3fGh7jLn5b\n";

    const result = try Redactor.withSalt(test_salt).rewrite(arena, text);
    try testing.expectEqual(@as(usize, 4), result.findings.len);
    try testing.expectEqual(Kind.aws_access_key_id, result.findings[0].kind);
    try testing.expectEqual(Kind.anthropic_api_key, result.findings[1].kind);
    try testing.expectEqual(Kind.url_credentials, result.findings[2].kind);
    try testing.expectEqual(Kind.named_secret, result.findings[3].kind);

    // Findings never overlap and are in order, which is what lets the rewrite
    // be one pass.
    var previous: usize = 0;
    for (result.findings) |finding| {
        try testing.expect(finding.start >= previous);
        try testing.expect(finding.end > finding.start);
        previous = finding.end;
    }

    try testing.expectEqual(@as(usize, 1), result.countOf(.url_credentials));
    try testing.expect(std.mem.indexOf(u8, result.text, "AKIA") == null);
    try testing.expect(std.mem.indexOf(u8, result.text, "sk-ant") == null);
    try testing.expect(std.mem.indexOf(u8, result.text, "sV8xQm2pLr6tYw9n") == null);
    try testing.expect(std.mem.indexOf(u8, result.text, "Kp4mZx8qWe2rTy6uIo9aSd3fGh7jLn5b") == null);
}

test "clean text is returned as the same slice, so the common case allocates nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "All 513 tests passed.\n";
    const result = try Redactor.withSalt(test_salt).rewrite(arena, text);
    try testing.expect(result.text.ptr == text.ptr);
}

test "the vectorised token scan agrees with the plain one at every length and offset" {
    // The tail of a vectorised scan is where this kind of code is wrong, and it
    // is wrong at exactly one length in a way no hand-written example finds.
    var prng = std.Random.DefaultPrng.init(0x5EC2E7);
    const random = prng.random();

    var buffer: [512]u8 = undefined;
    const alphabet = "abcXYZ019-_./+= \t\n!@#$%^&*(){}[]|;'\",<>?:";
    for (0..400) |_| {
        for (&buffer) |*byte| byte.* = alphabet[random.intRangeLessThan(usize, 0, alphabet.len)];
        var length: usize = 0;
        while (length <= buffer.len) : (length += 1) {
            const text = buffer[0..length];
            for (0..length) |from| {
                try testing.expectEqual(tokenEndSlow(text, from), tokenEnd(text, from));
            }
            // Lengths near a vector boundary are where it breaks; the rest is
            // covered by sampling so the test stays fast.
            if (length > 80) length += 37;
        }
    }
}

test "a name that says secret is told from one that only sounds like it" {
    try testing.expect(nameSaysSecret("api_key"));
    try testing.expect(nameSaysSecret("API_KEY"));
    try testing.expect(nameSaysSecret("MY_APP_TOKEN"));
    try testing.expect(nameSaysSecret("client_secret"));
    try testing.expect(nameSaysSecret("db-password"));

    // The pair that appears together in every OAuth configuration on earth. One
    // is a secret and one is published, and a detector that cannot tell them
    // apart redacts the half people need.
    try testing.expect(!nameSaysSecret("client_id"));
    try testing.expect(!nameSaysSecret("key_id"));
    try testing.expect(!nameSaysSecret("token_type"));
    try testing.expect(!nameSaysSecret("password_hash"));
    try testing.expect(!nameSaysSecret("username"));
    try testing.expect(!nameSaysSecret(""));
}

test "the detector can be told to report only what it recognises" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "MY_KEY=Xq7pLm2vNc9wTr4yUi8oPa3sDf6gHj1k and ghp_" ++ "m" ** 36;
    const strict: Policy = .{ .infer_from_names = false };

    const inferring = try scan(arena, text, .{});
    try testing.expectEqual(@as(usize, 2), inferring.len);

    // With inference off, only the published shape is reported — the setting
    // for a deployment where a false positive costs more than a miss.
    const recognising = try scan(arena, text, strict);
    try testing.expectEqual(@as(usize, 1), recognising.len);
    try testing.expectEqual(Kind.github_token, recognising[0].kind);
}

test "detects answers yes or no without building the rewritten copy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const redactor = Redactor.withSalt(test_salt);
    try testing.expect(try redactor.detects(arena, "key=ghp_" ++ "n" ** 36));
    try testing.expect(!try redactor.detects(arena, "nothing to see here"));
}

test "every kind names itself, and no two kinds share a name" {
    // The placeholder is the only thing a reader gets, so a kind with no words
    // or a duplicate name would make the record ambiguous about what was taken.
    for (std.enums.values(Kind)) |kind| {
        try testing.expect(kind.text().len > 0);
        for (std.enums.values(Kind)) |other| {
            if (kind == other) continue;
            try testing.expect(!std.mem.eql(u8, kind.text(), other.text()));
        }
    }
}
