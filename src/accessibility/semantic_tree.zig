//! The semantic accessibility tree.
//!
//! A terminal drawn on a GPU surface is, to an assistive technology, a
//! rectangle of pixels. Nothing about a block, a command, a status or an
//! approval is discoverable unless the application says so. This module is that
//! statement: a parallel tree of roles, names, states and relationships, which
//! the platform bridge (AT-SPI, UI Automation, NSAccessibility) publishes.
//!
//! The tree is also checkable. A node with no accessible name, a control that
//! cannot be reached by keyboard, or a live region that never announces a
//! finished command are defects the test suite can find.

const std = @import("std");
const contrast = @import("contrast.zig");

/// Roles the workbench needs. They map onto the platform roles the bridge uses.
pub const Role = enum {
    window,
    tab_list,
    tab,
    /// The scrolling list of blocks.
    log_view,
    /// One block: a command with its output, or an agent action.
    block,
    /// The text of a command.
    command,
    /// A block's output.
    output,
    /// The command input.
    text_input,
    button,
    menu,
    menu_item,
    dialog,
    /// A region that announces changes, such as "the command finished".
    status,
    /// A terminal surface a full-screen program has taken over.
    terminal,
    tree,
    tree_item,
    heading,
    group,

    /// A control the user operates, as against a container or a label.
    pub fn isInteractive(self: Role) bool {
        return switch (self) {
            .tab, .button, .menu_item, .text_input, .tree_item, .terminal => true,
            else => false,
        };
    }

    /// Does this role require an accessible name?
    pub fn requiresName(self: Role) bool {
        return switch (self) {
            .window, .tab, .button, .menu_item, .text_input, .dialog, .tree_item, .heading, .terminal => true,
            else => false,
        };
    }
};

pub const LiveRegion = enum {
    off,
    /// Announced when the user is idle.
    polite,
    /// Announced immediately, interrupting.
    assertive,
};

pub const State = struct {
    focusable: bool = false,
    focused: bool = false,
    selected: bool = false,
    expanded: ?bool = null,
    busy: bool = false,
    disabled: bool = false,
    /// True while a command is running inside this block.
    running: bool = false,
    /// True when the node is off screen but still in the tree.
    offscreen: bool = false,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn area(self: Rect) f32 {
        return self.width * self.height;
    }

    pub fn intersects(a: Rect, b: Rect) bool {
        return a.x < b.x + b.width and b.x < a.x + a.width and
            a.y < b.y + b.height and b.y < a.y + a.height;
    }
};

pub const Node = struct {
    id: u32,
    role: Role,
    /// The name a screen reader speaks. Not the same as the visible text: a
    /// button labelled with an icon still needs a name.
    name: []const u8 = "",
    /// Extra description, spoken after the name.
    description: []const u8 = "",
    /// The text content, for text-bearing roles.
    value: []const u8 = "",
    state: State = .{},
    live: LiveRegion = .off,
    bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// Keyboard shortcut, written the way the user's platform writes it.
    keyboard_shortcut: ?[]const u8 = null,
    children: []const Node = &.{},
    /// Node this one labels or controls.
    controls: ?u32 = null,
};

pub const Tree = struct {
    root: Node,

    pub fn count(self: Tree) usize {
        return countNode(self.root);
    }

    fn countNode(node: Node) usize {
        var total: usize = 1;
        for (node.children) |child| total += countNode(child);
        return total;
    }

    pub fn find(self: Tree, id: u32) ?Node {
        return findNode(self.root, id);
    }

    fn findNode(node: Node, id: u32) ?Node {
        if (node.id == id) return node;
        for (node.children) |child| {
            if (findNode(child, id)) |found| return found;
        }
        return null;
    }

    /// Nodes in the order the keyboard moves through them.
    pub fn focusOrder(self: Tree, arena: std.mem.Allocator) !std.ArrayList(Node) {
        var out: std.ArrayList(Node) = .empty;
        try collectFocusable(self.root, arena, &out);
        return out;
    }

    fn collectFocusable(node: Node, arena: std.mem.Allocator, out: *std.ArrayList(Node)) !void {
        if (node.state.focusable and !node.state.disabled) try out.append(arena, node);
        for (node.children) |child| try collectFocusable(child, arena, out);
    }
};

pub const FindingCode = enum {
    missing_name,
    interactive_not_focusable,
    target_too_small,
    focus_obscured,
    no_keyboard_path,
    live_region_missing,
    duplicate_id,
    focus_not_visible,

    pub fn text(self: FindingCode) []const u8 {
        return switch (self) {
            .missing_name => "A11Y01",
            .interactive_not_focusable => "A11Y02",
            .target_too_small => "A11Y22",
            .focus_obscured => "A11Y23",
            .no_keyboard_path => "A11Y03",
            .live_region_missing => "A11Y04",
            .duplicate_id => "A11Y05",
            .focus_not_visible => "A11Y24",
        };
    }

    /// The WCAG 2.2 success criterion the check comes from, where there is one.
    pub fn criterion(self: FindingCode) ?[]const u8 {
        return switch (self) {
            .missing_name => "4.1.2 Name, Role, Value",
            .interactive_not_focusable, .no_keyboard_path => "2.1.1 Keyboard",
            .target_too_small => "2.5.8 Target Size (Minimum)",
            .focus_obscured => "2.4.11 Focus Not Obscured (Minimum)",
            .focus_not_visible => "2.4.7 Focus Visible",
            .live_region_missing => "4.1.3 Status Messages",
            .duplicate_id => null,
        };
    }
};

pub const Finding = struct {
    code: FindingCode,
    node_id: u32,
    message: []const u8,
};

/// WCAG 2.2 target size minimum, in CSS pixels. The workbench uses the same
/// number for its own layout units.
pub const minimum_target_size: f32 = 24.0;

pub const CheckOptions = struct {
    /// Areas drawn over the interface, such as a floating panel. Focus must not
    /// end up underneath one of these.
    overlays: []const Rect = &.{},
    /// Whether the interface draws a visible focus indicator.
    draws_focus_indicator: bool = true,
};

pub fn check(arena: std.mem.Allocator, tree: Tree, options: CheckOptions) !std.ArrayList(Finding) {
    var findings: std.ArrayList(Finding) = .empty;
    var seen: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    try checkNode(arena, tree.root, options, &findings, &seen);

    if (!options.draws_focus_indicator) {
        try findings.append(arena, .{
            .code = .focus_not_visible,
            .node_id = tree.root.id,
            .message = "The interface draws no focus indicator, so a keyboard user cannot tell where they are.",
        });
    }
    return findings;
}

fn checkNode(
    arena: std.mem.Allocator,
    node: Node,
    options: CheckOptions,
    findings: *std.ArrayList(Finding),
    seen: *std.AutoArrayHashMapUnmanaged(u32, void),
) !void {
    if (seen.contains(node.id)) {
        try findings.append(arena, .{
            .code = .duplicate_id,
            .node_id = node.id,
            .message = try std.fmt.allocPrint(arena, "Two nodes share the identifier {d}. An assistive technology cannot tell them apart.", .{node.id}),
        });
    } else {
        try seen.put(arena, node.id, {});
    }

    if (node.role.requiresName() and node.name.len == 0) {
        try findings.append(arena, .{
            .code = .missing_name,
            .node_id = node.id,
            .message = try std.fmt.allocPrint(arena, "A {s} has no accessible name. Give it the words a person would use for it.", .{@tagName(node.role)}),
        });
    }

    if (node.role.isInteractive() and !node.state.focusable and !node.state.disabled) {
        try findings.append(arena, .{
            .code = .interactive_not_focusable,
            .node_id = node.id,
            .message = try std.fmt.allocPrint(arena, "The {s} \"{s}\" can be used with a pointer but cannot be reached with a keyboard.", .{ @tagName(node.role), node.name }),
        });
    }

    // Target size, with the exception the criterion allows for text targets
    // inside a sentence — which the workbench does not have, so any interactive
    // node is measured.
    if (node.role.isInteractive() and node.bounds.area() > 0) {
        if (node.bounds.width < minimum_target_size or node.bounds.height < minimum_target_size) {
            try findings.append(arena, .{
                .code = .target_too_small,
                .node_id = node.id,
                .message = try std.fmt.allocPrint(arena, "The target for \"{s}\" is {d:.0} by {d:.0}. It must be at least {d:.0} by {d:.0}.", .{ node.name, node.bounds.width, node.bounds.height, minimum_target_size, minimum_target_size }),
            });
        }
    }

    if (node.state.focused) {
        for (options.overlays) |overlay| {
            if (node.bounds.intersects(overlay)) {
                try findings.append(arena, .{
                    .code = .focus_obscured,
                    .node_id = node.id,
                    .message = try std.fmt.allocPrint(arena, "The focused item \"{s}\" is covered by something drawn over it.", .{node.name}),
                });
                break;
            }
        }
    }

    // A status region that never announces is the same as no status region.
    if (node.role == .status and node.live == .off) {
        try findings.append(arena, .{
            .code = .live_region_missing,
            .node_id = node.id,
            .message = "A status area does not announce its changes, so a screen-reader user never hears them.",
        });
    }

    for (node.children) |child| try checkNode(arena, child, options, findings, seen);
}

/// The tree the workbench publishes for a session with one finished command and
/// one approval waiting. It is written out in full here because it is the
/// contract the renderer has to meet, and because the tests check it.
pub fn exampleTree() Tree {
    return .{ .root = .{
        .id = 1,
        .role = .window,
        .name = "zag workbench",
        .children = &.{
            .{
                .id = 2,
                .role = .tab_list,
                .name = "Sessions",
                .children = &.{
                    .{
                        .id = 3,
                        .role = .tab,
                        .name = "feature/parser, 1 agent, 4 files changed, tests passing",
                        .state = .{ .focusable = true, .selected = true },
                        .bounds = .{ .x = 0, .y = 0, .width = 240, .height = 32 },
                        .keyboard_shortcut = "Control+1",
                    },
                },
            },
            .{
                .id = 4,
                .role = .log_view,
                .name = "Session history",
                .children = &.{
                    .{
                        .id = 5,
                        .role = .block,
                        .name = "zig build test, succeeded in 1.5 seconds",
                        .state = .{ .focusable = true },
                        .bounds = .{ .x = 0, .y = 40, .width = 800, .height = 120 },
                        .children = &.{
                            .{ .id = 6, .role = .command, .value = "zig build test" },
                            .{ .id = 7, .role = .output, .value = "All 233 tests passed." },
                        },
                    },
                    .{
                        .id = 8,
                        .role = .dialog,
                        .name = "Run rm -rf build/?",
                        .description = "The agent wants to delete the build folder in this repository.",
                        .state = .{ .focusable = true, .focused = true },
                        .bounds = .{ .x = 100, .y = 200, .width = 520, .height = 180 },
                        .children = &.{
                            .{
                                .id = 9,
                                .role = .button,
                                .name = "Allow once",
                                .state = .{ .focusable = true },
                                .bounds = .{ .x = 120, .y = 320, .width = 120, .height = 32 },
                            },
                            .{
                                .id = 10,
                                .role = .button,
                                .name = "Allow here from now on",
                                .state = .{ .focusable = true },
                                .bounds = .{ .x = 250, .y = 320, .width = 200, .height = 32 },
                            },
                            .{
                                .id = 11,
                                .role = .button,
                                .name = "Cancel",
                                .state = .{ .focusable = true },
                                .bounds = .{ .x = 460, .y = 320, .width = 100, .height = 32 },
                            },
                        },
                    },
                },
            },
            .{
                .id = 12,
                .role = .text_input,
                .name = "Command",
                .description = "Type a command, or ask the agent for something.",
                .state = .{ .focusable = true },
                .bounds = .{ .x = 0, .y = 400, .width = 800, .height = 40 },
            },
            .{
                .id = 13,
                .role = .status,
                .name = "Session status",
                .value = "The command finished. It succeeded.",
                .live = .polite,
            },
        },
    } };
}

const testing = std.testing;

test "the published tree passes its own checks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const findings = try check(arena, exampleTree(), .{});
    if (findings.items.len > 0) {
        for (findings.items) |finding| std.debug.print("{s} {d}: {s}\n", .{ finding.code.text(), finding.node_id, finding.message });
    }
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "every interactive node can be reached by keyboard, in order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const order = try exampleTree().focusOrder(arena);
    try testing.expect(order.items.len >= 6);
    try testing.expectEqualStrings("feature/parser, 1 agent, 4 files changed, tests passing", order.items[0].name);
    // The approval buttons come in the order they are read out.
    var saw_allow_once = false;
    var saw_cancel_after = false;
    for (order.items) |node| {
        if (std.mem.eql(u8, node.name, "Allow once")) saw_allow_once = true;
        if (saw_allow_once and std.mem.eql(u8, node.name, "Cancel")) saw_cancel_after = true;
    }
    try testing.expect(saw_cancel_after);
}

test "an unnamed control and an unreachable control are reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tree: Tree = .{ .root = .{
        .id = 1,
        .role = .window,
        .name = "test",
        .children = &.{
            .{ .id = 2, .role = .button, .bounds = .{ .x = 0, .y = 0, .width = 40, .height = 40 } },
            .{ .id = 3, .role = .status, .name = "status", .live = .off },
        },
    } };

    const findings = (try check(arena, tree, .{})).items;
    var codes: [std.meta.fields(FindingCode).len]bool = @splat(false);
    for (findings) |finding| codes[@intFromEnum(finding.code)] = true;
    try testing.expect(codes[@intFromEnum(FindingCode.missing_name)]);
    try testing.expect(codes[@intFromEnum(FindingCode.interactive_not_focusable)]);
    try testing.expect(codes[@intFromEnum(FindingCode.live_region_missing)]);
}

test "a target below the minimum size is reported with the criterion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tree: Tree = .{ .root = .{
        .id = 1,
        .role = .window,
        .name = "test",
        .children = &.{.{
            .id = 2,
            .role = .button,
            .name = "Close",
            .state = .{ .focusable = true },
            .bounds = .{ .x = 0, .y = 0, .width = 16, .height = 16 },
        }},
    } };

    const findings = (try check(arena, tree, .{})).items;
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqual(FindingCode.target_too_small, findings[0].code);
    try testing.expectEqualStrings("2.5.8 Target Size (Minimum)", findings[0].code.criterion().?);
}

test "focus hidden under an overlay is reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tree: Tree = .{ .root = .{
        .id = 1,
        .role = .window,
        .name = "test",
        .children = &.{.{
            .id = 2,
            .role = .button,
            .name = "Run",
            .state = .{ .focusable = true, .focused = true },
            .bounds = .{ .x = 0, .y = 0, .width = 80, .height = 32 },
        }},
    } };

    const clear = (try check(arena, tree, .{})).items;
    try testing.expectEqual(@as(usize, 0), clear.len);

    const covered = (try check(arena, tree, .{
        .overlays = &.{.{ .x = 0, .y = 0, .width = 400, .height = 200 }},
    })).items;
    try testing.expectEqual(@as(usize, 1), covered.len);
    try testing.expectEqual(FindingCode.focus_obscured, covered[0].code);
}

test "the tree can be searched and counted" {
    const tree = exampleTree();
    try testing.expectEqual(@as(usize, 13), tree.count());
    try testing.expectEqualStrings("Cancel", tree.find(11).?.name);
    try testing.expect(tree.find(99) == null);
}

test "the shipped theme and the tree are checked together" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The focus ring must stand out, or a visible focus indicator is not
    // actually visible.
    const failures = try contrast.default_dark.check(arena, .aa);
    try testing.expectEqual(@as(usize, 0), failures.items.len);
    const findings = try check(arena, exampleTree(), .{ .draws_focus_indicator = true });
    try testing.expectEqual(@as(usize, 0), findings.items.len);
}
