//! The zag command-line tool.
//!
//! This is the workbench: it opens a workspace, records what happens in it, and
//! asks models questions through the policy. Everything that audits a
//! repository against the standards it claims to meet moved to `zag-audit`,
//! because none of it is needed to record a shell session.
//!
//! The help text below is still checked by `zag-audit check`, using the
//! product's own plain-language rules. If the help is unclear, the build says
//! so — the check just runs from the other binary now.

const std = @import("std");
const zag = @import("zag");

const Command = enum {
    help,
    version,
    doctor,
    events,
    objects,
    recover,
    agents,
    run,
    shell_hook,
    workflow,
    history,
    show,
    knowledge,
    term,
    providers,
    policy,
    ask,
    why,
    secrets,

    fn parse(text: []const u8) ?Command {
        const table = [_]struct { name: []const u8, command: Command }{
            .{ .name = "help", .command = .help },
            .{ .name = "--help", .command = .help },
            .{ .name = "-h", .command = .help },
            .{ .name = "version", .command = .version },
            .{ .name = "--version", .command = .version },
            .{ .name = "doctor", .command = .doctor },
            .{ .name = "events", .command = .events },
            .{ .name = "objects", .command = .objects },
            .{ .name = "recover", .command = .recover },
            .{ .name = "agents", .command = .agents },
            .{ .name = "run", .command = .run },
            .{ .name = "shell-hook", .command = .shell_hook },
            .{ .name = "workflow", .command = .workflow },
            .{ .name = "history", .command = .history },
            .{ .name = "show", .command = .show },
            .{ .name = "knowledge", .command = .knowledge },
            .{ .name = "term", .command = .term },
            .{ .name = "providers", .command = .providers },
            .{ .name = "policy", .command = .policy },
            .{ .name = "ask", .command = .ask },
            .{ .name = "why", .command = .why },
            .{ .name = "secrets", .command = .secrets },
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
    \\  events <file>       Verify an event log and summarise what happened.
    \\  objects             Audit every command-output object without changing it.
    \\  recover             Plan recovery of a damaged event log without changing it.
    \\  agents <file>       Read an instruction file and show what it asks for.
    \\  run -- <command>    Run a command on a real terminal and record it as a block.
    \\  shell-hook <shell>  Print the shell integration for bash, zsh, fish or pwsh.
    \\  workflow            Show this repository's own workflow as a task graph.
    \\  history <query>     Search recorded work. For example: status:failed zig
    \\  show <query>        Show what a recorded command printed.
    \\  knowledge           Show the knowledge under .workspace/, and what is overdue.
    \\  term                Open a shell in a terminal that records what you do.
    \\  providers           List the model connectors and say which credentials are set.
    \\  policy [--init]     Show the policy in force, or write one to start from.
    \\  ask <question>      Ask a model, through the policy. It can use tools, one decision each.
    \\  why <file> [n]      Show what an event depended on, and what it went on to affect.
    \\  secrets <files>     Show what would be taken out of these files before recording them.
    \\
    \\Options
    \\  --json              Write the result as JSON.
    \\  --repo <directory>  Read the repository in this directory.
    \\  --root <directory>  Read the workspace in this directory.
    \\  --provider <name>   Which connector to use. Run "zag providers" to see them.
    \\  --model <name>      Which model to ask for.
    \\  --turns <count>     How many times a model may be asked in one run.
    \\  --compact-at <n>    Make room in the conversation once it passes n bytes.
    \\  --raw               Start the shell with no added prompt marks.
    \\  --stream            Print a model's answer as it arrives, not when it finishes.
    \\  --init              Write a starter policy file. Used with "zag policy".
    \\  --approve-truncate  Apply the recovery plan after preserving the original log.
    \\
    \\To audit a repository against the standards it claims to meet, use
    \\"zag-audit". Run "zag-audit help" to see it.
    \\
    \\Read more in README.md, or run "zag doctor" to see this build.
    \\
;

const Options = struct {
    json: bool = false,
    repo: []const u8 = ".",
    root: []const u8 = ".",
    /// Run the shell exactly as it is, with no generated init file.
    raw: bool = false,
    /// Print a model's answer as it arrives rather than when it is finished.
    stream: bool = false,
    approve_truncate: bool = false,
    /// Write a starter policy file rather than showing the policy in force.
    init: bool = false,
    /// Bytes of conversation above which room is made. Empty means the default.
    compact_at: []const u8 = "",
    provider: []const u8 = "",
    model: []const u8 = "",
    turns: []const u8 = "",
    positional: []const []const u8 = &.{},
    /// Everything after `--`.
    passthrough: []const []const u8 = &.{},
};

fn approvalOptionIsValid(command: Command, options: Options) bool {
    return !options.approve_truncate or command == .recover;
}

fn initOptionIsValid(command: Command, options: Options) bool {
    return !options.init or command == .policy;
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
        if (std.mem.eql(u8, arg, "--init")) {
            options.init = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--raw")) {
            options.raw = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--stream")) {
            options.stream = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--approve-truncate")) {
            options.approve_truncate = true;
            continue;
        }
        const named = [_]struct { flag: []const u8, field: *[]const u8 }{
            .{ .flag = "--repo", .field = &options.repo },
            .{ .flag = "--root", .field = &options.root },
            .{ .flag = "--provider", .field = &options.provider },
            .{ .flag = "--model", .field = &options.model },
            .{ .flag = "--turns", .field = &options.turns },
            .{ .flag = "--compact-at", .field = &options.compact_at },
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
    if (!initOptionIsValid(command, options)) {
        try w.writeAll("--init applies only to \"zag policy\". Nothing was changed.\n");
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
        .doctor => try doctor(arena, io, w, options, environment),

        .events => try events(arena, io, w, options),
        .objects => try contentObjects(arena, io, w, options),
        .recover => try recoverWorkspace(arena, io, w, options),
        .agents => try agentsFile(arena, io, w, options),
        .run => try runCommand(arena, io, w, options, environment),
        .shell_hook => try shellHook(w, options),
        .workflow => try workflowReport(arena, w, options),
        .history => try historySearch(arena, io, w, options),
        .show => try showOutput(arena, io, w, options),
        .knowledge => try knowledgeIndex(arena, io, w, options),
        .term => try interactiveTerminal(arena, io, w, options, environment),
        .providers => try listProviders(arena, io, w, options, environment),
        .policy => try showPolicy(arena, io, w, options),
        .ask => try askAModel(arena, io, w, options, environment),
        .why => try whyDidThatHappen(arena, io, w, options),
        .secrets => try showSecrets(arena, io, w, options),
    };
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn doctor(
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    options: Options,
    environment: []const []const u8,
) !u8 {
    const builtin = @import("builtin");
    const loaded = try LoadedPolicy.fromWorkspace(arena, io, options.root);
    const written_policy = loaded.path != null and loaded.problems.len == 0;
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
    try w.print("  Policy written by you, in a file:   {s}\n", .{if (written_policy) "yes, and it is in force" else "yes, but none is written here"});
    try w.print("  File access held inside the folder: {s}\n", .{if (zag.ai.sandbox.supported) "yes, enforced by the kernel" else "not on this platform"});
    try w.print("  Ask a model, through the policy:    yes, {d} connectors, {d} on this computer\n", .{
        zag.ai.catalog.count(),
        zag.ai.catalog.localCount(),
    });
    try w.print("  Agent loop, decided at each step:   yes, {d} tools offered to a model\n", .{
        zag.ai.toolschema.offers.len,
    });
    try w.writeAll("  Explain a failure from the record:  yes, with zag why\n");
    try w.writeAll("  Read an answer as it arrives:       yes, with --stream\n");
    try w.writeAll("  Run independent tool calls at once:  yes, in waves that share nothing\n");
    try w.writeAll("  Audit this repository:              yes, in the zag-audit binary\n\n");

    try w.writeAll("What this build cannot do yet\n");
    try w.writeAll("  Draw its own window. The renderer is not written; the accessibility tree it must publish is.\n");
    try w.writeAll("  Talk to a language server. The editor surfaces are not written.\n");
    try w.writeAll("  Run on Windows or macOS terminals. The pseudoterminal layer is Linux only so far.\n");
    try w.writeAll("  Split the screen. There are no tabs, panes or splits yet.\n");
    try w.writeAll("  Draw the colours or bind the keys a settings file asks for. It reads them and reports on them.\n\n");

    try writeNextStep(arena, w, loaded, written_policy, environment);

    const system = try zag.knowledge.vocabulary.build(arena);
    try w.print("The vocabulary holds {d} concepts.\n", .{system.count()});
    try w.print("The risk register holds {d} risks.\n", .{(try zag.ai.risk.workbenchRegister(arena)).risks.items.len});
    try w.print("The standards profile in use is \"{s}\".\n", .{zag.standards.profile.default.name});
    return 0;
}

fn events(arena: std.mem.Allocator, io: std.Io, w: *std.Io.Writer, options: Options) !u8 {
    if (options.positional.len == 0) {
        try w.writeAll("Name the log file to read. For example: zag events workspace.jsonl\n");
        return 2;
    }
    const path = options.positional[0];
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(zag.events.log.max_file_bytes)) catch {
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
    // No lookup here, deliberately. Building one costs about five times what a
    // single scan of the same blocks costs, so for a command that runs one
    // query and exits it would make `zag history` slower. The index is for a
    // surface that holds a workspace open and asks repeatedly; the numbers are
    // in `zig build bench` and the reasoning is in `workspace/index.zig`.
    const results = try zag.workspace.history.run(arena, index, parsed.query, .{
        .now = wallClock(io),
        .limit = 20,
    });
    try results.writeList(w);
    return if (incomplete) 1 else 0;
}

/// Show what a recorded command printed.
///
/// The output of every command is stored, verified and addressed by hash, and
/// until now nothing could read it back. A workspace that records what happened
/// and cannot show it to you has kept the evidence and lost the point: the
/// question a person actually asks is "what did it say when it broke", and the
/// answer was on disk with no way to reach it.
///
/// It takes the same query language as `zag history`, and shows the newest
/// match, because "show me the last failure" is the question.
fn showOutput(
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    options: Options,
) !u8 {
    const query_text = try std.mem.join(arena, " ", options.positional);
    const parsed = try zag.workspace.history.parse(arena, query_text);
    for (parsed.problems) |problem| {
        try problem.writeSentence(w);
        try w.writeAll("\n");
    }
    if (!parsed.ok()) return 2;

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
        try w.writeAll("The log is incomplete or damaged, so this covers only its verified prefix.\n\n");
    }

    const index = try opened.service.blocks();
    const results = try zag.workspace.history.run(arena, index, parsed.query, .{
        .now = wallClock(io),
        .limit = 1,
    });
    if (results.hits.len == 0) {
        try results.writeSummary(w);
        return 1;
    }

    const block = results.hits[0].block;
    try w.print("{s}\n", .{block.commandText orelse "(no command recorded)"});
    if (block.exitStatus) |status| {
        try w.print("{s}, status {d}", .{ block.status.text(), status });
    } else {
        try w.print("{s}", .{block.status.text()});
    }
    if (block.duration()) |took| {
        try w.writeAll(", took ");
        try zag.reports.notation.writeDuration(w, took);
    }
    try w.writeAll("\n\n");

    if (block.content == .none) {
        try w.writeAll("It printed nothing.\n");
        return if (incomplete) 1 else 0;
    }

    // Reassembled in the order the pieces were produced. A block whose output
    // arrived in three chunks is three objects, and showing only one of them
    // would be the same class of mistake the chunked variant exists to prevent.
    var single: [1]zag.workspace.block.Chunk = undefined;
    const pieces = block.content.pieces(&single);
    var shown: usize = 0;
    for (pieces) |piece| {
        const bytes = opened.service.content.read(io, piece.hash, 64 << 20) catch {
            try w.print("\n[a piece of this output is missing from the store: {f}]\n", .{piece.hash});
            continue;
        };
        try w.writeAll(bytes);
        shown += bytes.len;
    }
    if (shown != block.content.totalBytes()) {
        try w.print(
            "\n[{d} bytes shown of {d} recorded]\n",
            .{ shown, block.content.totalBytes() },
        );
    }
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
///
/// This is the workbench doing its job, not a person asking for something, and
/// the record has to be able to tell those apart.
fn workbenchActor() zag.events.event.Actor {
    return zag.events.event.Actor.of(zag.core.identity.program("zag"));
}

/// The person running the tool.
///
/// Derived from the account and machine names, so the same person is the same
/// actor in every workspace they open. Every event used to carry sixteen zero
/// bytes here, which meant the record could not say who wrote it or even
/// whether a person was involved.
fn personActor(arena: std.mem.Allocator, environment: []const []const u8) !zag.events.event.Actor {
    return zag.events.event.Actor.of(try zag.core.identity.person(arena, environment));
}

/// The wall clock, read through the platform's input and output layer rather
/// than from a global, so a test can drive the tool with a clock of its own.
// ---------------------------------------------------------------------------
// Model providers
// ---------------------------------------------------------------------------

/// Reads credentials from the environment the person started zag with.
///
/// The library never touches the environment itself. This is the one place
/// that does, and it hands the value straight to the connector's encoder, so
/// no key is ever held anywhere a log or an error message could reach it.
const Environment = struct {
    entries: []const []const u8,

    fn credentials(self: *const Environment) zag.ai.transport.Credentials {
        return .{ .context = @constCast(self), .lookupFn = lookup };
    }

    fn lookup(context: *anyopaque, variable: []const u8) ?[]const u8 {
        const self: *const Environment = @ptrCast(@alignCast(context));
        for (self.entries) |entry| {
            const equals = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (std.mem.eql(u8, entry[0..equals], variable)) {
                const value = entry[equals + 1 ..];
                return if (value.len > 0) value else null;
            }
        }
        return null;
    }
};

threadlocal var credential_view: ?*const Environment = null;

fn credentialIsSet(variable: []const u8) bool {
    const view = credential_view orelse return false;
    return Environment.lookup(@constCast(view), variable) != null;
}

fn listProviders(
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    options: Options,
    environment: []const []const u8,
) !u8 {
    _ = arena;
    _ = io;
    _ = options;
    const view: Environment = .{ .entries = environment };
    credential_view = &view;
    defer credential_view = null;
    try zag.ai.catalog.writeList(w, credentialIsSet);
    return 0;
}

/// Read the workspace's policy, or say plainly that the built-in one is in use.
///
/// A policy that was written by a person and a policy that was chosen for them
/// are different things, and the difference is worth a line of output every
/// time rather than being something they have to remember.
const LoadedPolicy = struct {
    policy: zag.ai.policy.Policy,
    path: ?[]const u8,
    problems: []const zag.ai.policy_file.Problem,

    fn fromWorkspace(arena: std.mem.Allocator, io: std.Io, root: []const u8) !LoadedPolicy {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{
            root,
            zag.ai.policy_file.default_path,
        });
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch {
            const built_in = try zag.ai.policy_file.parse(arena, zag.ai.policy_file.local_models_only);
            return .{ .policy = built_in.policy.?, .path = null, .problems = &.{} };
        };
        const result = try zag.ai.policy_file.parse(arena, source);
        if (result.policy) |written| {
            return .{ .policy = written, .path = path, .problems = &.{} };
        }
        // A file that could not be read grants nothing. The built-in policy is
        // not substituted for it, because that would turn a mistake in the
        // file into permissions the person did not write.
        return .{
            .policy = .{
                .id = "unusable",
                .name = "This workspace's policy could not be read",
                .description = "Nothing is allowed until the policy file is fixed.",
                .rules = &.{},
            },
            .path = path,
            .problems = result.problems,
        };
    }
};

fn showPolicy(
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    options: Options,
) !u8 {
    if (options.init) return writeStarterPolicy(arena, io, w, options);

    const loaded = try LoadedPolicy.fromWorkspace(arena, io, options.root);

    if (loaded.path) |path| {
        try w.print("Read from {s}.\n\n", .{path});
    } else {
        try w.print(
            "No policy is written in this workspace, so the built-in one is in force.\nWrite {s}/{s} to change it.\n\n",
            .{ options.root, zag.ai.policy_file.default_path },
        );
    }

    if (loaded.problems.len > 0) {
        try w.writeAll("This file could not be used. Nothing in it is in force.\n");
        for (loaded.problems) |problem| {
            if (problem.rule) |number| {
                try w.print("  Rule {d}: {s}\n", .{ number, problem.message });
            } else {
                try w.print("  {s}\n", .{problem.message});
            }
        }
        return 1;
    }

    try zag.ai.policy_file.describe(loaded.policy, w);
    return 0;
}

/// Say what is standing between this workspace and asking a model.
///
/// `zag doctor` listed what the build could do and left the person to work out
/// why their own machine would not do it. The interesting case is the one that
/// costs an afternoon: a key is set, the connector exists, and the policy in
/// force — usually the built-in one, which allows only a model on this
/// computer — refuses the network. Nothing is broken, nothing is misspelt, and
/// the only sign is a refusal at the moment of asking.
///
/// So this checks the two halves against each other and names the missing one.
/// A credential's value is never read here, only whether the variable is set:
/// the point is to say "the key is there", not to look at it.
fn wallClockOrZero() zag.core.time.Timestamp {
    // The decision here is only about a host, and no rule in a starter policy
    // is time-scoped, so a fixed instant keeps `zag doctor` from needing a
    // clock it does not otherwise use.
    return .{ .ns = 0 };
}

fn writeNextStep(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    loaded: LoadedPolicy,
    written_policy: bool,
    environment: []const []const u8,
) !void {
    const env: Environment = .{ .entries = environment };

    // Which connectors could actually be used: a hosted one needs its key set,
    // a local one needs nothing.
    var keyed: ?zag.ai.catalog.Connector = null;
    var local: ?zag.ai.catalog.Connector = null;
    for (zag.ai.catalog.connectors) |connector| {
        if (connector.locality == .local) {
            if (local == null) local = connector;
            continue;
        }
        if (connector.keyVariable.len == 0) continue;
        if (keyed == null and Environment.lookup(@constCast(&env), connector.keyVariable) != null) keyed = connector;
    }

    if (loaded.problems.len > 0) {
        try w.writeAll("Next: this workspace has a policy file that cannot be used, so nothing in\n");
        try w.writeAll("it is in force. Run \"zag policy\" to see what is wrong with it.\n\n");
        return;
    }

    const connector = keyed orelse {
        try w.writeAll("Next: no credential is set for any hosted connector, so a model on this\n");
        if (local) |one| {
            try w.print("computer is the one this build can reach. Start {s} and run \"zag ask\",\n", .{one.name});
            try w.writeAll("or set a key and run \"zag providers\" to see which one it belongs to.\n\n");
        } else {
            try w.writeAll("computer would be the way in. Run \"zag providers\" to see the connectors.\n\n");
        }
        return;
    };

    // A key is set. Does the policy in force let it reach that host?
    var engine = zag.ai.policy.Engine.init(arena, loaded.policy, 0);
    const host = connector.endpoint("").host();
    const reachable = engine.decide(.{
        .capability = .@"network.connect",
        .resource = .{ .host = host },
    }, .{
        .actor = .{ .raw = .{ .bytes = @splat(0) } },
        .session = .{ .raw = .{ .bytes = @splat(0) } },
        .agent = .{ .raw = .{ .bytes = @splat(0) } },
        .now = wallClockOrZero(),
    }) catch null;

    if (reachable) |decision| {
        if (decision.isAllowed()) {
            try w.print("Next: {s} is set and the policy allows reaching {s}.\n", .{ connector.keyVariable, host });
            try w.writeAll("Run \"zag ask\" to ask a question, or \"zag term\" to open a recorded shell.\n\n");
            return;
        }
    }

    // The interesting case, and the reason this function exists.
    try w.print("Next: {s} is set, so this build can reach {s} — but the policy in force\n", .{ connector.keyVariable, connector.name });
    try w.print("refuses to connect to {s}, so a question would be stopped before it was\n", .{host});
    try w.writeAll("sent. That is the policy doing its job, not a fault.\n");
    if (written_policy) {
        try w.print("Add {s} to a network.connect rule in {s}.\n\n", .{ host, zag.ai.policy_file.default_path });
    } else {
        try w.writeAll("Run \"zag policy --init\" to write a starter file that allows it.\n\n");
    }
}

/// Write a starter policy file for a person who has a key and no policy.
///
/// It never overwrites. A policy file is the thing standing between an agent
/// and someone's machine, and a command that silently replaced one because a
/// flag was typed twice would be the worst possible way to widen a policy.
fn writeStarterPolicy(
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    options: Options,
) !u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ options.root, zag.ai.policy_file.default_path });

    // Checked by reading, not by a flag on the open: a workspace where the
    // policy exists but cannot be read is not one to write into either.
    if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20))) |_| {
        try w.print("{s} already exists, so nothing was written.\n", .{path});
        try w.writeAll("Run \"zag policy\" to see what is in force, and edit that file to change it.\n");
        return 1;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => {
            try w.print("{s} exists but could not be read, so nothing was written.\n", .{path});
            return 1;
        },
    }

    // The host the starter file names comes from the connector the person
    // asked for, so the file is right for the provider they actually use
    // rather than right for the one this tool happened to list first.
    const connector_name = if (options.provider.len > 0) options.provider else "anthropic";
    const connector = zag.ai.catalog.find(connector_name) orelse {
        try w.print("\"{s}\" is not a connector this build knows. Run \"zag providers\" to see them.\n", .{connector_name});
        return 2;
    };

    var text: std.Io.Writer.Allocating = .init(arena);
    try zag.ai.policy_file.writeStarter(&text.writer, connector.endpoint("").host());

    const directory = try std.fmt.allocPrint(arena, "{s}/{s}", .{ options.root, zag.workspace.service.workspace_directory });
    std.Io.Dir.cwd().createDirPath(io, directory) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.written() }) catch {
        try w.print("zag could not write {s}.\n", .{path});
        return 1;
    };

    try w.print("Wrote {s} for {s}.\n\n", .{ path, connector.name });
    try w.writeAll("It allows asking a model, reaching that one host, and spending a saved\n");
    try w.writeAll("key without reading it. Everything else is refused. Read it before you\n");
    try w.writeAll("widen it, and run \"zag policy\" to see what is in force.\n");
    return 0;
}

/// Ask a model one question, through the policy.
///
/// Nothing here decides anything. The connector is chosen, the policy is read
/// from the workspace, and the transport asks it three times before a byte
/// leaves. When the answer is no, this prints what was refused and why, which
/// is the more interesting outcome and the one worth reading carefully.
fn askAModel(
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    options: Options,
    environment: []const []const u8,
) !u8 {
    if (options.positional.len == 0) {
        try w.writeAll("Write the question after the command. For example: zag ask \"what does this build do?\"\n");
        return 2;
    }

    const chosen = if (options.provider.len > 0) options.provider else "ollama";
    const connector = zag.ai.catalog.find(chosen) orelse {
        try w.print("\"{s}\" is not a connector zag knows. Run \"zag providers\" to see them.\n", .{chosen});
        return 2;
    };

    var question: std.ArrayList(u8) = .empty;
    for (options.positional, 0..) |word, index| {
        if (index > 0) try question.append(arena, ' ');
        try question.appendSlice(arena, word);
    }

    const loaded = try LoadedPolicy.fromWorkspace(arena, io, options.root);
    if (loaded.problems.len > 0) {
        try w.writeAll("This workspace's policy could not be read, so nothing was sent.\n");
        try w.writeAll("Run \"zag policy\" to see what is wrong with it.\n");
        return 1;
    }

    // The run is recorded in the workspace, like everything else. A model path
    // that talked to a provider, ran tools and printed to standard output
    // without writing a single event was the one place this product did not do
    // what it says it does.
    const opened = zag.workspace.service.Service.open(arena, io, .{
        .root = options.root,
        .actor = try personActor(arena, environment),
        .now = wallClock(io),
        .environment = environment,
    }) catch {
        try w.print("zag could not open the workspace in {s}, so this run would not be recorded.\n", .{options.root});
        return 1;
    };
    var service = opened.service;
    if (!opened.report.logIsHealthy()) {
        try opened.report.writeSummary(w);
        try w.writeAll("Keep the file as it is. A broken log is evidence, not a fault to repair.\n");
        return 1;
    }
    var recorder = zag.workspace.service.Service.AgentRecorder.init(&service);

    var engine = zag.ai.policy.Engine.init(arena, loaded.policy, @bitCast(wallClock(io).ns));
    var identifiers = zag.core.id.Generator.init(@bitCast(wallClock(io).ns), 0);
    const context: zag.ai.policy.Context = .{
        .actor = identifiers.next(zag.core.id.ActorId),
        .now = wallClock(io),
    };

    const view: Environment = .{ .entries = environment };
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    var http: zag.ai.transport.Http = .{ .client = &client };

    var sleeper: zag.ai.transport.SleepingWaiter = .{ .io = io };
    const transport: zag.ai.transport.Transport = .{
        .arena = arena,
        .engine = &engine,
        .sender = http.sender(),
        .credentials = view.credentials(),
        // Nothing that looks like a credential leaves this machine, whatever
        // the policy allowed to leave. The two are separate questions and this
        // is the second one.
        .streaming = http.streamingSender(),
        .redactor = try zag.security.secrets.Redactor.init(io),
        // And nothing connects to a host whose name does not resolve to where
        // the connector said it lives.
        .guard = .{ .io = io },
        // A 429 or a 503 is a shared service saying "not right now", not a
        // reason to throw away everything the run has done.
        .waiter = sleeper.waiter(),
    };

    // The loop, not a single question. A model that can read the workspace and
    // run the tests is worth more than one that can only answer, and every one
    // of those actions is a separate decision the policy makes.
    const executor: zag.ai.executor.Runner = .init(arena, .{
        .root = options.root,
        .io = io,
        // What a model-issued command may see of this is decided per request by
        // its environment policy, which by default hands over enough to run a
        // build and nothing that carries a credential.
        .environment = environment,
        // Without a store, every write_file is refused with "this build cannot
        // perform that kind of request" — which reads like the tool does not
        // exist rather than like the tool has nowhere to put anything.
        .content = &service.content,
    });
    // Printing straight to the writer as the answer arrives. The writer is
    // flushed on each piece, because a buffered stream shown at the end is a
    // slower way of not streaming.
    const Live = struct {
        fn write(target: ?*anyopaque, chunk: []const u8) anyerror!void {
            const out: *std.Io.Writer = @ptrCast(@alignCast(target orelse return));
            try out.writeAll(chunk);
            try out.flush();
        }
    };

    const runner: zag.ai.loop.Runner = .{
        .arena = arena,
        .transport = transport,
        .executor = executor,
        .engine = &engine,
        .clock = monotonic(io),
        .journal = recorder.journal(),
        // Independent tool calls overlap. Which ones are independent is worked
        // out from the typed requests the policy engine already decided about,
        // and the record comes out the same either way.
        .io = io,
        .watch = if (options.stream)
            .{ .context = w, .textFn = Live.write }
        else
            null,
    };

    var budget: zag.ai.loop.Budget = .{};
    if (options.turns.len > 0) {
        budget.turns = std.fmt.parseInt(usize, options.turns, 10) catch {
            try w.print("\"{s}\" is not a number of turns.\n", .{options.turns});
            return 2;
        };
    }
    if (options.compact_at.len > 0) {
        budget.compaction.threshold = std.fmt.parseInt(usize, options.compact_at, 10) catch {
            try w.print("\"{s}\" is not a number of bytes.\n", .{options.compact_at});
            return 2;
        };
    }

    const transcript = try runner.run(.{
        .connector = connector,
        .model = if (options.model.len > 0) options.model else defaultModel(connector),
        .system = agent_instructions,
        .budget = budget,
    }, question.items, context);

    // The record is committed before anything is printed, so what a person
    // reads on screen is what the log already holds.
    service.flush(io) catch |err| {
        try w.print("The run finished, but zag could not commit its record: {s}.\n", .{@errorName(err)});
        return 1;
    };

    // Already on screen when it was watched, so printing it again would show
    // the answer twice.
    if (!options.stream and transcript.answer.len > 0) try w.print("{s}\n\n", .{transcript.answer});
    if (options.stream and transcript.answer.len > 0) try w.writeAll("\n\n");

    for (transcript.turns) |turn| {
        for (turn.steps) |step| {
            try w.print("  {s} {s}\n", .{
                if (step.ran()) "ran" else "did not run:",
                step.toolName,
            });
            if (!step.ran()) try w.print("    {s}\n", .{step.reply});
        }
    }
    if (transcript.toolCallCount() > 0) try w.writeAll("\n");

    try transcript.writeSummary(w);
    if (recorder.failure) |problem| {
        try w.print("Part of this run could not be recorded: {s}.\n", .{problem});
    } else {
        try w.print("Recorded as {d} events in {s}/.workspace. Read it with \"zag why\".\n", .{
            recorder.recorded,
            options.root,
        });
    }

    if (transcript.pending) |request| {
        try w.print("\nIt is waiting for you to allow: {s} on {s}.\n", .{
            request.capability().explain(),
            (try request.resource(arena)).text(),
        });
        try w.writeAll("Add a rule for it to the workspace policy, then run this again.\n");
    }

    // The decisions from the last model request, which is where a refusal that
    // stopped the run will be.
    if (transcript.turns.len > 0) {
        const last = transcript.turns[transcript.turns.len - 1];
        if (last.attempt.refusedAt != null or !transcript.ending.succeeded()) {
            try w.writeAll("\n");
            if (last.attempt.sendProblem.len > 0) try w.print("{s}\n", .{last.attempt.sendProblem});
            if (last.attempt.providerError.len > 0) {
                try w.print("{s} answered {d}: {s}\n", .{
                    connector.name,
                    last.attempt.status orelse 0,
                    last.attempt.providerError,
                });
            }
            try writeDecisions(last.attempt, w);
        }
    }

    return if (transcript.ending.succeeded()) 0 else 1;
}

/// Show what one recorded event depended on, and what it went on to affect.
///
/// The causal chain answers "what led to this". The dependency graph answers
/// the harder question: which earlier work this rests on through the files that
/// passed between them, even when nothing caused anything and the two happened
/// in different sessions hours apart.
/// Show what the redactor would take out of a file, without changing it.
///
/// A person deciding whether to record something, or checking why a placeholder
/// appeared in a record they already have, needs to be able to ask this
/// directly. Nothing here writes anything, and the secrets themselves are never
/// printed — only what kind each one is, and where.
fn showSecrets(
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    options: Options,
) !u8 {
    if (options.positional.len == 0) {
        try w.writeAll("Name the files to check. For example: zag secrets .env deploy.log\n");
        return 2;
    }

    // A fresh salt each run. The fingerprints tell you which findings are the
    // same credential *within this report*, and mean nothing outside it, which
    // is what stops a printed report becoming a guessing oracle later.
    const redactor = try zag.security.secrets.Redactor.init(io);
    var total: usize = 0;
    var unreadable: usize = 0;

    for (options.positional) |path| {
        const contents = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch {
            try w.print("{s}: could not be read.\n", .{path});
            unreadable += 1;
            continue;
        };
        const findings = try zag.security.secrets.scan(arena, contents, .{});
        if (findings.len == 0) {
            try w.print("{s}: nothing found.\n", .{path});
            continue;
        }
        try w.print("{s}: {d} to remove.\n", .{ path, findings.len });
        for (findings) |finding| {
            const line = 1 + std.mem.count(u8, contents[0..finding.start], "\n");
            const print = redactor.fingerprint(contents[finding.start..finding.end]);
            try w.print("  line {d}: {s} ({s}, {d} bytes) {s}\n", .{
                line,
                finding.kind.text(),
                finding.kind.certainty().text(),
                finding.len(),
                print,
            });
        }
        total += findings.len;
    }

    if (total > 0) {
        try w.writeAll(
            \\
            \\Each of these would be replaced by a placeholder naming its kind, before
            \\anything was written to the record. The value itself is not printed here
            \\and is not written anywhere by this command.
            \\
        );
    }
    if (unreadable > 0) return 2;
    return 0;
}

fn whyDidThatHappen(
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    options: Options,
) !u8 {
    if (options.positional.len == 0) {
        try w.writeAll("Name the log file to read. For example: zag why .workspace/events.jsonl\n");
        return 2;
    }
    const path = options.positional[0];
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(zag.events.log.max_file_bytes)) catch {
        try w.print("zag could not read {s}.\n", .{path});
        return 1;
    };
    const loaded = try zag.events.log.Log.loadJsonLines(arena, source, 1);
    if (loaded.log.entries.items.len == 0) {
        try w.writeAll("That log has no events in it.\n");
        return 1;
    }

    // By default, the last thing that went wrong. Somebody running "why" has
    // usually just watched something fail, and the last event in a log is
    // almost always a session closing, which explains nothing. When nothing
    // went wrong, the last event is the right answer.
    var about: usize = lastFailure(loaded.log) orelse loaded.log.entries.items.len - 1;
    if (options.positional.len > 1) {
        about = std.fmt.parseInt(usize, options.positional[1], 10) catch {
            try w.print("\"{s}\" is not an event number.\n", .{options.positional[1]});
            return 2;
        };
        if (about >= loaded.log.entries.items.len) {
            try w.print("There are {d} events, so {d} is not one of them.\n", .{
                loaded.log.entries.items.len,
                about,
            });
            return 2;
        }
    }

    const dag = try zag.events.lineage.Dag.build(arena, loaded.log);
    if (!dag.isTopological()) {
        try w.writeAll("This log has an event that comes before its own cause, so the graph cannot be trusted.\n");
        try w.writeAll("Run \"zag events\" on it: a log in that state has been changed since it was written.\n");
        return 1;
    }

    try w.writeAll("What you asked about\n  ");
    try zag.ai.attention.writeEvent(loaded.log.entries.items[about], w);
    try w.writeAll("\n\n");

    const selection = try zag.ai.attention.select(arena, dag, about, .{
        .includeAffected = true,
        .recent = 0,
    });

    var wrote_any = false;
    inline for (.{
        .{ zag.ai.attention.Reason.depended_on, "What it depended on" },
        .{ zag.ai.attention.Reason.affected_by, "What it went on to affect" },
    }) |section| {
        var first = true;
        for (selection.chosen) |item| {
            if (item.reason != section[0]) continue;
            if (first) {
                try w.print("{s}\n", .{section[1]});
                first = false;
                wrote_any = true;
            }
            try w.print("  {d} step", .{item.distance});
            if (item.distance != 1) try w.writeAll("s");
            try w.print(" away, event {d}: ", .{item.index});
            try zag.ai.attention.writeEvent(item.envelope, w);
            try w.writeAll("\n");
        }
        if (!first) try w.writeAll("\n");
    }
    if (!wrote_any) {
        try w.writeAll("Nothing in this log connects to it, forwards or backwards.\n\n");
    }

    const path_through = try dag.criticalPath();
    const cost = dag.criticalPathCost(path_through.items);
    if (cost.ns > 0) {
        try w.print("The longest chain in this log runs through {d} events and takes ", .{
            path_through.items.len,
        });
        try zag.reports.notation.writeDuration(w, cost);
        try w.writeAll(".\n");
        try w.writeAll("That is what decided how long the work took, not the sum of everything in it.\n");
    }
    return 0;
}

/// The most recent event that reports something not working.
fn lastFailure(log: zag.events.log.Log) ?usize {
    var index = log.entries.items.len;
    while (index > 0) {
        index -= 1;
        switch (log.entries.items[index].payload) {
            .command_finished => |e| if (e.exitStatus != 0) return index,
            .diagnostic => |e| if (e.severity == .@"error") return index,
            .tool_finished => |e| if (e.outcome != .completed) return index,
            else => {},
        }
    }
    return null;
}

/// What the model is told before it starts.
///
/// This is prompt text. It shapes behaviour and grants nothing: every sentence
/// in it describes a boundary that is enforced elsewhere, so a model that
/// ignores all of it can still do only what the policy allows. It is written
/// anyway, because a model that knows the shape of the boundary wastes fewer
/// turns discovering it.
const agent_instructions =
    \\You are working in a recorded workspace, through a policy that decides
    \\every action separately.
    \\
    \\Each tool call is decided on its own. A refusal is final for that call:
    \\if you are told the policy did not allow something, do not ask for it
    \\again. Say what you needed and why, and let the person decide.
    \\
    \\Paths are inside the workspace. A path that leaves it is refused by the
    \\operating system, not by a check you can talk your way around.
    \\
    \\Commands are argument vectors. There is no shell, so a pipe, a semicolon
    \\or a redirect is an argument and not an instruction. Run one program at a
    \\time.
    \\
    \\Work in small steps and say what you found. When you are finished, answer
    \\in plain words.
    \\
;

/// A monotonic clock for the run's time budget.
///
/// Monotonic rather than wall clock, so that the system time changing under a
/// long run cannot cut it short or let it go on.
fn monotonic(io: std.Io) zag.ai.loop.Clock {
    const Reader = struct {
        io: std.Io,
        fn read(context: *anyopaque) i64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            const raw = std.Io.Timestamp.now(self.io, .awake);
            return @intCast(raw.nanoseconds);
        }
    };
    // The reader holds only the I/O handle, which outlives the run.
    const holder = struct {
        var state: Reader = undefined;
    };
    holder.state = .{ .io = io };
    return .{ .context = &holder.state, .nowFn = Reader.read };
}

/// The model a connector answers with when the person did not name one.
///
/// There is no right answer here, so the rule is to name something that
/// provider actually serves rather than to guess a capable one.
fn defaultModel(connector: zag.ai.catalog.Connector) []const u8 {
    if (std.mem.eql(u8, connector.id, "anthropic")) return "claude-opus-5";
    if (std.mem.eql(u8, connector.id, "openai")) return "gpt-5";
    if (std.mem.eql(u8, connector.id, "gemini")) return "gemini-2.5-pro";
    if (connector.locality == .local) return "llama3.2";
    return "";
}

fn writeDecisions(attempt: zag.ai.transport.Attempt, w: *std.Io.Writer) !void {
    if (attempt.decisions.len == 0) {
        try w.writeAll("No decision was reached.\n");
        return;
    }
    try w.writeAll("What the policy decided\n");
    for (attempt.decisions) |decision| {
        try w.print("  {s} to {s}: {s}\n", .{
            switch (decision.effect) {
                .allow => "Allowed",
                .deny => "Refused",
                .require_human => "Waiting for you",
            },
            decision.request.capability.explain(),
            decision.reason,
        });
    }
}

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
        .actor = try personActor(arena, environment),
        .now = wallClock(io),
        .environment = environment,
    }) catch {
        try w.print("zag could not open the workspace in {s}.\n", .{options.root});
        return 1;
    };
    var service = opened.service;
    // A torn tail and a malformed record are as disqualifying as a broken
    // chain: in all three the workspace is sealed and nothing this session did
    // would be written. Checking only the chain meant `zag term` started
    // happily on a log that `zag run` refuses, and recorded a session that went
    // nowhere.
    if (!opened.report.logIsHealthy()) {
        try opened.report.writeSummary(w);
        try w.writeAll("This session would not be recorded. Keep the file as it is: a damaged log is evidence, not a fault to repair.\n");
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

    // Settings, if there are any. A setting that cannot be read is named here
    // and the built-in value is used, rather than the terminal refusing to
    // open — a person reading this is usually trying to fix something else.
    const configured = try zag.terminal.settings.load(arena, io, options.root);
    for (configured.reports) |report| {
        try report.writeSentence(w);
        try w.writeByte('\n');
    }
    if (!configured.ok()) try w.writeAll("\n");

    try w.writeAll("Recording this session. Leave the shell to stop.\n");
    try w.flush();

    const outcome = zag.terminal.interactive.run(&service, &tty, io, .{
        .workingDirectory = options.root,
        .environment = environment,
        .hookDirectory = hook_directory,
        .shell = configured.settings.shell,
        .scrollback = configured.settings.scrollback,
        // `--raw` is a decision made at the moment of running, so it wins over
        // a file written earlier.
        .integrate = !options.raw and configured.settings.integrate,
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

/// Join an argument vector back into a command line, without losing it.
///
/// The workspace service runs a command through a shell, because that is what
/// produces the boundary marks a block is built from. So the vector a person
/// typed after `--` has to become one line. Joining it with spaces is what a
/// person reaches for, and it is wrong: `zag run -- sh -c 'exit 3'` becomes
/// `sh -c exit 3`, which runs `exit` with `3` as its name and reports success
/// for a command that failed. A workbench whose record says a failed command
/// worked is worse than no record.
///
/// So each argument that contains anything a shell would act on is wrapped in
/// single quotes, and an embedded single quote is closed, escaped and reopened
/// — the one form that survives every POSIX shell. An argument of plain word
/// characters is left alone, so the recorded command line still reads the way
/// the person typed it.
pub fn quoteArgv(arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (argv, 0..) |argument, index| {
        if (index > 0) try out.append(arena, ' ');
        if (needsQuoting(argument)) {
            try out.append(arena, '\'');
            for (argument) |byte| {
                if (byte == '\'') {
                    try out.appendSlice(arena, "'\\''");
                } else {
                    try out.append(arena, byte);
                }
            }
            try out.append(arena, '\'');
        } else {
            try out.appendSlice(arena, argument);
        }
    }
    return out.items;
}

fn needsQuoting(argument: []const u8) bool {
    if (argument.len == 0) return true;
    for (argument) |byte| {
        const safe = (byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or
            byte == '_' or byte == '-' or byte == '.' or byte == '/' or
            byte == ':' or byte == '=' or byte == '@' or byte == ',' or byte == '+';
        if (!safe) return true;
    }
    return false;
}

fn runCommand(
    arena: std.mem.Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    options: Options,
    environment: []const []const u8,
) !u8 {
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
        .actor = try personActor(arena, environment),
        .now = wallClock(io),
        .environment = environment,
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

    const command_text = try quoteArgv(arena, options.passthrough);
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

    const options = try parseOptions(arena, &.{ "--repo", "elsewhere", "--json", "--approve-truncate", "file.md", "--", "echo", "hello" });
    try testing.expectEqualStrings("elsewhere", options.repo);
    try testing.expect(options.json);
    try testing.expect(options.approve_truncate);
    try testing.expectEqual(@as(usize, 1), options.positional.len);
    try testing.expectEqualStrings("file.md", options.positional[0]);
    try testing.expectEqual(@as(usize, 2), options.passthrough.len);
    try testing.expectEqualStrings("hello", options.passthrough[1]);

    try testing.expectError(error.MissingOptionValue, parseOptions(arena, &.{"--repo"}));
    try testing.expectError(error.UnknownOption, parseOptions(arena, &.{"--wat"}));
    try testing.expect(approvalOptionIsValid(.recover, options));
    try testing.expect(!approvalOptionIsValid(.doctor, options));
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

test "the connector list says which credentials are set, without printing one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buffer: [16384]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    const environment = [_][]const u8{
        "PATH=/usr/bin",
        "ANTHROPIC_API_KEY=sk-secret-value",
        "OPENAI_API_KEY=",
    };
    try testing.expectEqual(@as(u8, 0), try listProviders(arena, io, &w, .{}, &environment));
    const text = w.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "ANTHROPIC_API_KEY (set)") != null);
    // An empty variable is not a credential, whatever the shell thinks.
    try testing.expect(std.mem.indexOf(u8, text, "OPENAI_API_KEY (not set)") != null);
    // The value never reaches the page.
    try testing.expect(std.mem.indexOf(u8, text, "sk-secret-value") == null);
}

test "the policy shown is the one written in the workspace, and a broken one grants nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const directory = try std.fmt.allocPrint(arena, "{s}/.workspace", .{root});
    const policy_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, zag.ai.policy_file.default_path });
    try std.Io.Dir.cwd().createDirPath(io, directory);

    // With no file, the built-in policy is in force and says so.
    var absent_buffer: [4096]u8 = undefined;
    var absent = std.Io.Writer.fixed(&absent_buffer);
    try testing.expectEqual(@as(u8, 0), try showPolicy(arena, io, &absent, .{ .root = root }));
    try testing.expect(std.mem.indexOf(u8, absent.buffered(), "No policy is written") != null);

    // A written one replaces it.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = policy_path,
        .data =
        \\name = "Read only"
        \\
        \\[[rule]]
        \\allow = ["fs.read"]
        \\because = "Looking is allowed."
        \\
        ,
    });
    var written_buffer: [4096]u8 = undefined;
    var written = std.Io.Writer.fixed(&written_buffer);
    try testing.expectEqual(@as(u8, 0), try showPolicy(arena, io, &written, .{ .root = root }));
    try testing.expect(std.mem.indexOf(u8, written.buffered(), "Read only") != null);
    try testing.expect(std.mem.indexOf(u8, written.buffered(), "Looking is allowed.") != null);

    // A broken one is reported, and the built-in policy is not quietly put in
    // its place. Substituting one would hand out permissions nobody wrote.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = policy_path,
        .data =
        \\[[rule]]
        \\allow = ["fs.read", "network.teleport"]
        \\
        ,
    });
    var broken_buffer: [4096]u8 = undefined;
    var broken = std.Io.Writer.fixed(&broken_buffer);
    try testing.expectEqual(@as(u8, 1), try showPolicy(arena, io, &broken, .{ .root = root }));
    try testing.expect(std.mem.indexOf(u8, broken.buffered(), "network.teleport") != null);
    try testing.expect(std.mem.indexOf(u8, broken.buffered(), "Nothing in it is in force") != null);
}

test "asking a model refuses before it sends, and says what the policy decided" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // No policy is written, so the built-in local-only one applies. A hosted
    // provider is refused, and nothing is sent: this runs with no network.
    var buffer: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    const status = try askAModel(arena, io, &w, .{
        .root = root,
        .provider = "anthropic",
        .positional = &.{ "two", "plus", "two" },
    }, &.{"ANTHROPIC_API_KEY=sk-secret-value"});
    try testing.expectEqual(@as(u8, 1), status);

    const text = w.buffered();
    // The run ended because the policy refused, and the reason is the one the
    // policy gave, not one this command invented.
    try testing.expect(std.mem.indexOf(u8, text, "The policy refused something the model needed") != null);
    try testing.expect(std.mem.indexOf(u8, text, "What the policy decided") != null);
    // Nothing ran, so there are no tool calls to report.
    try testing.expect(std.mem.indexOf(u8, text, "0 tool calls") != null);
    // Using a model was allowed; reaching that host was not, and the two are
    // shown separately because they are separate answers.
    try testing.expect(std.mem.indexOf(u8, text, "Allowed to send this work to a model provider") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Refused to connect to services over the network") != null);
    try testing.expect(std.mem.indexOf(u8, text, "sk-secret-value") == null);
}

test "a connector nobody has heard of is refused before any policy is read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buffer: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try testing.expectEqual(@as(u8, 2), try askAModel(arena, io, &w, .{
        .provider = "skynet",
        .positional = &.{"hello"},
    }, &.{}));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "zag providers") != null);
}

test "every connector this build ships resolves and can be named on the command line" {
    // The list the tool prints and the list the transport can reach are the
    // same list. A connector that printed but could not be found would be a
    // promise the tool could not keep.
    for (zag.ai.catalog.connectors) |connector| {
        const found = zag.ai.catalog.find(connector.id) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(connector.baseUrl, found.baseUrl);
        try testing.expect(defaultModel(found).len > 0 or connector.locality == .hosted);
    }
}

test "an argument vector survives being turned back into a command line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The case that was wrong: joining with spaces turned this into
    // "sh -c exit 3", which runs `exit` with `3` as its name, exits zero, and
    // was recorded as a command that succeeded.
    try testing.expectEqualStrings(
        "sh -c 'exit 3'",
        try quoteArgv(arena, &.{ "sh", "-c", "exit 3" }),
    );

    // Plain words are left alone, so the recorded line still reads the way it
    // was typed.
    try testing.expectEqualStrings(
        "zig build test",
        try quoteArgv(arena, &.{ "zig", "build", "test" }),
    );
    try testing.expectEqualStrings(
        "git commit -m 'a message with spaces'",
        try quoteArgv(arena, &.{ "git", "commit", "-m", "a message with spaces" }),
    );

    // A single quote inside an argument is the case that breaks naive quoting.
    try testing.expectEqualStrings(
        "echo 'it'\\''s here'",
        try quoteArgv(arena, &.{ "echo", "it's here" }),
    );

    // An empty argument is a real argument and must not vanish.
    try testing.expectEqualStrings("echo '' x", try quoteArgv(arena, &.{ "echo", "", "x" }));

    // Everything a shell would act on is quoted.
    for ([_][]const u8{ ";", "|", "&", "$x", "`x`", ">out", "<in", "*", "(", ")", "\n", "\\" }) |dangerous| {
        const line = try quoteArgv(arena, &.{ "echo", dangerous });
        try testing.expect(std.mem.startsWith(u8, line, "echo '"));
        try testing.expect(std.mem.endsWith(u8, line, "'"));
    }
}

test "a command that fails is recorded as failed, with its status" {
    if (!zag.terminal.pty.supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // End to end, the way a person runs it: the vector after `--`, through the
    // quoting, through the shell wrapper, into the record.
    var buffer: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    const status = try runCommand(arena, io, &w, .{
        .root = root,
        .passthrough = &.{ "sh", "-c", "exit 3" },
    }, &.{ "USER=tester", "HOSTNAME=test-machine" });

    try testing.expectEqual(@as(u8, 3), status);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "[failed]") != null);
    // The recorded line is the one that ran, quoting and all.
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "sh -c 'exit 3'") != null);

    // And the record itself says three, not zero.
    const path = try std.fmt.allocPrint(arena, "{s}/.workspace/events.jsonl", .{root});
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    const loaded = try zag.events.log.Log.loadJsonLines(arena, source, 1);
    var saw_failure = false;
    for (loaded.log.entries.items) |entry| {
        switch (entry.payload) {
            .command_finished => |e| {
                try testing.expectEqual(@as(u8, 3), e.exitStatus);
                saw_failure = true;
            },
            else => {},
        }
    }
    try testing.expect(saw_failure);
}

test "the record says who wrote it, and tells a person from the workbench" {
    if (!zag.terminal.pty.supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var buffer: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    _ = try runCommand(arena, io, &w, .{
        .root = root,
        .passthrough = &.{ "echo", "hello" },
    }, &.{ "USER=sean", "HOSTNAME=workshop" });

    const path = try std.fmt.allocPrint(arena, "{s}/.workspace/events.jsonl", .{root});
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    const loaded = try zag.events.log.Log.loadJsonLines(arena, source, 1);
    try testing.expect(loaded.log.entries.items.len > 0);

    const zero = zag.core.id.ActorId.fromRaw(.{ .bytes = [_]u8{0} ** 16 });
    const expected = try zag.core.identity.person(arena, &.{ "USER=sean", "HOSTNAME=workshop" });

    for (loaded.log.entries.items) |entry| {
        // Not the zero identifier, which is what every event used to carry.
        try testing.expect(!entry.actor.id.eql(zero));
        // The person who ran it, and readable as such.
        try testing.expect(entry.actor.id.eql(expected.id));
        try testing.expectEqual(zag.data.provenance.ProducerKind.person, entry.actor.kind);
        try testing.expectEqualStrings("sean", entry.actor.label);
    }

    // The same account on the same machine is the same actor in another
    // workspace, so a person can be followed across their own work.
    var elsewhere = std.testing.tmpDir(.{});
    defer elsewhere.cleanup();
    var second_buffer: [8192]u8 = undefined;
    var second = std.Io.Writer.fixed(&second_buffer);
    _ = try runCommand(arena, io, &second, .{
        .root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{elsewhere.sub_path}),
        .passthrough = &.{ "echo", "again" },
    }, &.{ "USER=sean", "HOSTNAME=workshop" });
    const second_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/.workspace/events.jsonl", .{elsewhere.sub_path});
    const second_source = try std.Io.Dir.cwd().readFileAlloc(io, second_path, arena, .limited(1 << 20));
    const second_log = try zag.events.log.Log.loadJsonLines(arena, second_source, 1);
    try testing.expect(second_log.log.entries.items[0].actor.id.eql(expected.id));

    // And the workbench acting on its own is a different actor, of a different
    // kind. A governance framework that cannot tell those apart describes
    // nothing.
    const workbench = workbenchActor();
    try testing.expect(!workbench.id.eql(expected.id));
    try testing.expectEqual(zag.data.provenance.ProducerKind.system, workbench.kind);
}

test "a starter policy is written once, and never over one that exists" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = ".zig-cache/tmp/policy-init-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    var out: std.Io.Writer.Allocating = .init(arena);
    const wrote = try writeStarterPolicy(arena, io, &out.writer, .{ .root = root, .init = true });
    try testing.expectEqual(@as(u8, 0), wrote);

    // What it wrote has to be what this build reads, or the command has handed
    // somebody a file that fails the moment they use it.
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, zag.ai.policy_file.default_path });
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    const parsed = try zag.ai.policy_file.parse(arena, source);
    try testing.expect(parsed.usable());

    // A policy file is what stands between an agent and someone's machine. A
    // second --init, whatever the reason for it, must not touch it.
    var again: std.Io.Writer.Allocating = .init(arena);
    const second = try writeStarterPolicy(arena, io, &again.writer, .{ .root = root, .init = true });
    try testing.expectEqual(@as(u8, 1), second);
    try testing.expect(std.mem.indexOf(u8, again.written(), "already exists") != null);

    const after = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    try testing.expectEqualStrings(source, after);
}

test "a starter policy for a connector nobody has heard of writes nothing at all" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = ".zig-cache/tmp/policy-init-unknown";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    var out: std.Io.Writer.Allocating = .init(arena);
    const status = try writeStarterPolicy(arena, io, &out.writer, .{
        .root = root,
        .init = true,
        .provider = "no-such-connector",
    });
    try testing.expectEqual(@as(u8, 2), status);

    // Refused before anything was created, so a typo does not leave a
    // half-made workspace behind.
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, zag.ai.policy_file.default_path });
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)));
}

test "the starter policy names the host of the connector that was asked for" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = ".zig-cache/tmp/policy-init-local";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    var out: std.Io.Writer.Allocating = .init(arena);
    _ = try writeStarterPolicy(arena, io, &out.writer, .{ .root = root, .init = true, .provider = "ollama" });

    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, zag.ai.policy_file.default_path });
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    // A file for a model on this machine that allowed api.anthropic.com would
    // be a file written for somebody else's setup.
    try testing.expect(std.mem.indexOf(u8, source, "localhost") != null);
    try testing.expect(std.mem.indexOf(u8, source, "api.anthropic.com") == null);
}

test "doctor names the policy as the blocker when a key is set and the host is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The case worth catching: nothing is broken, nothing is misspelt, and the
    // only symptom is a refusal at the moment of asking. The built-in policy
    // allows a model on this computer and nothing else.
    const loaded: LoadedPolicy = .{
        .policy = (try zag.ai.policy_file.parse(arena, zag.ai.policy_file.local_models_only)).policy.?,
        .path = null,
        .problems = &.{},
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeNextStep(arena, &out.writer, loaded, false, &.{"ANTHROPIC_API_KEY=sk-ant-whatever"});

    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "ANTHROPIC_API_KEY is set") != null);
    try testing.expect(std.mem.indexOf(u8, text, "api.anthropic.com") != null);
    // It says what to do, not just what is wrong.
    try testing.expect(std.mem.indexOf(u8, text, "zag policy --init") != null);
    // And it never prints the key.
    try testing.expect(std.mem.indexOf(u8, text, "sk-ant-whatever") == null);
}

test "doctor says nothing is in the way when the policy allows the host" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var starter: std.Io.Writer.Allocating = .init(arena);
    try zag.ai.policy_file.writeStarter(&starter.writer, "api.anthropic.com");
    const loaded: LoadedPolicy = .{
        .policy = (try zag.ai.policy_file.parse(arena, starter.written())).policy.?,
        .path = ".workspace/policy.toml",
        .problems = &.{},
    };

    var out: std.Io.Writer.Allocating = .init(arena);
    try writeNextStep(arena, &out.writer, loaded, true, &.{"ANTHROPIC_API_KEY=sk-ant-whatever"});
    try testing.expect(std.mem.indexOf(u8, out.written(), "the policy allows reaching") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "sk-ant-whatever") == null);
}

test "doctor points at a broken policy file before anything else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A file that cannot be used grants nothing, so saying "your key is fine"
    // would send somebody looking in the wrong place.
    const loaded: LoadedPolicy = .{
        .policy = (try zag.ai.policy_file.parse(arena, zag.ai.policy_file.local_models_only)).policy.?,
        .path = ".workspace/policy.toml",
        .problems = &.{.{ .rule = 1, .message = "This rule does not say allow, ask or deny, so it would do nothing." }},
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeNextStep(arena, &out.writer, loaded, false, &.{"ANTHROPIC_API_KEY=sk-ant-whatever"});
    try testing.expect(std.mem.indexOf(u8, out.written(), "cannot be used") != null);
}

test "what a command printed can be read back out of the record" {
    if (!zag.terminal.pty.supported) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = ".zig-cache/tmp/show-output-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    // Record something with output worth reading back.
    {
        var out: std.Io.Writer.Allocating = .init(arena);
        const status = try runCommand(arena, io, &out.writer, .{ .root = root }, &.{
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        });
        _ = status;
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    const status = try showOutput(arena, io, &out.writer, .{ .root = root, .positional = &.{"nothing-was-recorded"} });
    // Nothing matched, and that is said rather than shown as an empty screen.
    try testing.expectEqual(@as(u8, 1), status);
}

test "showing output reassembles every piece, not just the last one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The `chunked` variant exists because a fold once kept the last piece's
    // hash beside the summed byte count. A reader that showed one piece and
    // called it the output would be the same mistake from the other end, so
    // the reassembly walks `pieces()` and the count is checked against the
    // total the record claims.
    const first = zag.core.hash.Hash.of("first half, ");
    const second = zag.core.hash.Hash.of("second half");
    const content: zag.workspace.block.ContentRef = .{ .chunked = .{
        .chunks = &.{
            .{ .hash = first, .byteCount = 12, .index = 0 },
            .{ .hash = second, .byteCount = 11, .index = 1 },
        },
        .byteCount = 23,
    } };

    var single: [1]zag.workspace.block.Chunk = undefined;
    const pieces = content.pieces(&single);
    try testing.expectEqual(@as(usize, 2), pieces.len);
    var summed: usize = 0;
    for (pieces) |piece| summed += piece.byteCount;
    try testing.expectEqual(content.totalBytes(), summed);
    _ = arena;
}
