//! Who wrote a record.
//!
//! Every event carries an actor, and until now every actor written by the
//! product was sixteen zero bytes. Three programs — the command-line tool, the
//! recording terminal and the daemon — all wrote the same identifier, so the
//! envelope could not answer the one question an audit trail exists to answer.
//! Worse, it could not distinguish a person from the workbench acting on its
//! own, which is the distinction the whole governance layer is built on.
//!
//! ## What an identity is here
//!
//! It is a stable name for *an account on a machine*, and nothing more. It is
//! derived, not stored: the same person on the same computer gets the same
//! identifier in every workspace, on the first run, with no file to create and
//! nothing to migrate. Two people on one machine differ. One person on two
//! machines differs, which is correct — those are two places work can happen
//! and the record should say which.
//!
//! ## What it is not
//!
//! It is not a claim about a human being. It cannot be, because nothing here
//! verifies anything: the name comes from the environment, and a person who
//! edits their own environment can write whatever they like into their own
//! record. That is fine for what this is for — reading back what happened on
//! your own machine — and it is not fine as evidence about somebody else. A
//! deployment that needs the second thing needs a signed identity, and does not
//! have one yet.
//!
//! ## Why it is derived rather than random
//!
//! A random identifier stored in the workspace would be stable too, and would
//! need a file, a first-run path, a migration, and an answer for what happens
//! when the file is deleted or copied along with the repository. Deriving it
//! from the account name and the machine name costs none of that, and gives the
//! property that actually matters: the same person is recognisably the same
//! person across every workspace they open.

const std = @import("std");
const idmod = @import("id.zig");
const hashing = @import("hash.zig");
const provenance = @import("../data/provenance.zig");

pub const ActorId = idmod.ActorId;

/// An actor, ready to be put on an event.
pub const Identity = struct {
    id: ActorId,
    kind: provenance.ProducerKind,
    /// What a person reads. Never used to decide anything.
    label: []const u8,
};

/// Build an identifier from text, deterministically.
///
/// The identifier is the first sixteen bytes of the hash of a namespaced
/// string. An actor is not an event, so nothing asks it when it was created,
/// and the timestamp bytes a generated identifier would carry are spent on more
/// hash instead.
pub fn idFrom(namespace: []const u8, name: []const u8) ActorId {
    const digest = hashing.Hash.ofParts(&.{ namespace, name });
    var bytes: [16]u8 = undefined;
    @memcpy(&bytes, digest.bytes[0..16]);
    return ActorId.fromRaw(.{ .bytes = bytes });
}

/// Look a variable up in an environment given as `NAME=value` entries.
///
/// The environment is passed in rather than read, so that this is testable and
/// so that nothing in the library reaches for the process on its own.
pub fn lookup(environment: []const []const u8, name: []const u8) ?[]const u8 {
    for (environment) |entry| {
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (!std.mem.eql(u8, entry[0..equals], name)) continue;
        const value = entry[equals + 1 ..];
        return if (value.len > 0) value else null;
    }
    return null;
}

/// The person at this computer.
///
/// The account name comes from `USER`, then `LOGNAME`, then `USERNAME` for a
/// Windows shell. The machine name comes from `HOSTNAME` or `COMPUTERNAME`.
/// When neither is set the identity is still stable — it is the identity of
/// "somebody on a machine that does not say who it is", which is a true
/// statement and a useful one to be able to tell apart from a named account.
pub fn person(arena: std.mem.Allocator, environment: []const []const u8) !Identity {
    const account = lookup(environment, "USER") orelse
        lookup(environment, "LOGNAME") orelse
        lookup(environment, "USERNAME");
    const machine = lookup(environment, "HOSTNAME") orelse
        lookup(environment, "COMPUTERNAME");

    const key = try std.fmt.allocPrint(arena, "{s}@{s}", .{
        account orelse "unnamed-account",
        machine orelse "unnamed-machine",
    });

    return .{
        .id = idFrom("person", key),
        .kind = .person,
        // The label is what a person reads in their own record. Their own
        // account name is the thing they will recognise; "you" is what to say
        // when the environment did not offer one.
        .label = account orelse "you",
    };
}

/// The workbench itself, acting on its own behalf.
///
/// Used for the events a program writes because it is doing its job rather than
/// because a person asked for something: opening a workspace, recording that a
/// check ran. Keeping this distinct from a person is the point — a governance
/// framework that cannot tell an automated action from a human one is not
/// describing anything.
pub fn program(name: []const u8) Identity {
    return .{
        .id = idFrom("program", name),
        .kind = .system,
        .label = name,
    };
}

/// An agent the workbench is running.
pub fn agent(label: []const u8) Identity {
    return .{
        .id = idFrom("agent", label),
        .kind = .agent,
        .label = label,
    };
}

const testing = std.testing;

test "the same account on the same machine is the same actor, every time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const environment = [_][]const u8{ "PATH=/usr/bin", "USER=sean", "HOSTNAME=workshop" };
    const first = try person(arena, &environment);
    const second = try person(arena, &environment);
    try testing.expect(first.id.eql(second.id));
    try testing.expectEqualStrings("sean", first.label);
    try testing.expectEqual(provenance.ProducerKind.person, first.kind);

    // The identity does not depend on the order of the environment, or on what
    // else is in it.
    const shuffled = [_][]const u8{ "HOSTNAME=workshop", "TERM=xterm", "USER=sean" };
    try testing.expect(first.id.eql((try person(arena, &shuffled)).id));
}

test "two people, and two machines, are told apart" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const here = try person(arena, &.{ "USER=sean", "HOSTNAME=workshop" });
    const colleague = try person(arena, &.{ "USER=alex", "HOSTNAME=workshop" });
    const elsewhere = try person(arena, &.{ "USER=sean", "HOSTNAME=laptop" });

    try testing.expect(!here.id.eql(colleague.id));
    // The same person on another machine is another place work happened, and
    // the record should be able to say which.
    try testing.expect(!here.id.eql(elsewhere.id));
}

test "an environment that says nothing still gives a stable identity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const anonymous = try person(arena, &.{"PATH=/usr/bin"});
    const again = try person(arena, &.{});
    try testing.expect(anonymous.id.eql(again.id));
    try testing.expectEqualStrings("you", anonymous.label);

    // And it is not the zero identifier, which is what every event used to
    // carry and what nothing should carry.
    const zero = ActorId.fromRaw(.{ .bytes = [_]u8{0} ** 16 });
    try testing.expect(!anonymous.id.eql(zero));

    // A named account is a different actor from an unnamed one, so a record
    // cannot quietly merge them.
    const named = try person(arena, &.{ "USER=sean", "HOSTNAME=workshop" });
    try testing.expect(!anonymous.id.eql(named.id));
}

test "a person, a program and an agent are never the same actor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const human = try person(arena, &.{ "USER=zag", "HOSTNAME=zag" });
    const tool = program("zag");
    const robot = agent("zag");

    // The names collide on purpose. The namespace is what keeps them apart, so
    // an automated action can never be read as a human one.
    try testing.expect(!human.id.eql(tool.id));
    try testing.expect(!human.id.eql(robot.id));
    try testing.expect(!tool.id.eql(robot.id));

    try testing.expectEqual(provenance.ProducerKind.system, tool.kind);
    try testing.expectEqual(provenance.ProducerKind.agent, robot.kind);
}

test "an identifier is text a person can read back and compare" {
    const tool = program("zagd");
    var buffer: [ActorId.text_len]u8 = undefined;
    const text = tool.id.toText(&buffer);
    try testing.expect(std.mem.startsWith(u8, text, "act_"));
    const parsed = try ActorId.parse(text);
    try testing.expect(tool.id.eql(parsed));
}
