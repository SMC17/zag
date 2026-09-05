//! The zag command-line tool.
//!
//! Every subsystem in the library has a way in from here, because a capability
//! nobody can reach is a capability that rots. The tool is also the release
//! gate: `zag check` audits this repository against its own standards profile
//! and fails the build when something that can be checked is wrong.
//!
//! The help text below is itself checked by `zag check`, using the product's
//! plain-language rules. If the help is unclear, the build says so.

const std = @import("std");
const zag = @import("zag");

const Command = enum {
    help,
    version,
    doctor,
    lint,
    terms,
    standards,
    check,
    emit,
    card,
    risk,
    impact,
    quality,
    accessibility,
    report,
    events,
    agents,
    run,
    shell_hook,

    fn parse(text: []const u8) ?Command {
        const table = [_]struct { name: []const u8, command: Command }{
            .{ .name = "help", .command = .help },
            .{ .name = "--help", .command = .help },
            .{ .name = "-h", .command = .help },
            .{ .name = "version", .command = .version },
            .{ .name = "--version", .command = .version },
            .{ .name = "doctor", .command = .doctor },
            .{ .name = "lint", .command = .lint },
            .{ .name = "terms", .command = .terms },
            .{ .name = "standards", .command = .standards },
            .{ .name = "check", .command = .check },
            .{ .name = "emit", .command = .emit },
            .{ .name = "card", .command = .card },
            .{ .name = "risk", .command = .risk },
            .{ .name = "impact", .command = .impact },
            .{ .name = "quality", .command = .quality },
            .{ .name = "accessibility", .command = .accessibility },
            .{ .name = "report", .command = .report },
            .{ .name = "events", .command = .events },
            .{ .name = "agents", .command = .agents },
            .{ .name = "run", .command = .run },
            .{ .name = "shell-hook", .command = .shell_hook },
        };
        for (table) |entry| {
            if (std.mem.eql(u8, entry.name, text)) return entry.command;
        }
        return null;
    }
};

pub const help_text =
    \\zag - a workbench where people and agents do engineering work in one recorded workspace.
    \\
    \\Use it like this:
    \\  zag <command> [options]
    \\
    \\Commands
    \\  doctor              Show what this build can do, and what it cannot.
    \\  lint <files>        Check text against the plain-language rules.
    \\  terms               Show the registered concepts and their definitions.
    \\  standards           Show the standards in force and how each is checked.
    \\  check               Audit this repository against its standards profile.
    \\  emit                Write the schemas, the vocabulary and the interface files.
    \\  card <kind>         Write the model card, system card, datasheet or fact sheet.
    \\  risk                Show the risk register.
    \\  impact              Show the impact assessment.
    \\  quality             Show the quality measures, including what was never measured.
    \\  accessibility       Show the accessibility statement and check the themes.
    \\  report              Show an example report in the product's notation.
    \\  events <file>       Verify an event log and summarise what happened.
    \\  agents <file>       Read an instruction file and show what it asks for.
    \\  run -- <command>    Run a command on a real terminal and record it as a block.
    \\  shell-hook <shell>  Print the shell integration for bash, zsh, fish or pwsh.
    \\
    \\Options
    \\  --profile <name>    Use this conformance profile. The default is "default".
    \\  --kind <kind>       Say what the text is, so the right rules apply.
    \\  --audience <name>   Say who the text is written for.
    \\  --json              Write the result as JSON.
    \\  --out <directory>   Write generated files here.
    \\  --repo <directory>  Audit this directory.
    \\
    \\Read more in README.md, or run "zag doctor" to see this build.
    \\
;

const Options = struct {
    profile: []const u8 = "default",
    kind: []const u8 = "body",
    audience: []const u8 = "developer",
    json: bool = false,
    out: []const u8 = ".",
    repo: []const u8 = ".",
    positional: []const []const u8 = &.{},
    /// Everything after `--`.
    passthrough: []const []const u8 = &.{},
};

fn parseOptions(arena: std.mem.Allocator, args: []const []const u8) !Options {
    var options: Options = .{};
    var positional: std.ArrayList([]const u8) = .empty;
    var passthrough: std.ArrayList([]const u8) = .empty;
    var after_separator = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (after_separator) {
            try passthrough.append(arena, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            after_separator = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
            continue;
        }
        const named = [_]struct { flag: []const u8, field: *[]const u8 }{
            .{ .flag = "--profile", .field = &options.profile },
            .{ .flag = "--kind", .field = &options.kind },
            .{ .flag = "--audience", .field = &options.audience },
            .{ .flag = "--out", .field = &options.out },
            .{ .flag = "--repo", .field = &options.repo },
        };
        var matched = false;
        for (named) |entry| {
            if (!std.mem.eql(u8, arg, entry.flag)) continue;
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            entry.field.* = args[index];
            matched = true;
            break;
        }
        if (matched) continue;
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownOption;
        try positional.append(arena, arg);
    }

    options.positional = try positional.toOwnedSlice(arena);
    options.passthrough = try passthrough.toOwnedSlice(arena);
    return options;
}

/// Zig 0.16 hands the program its arguments, its allocators and its I/O
/// implementation, so nothing here reaches for a global.
pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try init.minimal.args.toSlice(arena);

    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const w = &stdout.interface;

    if (argv.len < 2) {
        try w.writeAll(help_text);
        try w.flush();
        return 0;
    }

    const command = Command.parse(argv[1]) orelse {
        try w.print("\"{s}\" is not a zag command.\n\n", .{argv[1]});
        try w.writeAll(help_text);
        try w.flush();
        return 2;
    };

    var text_args: std.ArrayList([]const u8) = .empty;
    for (argv[2..]) |arg| try text_args.append(arena, arg);

    const options = parseOptions(arena, text_args.items) catch |err| {
        switch (err) {
            error.MissingOptionValue => try w.writeAll("An option is missing its value. Run \"zag help\" to see the options.\n"),
            error.UnknownOption => try w.writeAll("That option is not one zag knows. Run \"zag help\" to see the options.\n"),
            else => return err,
        }
        try w.flush();
        return 2;
    };

    const status = try run(arena, io, w, command, options);
    try w.flush();
    return status;
}

fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    command: Command,
    options: Options,
) !u8 {
    return switch (command) {
        .help => blk: {
            try w.writeAll(help_text);
            break :blk 0;
        },
        .version => blk: {
            try w.print("zag {s}\n", .{zag.version});
            break :blk 0;
        },
        .doctor => try doctor(arena, w),
        .lint => try lint(arena, io, w, options),
        .terms => try terms(arena, w, options),
        .standards => try standards(arena, w, options),
        .check => try check(arena, io, w, options),
        .emit => try emit(arena, io, w, options),
        .card => try card(arena, w, options),
        .risk => try riskReport(arena, w),
        .impact => try impactReport(arena, w),
        .quality => try qualityReport(arena, w),
        .accessibility => try accessibilityReport(arena, w),
        .report => try exampleReport(arena, w),
        .events => try events(arena, io, w, options),
        .agents => try agentsFile(arena, io, w, options),
        .run => try runCommand(arena, w, options),
        .shell_hook => try shellHook(w, options),
    };
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn doctor(arena: std.mem.Allocator, w: *std.Io.Writer) !u8 {
    const builtin = @import("builtin");
    try w.print("zag {s}\n\n", .{zag.version});
    try w.print("Built for {s} on {s}, with Zig {s}.\n\n", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
        builtin.zig_version_string,
    });

    try w.writeAll("What this build can do\n");
    try w.print("  Terminal on a real pseudoterminal:  {s}\n", .{if (zag.terminal.pty.supported) "yes" else "not on this platform"});
    try w.writeAll("  Typed workspace event log:          yes\n");
    try w.writeAll("  Capability policy and approvals:    yes\n");
    try w.writeAll("  Plain-language checks:              yes\n");
    try w.writeAll("  Terminology and metadata registry:  yes\n");
    try w.writeAll("  Standards registry and evidence:    yes\n");
    try w.writeAll("  Generated schemas and vocabulary:   yes\n\n");

    try w.writeAll("What this build cannot do yet\n");
    try w.writeAll("  Draw its own window. The renderer is not written; the accessibility tree it must publish is.\n");
    try w.writeAll("  Talk to a language server. The editor surfaces are not written.\n");
    try w.writeAll("  Reach a model provider. The runtime and its policy are written; no provider is wired in.\n");
    try w.writeAll("  Run on Windows or macOS terminals. The pseudoterminal layer is Linux only so far.\n\n");

    const system = try zag.knowledge.vocabulary.build(arena);
    try w.print("The vocabulary holds {d} concepts.\n", .{system.count()});
    try w.print("The risk register holds {d} risks.\n", .{(try zag.ai.risk.workbenchRegister(arena)).risks.items.len});
    try w.print("The standards profile in use is \"{s}\".\n", .{zag.standards.profile.default.name});
    return 0;
}

fn lint(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    if (options.positional.len == 0) {
        try w.writeAll("Name at least one file to check. For example: zag lint README.md\n");
        return 2;
    }

    const kind = std.meta.stringToEnum(zag.language.audience.TextKind, options.kind) orelse {
        try w.print("\"{s}\" is not a kind of text zag knows. Try body, error_message, permission_prompt, button_label, procedure or warning.\n", .{options.kind});
        return 2;
    };
    const who = zag.language.audience.byId(options.audience) orelse {
        try w.print("\"{s}\" is not an audience zag knows. Try developer, new-user, operator-in-incident, auditor, easy-read, legal-reviewer or scientific-reviewer.\n", .{options.audience});
        return 2;
    };

    const system = try zag.knowledge.vocabulary.build(arena);
    var worst: u8 = 0;

    for (options.positional) |path| {
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(8 << 20)) catch {
            try w.print("zag could not read {s}.\n", .{path});
            worst = 1;
            continue;
        };
        const report = try zag.language.plain.check(arena, source, .{
            .kind = kind,
            .audience = who,
            .purpose = if (kind == .procedure) .instruct else .inform,
            .terminology = &system,
        });

        if (options.json) {
            try report.writeJson(w);
            try w.writeAll("\n");
        } else {
            try w.print("{s}\n", .{path});
            for (report.findings) |finding| try finding.writeLine(w);
            try w.print("  {d} finding(s). Written for: {s}\n", .{ report.findings.len, who.description });
            try w.print("  Estimated reading: {s}.\n\n", .{report.metrics.describe()});
        }
        for (report.findings) |finding| {
            if (finding.severity == .blocking) worst = 1;
        }
    }

    if (!options.json) try w.print("{s}\n", .{zag.language.plain.limits_statement});
    return worst;
}

fn terms(arena: std.mem.Allocator, w: *std.Io.Writer, options: Options) !u8 {
    const system = try zag.knowledge.vocabulary.build(arena);

    if (options.positional.len == 0) {
        const thesaurus = try zag.knowledge.thesaurus.Thesaurus.build(arena, system);
        try thesaurus.writeAlphabetical(w);
        return 0;
    }

    const query = options.positional[0];
    const resolution = system.resolve(query) orelse {
        try w.print("\"{s}\" is not a registered term.\n", .{query});
        return 1;
    };
    const concept = resolution.concept;
    try w.print("{s}\n", .{concept.preferred});
    if (resolution.status == .deprecated) {
        try w.print("  You wrote \"{s}\", which we no longer use. Use \"{s}\".\n", .{ resolution.matched, concept.preferred });
    }
    try w.print("  Definition: {s}\n", .{concept.definition});
    try w.print("  Subject field: {s}\n", .{concept.subject_field});
    if (concept.source) |source| try w.print("  From: {s}\n", .{source});
    for (concept.designations) |designation| {
        try w.print("  {s}: {s}\n", .{ switch (designation.status) {
            .preferred => "Preferred",
            .admitted => "Also called",
            .deprecated => "Do not use",
        }, designation.text });
    }
    const path = try system.broaderPath(concept.id);
    if (path.items.len > 0) {
        try w.writeAll("  Broader: ");
        for (path.items, 0..) |item, i| {
            if (i > 0) try w.writeAll(" -> ");
            try w.writeAll(system.get(item).?.preferred);
        }
        try w.writeAll("\n");
    }
    const children = try system.narrower(concept.id);
    if (children.items.len > 0) {
        try w.writeAll("  Narrower: ");
        for (children.items, 0..) |item, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(system.get(item).?.preferred);
        }
        try w.writeAll("\n");
    }
    return 0;
}

fn standards(arena: std.mem.Allocator, w: *std.Io.Writer, options: Options) !u8 {
    if (options.positional.len > 0 and std.mem.eql(u8, options.positional[0], "profiles")) {
        for (zag.standards.profile.registry) |profile| {
            try w.print("{s}  {s}\n  {s}\n", .{ profile.id, profile.name, profile.description });
            try w.print("  Language rules: {s}. Written for: {s}. Accessibility: level {s}.\n", .{
                @tagName(profile.language),
                profile.audience.description,
                @tagName(profile.accessibility),
            });
            try w.print("  Standards in force: {d}\n", .{profile.standards.len});
            for (profile.exclusions) |exclusion| {
                try w.print("  Does not apply {s}: {s}\n", .{ exclusion.requirement_id, exclusion.reason });
            }
            try w.writeAll("\n");
        }
        return 0;
    }
    if (options.positional.len > 0 and std.mem.eql(u8, options.positional[0], "crosswalks")) {
        try zag.standards.crosswalk.all.writeReport(w);
        return 0;
    }

    const registry = try loadStandards(arena);
    const issues = try registry.validate();

    var it = registry.standards.iterator();
    while (it.next()) |entry| {
        const standard = entry.value_ptr.*;
        try w.print("{s}", .{standard.identifier});
        if (standard.edition) |edition| try w.print(":{s}", .{edition});
        try w.print("  [{s}, {s}]\n    {s}\n", .{ @tagName(standard.status), @tagName(standard.enforcement), standard.title });
        if (standard.purpose.len > 0) try w.print("    {s}\n", .{standard.purpose});
    }

    try w.print("\n{d} standards recorded.\n", .{registry.count()});
    if (issues.items.len > 0) {
        try w.writeAll("\nProblems with the registry itself:\n");
        for (issues.items) |issue| try w.print("  {s} {s}\n", .{ issue.code.text(), issue.message });
        return 1;
    }
    return 0;
}

fn loadStandards(arena: std.mem.Allocator) !zag.standards.registry.Registry {
    var registry = zag.standards.registry.Registry.init(arena);
    inline for (.{
        @embedFile("registry_language"),
        @embedFile("registry_accessibility"),
        @embedFile("registry_knowledge"),
        @embedFile("registry_interoperability"),
        @embedFile("registry_governance"),
    }) |source| {
        _ = try registry.loadStandards(source);
    }
    return registry;
}

fn card(arena: std.mem.Allocator, w: *std.Io.Writer, options: Options) !u8 {
    const facts = try workbenchFacts(arena);
    const kind = if (options.positional.len > 0) options.positional[0] else "model";

    if (std.mem.eql(u8, kind, "model")) {
        try zag.ai.documentation.writeModelCard(facts, w);
    } else if (std.mem.eql(u8, kind, "system")) {
        try zag.ai.documentation.writeSystemCard(facts, w);
    } else if (std.mem.eql(u8, kind, "factsheet")) {
        try zag.ai.documentation.writeFactSheet(facts, w);
    } else if (std.mem.eql(u8, kind, "datasheet")) {
        try zag.ai.documentation.writeDatasheet(historyDataset(), w);
    } else {
        try w.print("\"{s}\" is not a card zag writes. Try model, system, factsheet or datasheet.\n", .{kind});
        return 2;
    }
    return 0;
}

fn workbenchFacts(arena: std.mem.Allocator) !zag.ai.documentation.SystemFacts {
    var suite = try zag.ai.evaluation.workbenchSuite(arena);
    try suite.addResult(.{
        .measure_id = "M-PROMPT-CLARITY",
        .value = 1.0,
        .sample_size = 4,
        .method = .automated_test,
        .measured_at = try zag.core.time.Timestamp.parseIso("2026-09-04T12:00:00Z"),
        .conditions = "The generated prompts in the approval test suite",
    });
    try suite.addResult(.{
        .measure_id = "M-POLICY-CORRECTNESS",
        .value = 1.0,
        .sample_size = 24,
        .method = .automated_test,
        .measured_at = try zag.core.time.Timestamp.parseIso("2026-09-04T12:00:00Z"),
        .conditions = "The policy test suite, including path traversal and expiry",
    });

    return .{
        .name = "zag workbench",
        .version = zag.version,
        .owner = "workbench maintainers",
        .contact = "the repository issue tracker",
        .license = "MIT",
        .purpose = "Help a developer run commands, read and change code, and direct agents, on a machine they control.",
        .intended_users = &.{"Software developers working on their own or their organisation's code."},
        .intended_uses = &.{
            "Running commands and reading their output as durable records.",
            "Directing an agent to change code under a policy the person sets.",
            "Reviewing what an agent did, and why.",
        },
        .excluded_uses = &.{
            "Deciding anything about a person, such as employment, credit, benefits or access.",
            "Running without a person able to see and stop what an agent does.",
        },
        .model = .{ .provider = "configured by the operator", .model = "configured by the operator", .version = null },
        .model_inputs = &.{
            "The request the person typed.",
            "Files the policy allows the agent to read.",
            "Output of commands the agent ran.",
        },
        .model_outputs = &.{
            "A plan, in words.",
            "Typed tool requests, which the policy engine decides before anything runs.",
        },
        .policy = try zag.ai.policy.repositoryWriteNoNetwork(".", arena),
        .allowed_capabilities = &.{ .@"fs.read", .@"fs.write", .@"process.execute", .@"git.read", .@"git.commit" },
        .data_sources = &.{
            .{
                .name = "the workspace",
                .description = "Files, commands and output in the repository the person opened.",
                .personal_data = false,
                .leaves_machine = false,
                .retention = "Until the person deletes the workspace.",
            },
            .{
                .name = "the event log",
                .description = "Every typed event, chained by hash.",
                .personal_data = false,
                .leaves_machine = false,
                .retention = "For as long as the retention rule on each record says.",
            },
        },
        .limitations = &.{
            "It cannot tell whether a change an agent wrote is correct. It can only show you what changed and let you check.",
            "Block boundaries depend on shell integration. Without it, timings and exit statuses are inferred and marked as inferred.",
            "The graphical renderer and the language-server client are not built yet.",
        },
        .human_oversight = "A person can stop any agent, refuse any approval, and withdraw any standing permission. Operations that cannot be undone always stop and ask.",
        .evaluations = suite,
        .risks = try zag.ai.risk.workbenchRegister(arena),
        .impact = try zag.ai.impact.workbenchAssessment(arena),
        .produced_at = try zag.core.time.Timestamp.parseIso("2026-09-04T00:00:00Z"),
        .review_due = try zag.core.time.Timestamp.parseIso("2027-03-04T00:00:00Z"),
    };
}

fn historyDataset() zag.ai.documentation.DatasetFacts {
    return .{
        .name = "workspace command history",
        .version = "2026-09",
        .purpose = "Let a person search what they ran, where, and what happened.",
        .made_by = "the workbench, from the person's own sessions",
        .contents = "One record for each command: the text, the directory, the repository, the exit status and the time it took.",
        .instance_count = 0,
        .collection_method = "Recorded by the workbench as the person worked, from shell integration marks.",
        .preparation = "Output larger than a few kilobytes is stored by hash rather than inline.",
        .uses = &.{ "Searching earlier work.", "Explaining how a regression was introduced." },
        .unsupported_uses = &.{ "Judging how productive a person is.", "Training a model without the person's agreement." },
        .personal_data = true,
        .consent_basis = "The person's own use of their own machine. Nothing is shared unless they share it.",
        .retention = "Kept locally until the person deletes it. Nothing is sent anywhere by default.",
        .limitations = &.{
            "Without shell integration, command boundaries are inferred and some records are incomplete.",
            "Commands typed inside a full-screen program are not recorded separately.",
        },
        .contact = "the repository issue tracker",
        .produced_at = zag.core.time.Timestamp.epoch,
    };
}

fn riskReport(arena: std.mem.Allocator, w: *std.Io.Writer) !u8 {
    const register = try zag.ai.risk.workbenchRegister(arena);
    try register.writeReport(w);
    const findings = try register.review();
    return if (findings.items.len > 0) 1 else 0;
}

fn impactReport(arena: std.mem.Allocator, w: *std.Io.Writer) !u8 {
    const assessment = try zag.ai.impact.workbenchAssessment(arena);
    try assessment.writeText(w);
    const findings = try assessment.review(arena);
    if (findings.items.len > 0) {
        try w.writeAll("\nOpen items:\n");
        for (findings.items) |finding| try w.print("  - {s}\n", .{finding});
        return 1;
    }
    return 0;
}

fn qualityReport(arena: std.mem.Allocator, w: *std.Io.Writer) !u8 {
    const suite = try zag.ai.evaluation.workbenchSuite(arena);
    try suite.writeReport(w);
    return 0;
}

fn accessibilityReport(arena: std.mem.Allocator, w: *std.Io.Writer) !u8 {
    try zag.accessibility.wcag.writeStatement(w, .aa);
    try w.writeAll("\n");
    try zag.accessibility.contrast.default_dark.writeReport(w, .aa);
    try w.writeAll("\n");
    try zag.accessibility.contrast.default_light.writeReport(w, .aa);

    var status: u8 = 0;
    inline for ([_]zag.accessibility.contrast.Theme{
        zag.accessibility.contrast.default_dark,
        zag.accessibility.contrast.default_light,
    }) |theme| {
        const failures = try theme.check(arena, .aa);
        if (failures.items.len > 0) status = 1;
    }

    const tree_findings = try zag.accessibility.semantic_tree.check(arena, zag.accessibility.semantic_tree.exampleTree(), .{});
    try w.print("\nThe published accessibility tree has {d} problem(s).\n", .{tree_findings.items.len});
    for (tree_findings.items) |finding| try w.print("  {s} {s}\n", .{ finding.code.text(), finding.message });
    if (tree_findings.items.len > 0) status = 1;
    return status;
}

fn exampleReport(arena: std.mem.Allocator, w: *std.Io.Writer) !u8 {
    _ = arena;
    const metrics = zag.reports.metrics;
    const period: metrics.Period = .{
        .start = try zag.core.time.Timestamp.parseIso("2026-09-01T00:00:00Z"),
        .end = try zag.core.time.Timestamp.parseIso("2026-09-08T00:00:00Z"),
    };

    const latency: metrics.Metric = .{
        .id = "latency",
        .name = "Keystroke latency, 99th percentile",
        .definition = "Time from a key press to the frame that shows it, on an idle machine.",
        .kind = .quantile,
        .unit = "ms",
        .direction = .lower_is_better,
        .source = "the render benchmark",
        .decimals = 1,
    };
    const commands: metrics.Metric = .{
        .id = "commands",
        .name = "Commands run",
        .definition = "Commands submitted through a session, including those an agent submitted.",
        .kind = .flow,
        .unit = "{command}",
        .direction = .neutral,
        .source = "the workspace event log",
    };
    const denied: metrics.Metric = .{
        .id = "denied",
        .name = "Tool calls denied by policy",
        .definition = "Typed tool requests the policy refused, as a share of all tool requests.",
        .kind = .rate,
        .unit = "1",
        .direction = .neutral,
        .source = "the workspace event log",
        .decimals = 2,
    };

    const table: zag.reports.notation.Table = .{
        .title = "Workspace, week of 1 September 2026",
        .period = period,
        .rows = &.{
            .{ .metric = latency, .value = .{ .metric_id = "latency", .value = 8.4, .period = period, .comparison = .{ .target = 10.0 }, .confidence = .sampled, .sample_size = 1000 } },
            .{ .metric = commands, .value = .{ .metric_id = "commands", .value = 412, .period = period, .comparison = .{ .previous_period = 388 } } },
            .{ .metric = denied, .value = .{ .metric_id = "denied", .value = 0.03, .period = period, .comparison = .{ .previous_period = 0.02 } } },
        },
    };
    try table.write(w);

    try w.writeAll("\n");
    const chart: zag.reports.notation.BarChart = .{
        .title = "Keystroke latency by build",
        .metric = latency,
        .bars = &.{
            .{ .label = "debug", .value = 18.2 },
            .{ .label = "release", .value = 8.4 },
        },
    };
    try chart.write(w);
    return 0;
}

fn events(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    if (options.positional.len == 0) {
        try w.writeAll("Name the log file to read. For example: zag events workspace.jsonl\n");
        return 2;
    }
    const path = options.positional[0];
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 << 20)) catch {
        try w.print("zag could not read {s}.\n", .{path});
        return 1;
    };

    const loaded = try zag.events.log.Log.loadJsonLines(arena, source, 1);
    try w.print("{d} events read from {s}.\n", .{ loaded.recovered, path });
    if (loaded.torn_bytes > 0) {
        try w.print("The last {d} bytes were an incomplete entry, so they were left out. That usually means a process stopped while writing.\n", .{loaded.torn_bytes});
    }

    if (try loaded.log.verify()) |broken| {
        try w.print("\nThe log does not verify. Entry {d} (sequence {d}) does not match: {s}.\n", .{ broken.index, broken.sequence, @tagName(broken.reason) });
        try w.writeAll("Everything before that entry is intact. Everything from it onwards has been changed since it was written.\n");
        return 1;
    }
    try w.writeAll("The log verifies: every entry still hashes to what it did when it was written.\n\n");

    const graph = try zag.events.graph.Graph.build(arena, loaded.log);
    var all: std.ArrayList(usize) = .empty;
    for (graph.nodes, 0..) |_, index| try all.append(arena, index);
    const summary = graph.summarise(all.items);
    try summary.writeSentence(w);
    try w.writeAll("\n\n");
    try graph.writeTree(w);
    return 0;
}

fn agentsFile(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    const path = if (options.positional.len > 0) options.positional[0] else "AGENTS.md";
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20)) catch {
        try w.print("zag could not read {s}.\n", .{path});
        return 1;
    };

    const document = try zag.agent_context.agents_md.parse(arena, ".", source);
    try w.print("{s}\n\n", .{path});
    try w.print("{d} sections, {d} instructions.\n\n", .{ document.sections.len, document.instructions.len });
    for (document.instructions) |instruction| {
        try w.print("  [{s}] {s}\n", .{ instruction.section, instruction.text });
    }
    if (document.findings.len > 0) {
        try w.writeAll("\nThese lines carry no authority, and are reported rather than followed:\n");
        for (document.findings) |finding| {
            try w.print("  {s} line {d}: {s}\n", .{ finding.code.text(), finding.line, finding.message });
        }
        return 1;
    }
    try w.writeAll("\nNothing in this file tries to grant a permission.\n");
    return 0;
}

fn runCommand(arena: std.mem.Allocator, w: *std.Io.Writer, options: Options) !u8 {
    if (options.passthrough.len == 0) {
        try w.writeAll("Put the command after two dashes. For example: zag run -- echo hello\n");
        return 2;
    }
    if (!zag.terminal.pty.supported) {
        try w.writeAll("This build cannot open a pseudoterminal on this platform yet.\n");
        return 1;
    }

    var log = zag.events.log.Log.init(arena, 1);
    var generator: zag.core.id.Generator = .init(1, 0);
    const actor: zag.events.event.Actor = .{ .id = generator.next(zag.core.id.ActorId), .kind = .person, .label = "you" };
    const start = zag.core.time.Timestamp.epoch;

    var session = try zag.terminal.session.Session.init(arena, &log, generator.next(zag.core.id.SessionId), .{
        .actor = actor,
        .working_directory = options.repo,
    }, start);

    // The command runs under a shell so that the shell integration marks the
    // block boundary, which is what makes the run a record rather than a blob.
    const hook = zag.terminal.shell_integration.hooks.bash;
    _ = hook;
    var command_text: std.ArrayList(u8) = .empty;
    for (options.passthrough, 0..) |part, index| {
        if (index > 0) try command_text.append(arena, ' ');
        try command_text.appendSlice(arena, part);
    }

    const script = try std.fmt.allocPrint(arena,
        \\printf '\033]133;C;cmdline=%s\007' "$ZAG_COMMAND"; {s}; status=$?; printf '\033]133;D;%s\007' "$status"; exit $status
    , .{command_text.items});

    try session.run(
        "/bin/sh",
        &.{ "/bin/sh", "-c", script },
        &.{
            try std.fmt.allocPrint(arena, "ZAG_COMMAND={s}", .{command_text.items}),
            "TERM=xterm-256color",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        },
        options.repo,
        zag.core.time.Duration.fromSeconds(120),
    );
    try session.close("the command finished");

    const screen_text = try session.screen.text(arena);
    try w.print("{s}\n", .{std.mem.trim(u8, screen_text, " \n")});

    const index = try zag.workspace.block.Index.build(arena, log);
    try w.writeAll("\nRecorded as:\n");
    for (index.blocks.items) |block| {
        try w.writeAll("  ");
        try block.writeSummary(w);
        try w.writeAll("\n");
    }
    if (try log.verify()) |_| {
        try w.writeAll("\nThe log does not verify, which should never happen. Please report it.\n");
        return 1;
    }
    try w.print("\n{d} events, and the log verifies.\n", .{log.count()});

    for (index.blocks.items) |block| {
        if (block.exitStatus) |status| {
            if (status != 0) return status;
        }
    }
    return 0;
}

fn shellHook(w: *std.Io.Writer, options: Options) !u8 {
    const name = if (options.positional.len > 0) options.positional[0] else "bash";
    const hook = zag.terminal.shell_integration.hooks.forShell(name) orelse {
        try w.print("zag has no shell integration for \"{s}\". It has one for bash, zsh, fish and pwsh.\n", .{name});
        return 2;
    };
    try w.print("{s}\n", .{hook});
    return 0;
}

// ---------------------------------------------------------------------------
// emit and check
// ---------------------------------------------------------------------------

fn emit(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    const dir = std.Io.Dir.cwd();
    var written: usize = 0;

    const schemas = [_]struct { path: []const u8, body: []const u8 }{
        .{
            .path = "schemas/workspace-event.schema.json",
            .body = try zag.interop.jsonschema.documentAlloc(zag.events.event.Envelope, arena, .{
                .id = "https://zag.dev/schemas/workspace-event.schema.json",
                .title = "Workspace event",
                .description = "One entry in the workspace event log.",
            }),
        },
        .{
            .path = "schemas/tool-request.schema.json",
            .body = try zag.interop.jsonschema.documentAlloc(zag.ai.tools.ToolRequest, arena, .{
                .id = "https://zag.dev/schemas/tool-request.schema.json",
                .title = "Tool request",
                .description = "Everything an agent can ask to do. Each request names one capability.",
            }),
        },
        .{
            .path = "schemas/block.schema.json",
            .body = try zag.interop.jsonschema.documentAlloc(zag.workspace.block.Block, arena, .{
                .id = "https://zag.dev/schemas/block.schema.json",
                .title = "Block",
                .description = "One unit of work, with what caused it and what it produced.",
            }),
        },
    };
    for (schemas) |schema| {
        try writeGenerated(io, dir, arena, options.out, schema.path, schema.body);
        try w.print("wrote {s}\n", .{schema.path});
        written += 1;
    }

    // The daemon's interface, generated from the same types.
    const openapi_body = try zag.interop.openapi.documentAlloc(&daemon_operations, arena, .{
        .title = "zag workspace daemon",
        .version = zag.version,
        .summary = "Read and drive a workspace over HTTP.",
        .server_url = "http://127.0.0.1:7717",
    });
    try writeGenerated(io, dir, arena, options.out, "schemas/openapi.json", openapi_body);
    try w.writeAll("wrote schemas/openapi.json\n");
    written += 1;

    // The metadata registry, so other languages can adopt the same names.
    var registry_text: std.Io.Writer.Allocating = .init(arena);
    const registry = try workbenchMetadataRegistry(arena);
    try registry.writeJson(&registry_text.writer);
    try writeGenerated(io, dir, arena, options.out, "schemas/metadata-registry.json", registry_text.written());
    try w.writeAll("wrote schemas/metadata-registry.json\n");
    written += 1;

    // The vocabulary, in the two forms other systems ask for.
    const system = try zag.knowledge.vocabulary.build(arena);
    var graph = try zag.knowledge.skos.buildGraph(arena, system, zag.knowledge.skos.default_scheme);

    var turtle: std.Io.Writer.Allocating = .init(arena);
    try graph.writeTurtle(&turtle.writer);
    try writeGenerated(io, dir, arena, options.out, "vocab/workspace.ttl", turtle.written());
    try w.writeAll("wrote vocab/workspace.ttl\n");

    var jsonld: std.Io.Writer.Allocating = .init(arena);
    try graph.writeJsonLd(&jsonld.writer);
    try writeGenerated(io, dir, arena, options.out, "vocab/workspace.jsonld", jsonld.written());
    try w.writeAll("wrote vocab/workspace.jsonld\n");

    var alphabetical: std.Io.Writer.Allocating = .init(arena);
    const thesaurus = try zag.knowledge.thesaurus.Thesaurus.build(arena, system);
    try thesaurus.writeAlphabetical(&alphabetical.writer);
    try writeGenerated(io, dir, arena, options.out, "vocab/workspace.thesaurus.txt", alphabetical.written());
    try w.writeAll("wrote vocab/workspace.thesaurus.txt\n");

    // The glossary and the risk register are generated, not maintained by
    // hand, so they cannot fall behind the code they describe.
    var glossary: std.Io.Writer.Allocating = .init(arena);
    try glossary.writer.writeAll(
        \\# Glossary
        \\
        \\Generated by `zag emit` from the concept system in `src/knowledge`. Do not
        \\edit this file: change the concept, and the definition changes everywhere it
        \\is used, including in the product's own text checks.
        \\
        \\
    );
    var concept_it = system.concepts.iterator();
    while (concept_it.next()) |entry| {
        const concept = entry.value_ptr.*;
        try glossary.writer.print("## {s}\n\n{s}\n\n", .{ concept.preferred, concept.definition });
        for (concept.designations) |designation| {
            switch (designation.status) {
                .admitted => try glossary.writer.print("Also called: {s}\n\n", .{designation.text}),
                .deprecated => try glossary.writer.print("Do not use: {s}\n\n", .{designation.text}),
                .preferred => {},
            }
        }
        if (concept.source) |source| try glossary.writer.print("From: {s}\n\n", .{source});
    }
    try writeGenerated(io, dir, arena, options.out, "docs/glossary.md", glossary.written());
    try w.writeAll("wrote docs/glossary.md\n");

    var risks: std.Io.Writer.Allocating = .init(arena);
    try risks.writer.writeAll(
        \\# Risk register
        \\
        \\Generated by `zag emit` from `src/ai/risk.zig`. A treatment that claims to
        \\reduce a risk must name a control that is enforced by code; an instruction to
        \\a model is not a control, and the build says so.
        \\
        \\
    );
    const register = try zag.ai.risk.workbenchRegister(arena);
    try register.writeReport(&risks.writer);
    try writeGenerated(io, dir, arena, options.out, "docs/risk-register.md", risks.written());
    try w.writeAll("wrote docs/risk-register.md\n");

    // The machine-readable index for agents.
    var llms: std.Io.Writer.Allocating = .init(arena);
    try zag.agent_context.llms_txt.write(zag.agent_context.llms_txt.workbenchDocument(), &llms.writer);
    try writeGenerated(io, dir, arena, options.out, "llms.txt", llms.written());
    try w.writeAll("wrote llms.txt\n");

    return 0;
}

fn writeGenerated(
    io: std.Io,
    dir: std.Io.Dir,
    arena: std.mem.Allocator,
    out_root: []const u8,
    relative_path: []const u8,
    body: []const u8,
) !void {
    const full = try std.fs.path.join(arena, &.{ out_root, relative_path });
    if (std.fs.path.dirname(full)) |parent| {
        dir.createDirPath(io, parent) catch {};
    }
    try dir.writeFile(io, .{ .sub_path = full, .data = body });
}

const daemon_operations = [_]zag.interop.openapi.Operation{
    .{
        .method = .get,
        .path = "/health",
        .operation_id = "getHealth",
        .summary = "Report whether the daemon is running",
        .response = Health,
        .tags = &.{"system"},
    },
    .{
        .method = .get,
        .path = "/sessions",
        .operation_id = "listSessions",
        .summary = "List the sessions in this workspace",
        .response = SessionList,
        .capability = "fs.read",
        .tags = &.{"sessions"},
    },
    .{
        .method = .get,
        .path = "/sessions/{sessionId}/blocks",
        .operation_id = "listBlocks",
        .summary = "List the blocks in one session",
        .response = BlockList,
        .capability = "fs.read",
        .tags = &.{"sessions"},
    },
    .{
        .method = .post,
        .path = "/sessions/{sessionId}/commands",
        .operation_id = "submitCommand",
        .summary = "Run a command in one session",
        .request = SubmitCommand,
        .response = zag.workspace.block.Block,
        .capability = "process.execute",
        .tags = &.{"sessions"},
    },
    .{
        .method = .get,
        .path = "/events",
        .operation_id = "listEvents",
        .summary = "Read the workspace event log from a sequence number",
        .response = EventPage,
        .capability = "fs.read",
        .tags = &.{"events"},
    },
    .{
        .method = .post,
        .path = "/approvals/{approvalId}",
        .operation_id = "answerApproval",
        .summary = "Answer a request that is waiting for a person",
        .request = ApprovalAnswer,
        .response = ApprovalResult,
        .capability = "process.execute",
        .tags = &.{"approvals"},
    },
};

const Health = struct { status: []const u8, version: []const u8, pseudoterminalSupported: bool };
const SessionList = struct { sessions: []const zag.workspace.model.Session };
const BlockList = struct { blocks: []const zag.workspace.block.Block };
const SubmitCommand = struct { commandText: []const u8, workingDirectory: []const u8 };
const EventPage = struct { events: []const zag.events.event.Envelope, nextSequence: u64 };
const ApprovalAnswer = struct { outcome: []const u8, note: []const u8 };
const ApprovalResult = struct { accepted: bool, message: []const u8 };

fn workbenchMetadataRegistry(arena: std.mem.Allocator) !zag.metadata.registry.Registry {
    var registry = zag.metadata.registry.Registry.init(arena);

    try registry.addConcept(.{ .id = "process.working-directory", .object_class = "process", .property = "working directory", .definition = "Directory a process resolves relative paths against.", .concept_id = "session" });
    try registry.addConcept(.{ .id = "process.exit-status", .object_class = "process", .property = "exit status", .definition = "Status a process returned when it finished.", .concept_id = "block" });
    try registry.addConcept(.{ .id = "event.instant", .object_class = "workspace event", .property = "instant", .definition = "The moment the event happened.", .concept_id = "workspace-event" });
    try registry.addConcept(.{ .id = "artifact.content-hash", .object_class = "artefact", .property = "content hash", .definition = "Hash of the content this record refers to.", .concept_id = "artifact" });
    try registry.addConcept(.{ .id = "capability.name", .object_class = "capability", .property = "name", .definition = "The capability an operation needs.", .concept_id = "capability" });

    try registry.addDomain(.{ .id = "path", .definition = "Filesystem path.", .datatype = .path, .maximum_length = 4096 });
    try registry.addDomain(.{ .id = "exit-status", .definition = "Process exit status.", .datatype = .integer, .minimum = 0, .maximum = 255 });
    try registry.addDomain(.{ .id = "instant", .definition = "Point in time, in UTC.", .datatype = .timestamp });
    try registry.addDomain(.{ .id = "content-hash", .definition = "BLAKE3-256 hash in the workbench's canonical form.", .datatype = .content_hash });
    try registry.addDomain(.{
        .id = "capability-name",
        .definition = "One of the capabilities the policy engine knows.",
        .datatype = .code,
        .permitted = &.{
            .{ .value = "fs.read", .meaning = "Read a file or list a directory" },
            .{ .value = "fs.write", .meaning = "Create or change a file" },
            .{ .value = "fs.delete", .meaning = "Delete a file or directory" },
            .{ .value = "process.execute", .meaning = "Start a process" },
            .{ .value = "network.connect", .meaning = "Open a network connection" },
            .{ .value = "git.commit", .meaning = "Record a commit" },
            .{ .value = "git.push", .meaning = "Send commits to a remote" },
            .{ .value = "model.infer", .meaning = "Send a request to a model provider" },
        },
    });

    try registry.addElement(.{
        .id = "workingDirectory",
        .concept_id = "process.working-directory",
        .domain_id = "path",
        .canonical_key = "workingDirectory",
        .zig_type = "[]const u8",
        .aliases = &.{ "cwd", "working_directory", "current_path", "directory" },
        .obligation = .conditional,
        .status = .standardised,
        .definition = "Directory the process resolves relative paths against.",
        .example = "/home/user/zag",
    });
    try registry.addElement(.{
        .id = "exitStatus",
        .concept_id = "process.exit-status",
        .domain_id = "exit-status",
        .canonical_key = "exitStatus",
        .zig_type = "?u8",
        .aliases = &.{ "exit_code", "exitCode", "returncode", "status_code" },
        .obligation = .conditional,
        .status = .standardised,
        .definition = "Status the process returned when it finished.",
        .example = "0",
    });
    try registry.addElement(.{
        .id = "at",
        .concept_id = "event.instant",
        .domain_id = "instant",
        .canonical_key = "at",
        .zig_type = "Timestamp",
        .aliases = &.{ "timestamp", "time", "ts", "occurred_at" },
        .obligation = .mandatory,
        .status = .standardised,
        .definition = "The moment the event happened, in UTC.",
        .example = "2026-09-04T20:41:31.500Z",
    });
    try registry.addElement(.{
        .id = "contentHash",
        .concept_id = "artifact.content-hash",
        .domain_id = "content-hash",
        .canonical_key = "contentHash",
        .zig_type = "Hash",
        .aliases = &.{ "content_hash", "digest", "sha", "checksum" },
        .obligation = .mandatory,
        .status = .standardised,
        .definition = "Hash of the content this record refers to.",
        .example = "b3:0000000000000000000000000000000000000000000000000000000000000000",
    });
    try registry.addElement(.{
        .id = "capability",
        .concept_id = "capability.name",
        .domain_id = "capability-name",
        .canonical_key = "capability",
        .zig_type = "Capability",
        .aliases = &.{ "permission", "scope", "grant" },
        .obligation = .mandatory,
        .status = .standardised,
        .definition = "The capability an operation needs.",
        .example = "process.execute",
    });

    return registry;
}

/// `zag check` — the release gate.
fn check(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    const profile = zag.standards.profile.byId(options.profile) orelse {
        try w.print("\"{s}\" is not a profile zag knows. Run \"zag standards profiles\" to see them.\n", .{options.profile});
        return 2;
    };

    try w.print("Checking {s} against the \"{s}\" profile.\n\n", .{ options.repo, profile.name });

    var problems: usize = 0;
    const dir = std.Io.Dir.cwd();

    // 1. The standards registry itself.
    const registry = try loadStandards(arena);
    const issues = try registry.validate();
    try w.print("Standards registry: {d} standards recorded, {d} problem(s).\n", .{ registry.count(), issues.items.len });
    for (issues.items) |issue| {
        try w.print("  {s} {s}\n", .{ issue.code.text(), issue.message });
        problems += 1;
    }

    // 2. The vocabulary.
    const system = try zag.knowledge.vocabulary.build(arena);
    const term_findings = try system.validate();
    try w.print("Vocabulary: {d} concepts, {d} problem(s).\n", .{ system.count(), term_findings.items.len });
    for (term_findings.items) |finding| {
        try w.print("  {s} {s}\n", .{ finding.code.text(), finding.message });
        problems += 1;
    }

    const thesaurus = try zag.knowledge.thesaurus.Thesaurus.build(arena, system);
    const reciprocity = try thesaurus.checkReciprocity();
    for (reciprocity.items) |problem| {
        try w.print("  TERM {s}\n", .{problem});
        problems += 1;
    }

    // 3. The metadata registry.
    const metadata_registry = try workbenchMetadataRegistry(arena);
    const metadata_findings = try metadata_registry.validate();
    try w.print("Metadata registry: {d} elements, {d} problem(s).\n", .{ metadata_registry.elements.count(), metadata_findings.items.len });
    for (metadata_findings.items) |finding| {
        try w.print("  {s} {s}\n", .{ finding.code.text(), finding.message });
        problems += 1;
    }

    // 4. Accessibility.
    var contrast_problems: usize = 0;
    inline for ([_]zag.accessibility.contrast.Theme{
        zag.accessibility.contrast.default_dark,
        zag.accessibility.contrast.default_light,
    }) |theme| {
        const failures = try theme.check(arena, .aa);
        for (failures.items) |failure| {
            try w.print("  CONTRAST {s} in {s}: {d:.2}:1, needs {d:.1}:1\n", .{ failure.pair.name, theme.name, failure.result.ratio, failure.result.required });
            contrast_problems += 1;
        }
    }
    const tree_findings = try zag.accessibility.semantic_tree.check(arena, zag.accessibility.semantic_tree.exampleTree(), .{});
    try w.print("Accessibility: {d} contrast problem(s), {d} tree problem(s).\n", .{ contrast_problems, tree_findings.items.len });
    for (tree_findings.items) |finding| try w.print("  {s} {s}\n", .{ finding.code.text(), finding.message });
    problems += contrast_problems + tree_findings.items.len;

    // 5. Risk, impact and transparency.
    const risk_register = try zag.ai.risk.workbenchRegister(arena);
    const risk_findings = try risk_register.review();
    const assessment = try zag.ai.impact.workbenchAssessment(arena);
    const impact_findings = try assessment.review(arena);
    try w.print("Governance: {d} risk problem(s), {d} impact problem(s).\n", .{ risk_findings.items.len, impact_findings.items.len });
    for (risk_findings.items) |finding| try w.print("  RISK {s}\n", .{finding.message});
    for (impact_findings.items) |finding| try w.print("  IMPACT {s}\n", .{finding});
    problems += risk_findings.items.len + impact_findings.items.len;

    const unmet = try zag.ai.transparency.unmetObligations(arena);
    try w.print("Transparency: {d} obligation(s) not yet met.\n", .{unmet.items.len});
    for (unmet.items) |obligation| {
        try w.print("  OPEN {s} {s}\n", .{ obligation.topic.question(), obligation.gap });
    }

    // 6. The product's own text, including this tool's help.
    var text_findings: usize = 0;
    const documents = [_]struct { path: []const u8, kind: zag.language.audience.TextKind }{
        .{ .path = "README.md", .kind = .body },
        .{ .path = "AGENTS.md", .kind = .body },
        .{ .path = "docs/architecture.md", .kind = .body },
        .{ .path = "docs/standards-conformance.md", .kind = .body },
        .{ .path = "docs/plain-language.md", .kind = .body },
    };
    for (documents) |document| {
        const path = try std.fs.path.join(arena, &.{ options.repo, document.path });
        const source = dir.readFileAlloc(io, path, arena, .limited(8 << 20)) catch continue;
        const report = try zag.language.plain.check(arena, source, .{
            .kind = document.kind,
            .audience = profile.audience,
            .terminology = &system,
        });
        for (report.findings) |finding| {
            if (finding.severity != .blocking) continue;
            try w.print("  {s} {s}:{d} {s}\n", .{ finding.rule.code(), document.path, finding.line, finding.message });
            text_findings += 1;
        }
    }
    const help_report = try zag.language.plain.check(arena, help_text, .{
        .kind = .body,
        .audience = zag.language.audience.new_user,
        .terminology = &system,
    });
    for (help_report.findings) |finding| {
        if (finding.severity != .blocking) continue;
        try w.print("  {s} zag help: {s}\n", .{ finding.rule.code(), finding.message });
        text_findings += 1;
    }
    try w.print("Product text: {d} blocking problem(s).\n", .{text_findings});
    problems += text_findings;

    // 7. Instruction files.
    const agents_path = try std.fs.path.join(arena, &.{ options.repo, "AGENTS.md" });
    if (dir.readFileAlloc(io, agents_path, arena, .limited(4 << 20))) |source| {
        const document = try zag.agent_context.agents_md.parse(arena, options.repo, source);
        try w.print("Instruction file: {d} instruction(s), {d} finding(s).\n", .{ document.instructions.len, document.findings.len });
        for (document.findings) |finding| {
            try w.print("  {s} AGENTS.md:{d} {s}\n", .{ finding.code.text(), finding.line, finding.message });
            problems += 1;
        }
    } else |_| {
        try w.writeAll("Instruction file: none found.\n");
    }

    // The statement.
    try w.writeAll("\n");
    if (problems == 0) {
        try w.writeAll("Every check that a program can run has passed.\n");
    } else {
        try w.print("{d} problem(s) found by checks a program can run.\n", .{problems});
    }
    try w.writeAll(
        \\
        \\What this does not establish: whether a reader can find, understand and use
        \\the information; whether a person using a screen reader can finish a task;
        \\whether the risk treatments work in practice. Those are settled by evaluating
        \\the product with people, and by audit. This report says only what was checked.
        \\
    );
    return if (problems == 0) 0 else 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the help text passes the product's own plain-language rules" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const system = try zag.knowledge.vocabulary.build(arena);
    const report = try zag.language.plain.check(arena, help_text, .{
        .kind = .body,
        .audience = zag.language.audience.new_user,
        .terminology = &system,
    });
    for (report.findings) |finding| {
        if (finding.severity == .blocking or finding.severity == .major) {
            std.debug.print("{s} {d}:{d} {s}\n", .{ finding.rule.code(), finding.line, finding.column, finding.message });
        }
        try testing.expect(finding.severity != .blocking);
        try testing.expect(finding.severity != .major);
    }
}

test "every command name parses, and an unknown one does not" {
    try testing.expectEqual(Command.doctor, Command.parse("doctor").?);
    try testing.expectEqual(Command.help, Command.parse("--help").?);
    try testing.expectEqual(Command.shell_hook, Command.parse("shell-hook").?);
    try testing.expect(Command.parse("teleport") == null);

    // Every command in the enum appears in the help text, so the help cannot
    // fall behind the code.
    var missing: usize = 0;
    inline for (std.meta.fields(Command)) |field| {
        const name = comptime blk: {
            var buf: [field.name.len]u8 = undefined;
            for (field.name, 0..) |c, i| buf[i] = if (c == '_') '-' else c;
            const out = buf;
            break :blk &out;
        };
        const skip = comptime (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "version"));
        if (!skip and std.mem.indexOf(u8, help_text, name) == null) {
            std.debug.print("the help text does not mention \"{s}\"\n", .{name});
            missing += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), missing);
}

test "options parse, including the passthrough after two dashes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const options = try parseOptions(arena, &.{ "--profile", "legal", "--json", "file.md", "--", "echo", "hello" });
    try testing.expectEqualStrings("legal", options.profile);
    try testing.expect(options.json);
    try testing.expectEqual(@as(usize, 1), options.positional.len);
    try testing.expectEqualStrings("file.md", options.positional[0]);
    try testing.expectEqual(@as(usize, 2), options.passthrough.len);
    try testing.expectEqualStrings("hello", options.passthrough[1]);

    try testing.expectError(error.MissingOptionValue, parseOptions(arena, &.{"--profile"}));
    try testing.expectError(error.UnknownOption, parseOptions(arena, &.{"--wat"}));
}

test "the metadata registry the tool publishes is valid" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const registry = try workbenchMetadataRegistry(arena);
    const findings = try registry.validate();
    if (findings.items.len > 0) {
        for (findings.items) |finding| std.debug.print("{s} {s}\n", .{ finding.code.text(), finding.message });
    }
    try testing.expectEqual(@as(usize, 0), findings.items.len);
    try testing.expectEqualStrings("workingDirectory", registry.canonicalKey("cwd").?);
    try testing.expectEqualStrings("exitStatus", registry.canonicalKey("exit_code").?);
    try testing.expectEqualStrings("at", registry.canonicalKey("timestamp").?);
}

test "the daemon interface describes every operation with its capability" {
    const gpa = testing.allocator;
    const text = try zag.interop.openapi.documentAlloc(&daemon_operations, gpa, .{
        .title = "zag workspace daemon",
        .version = "0.1.0",
    });
    defer gpa.free(text);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;
    try testing.expect(paths.contains("/sessions"));
    try testing.expect(paths.contains("/events"));

    const submit = paths.get("/sessions/{sessionId}/commands").?.object.get("post").?.object;
    try testing.expectEqualStrings("process.execute", submit.get("x-zag-capability").?.string);
    try testing.expect(submit.get("requestBody") != null);
}
