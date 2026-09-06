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
    objects,
    recover,
    agents,
    run,
    shell_hook,
    workflow,
    lifecycle,
    evidence,
    history,
    knowledge,
    term,

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
            .{ .name = "objects", .command = .objects },
            .{ .name = "recover", .command = .recover },
            .{ .name = "agents", .command = .agents },
            .{ .name = "run", .command = .run },
            .{ .name = "shell-hook", .command = .shell_hook },
            .{ .name = "workflow", .command = .workflow },
            .{ .name = "lifecycle", .command = .lifecycle },
            .{ .name = "evidence", .command = .evidence },
            .{ .name = "history", .command = .history },
            .{ .name = "knowledge", .command = .knowledge },
            .{ .name = "term", .command = .term },
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
    \\  objects             Audit every command-output object without changing it.
    \\  recover             Plan recovery of a damaged event log without changing it.
    \\  agents <file>       Read an instruction file and show what it asks for.
    \\  run -- <command>    Run a command on a real terminal and record it as a block.
    \\  shell-hook <shell>  Print the shell integration for bash, zsh, fish or pwsh.
    \\  workflow            Show this repository's own workflow as a task graph.
    \\  lifecycle           Show the lifecycle record, and what has not started.
    \\  evidence            Write the conformance statement from recorded evidence.
    \\  history <query>     Search recorded work. For example: status:failed zig
    \\  knowledge           Show the knowledge under .workspace/, and what is overdue.
    \\  term                Open a shell in a terminal that records what you do.
    \\
    \\Options
    \\  --profile <name>    Use this conformance profile. The default is "default".
    \\  --kind <kind>       Say what the text is, so the right rules apply.
    \\  --audience <name>   Say who the text is written for.
    \\  --json              Write the result as JSON.
    \\  --out <directory>   Write generated files here.
    \\  --repo <directory>  Audit this directory.
    \\  --root <directory>  Read the workspace in this directory.
    \\  --raw               Start the shell with no added prompt marks.
    \\  --approve-truncate  Apply the recovery plan after preserving the original log.
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
    root: []const u8 = ".",
    /// Run the shell exactly as it is, with no generated init file.
    raw: bool = false,
    approve_truncate: bool = false,
    positional: []const []const u8 = &.{},
    /// Everything after `--`.
    passthrough: []const []const u8 = &.{},
};

fn approvalOptionIsValid(command: Command, options: Options) bool {
    return !options.approve_truncate or command == .recover;
}

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
        if (std.mem.eql(u8, arg, "--raw")) {
            options.raw = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--approve-truncate")) {
            options.approve_truncate = true;
            continue;
        }
        const named = [_]struct { flag: []const u8, field: *[]const u8 }{
            .{ .flag = "--profile", .field = &options.profile },
            .{ .flag = "--kind", .field = &options.kind },
            .{ .flag = "--audience", .field = &options.audience },
            .{ .flag = "--out", .field = &options.out },
            .{ .flag = "--repo", .field = &options.repo },
            .{ .flag = "--root", .field = &options.root },
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
    if (!approvalOptionIsValid(command, options)) {
        try w.writeAll("--approve-truncate applies only to \"zag recover\". Nothing was changed.\n");
        try w.flush();
        return 2;
    }

    var environment: std.ArrayList([]const u8) = .empty;
    {
        // The shell the person opens should behave the way it does everywhere
        // else, so it is handed their environment rather than a made-up one.
        const map = init.environ_map;
        for (map.keys(), map.values()) |key, value| {
            try environment.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ key, value }));
        }
    }

    const status = try run(arena, io, w, command, options, environment.items);
    try w.flush();
    return status;
}

fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    command: Command,
    options: Options,
    environment: []const []const u8,
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
        .objects => try contentObjects(arena, io, w, options),
        .recover => try recoverWorkspace(arena, io, w, options),
        .agents => try agentsFile(arena, io, w, options),
        .run => try runCommand(arena, io, w, options),
        .shell_hook => try shellHook(w, options),
        .workflow => try workflowReport(arena, w, options),
        .lifecycle => try lifecycleReport(arena, w),
        .evidence => try evidenceReport(arena, io, w, options),
        .history => try historySearch(arena, io, w, options),
        .knowledge => try knowledgeIndex(arena, io, w, options),
        .term => try interactiveTerminal(arena, io, w, options, environment),
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
    try w.print("  Record an interactive shell:        {s}\n", .{if (zag.terminal.pty.supported and zag.terminal.tty.supported) "yes, with zag term" else "not on this platform"});
    try w.writeAll("  Typed workspace event log:          yes\n");
    try w.writeAll("  Verified command-output store:      yes\n");
    try w.writeAll("  Read-only object audit:             yes\n");
    try w.writeAll("  Evidence-preserving log recovery:   yes\n");
    try w.writeAll("  Capability policy and approvals:    yes\n");
    try w.writeAll("  Plain-language checks:              yes\n");
    try w.writeAll("  Terminology and metadata registry:  yes\n");
    try w.writeAll("  Standards registry and evidence:    yes\n");
    try w.writeAll("  Generated schemas and vocabulary:   yes\n\n");

    try w.writeAll("What this build cannot do yet\n");
    try w.writeAll("  Draw its own window. The renderer is not written; the accessibility tree it must publish is.\n");
    try w.writeAll("  Talk to a language server. The editor surfaces are not written.\n");
    try w.writeAll("  Reach a model provider. The runtime and its policy are written; no provider is wired in.\n");
    try w.writeAll("  Run on Windows or macOS terminals. The pseudoterminal layer is Linux only so far.\n");
    try w.writeAll("  Split the screen. There are no tabs, panes or splits yet.\n");
    try w.writeAll("  Be configured. There is no settings file and no key bindings yet.\n\n");
    try w.writeAll("  Enforce file and network policy at the operating-system boundary. The concrete executors are not written.\n");
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
    var status: u8 = 0;
    if (loaded.torn_bytes > 0) {
        try w.print("The last {d} bytes are an incomplete entry. They remain in the file but are not part of the recovered prefix.\n", .{loaded.torn_bytes});
        status = 1;
    }
    if (loaded.malformed) |issue| {
        try w.print("Line {d} is a complete but malformed record at byte {d}. Records after it were not accepted.\n", .{
            issue.line,
            issue.byte_offset,
        });
        status = 1;
    }

    if (try loaded.log.verify()) |broken| {
        try w.print("\nThe log does not verify. Entry {d} (sequence {d}) does not match: {s}.\n", .{ broken.index, broken.sequence, @tagName(broken.reason) });
        try w.writeAll("Everything before that entry is intact. Everything from it onwards has been changed since it was written.\n");
        return 1;
    }
    if (status == 0) {
        try w.writeAll("The log verifies: every entry still hashes to what it did when it was written.\n\n");
    } else {
        try w.writeAll("The recovered prefix verifies, but the complete file does not pass verification.\n\n");
    }

    const graph = try zag.events.graph.Graph.build(arena, loaded.log);
    var all: std.ArrayList(usize) = .empty;
    for (graph.nodes, 0..) |_, index| try all.append(arena, index);
    const summary = graph.summarise(all.items);
    try summary.writeSentence(w);
    try w.writeAll("\n\n");
    try graph.writeTree(w);
    return status;
}

/// Inspect the immutable command-output store. The command is deliberately
/// read-only: unreferenced bytes may be the only evidence left by a crash.
fn contentObjects(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    const opened = zag.workspace.service.Service.open(arena, io, .{
        .root = options.root,
        .actor = workbenchActor(),
        .now = wallClock(io),
    }) catch |err| {
        try w.print("zag could not open the workspace in {s}: {s}. Check the path and its permissions, then run the audit again.\n", .{
            options.root,
            @errorName(err),
        });
        return 1;
    };
    const audit = opened.service.auditContent(io) catch |err| {
        try w.print("zag could not inspect the content store in {s}: {s}. Preserve the store and check its permissions before trying again.\n", .{
            options.root,
            @errorName(err),
        });
        return 1;
    };

    try w.print("Content store for {s}\n", .{options.root});
    try w.print("  {d} unique command-output references in the verified log prefix.\n", .{audit.references});
    try w.print("  {d} canonical objects inspected.\n", .{audit.objects});
    if (!opened.report.logIsHealthy()) {
        try w.writeAll("  The event log is incomplete or damaged, so unreferenced results apply only to its verified prefix.\n");
    }
    for (audit.missing) |hash| {
        try w.writeAll("  Missing ");
        try hash.format(w);
        try w.writeAll(". Restore its bytes from a trusted copy before replaying this command.\n");
    }
    for (audit.changed) |object| {
        try w.writeAll("  Changed ");
        try object.hash.format(w);
        try w.print(" at {s}. Preserve it, then restore bytes whose hash matches its name.\n", .{object.path});
    }
    for (audit.size_mismatches) |mismatch| {
        try w.writeAll("  Size mismatch ");
        try mismatch.hash.format(w);
        try w.print(": the event records {d} bytes but the verified object has {d} bytes. Repair the event only through an approved recovery or migration.\n", .{
            mismatch.expected_bytes,
            mismatch.actual_bytes,
        });
    }
    for (audit.unreferenced) |object| {
        try w.writeAll("  Unreferenced ");
        try object.hash.format(w);
        try w.print(" at {s}. It was kept because it may be crash evidence.\n", .{object.path});
    }
    for (audit.unexpected) |path| {
        try w.print("  Unexpected entry {s}. It was not followed or changed.\n", .{path});
    }
    if (audit.isHealthy() and opened.report.logIsHealthy()) {
        try w.writeAll("  Every referenced object matches its BLAKE3-256 address and recorded byte count. No unreferenced or unexpected entries were found.\n");
        return 0;
    }
    try w.print("  {d} content-store issue(s) found. Nothing was changed.\n", .{audit.issueCount()});
    return 1;
}

/// Describe or apply an event-log truncation. The approval flag is explicit
/// because recovery discards bytes from the active log even though it first
/// preserves those bytes as evidence.
fn recoverWorkspace(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    const plan = zag.events.recovery.inspect(arena, io, options.root) catch |err| {
        try w.print("zag could not inspect the event log in {s}: {s}. Check the path and its permissions; nothing was changed.\n", .{
            options.root,
            @errorName(err),
        });
        return 1;
    };

    try w.print("Recovery plan for {s}\n", .{plan.source_path});
    if (!plan.source_exists) {
        try w.writeAll("  No event log exists. There is nothing to recover, and nothing was changed.\n");
        return 0;
    }
    try w.print("  Original log: {d} bytes, BLAKE3-256 ", .{plan.original_bytes});
    try plan.original_hash.format(w);
    try w.writeAll(".\n");
    if (!plan.needsRecovery()) {
        try w.print("  All {d} events and {d} bytes verify. No recovery is needed, and nothing was changed.\n", .{
            plan.kept_events,
            plan.kept_bytes,
        });
        return 0;
    }

    try w.print("  Verified prefix: {d} events in {d} bytes.\n", .{ plan.kept_events, plan.kept_bytes });
    try w.print("  Proposed truncation: remove {d} bytes from the active log.\n", .{plan.removed_bytes});
    if (plan.chain_break) |broken| {
        try w.print("  Reason: event sequence {d} fails {s}.\n", .{ broken.sequence, @tagName(broken.reason) });
    }
    if (plan.malformed) |issue| {
        try w.print("  Reason: line {d} is a malformed complete record at byte {d}.\n", .{ issue.line, issue.byte_offset });
    }
    if (plan.torn_bytes > 0) {
        try w.print("  Reason: the log ends with {d} incomplete bytes.\n", .{plan.torn_bytes});
    }
    try w.print("  Evidence copy: {s}\n", .{plan.evidence_path});

    if (!options.approve_truncate) {
        try w.writeAll("Nothing was changed. Review this plan, then rerun with --approve-truncate to preserve the original log and apply this exact truncation.\n");
        return 1;
    }

    zag.events.recovery.apply(arena, io, plan) catch |err| {
        try w.print("Recovery did not complete: {s}. Preserve the active log and the planned evidence path, then inspect both before trying again.\n", .{@errorName(err)});
        return 1;
    };
    try w.print("Recovery completed. The original {d} bytes are preserved at {s}.\n", .{ plan.original_bytes, plan.evidence_path });
    try w.print("The active log now contains the verified {d}-event, {d}-byte prefix. Run \"zag objects --root {s}\" before deleting any unreferenced content.\n", .{
        plan.kept_events,
        plan.kept_bytes,
        options.root,
    });
    return 0;
}

/// Search recorded work, using the structured history query language. The
/// answer says what was asked as well as what matched, because a search that
/// silently drops a filter is worse than one that fails.
fn historySearch(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    const query_text = try std.mem.join(arena, " ", options.positional);
    const parsed = try zag.workspace.history.parse(arena, query_text);
    if (!parsed.ok()) {
        for (parsed.problems) |problem| {
            try problem.writeSentence(w);
            try w.writeAll("\n");
        }
        try w.writeAll("\nFilters: status, kind, actor, dir, branch, repo, exit, since, until, marked.\n");
        return 2;
    }
    const opened = zag.workspace.service.Service.open(arena, io, .{
        .root = options.root,
        .actor = workbenchActor(),
        .now = wallClock(io),
    }) catch {
        try w.print("zag could not open the workspace in {s}.\n", .{options.root});
        return 1;
    };
    const incomplete = !opened.report.logIsHealthy();
    if (incomplete) {
        try w.writeAll("The log is incomplete or damaged, so these results cover only its verified prefix.\n\n");
    }
    const index = try opened.service.blocks();
    const results = try zag.workspace.history.run(arena, index, parsed.query, .{
        .now = wallClock(io),
        .limit = 20,
    });
    try results.writeList(w);
    return if (incomplete) 1 else 0;
}

/// Show the workspace knowledge base: what is there, who owns it, and what is
/// past its review date. ISO 30401 asks for named owners and current
/// knowledge; this is where the product answers for itself.
fn knowledgeIndex(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    const opened = zag.workspace.service.Service.open(arena, io, .{
        .root = options.root,
        .actor = workbenchActor(),
        .now = wallClock(io),
    }) catch {
        try w.print("zag could not open the workspace in {s}.\n", .{options.root});
        return 1;
    };
    if (opened.report.knowledgeCount == 0) {
        try w.print("There is no knowledge under {s}/{s}/ yet.\n\n", .{ options.root, zag.workspace.service.workspace_directory });
        try w.writeAll(zag.knowledge.base.layout);
        try w.writeAll("\n");
        return 0;
    }
    try opened.service.knowledge.writeIndex(w);
    if (opened.report.knowledgeFindings.len > 0) {
        try w.writeAll("\nWhat needs attention\n");
        for (opened.report.knowledgeFindings) |finding| {
            try w.print("  {s}: {s}\n", .{ finding.path, finding.message });
        }
        return 1;
    }
    return 0;
}

/// The actor the tool acts as when it opens a workspace of its own accord.
fn workbenchActor() zag.events.event.Actor {
    return .{
        .id = zag.core.id.ActorId.fromRaw(.{ .bytes = [_]u8{0} ** 16 }),
        .kind = .system,
        .label = "zag",
    };
}

/// The wall clock, read through the platform's input and output layer rather
/// than from a global, so a test can drive the tool with a clock of its own.
fn wallClock(io: std.Io) zag.core.time.Timestamp {
    const raw = std.Io.Timestamp.now(io, .real);
    return .{ .ns = @intCast(raw.nanoseconds) };
}

/// Open a shell in a terminal that records what happens in it.
///
/// This is the workbench used as a terminal rather than as a tool: the person's
/// own shell, their own configuration, and a record of every command that they
/// can search and verify afterwards.
fn interactiveTerminal(
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    options: Options,
    environment: []const []const u8,
) !u8 {
    var tty = zag.terminal.tty.Tty.init();
    if (!tty.isTerminal()) {
        try w.writeAll("zag term needs a terminal. Run it from a shell rather than from a pipe.\n");
        return 2;
    }
    if (!zag.terminal.pty.supported) {
        try w.writeAll("This build cannot open a pseudoterminal on this platform yet.\n");
        return 1;
    }

    const opened = zag.workspace.service.Service.open(arena, io, .{
        .root = options.root,
        .actor = .{
            .id = zag.core.id.ActorId.fromRaw(.{ .bytes = [_]u8{0} ** 16 }),
            .kind = .person,
            .label = "you",
        },
        .now = wallClock(io),
    }) catch {
        try w.print("zag could not open the workspace in {s}.\n", .{options.root});
        return 1;
    };
    var service = opened.service;
    if (opened.report.chainBreak) |broken| {
        try w.print("The event log is broken at event {d}, so this session would not be recorded.\n", .{broken.sequence});
        try w.writeAll("Keep the file as it is. A broken log is evidence, not a fault to repair.\n");
        return 1;
    }

    const hook_directory = try std.fmt.allocPrint(arena, "{s}/{s}/shell", .{
        options.root,
        zag.workspace.service.workspace_directory,
    });

    // A secret on every boundary mark, so output printed by a program cannot
    // forge a command boundary in the record.
    var token_bytes: [16]u8 = undefined;
    try io.randomSecure(&token_bytes);
    var token_buffer: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (token_bytes, 0..) |byte, index| {
        token_buffer[index * 2] = hex[byte >> 4];
        token_buffer[index * 2 + 1] = hex[byte & 0x0f];
    }
    const marker_token = try arena.dupe(u8, &token_buffer);
    try w.writeAll("Recording this session. Leave the shell to stop.\n");
    try w.flush();

    const outcome = zag.terminal.interactive.run(&service, &tty, io, .{
        .workingDirectory = options.root,
        .environment = environment,
        .hookDirectory = hook_directory,
        .integrate = !options.raw,
        .markerToken = marker_token,
    }) catch |err| {
        tty.restore();
        switch (err) {
            error.NotATerminal => try w.writeAll("zag term needs a terminal. Run it from a shell rather than from a pipe.\n"),
            error.Unsupported => try w.writeAll("This build cannot open a pseudoterminal on this platform yet.\n"),
            else => return err,
        }
        return 1;
    };
    try service.flush(io);

    try w.writeAll("\n");
    try outcome.writeSummary(w);
    return outcome.exitStatus orelse 0;
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

fn runCommand(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    if (options.passthrough.len == 0) {
        try w.writeAll("Put the command after two dashes. For example: zag run -- echo hello\n");
        return 2;
    }
    if (!zag.terminal.pty.supported) {
        try w.writeAll("This build cannot open a pseudoterminal on this platform yet.\n");
        return 1;
    }

    const opened = zag.workspace.service.Service.open(arena, io, .{
        .root = options.root,
        .actor = .{
            .id = zag.core.id.ActorId.fromRaw(.{ .bytes = [_]u8{0} ** 16 }),
            .kind = .person,
            .label = "you",
        },
        .now = wallClock(io),
    }) catch {
        try w.print("zag could not open the workspace in {s}.\n", .{options.root});
        return 1;
    };
    var service = opened.service;
    if (!opened.report.logIsHealthy()) {
        try opened.report.writeSummary(w);
        try w.writeAll("Keep the file as it is. A broken log is evidence, not a fault to repair.\n");
        return 1;
    }

    const command_text = try std.mem.join(arena, " ", options.passthrough);
    const result = service.runCommand(command_text, zag.core.time.Duration.fromSeconds(120)) catch |err| switch (err) {
        error.ContentTooLarge => {
            try w.writeAll("The command produced more than 64 MiB of captured output. Redirect large output to a file, then run the command again.\n");
            return 1;
        },
        else => {
            try w.print("zag could not run the command: {s}. Check the command and workspace, then run it again.\n", .{@errorName(err)});
            return 1;
        },
    };
    service.flush(io) catch |err| {
        if (err == error.LogTooLarge) {
            try w.writeAll("The command ran, but the active event log would exceed 64 MiB. The workspace is sealed. Preserve it and define an approved rotation or migration before writing more events.\n");
            return 1;
        }
        try w.print("The command ran, but zag could not commit its record: {s}. The workspace is sealed against further writes; preserve it and inspect the storage before retrying.\n", .{@errorName(err)});
        return 1;
    };

    try w.print("{s}\n", .{std.mem.trim(u8, result.screen, " \n")});
    try w.writeAll("\nRecorded as:\n");
    for (result.blocks) |block| {
        try w.writeAll("  ");
        try block.writeSummary(w);
        try w.writeAll("\n");
    }
    if (try service.log.verify()) |_| {
        try w.writeAll("\nThe log does not verify, which should never happen. Please report it.\n");
        return 1;
    }
    try w.print("\n{d} events in the log, and it verifies. Search it with \"zag history\".\n", .{service.log.count()});

    return result.exitStatus orelse 0;
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

fn workflowReport(arena: std.mem.Allocator, w: *std.Io.Writer, options: Options) !u8 {
    const workflow = try zag.workspace.workflow.buildAndCheck(arena, options.repo);
    try workflow.writeSummary(arena, w);

    const findings = try workflow.validate(arena);
    if (findings.items.len > 0) {
        try w.writeAll("\nProblems with the workflow:\n");
        for (findings.items) |finding| try w.print("  {s}: {s}\n", .{ finding.node_id, finding.message });
        return 1;
    }
    return 0;
}

fn lifecycleReport(arena: std.mem.Allocator, w: *std.Io.Writer) !u8 {
    const record = zag.ai.lifecycle.workbenchRecord();
    try record.writeReport(arena, w);
    const findings = try record.review(arena);
    return if (findings.items.len > 0) 1 else 0;
}

/// `zag evidence` — run the checks that can be run, record what each one
/// established, and write the conformance statement that follows from it.
fn evidenceReport(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    const profile = zag.standards.profile.byId(options.profile) orelse {
        try w.print("\"{s}\" is not a profile zag knows. Run \"zag standards profiles\" to see them.\n", .{options.profile});
        return 2;
    };

    var registry = try loadStandards(arena);
    _ = try registry.loadRequirements(@embedFile("registry_requirements"));

    var ledger = zag.standards.evidence.Ledger.init(arena);
    var ids: zag.core.id.Generator = .init(0x2026_0904, 1_788_000_000_000);
    const tool: zag.standards.evidence.ToolIdentity = .{ .name = "zag check", .version = zag.version };
    const now = zag.core.time.Timestamp.epoch;

    // Terminology.
    const system = try zag.knowledge.vocabulary.build(arena);
    const term_findings = try system.validate();
    try ledger.record(.{
        .id = ids.next(zag.core.id.EvidenceId),
        .requirement_id = "ISO-704:R-DEFINITION",
        .subject = "src/knowledge/vocabulary.zig",
        .method = .static_analysis,
        .result = if (term_findings.items.len == 0) .pass else .fail,
        .tool = tool,
        .created_at = now,
        .content_hash = zag.core.hash.Hash.of("vocabulary"),
        .note = "Every concept was checked for a definition that is present, not circular and not negative.",
    });
    try ledger.record(.{
        .id = ids.next(zag.core.id.EvidenceId),
        .requirement_id = "ISO-704:R-ONE-TERM",
        .subject = "src/knowledge/vocabulary.zig",
        .method = .static_analysis,
        .result = if (term_findings.items.len == 0) .pass else .fail,
        .tool = tool,
        .created_at = now,
        .content_hash = zag.core.hash.Hash.of("vocabulary"),
        .note = "No preferred term designates two concepts.",
    });

    const thesaurus = try zag.knowledge.thesaurus.Thesaurus.build(arena, system);
    const reciprocity = try thesaurus.checkReciprocity();
    try ledger.record(.{
        .id = ids.next(zag.core.id.EvidenceId),
        .requirement_id = "ISO-25964:R-RECIPROCAL",
        .subject = "the thesaurus view of the vocabulary",
        .method = .static_analysis,
        .result = if (reciprocity.items.len == 0) .pass else .fail,
        .tool = tool,
        .created_at = now,
        .content_hash = zag.core.hash.Hash.of("thesaurus"),
    });

    // Metadata.
    const metadata_registry = try workbenchMetadataRegistry(arena);
    const metadata_findings = try metadata_registry.validate();
    inline for (.{ "ISO-11179:R-ONE-NAME", "ISO-11179:R-VALUE-DOMAIN" }) |requirement_id| {
        try ledger.record(.{
            .id = ids.next(zag.core.id.EvidenceId),
            .requirement_id = requirement_id,
            .subject = "the metadata registry",
            .method = .static_analysis,
            .result = if (metadata_findings.items.len == 0) .pass else .fail,
            .tool = tool,
            .created_at = now,
            .content_hash = zag.core.hash.Hash.of("metadata"),
        });
    }

    // Accessibility.
    var contrast_failures: usize = 0;
    inline for ([_]zag.accessibility.contrast.Theme{
        zag.accessibility.contrast.default_dark,
        zag.accessibility.contrast.default_light,
    }) |theme| {
        contrast_failures += (try theme.check(arena, .aa)).items.len;
    }
    try ledger.record(.{
        .id = ids.next(zag.core.id.EvidenceId),
        .requirement_id = "WCAG-2.2:R-CONTRAST",
        .subject = "the shipped themes",
        .method = .automated_test,
        .result = if (contrast_failures == 0) .pass else .fail,
        .tool = tool,
        .created_at = now,
        .content_hash = zag.core.hash.Hash.of("themes"),
    });

    const tree_findings = try zag.accessibility.semantic_tree.check(arena, zag.accessibility.semantic_tree.exampleTree(), .{});
    inline for (.{ "WCAG-2.2:R-TARGET-SIZE", "WCAG-2.2:R-NAME-ROLE-VALUE" }) |requirement_id| {
        try ledger.record(.{
            .id = ids.next(zag.core.id.EvidenceId),
            .requirement_id = requirement_id,
            .subject = "the published accessibility tree",
            .method = .automated_test,
            .result = if (tree_findings.items.len == 0) .pass else .fail,
            .tool = tool,
            .created_at = now,
            .content_hash = zag.core.hash.Hash.of("tree"),
        });
    }

    // Governance.
    const risk_register = try zag.ai.risk.workbenchRegister(arena);
    try ledger.record(.{
        .id = ids.next(zag.core.id.EvidenceId),
        .requirement_id = "ISO-23894:R-TREATED",
        .subject = "the risk register",
        .method = .static_analysis,
        .result = if ((try risk_register.review()).items.len == 0) .pass else .fail,
        .tool = tool,
        .created_at = now,
        .content_hash = zag.core.hash.Hash.of("risks"),
    });
    const assessment = try zag.ai.impact.workbenchAssessment(arena);
    try ledger.record(.{
        .id = ids.next(zag.core.id.EvidenceId),
        .requirement_id = "ISO-42005:R-AFFECTED",
        .subject = "the impact assessment",
        .method = .static_analysis,
        .result = if ((try assessment.review(arena)).items.len == 0) .pass else .fail,
        .tool = tool,
        .created_at = now,
        .content_hash = zag.core.hash.Hash.of("impact"),
    });

    // Product text.
    const help_report = try zag.language.plain.check(arena, help_text, .{ .kind = .body, .audience = profile.audience, .terminology = &system });
    var blocking: usize = 0;
    for (help_report.findings) |finding| {
        if (finding.severity == .blocking) blocking += 1;
    }
    inline for (.{ "ISO-24495-1:R-ERROR-NEXT-STEP", "ISO-24495-1:R-LABEL-ACTION", "ISO-24495-1:R-UNDERSTANDABLE", "ISO-24495-1:R-FINDABLE" }) |requirement_id| {
        try ledger.record(.{
            .id = ids.next(zag.core.id.EvidenceId),
            .requirement_id = requirement_id,
            .subject = "the product's own text and the tool's help",
            .method = .static_analysis,
            .result = if (blocking == 0) .pass else .fail,
            .tool = tool,
            .created_at = now,
            .content_hash = zag.core.hash.Hash.of(help_text),
            .note = "The plain-language checker found no blocking problem. It cannot establish that a reader can act on the text.",
        });
    }

    // The workspace knowledge base, against ISO 30401 and ISO 10013.
    const workspace = zag.workspace.service.Service.open(arena, io, .{
        .root = options.repo,
        .actor = workbenchActor(),
        .now = wallClock(io),
    }) catch |err| {
        try w.print("zag could not read workspace knowledge in {s}: {s}. Fix the path or permissions, then generate the evidence again. No evidence file was written.\n", .{
            options.repo,
            @errorName(err),
        });
        return 1;
    };
    {
        var missing_owner: usize = 0;
        var overdue: usize = 0;
        var stateless: usize = 0;
        for (workspace.report.knowledgeFindings) |finding| {
            switch (finding.code) {
                .missing_owner => missing_owner += 1,
                .review_overdue => overdue += 1,
                .approved_without_review_date => stateless += 1,
                else => {},
            }
        }
        const knowledge_checks = [_]struct {
            requirement_id: []const u8,
            failures: usize,
            note: []const u8,
        }{
            .{
                .requirement_id = "ISO-30401:R-OWNER",
                .failures = missing_owner,
                .note = "Every entry under .workspace/ names an owner. Whether that owner acts on the review is not established here.",
            },
            .{
                .requirement_id = "ISO-30401:R-CURRENT",
                .failures = overdue,
                .note = "No approved entry is past its review date. Whether the content is still correct is established by review.",
            },
            .{
                .requirement_id = "ISO-10013:R-STATE",
                .failures = stateless,
                .note = "Every entry carries a state, so a draft cannot be read as approved.",
            },
        };
        for (knowledge_checks) |entry| {
            try ledger.record(.{
                .id = ids.next(zag.core.id.EvidenceId),
                .requirement_id = entry.requirement_id,
                .subject = "the knowledge base under .workspace/",
                .method = .static_analysis,
                .result = if (entry.failures == 0) .pass else .fail,
                .tool = tool,
                .created_at = now,
                .content_hash = zag.core.hash.Hash.of("workspace-knowledge"),
                .note = entry.note,
            });
        }
    }

    // The statement, for each scope the profile covers.
    const scopes = [_]zag.standards.registry.Scope{ .interface_text, .documentation, .terminology, .metadata, .user_interface, .ai_system, .records, .reporting, .data, .process };
    var worst: u8 = 0;
    for (scopes) |scope| {
        const summary = try ledger.summarise(registry, scope, profile.id);
        if (summary.total == 0) continue;
        try ledger.writeStatement(w, registry, scope, profile.id);
        try w.writeAll("\n");
        if (summary.claim == .not_conformant) worst = 1;
    }

    // The evidence itself is a record, so it is written rather than printed and
    // forgotten. It is deterministic: the same repository produces the same
    // file, and a change in the file means a change in what was established.
    var jsonl: std.Io.Writer.Allocating = .init(arena);
    for (ledger.items.items) |item| {
        try std.json.Stringify.value(item, .{}, &jsonl.writer);
        try jsonl.writer.writeByte('\n');
    }
    try writeGenerated(io, std.Io.Dir.cwd(), arena, options.out, "evidence/conformance.jsonl", jsonl.written());
    try w.print("Evidence written to {s}/evidence/conformance.jsonl\n", .{options.out});
    return worst;
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
        try dir.createDirPath(io, parent);
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
        .{ .path = "docs/competitive-position.md", .kind = .body },
        .{ .path = "docs/roadmap.md", .kind = .body },
        .{ .path = "docs/threat-model.md", .kind = .body },
        .{ .path = "docs/platform-support.md", .kind = .body },
        .{ .path = "CONTRIBUTING.md", .kind = .body },
        .{ .path = "SECURITY.md", .kind = .body },
    };
    for (documents) |document| {
        const path = try std.fs.path.join(arena, &.{ options.repo, document.path });
        const source = dir.readFileAlloc(io, path, arena, .limited(8 << 20)) catch |err| {
            try w.print("  TEXT zag could not read {s}: {s}.\n", .{ document.path, @errorName(err) });
            text_findings += 1;
            continue;
        };
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

    // 7. The repository's own workflow and lifecycle record.
    const workflow = try zag.workspace.workflow.buildAndCheck(arena, options.repo);
    const workflow_findings = try workflow.validate(arena);
    const lifecycle_findings = try zag.ai.lifecycle.workbenchRecord().review(arena);
    try w.print("Workflow and lifecycle: {d} workflow problem(s), {d} lifecycle problem(s).\n", .{ workflow_findings.items.len, lifecycle_findings.items.len });
    for (workflow_findings.items) |finding| try w.print("  WORKFLOW {s}: {s}\n", .{ finding.node_id, finding.message });
    for (lifecycle_findings.items) |finding| try w.print("  LIFECYCLE {s}\n", .{finding});
    problems += workflow_findings.items.len + lifecycle_findings.items.len;

    // 8. Instruction files.
    const agents_path = try std.fs.path.join(arena, &.{ options.repo, "AGENTS.md" });
    if (dir.readFileAlloc(io, agents_path, arena, .limited(4 << 20))) |source| {
        const document = try zag.agent_context.agents_md.parse(arena, options.repo, source);
        try w.print("Instruction file: {d} instruction(s), {d} finding(s).\n", .{ document.instructions.len, document.findings.len });
        for (document.findings) |finding| {
            try w.print("  {s} AGENTS.md:{d} {s}\n", .{ finding.code.text(), finding.line, finding.message });
            problems += 1;
        }
    } else |err| {
        try w.print("Instruction file: zag could not read AGENTS.md: {s}.\n", .{@errorName(err)});
        problems += 1;
    }

    // 9. The workspace knowledge base. ISO 30401 asks for named owners and for
    // knowledge that is kept current; this is where the product answers for
    // its own knowledge rather than only for its code.
    const opened = zag.workspace.service.Service.open(arena, io, .{
        .root = options.repo,
        .actor = workbenchActor(),
        .now = wallClock(io),
    }) catch |err| blk: {
        try w.print("Workspace knowledge: zag could not open it: {s}.\n", .{@errorName(err)});
        problems += 1;
        break :blk null;
    };
    if (opened) |workspace| {
        try w.print("Workspace knowledge: {d} entries, {d} problem(s).\n", .{
            workspace.report.knowledgeCount,
            workspace.report.knowledgeFindings.len,
        });
        for (workspace.report.knowledgeFindings) |finding| {
            try w.print("  {s} {s}: {s}\n", .{ finding.code.text(), finding.path, finding.message });
            problems += 1;
        }
        if (!workspace.report.logIsHealthy()) {
            try w.writeAll("  LOG The event log is incomplete or damaged.\n");
            problems += 1;
        }
        // Knowledge an agent reads is product text, so it is held to the same
        // language rules as the documentation.
        for (workspace.service.knowledge.entries.items) |entry| {
            const entry_report = try zag.language.plain.check(arena, entry.body, .{
                .kind = .body,
                .audience = profile.audience,
                .terminology = &system,
            });
            for (entry_report.findings) |finding| {
                if (finding.severity != .blocking) continue;
                try w.print("  {s} {s}:{d} {s}\n", .{ finding.rule.code(), entry.path, finding.line, finding.message });
                problems += 1;
            }
        }
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

    const options = try parseOptions(arena, &.{ "--profile", "legal", "--json", "--approve-truncate", "file.md", "--", "echo", "hello" });
    try testing.expectEqualStrings("legal", options.profile);
    try testing.expect(options.json);
    try testing.expect(options.approve_truncate);
    try testing.expectEqual(@as(usize, 1), options.positional.len);
    try testing.expectEqualStrings("file.md", options.positional[0]);
    try testing.expectEqual(@as(usize, 2), options.passthrough.len);
    try testing.expectEqualStrings("hello", options.passthrough[1]);

    try testing.expectError(error.MissingOptionValue, parseOptions(arena, &.{"--profile"}));
    try testing.expectError(error.UnknownOption, parseOptions(arena, &.{"--wat"}));
    try testing.expect(approvalOptionIsValid(.recover, options));
    try testing.expect(!approvalOptionIsValid(.doctor, options));
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

test "events rejects a malformed complete record without hiding it as torn" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/events.jsonl", .{tmp.sub_path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "not an event\n" });

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const status = try events(arena, io, &writer, .{ .positional = &.{path} });
    try testing.expectEqual(@as(u8, 1), status);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "complete but malformed") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "recovered prefix verifies") != null);
}

test "objects reports an unreferenced object and does not delete it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var store = zag.events.content_store.Store.init(arena, root);
    const hash = try store.put("crash evidence");
    try store.flush(io);

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const status = try contentObjects(arena, io, &writer, .{ .root = root });
    try testing.expectEqual(@as(u8, 1), status);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Unreferenced") != null);
    try testing.expectEqualStrings("crash evidence", try store.read(io, hash, 1024));
}

test "recover plans first and applies only with explicit approval" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const workspace = try std.fmt.allocPrint(arena, "{s}/.workspace", .{root});
    const path = try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{workspace});
    try std.Io.Dir.cwd().createDirPath(io, workspace);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "torn" });

    var plan_buffer: [4096]u8 = undefined;
    var plan_writer = std.Io.Writer.fixed(&plan_buffer);
    try testing.expectEqual(@as(u8, 1), try recoverWorkspace(arena, io, &plan_writer, .{ .root = root }));
    try testing.expect(std.mem.indexOf(u8, plan_writer.buffered(), "Nothing was changed") != null);
    try testing.expectEqualStrings("torn", try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16)));

    var apply_buffer: [4096]u8 = undefined;
    var apply_writer = std.Io.Writer.fixed(&apply_buffer);
    try testing.expectEqual(@as(u8, 0), try recoverWorkspace(arena, io, &apply_writer, .{
        .root = root,
        .approve_truncate = true,
    }));
    try testing.expect(std.mem.indexOf(u8, apply_writer.buffered(), "Recovery completed") != null);
    try testing.expectEqualStrings("", try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16)));
}

test "recover reports an absent event log as a clean no-op" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try testing.expectEqual(@as(u8, 0), try recoverWorkspace(arena, io, &writer, .{
        .root = root,
        .approve_truncate = true,
    }));
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "No event log exists") != null);
    const event_path = try std.fmt.allocPrint(arena, "{s}/.workspace/events.jsonl", .{root});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, event_path, .{}));
}

test "evidence generation never hides an unreadable workspace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const event_path = try std.fmt.allocPrint(arena, "{s}/.workspace/events.jsonl", .{root});
    try std.Io.Dir.cwd().createDirPath(io, event_path);

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const status = try evidenceReport(arena, io, &writer, .{ .repo = root });
    try testing.expectEqual(@as(u8, 1), status);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "No evidence file was written") != null);
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
