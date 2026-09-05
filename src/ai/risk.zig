//! AI risk management (ISO/IEC 23894, with the NIST AI RMF as a crosswalk).
//!
//! A risk register is only useful if it is attached to the system that creates
//! the risk. Here it is: risks name the capabilities and the events they arise
//! from, treatments name the controls that exist in this codebase, and the
//! register can report which risks have no treatment at all.
//!
//! The NIST AI Risk Management Framework is voluntary guidance rather than a
//! standard, so it is used as a *map* over the same register, not as a second
//! set of records to keep in step.

const std = @import("std");
const capability_mod = @import("capability.zig");
const idmod = @import("../core/id.zig");
const timeutil = @import("../core/time.zig");

pub const Capability = capability_mod.Capability;
pub const Timestamp = timeutil.Timestamp;

/// Where a risk comes from. Keeping the source explicit stops a register from
/// filling up with restatements of the same underlying problem.
pub const Source = enum {
    /// The model produces something wrong or made up.
    model_output,
    /// The model is steered by content it reads.
    prompt_injection,
    /// Data leaves the machine.
    data_egress,
    /// An action cannot be undone.
    irreversible_action,
    /// The system does something the person did not intend to authorise.
    scope_creep,
    /// A person cannot tell what the system did.
    opacity,
    /// The system is unavailable or too slow to use.
    availability,
    /// The system behaves differently for different people.
    unfair_outcome,
    /// A dependency or a supply chain problem.
    supply_chain,
    /// Personal data is handled in a way people did not expect.
    privacy,
};

pub const Likelihood = enum {
    rare,
    unlikely,
    possible,
    likely,
    almost_certain,

    pub fn weight(self: Likelihood) u8 {
        return @intFromEnum(self) + 1;
    }
};

pub const Impact = enum {
    negligible,
    minor,
    moderate,
    major,
    severe,

    pub fn weight(self: Impact) u8 {
        return @intFromEnum(self) + 1;
    }
};

pub const Level = enum {
    low,
    medium,
    high,
    very_high,

    pub fn text(self: Level) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
            .very_high => "very high",
        };
    }
};

pub fn levelOf(likelihood: Likelihood, impact: Impact) Level {
    const score = @as(u16, likelihood.weight()) * @as(u16, impact.weight());
    if (score >= 16) return .very_high;
    if (score >= 9) return .high;
    if (score >= 4) return .medium;
    return .low;
}

/// How the organisation is dealing with a risk.
pub const TreatmentKind = enum {
    /// A control reduces the likelihood or the impact.
    mitigate,
    /// The activity that creates the risk is not done.
    avoid,
    /// Someone else carries it, by contract.
    transfer,
    /// The risk is understood and carried, on purpose, by a named owner.
    accept,
    /// Nothing has been decided yet. This is a finding, not a treatment.
    untreated,
};

pub const Control = struct {
    id: []const u8,
    /// What the control does, in plain language.
    description: []const u8,
    /// Where it lives in this repository, so a reviewer can read it.
    implemented_in: []const u8,
    /// True when the control is enforced by code rather than by instruction.
    enforced_by_code: bool,
};

pub const Treatment = struct {
    kind: TreatmentKind,
    controls: []const Control = &.{},
    /// Who owns the decision.
    owner: []const u8 = "unassigned",
    /// Why this treatment is enough, when it is `accept`.
    justification: []const u8 = "",
};

/// The five NIST AI RMF functions, used only as a view over the register.
pub const NistFunction = enum {
    govern,
    map,
    measure,
    manage,

    pub fn text(self: NistFunction) []const u8 {
        return @tagName(self);
    }
};

pub const Risk = struct {
    id: []const u8,
    /// One sentence naming what could happen and to whom.
    statement: []const u8,
    source: Source,
    /// Capabilities that make this risk possible. Empty means it does not
    /// depend on a capability.
    capabilities: []const Capability = &.{},
    likelihood: Likelihood,
    impact: Impact,
    treatment: Treatment,
    /// Residual likelihood and impact once the controls are in place.
    residual_likelihood: ?Likelihood = null,
    residual_impact: ?Impact = null,
    /// NIST AI RMF functions this risk work sits under.
    nist_functions: []const NistFunction = &.{},
    reviewed_at: ?Timestamp = null,

    pub fn inherentLevel(self: Risk) Level {
        return levelOf(self.likelihood, self.impact);
    }

    pub fn residualLevel(self: Risk) Level {
        return levelOf(
            self.residual_likelihood orelse self.likelihood,
            self.residual_impact orelse self.impact,
        );
    }

    /// A risk whose treatment claims to reduce it, but whose controls are only
    /// instructions to a model, is not treated. This check is the reason the
    /// `enforced_by_code` field exists.
    pub fn hasEnforcedControl(self: Risk) bool {
        for (self.treatment.controls) |control| {
            if (control.enforced_by_code) return true;
        }
        return false;
    }

    pub fn writeSummary(self: Risk, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}  {s} -> {s}\n", .{ self.id, self.inherentLevel().text(), self.residualLevel().text() });
        try w.print("    {s}\n", .{self.statement});
        try w.print("    Treatment: {s}", .{@tagName(self.treatment.kind)});
        if (self.treatment.controls.len > 0) {
            try w.writeAll(" by ");
            for (self.treatment.controls, 0..) |control, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(control.id);
            }
        }
        try w.writeAll("\n");
    }
};

pub const Finding = struct {
    risk_id: []const u8,
    message: []const u8,
};

pub const Register = struct {
    arena: std.mem.Allocator,
    risks: std.ArrayList(Risk) = .empty,

    pub fn init(arena: std.mem.Allocator) Register {
        return .{ .arena = arena };
    }

    pub fn add(self: *Register, risk: Risk) !void {
        try self.risks.append(self.arena, risk);
    }

    pub fn get(self: Register, id: []const u8) ?Risk {
        for (self.risks.items) |risk| {
            if (std.mem.eql(u8, risk.id, id)) return risk;
        }
        return null;
    }

    /// Risks a capability makes possible. Used when a policy is widened: the
    /// person turning on `network.connect` sees what that opens up.
    pub fn forCapability(self: Register, capability: Capability) !std.ArrayList(Risk) {
        var out: std.ArrayList(Risk) = .empty;
        for (self.risks.items) |risk| {
            for (risk.capabilities) |c| {
                if (c == capability) {
                    try out.append(self.arena, risk);
                    break;
                }
            }
        }
        return out;
    }

    pub fn atOrAbove(self: Register, level: Level) !std.ArrayList(Risk) {
        var out: std.ArrayList(Risk) = .empty;
        for (self.risks.items) |risk| {
            if (@intFromEnum(risk.residualLevel()) >= @intFromEnum(level)) try out.append(self.arena, risk);
        }
        return out;
    }

    /// Problems with the register itself.
    pub fn review(self: Register) !std.ArrayList(Finding) {
        var findings: std.ArrayList(Finding) = .empty;
        for (self.risks.items) |risk| {
            if (risk.treatment.kind == .untreated) {
                try findings.append(self.arena, .{
                    .risk_id = risk.id,
                    .message = try std.fmt.allocPrint(self.arena, "{s} has no treatment. Decide who owns it and what is done about it.", .{risk.id}),
                });
            }
            if (risk.treatment.kind == .accept and risk.treatment.justification.len == 0) {
                try findings.append(self.arena, .{
                    .risk_id = risk.id,
                    .message = try std.fmt.allocPrint(self.arena, "{s} is accepted without saying why. Write the reason so the next reviewer can judge it.", .{risk.id}),
                });
            }
            if (risk.treatment.kind == .mitigate and !risk.hasEnforcedControl()) {
                try findings.append(self.arena, .{
                    .risk_id = risk.id,
                    .message = try std.fmt.allocPrint(self.arena, "{s} says it is mitigated, but no control is enforced by code. An instruction to a model is not a control.", .{risk.id}),
                });
            }
            if (risk.residualLevel() == .very_high) {
                try findings.append(self.arena, .{
                    .risk_id = risk.id,
                    .message = try std.fmt.allocPrint(self.arena, "{s} is still very high after treatment. It needs a decision at the level that owns the product.", .{risk.id}),
                });
            }
            if (std.mem.eql(u8, risk.treatment.owner, "unassigned")) {
                try findings.append(self.arena, .{
                    .risk_id = risk.id,
                    .message = try std.fmt.allocPrint(self.arena, "{s} has no owner.", .{risk.id}),
                });
            }
        }
        return findings;
    }

    pub fn writeReport(self: Register, w: *std.Io.Writer) !void {
        try w.writeAll("Risk register\n\n");
        for (self.risks.items) |risk| try risk.writeSummary(w);
        const findings = try self.review();
        if (findings.items.len == 0) {
            try w.writeAll("\nEvery risk has an owner and a treatment.\n");
            return;
        }
        try w.writeAll("\nOpen items:\n");
        for (findings.items) |finding| try w.print("  - {s}\n", .{finding.message});
    }
};

// ---------------------------------------------------------------------------
// The workbench's own register
// ---------------------------------------------------------------------------

const controls = struct {
    const capability_policy: Control = .{
        .id = "C-POLICY",
        .description = "Every tool request is decided by the local policy engine before it runs.",
        .implemented_in = "src/ai/policy.zig",
        .enforced_by_code = true,
    };
    const typed_tools: Control = .{
        .id = "C-TYPED-TOOLS",
        .description = "There is no free-form shell tool; each request names one capability and one resource.",
        .implemented_in = "src/ai/tools.zig",
        .enforced_by_code = true,
    };
    const human_approval: Control = .{
        .id = "C-APPROVAL",
        .description = "Operations that cannot be undone stop and ask a person, in words that name the operation.",
        .implemented_in = "src/ai/approval.zig",
        .enforced_by_code = true,
    };
    const event_log: Control = .{
        .id = "C-LOG",
        .description = "Every action is written to a hash-chained log, so a later change is detectable.",
        .implemented_in = "src/events/log.zig",
        .enforced_by_code = true,
    };
    const provenance: Control = .{
        .id = "C-PROVENANCE",
        .description = "Generated content carries its producer, model, sources, tools and period.",
        .implemented_in = "src/data/provenance.zig",
        .enforced_by_code = true,
    };
    const path_containment: Control = .{
        .id = "C-PATHS",
        .description = "Paths are normalised before they are matched, so traversal cannot leave the workspace.",
        .implemented_in = "src/ai/policy.zig",
        .enforced_by_code = true,
    };
    const agents_md_separation: Control = .{
        .id = "C-CONTEXT-SPLIT",
        .description = "Repository instruction files set behaviour but can never grant a capability.",
        .implemented_in = "src/agent_context/resolver.zig",
        .enforced_by_code = true,
    };
    const plain_language: Control = .{
        .id = "C-PLAIN",
        .description = "Prompts, errors and reports are checked against the plain-language rules before release.",
        .implemented_in = "src/language/plain.zig",
        .enforced_by_code = true,
    };
};

/// The register the product ships with. It is deliberately short: a register
/// nobody reads is worse than none.
pub fn workbenchRegister(arena: std.mem.Allocator) !Register {
    var register = Register.init(arena);

    try register.add(.{
        .id = "R-INJECTION",
        .statement = "Content the agent reads — a file, a web page, a tool result — tells it to do something the person did not ask for.",
        .source = .prompt_injection,
        .capabilities = &.{ .@"fs.read", .@"mcp.invoke", .@"network.connect" },
        .likelihood = .likely,
        .impact = .major,
        .treatment = .{
            .kind = .mitigate,
            .owner = "workbench maintainers",
            .controls = &.{ controls.capability_policy, controls.typed_tools, controls.agents_md_separation },
        },
        .residual_likelihood = .possible,
        .residual_impact = .minor,
        .nist_functions = &.{ .map, .manage },
    });

    try register.add(.{
        .id = "R-IRREVERSIBLE",
        .statement = "An agent deletes work, or pushes a change, that the person cannot get back.",
        .source = .irreversible_action,
        .capabilities = &.{ .@"fs.delete", .@"git.push" },
        .likelihood = .possible,
        .impact = .severe,
        .treatment = .{
            .kind = .mitigate,
            .owner = "workbench maintainers",
            .controls = &.{ controls.human_approval, controls.capability_policy, controls.event_log },
        },
        .residual_likelihood = .rare,
        .residual_impact = .moderate,
        .nist_functions = &.{ .govern, .manage },
    });

    try register.add(.{
        .id = "R-EGRESS",
        .statement = "Workspace content, including secrets in files, leaves the machine in a model request or a network call.",
        .source = .data_egress,
        .capabilities = &.{ .@"model.infer", .@"network.connect", .@"remote.execute" },
        .likelihood = .possible,
        .impact = .severe,
        .treatment = .{
            .kind = .mitigate,
            .owner = "workbench maintainers",
            .controls = &.{ controls.capability_policy, controls.human_approval, controls.event_log },
        },
        .residual_likelihood = .unlikely,
        .residual_impact = .major,
        .nist_functions = &.{ .map, .measure, .manage },
    });

    try register.add(.{
        .id = "R-WRONG-OUTPUT",
        .statement = "The agent writes a change that looks right, passes review, and is wrong.",
        .source = .model_output,
        .capabilities = &.{.@"fs.write"},
        .likelihood = .likely,
        .impact = .moderate,
        .treatment = .{
            .kind = .mitigate,
            .owner = "workbench maintainers",
            .controls = &.{ controls.provenance, controls.event_log },
        },
        .residual_likelihood = .possible,
        .residual_impact = .moderate,
        .nist_functions = &.{ .measure, .manage },
    });

    try register.add(.{
        .id = "R-OPACITY",
        .statement = "A person cannot tell what the agent did, or why, after the fact.",
        .source = .opacity,
        .likelihood = .unlikely,
        .impact = .major,
        .treatment = .{
            .kind = .mitigate,
            .owner = "workbench maintainers",
            .controls = &.{ controls.event_log, controls.provenance, controls.plain_language },
        },
        .residual_likelihood = .rare,
        .residual_impact = .minor,
        .nist_functions = &.{ .govern, .measure },
    });

    try register.add(.{
        .id = "R-ESCAPE",
        .statement = "An agent reaches files outside the workspace it was given.",
        .source = .scope_creep,
        .capabilities = &.{ .@"fs.read", .@"fs.write", .@"process.execute" },
        .likelihood = .possible,
        .impact = .major,
        .treatment = .{
            .kind = .mitigate,
            .owner = "workbench maintainers",
            .controls = &.{ controls.path_containment, controls.capability_policy },
        },
        .residual_likelihood = .rare,
        .residual_impact = .moderate,
        .nist_functions = &.{ .map, .manage },
    });

    return register;
}

const testing = std.testing;

test "risk level follows likelihood and impact" {
    try testing.expectEqual(Level.low, levelOf(.rare, .minor));
    try testing.expectEqual(Level.medium, levelOf(.possible, .minor));
    try testing.expectEqual(Level.high, levelOf(.likely, .moderate));
    try testing.expectEqual(Level.very_high, levelOf(.almost_certain, .severe));
}

test "the shipped register is complete and treated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const register = try workbenchRegister(arena);
    const findings = try register.review();
    if (findings.items.len > 0) {
        for (findings.items) |f| std.debug.print("{s}\n", .{f.message});
    }
    try testing.expectEqual(@as(usize, 0), findings.items.len);
    try testing.expect(register.risks.items.len >= 6);

    // Every risk that mitigates does so with at least one control in code.
    for (register.risks.items) |risk| {
        if (risk.treatment.kind != .mitigate) continue;
        try testing.expect(risk.hasEnforcedControl());
    }
}

test "an untreated or unenforced risk is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var register = Register.init(arena);
    try register.add(.{
        .id = "R-TEST-1",
        .statement = "Something bad happens.",
        .source = .model_output,
        .likelihood = .possible,
        .impact = .major,
        .treatment = .{ .kind = .untreated },
    });
    try register.add(.{
        .id = "R-TEST-2",
        .statement = "Something else bad happens.",
        .source = .opacity,
        .likelihood = .likely,
        .impact = .major,
        .treatment = .{
            .kind = .mitigate,
            .owner = "someone",
            .controls = &.{.{
                .id = "C-PROMPT",
                .description = "The system prompt asks the model not to do it.",
                .implemented_in = "prompts/system.md",
                .enforced_by_code = false,
            }},
        },
    });

    const findings = (try register.review()).items;
    try testing.expect(findings.len >= 3);
    var saw_instruction_finding = false;
    for (findings) |f| {
        if (std.mem.indexOf(u8, f.message, "instruction to a model is not a control") != null) saw_instruction_finding = true;
    }
    try testing.expect(saw_instruction_finding);
}

test "risks can be found by the capability that enables them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const register = try workbenchRegister(arena);
    const network_risks = try register.forCapability(.@"network.connect");
    try testing.expect(network_risks.items.len >= 2);

    // One risk stays high after treatment, and the register says so rather
    // than rounding it down: recording what an agent did does not stop the
    // agent from writing a change that is wrong.
    const high = try register.atOrAbove(.high);
    try testing.expectEqual(@as(usize, 1), high.items.len);
    try testing.expectEqualStrings("R-WRONG-OUTPUT", high.items[0].id);
}

test "the report reads as sentences" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const register = try workbenchRegister(arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try register.writeReport(&aw.writer);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "R-INJECTION") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Every risk has an owner and a treatment.") != null);
}
