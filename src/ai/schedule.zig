//! Deciding which tool calls may run at the same time.
//!
//! A model that asks to read four files gets them read one after another. Each
//! read is a syscall that spends most of its time waiting, and there is no
//! reason four of them should take four times as long as one. That is the
//! feature. This file is about the reason it is not simply a matter of starting
//! four threads.
//!
//! ## The record has to come out the same
//!
//! Everything this workbench does ends up in an append-only, hash-chained log,
//! and the value of that log is that it says what happened. A log whose
//! contents depend on which read finished first says something slightly
//! different every time the same work is done, and a chain over that proves
//! nothing anybody wants proved. Two runs of the same turn must produce the
//! same events in the same order.
//!
//! So the parallelism here is deliberately narrow. Everything that decides
//! anything — parsing a call into a typed request, counting repeats, asking the
//! policy engine — happens serially, in the order the model asked, exactly as
//! it did before. Only the executor's work runs at once, and the results are
//! written back into the caller's own array by index rather than as they
//! arrive. A turn recorded from eight threads is byte-for-byte the turn
//! recorded from one.
//!
//! ## Two calls that touch the same thing do not overlap
//!
//! Reading a file while another call writes it is a race whose answer depends
//! on timing, and a workbench that produced one answer on a fast machine and
//! another on a slow one would be worse than a slow one. Calls are grouped into
//! waves: everything in a wave is independent of everything else in it, and one
//! wave finishes before the next starts.
//!
//! Independence is decided from the *typed request* — the same value the policy
//! engine decided about — never from anything the model wrote. Two claims
//! conflict when they name overlapping resources and at least one of them
//! writes. Paths overlap by prefix, so writing `src/` conflicts with reading
//! `src/ai/loop.zig`, which is the case a naive equality test misses.
//!
//! ## When in doubt, run it alone
//!
//! A call whose effects cannot be bounded is a barrier: it waits for everything
//! before it and everything after it waits for it. Running a process is the
//! obvious one — a command can touch any file on the machine, and no amount of
//! reading its argument vector tells you which. Pushing to a remote, signalling
//! a process and anything this build does not recognise are barriers too.
//!
//! That is the conservative direction, and it is the right one. Missing a
//! chance to overlap two reads costs milliseconds. Overlapping two calls that
//! turn out to share a file costs correctness, and costs it intermittently.

const std = @import("std");
const capability_mod = @import("capability.zig");
const tools = @import("tools.zig");

pub const Capability = capability_mod.Capability;
pub const Resource = capability_mod.Resource;

/// Whether a call only observes a resource, or changes it.
pub const Access = enum {
    read,
    write,

    pub fn text(self: Access) []const u8 {
        return switch (self) {
            .read => "reads",
            .write => "changes",
        };
    }
};

/// What one call touches.
pub const Claim = union(enum) {
    /// Nothing outside itself. Two of these never conflict.
    nothing,
    /// A named resource, observed or changed.
    on: struct { resource: Resource, access: Access },
    /// Effects this build cannot bound, except alongside its own kind.
    ///
    /// This exists for one case and it is worth naming: starting a child
    /// agent. A child does arbitrary work, so it cannot overlap a write or a
    /// command — but the whole reason to start four children is that they run
    /// at the same time, and a claim of `.everything` makes four children into
    /// four turns' worth of waiting. `siblings` says "runs alone, except
    /// beside others in this group", which is exactly the shape a fan-out has
    /// and which neither of the other two variants can express.
    ///
    /// It is only safe because of what the group guarantees about itself.
    /// Children that run together are narrowed to reading — see
    /// `swarm.readOnly` — so two of them cannot disagree about a file. A caller
    /// that puts things in a group without that guarantee has written a race.
    siblings: []const u8,
    /// Effects this build cannot bound. Runs alone.
    everything,

    /// Whether two calls may run at the same time.
    ///
    /// The relation is symmetric and reflexive-free in the sense that matters:
    /// a call is never asked whether it conflicts with itself.
    pub fn conflictsWith(self: Claim, other: Claim) bool {
        if (self == .everything or other == .everything) return true;
        if (self == .siblings or other == .siblings) {
            // Beside its own group and nothing else. A sibling next to a read
            // is still a barrier: a child can do anything a policy allows it,
            // and what that is cannot be read off the request.
            if (self != .siblings or other != .siblings) return true;
            return !std.mem.eql(u8, self.siblings, other.siblings);
        }
        if (self == .nothing or other == .nothing) return false;
        const a = self.on;
        const b = other.on;
        // Two readers never conflict. That is the whole point of the exercise:
        // reads are what a model asks for most, and reads are what overlap.
        if (a.access == .read and b.access == .read) return false;
        return overlaps(a.resource, b.resource);
    }
};

/// Whether two resources name anything in common.
///
/// Different kinds never overlap: a host is not a path, and a credential is not
/// a command. Within a kind, paths overlap by prefix and everything else by
/// equality.
pub fn overlaps(a: Resource, b: Resource) bool {
    if (a == .none or b == .none) return false;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .path => pathsOverlap(a.text(), b.text()),
        .none => false,
        else => std.mem.eql(u8, a.text(), b.text()),
    };
}

/// Whether one path contains the other, or they are the same path.
///
/// `src` contains `src/ai/loop.zig`; `src` does not contain `srcery`. The
/// separator test is what tells those apart, and leaving it out is how a
/// scheduler decides two unrelated directories are the same one.
fn pathsOverlap(a: []const u8, b: []const u8) bool {
    const shorter = if (a.len <= b.len) a else b;
    const longer = if (a.len <= b.len) b else a;
    if (!std.mem.startsWith(u8, longer, shorter)) return false;
    if (longer.len == shorter.len) return true;
    // The shorter one is a directory only if the next byte begins a new
    // segment. Trailing separators on the shorter path count as one already.
    if (shorter.len > 0 and shorter[shorter.len - 1] == '/') return true;
    return longer[shorter.len] == '/';
}

/// What a typed request touches, derived from the request rather than from
/// anything the model wrote.
///
/// Every capability is named, so a new one added to the enum fails to compile
/// here rather than falling into a default that lets it run beside anything.
pub fn claimOf(arena: std.mem.Allocator, request: tools.ToolRequest) !Claim {
    const capability = request.capability();
    const resource = try request.resource(arena);

    return switch (capability) {
        // Observers. Any number may run at once, and beside any writer that
        // does not touch what they are reading.
        .@"fs.read", .@"git.read" => .{ .on = .{ .resource = resource, .access = .read } },

        // Changers of one named thing.
        .@"fs.write", .@"fs.delete" => .{ .on = .{ .resource = resource, .access = .write } },

        // A commit changes the whole repository's state, not one path, and two
        // of them racing produce a repository neither asked for.
        .@"git.commit", .@"git.push" => .everything,

        // A command can touch any file on the machine, and reading its argument
        // vector does not tell you which. This is the barrier that matters
        // most, because it is the capability a model reaches for when it wants
        // to do something the typed tools do not offer.
        .@"process.execute", .@"process.signal" => .everything,

        // Network and credentials: the resource is the host or the variable,
        // and two requests to the same host are ordered because a provider's
        // rate limit and a server's state both care.
        .@"network.connect", .@"network.listen" => .{ .on = .{ .resource = resource, .access = .write } },
        .@"credentials.use", .@"credentials.read" => .{ .on = .{ .resource = resource, .access = .read } },

        // A model asking a model, a tool on a server this build did not write,
        // a container, another machine, or a write to the shared knowledge
        // base. None of these has effects this build can bound from the
        // request, so each runs alone.
        // Children fan out together and wait for nothing else. What makes
        // that safe is not this line: it is that children which run together
        // are narrowed to reading. See `swarm.readOnly` and `loop.Children`.
        .@"agent.spawn" => .{ .siblings = "agents" },

        .@"model.infer",
        .@"mcp.invoke",
        .@"container.start",
        .@"remote.execute",
        .@"knowledge.write",
        => .everything,
    };
}

/// A group of calls that may run at the same time.
///
/// Holds indices into the caller's own array, so that results go back where
/// they came from and the record does not depend on which finished first.
pub const Wave = struct {
    members: []const usize,

    pub fn len(self: Wave) usize {
        return self.members.len;
    }
};

/// Group calls into waves.
///
/// A call joins the earliest wave that contains nothing it conflicts with, and
/// never overtakes a call it conflicts with — so the relative order of any two
/// dependent calls is the order the model asked for them in. Calls that conflict
/// with nothing all land in the first wave.
///
/// `null` in `claims` means the call is not going to run at all — it was
/// refused, or never became a typed request — and takes no part in the
/// scheduling.
pub fn plan(arena: std.mem.Allocator, claims: []const ?Claim) ![]const Wave {
    var waves: std.ArrayList(std.ArrayList(usize)) = .empty;
    // What each wave collectively touches, so a candidate is checked against a
    // wave rather than against every call ever placed.
    var touched: std.ArrayList(std.ArrayList(Claim)) = .empty;

    for (claims, 0..) |maybe, index| {
        const claim = maybe orelse continue;

        // The last wave holding something this conflicts with. Every wave after
        // that one is free of conflicts by construction, so the first wave this
        // may join is the one immediately after it — which is also the earliest
        // wave that does not let it overtake a call it depends on.
        var after: ?usize = null;
        for (touched.items, 0..) |wave, at| {
            for (wave.items) |placed| {
                if (claim.conflictsWith(placed)) {
                    after = at;
                    break;
                }
            }
        }

        const target = if (after) |last| last + 1 else 0;
        while (waves.items.len <= target) {
            try waves.append(arena, .empty);
            try touched.append(arena, .empty);
        }
        try waves.items[target].append(arena, index);
        try touched.items[target].append(arena, claim);
    }

    var out: std.ArrayList(Wave) = .empty;
    for (waves.items) |members| {
        if (members.items.len == 0) continue;
        try out.append(arena, .{ .members = members.items });
    }
    return out.items;
}

/// How many calls in the widest wave. What a caller sizes a pool from.
pub fn widest(waves: []const Wave) usize {
    var most: usize = 0;
    for (waves) |wave| most = @max(most, wave.len());
    return most;
}

/// Whether any wave holds more than one call.
///
/// When this is false, running the waves concurrently costs the setup and
/// gains nothing, so a caller may take the plain path and get an identical
/// result.
pub fn anyOverlap(waves: []const Wave) bool {
    return widest(waves) > 1;
}

const testing = std.testing;

/// The two void variants as values rather than as tag literals, which is what
/// `Claim.everything` on its own resolves to.
const barrier: Claim = .everything;
const idle_claim: Claim = .nothing;

fn reads(path: []const u8) ?Claim {
    return .{ .on = .{ .resource = .{ .path = path }, .access = .read } };
}

fn writes(path: []const u8) ?Claim {
    return .{ .on = .{ .resource = .{ .path = path }, .access = .write } };
}

test "four reads of four files are one wave" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The case the feature exists for. Four reads that touch nothing in common
    // should take about as long as one, and they cannot unless they are in one
    // wave.
    const waves = try plan(arena, &.{
        reads("src/a.zig"), reads("src/b.zig"), reads("src/c.zig"), reads("src/d.zig"),
    });
    try testing.expectEqual(@as(usize, 1), waves.len);
    try testing.expectEqual(@as(usize, 4), waves[0].len());
    try testing.expect(anyOverlap(waves));
}

test "reading the file another call is writing waits for it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A race whose answer depends on timing. A workbench that gave one answer
    // on a fast machine and another on a slow one would be worse than a slow
    // one.
    const waves = try plan(arena, &.{
        reads("src/a.zig"),
        writes("src/a.zig"),
        reads("src/a.zig"),
    });
    try testing.expectEqual(@as(usize, 3), waves.len);
    try testing.expectEqualSlices(usize, &.{0}, waves[0].members);
    try testing.expectEqualSlices(usize, &.{1}, waves[1].members);
    try testing.expectEqualSlices(usize, &.{2}, waves[2].members);
}

test "a directory contains the files under it, and does not contain its neighbour" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The case a naive equality test misses: writing a directory conflicts with
    // reading anything inside it.
    const nested = try plan(arena, &.{ writes("src"), reads("src/ai/loop.zig") });
    try testing.expectEqual(@as(usize, 2), nested.len);

    // And the case a naive prefix test gets wrong: `src` is not a prefix of
    // `srcery` in any sense that matters, because they are different
    // directories.
    const neighbours = try plan(arena, &.{ writes("src"), reads("srcery/thing.zig") });
    try testing.expectEqual(@as(usize, 1), neighbours.len);

    try testing.expect(pathsOverlap("src", "src/ai/loop.zig"));
    try testing.expect(pathsOverlap("src/", "src/ai/loop.zig"));
    try testing.expect(pathsOverlap("src/a.zig", "src/a.zig"));
    try testing.expect(!pathsOverlap("src", "srcery"));
    try testing.expect(!pathsOverlap("src/a.zig", "src/b.zig"));
    try testing.expect(!pathsOverlap("docs", "src"));
}

test "running a command is a barrier in both directions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A command can touch any file on the machine and reading its argument
    // vector does not tell you which. Everything before it finishes first, and
    // everything after it waits.
    const waves = try plan(arena, &.{
        reads("src/a.zig"),
        reads("src/b.zig"),
        barrier,
        reads("src/c.zig"),
        reads("src/d.zig"),
    });
    try testing.expectEqual(@as(usize, 3), waves.len);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, waves[0].members);
    try testing.expectEqualSlices(usize, &.{2}, waves[1].members);
    try testing.expectEqualSlices(usize, &.{ 3, 4 }, waves[2].members);
}

test "a refused call takes no part in the schedule" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A call that never became a typed request, or that the policy refused, is
    // not going to run. Reserving a place for it would serialise calls that
    // have nothing to do with it.
    const waves = try plan(arena, &.{ reads("a"), null, reads("b"), null });
    try testing.expectEqual(@as(usize, 1), waves.len);
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, waves[0].members);
}

test "different kinds of resource never conflict" {
    // A host is not a path and a credential is not a command. Treating the text
    // as the whole story would serialise a read of `build.zig` behind a
    // connection to a host that happened to be called `build.zig`.
    const path: Claim = .{ .on = .{ .resource = .{ .path = "x" }, .access = .write } };
    const host: Claim = .{ .on = .{ .resource = .{ .host = "x" }, .access = .write } };
    try testing.expect(!path.conflictsWith(host));

    const same_host: Claim = .{ .on = .{ .resource = .{ .host = "x" }, .access = .write } };
    try testing.expect(host.conflictsWith(same_host));
}

test "nothing conflicts with nothing" {
    const idle: Claim = .nothing;
    try testing.expect(!idle.conflictsWith(idle));
    try testing.expect(!idle.conflictsWith(reads("a").?));
    // Except a barrier, which conflicts with everything including idleness,
    // because "runs alone" has to mean alone.
    try testing.expect(idle.conflictsWith(barrier));
    try testing.expect(barrier.conflictsWith(idle));
    try testing.expect(barrier.conflictsWith(barrier));
}

test "children fan out together and beside nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The whole reason to start four children is that they run at the same
    // time. A claim of `.everything` would make four children into four turns'
    // worth of waiting, which is the cost of the fan-out without the benefit.
    const first = try claimOf(arena, .{ .spawn_agent = .{ .request = "Read the parser." } });
    const second = try claimOf(arena, .{ .spawn_agent = .{ .request = "Read the lexer." } });
    try testing.expect(first == .siblings);
    try testing.expect(!first.conflictsWith(second));

    // And beside nothing else, including a read. A child does whatever a model
    // decides, and what that touches cannot be read off the request.
    try testing.expect(first.conflictsWith(reads("src").?));
    try testing.expect(reads("src").?.conflictsWith(first));
    try testing.expect(first.conflictsWith(writes("src/a.zig").?));
    try testing.expect(first.conflictsWith(barrier));
    try testing.expect(first.conflictsWith(idle_claim));

    // A different group is a different fan-out, and does not join this one.
    const stranger: Claim = .{ .siblings = "something-else" };
    try testing.expect(first.conflictsWith(stranger));

    // Four children in one turn make one wave; a write among them makes three.
    const together = try plan(arena, &.{ first, second, first, second });
    try testing.expectEqual(@as(usize, 1), together.len);
    try testing.expectEqual(@as(usize, 4), together[0].len());

    const interrupted = try plan(arena, &.{ first, writes("src/a.zig").?, second });
    try testing.expectEqual(@as(usize, 3), interrupted.len);
}

test "conflict is symmetric, whatever the pair" {
    // An asymmetric conflict test schedules a pair one way and not the other,
    // which shows up as a race that depends on the order the model listed its
    // calls in.
    const samples = [_]Claim{
        idle_claim,
        barrier,
        reads("src").?,
        writes("src").?,
        reads("src/a.zig").?,
        writes("src/a.zig").?,
        .{ .on = .{ .resource = .{ .host = "api.example.com" }, .access = .write } },
        .{ .on = .{ .resource = .{ .credential = "KEY" }, .access = .read } },
        .{ .on = .{ .resource = .none, .access = .read } },
        .{ .siblings = "agents" },
        .{ .siblings = "something-else" },
    };
    for (samples) |a| {
        for (samples) |b| {
            try testing.expectEqual(a.conflictsWith(b), b.conflictsWith(a));
        }
    }
}

test "a plan never lets two conflicting calls share a wave, or swap places" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The two properties the whole file exists to guarantee, checked over
    // pseudo-random turns rather than over the examples somebody thought of.
    var prng = std.Random.DefaultPrng.init(0x5CEDA1E);
    const random = prng.random();
    const paths = [_][]const u8{ "src", "src/a.zig", "src/b.zig", "docs", "docs/x.md", "build.zig" };

    for (0..300) |_| {
        const count = random.intRangeLessThan(usize, 1, 12);
        const claims = try arena.alloc(?Claim, count);
        for (claims) |*slot| {
            slot.* = switch (random.intRangeLessThan(u8, 0, 10)) {
                0 => null,
                1 => barrier,
                2 => idle_claim,
                3, 4, 5 => reads(paths[random.intRangeLessThan(usize, 0, paths.len)]),
                else => writes(paths[random.intRangeLessThan(usize, 0, paths.len)]),
            };
        }

        const waves = try plan(arena, claims);

        // Where each call ended up.
        var placed = try arena.alloc(?usize, count);
        @memset(placed, null);
        var total: usize = 0;
        for (waves, 0..) |wave, at| {
            for (wave.members) |index| {
                try testing.expect(placed[index] == null); // never scheduled twice
                placed[index] = at;
                total += 1;
            }
        }

        // Every call that was going to run is in exactly one wave.
        var expected: usize = 0;
        for (claims) |claim| {
            if (claim != null) expected += 1;
        }
        try testing.expectEqual(expected, total);

        for (claims, 0..) |maybe_a, i| {
            const a = maybe_a orelse continue;
            for (claims[i + 1 ..], i + 1..) |maybe_b, j| {
                const b = maybe_b orelse continue;
                if (!a.conflictsWith(b)) continue;
                // Never in the same wave: they would race.
                try testing.expect(placed[i].? != placed[j].?);
                // And never reordered: the earlier call runs first, so the
                // effect a model asked for second cannot land first.
                try testing.expect(placed[i].? < placed[j].?);
            }
        }
    }
}

test "every capability decides what it touches, rather than falling through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Reads overlap and writes do not. Anything unbounded is a barrier. The
    // switch in `claimOf` names every capability, so a new one added to the
    // enum fails to compile here rather than quietly running beside anything.
    const reading: tools.ToolRequest = .{ .read_file = .{ .path = "README.md" } };
    const claim = try claimOf(arena, reading);
    try testing.expectEqual(Access.read, claim.on.access);

    const running: tools.ToolRequest = .{ .execute = .{ .argv = &.{ "zig", "build" }, .workingDirectory = "." } };
    try testing.expectEqual(barrier, try claimOf(arena, running));
}
