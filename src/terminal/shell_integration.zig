//! Shell integration: knowing where a command starts and ends.
//!
//! The workbench does not replace the user's shell. It asks the shell to emit
//! small OSC markers around the prompt and the command, which is the
//! compatibility boundary that lets bash, zsh, fish and PowerShell all work
//! unchanged. Everything the block model needs — command boundaries, the
//! command text, the working directory, the exit status — arrives through the
//! existing pseudoterminal channel.
//!
//! Two sequence families are understood:
//!   * OSC 133 (`FinalTerm`), the de facto standard for semantic prompts.
//!   * OSC 7, the working-directory URL.
//! Anything else is passed through untouched.

const std = @import("std");

pub const Boundary = union(enum) {
    /// The shell is about to draw a prompt.
    prompt_start,
    /// The prompt has been drawn; what follows is what the person types.
    command_start,
    /// The command has been submitted; what follows is its output.
    output_start: struct { command: ?[]const u8 },
    /// The command finished.
    command_finished: struct { exit_status: ?u8 },
    /// The working directory changed.
    directory_changed: []const u8,
    /// A marker we understand the shape of but not the meaning.
    unknown: []const u8,
};

pub const Parser = struct {
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) Parser {
        return .{ .arena = arena };
    }

    /// Interpret one OSC string, as delivered by the terminal parser.
    pub fn parse(self: Parser, raw: []const u8) !?Boundary {
        const semi = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
        const command_text = raw[0..semi];
        const rest = if (semi < raw.len) raw[semi + 1 ..] else "";

        if (std.mem.eql(u8, command_text, "133")) return try self.parseFinalTerm(rest);
        if (std.mem.eql(u8, command_text, "7")) return .{ .directory_changed = try self.parseFileUrl(rest) };
        // Some shells ship the same marks under OSC 633; treat them alike.
        if (std.mem.eql(u8, command_text, "633")) return try self.parseFinalTerm(rest);
        return null;
    }

    fn parseFinalTerm(self: Parser, rest: []const u8) !?Boundary {
        if (rest.len == 0) return null;
        const kind = rest[0];
        var fields = std.mem.splitScalar(u8, rest, ';');
        _ = fields.next();

        return switch (kind) {
            'A' => .prompt_start,
            'B' => .command_start,
            'C' => blk: {
                var command: ?[]const u8 = null;
                // The hooks put cmdline last. Taking the remainder preserves a
                // real shell semicolon instead of mistaking it for another
                // metadata field. Percent encoding still handles controls.
                if (std.mem.indexOf(u8, rest, ";cmdline=")) |start| {
                    command = try self.decode(rest[start + ";cmdline=".len ..]);
                }
                break :blk .{ .output_start = .{ .command = command } };
            },
            'D' => blk: {
                var status: ?u8 = null;
                if (fields.next()) |field| {
                    status = std.fmt.parseInt(u8, std.mem.trim(u8, field, " "), 10) catch null;
                }
                break :blk .{ .command_finished = .{ .exit_status = status } };
            },
            'E' => blk: {
                // OSC 133;E reports the command line before it runs.
                var command: ?[]const u8 = null;
                if (std.mem.indexOf(u8, rest, ";cmdline=")) |start| {
                    command = try self.decode(rest[start + ";cmdline=".len ..]);
                }
                break :blk .{ .output_start = .{ .command = command } };
            },
            'P' => .{ .unknown = try self.arena.dupe(u8, rest) },
            else => .{ .unknown = try self.arena.dupe(u8, rest) },
        };
    }

    /// `file://host/path` or a bare path.
    fn parseFileUrl(self: Parser, url: []const u8) ![]const u8 {
        if (!std.mem.startsWith(u8, url, "file://")) return self.decode(url);
        const after_scheme = url["file://".len..];
        const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return self.decode(after_scheme);
        return self.decode(after_scheme[slash..]);
    }

    /// Percent-decoding, because paths arrive URL-encoded.
    fn decode(self: Parser, text: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '%' and i + 2 < text.len) {
                const value = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch {
                    try out.append(self.arena, text[i]);
                    continue;
                };
                try out.append(self.arena, value);
                i += 2;
                continue;
            }
            try out.append(self.arena, text[i]);
        }
        return out.toOwnedSlice(self.arena);
    }
};

/// Tracks where the shell is, so the block engine can open and close blocks.
pub const State = enum {
    /// Before anything is known.
    unknown,
    /// A prompt is on screen and the person is typing.
    at_prompt,
    /// A command is running.
    running,
    /// A command finished and the next prompt has not started.
    finished,
};

pub const Tracker = struct {
    parser: Parser,
    /// When set, command boundaries are accepted only when their token field
    /// matches. This keeps child output from impersonating a service-owned
    /// shell wrapper.
    expected_token: ?[]const u8 = null,
    state: State = .unknown,
    working_directory: ?[]const u8 = null,
    current_command: ?[]const u8 = null,
    last_exit_status: ?u8 = null,
    /// True once any OSC 133 mark has been seen. Until then, block boundaries
    /// are inferred and every metric derived from them says so.
    integrated: bool = false,

    pub fn init(arena: std.mem.Allocator) Tracker {
        return .{ .parser = Parser.init(arena) };
    }

    pub fn initAuthenticated(arena: std.mem.Allocator, token: []const u8) Tracker {
        return .{ .parser = Parser.init(arena), .expected_token = token };
    }

    pub fn consume(self: *Tracker, raw: []const u8) !?Boundary {
        const boundary = (try self.parser.parse(raw)) orelse return null;
        if (self.expected_token) |token| {
            const needs_token = switch (boundary) {
                .output_start, .command_finished => true,
                else => false,
            };
            if (needs_token and !hasField(raw, "token", token)) return null;
        }
        switch (boundary) {
            .prompt_start => {
                self.integrated = true;
                self.state = .at_prompt;
                self.current_command = null;
            },
            .command_start => {
                self.integrated = true;
                self.state = .at_prompt;
            },
            .output_start => |o| {
                self.integrated = true;
                self.state = .running;
                if (o.command) |c| self.current_command = c;
            },
            .command_finished => |f| {
                self.integrated = true;
                self.state = .finished;
                self.last_exit_status = f.exit_status;
            },
            .directory_changed => |path| self.working_directory = path,
            .unknown => {},
        }
        return boundary;
    }
};

fn hasField(raw: []const u8, name: []const u8, expected: []const u8) bool {
    var fields = std.mem.splitScalar(u8, raw, ';');
    while (fields.next()) |field| {
        const equal = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (!std.mem.eql(u8, field[0..equal], name)) continue;
        return std.mem.eql(u8, field[equal + 1 ..], expected);
    }
    return false;
}

/// Hook scripts. They are deliberately small: they emit markers and nothing
/// else, so that a person can read the whole thing before letting it run in
/// their shell.
pub const hooks = struct {
    pub const bash =
        \\# zag shell integration for bash.
        \\# It reports where prompts and commands start and end. It changes
        \\# nothing else about your shell.
        \\#
        \\# PS0 is expanded once, after bash has read a command line and before
        \\# it runs it. That is exactly one mark for one command. The DEBUG trap
        \\# is not used: it fires before every simple command, including the
        \\# ones inside the prompt's own functions, which produces marks for
        \\# commands nobody typed.
        \\__zag_prompt_start() { printf '\033]133;A\007'; }
        \\__zag_command_start() { printf '\033]133;B\007'; }
        \\__zag_report_cwd() { printf '\033]7;file://%s%s\007' "${HOSTNAME:-}" "$PWD"; }
        \\__zag_preexec() {
        \\  local number rest
        \\  read -r number rest <<< "$(HISTTIMEFORMAT= history 1)"
        \\  if [ -n "${__zag_token:-}" ]; then
        \\    printf '\033]133;C;token=%s;cmdline=%s\007' "$__zag_token" "$rest"
        \\  else
        \\    printf '\033]133;C;cmdline=%s\007' "$rest"
        \\  fi
        \\}
        \\__zag_precmd() {
        \\  local status=$?
        \\  if [ -n "${__zag_token:-}" ]; then
        \\    printf '\033]133;D;%s;token=%s\007' "$status" "$__zag_token"
        \\  else
        \\    printf '\033]133;D;%s\007' "$status"
        \\  fi
        \\  __zag_report_cwd
        \\  __zag_prompt_start
        \\}
        \\PROMPT_COMMAND="__zag_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
        \\PS0='$(__zag_preexec)'"${PS0:-}"
        \\PS1="\[$(__zag_command_start)\]$PS1"
    ;

    pub const zsh =
        \\# zag shell integration for zsh.
        \\__zag_precmd() {
        \\  local status=$?
        \\  if [ -n "${__zag_token:-}" ]; then
        \\    printf '\033]133;D;%s;token=%s\007' "$status" "$__zag_token"
        \\  else
        \\    printf '\033]133;D;%s\007' "$status"
        \\  fi
        \\  printf '\033]7;file://%s%s\007' "${HOST:-}" "$PWD"
        \\  printf '\033]133;A\007'
        \\}
        \\__zag_preexec() {
        \\  if [ -n "${__zag_token:-}" ]; then
        \\    printf '\033]133;C;token=%s;cmdline=%s\007' "$__zag_token" "$1"
        \\  else
        \\    printf '\033]133;C;cmdline=%s\007' "$1"
        \\  fi
        \\}
        \\autoload -Uz add-zsh-hook
        \\add-zsh-hook precmd __zag_precmd
        \\add-zsh-hook preexec __zag_preexec
        \\PS1="%{$(printf '\033]133;B\007')%}$PS1"
    ;

    pub const fish =
        \\# zag shell integration for fish.
        \\function __zag_prompt --on-event fish_prompt
        \\    printf '\033]133;D;%s\007' $status
        \\    printf '\033]7;file://%s%s\007' (hostname) $PWD
        \\    printf '\033]133;A\007'
        \\end
        \\function __zag_preexec --on-event fish_preexec
        \\    printf '\033]133;C;cmdline=%s\007' $argv[1]
        \\end
    ;

    pub const powershell =
        \\# zag shell integration for PowerShell.
        \\function Global:__Zag-Prompt {
        \\  $status = if ($?) { 0 } else { 1 }
        \\  Write-Host -NoNewline "$([char]27)]133;D;$status$([char]7)"
        \\  Write-Host -NoNewline "$([char]27)]7;file://$env:COMPUTERNAME$($PWD.Path)$([char]7)"
        \\  Write-Host -NoNewline "$([char]27)]133;A$([char]7)"
        \\}
    ;

    pub fn forShell(name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "bash")) return bash;
        if (std.mem.eql(u8, name, "zsh")) return zsh;
        if (std.mem.eql(u8, name, "fish")) return fish;
        if (std.mem.eql(u8, name, "powershell") or std.mem.eql(u8, name, "pwsh")) return powershell;
        return null;
    }
};

/// Programs that take over the whole screen. While one of these runs, the
/// session switches to a plain terminal surface and stops trying to find block
/// boundaries, because there are none to find.
pub const full_screen_programs = [_][]const u8{
    "vim", "nvim", "vi",  "emacs",   "nano",  "htop", "top",   "less",
    "man", "tmux", "ssh", "lazygit", "gitui", "btop", "watch", "screen",
};

pub fn isFullScreenProgram(command: []const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t");
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = it.next() orelse return false;
    const base = if (std.mem.lastIndexOfScalar(u8, first, '/')) |slash| first[slash + 1 ..] else first;
    for (full_screen_programs) |program| {
        if (std.mem.eql(u8, base, program)) return true;
    }
    return false;
}

const testing = std.testing;

test "final term marks drive the block boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tracker = Tracker.init(arena);
    try testing.expect(!tracker.integrated);

    _ = try tracker.consume("133;A");
    try testing.expectEqual(State.at_prompt, tracker.state);
    try testing.expect(tracker.integrated);

    _ = try tracker.consume("133;B");
    const started = (try tracker.consume("133;C;cmdline=zig build test")).?;
    try testing.expectEqualStrings("zig build test", started.output_start.command.?);
    try testing.expectEqual(State.running, tracker.state);

    const finished = (try tracker.consume("133;D;1")).?;
    try testing.expectEqual(@as(u8, 1), finished.command_finished.exit_status.?);
    try testing.expectEqual(State.finished, tracker.state);
    try testing.expectEqual(@as(u8, 1), tracker.last_exit_status.?);

    const compound = (try tracker.consume("133;C;cmdline=printf one; printf two")).?;
    try testing.expectEqualStrings("printf one; printf two", compound.output_start.command.?);
}

test "the working directory arrives as a file url" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tracker = Tracker.init(arena);
    _ = try tracker.consume("7;file://workstation/home/user/my%20projects/zag");
    try testing.expectEqualStrings("/home/user/my projects/zag", tracker.working_directory.?);

    _ = try tracker.consume("7;file:///tmp");
    try testing.expectEqualStrings("/tmp", tracker.working_directory.?);
}

test "an authenticated tracker rejects forged command marks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var tracker = Tracker.initAuthenticated(arena_state.allocator(), "secret-token");
    try testing.expect((try tracker.consume("133;C;cmdline=forged")) == null);
    try testing.expect((try tracker.consume("133;D;0;token=wrong")) == null);

    const start = (try tracker.consume("133;C;token=secret-token;cmdline=printf one%3B printf two")).?;
    try testing.expectEqualStrings("printf one; printf two", start.output_start.command.?);
    const finish = (try tracker.consume("133;D;7;token=secret-token")).?;
    try testing.expectEqual(@as(u8, 7), finish.command_finished.exit_status.?);
}

test "unrelated osc strings are left alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parser = Parser.init(arena);
    try testing.expect((try parser.parse("0;window title")) == null);
    try testing.expect((try parser.parse("8;;https://example.test")) == null);
}

test "full screen programs are recognised" {
    try testing.expect(isFullScreenProgram("vim src/main.zig"));
    try testing.expect(isFullScreenProgram("/usr/bin/htop"));
    try testing.expect(isFullScreenProgram("ssh workstation"));
    try testing.expect(!isFullScreenProgram("zig build test"));
    try testing.expect(!isFullScreenProgram(""));
}

test "hook scripts exist for the shells we support" {
    try testing.expect(hooks.forShell("bash") != null);
    try testing.expect(hooks.forShell("zsh") != null);
    try testing.expect(hooks.forShell("fish") != null);
    try testing.expect(hooks.forShell("pwsh") != null);
    try testing.expect(hooks.forShell("csh") == null);
    // Every hook emits the prompt-start mark, which is what makes a block.
    try testing.expect(std.mem.indexOf(u8, hooks.bash, "133;A") != null);
    try testing.expect(std.mem.indexOf(u8, hooks.zsh, "133;A") != null);
}

test "the 633 family is treated as an alias" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tracker = Tracker.init(arena);
    const boundary = (try tracker.consume("633;C;cmdline=ls")).?;
    try testing.expectEqualStrings("ls", boundary.output_start.command.?);
}
