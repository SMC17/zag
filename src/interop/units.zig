//! Quantities, SI units and UCUM unit expressions.
//!
//! Every measured value in the workspace — latency, throughput, memory, token
//! counts, cost, screen distance — carries a unit. The unit is parsed into a
//! dimension vector so the system can refuse to compare a duration with a
//! length instead of silently producing a wrong dashboard number.
//!
//! The unit syntax is the UCUM case-sensitive form: `ms`, `m/s`, `kg.m/s2`,
//! `mm[Hg]`, `{token}/s`. Annotations in braces are carried but do not affect
//! the dimension.

const std = @import("std");

pub const Error = error{
    UnknownUnit,
    MalformedUnit,
    IncommensurableUnits,
    UnitTooLong,
};

/// Exponents over the seven SI base quantities, in the ISO 80000 order.
pub const Dimension = struct {
    length: i8 = 0,
    mass: i8 = 0,
    time: i8 = 0,
    current: i8 = 0,
    temperature: i8 = 0,
    amount: i8 = 0,
    luminous: i8 = 0,

    pub const dimensionless: Dimension = .{};

    pub fn eql(a: Dimension, b: Dimension) bool {
        return std.meta.eql(a, b);
    }

    pub fn mul(a: Dimension, b: Dimension) Dimension {
        return .{
            .length = a.length + b.length,
            .mass = a.mass + b.mass,
            .time = a.time + b.time,
            .current = a.current + b.current,
            .temperature = a.temperature + b.temperature,
            .amount = a.amount + b.amount,
            .luminous = a.luminous + b.luminous,
        };
    }

    pub fn pow(a: Dimension, e: i8) Dimension {
        return .{
            .length = a.length * e,
            .mass = a.mass * e,
            .time = a.time * e,
            .current = a.current * e,
            .temperature = a.temperature * e,
            .amount = a.amount * e,
            .luminous = a.luminous * e,
        };
    }

    pub fn isDimensionless(self: Dimension) bool {
        return self.eql(dimensionless);
    }
};

const AtomDef = struct {
    code: []const u8,
    /// Factor to the coherent SI unit of the same dimension.
    factor: f64,
    dim: Dimension,
    /// Metric atoms may take SI prefixes; non-metric ones (`h`, `[in_i]`) may not.
    metric: bool = true,
};

const length: Dimension = .{ .length = 1 };
const mass: Dimension = .{ .mass = 1 };
const duration: Dimension = .{ .time = 1 };
const current: Dimension = .{ .current = 1 };
const temperature: Dimension = .{ .temperature = 1 };
const amount: Dimension = .{ .amount = 1 };
const luminous: Dimension = .{ .luminous = 1 };

/// The atoms the workbench actually needs, in UCUM case-sensitive codes.
const atoms = [_]AtomDef{
    // SI base units
    .{ .code = "m", .factor = 1, .dim = length },
    .{ .code = "g", .factor = 0.001, .dim = mass }, // UCUM's metric mass atom is the gram
    .{ .code = "s", .factor = 1, .dim = duration },
    .{ .code = "A", .factor = 1, .dim = current },
    .{ .code = "K", .factor = 1, .dim = temperature },
    .{ .code = "mol", .factor = 1, .dim = amount },
    .{ .code = "cd", .factor = 1, .dim = luminous },
    // Derived SI units used in engineering telemetry
    .{ .code = "Hz", .factor = 1, .dim = .{ .time = -1 } },
    .{ .code = "N", .factor = 1, .dim = .{ .length = 1, .mass = 1, .time = -2 } },
    .{ .code = "Pa", .factor = 1, .dim = .{ .length = -1, .mass = 1, .time = -2 } },
    .{ .code = "J", .factor = 1, .dim = .{ .length = 2, .mass = 1, .time = -2 } },
    .{ .code = "W", .factor = 1, .dim = .{ .length = 2, .mass = 1, .time = -3 } },
    .{ .code = "V", .factor = 1, .dim = .{ .length = 2, .mass = 1, .time = -3, .current = -1 } },
    .{ .code = "C", .factor = 1, .dim = .{ .time = 1, .current = 1 } },
    // Non-metric time units: no prefixes, exact factors
    .{ .code = "min", .factor = 60, .dim = duration, .metric = false },
    .{ .code = "h", .factor = 3600, .dim = duration, .metric = false },
    .{ .code = "d", .factor = 86400, .dim = duration, .metric = false },
    .{ .code = "wk", .factor = 604800, .dim = duration, .metric = false },
    .{ .code = "a", .factor = 31557600, .dim = duration, .metric = false }, // Julian year
    // Dimensionless counting units
    .{ .code = "1", .factor = 1, .dim = Dimension.dimensionless, .metric = false },
    .{ .code = "%", .factor = 0.01, .dim = Dimension.dimensionless, .metric = false },
    .{ .code = "[ppm]", .factor = 1e-6, .dim = Dimension.dimensionless, .metric = false },
    // Information units. UCUM writes the bit as `bit` and the byte as `By`.
    .{ .code = "bit", .factor = 1, .dim = Dimension.dimensionless },
    .{ .code = "By", .factor = 8, .dim = Dimension.dimensionless },
    // Common non-metric lengths, kept for display density calculations
    .{ .code = "[in_i]", .factor = 0.0254, .dim = length, .metric = false },
    .{ .code = "[pt]", .factor = 0.0254 / 72.0, .dim = length, .metric = false },
};

const PrefixDef = struct { code: []const u8, factor: f64 };

/// SI prefixes plus the binary prefixes UCUM defines for information units.
const prefixes = [_]PrefixDef{
    .{ .code = "Y", .factor = 1e24 },
    .{ .code = "Z", .factor = 1e21 },
    .{ .code = "E", .factor = 1e18 },
    .{ .code = "P", .factor = 1e15 },
    .{ .code = "T", .factor = 1e12 },
    .{ .code = "G", .factor = 1e9 },
    .{ .code = "M", .factor = 1e6 },
    .{ .code = "k", .factor = 1e3 },
    .{ .code = "h", .factor = 1e2 },
    .{ .code = "da", .factor = 1e1 },
    .{ .code = "d", .factor = 1e-1 },
    .{ .code = "c", .factor = 1e-2 },
    .{ .code = "m", .factor = 1e-3 },
    .{ .code = "u", .factor = 1e-6 },
    .{ .code = "n", .factor = 1e-9 },
    .{ .code = "p", .factor = 1e-12 },
    .{ .code = "f", .factor = 1e-15 },
    .{ .code = "Ki", .factor = 1024 },
    .{ .code = "Mi", .factor = 1024 * 1024 },
    .{ .code = "Gi", .factor = 1024 * 1024 * 1024 },
    .{ .code = "Ti", .factor = 1024.0 * 1024 * 1024 * 1024 },
};

/// A parsed unit: a scale factor to the coherent SI unit, and a dimension.
pub const Unit = struct {
    factor: f64,
    dim: Dimension,
    /// The text as written, kept so that output can echo the author's unit.
    text: []const u8,

    pub const one: Unit = .{ .factor = 1, .dim = Dimension.dimensionless, .text = "1" };

    pub fn parse(text: []const u8) Error!Unit {
        if (text.len == 0) return error.MalformedUnit;
        if (text.len > 64) return error.UnitTooLong;
        var factor: f64 = 1;
        var dim: Dimension = .{};
        var index: usize = 0;
        var dividing = false;
        // A leading `/` means the whole term is inverted, as in `/s`.
        if (text[0] == '/') {
            dividing = true;
            index = 1;
        }
        while (index < text.len) {
            const start = index;
            while (index < text.len and text[index] != '.' and text[index] != '/') : (index += 1) {
                if (text[index] == '[') {
                    while (index < text.len and text[index] != ']') : (index += 1) {}
                } else if (text[index] == '{') {
                    while (index < text.len and text[index] != '}') : (index += 1) {}
                }
            }
            const component = text[start..index];
            const parsed = try parseComponent(component);
            if (dividing) {
                factor /= parsed.factor;
                dim = dim.mul(parsed.dim.pow(-1));
            } else {
                factor *= parsed.factor;
                dim = dim.mul(parsed.dim);
            }
            if (index < text.len) {
                dividing = text[index] == '/';
                index += 1;
                if (index == text.len) return error.MalformedUnit;
            }
        }
        return .{ .factor = factor, .dim = dim, .text = text };
    }

    const Component = struct { factor: f64, dim: Dimension };

    fn parseComponent(text_in: []const u8) Error!Component {
        var text = text_in;
        // Strip a trailing annotation such as `{token}`.
        if (std.mem.indexOfScalar(u8, text, '{')) |brace| {
            const close = std.mem.indexOfScalar(u8, text, '}') orelse return error.MalformedUnit;
            if (close < brace) return error.MalformedUnit;
            if (brace == 0) return .{ .factor = 1, .dim = Dimension.dimensionless }; // pure annotation
            text = text[0..brace];
        }
        if (text.len == 0) return error.MalformedUnit;

        // Trailing signed exponent.
        var exponent: i8 = 1;
        var end = text.len;
        var digits_start = text.len;
        while (digits_start > 0 and std.ascii.isDigit(text[digits_start - 1])) digits_start -= 1;
        if (digits_start < text.len and digits_start > 0) {
            var sign: i8 = 1;
            var num_start = digits_start;
            if (text[digits_start - 1] == '-' or text[digits_start - 1] == '+') {
                if (text[digits_start - 1] == '-') sign = -1;
                num_start = digits_start - 1;
            }
            // `[in_i]` and similar bracketed atoms end in `]`, never in a digit.
            if (text[num_start - 1] != ']') {
                const magnitude = std.fmt.parseInt(i8, text[digits_start..], 10) catch return error.MalformedUnit;
                exponent = sign * magnitude;
                end = num_start;
            }
        }
        const atom_text = text[0..end];
        if (atom_text.len == 0) return error.MalformedUnit;

        // A bare integer is a numeric factor, as in `10*3` style shorthand `2`.
        if (std.fmt.parseFloat(f64, atom_text)) |number| {
            return .{ .factor = std.math.pow(f64, number, @floatFromInt(exponent)), .dim = Dimension.dimensionless };
        } else |_| {}

        const resolved = try resolveAtom(atom_text);
        return .{
            .factor = std.math.pow(f64, resolved.factor, @floatFromInt(exponent)),
            .dim = resolved.dim.pow(exponent),
        };
    }

    fn resolveAtom(text: []const u8) Error!Component {
        // Exact atom match wins over any prefix interpretation.
        for (atoms) |a| {
            if (std.mem.eql(u8, a.code, text)) return .{ .factor = a.factor, .dim = a.dim };
        }
        // Longest prefix first so that `da` beats `d`, and `Mi` beats `M`.
        var best: ?Component = null;
        var best_prefix_len: usize = 0;
        for (prefixes) |p| {
            if (text.len <= p.code.len) continue;
            if (!std.mem.startsWith(u8, text, p.code)) continue;
            const rest = text[p.code.len..];
            for (atoms) |a| {
                if (!a.metric) continue;
                if (!std.mem.eql(u8, a.code, rest)) continue;
                if (p.code.len > best_prefix_len) {
                    best = .{ .factor = p.factor * a.factor, .dim = a.dim };
                    best_prefix_len = p.code.len;
                }
            }
        }
        return best orelse error.UnknownUnit;
    }

    pub fn commensurableWith(a: Unit, b: Unit) bool {
        return a.dim.eql(b.dim);
    }
};

/// A value with a unit. Arithmetic that crosses dimensions is a compile-time
/// impossible thing to express and a run-time error to attempt.
pub const Quantity = struct {
    value: f64,
    unit: Unit,

    pub fn parse(value: f64, unit_text: []const u8) Error!Quantity {
        return .{ .value = value, .unit = try Unit.parse(unit_text) };
    }

    /// Value expressed in the coherent SI unit of the same dimension.
    pub fn siValue(self: Quantity) f64 {
        return self.value * self.unit.factor;
    }

    pub fn convertTo(self: Quantity, unit_text: []const u8) Error!Quantity {
        const target = try Unit.parse(unit_text);
        if (!self.unit.commensurableWith(target)) return error.IncommensurableUnits;
        return .{ .value = self.siValue() / target.factor, .unit = target };
    }

    pub fn add(a: Quantity, b: Quantity) Error!Quantity {
        if (!a.unit.commensurableWith(b.unit)) return error.IncommensurableUnits;
        return .{ .value = a.value + b.siValue() / a.unit.factor, .unit = a.unit };
    }

    pub fn format(self: Quantity, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d} {s}", .{ self.value, self.unit.text });
    }
};

/// Unit codes whose meaning depends on context and so must never be written
/// without a declared unit system. `m` is the classic case: metre in SI,
/// "minutes" in casual engineering prose.
pub const ambiguous_in_prose = [_][]const u8{ "m", "M", "B", "K", "min", "s", "h", "d" };

pub fn isAmbiguousInProse(code: []const u8) bool {
    for (ambiguous_in_prose) |c| {
        if (std.mem.eql(u8, c, code)) return true;
    }
    return false;
}

test "parses si units and prefixes" {
    const ms = try Unit.parse("ms");
    try std.testing.expectEqual(@as(f64, 1e-3), ms.factor);
    try std.testing.expect(ms.dim.eql(.{ .time = 1 }));

    const km = try Unit.parse("km");
    try std.testing.expectEqual(@as(f64, 1000), km.factor);

    const kg = try Unit.parse("kg");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), kg.factor, 1e-12);
    try std.testing.expect(kg.dim.eql(.{ .mass = 1 }));
}

test "parses compound expressions" {
    const speed = try Unit.parse("m/s");
    try std.testing.expect(speed.dim.eql(.{ .length = 1, .time = -1 }));

    const force = try Unit.parse("kg.m/s2");
    try std.testing.expect(force.dim.eql(.{ .length = 1, .mass = 1, .time = -2 }));
    try std.testing.expect(force.dim.eql((try Unit.parse("N")).dim));

    const rate = try Unit.parse("/s");
    try std.testing.expect(rate.dim.eql(.{ .time = -1 }));

    const throughput = try Unit.parse("MiBy/s");
    try std.testing.expect(throughput.dim.eql(.{ .time = -1 }));
    try std.testing.expectApproxEqRel(@as(f64, 1024 * 1024 * 8), throughput.factor, 1e-12);
}

test "annotations do not change the dimension" {
    const tokens = try Unit.parse("{token}/s");
    try std.testing.expect(tokens.dim.eql(.{ .time = -1 }));
    const frames = try Unit.parse("{frame}");
    try std.testing.expect(frames.dim.isDimensionless());
}

test "conversion respects commensurability" {
    const latency = try Quantity.parse(1500, "us");
    const in_ms = try latency.convertTo("ms");
    try std.testing.expectApproxEqRel(@as(f64, 1.5), in_ms.value, 1e-12);

    const distance = try Quantity.parse(1, "m");
    try std.testing.expectError(error.IncommensurableUnits, distance.convertTo("s"));
    try std.testing.expectError(error.IncommensurableUnits, latency.add(distance));

    const sum = try latency.add(try Quantity.parse(1, "ms"));
    try std.testing.expectApproxEqRel(@as(f64, 2500), sum.value, 1e-12);
}

test "non metric units reject prefixes" {
    try std.testing.expectError(error.UnknownUnit, Unit.parse("kmin"));
    const hour = try Unit.parse("h");
    try std.testing.expectEqual(@as(f64, 3600), hour.factor);
}

test "unknown units are rejected rather than guessed" {
    try std.testing.expectError(error.UnknownUnit, Unit.parse("furlong"));
    try std.testing.expect(isAmbiguousInProse("m"));
    try std.testing.expect(!isAmbiguousInProse("ms"));
}
