//! Value domains, in the sense of ISO/IEC 11179-3.
//!
//! A data element says *what* is being recorded. A value domain says *which
//! values are permitted*. Separating them is what lets two elements (say, the
//! session's working directory and a tool call's working directory) share one
//! validated set of rules instead of drifting apart.

const std = @import("std");
const timeutil = @import("../core/time.zig");
const units = @import("../interop/units.zig");
const language = @import("../interop/language.zig");

pub const Datatype = enum {
    text,
    integer,
    real,
    boolean,
    /// ISO 8601 instant, stored in UTC.
    timestamp,
    /// ISO 8601 duration.
    duration,
    /// Opaque identifier issued by the workbench.
    identifier,
    /// Filesystem path.
    path,
    uri,
    /// Value drawn from an enumerated list.
    code,
    /// Number with a unit.
    quantity,
    /// Language tag validated against ISO 639-1, ISO 15924 and ISO 3166-1.
    language_tag,
    /// Content hash in the workbench's canonical form.
    content_hash,

    pub fn jsonType(self: Datatype) []const u8 {
        return switch (self) {
            .integer => "integer",
            .real => "number",
            .boolean => "boolean",
            .quantity => "object",
            else => "string",
        };
    }
};

pub const PermittedValue = struct {
    value: []const u8,
    meaning: []const u8,
    /// A retired value is still understood on input but must not be produced.
    retired: bool = false,
};

pub const ValidationError = error{
    NotPermitted,
    WrongDatatype,
    OutOfRange,
    TooLong,
    NotCanonical,
    UnitMismatch,
    UnknownCode,
};

pub const ValueDomain = struct {
    id: []const u8,
    definition: []const u8,
    datatype: Datatype,
    /// For enumerated domains.
    permitted: []const PermittedValue = &.{},
    /// For quantities: the unit every value is expressed in.
    unit: ?[]const u8 = null,
    maximum_length: ?usize = null,
    minimum: ?i64 = null,
    maximum: ?i64 = null,
    /// Free-text statement of the rule when it cannot be expressed above.
    described_rule: ?[]const u8 = null,

    pub fn isEnumerated(self: ValueDomain) bool {
        return self.permitted.len > 0;
    }

    /// Check one value written in its canonical text form.
    pub fn validate(self: ValueDomain, value: []const u8) ValidationError!void {
        if (self.maximum_length) |limit| {
            if (value.len > limit) return error.TooLong;
        }
        if (self.isEnumerated()) {
            for (self.permitted) |p| {
                if (std.mem.eql(u8, p.value, value)) return;
            }
            return error.NotPermitted;
        }
        switch (self.datatype) {
            .text, .path, .identifier, .uri => {},
            .integer => {
                const n = std.fmt.parseInt(i64, value, 10) catch return error.WrongDatatype;
                if (self.minimum) |min| {
                    if (n < min) return error.OutOfRange;
                }
                if (self.maximum) |max| {
                    if (n > max) return error.OutOfRange;
                }
            },
            .real => {
                _ = std.fmt.parseFloat(f64, value) catch return error.WrongDatatype;
            },
            .boolean => {
                if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return error.WrongDatatype;
            },
            .timestamp => {
                _ = timeutil.Timestamp.parseIso(value) catch return error.WrongDatatype;
                if (value[value.len - 1] != 'Z') return error.NotCanonical;
            },
            .duration => {
                _ = timeutil.Duration.parseIso(value) catch return error.WrongDatatype;
            },
            .quantity => {
                const space = std.mem.indexOfScalar(u8, value, ' ') orelse return error.WrongDatatype;
                _ = std.fmt.parseFloat(f64, value[0..space]) catch return error.WrongDatatype;
                const written = units.Unit.parse(value[space + 1 ..]) catch return error.WrongDatatype;
                if (self.unit) |expected_text| {
                    const expected = units.Unit.parse(expected_text) catch return error.WrongDatatype;
                    if (!written.commensurableWith(expected)) return error.UnitMismatch;
                }
            },
            .language_tag => {
                _ = language.Tag.parse(value) catch return error.UnknownCode;
            },
            .content_hash => {
                if (!std.mem.startsWith(u8, value, "b3:") or value.len != 67) return error.NotCanonical;
            },
            .code => return error.NotPermitted,
        }
    }
};

test "enumerated domains accept only listed values" {
    const domain: ValueDomain = .{
        .id = "approval-outcome",
        .definition = "result of asking a person to approve one operation",
        .datatype = .code,
        .permitted = &.{
            .{ .value = "allow_once", .meaning = "Allow this operation only this time" },
            .{ .value = "allow_always", .meaning = "Allow this operation here from now on" },
            .{ .value = "deny", .meaning = "Do not allow the operation" },
        },
    };
    try domain.validate("allow_once");
    try std.testing.expectError(error.NotPermitted, domain.validate("maybe"));
}

test "timestamps must be canonical utc" {
    const domain: ValueDomain = .{ .id = "instant", .definition = "point in time", .datatype = .timestamp };
    try domain.validate("2026-09-04T20:41:31Z");
    try std.testing.expectError(error.NotCanonical, domain.validate("2026-09-04T22:41:31+02:00"));
    try std.testing.expectError(error.WrongDatatype, domain.validate("yesterday"));
}

test "quantities must use a commensurable unit" {
    const domain: ValueDomain = .{
        .id = "keystroke-latency",
        .definition = "time between a key press and the frame that shows it",
        .datatype = .quantity,
        .unit = "ms",
    };
    try domain.validate("8.5 ms");
    try domain.validate("0.5 s");
    try std.testing.expectError(error.UnitMismatch, domain.validate("8.5 m"));
    try std.testing.expectError(error.WrongDatatype, domain.validate("8.5"));
}

test "ranges and lengths are enforced" {
    const domain: ValueDomain = .{
        .id = "exit-status",
        .definition = "status a process returned when it finished",
        .datatype = .integer,
        .minimum = 0,
        .maximum = 255,
    };
    try domain.validate("0");
    try std.testing.expectError(error.OutOfRange, domain.validate("256"));

    const short: ValueDomain = .{ .id = "label", .definition = "short label", .datatype = .text, .maximum_length = 4 };
    try std.testing.expectError(error.TooLong, short.validate("far too long"));
}
