//! Checking where a name actually goes, not only what it is called.
//!
//! The policy engine decides `network.connect` on a host, and it decides it on
//! *text*: `api.anthropic.com`, `localhost:11434`, `*.internal.test`. That is
//! the right unit for a person to write a rule in, and it is not the thing a
//! socket connects to. Between the rule and the connection sits a name lookup
//! that the workspace does not control and, until this module, did not look at.
//!
//! Three things go wrong in that gap, and the third is the one that matters:
//!
//!   * **A literal address dodges the name.** A rule listing hosts by name has
//!     nothing to say about `https://169.254.169.254/`, which is the cloud
//!     metadata service on every major provider and hands out credentials to
//!     anything that asks.
//!   * **A public name resolves somewhere private.** `evil.example` with an A
//!     record of `10.0.0.5` is a request to the machine's own network, made
//!     from inside it, wearing a name the allowlist accepted.
//!   * **A name answers differently the second time.** The lookup that a check
//!     performs and the lookup that the connection performs are two separate
//!     questions, and an attacker who controls the name can answer them
//!     differently. This is DNS rebinding and it is the reason the section at
//!     the bottom of this comment exists.
//!
//! ## What is enforced
//!
//! Every address a name resolves to is classified and checked — not the first
//! one, not the one that happens to be chosen. A client is free to try any
//! address in the list, and a race that picks the bad one is exactly the case
//! worth stopping, so one bad address refuses the whole name.
//!
//! What counts as bad depends on where the connector said it lives, and the
//! two cases are opposites rather than degrees:
//!
//!   * A **local** connector — Ollama, llama.cpp, LM Studio, anything at
//!     `localhost` — must resolve onto this machine and nowhere else. A local
//!     model whose name suddenly resolves to a public address is a workspace
//!     sending its prompts somewhere it believes is its own laptop.
//!   * A **remote** connector must resolve to public address space and nothing
//!     else. This is the rule that stops the metadata service, the private
//!     network and the loopback interface, and it stops them whether the
//!     address arrived as a literal or as an answer to a question.
//!
//! ## The IPv4-mapped form is the same address
//!
//! `::ffff:169.254.169.254` is the metadata service written as IPv6, and a
//! checker that classifies IPv6 addresses by their own prefixes calls it a
//! global unicast address and lets it through. Every mapped address is unmapped
//! before it is classified, and there is a test for exactly this because it is
//! the bypass this kind of code is usually missing.
//!
//! ## What this does not close
//!
//! The connection is made by `std.http.Client`, which resolves the name again
//! when it connects. This module resolves, checks, and then hands the name
//! over — so a name that answers correctly to the check and incorrectly to the
//! connection a moment later is not caught. That is the rebinding case, it is
//! narrow, and it is real.
//!
//! Closing it needs the connection to be made to the address that was checked,
//! which means owning the socket rather than handing a URL to a client. That is
//! a larger change than this one and it is written down here rather than
//! implied away. What is closed today is every literal address, every name with
//! a bad answer, and every name whose answer set contains one bad address —
//! which is the whole of the attack that does not require controlling a
//! nameserver in real time.

const std = @import("std");
const net = std.Io.net;

/// Where an address lives.
///
/// The names are the ones the registries use, so that somebody checking this
/// against RFC 6890 or RFC 4193 is reading the same words.
pub const Reach = enum {
    /// This machine. `127.0.0.0/8`, `::1`.
    loopback,
    /// This link only, and the address the cloud metadata service answers on.
    /// `169.254.0.0/16`, `fe80::/10`.
    link_local,
    /// A private network. `10/8`, `172.16/12`, `192.168/16`, `fc00::/7`.
    private,
    /// Carrier-grade NAT, `100.64.0.0/10`. Not the public internet and not the
    /// machine's own network either.
    shared,
    /// Many machines at once. `224.0.0.0/4`, `ff00::/8`.
    multicast,
    /// "This host on this network", `0.0.0.0` and `::`. Connecting to it means
    /// connecting to this machine.
    unspecified,
    /// Reserved, documentation, benchmarking, or broadcast. Never a service.
    reserved,
    /// Ordinary public address space.
    global,

    pub fn text(self: Reach) []const u8 {
        return switch (self) {
            .loopback => "this machine",
            .link_local => "this network link",
            .private => "a private network",
            .shared => "carrier-grade NAT space",
            .multicast => "a multicast group",
            .unspecified => "the unspecified address",
            .reserved => "reserved address space",
            .global => "the public internet",
        };
    }

    /// Whether an address with this reach is on the machine doing the asking.
    pub fn isThisMachine(self: Reach) bool {
        return self == .loopback or self == .unspecified;
    }
};

/// Where a connector said it lives, and therefore what its addresses must be.
pub const Expectation = enum {
    /// A model running on this computer. Anything but loopback is wrong.
    this_machine,
    /// A provider on the internet. Anything but public address space is wrong.
    the_internet,

    pub fn accepts(self: Expectation, reach: Reach) bool {
        return switch (self) {
            .this_machine => reach.isThisMachine(),
            .the_internet => reach == .global,
        };
    }
};

/// Why a connection was refused, or that it was not.
pub const Verdict = union(enum) {
    allowed: struct {
        /// How many addresses were checked. Zero never reaches here — a name
        /// that resolves to nothing is refused rather than allowed by default,
        /// which is the direction an empty set has to fall in a security check.
        checked: usize,
    },
    refused: Refusal,

    pub fn isAllowed(self: Verdict) bool {
        return self == .allowed;
    }
};

/// A refusal, in enough detail to be read by a person and recorded.
pub const Refusal = struct {
    /// What the rule was written against.
    host: []const u8,
    /// The address that failed, rendered. Empty when the name resolved to
    /// nothing at all.
    address: []const u8,
    reach: Reach,
    expectation: Expectation,

    /// One sentence, for a person who is trying to find out what went wrong.
    pub fn writeTo(self: Refusal, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.address.len == 0) {
            try w.print("{s} does not resolve to any address.", .{self.host});
            return;
        }
        switch (self.expectation) {
            .this_machine => try w.print(
                "{s} resolves to {s}, which is {s}. A model that was supposed to be on this computer is not.",
                .{ self.host, self.address, self.reach.text() },
            ),
            .the_internet => try w.print(
                "{s} resolves to {s}, which is {s} rather than a public address. The connection was not made.",
                .{ self.host, self.address, self.reach.text() },
            ),
        }
    }

    pub fn text(self: Refusal, arena: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        try self.writeTo(&out.writer);
        return out.written();
    }
};

/// Classify an address.
///
/// IPv4-mapped IPv6 addresses are unmapped first, so `::ffff:127.0.0.1` is
/// loopback and not a global unicast address. That single line is the
/// difference between a check and the appearance of one.
pub fn reachOf(address: net.IpAddress) Reach {
    return switch (address) {
        .ip4 => |v4| reachOfIp4(v4.bytes),
        .ip6 => |v6| if (mappedIp4(v6.bytes)) |v4| reachOfIp4(v4) else reachOfIp6(v6.bytes),
    };
}

/// The IPv4 address inside an IPv4-mapped or IPv4-compatible IPv6 address.
///
/// Both forms are covered. The compatible form (`::a.b.c.d`) is deprecated and
/// still parses, so a checker that only unmaps the `::ffff:` form leaves the
/// other one open.
fn mappedIp4(bytes: [16]u8) ?[4]u8 {
    const zeros = std.mem.allEqual(u8, bytes[0..10], 0);
    if (!zeros) return null;
    if (bytes[10] == 0xff and bytes[11] == 0xff) return bytes[12..16].*;
    if (bytes[10] == 0 and bytes[11] == 0) {
        // `::` and `::1` are their own addresses, not IPv4 in disguise.
        const tail = std.mem.readInt(u32, bytes[12..16], .big);
        if (tail > 1) return bytes[12..16].*;
    }
    return null;
}

fn reachOfIp4(bytes: [4]u8) Reach {
    return switch (bytes[0]) {
        0 => if (std.mem.allEqual(u8, &bytes, 0)) .unspecified else .reserved,
        10 => .private,
        127 => .loopback,
        // 100.64.0.0/10, carrier-grade NAT.
        100 => if (bytes[1] >= 64 and bytes[1] <= 127) .shared else .global,
        // 169.254.0.0/16, which is where every cloud metadata service answers.
        169 => if (bytes[1] == 254) .link_local else .global,
        // 172.16.0.0/12.
        172 => if (bytes[1] >= 16 and bytes[1] <= 31) .private else .global,
        192 => switch (bytes[1]) {
            168 => .private,
            // 192.0.0.0/24 protocol assignments and 192.0.2.0/24 documentation.
            0 => if (bytes[2] == 0 or bytes[2] == 2) .reserved else .global,
            else => .global,
        },
        // 198.18.0.0/15 benchmarking, 198.51.100.0/24 documentation.
        198 => if (bytes[1] == 18 or bytes[1] == 19 or (bytes[1] == 51 and bytes[2] == 100)) .reserved else .global,
        // 203.0.113.0/24 documentation.
        203 => if (bytes[1] == 0 and bytes[2] == 113) .reserved else .global,
        224...239 => .multicast,
        // 240.0.0.0/4 reserved, and 255.255.255.255 broadcast inside it.
        240...255 => .reserved,
        else => .global,
    };
}

fn reachOfIp6(bytes: [16]u8) Reach {
    if (std.mem.allEqual(u8, &bytes, 0)) return .unspecified;
    if (std.mem.allEqual(u8, bytes[0..15], 0) and bytes[15] == 1) return .loopback;
    if (bytes[0] == 0xff) return .multicast;
    // fe80::/10, link-local unicast.
    if (bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0x80) return .link_local;
    // fc00::/7, unique local. Private address space by another name.
    if ((bytes[0] & 0xfe) == 0xfc) return .private;
    // 2001:db8::/32, reserved for documentation.
    if (bytes[0] == 0x20 and bytes[1] == 0x01 and bytes[2] == 0x0d and bytes[3] == 0xb8) return .reserved;
    // 2001:20::/28 ORCHIDv2 and 2001:db8 above are the two that matter; the
    // rest of 2001::/23 is IETF protocol assignment space.
    if (bytes[0] == 0x20 and bytes[1] == 0x01 and bytes[2] == 0 and (bytes[3] & 0xf8) == 0) return .reserved;
    // 100::/64, the discard prefix. A packet sent here goes nowhere.
    if (bytes[0] == 0x01 and bytes[1] == 0x00 and std.mem.allEqual(u8, bytes[2..8], 0)) return .reserved;
    return .global;
}

/// Check a set of already-resolved addresses.
///
/// Pure, so that every address family and every boundary can be tested without
/// a nameserver. `verify` is the same check with the lookup in front of it.
///
/// One bad address refuses the whole name. A client may try any address a name
/// resolves to, so allowing a name because *one* of its addresses was
/// acceptable would allow exactly the case worth stopping.
pub fn check(
    arena: std.mem.Allocator,
    host: []const u8,
    expectation: Expectation,
    addresses: []const net.IpAddress,
) !Verdict {
    if (addresses.len == 0) {
        return .{ .refused = .{
            .host = host,
            .address = "",
            .reach = .unspecified,
            .expectation = expectation,
        } };
    }
    for (addresses) |address| {
        const reach = reachOf(address);
        if (expectation.accepts(reach)) continue;
        return .{ .refused = .{
            .host = host,
            .address = try render(arena, address),
            .reach = reach,
            .expectation = expectation,
        } };
    }
    return .{ .allowed = .{ .checked = addresses.len } };
}

/// An address as text, without its port.
pub fn render(arena: std.mem.Allocator, address: net.IpAddress) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    switch (address) {
        .ip4 => |v4| try out.writer.print("{d}.{d}.{d}.{d}", .{
            v4.bytes[0], v4.bytes[1], v4.bytes[2], v4.bytes[3],
        }),
        .ip6 => |v6| {
            if (mappedIp4(v6.bytes)) |v4| {
                // Rendered as what it is, so a refusal names the address a
                // person would recognise rather than its disguise.
                try out.writer.print("{d}.{d}.{d}.{d} (written as IPv6)", .{
                    v4[0], v4[1], v4[2], v4[3],
                });
            } else {
                try out.writer.writeByte('[');
                var index: usize = 0;
                while (index < 16) : (index += 2) {
                    if (index > 0) try out.writer.writeByte(':');
                    try out.writer.print("{x}", .{std.mem.readInt(u16, v6.bytes[index..][0..2], .big)});
                }
                try out.writer.writeByte(']');
            }
        },
    }
    return out.written();
}

/// The most addresses a single name may resolve to before the guard stops
/// reading them.
///
/// A name with more answers than this is refused rather than partly checked:
/// the alternative is an unbounded read driven by whoever controls the
/// nameserver, and a partial check is not a check.
pub const max_addresses = 32;

pub const Error = error{
    /// The host is not a name or an address this build can parse.
    HostUnusable,
    /// The name could not be looked up at all.
    LookupFailed,
    /// More answers than `max_addresses`.
    TooManyAddresses,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

/// Resolve a host and check every address it answers with.
///
/// A literal address is checked without any lookup at all, which is the case a
/// name-based allowlist has nothing to say about.
pub fn verify(
    arena: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    expectation: Expectation,
) Error!Verdict {
    const name = hostWithoutPort(host);
    if (name.len == 0) return error.HostUnusable;

    // A literal first. `https://169.254.169.254/` never reaches a nameserver,
    // so a guard that only inspects lookups never sees it.
    if (net.IpAddress.parse(name, port)) |literal| {
        return check(arena, host, expectation, &.{literal});
    } else |_| {}

    const host_name = net.HostName.init(name) catch return error.HostUnusable;

    var buffer: [max_addresses + 4]net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(net.HostName.LookupResult) = .init(&buffer);
    var lookup = io.async(net.HostName.lookup, .{ host_name, io, &queue, net.HostName.LookupOptions{ .port = port } });
    defer lookup.cancel(io) catch {};

    var addresses: std.ArrayList(net.IpAddress) = .empty;
    while (queue.getOne(io)) |result| {
        switch (result) {
            .address => |address| {
                if (addresses.items.len >= max_addresses) return error.TooManyAddresses;
                try addresses.append(arena, address);
            },
            // The canonical name is not what is connected to, so it is not what
            // is checked. Checking it instead of the addresses is the mistake
            // that makes a guard look like it works.
            .canonical_name => {},
        }
    } else |err| switch (err) {
        error.Closed => {},
        error.Canceled => return error.LookupFailed,
    }

    lookup.await(io) catch return error.LookupFailed;
    return check(arena, host, expectation, addresses.items);
}

/// The address check, ready to be held by whatever makes the connection.
///
/// Carries its own `Io` because the check needs a nameserver and the transport
/// that holds it does not otherwise touch the operating system. Optional
/// everywhere it is held, so that a wire-format test need not resolve anything;
/// every path that reaches a real provider sets it.
pub const Guard = struct {
    io: std.Io,

    pub fn verify(
        self: Guard,
        arena: std.mem.Allocator,
        host: []const u8,
        port: u16,
        expectation: Expectation,
    ) Error!Verdict {
        return @import("netguard.zig").verify(arena, self.io, host, port, expectation);
    }
};

/// Strip a port, leaving the host.
///
/// The same rules as the policy engine's own: a bracketed address carries its
/// port outside the brackets, and a bare IPv6 address is nothing but colons.
/// Kept here rather than imported so that this module has no dependency on the
/// policy layer — it is checked against it by a test instead, which is the
/// relationship that would otherwise drift.
pub fn hostWithoutPort(host: []const u8) []const u8 {
    if (host.len == 0) return host;
    if (host[0] == '[') {
        if (std.mem.indexOfScalar(u8, host, ']')) |close| return host[1..close];
        return host[1..];
    }
    var colons: usize = 0;
    for (host) |byte| {
        if (byte == ':') colons += 1;
    }
    if (colons > 1) return host;
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| return host[0..colon];
    return host;
}

const testing = std.testing;

fn ip4(text: []const u8) net.IpAddress {
    return net.IpAddress.parseIp4(text, 443) catch unreachable;
}

fn ip6(text: []const u8) net.IpAddress {
    return net.IpAddress.parseIp6(text, 443) catch unreachable;
}

/// An IPv6 address built from its bytes.
///
/// Needed because two of the forms that matter here do not go through a text
/// parser at all. Zig's own IPv6 parser rejects both `::ffff:a9fe:a9fe` — the
/// hexadecimal spelling of a mapped address — and the deprecated
/// `::169.254.169.254` compatible form. Neither of those refusals protects
/// anything, because a nameserver answers an AAAA query with sixteen bytes and
/// no text at all. Classification works on the bytes, so the test does too.
fn ip6Bytes(bytes: [16]u8) net.IpAddress {
    return .{ .ip6 = .{ .bytes = bytes, .port = 443 } };
}

/// The IPv4-mapped form, `::ffff:a.b.c.d`, as bytes.
fn mapped(a: u8, b: u8, c: u8, d: u8) net.IpAddress {
    return ip6Bytes(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, a, b, c, d });
}

/// The deprecated IPv4-compatible form, `::a.b.c.d`, as bytes.
fn compatible(a: u8, b: u8, c: u8, d: u8) net.IpAddress {
    return ip6Bytes(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, a, b, c, d });
}

test "the addresses a remote provider must never resolve to" {
    // Each of these is a real attack rather than a category. The first is the
    // cloud metadata service, which hands credentials to anything on the
    // machine that asks; the rest are the machine's own network, reachable
    // from inside it under any name an allowlist happened to accept.
    const cases = [_]struct { address: net.IpAddress, reach: Reach }{
        .{ .address = ip4("169.254.169.254"), .reach = .link_local },
        .{ .address = ip4("127.0.0.1"), .reach = .loopback },
        .{ .address = ip4("127.1.2.3"), .reach = .loopback },
        .{ .address = ip4("0.0.0.0"), .reach = .unspecified },
        .{ .address = ip4("10.0.0.5"), .reach = .private },
        .{ .address = ip4("172.16.0.1"), .reach = .private },
        .{ .address = ip4("172.31.255.254"), .reach = .private },
        .{ .address = ip4("192.168.1.1"), .reach = .private },
        .{ .address = ip4("100.64.0.1"), .reach = .shared },
        .{ .address = ip4("224.0.0.1"), .reach = .multicast },
        .{ .address = ip4("255.255.255.255"), .reach = .reserved },
        .{ .address = ip4("192.0.2.1"), .reach = .reserved },
        .{ .address = ip4("198.18.0.1"), .reach = .reserved },
        .{ .address = ip4("203.0.113.7"), .reach = .reserved },
        .{ .address = ip6("::1"), .reach = .loopback },
        .{ .address = ip6("::"), .reach = .unspecified },
        .{ .address = ip6("fe80::1"), .reach = .link_local },
        .{ .address = ip6("fc00::1"), .reach = .private },
        .{ .address = ip6("fd12:3456::1"), .reach = .private },
        .{ .address = ip6("ff02::1"), .reach = .multicast },
        .{ .address = ip6("2001:db8::1"), .reach = .reserved },
    };

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (cases) |case| {
        try testing.expectEqual(case.reach, reachOf(case.address));
        const verdict = try check(arena, "provider.example", .the_internet, &.{case.address});
        try testing.expect(!verdict.isAllowed());
        try testing.expectEqual(case.reach, verdict.refused.reach);
    }
}

test "the addresses a remote provider is allowed to resolve to" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Ordinary public addresses, including the ones next door to a reserved
    // range. A classifier that used a whole /8 where the registry says a /24
    // would refuse real providers, and a refusal nobody can explain is how a
    // security control gets switched off.
    for ([_]net.IpAddress{
        ip4("160.79.104.10"),
        ip4("8.8.8.8"),
        ip4("100.63.255.255"),
        ip4("100.128.0.1"),
        ip4("169.253.0.1"),
        ip4("169.255.0.1"),
        ip4("172.15.0.1"),
        ip4("172.32.0.1"),
        ip4("192.0.1.1"),
        ip4("192.0.3.1"),
        ip4("192.167.0.1"),
        ip4("192.169.0.1"),
        ip4("198.20.0.1"),
        ip4("198.51.101.1"),
        ip4("203.0.114.1"),
        ip6("2606:4700::1111"),
        ip6("2001:db9::1"),
    }) |address| {
        try testing.expectEqual(Reach.global, reachOf(address));
        const verdict = try check(arena, "api.example.com", .the_internet, &.{address});
        try testing.expect(verdict.isAllowed());
    }
}

test "an IPv4 address wearing an IPv6 costume is the same address" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // This is the bypass this kind of code is usually missing. A checker that
    // reads IPv6 prefixes and stops calls every one of these a global unicast
    // address and lets the connection through.
    const disguised = [_]struct { address: net.IpAddress, reach: Reach }{
        // The mapped form, spelled the way a URL would carry it.
        .{ .address = ip6("::ffff:169.254.169.254"), .reach = .link_local },
        .{ .address = ip6("::ffff:127.0.0.1"), .reach = .loopback },
        .{ .address = ip6("::ffff:10.0.0.5"), .reach = .private },
        .{ .address = ip6("::ffff:192.168.1.1"), .reach = .private },
        // The same addresses as bytes, which is how a AAAA answer arrives. The
        // hexadecimal spelling `::ffff:a9fe:a9fe` has no text parser here at
        // all, so a check written against text would never see it.
        .{ .address = mapped(169, 254, 169, 254), .reach = .link_local },
        .{ .address = mapped(127, 0, 0, 1), .reach = .loopback },
        .{ .address = mapped(192, 168, 1, 1), .reach = .private },
        // The deprecated IPv4-compatible form.
        .{ .address = compatible(169, 254, 169, 254), .reach = .link_local },
        .{ .address = compatible(10, 0, 0, 5), .reach = .private },
    };

    for (disguised) |case| {
        const address = case.address;
        try testing.expectEqual(case.reach, reachOf(address));
        const verdict = try check(arena, "evil.example", .the_internet, &.{address});
        try testing.expect(!verdict.isAllowed());

        // And the refusal names the address a person would recognise, rather
        // than the form it arrived in.
        try testing.expect(std.mem.indexOf(u8, verdict.refused.address, "written as IPv6") != null);
    }

    // `::1` and `::` are their own addresses and must not be unmapped into
    // 0.0.0.1 and 0.0.0.0, which would give the right answer for the wrong
    // reason and the wrong answer as soon as the ranges moved.
    try testing.expectEqual(Reach.loopback, reachOf(ip6("::1")));
    try testing.expectEqual(Reach.unspecified, reachOf(ip6("::")));
}

test "one bad address refuses the whole name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A client may try any address a name answers with, so a name is only as
    // safe as its worst answer. Checking the first one, or accepting the name
    // because one answer was fine, allows exactly the case worth stopping.
    const mixed = [_]net.IpAddress{
        ip4("160.79.104.10"),
        ip4("8.8.8.8"),
        ip4("169.254.169.254"),
        ip4("1.1.1.1"),
    };
    const verdict = try check(arena, "half.example", .the_internet, &mixed);
    try testing.expect(!verdict.isAllowed());
    try testing.expectEqual(Reach.link_local, verdict.refused.reach);
    try testing.expectEqualStrings("169.254.169.254", verdict.refused.address);
}

test "a name that resolves to nothing is refused, not allowed by default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The direction an empty set has to fall in a security check. A loop over
    // zero addresses that ends in "allowed" is the most common way a guard
    // like this fails open.
    const verdict = try check(arena, "nowhere.example", .the_internet, &.{});
    try testing.expect(!verdict.isAllowed());
    const message = try verdict.refused.text(arena);
    try testing.expect(std.mem.indexOf(u8, message, "does not resolve") != null);
}

test "a local model must be local, and the check runs the other way" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Ollama on this laptop.
    for ([_]net.IpAddress{ ip4("127.0.0.1"), ip6("::1"), ip4("0.0.0.0") }) |address| {
        try testing.expect((try check(arena, "localhost:11434", .this_machine, &.{address})).isAllowed());
    }

    // The same name, answering with a public address. A workspace that thinks
    // it is talking to its own machine and is not is sending its prompts to a
    // stranger, which is the worse of the two directions.
    const stolen = try check(arena, "localhost:11434", .this_machine, &.{ip4("160.79.104.10")});
    try testing.expect(!stolen.isAllowed());
    const message = try stolen.refused.text(arena);
    try testing.expect(std.mem.indexOf(u8, message, "supposed to be on this computer") != null);

    // A private address is not this machine either. It is somebody else's.
    try testing.expect(!(try check(arena, "localhost", .this_machine, &.{ip4("192.168.1.50")})).isAllowed());
}

test "an expectation accepts exactly one class of address" {
    // Written as a table over every reach so that adding a new one has to
    // decide, in both directions, rather than falling through a default.
    for (std.enums.values(Reach)) |reach| {
        const local = Expectation.this_machine.accepts(reach);
        const remote = Expectation.the_internet.accepts(reach);
        // No reach is acceptable to both. That would mean an address that is
        // simultaneously this machine and the public internet.
        try testing.expect(!(local and remote));
        switch (reach) {
            .loopback, .unspecified => try testing.expect(local),
            .global => try testing.expect(remote),
            else => try testing.expect(!local and !remote),
        }
    }
}

test "a literal address is checked without any lookup" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The case a host allowlist written in names has nothing to say about.
    // There is no nameserver in this test, and there does not need to be.
    const metadata = try verify(arena, io, "169.254.169.254", 80, .the_internet);
    try testing.expect(!metadata.isAllowed());
    try testing.expectEqual(Reach.link_local, metadata.refused.reach);

    const loopback = try verify(arena, io, "127.0.0.1:8080", 8080, .the_internet);
    try testing.expect(!loopback.isAllowed());
    try testing.expectEqual(Reach.loopback, loopback.refused.reach);

    // Bracketed IPv6 with a port, which is where a hand-rolled parser usually
    // gives up and passes the whole string to a resolver.
    const bracketed = try verify(arena, io, "[::ffff:169.254.169.254]:443", 443, .the_internet);
    try testing.expect(!bracketed.isAllowed());
    try testing.expectEqual(Reach.link_local, bracketed.refused.reach);

    // And the same literal is fine for a local model.
    try testing.expect((try verify(arena, io, "127.0.0.1:11434", 11434, .this_machine)).isAllowed());
}

test "the port is stripped the same way the policy engine strips it" {
    // Two definitions of "the host part" that disagree is the defect this
    // repository already found once, between the policy and the executor. The
    // two live in different modules on purpose; this is what stops them
    // drifting apart again.
    const policy = @import("../ai/policy.zig");
    for ([_][]const u8{
        "api.example.com",
        "api.example.com:443",
        "localhost:11434",
        "::1",
        "[::1]:8080",
        "[2001:db8::1]:443",
        "127.0.0.1:80",
        "",
    }) |host| {
        try testing.expectEqualStrings(policy.hostWithoutPort(host), hostWithoutPort(host));
    }
}

test "a refusal says what happened in words a person can act on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const verdict = try check(arena, "api.provider.example", .the_internet, &.{ip4("169.254.169.254")});
    const message = try verdict.refused.text(arena);

    // Names the host, the address and what is wrong with it. A message that
    // only said "refused" would send somebody to read this file.
    try testing.expect(std.mem.indexOf(u8, message, "api.provider.example") != null);
    try testing.expect(std.mem.indexOf(u8, message, "169.254.169.254") != null);
    try testing.expect(std.mem.indexOf(u8, message, "this network link") != null);
}

test "every reach names itself, and no two share a name" {
    for (std.enums.values(Reach)) |reach| {
        try testing.expect(reach.text().len > 0);
        for (std.enums.values(Reach)) |other| {
            if (reach == other) continue;
            try testing.expect(!std.mem.eql(u8, reach.text(), other.text()));
        }
    }
}
