//! Finding recorded work without reading all of it.
//!
//! `zag history` answers a query by walking every block and asking each one
//! whether it matches. That is the right first version — it is obviously
//! correct, and correctness is what a record is for — and it is linear in the
//! whole history. Twenty thousand blocks took three milliseconds a query on the
//! machine this was written on, which is fine, and a hundred times that many
//! would not be.
//!
//! ## The index never changes an answer
//!
//! This is the constraint everything here is built around. An index that
//! returns *nearly* the same results as the scan is worse than no index: a
//! person searching their own record for a command they know they ran, and not
//! finding it, has been told something false about their own history.
//!
//! So the index does not answer queries. It narrows the set of blocks worth
//! asking, and the same matcher that answered before answers again, on the
//! survivors. Whatever the index gets wrong can only be a *candidate* that
//! turns out not to match — never a match that was skipped. There is a test
//! that runs several hundred pseudo-random queries through both paths and
//! asserts the results are identical, block for block, in order.
//!
//! ## Why the text index is over tokens and the query is not
//!
//! A word in a query matches anywhere in a command: `hist` finds
//! `zag history`. A plain token index cannot answer that, and changing the
//! query language to make the index easy would be the tail wagging the dog.
//!
//! Instead the dictionary is searched, not the corpus. A workspace with twenty
//! thousand blocks has a few thousand distinct tokens, and finding every token
//! that contains `hist` is a scan over those few thousand short strings rather
//! than over twenty thousand command lines. The postings of the matching tokens
//! are unioned, and that is the candidate set.
//!
//! ## Why the typed filters are bitsets
//!
//! `status:failed` is the query people actually run, and it is a filter that
//! throws away most of the history before any text is looked at. One word of a
//! bitset answers it for sixty-four blocks at a time, and intersecting two
//! filters is an `and` per word. The text pass then runs over what is left,
//! which for a real query is a small fraction of the whole.
//!
//! ## What this is worth, measured
//!
//! On twenty thousand blocks, `status:failed zig build` takes 344 µs scanned
//! and 72 µs through the index — 4.8 times faster. Building the index takes
//! 1.8 ms.
//!
//! Those three numbers together say something the first two on their own do
//! not: **an index never pays for a single query.** Building costs about
//! 89 ns a block and scanning costs about 17 ns, so one query through a
//! freshly built index is five times slower than not building one. That does
//! not change at a larger size — both grow linearly — so no threshold makes it
//! worthwhile.
//!
//! `zag history` therefore does not use it, and says so where it does not. The
//! index is for a surface that holds a workspace open and asks repeatedly: the
//! graphical client, a request interface on the daemon, an interactive search
//! inside `zag term`. None of those exist yet. What would make it pay for a
//! one-shot command is persisting it beside the log and updating it as events
//! are appended, and that is a different piece of work with its own failure
//! mode — a stale index — which is exactly the thing the whole file is written
//! to avoid.

const std = @import("std");
const block_mod = @import("block.zig");
const provenance = @import("../data/provenance.zig");

pub const Block = block_mod.Block;
pub const Status = block_mod.Status;
pub const Kind = block_mod.Kind;

/// A set of block positions, one bit each.
///
/// Sized once at build time and never grown, because the set of blocks an index
/// was built over does not change while it is being queried.
pub const Set = struct {
    words: []u64,
    /// How many blocks the set is over. The bits above this in the last word
    /// are always zero and must stay that way, or a count is wrong by up to
    /// sixty-three.
    len: usize,

    pub fn init(arena: std.mem.Allocator, len: usize) !Set {
        const words = try arena.alloc(u64, (len + 63) / 64);
        @memset(words, 0);
        return .{ .words = words, .len = len };
    }

    /// Every block, set.
    pub fn full(arena: std.mem.Allocator, len: usize) !Set {
        var set = try init(arena, len);
        @memset(set.words, ~@as(u64, 0));
        set.trim();
        return set;
    }

    /// Clear the bits past `len` in the last word.
    fn trim(self: *Set) void {
        if (self.words.len == 0) return;
        const used = self.len % 64;
        if (used != 0) self.words[self.words.len - 1] &= (@as(u64, 1) << @intCast(used)) - 1;
    }

    pub fn add(self: *Set, at: usize) void {
        self.words[at / 64] |= @as(u64, 1) << @intCast(at % 64);
    }

    pub fn has(self: Set, at: usize) bool {
        if (at >= self.len) return false;
        return self.words[at / 64] & (@as(u64, 1) << @intCast(at % 64)) != 0;
    }

    pub fn andWith(self: *Set, other: Set) void {
        for (self.words, other.words) |*word, mask| word.* &= mask;
    }

    pub fn orWith(self: *Set, other: Set) void {
        for (self.words, other.words) |*word, mask| word.* |= mask;
    }

    pub fn count(self: Set) usize {
        var total: usize = 0;
        for (self.words) |word| total += @popCount(word);
        return total;
    }

    pub fn isEmpty(self: Set) bool {
        for (self.words) |word| {
            if (word != 0) return false;
        }
        return true;
    }

    /// Walks the set positions in order, a word at a time.
    ///
    /// Skipping a whole empty word is the reason this is a bitset rather than a
    /// list: a filter that keeps one block in a thousand leaves most words zero,
    /// and those cost one comparison each.
    pub const Iterator = struct {
        set: Set,
        word: usize = 0,
        remaining: u64 = 0,

        pub fn next(self: *Iterator) ?usize {
            while (self.remaining == 0) {
                if (self.word >= self.set.words.len) return null;
                self.remaining = self.set.words[self.word];
                self.word += 1;
            }
            const bit = @ctz(self.remaining);
            self.remaining &= self.remaining - 1;
            return (self.word - 1) * 64 + bit;
        }
    };

    pub fn iterate(self: Set) Iterator {
        return .{ .set = self };
    }
};

/// The lookup structures over one block index.
///
/// Built once and read many times. Rebuilding is cheaper than maintaining, at
/// the sizes this is for, and a stale index is the kind of bug that makes a
/// person distrust their own record.
pub const Lookup = struct {
    /// How many blocks this was built over. A lookup used against a different
    /// index would silently answer about the wrong blocks, so callers check.
    blocks: usize,
    /// Token to the positions of the blocks whose command text holds it.
    /// Insertion order is the order tokens were first seen, which makes the
    /// dictionary scan deterministic.
    postings: std.StringArrayHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    by_status: std.AutoArrayHashMapUnmanaged(Status, Set) = .empty,
    by_kind: std.AutoArrayHashMapUnmanaged(Kind, Set) = .empty,
    by_actor: std.AutoArrayHashMapUnmanaged(provenance.ProducerKind, Set) = .empty,
    /// Blocks whose boundary came from shell integration.
    shell_marked: Set,
    /// Blocks that have an exit status at all, keyed by it.
    by_exit: std.AutoArrayHashMapUnmanaged(u8, Set) = .empty,

    /// The longest token the dictionary holds.
    ///
    /// A command line can be enormous — a linker invocation with two thousand
    /// object files — and indexing every token of one would make the dictionary
    /// larger than the corpus. Tokens past this are indexed by their first
    /// `max_token_bytes` and the matcher settles the rest, which is safe
    /// because the index only ever narrows.
    pub const max_token_bytes = 64;

    /// Build the lookup over every block in `index`.
    pub fn build(arena: std.mem.Allocator, index: block_mod.Index) !Lookup {
        const count = index.blocks.items.len;
        var self: Lookup = .{
            .blocks = count,
            .shell_marked = try Set.init(arena, count),
        };

        for (index.blocks.items, 0..) |b, at| {
            (try setFor(arena, &self.by_status, b.status, count)).add(at);
            (try setFor(arena, &self.by_kind, b.kind, count)).add(at);
            (try setFor(arena, &self.by_actor, b.actor.kind, count)).add(at);
            if (b.exitStatus) |code| (try setFor(arena, &self.by_exit, code, count)).add(at);
            if (b.boundaryFromShell) self.shell_marked.add(at);

            const text = b.commandText orelse continue;
            var walk = Tokens{ .text = text };
            var lowered: [max_token_bytes]u8 = undefined;
            while (walk.next()) |token| {
                const cut = token[0..@min(token.len, max_token_bytes)];
                // Lowered *before* the lookup, not after. Writing a different
                // key into the map once the entry exists leaves it in the
                // bucket its old hash chose, and every later lookup misses it.
                const key = lowered[0..cut.len];
                for (cut, 0..) |byte, offset| key[offset] = std.ascii.toLower(byte);

                const entry = try self.postings.getOrPut(arena, key);
                if (!entry.found_existing) {
                    // The key so far points at a stack buffer that is about to
                    // be reused, so the map gets its own copy.
                    entry.key_ptr.* = try arena.dupe(u8, key);
                    entry.value_ptr.* = .empty;
                }
                // Postings are appended in block order and so are already
                // sorted, and a block never appends the same token twice
                // because the last position is checked.
                const list = entry.value_ptr;
                if (list.items.len > 0 and list.items[list.items.len - 1] == at) continue;
                try list.append(arena, @intCast(at));
            }
        }
        return self;
    }

    fn setFor(
        arena: std.mem.Allocator,
        map: anytype,
        key: anytype,
        count: usize,
    ) !*Set {
        const entry = try map.getOrPut(arena, key);
        if (!entry.found_existing) entry.value_ptr.* = try Set.init(arena, count);
        return entry.value_ptr;
    }

    /// Blocks that might match. Never fewer than the blocks that do.
    ///
    /// Every filter here is one the index can answer exactly. Anything it
    /// cannot — a time range, a directory prefix, a branch — is left to the
    /// matcher, which runs on the survivors.
    pub fn candidates(self: Lookup, arena: std.mem.Allocator, query: anytype) !Set {
        var out = try Set.full(arena, self.blocks);

        if (query.status) |status| out.andWith(self.by_status.get(status) orelse try Set.init(arena, self.blocks));
        if (query.kind) |kind| out.andWith(self.by_kind.get(kind) orelse try Set.init(arena, self.blocks));
        if (query.actor) |actor| out.andWith(self.by_actor.get(actor) orelse try Set.init(arena, self.blocks));
        if (query.exit_status) |code| out.andWith(self.by_exit.get(code) orelse try Set.init(arena, self.blocks));
        if (query.shell_marked_only) out.andWith(self.shell_marked);

        for (query.words) |word| {
            if (word.len == 0) continue;
            if (out.isEmpty()) break;
            out.andWith(try self.blocksHolding(arena, word));
        }
        return out;
    }

    /// Every block whose command text contains `word`, anywhere.
    ///
    /// The dictionary is scanned rather than the corpus. A workspace with
    /// twenty thousand blocks has a few thousand distinct tokens, and a
    /// substring search over those short strings is far cheaper than one over
    /// every command line.
    ///
    /// A word longer than a token can hold cannot be answered from the
    /// dictionary at all, so every block is a candidate and the matcher
    /// decides. That is slow and correct, which is the right way round.
    fn blocksHolding(self: Lookup, arena: std.mem.Allocator, word: []const u8) !Set {
        if (word.len > max_token_bytes) return Set.full(arena, self.blocks);

        var lowered_buffer: [max_token_bytes]u8 = undefined;
        const lowered = lowered_buffer[0..word.len];
        for (word, 0..) |byte, at| lowered[at] = std.ascii.toLower(byte);

        var out = try Set.init(arena, self.blocks);
        var entries = self.postings.iterator();
        while (entries.next()) |entry| {
            if (std.mem.indexOf(u8, entry.key_ptr.*, lowered) == null) continue;
            for (entry.value_ptr.items) |at| out.add(at);
        }
        return out;
    }

    /// How many distinct tokens the dictionary holds. Reported so that a
    /// measurement can say what size it was taken at.
    pub fn tokenCount(self: Lookup) usize {
        return self.postings.count();
    }
};

/// Splits command text into the runs a query word could sit inside.
///
/// A token is a run of letters, digits and the punctuation that holds a path or
/// a flag together: `--summary`, `src/ai/loop.zig`, `v1.2.3`. Splitting those
/// apart would put `src` and `loop` in different tokens and make
/// `src/ai/loop` findable only by scanning, which is the thing being avoided.
pub const Tokens = struct {
    text: []const u8,
    at: usize = 0,

    fn isTokenByte(byte: u8) bool {
        return switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '/', '\\', ':', '@', '+', '~', '=' => true,
            else => false,
        };
    }

    pub fn next(self: *Tokens) ?[]const u8 {
        while (self.at < self.text.len and !isTokenByte(self.text[self.at])) self.at += 1;
        if (self.at >= self.text.len) return null;
        const start = self.at;
        while (self.at < self.text.len and isTokenByte(self.text[self.at])) self.at += 1;
        return self.text[start..self.at];
    }
};

const testing = std.testing;
const history = @import("history.zig");
const event_mod = @import("../events/event.zig");
const idmod = @import("../core/id.zig");
const timeutil = @import("../core/time.zig");

/// A workspace's worth of blocks, built without a log so the test is about the
/// index rather than about folding events.
fn sampleBlocks(arena: std.mem.Allocator, count: usize, seed: u64) !block_mod.Index {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    const programs = [_][]const u8{ "zig", "git", "grep", "zag", "curl", "make" };
    const verbs = [_][]const u8{ "build", "test", "status", "commit", "history", "check", "fmt" };
    const paths = [_][]const u8{ "src/ai/loop.zig", "src/workspace/index.zig", "README.md", "docs/roadmap.md", "" };
    const statuses = [_]Status{ .succeeded, .failed, .running, .denied, .cancelled, .unknown };
    const kinds = [_]Kind{ .command, .agent_run, .tool_call, .message };
    const actors = [_]provenance.ProducerKind{ .person, .agent, .system };

    var index: block_mod.Index = .{ .arena = arena };
    var gen: idmod.Generator = .init(seed, 1_780_000_000_000);
    for (0..count) |at| {
        const text = try std.fmt.allocPrint(arena, "{s} {s} {s}", .{
            programs[random.intRangeLessThan(usize, 0, programs.len)],
            verbs[random.intRangeLessThan(usize, 0, verbs.len)],
            paths[random.intRangeLessThan(usize, 0, paths.len)],
        });
        const status = statuses[random.intRangeLessThan(usize, 0, statuses.len)];
        try index.blocks.append(arena, .{
            .id = gen.next(idmod.BlockId),
            .session = gen.next(idmod.SessionId),
            .kind = kinds[random.intRangeLessThan(usize, 0, kinds.len)],
            .status = status,
            .createdAt = .{ .ns = 1_780_000_000_000_000_000 + @as(i64, @intCast(at)) * 1_000_000_000 },
            .workingDirectory = if (random.boolean()) "/home/user/zag" else "/tmp/scratch",
            .commandText = text,
            .exitStatus = if (status == .failed) random.intRangeLessThan(u8, 1, 5) else @as(?u8, if (status == .succeeded) 0 else null),
            .actor = .{
                .id = gen.next(idmod.ActorId),
                .kind = actors[random.intRangeLessThan(usize, 0, actors.len)],
                .label = "someone",
            },
            .boundaryFromShell = random.boolean(),
        });
    }
    return index;
}

test "the index narrows the search and never changes the answer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The test the whole file rests on. An index that returns nearly the same
    // results as the scan is worse than no index: a person searching their own
    // record for a command they know they ran, and not finding it, has been
    // told something false about their own history.
    const blocks = try sampleBlocks(arena, 900, 0x1DEA);
    const lookup = try Lookup.build(arena, blocks);
    const now: timeutil.Timestamp = .{ .ns = 1_781_000_000_000_000_000 };

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = prng.random();
    const words = [_][]const u8{ "zig", "git", "test", "loop", "ZAG", "hist", "src/ai", ".md", "nothing-here", "z" };

    for (0..400) |_| {
        var query: history.Query = .{};
        var chosen: std.ArrayList([]const u8) = .empty;
        const word_count = random.intRangeLessThan(usize, 0, 3);
        for (0..word_count) |_| {
            try chosen.append(arena, words[random.intRangeLessThan(usize, 0, words.len)]);
        }
        query.words = chosen.items;
        if (random.boolean()) query.status = @enumFromInt(random.intRangeLessThan(u8, 0, 6));
        if (random.boolean()) query.kind = @enumFromInt(random.intRangeLessThan(u8, 0, 6));
        if (random.boolean()) query.actor = @enumFromInt(random.intRangeLessThan(u8, 0, 3));
        if (random.boolean()) query.exit_status = random.intRangeLessThan(u8, 0, 5);
        if (random.boolean()) query.shell_marked_only = true;
        if (random.boolean()) query.directory = "/home/user/zag";
        if (random.boolean()) query.since = .{ .ns = 1_780_000_000_000_000_000 + 400 * 1_000_000_000 };

        const options: history.Options = .{ .now = now, .foldRepeats = random.boolean() };
        var with_index = options;
        with_index.lookup = &lookup;

        const scanned = try history.run(arena, blocks, query, options);
        const indexed = try history.run(arena, blocks, query, with_index);

        try testing.expectEqual(scanned.matchCount, indexed.matchCount);
        try testing.expectEqual(scanned.hits.len, indexed.hits.len);
        for (scanned.hits, indexed.hits) |a, b| {
            try testing.expect(a.block.id.eql(b.block.id));
            try testing.expectEqual(a.repeatCount, b.repeatCount);
        }
    }
}

test "a lookup built over different blocks is ignored, not trusted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A stale index would answer about the wrong history, quietly. Falling back
    // to the scan is slow and right; using it anyway is fast and wrong.
    const small = try sampleBlocks(arena, 20, 1);
    const large = try sampleBlocks(arena, 200, 2);
    const stale = try Lookup.build(arena, small);
    const now: timeutil.Timestamp = .{ .ns = 1_781_000_000_000_000_000 };

    const query: history.Query = .{ .words = &.{"zig"} };
    const scanned = try history.run(arena, large, query, .{ .now = now });
    const with_stale = try history.run(arena, large, query, .{ .now = now, .lookup = &stale });
    try testing.expectEqual(scanned.hits.len, with_stale.hits.len);
    try testing.expectEqual(scanned.matchCount, with_stale.matchCount);
}

test "a bitset counts, iterates and never reports a bit past its end" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The bits above `len` in the last word are the classic place a count comes
    // out sixty-three too high.
    for ([_]usize{ 0, 1, 63, 64, 65, 127, 128, 1000 }) |len| {
        const everything = try Set.full(arena, len);
        try testing.expectEqual(len, everything.count());

        var walked: usize = 0;
        var iterator = everything.iterate();
        while (iterator.next()) |at| {
            try testing.expect(at < len);
            try testing.expectEqual(walked, at);
            walked += 1;
        }
        try testing.expectEqual(len, walked);

        var empty = try Set.init(arena, len);
        try testing.expect(empty.isEmpty());
        try testing.expectEqual(@as(usize, 0), empty.count());
        if (len > 0) {
            empty.add(len - 1);
            try testing.expect(empty.has(len - 1));
            try testing.expectEqual(@as(usize, 1), empty.count());
            try testing.expect(!empty.isEmpty());
        }
        try testing.expect(!empty.has(len));
    }
}

test "and and or work word by word" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var a = try Set.init(arena, 200);
    var b = try Set.init(arena, 200);
    for ([_]usize{ 0, 63, 64, 130 }) |at| a.add(at);
    for ([_]usize{ 63, 64, 199 }) |at| b.add(at);

    var both = a;
    both.words = try arena.dupe(u64, a.words);
    both.andWith(b);
    try testing.expectEqual(@as(usize, 2), both.count());
    try testing.expect(both.has(63) and both.has(64));

    var either = a;
    either.words = try arena.dupe(u64, a.words);
    either.orWith(b);
    try testing.expectEqual(@as(usize, 5), either.count());
    try testing.expect(either.has(199));
}

test "a token keeps a path and a flag together" {
    // Splitting these apart would put `src` and `loop` in different tokens, and
    // make `src/ai/loop` findable only by scanning — which is the thing being
    // avoided.
    var walk = Tokens{ .text = "zig build test --summary all src/ai/loop.zig v1.2.3 a@b" };
    const expected = [_][]const u8{
        "zig", "build", "test", "--summary", "all", "src/ai/loop.zig", "v1.2.3", "a@b",
    };
    for (expected) |word| {
        try testing.expectEqualStrings(word, walk.next().?);
    }
    try testing.expect(walk.next() == null);

    // Quotes, pipes and semicolons separate; an empty string yields nothing.
    var shell = Tokens{ .text = "sh -c 'printf x' | grep -q x; echo done" };
    var count: usize = 0;
    while (shell.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 9), count);

    var nothing = Tokens{ .text = "" };
    try testing.expect(nothing.next() == null);
    var punctuation = Tokens{ .text = "  ||  " };
    try testing.expect(punctuation.next() == null);
}

test "a word longer than a token still finds what it should" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The dictionary cannot answer this, so every block becomes a candidate and
    // the matcher decides. Slow and correct, which is the right way round.
    var index: block_mod.Index = .{ .arena = arena };
    var gen: idmod.Generator = .init(3, 1_780_000_000_000);
    const long = "x" ** (Lookup.max_token_bytes + 20);
    try index.blocks.append(arena, .{
        .id = gen.next(idmod.BlockId),
        .session = gen.next(idmod.SessionId),
        .kind = .command,
        .status = .succeeded,
        .createdAt = .{ .ns = 1_780_000_000_000_000_000 },
        .commandText = "echo " ++ long,
        .actor = .{ .id = gen.next(idmod.ActorId), .kind = .person, .label = "you" },
    });

    const lookup = try Lookup.build(arena, index);
    const now: timeutil.Timestamp = .{ .ns = 1_781_000_000_000_000_000 };
    const query: history.Query = .{ .words = &.{long} };
    const found = try history.run(arena, index, query, .{ .now = now, .lookup = &lookup });
    try testing.expectEqual(@as(usize, 1), found.hits.len);
}

test "the dictionary is much smaller than the history" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The premise the whole approach rests on: searching the dictionary beats
    // searching the corpus because there is far less of it. If this ever stops
    // being true — a workspace of entirely unique command lines — the index
    // stops helping, and it still does not stop being correct.
    const blocks = try sampleBlocks(arena, 2000, 0xD1C7);
    const lookup = try Lookup.build(arena, blocks);
    try testing.expect(lookup.tokenCount() < blocks.blocks.items.len / 10);
    try testing.expectEqual(blocks.blocks.items.len, lookup.blocks);
}
