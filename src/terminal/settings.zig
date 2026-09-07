//! What a person can change about their terminal without editing Zig.
//!
//! `zag term` chooses a shell, a scrollback size, a set of colours and a few
//! key bindings, and until now every one of those was a constant in a source
//! file. A terminal somebody has to recompile to make usable is not a terminal
//! they will use.
//!
//! ## A bad setting must not stop the terminal starting
//!
//! This is the whole design, and it is the opposite of what a configuration
//! reader usually does. The file is read at the moment a person is trying to
//! open a shell — often the moment they are trying to fix something else — and
//! refusing to start because line nine says `scrollback = "lots"` leaves them
//! with no terminal and a message about line nine.
//!
//! So every setting is independent. One that cannot be read is reported by
//! name, with what was found and what is being used instead, and the terminal
//! opens with the default for that setting and the person's own values for
//! every other. A file that is not valid TOML at all is one report and a
//! terminal that opens with nothing but defaults.
//!
//! The reports are not warnings printed and forgotten. They are values the
//! caller is handed, so `zag term` can show them, `zag doctor` can list them,
//! and a test can assert on them.
//!
//! ## Why the reports name the value they rejected
//!
//! "scrollback is not valid" sends somebody to read documentation. "scrollback:
//! expected a whole number of lines, found \"lots\"; using 10000" tells them
//! what to type. The rejected value is quoted back because a setting a person
//! cannot see is a setting they cannot fix — and it is their own file, so
//! nothing in it is a secret from them.
//!
//! ## What is deliberately not settable
//!
//! Nothing here can change what the workspace records, what the policy allows,
//! or whether boundaries are authenticated. A settings file is the easiest
//! thing in a workspace for another program to write, and a settings file that
//! could turn off the record would be the shortest path to a workspace that
//! keeps nothing. Appearance and convenience only.

const std = @import("std");
const toml = @import("../interop/toml.zig");
const contrast = @import("../accessibility/contrast.zig");

/// One setting that could not be used, and what happened instead.
pub const Report = struct {
    /// The setting's name as it appears in the file, dotted: `colours.text`.
    setting: []const u8,
    /// What the file said, quoted back so a person can find it.
    found: []const u8,
    /// Why it could not be used, in a few words.
    problem: []const u8,
    /// What is being used in its place, written the way it would be typed.
    using: []const u8,

    pub fn writeSentence(self: Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.found.len == 0) {
            try w.print("{s}: {s}. Using {s}.", .{ self.setting, self.problem, self.using });
            return;
        }
        try w.print("{s}: {s}, found \"{s}\". Using {s}.", .{
            self.setting,
            self.problem,
            self.found,
            self.using,
        });
    }

    pub fn text(self: Report, arena: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        try self.writeSentence(&out.writer);
        return out.written();
    }
};

/// A key binding: what to press, and what it does.
pub const Binding = struct {
    /// The chord as written: `ctrl+shift+k`.
    chord: []const u8,
    action: Action,
};

/// The things a binding can be bound to.
///
/// A closed set, not a command to run. A settings file that could name a
/// program to execute on a keystroke would be a way to run code by writing a
/// file, which is exactly what the policy engine exists to prevent.
pub const Action = enum {
    /// Clear the screen and the scrollback.
    clear_screen,
    /// Jump to the previous or next command boundary.
    previous_block,
    next_block,
    /// Copy the output of the block the cursor is in.
    copy_block_output,
    /// Search the recorded history.
    search_history,
    /// Show what the current session has recorded so far.
    show_record,

    pub fn parse(name: []const u8) ?Action {
        return std.meta.stringToEnum(Action, name);
    }

    /// What it does, for a person reading a list of bindings.
    pub fn text(self: Action) []const u8 {
        return switch (self) {
            .clear_screen => "clear the screen and the scrollback",
            .previous_block => "go to the previous command",
            .next_block => "go to the next command",
            .copy_block_output => "copy this command's output",
            .search_history => "search recorded work",
            .show_record => "show what this session has recorded",
        };
    }
};

/// The colours the terminal draws with.
///
/// Named by role rather than by colour, so a theme can be checked for contrast
/// and so the names still mean something when somebody sets them to anything.
pub const Colours = struct {
    text: contrast.Rgb = .{ .r = 0xE6, .g = 0xE6, .b = 0xE6 },
    background: contrast.Rgb = .{ .r = 0x12, .g = 0x12, .b = 0x12 },
    /// A command that failed.
    failure: contrast.Rgb = .{ .r = 0xFF, .g = 0x8A, .b = 0x80 },
    /// A command that succeeded.
    success: contrast.Rgb = .{ .r = 0x9C, .g = 0xE6, .b = 0xB0 },
    /// The prompt and other structure the terminal itself draws.
    structure: contrast.Rgb = .{ .r = 0x9E, .g = 0xC1, .b = 0xFF },

    /// The colour pairs a contrast check applies to.
    ///
    /// Every foreground is checked against the background, because a person who
    /// sets one to something unreadable should be told rather than left
    /// squinting. The check runs; whether to obey it is theirs.
    pub fn pairs(self: Colours, arena: std.mem.Allocator) ![]const contrast.Pair {
        var out: std.ArrayList(contrast.Pair) = .empty;
        try out.append(arena, .{ .name = "text", .foreground = self.text, .background = self.background });
        try out.append(arena, .{ .name = "failure", .foreground = self.failure, .background = self.background });
        try out.append(arena, .{ .name = "success", .foreground = self.success, .background = self.background });
        try out.append(arena, .{ .name = "structure", .foreground = self.structure, .background = self.background });
        return out.items;
    }
};

/// Everything the terminal reads from the file.
pub const Settings = struct {
    /// The program to run. Null means `$SHELL`, then `/bin/bash`, which is what
    /// the terminal already did.
    shell: ?[]const u8 = null,
    /// Lines of scrollback kept in memory.
    scrollback: usize = default_scrollback,
    columns: u16 = 80,
    rows: u16 = 24,
    colours: Colours = .{},
    bindings: []const Binding = &.{},
    /// Set false to start the shell with no generated init file. The session
    /// then records inferred boundaries rather than marked ones, which is worse
    /// and is sometimes what a person needs.
    integrate: bool = true,

    pub const default_scrollback: usize = 10_000;
    pub const min_scrollback: usize = 100;
    /// Above this a session holds more memory than a terminal has any business
    /// holding, and the number is almost always a typo.
    pub const max_scrollback: usize = 10_000_000;
    pub const min_size: u16 = 20;
    pub const max_size: u16 = 5_000;

    /// The bindings a build ships with. A file that sets none gets these; a
    /// file that sets any replaces the lot, because a person who wrote their
    /// own list meant it.
    pub const default_bindings = [_]Binding{
        .{ .chord = "ctrl+shift+k", .action = .clear_screen },
        .{ .chord = "ctrl+shift+up", .action = .previous_block },
        .{ .chord = "ctrl+shift+down", .action = .next_block },
        .{ .chord = "ctrl+shift+c", .action = .copy_block_output },
        .{ .chord = "ctrl+shift+f", .action = .search_history },
        .{ .chord = "ctrl+shift+r", .action = .show_record },
    };
};

/// What reading a settings file produced.
pub const Loaded = struct {
    settings: Settings,
    /// Every setting that could not be used, in the order they appear in this
    /// file's own layout rather than the file's, so two runs report the same
    /// list in the same order.
    reports: []const Report,
    /// False when there was no file at all, which is not a problem and is the
    /// normal case.
    found: bool,

    pub fn ok(self: Loaded) bool {
        return self.reports.len == 0;
    }

    /// Every report, one per line.
    pub fn writeReports(self: Loaded, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.reports) |report| {
            try report.writeSentence(w);
            try w.writeByte('\n');
        }
    }
};

/// The defaults, for a workspace with no settings file.
pub fn defaults(arena: std.mem.Allocator) !Settings {
    return .{ .bindings = try arena.dupe(Binding, &Settings.default_bindings) };
}

/// Read settings from TOML text.
///
/// Never fails on the content. A file that is not TOML at all becomes one
/// report and the defaults; a file with one bad line becomes one report and
/// every other setting the person wrote.
pub fn read(arena: std.mem.Allocator, source: []const u8) !Loaded {
    var reports: std.ArrayList(Report) = .empty;
    var settings = try defaults(arena);

    const document = toml.parse(arena, source) catch |err| {
        try reports.append(arena, .{
            .setting = "the file",
            .found = "",
            .problem = problemText(err),
            .using = "the built-in settings",
        });
        return .{ .settings = settings, .reports = reports.items, .found = true };
    };

    if (document.get("terminal.shell")) |value| {
        if (value.asString()) |text| {
            if (text.len == 0) {
                try reports.append(arena, .{
                    .setting = "terminal.shell",
                    .found = "",
                    .problem = "a shell must be named",
                    .using = "your $SHELL",
                });
            } else settings.shell = text;
        } else try reports.append(arena, .{
            .setting = "terminal.shell",
            .found = try describe(arena, value),
            .problem = "expected the path to a shell, in quotes",
            .using = "your $SHELL",
        });
    }

    if (document.get("terminal.scrollback")) |value| {
        settings.scrollback = try wholeNumber(
            arena,
            &reports,
            "terminal.scrollback",
            value,
            Settings.min_scrollback,
            Settings.max_scrollback,
            Settings.default_scrollback,
            "lines",
        );
    }

    if (document.get("terminal.columns")) |value| {
        settings.columns = @intCast(try wholeNumber(
            arena,
            &reports,
            "terminal.columns",
            value,
            Settings.min_size,
            Settings.max_size,
            80,
            "columns",
        ));
    }

    if (document.get("terminal.rows")) |value| {
        settings.rows = @intCast(try wholeNumber(
            arena,
            &reports,
            "terminal.rows",
            value,
            Settings.min_size,
            Settings.max_size,
            24,
            "rows",
        ));
    }

    if (document.get("terminal.shell_integration")) |value| {
        switch (value) {
            .boolean => |on| settings.integrate = on,
            else => try reports.append(arena, .{
                .setting = "terminal.shell_integration",
                .found = try describe(arena, value),
                .problem = "expected true or false",
                .using = "true",
            }),
        }
    }

    // Colours, each one independent of the others, so a single bad hex string
    // does not cost somebody their whole theme.
    const colour_fields = [_]struct { path: []const u8, field: []const u8 }{
        .{ .path = "colours.text", .field = "text" },
        .{ .path = "colours.background", .field = "background" },
        .{ .path = "colours.failure", .field = "failure" },
        .{ .path = "colours.success", .field = "success" },
        .{ .path = "colours.structure", .field = "structure" },
    };
    inline for (colour_fields) |entry| {
        if (document.get(entry.path)) |value| {
            if (value.asString()) |text| {
                if (parseHex(text)) |rgb| {
                    @field(settings.colours, entry.field) = rgb;
                } else {
                    try reports.append(arena, .{
                        .setting = entry.path,
                        .found = text,
                        .problem = "expected a colour like \"#1e1e1e\"",
                        .using = try hexOf(arena, @field(settings.colours, entry.field)),
                    });
                }
            } else try reports.append(arena, .{
                .setting = entry.path,
                .found = try describe(arena, value),
                .problem = "expected a colour like \"#1e1e1e\", in quotes",
                .using = try hexOf(arena, @field(settings.colours, entry.field)),
            });
        }
    }

    if (document.get("keys")) |value| {
        settings.bindings = try readBindings(arena, &reports, value);
    }

    return .{ .settings = settings, .reports = reports.items, .found = true };
}

/// Read the `[keys]` table: each key is a chord, each value an action.
///
/// A chord bound to something this build does not do is one report and one
/// binding dropped — not a refusal of the whole table, because the other five
/// bindings are still what the person asked for.
fn readBindings(
    arena: std.mem.Allocator,
    reports: *std.ArrayList(Report),
    value: toml.Value,
) ![]const Binding {
    const table = switch (value) {
        .table => |t| t,
        else => {
            try reports.append(arena, .{
                .setting = "keys",
                .found = try describe(arena, value),
                .problem = "expected a [keys] table of chord = \"action\"",
                .using = "the built-in bindings",
            });
            return arena.dupe(Binding, &Settings.default_bindings);
        },
    };

    var out: std.ArrayList(Binding) = .empty;
    var entries = table.iterator();
    while (entries.next()) |entry| {
        const chord = entry.key_ptr.*;
        const name = entry.value_ptr.asString() orelse {
            try reports.append(arena, .{
                .setting = try std.fmt.allocPrint(arena, "keys.{s}", .{chord}),
                .found = try describe(arena, entry.value_ptr.*),
                .problem = "expected the name of an action, in quotes",
                .using = "nothing for that key",
            });
            continue;
        };
        const action = Action.parse(name) orelse {
            try reports.append(arena, .{
                .setting = try std.fmt.allocPrint(arena, "keys.{s}", .{chord}),
                .found = name,
                .problem = "this build has no such action",
                .using = "nothing for that key",
            });
            continue;
        };
        try out.append(arena, .{ .chord = chord, .action = action });
    }

    // A table that named nothing usable leaves the defaults in place, rather
    // than a terminal with no bindings at all.
    if (out.items.len == 0) return arena.dupe(Binding, &Settings.default_bindings);
    return out.items;
}

fn wholeNumber(
    arena: std.mem.Allocator,
    reports: *std.ArrayList(Report),
    setting: []const u8,
    value: toml.Value,
    low: anytype,
    high: anytype,
    fallback: anytype,
    unit: []const u8,
) !usize {
    const found = switch (value) {
        .integer => |n| n,
        else => {
            try reports.append(arena, .{
                .setting = setting,
                .found = try describe(arena, value),
                .problem = try std.fmt.allocPrint(arena, "expected a whole number of {s}", .{unit}),
                .using = try std.fmt.allocPrint(arena, "{d}", .{fallback}),
            });
            return fallback;
        },
    };
    if (found < low or found > high) {
        try reports.append(arena, .{
            .setting = setting,
            .found = try std.fmt.allocPrint(arena, "{d}", .{found}),
            .problem = try std.fmt.allocPrint(arena, "expected between {d} and {d} {s}", .{ low, high, unit }),
            .using = try std.fmt.allocPrint(arena, "{d}", .{fallback}),
        });
        return fallback;
    }
    return @intCast(found);
}

/// What kind of thing was found, for a report about the wrong kind.
///
/// A number is quoted back as itself; a table or an array is described rather
/// than printed, because printing one back at somebody who wrote it by mistake
/// fills the screen without helping.
fn describe(arena: std.mem.Allocator, value: toml.Value) ![]const u8 {
    return switch (value) {
        .string, .datetime => |s| s,
        .integer => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        .boolean => |b| if (b) "true" else "false",
        .array => "a list",
        .table => "a table",
    };
}

fn problemText(err: anyerror) []const u8 {
    return switch (err) {
        error.UnterminatedString => "a quoted value is missing its closing quote",
        error.UnterminatedTable => "a table header is missing its closing bracket",
        error.UnterminatedArray => "a list is missing its closing bracket",
        error.OutOfMemory => "there was not enough memory to read it",
        else => "this is not a settings file this build can read",
    };
}

/// `#rrggbb`, or `#rgb` for the short form people actually type.
pub fn parseHex(text: []const u8) ?contrast.Rgb {
    if (text.len == 0 or text[0] != '#') return null;
    const digits = text[1..];
    switch (digits.len) {
        3 => {
            const r = hexDigit(digits[0]) orelse return null;
            const g = hexDigit(digits[1]) orelse return null;
            const b = hexDigit(digits[2]) orelse return null;
            // `#abc` means `#aabbcc`, which is what every other tool does and
            // what somebody typing it expects.
            return .{ .r = r * 17, .g = g * 17, .b = b * 17 };
        },
        6 => {
            return .{
                .r = (hexDigit(digits[0]) orelse return null) * 16 + (hexDigit(digits[1]) orelse return null),
                .g = (hexDigit(digits[2]) orelse return null) * 16 + (hexDigit(digits[3]) orelse return null),
                .b = (hexDigit(digits[4]) orelse return null) * 16 + (hexDigit(digits[5]) orelse return null),
            };
        },
        else => return null,
    }
}

fn hexDigit(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

pub fn hexOf(arena: std.mem.Allocator, rgb: contrast.Rgb) ![]const u8 {
    return std.fmt.allocPrint(arena, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb.r, rgb.g, rgb.b });
}

/// Where a workspace keeps its settings.
pub fn pathIn(arena: std.mem.Allocator, root: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/.workspace/settings.toml", .{root});
}

/// Read the settings file in a workspace, if there is one.
///
/// A missing file is not a problem and produces no report: most workspaces will
/// never have one, and telling somebody their absent file is absent every time
/// they open a terminal would teach them to ignore the reports that matter.
pub fn load(arena: std.mem.Allocator, io: std.Io, root: []const u8) !Loaded {
    const path = try pathIn(arena, root);
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{
            .settings = try defaults(arena),
            .reports = &.{},
            .found = false,
        },
        else => {
            var reports: std.ArrayList(Report) = .empty;
            try reports.append(arena, .{
                .setting = "the file",
                .found = path,
                .problem = "could not be read",
                .using = "the built-in settings",
            });
            return .{ .settings = try defaults(arena), .reports = reports.items, .found = false };
        },
    };
    return read(arena, source);
}

/// An example file, with every setting at its default, for somebody starting
/// one from nothing.
pub fn writeExample(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(
        \\# Settings for zag term. Every line is optional.
        \\#
        \\# A setting this build cannot read is reported by name and the built-in
        \\# value is used instead, so a mistake here never stops a terminal
        \\# opening.
        \\
        \\[terminal]
        \\# The program to run. Leave it out to use your own $SHELL.
        \\# shell = "/bin/zsh"
        \\scrollback = 10000
        \\columns = 80
        \\rows = 24
        \\# Set false to start the shell with no added prompt marks. The record
        \\# then holds inferred command boundaries rather than marked ones.
        \\shell_integration = true
        \\
        \\[colours]
        \\text = "#e6e6e6"
        \\background = "#121212"
        \\failure = "#ff8a80"
        \\success = "#9ce6b0"
        \\structure = "#9ec1ff"
        \\
        \\[keys]
        \\
    );
    for (Settings.default_bindings) |binding| {
        try w.print("\"{s}\" = \"{s}\"   # {s}\n", .{
            binding.chord,
            @tagName(binding.action),
            binding.action.text(),
        });
    }
}

const testing = std.testing;

test "one bad setting costs that setting and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The whole design in one test. Somebody typed a word where a number goes,
    // and everything else they wrote still applies. Refusing to start here
    // would leave them with no terminal at the moment they were trying to fix
    // something else.
    const loaded = try read(arena,
        \\[terminal]
        \\shell = "/bin/zsh"
        \\scrollback = "lots"
        \\columns = 120
        \\
        \\[colours]
        \\text = "#ffffff"
    );

    try testing.expectEqualStrings("/bin/zsh", loaded.settings.shell.?);
    try testing.expectEqual(@as(u16, 120), loaded.settings.columns);
    try testing.expectEqual(@as(u8, 0xFF), loaded.settings.colours.text.r);
    // And the one that was wrong fell back.
    try testing.expectEqual(Settings.default_scrollback, loaded.settings.scrollback);

    try testing.expectEqual(@as(usize, 1), loaded.reports.len);
    const sentence = try loaded.reports[0].text(arena);
    // Named, with what was found and what is being used. "scrollback is not
    // valid" would send somebody to read documentation; this tells them what to
    // type.
    try testing.expect(std.mem.indexOf(u8, sentence, "terminal.scrollback") != null);
    try testing.expect(std.mem.indexOf(u8, sentence, "\"lots\"") != null);
    try testing.expect(std.mem.indexOf(u8, sentence, "10000") != null);
}

test "a file that is not a settings file at all still opens a terminal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = try read(arena, "[terminal\nshell = \"/bin/sh");
    try testing.expectEqual(@as(usize, 1), loaded.reports.len);
    try testing.expect(!loaded.ok());

    // Every default is in place, including the bindings, so the terminal that
    // opens is the one somebody would get with no file at all.
    try testing.expect(loaded.settings.shell == null);
    try testing.expectEqual(Settings.default_scrollback, loaded.settings.scrollback);
    try testing.expectEqual(Settings.default_bindings.len, loaded.settings.bindings.len);
}

test "no file is not a problem and produces no report" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    // Most workspaces will never have one. Telling somebody their absent file
    // is absent, every time they open a terminal, teaches them to ignore the
    // reports that matter.
    const loaded = try load(arena, threaded.io(), ".zig-cache/tmp/no-such-workspace-here");
    try testing.expect(!loaded.found);
    try testing.expect(loaded.ok());
    try testing.expectEqual(@as(usize, 0), loaded.reports.len);
    try testing.expectEqual(Settings.default_bindings.len, loaded.settings.bindings.len);
}

test "a number out of range is reported with the range" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A scrollback of two thousand million is a typo, not a preference, and
    // honouring it would hold more memory than a terminal has any business
    // holding.
    const loaded = try read(arena,
        \\[terminal]
        \\scrollback = 2000000000
        \\rows = 2
    );
    try testing.expectEqual(@as(usize, 2), loaded.reports.len);
    try testing.expectEqual(Settings.default_scrollback, loaded.settings.scrollback);
    try testing.expectEqual(@as(u16, 24), loaded.settings.rows);

    const sentence = try loaded.reports[0].text(arena);
    try testing.expect(std.mem.indexOf(u8, sentence, "between 100 and 10000000") != null);
}

test "colours are read, and one bad colour costs one colour" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = try read(arena,
        \\[colours]
        \\text = "#abc"
        \\background = "black"
        \\failure = "#FF0000"
    );

    // The short form means what it does everywhere else.
    try testing.expectEqual(@as(u8, 0xAA), loaded.settings.colours.text.r);
    try testing.expectEqual(@as(u8, 0xBB), loaded.settings.colours.text.g);
    try testing.expectEqual(@as(u8, 0xCC), loaded.settings.colours.text.b);
    // Upper case hex is hex.
    try testing.expectEqual(@as(u8, 0xFF), loaded.settings.colours.failure.r);
    // And the one that is not a colour left its default alone.
    try testing.expectEqual(@as(u8, 0x12), loaded.settings.colours.background.r);

    try testing.expectEqual(@as(usize, 1), loaded.reports.len);
    const sentence = try loaded.reports[0].text(arena);
    try testing.expect(std.mem.indexOf(u8, sentence, "colours.background") != null);
    try testing.expect(std.mem.indexOf(u8, sentence, "\"black\"") != null);
    // The fallback is written the way it would be typed, so it can be pasted.
    try testing.expect(std.mem.indexOf(u8, sentence, "#121212") != null);
}

test "hex parsing accepts what people type and refuses what they do not" {
    try testing.expect(parseHex("#000000").?.r == 0);
    try testing.expect(parseHex("#ffffff").?.b == 255);
    try testing.expect(parseHex("#FFF").?.g == 255);
    try testing.expect(parseHex("#1e1e1e").?.r == 0x1E);

    try testing.expect(parseHex("") == null);
    try testing.expect(parseHex("ffffff") == null); // no hash
    try testing.expect(parseHex("#fffff") == null); // five digits
    try testing.expect(parseHex("#gggggg") == null);
    try testing.expect(parseHex("#12345678") == null);
}

test "a key bound to something this build cannot do costs one key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = try read(arena,
        \\[keys]
        \\"ctrl+l" = "clear_screen"
        \\"ctrl+shift+p" = "launch_the_rockets"
        \\"ctrl+shift+f" = "search_history"
    );

    // Two bindings survive; the invented one does not, and the person is told
    // which. Refusing the whole table would cost them the two they got right.
    try testing.expectEqual(@as(usize, 2), loaded.settings.bindings.len);
    try testing.expectEqualStrings("ctrl+l", loaded.settings.bindings[0].chord);
    try testing.expectEqual(Action.clear_screen, loaded.settings.bindings[0].action);
    try testing.expectEqual(Action.search_history, loaded.settings.bindings[1].action);

    try testing.expectEqual(@as(usize, 1), loaded.reports.len);
    const sentence = try loaded.reports[0].text(arena);
    try testing.expect(std.mem.indexOf(u8, sentence, "keys.ctrl+shift+p") != null);
    try testing.expect(std.mem.indexOf(u8, sentence, "launch_the_rockets") != null);
}

test "a keys table with nothing usable leaves the built-in bindings alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Better than a terminal with no bindings at all, which is what an empty
    // list would give.
    const loaded = try read(arena,
        \\[keys]
        \\"ctrl+x" = "do_something_impossible"
    );
    try testing.expectEqual(Settings.default_bindings.len, loaded.settings.bindings.len);
    try testing.expectEqual(@as(usize, 1), loaded.reports.len);
}

test "settings cannot reach anything the record depends on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A settings file is the easiest thing in a workspace for another program
    // to write. One that could turn off the record, widen the policy or run a
    // program on a keystroke would be the shortest path to a workspace that
    // keeps nothing. Every field here is checked against that.
    const fields = @typeInfo(Settings).@"struct".fields;
    inline for (fields) |field| {
        const forbidden = [_][]const u8{ "policy", "capabilit", "actor", "token", "record", "log", "redact", "credential" };
        for (forbidden) |word| {
            try testing.expect(std.mem.indexOf(u8, field.name, word) == null);
        }
    }

    // And an action is a closed set, never a command line. A file that could
    // name a program to run on a keystroke would be a way to execute code by
    // writing a file, which is what the policy engine exists to prevent.
    for (std.enums.values(Action)) |action| {
        try testing.expect(action.text().len > 0);
        _ = Action.parse(@tagName(action)).?;
    }
    try testing.expect(Action.parse("/bin/sh") == null);
    _ = arena;
}

test "the example file is a settings file this build reads back with no reports" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An example that does not parse is worse than none: it is the first thing
    // somebody copies, and it teaches them the format is broken.
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeExample(&out.writer);
    const loaded = try read(arena, out.written());

    if (!loaded.ok()) {
        var problems: std.Io.Writer.Allocating = .init(arena);
        try loaded.writeReports(&problems.writer);
        std.debug.print("the example file does not read cleanly:\n{s}\n", .{problems.written()});
    }
    try testing.expect(loaded.ok());

    // And it round-trips: every default in the example is the default the code
    // holds, so the file does not quietly document something else.
    try testing.expectEqual(Settings.default_scrollback, loaded.settings.scrollback);
    try testing.expectEqual(@as(u16, 80), loaded.settings.columns);
    try testing.expectEqual(@as(u16, 24), loaded.settings.rows);
    try testing.expect(loaded.settings.integrate);
    try testing.expectEqual(Settings.default_bindings.len, loaded.settings.bindings.len);
    const defaults_now = try defaults(arena);
    try testing.expectEqual(defaults_now.colours.text.r, loaded.settings.colours.text.r);
    try testing.expectEqual(defaults_now.colours.background.b, loaded.settings.colours.background.b);
}

test "the default colours pass the contrast level the product claims" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Shipping a default theme that fails the standard this repository audits
    // itself against would be the plainest kind of hypocrisy, and it is the
    // sort of thing that only stays true if a test says so.
    const settings = try defaults(arena);
    const theme: contrast.Theme = .{
        .name = "terminal defaults",
        .pairs = try settings.colours.pairs(arena),
    };
    const failures = try theme.check(arena, .aa);
    if (failures.items.len > 0) {
        for (failures.items) |failure| {
            std.debug.print("{s}: ratio {d:.2}\n", .{ failure.pair.name, failure.result.ratio });
        }
    }
    try testing.expectEqual(@as(usize, 0), failures.items.len);
}

test "a setting the file does not mention keeps its default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = try read(arena, "[terminal]\nrows = 50\n");
    try testing.expect(loaded.ok());
    try testing.expectEqual(@as(u16, 50), loaded.settings.rows);
    try testing.expectEqual(@as(u16, 80), loaded.settings.columns);
    try testing.expectEqual(Settings.default_scrollback, loaded.settings.scrollback);
    try testing.expect(loaded.settings.shell == null);
    try testing.expect(loaded.settings.integrate);
}

test "shell integration can be turned off, and only by a boolean" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const off = try read(arena, "[terminal]\nshell_integration = false\n");
    try testing.expect(off.ok());
    try testing.expect(!off.settings.integrate);

    // "no" is not false. Guessing at it would mean a person who typed
    // something else got a terminal that records worse boundaries without
    // being told.
    const vague = try read(arena, "[terminal]\nshell_integration = \"no\"\n");
    try testing.expectEqual(@as(usize, 1), vague.reports.len);
    try testing.expect(vague.settings.integrate);
}
