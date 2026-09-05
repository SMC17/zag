//! Typed identifiers.
//!
//! Every durable object gets a 128-bit, lexicographically sortable identifier
//! (48-bit millisecond timestamp + 80 random bits, Crockford base32). Sortable
//! identifiers matter here because the event log, the block graph and the
//! records ledger are all append-ordered.
//!
//! Identifiers are *typed at compile time*: a `BlockId` cannot be passed where
//! a `SessionId` is expected. This is the cheapest available defence against
//! the class of bug where a subsystem quietly stores the wrong reference, which
//! ISO/IEC 11179 identification rules are meant to prevent at the data level.

const std = @import("std");

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub const Raw = struct {
    bytes: [16]u8,

    pub const text_len = 26;

    pub fn generate(random: std.Random, unix_ms: i64) Raw {
        var r: Raw = undefined;
        const ms: u64 = @bitCast(unix_ms);
        r.bytes[0] = @truncate(ms >> 40);
        r.bytes[1] = @truncate(ms >> 32);
        r.bytes[2] = @truncate(ms >> 24);
        r.bytes[3] = @truncate(ms >> 16);
        r.bytes[4] = @truncate(ms >> 8);
        r.bytes[5] = @truncate(ms);
        random.bytes(r.bytes[6..]);
        return r;
    }

    pub fn timestampMillis(self: Raw) i64 {
        var ms: u64 = 0;
        for (self.bytes[0..6]) |b| ms = (ms << 8) | b;
        return @intCast(ms);
    }

    pub fn toText(self: Raw, buf: *[text_len]u8) []const u8 {
        var value: u128 = 0;
        for (self.bytes) |b| value = (value << 8) | b;
        var i: usize = text_len;
        while (i > 0) {
            i -= 1;
            buf[i] = crockford[@intCast(value & 0x1f)];
            value >>= 5;
        }
        return buf[0..];
    }

    pub fn parse(text: []const u8) error{InvalidId}!Raw {
        if (text.len != text_len) return error.InvalidId;
        var value: u128 = 0;
        for (text) |c| {
            const digit = decodeChar(c) orelse return error.InvalidId;
            value = (value << 5) | digit;
        }
        var r: Raw = undefined;
        var i: usize = 16;
        while (i > 0) {
            i -= 1;
            r.bytes[i] = @truncate(value);
            value >>= 8;
        }
        return r;
    }

    fn decodeChar(c: u8) ?u8 {
        const upper = std.ascii.toUpper(c);
        // Crockford base32 treats I/L as 1 and O as 0 to survive transcription.
        return switch (upper) {
            '0', 'O' => 0,
            '1', 'I', 'L' => 1,
            else => for (crockford, 0..) |candidate, idx| {
                if (candidate == upper) break @intCast(idx);
            } else null,
        };
    }

    pub fn order(a: Raw, b: Raw) std.math.Order {
        return std.mem.order(u8, &a.bytes, &b.bytes);
    }

    pub fn eql(a: Raw, b: Raw) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

/// Build a distinct identifier type with a human-readable prefix.
pub fn TypedId(comptime prefix: []const u8) type {
    return struct {
        const Self = @This();

        raw: Raw,

        pub const id_prefix = prefix;
        pub const text_len = prefix.len + 1 + Raw.text_len;

        pub fn generate(random: std.Random, unix_ms: i64) Self {
            return .{ .raw = Raw.generate(random, unix_ms) };
        }

        pub fn fromRaw(raw: Raw) Self {
            return .{ .raw = raw };
        }

        pub fn timestampMillis(self: Self) i64 {
            return self.raw.timestampMillis();
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.raw.eql(b.raw);
        }

        pub fn order(a: Self, b: Self) std.math.Order {
            return Raw.order(a.raw, b.raw);
        }

        pub fn toText(self: Self, buf: *[text_len]u8) []const u8 {
            @memcpy(buf[0..prefix.len], prefix);
            buf[prefix.len] = '_';
            var body: [Raw.text_len]u8 = undefined;
            @memcpy(buf[prefix.len + 1 ..], self.raw.toText(&body));
            return buf[0..];
        }

        pub fn parse(text: []const u8) error{InvalidId}!Self {
            if (text.len != text_len) return error.InvalidId;
            if (!std.mem.eql(u8, text[0..prefix.len], prefix)) return error.InvalidId;
            if (text[prefix.len] != '_') return error.InvalidId;
            return .{ .raw = try Raw.parse(text[prefix.len + 1 ..]) };
        }

        pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            var buf: [text_len]u8 = undefined;
            try w.writeAll(self.toText(&buf));
        }

        pub fn jsonStringify(self: Self, jw: *std.json.Stringify) !void {
            var buf: [text_len]u8 = undefined;
            try jw.write(self.toText(&buf));
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Self {
            const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            const slice = switch (token) {
                inline .string, .allocated_string => |s| s,
                else => return error.UnexpectedToken,
            };
            return parse(slice) catch error.InvalidCharacter;
        }
    };
}

pub const EventId = TypedId("evt");
pub const BlockId = TypedId("blk");
pub const SessionId = TypedId("ses");
pub const ActorId = TypedId("act");
pub const AgentId = TypedId("agt");
pub const ArtifactId = TypedId("art");
pub const ConceptId = TypedId("cpt");
pub const RequirementId = TypedId("req");
pub const EvidenceId = TypedId("evd");
pub const RecordId = TypedId("rec");
pub const DatasetId = TypedId("dst");
pub const PolicyId = TypedId("pol");
pub const DecisionId = TypedId("dec");
pub const RiskId = TypedId("rsk");
pub const TaskId = TypedId("tsk");
pub const ToolCallId = TypedId("tcl");
pub const MetricId = TypedId("met");

/// Deterministic identifier source. Tests and replays need reproducible
/// identifiers; production uses a seeded cryptographic source.
pub const Generator = struct {
    prng: std.Random.DefaultPrng,
    clock_ms: i64,
    step_ms: i64,

    pub fn init(seed: u64, start_ms: i64) Generator {
        return .{ .prng = std.Random.DefaultPrng.init(seed), .clock_ms = start_ms, .step_ms = 1 };
    }

    pub fn next(self: *Generator, comptime T: type) T {
        const id = T.generate(self.prng.random(), self.clock_ms);
        self.clock_ms += self.step_ms;
        return id;
    }
};

test "identifier text round trip" {
    var gen: Generator = .init(7, 1_788_000_000_000);
    const a = gen.next(BlockId);
    var buf: [BlockId.text_len]u8 = undefined;
    const text = a.toText(&buf);
    try std.testing.expect(std.mem.startsWith(u8, text, "blk_"));
    const back = try BlockId.parse(text);
    try std.testing.expect(a.eql(back));
}

test "identifiers sort by creation time" {
    var gen: Generator = .init(11, 1_788_000_000_000);
    const first = gen.next(EventId);
    const second = gen.next(EventId);
    try std.testing.expectEqual(std.math.Order.lt, EventId.order(first, second));
    try std.testing.expectEqual(@as(i64, 1_788_000_000_000), first.timestampMillis());
}

test "identifier types do not mix" {
    var gen: Generator = .init(3, 1_788_000_000_000);
    const block = gen.next(BlockId);
    var buf: [BlockId.text_len]u8 = undefined;
    try std.testing.expectError(error.InvalidId, SessionId.parse(block.toText(&buf)));
}

test "identifiers round trip through json" {
    const gpa = std.testing.allocator;
    var gen: Generator = .init(21, 1_788_000_000_000);
    const Holder = struct { block: BlockId, session: SessionId };
    const original: Holder = .{ .block = gen.next(BlockId), .session = gen.next(SessionId) };

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(original, .{}, &aw.writer);

    const parsed = try std.json.parseFromSlice(Holder, gpa, aw.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(original.block.eql(parsed.value.block));
    try std.testing.expect(original.session.eql(parsed.value.session));
}
