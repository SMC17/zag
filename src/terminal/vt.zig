//! Terminal escape-sequence parser.
//!
//! This is a straight implementation of the DEC ANSI state machine (the one
//! Paul Williams documented), with UTF-8 decoding in the ground state.
//!
//! A note on where this sits. Terminal emulation is *infrastructure*: it is
//! well specified, hard to get right, and identical for everyone. The workbench
//! is designed so that this module can be replaced by `libghostty-vt` behind
//! the `Backend` seam in `backend.zig` without touching the block model, the
//! event log or the user interface, which is where the product actually lives.
//! Until that dependency is vendored, this parser keeps the system honest: it
//! is complete enough to drive the grid, the shell integration marks and the
//! tests, and it makes no claim to be a full terminal.

const std = @import("std");

pub const max_params = 16;
pub const max_intermediates = 2;
pub const max_string = 4096;

pub const CsiCommand = struct {
    /// Numeric parameters. An omitted parameter is reported as 0.
    params: []const u16,
    /// Sub-parameters, as in `38:2:255:0:0`, flattened alongside `params`.
    /// `param_is_sub[i]` is true when `params[i]` continues the previous one.
    param_is_sub: []const bool,
    intermediates: []const u8,
    /// `?` in `CSI ? 25 h`, or another private marker.
    private: ?u8,
    final: u8,

    /// Parameter at `index`, or `fallback` when absent or zero.
    pub fn param(self: CsiCommand, index: usize, fallback: u16) u16 {
        if (index >= self.params.len) return fallback;
        if (self.params[index] == 0) return fallback;
        return self.params[index];
    }

    pub fn rawParam(self: CsiCommand, index: usize, fallback: u16) u16 {
        if (index >= self.params.len) return fallback;
        return self.params[index];
    }
};

pub const EscCommand = struct {
    intermediates: []const u8,
    final: u8,
};

pub const OscCommand = struct {
    /// The whole string between the introducer and the terminator.
    raw: []const u8,

    /// The numeric command, when the string starts with digits and `;`.
    pub fn command(self: OscCommand) ?u32 {
        const end = std.mem.indexOfScalar(u8, self.raw, ';') orelse self.raw.len;
        if (end == 0) return null;
        return std.fmt.parseInt(u32, self.raw[0..end], 10) catch null;
    }

    /// Everything after the first `;`.
    pub fn payload(self: OscCommand) []const u8 {
        const semi = std.mem.indexOfScalar(u8, self.raw, ';') orelse return "";
        return self.raw[semi + 1 ..];
    }
};

pub const Action = union(enum) {
    /// A printable character, already decoded from UTF-8.
    print: u21,
    /// A C0 or C1 control character to execute.
    execute: u8,
    csi: CsiCommand,
    esc: EscCommand,
    osc: OscCommand,
    /// A device control string, delivered whole.
    dcs: struct { params: []const u16, intermediates: []const u8, final: u8, data: []const u8 },
    /// An invalid UTF-8 sequence was replaced by U+FFFD.
    invalid_utf8,
};

const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    osc_string,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_passthrough,
    dcs_ignore,
    sos_pm_apc_string,
};

pub const Parser = struct {
    state: State = .ground,

    params: [max_params]u16 = undefined,
    param_is_sub: [max_params]bool = undefined,
    param_count: usize = 0,
    param_started: bool = false,
    params_overflowed: bool = false,

    intermediates: [max_intermediates]u8 = undefined,
    intermediate_count: usize = 0,
    intermediates_overflowed: bool = false,
    private: ?u8 = null,

    string: [max_string]u8 = undefined,
    string_len: usize = 0,
    string_truncated: bool = false,

    /// Final byte of the device control string being collected.
    dcs_final: u8 = 0,

    /// UTF-8 decoding state for the ground state.
    utf8_remaining: u3 = 0,
    utf8_value: u21 = 0,
    utf8_seen: [4]u8 = undefined,
    utf8_len: u3 = 0,

    pub fn init() Parser {
        return .{};
    }

    pub fn reset(self: *Parser) void {
        self.* = .{};
    }

    /// Feed one byte. Returns the action it completes, if any.
    ///
    /// Slices inside the returned action point into the parser and stay valid
    /// only until the next call. Callers that keep them must copy.
    pub fn advance(self: *Parser, byte: u8) ?Action {
        // C0 controls act immediately in every state except the string states,
        // which is what makes a terminal recover from a truncated sequence.
        switch (self.state) {
            .osc_string, .sos_pm_apc_string, .dcs_passthrough, .dcs_ignore => {},
            else => {
                if (byte == 0x1b) {
                    self.clear();
                    self.state = .escape;
                    return null;
                }
                if (byte == 0x18 or byte == 0x1a) { // CAN, SUB
                    self.state = .ground;
                    return .{ .execute = byte };
                }
                if (byte < 0x20) {
                    if (self.state == .ground and self.utf8_remaining > 0) {
                        // A control byte interrupts a partial character.
                        self.utf8_remaining = 0;
                        return .invalid_utf8;
                    }
                    return .{ .execute = byte };
                }
            },
        }

        return switch (self.state) {
            .ground => self.ground(byte),
            .escape => self.escape(byte),
            .escape_intermediate => self.escapeIntermediate(byte),
            .csi_entry => self.csiEntry(byte),
            .csi_param => self.csiParam(byte),
            .csi_intermediate => self.csiIntermediate(byte),
            .csi_ignore => self.csiIgnore(byte),
            .osc_string => self.oscString(byte),
            .dcs_entry, .dcs_param, .dcs_intermediate => self.dcsPrelude(byte),
            .dcs_passthrough => self.dcsPassthrough(byte),
            .dcs_ignore => self.stringIgnore(byte),
            .sos_pm_apc_string => self.stringIgnore(byte),
        };
    }

    /// Feed a slice, appending each action to `out`.
    pub fn feed(self: *Parser, arena: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(Action)) !void {
        for (bytes) |byte| {
            if (self.advance(byte)) |action| try out.append(arena, action);
        }
    }

    fn clear(self: *Parser) void {
        self.param_count = 0;
        self.param_started = false;
        self.params_overflowed = false;
        self.intermediate_count = 0;
        self.intermediates_overflowed = false;
        self.private = null;
        self.string_len = 0;
        self.string_truncated = false;
    }

    fn ground(self: *Parser, byte: u8) ?Action {
        if (self.utf8_remaining > 0) {
            if (byte & 0xc0 != 0x80) {
                self.utf8_remaining = 0;
                self.utf8_len = 0;
                return .invalid_utf8;
            }
            self.utf8_value = (self.utf8_value << 6) | (byte & 0x3f);
            self.utf8_seen[self.utf8_len] = byte;
            self.utf8_len += 1;
            self.utf8_remaining -= 1;
            if (self.utf8_remaining == 0) {
                const value = self.utf8_value;
                self.utf8_len = 0;
                // Reject over-long encodings and surrogates.
                if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return .invalid_utf8;
                return .{ .print = value };
            }
            return null;
        }

        if (byte < 0x80) return .{ .print = byte };
        if (byte & 0xe0 == 0xc0) {
            self.utf8_value = byte & 0x1f;
            self.utf8_remaining = 1;
            self.utf8_len = 1;
            self.utf8_seen[0] = byte;
            return null;
        }
        if (byte & 0xf0 == 0xe0) {
            self.utf8_value = byte & 0x0f;
            self.utf8_remaining = 2;
            self.utf8_len = 1;
            self.utf8_seen[0] = byte;
            return null;
        }
        if (byte & 0xf8 == 0xf0) {
            self.utf8_value = byte & 0x07;
            self.utf8_remaining = 3;
            self.utf8_len = 1;
            self.utf8_seen[0] = byte;
            return null;
        }
        return .invalid_utf8;
    }

    fn escape(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x20...0x2f => {
                self.collectIntermediate(byte);
                self.state = .escape_intermediate;
                return null;
            },
            '[' => {
                self.state = .csi_entry;
                return null;
            },
            ']' => {
                self.state = .osc_string;
                return null;
            },
            'P' => {
                self.state = .dcs_entry;
                return null;
            },
            'X', '^', '_' => {
                self.state = .sos_pm_apc_string;
                return null;
            },
            0x30...0x4f, 0x51...0x57, 0x59, 0x5a, 0x5c, 0x60...0x7e => {
                self.state = .ground;
                return .{ .esc = .{ .intermediates = self.intermediates[0..self.intermediate_count], .final = byte } };
            },
            else => {
                self.state = .ground;
                return null;
            },
        }
    }

    fn escapeIntermediate(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x20...0x2f => {
                self.collectIntermediate(byte);
                return null;
            },
            0x30...0x7e => {
                self.state = .ground;
                return .{ .esc = .{ .intermediates = self.intermediates[0..self.intermediate_count], .final = byte } };
            },
            else => {
                self.state = .ground;
                return null;
            },
        }
    }

    fn csiEntry(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            '0'...'9' => {
                self.state = .csi_param;
                return self.csiParam(byte);
            },
            ';', ':' => {
                self.state = .csi_param;
                return self.csiParam(byte);
            },
            '<'...'?' => {
                self.private = byte;
                self.state = .csi_param;
                return null;
            },
            0x20...0x2f => {
                self.collectIntermediate(byte);
                self.state = .csi_intermediate;
                return null;
            },
            0x40...0x7e => return self.dispatchCsi(byte),
            else => {
                self.state = .csi_ignore;
                return null;
            },
        }
    }

    fn csiParam(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            '0'...'9' => {
                if (!self.param_started) {
                    self.pushParam(0, false);
                    self.param_started = true;
                }
                if (self.param_count > 0 and self.param_count <= max_params) {
                    const slot = &self.params[self.param_count - 1];
                    const digit: u16 = byte - '0';
                    // Values are clamped rather than wrapped: a terminal that
                    // wraps a parameter jumps the cursor somewhere absurd.
                    slot.* = std.math.mul(u16, slot.*, 10) catch 65535;
                    slot.* = std.math.add(u16, slot.*, digit) catch 65535;
                }
                return null;
            },
            ';' => {
                if (!self.param_started) self.pushParam(0, false);
                self.param_started = false;
                return null;
            },
            ':' => {
                if (!self.param_started) self.pushParam(0, false);
                self.pushParam(0, true);
                self.param_started = true;
                return null;
            },
            0x20...0x2f => {
                self.collectIntermediate(byte);
                self.state = .csi_intermediate;
                return null;
            },
            '<'...'?' => {
                self.state = .csi_ignore;
                return null;
            },
            0x40...0x7e => return self.dispatchCsi(byte),
            else => {
                self.state = .csi_ignore;
                return null;
            },
        }
    }

    fn csiIntermediate(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x20...0x2f => {
                self.collectIntermediate(byte);
                return null;
            },
            0x40...0x7e => return self.dispatchCsi(byte),
            else => {
                self.state = .csi_ignore;
                return null;
            },
        }
    }

    fn csiIgnore(self: *Parser, byte: u8) ?Action {
        if (byte >= 0x40 and byte <= 0x7e) self.state = .ground;
        return null;
    }

    fn dispatchCsi(self: *Parser, final: u8) ?Action {
        self.state = .ground;
        if (!self.param_started and self.param_count == 0) {
            // No parameters at all.
        }
        if (self.params_overflowed or self.intermediates_overflowed) return null;
        return .{ .csi = .{
            .params = self.params[0..self.param_count],
            .param_is_sub = self.param_is_sub[0..self.param_count],
            .intermediates = self.intermediates[0..self.intermediate_count],
            .private = self.private,
            .final = final,
        } };
    }

    fn oscString(self: *Parser, byte: u8) ?Action {
        // BEL and ST both terminate an OSC string.
        if (byte == 0x07) {
            self.state = .ground;
            return .{ .osc = .{ .raw = self.string[0..self.string_len] } };
        }
        if (byte == 0x1b) {
            // Expect ST (`ESC \`); anything else restarts a sequence.
            self.state = .ground;
            const action: Action = .{ .osc = .{ .raw = self.string[0..self.string_len] } };
            return action;
        }
        if (byte == 0x9c) {
            self.state = .ground;
            return .{ .osc = .{ .raw = self.string[0..self.string_len] } };
        }
        self.pushString(byte);
        return null;
    }

    fn dcsPrelude(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            '0'...'9' => {
                if (!self.param_started) {
                    self.pushParam(0, false);
                    self.param_started = true;
                }
                if (self.param_count > 0) {
                    const slot = &self.params[self.param_count - 1];
                    slot.* = std.math.mul(u16, slot.*, 10) catch 65535;
                    slot.* = std.math.add(u16, slot.*, byte - '0') catch 65535;
                }
                self.state = .dcs_param;
                return null;
            },
            ';' => {
                if (!self.param_started) self.pushParam(0, false);
                self.param_started = false;
                self.state = .dcs_param;
                return null;
            },
            0x20...0x2f => {
                self.collectIntermediate(byte);
                self.state = .dcs_intermediate;
                return null;
            },
            0x40...0x7e => {
                self.string_len = 0;
                self.dcs_final = byte;
                self.state = .dcs_passthrough;
                return null;
            },
            else => {
                self.state = .dcs_ignore;
                return null;
            },
        }
    }

    fn dcsPassthrough(self: *Parser, byte: u8) ?Action {
        if (byte == 0x1b or byte == 0x9c) {
            self.state = .ground;
            return .{ .dcs = .{
                .params = self.params[0..self.param_count],
                .intermediates = self.intermediates[0..self.intermediate_count],
                .final = self.dcs_final,
                .data = self.string[0..self.string_len],
            } };
        }
        self.pushString(byte);
        return null;
    }

    fn stringIgnore(self: *Parser, byte: u8) ?Action {
        if (byte == 0x1b or byte == 0x07 or byte == 0x9c) self.state = .ground;
        return null;
    }

    fn pushParam(self: *Parser, value: u16, is_sub: bool) void {
        if (self.param_count >= max_params) {
            self.params_overflowed = true;
            return;
        }
        self.params[self.param_count] = value;
        self.param_is_sub[self.param_count] = is_sub;
        self.param_count += 1;
    }

    fn collectIntermediate(self: *Parser, byte: u8) void {
        if (self.intermediate_count >= max_intermediates) {
            self.intermediates_overflowed = true;
            return;
        }
        self.intermediates[self.intermediate_count] = byte;
        self.intermediate_count += 1;
    }

    fn pushString(self: *Parser, byte: u8) void {
        if (self.string_len >= max_string) {
            self.string_truncated = true;
            return;
        }
        self.string[self.string_len] = byte;
        self.string_len += 1;
    }
};

const testing = std.testing;

fn collect(arena: std.mem.Allocator, bytes: []const u8) !std.ArrayList(Action) {
    var parser = Parser.init();
    var out: std.ArrayList(Action) = .empty;
    for (bytes) |byte| {
        if (parser.advance(byte)) |action| {
            // Copy the slices so that later bytes cannot invalidate them.
            const copied: Action = switch (action) {
                .csi => |c| .{ .csi = .{
                    .params = try arena.dupe(u16, c.params),
                    .param_is_sub = try arena.dupe(bool, c.param_is_sub),
                    .intermediates = try arena.dupe(u8, c.intermediates),
                    .private = c.private,
                    .final = c.final,
                } },
                .osc => |o| .{ .osc = .{ .raw = try arena.dupe(u8, o.raw) } },
                .esc => |e| .{ .esc = .{ .intermediates = try arena.dupe(u8, e.intermediates), .final = e.final } },
                .dcs => |d| .{ .dcs = .{
                    .params = try arena.dupe(u16, d.params),
                    .intermediates = try arena.dupe(u8, d.intermediates),
                    .final = d.final,
                    .data = try arena.dupe(u8, d.data),
                } },
                else => action,
            };
            try out.append(arena, copied);
        }
    }
    return out;
}

test "prints plain text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const actions = try collect(arena, "hi");
    try testing.expectEqual(@as(usize, 2), actions.items.len);
    try testing.expectEqual(@as(u21, 'h'), actions.items[0].print);
    try testing.expectEqual(@as(u21, 'i'), actions.items[1].print);
}

test "decodes utf-8, including characters outside the basic plane" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const actions = try collect(arena, "é中🙂");
    try testing.expectEqual(@as(usize, 3), actions.items.len);
    try testing.expectEqual(@as(u21, 0xe9), actions.items[0].print);
    try testing.expectEqual(@as(u21, 0x4e2d), actions.items[1].print);
    try testing.expectEqual(@as(u21, 0x1f642), actions.items[2].print);

    const broken = try collect(arena, "\xc3\x28");
    try testing.expectEqual(Action.invalid_utf8, broken.items[0]);
}

test "parses csi sequences with parameters and private markers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const actions = try collect(arena, "\x1b[12;40H\x1b[?25l\x1b[38:2:255:0:0m");
    try testing.expectEqual(@as(usize, 3), actions.items.len);

    const cup = actions.items[0].csi;
    try testing.expectEqual(@as(u8, 'H'), cup.final);
    try testing.expectEqual(@as(u16, 12), cup.param(0, 1));
    try testing.expectEqual(@as(u16, 40), cup.param(1, 1));
    try testing.expect(cup.private == null);

    const hide = actions.items[1].csi;
    try testing.expectEqual(@as(u8, '?'), hide.private.?);
    try testing.expectEqual(@as(u16, 25), hide.param(0, 0));
    try testing.expectEqual(@as(u8, 'l'), hide.final);

    const colour = actions.items[2].csi;
    try testing.expectEqual(@as(usize, 5), colour.params.len);
    try testing.expectEqual(@as(u16, 38), colour.params[0]);
    try testing.expect(colour.param_is_sub[1]);
    try testing.expectEqual(@as(u16, 255), colour.params[2]);
}

test "parses osc strings ended by bel or st" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bel = try collect(arena, "\x1b]0;zag workbench\x07");
    try testing.expectEqual(@as(u32, 0), bel.items[0].osc.command().?);
    try testing.expectEqualStrings("zag workbench", bel.items[0].osc.payload());

    const st = try collect(arena, "\x1b]133;A\x1b\\");
    try testing.expectEqual(@as(u32, 133), st.items[0].osc.command().?);
    try testing.expectEqualStrings("A", st.items[0].osc.payload());
}

test "executes control characters and recovers from a truncated sequence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const actions = try collect(arena, "a\r\nb");
    try testing.expectEqual(@as(u21, 'a'), actions.items[0].print);
    try testing.expectEqual(@as(u8, '\r'), actions.items[1].execute);
    try testing.expectEqual(@as(u8, '\n'), actions.items[2].execute);
    try testing.expectEqual(@as(u21, 'b'), actions.items[3].print);

    // An escape in the middle of a sequence abandons it, as a terminal does.
    const recovered = try collect(arena, "\x1b[12;\x1b[H!");
    try testing.expectEqual(@as(u8, 'H'), recovered.items[0].csi.final);
    try testing.expectEqual(@as(u21, '!'), recovered.items[1].print);
}

test "parses escape and device control strings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const esc = try collect(arena, "\x1b(B");
    try testing.expectEqual(@as(u8, 'B'), esc.items[0].esc.final);
    try testing.expectEqual(@as(u8, '('), esc.items[0].esc.intermediates[0]);

    const dcs = try collect(arena, "\x1bP1$qm\x1b\\");
    try testing.expectEqual(@as(u8, 'q'), dcs.items[0].dcs.final);
    try testing.expectEqualStrings("m", dcs.items[0].dcs.data);
}

test "parameter values are clamped rather than wrapped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const actions = try collect(arena, "\x1b[999999999H");
    try testing.expectEqual(@as(u16, 65535), actions.items[0].csi.params[0]);
}
