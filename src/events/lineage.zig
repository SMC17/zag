//! What depended on what, derived from the record rather than declared.
//!
//! The causal graph in `graph.zig` answers "what did this event lead to". It is
//! a forest: each event has at most one cause, so every question about it is a
//! walk up or down one chain. That is the right shape for "why did this happen",
//! and it is the wrong shape for the question a person actually asks after a
//! failure, which is:
//!
//!   > Which of the things I did could this be about?
//!
//! Answering that needs edges the log does not write down. A command that reads
//! a file depends on whoever wrote that file last, even though neither event
//! caused the other and they may sit in different sessions hours apart. Adding
//! those edges turns the forest into a directed acyclic graph, and the graph is
//! what makes impact analysis and blame possible over recorded work.
//!
//! ## Where the edges come from
//!
//! Three kinds, all derived, none declared:
//!
//!   * **Causation.** The `causedBy` link already in the log.
//!   * **Data flow.** A file is written, then read or opened: the reader
//!     depends on the last writer *before it*. Only the last one, because an
//!     earlier write was already replaced and depending on it would be false.
//!   * **Sequence within a block.** Output and a finish belong to the command
//!     that produced them.
//!
//! ## Why log order is a topological order
//!
//! Every edge points from an earlier index to a later one. Causation does,
//! because a cause is appended before its effect. Data flow does, because the
//! writer is chosen from the writes that came before the read. So no sort is
//! needed anywhere in this file, no cycle is possible, and a single forward
//! pass computes longest paths. That invariant is checked, not assumed:
//! `isTopological` is the property every algorithm here rests on, and a merged
//! or repaired log is exactly where it would stop holding.
//!
//! ## Reachability
//!
//! "Did anything I changed this morning reach the test that failed?" is a
//! reachability question over that DAG. The answer is computed with bitsets, a
//! row per node, filled in one backwards pass: a node reaches whatever its
//! successors reach, and the union is a word-at-a-time OR. That costs
//! `nodes * edges / 64` words of work instead of a search per question, which
//! is what makes asking it about every node at once affordable.
//!
//! The memory is the honest limit: a row is one bit per node, so the whole
//! closure is `n²/8` bytes and a hundred thousand events would want more than a
//! gigabyte. So it is built for a chosen set of events — one run, one session,
//! one day — and `Reach.build` refuses a set larger than it can hold rather
//! than trying and failing partway.

const std = @import("std");
const event_mod = @import("event.zig");
const graph_mod = @import("graph.zig");
const log_mod = @import("log.zig");
const timeutil = @import("../core/time.zig");

pub const Envelope = event_mod.Envelope;
pub const EventId = event_mod.EventId;

pub const EdgeKind = enum {
    /// The log's own `causedBy` link.
    caused,
    /// One event wrote a file, a later one read it.
    data,
    /// Output and completion belong to the command they came from.
    sequence,

    pub fn text(self: EdgeKind) []const u8 {
        return switch (self) {
            .caused => "led to",
            .data => "was read by",
            .sequence => "belongs to",
        };
    }
};

pub const Edge = struct {
    from: usize,
    to: usize,
    kind: EdgeKind,
    /// The file, when the edge is data flow. Empty otherwise.
    through: []const u8 = "",
};

pub const Node = struct {
    envelope: Envelope,
    /// Edges out of this node, as indices into `edges`.
    out: []const usize = &.{},
    /// Edges into this node.
    in: []const usize = &.{},
    /// How long this event itself took, where that is known. Used for the
    /// critical path, and zero for an event that is an instant.
    cost: timeutil.Duration = .{ .ns = 0 },
};

pub const Dag = struct {
    arena: std.mem.Allocator,
    nodes: []Node,
    edges: []const Edge,

    /// Derive the graph from a log.
    ///
    /// One forward pass. A map from path to "who wrote it last" is carried
    /// along, which is what makes data-flow edges linear rather than a search
    /// back through the log for every read.
    pub fn build(arena: std.mem.Allocator, log: log_mod.Log) !Dag {
        const entries = log.entries.items;
        var nodes = try arena.alloc(Node, entries.len);
        for (entries, 0..) |entry, i| {
            nodes[i] = .{ .envelope = entry, .cost = costOf(entry) };
        }

        var index_of: std.AutoArrayHashMapUnmanaged([16]u8, usize) = .empty;
        for (entries, 0..) |entry, i| try index_of.put(arena, entry.id.raw.bytes, i);

        // The last writer of each path, and the event that opened each block.
        var last_writer: std.StringArrayHashMapUnmanaged(usize) = .empty;
        var block_start: std.AutoArrayHashMapUnmanaged([16]u8, usize) = .empty;

        var edges: std.ArrayList(Edge) = .empty;

        for (entries, 0..) |entry, i| {
            if (entry.causedBy) |cause| {
                if (index_of.get(cause.raw.bytes)) |from| {
                    if (from < i) try edges.append(arena, .{ .from = from, .to = i, .kind = .caused });
                }
            }

            switch (entry.payload) {
                .command_submitted => |e| try block_start.put(arena, e.block.raw.bytes, i),
                .process_output => |e| {
                    if (block_start.get(e.block.raw.bytes)) |from| {
                        if (from < i) try edges.append(arena, .{ .from = from, .to = i, .kind = .sequence });
                    }
                },
                .command_finished => |e| {
                    if (block_start.get(e.block.raw.bytes)) |from| {
                        if (from < i) try edges.append(arena, .{ .from = from, .to = i, .kind = .sequence });
                    }
                },
                .file_changed => |e| {
                    // A read of the previous contents, then a new writer. The
                    // order matters: a change that reads and then replaces
                    // depends on what was there, and becomes what the next
                    // reader depends on.
                    if (last_writer.get(e.path)) |from| {
                        if (from < i) try edges.append(arena, .{
                            .from = from,
                            .to = i,
                            .kind = .data,
                            .through = e.path,
                        });
                    }
                    if (e.changeKind != .deleted) {
                        try last_writer.put(arena, e.path, i);
                    } else {
                        _ = last_writer.swapRemove(e.path);
                    }
                },
                .file_opened => |e| {
                    if (last_writer.get(e.path)) |from| {
                        if (from < i) try edges.append(arena, .{
                            .from = from,
                            .to = i,
                            .kind = .data,
                            .through = e.path,
                        });
                    }
                },
                .diagnostic => |e| {
                    // A diagnostic is about a file, so it depends on whoever
                    // last wrote it. This is what connects a compiler error to
                    // the change that caused it.
                    if (last_writer.get(e.path)) |from| {
                        if (from < i) try edges.append(arena, .{
                            .from = from,
                            .to = i,
                            .kind = .data,
                            .through = e.path,
                        });
                    }
                },
                else => {},
            }
        }

        // Fill the adjacency lists in two counting passes, so the whole build
        // is linear and allocates once per direction rather than per node.
        var out_counts = try arena.alloc(usize, entries.len);
        var in_counts = try arena.alloc(usize, entries.len);
        @memset(out_counts, 0);
        @memset(in_counts, 0);
        for (edges.items) |edge| {
            out_counts[edge.from] += 1;
            in_counts[edge.to] += 1;
        }

        const out_storage = try arena.alloc(usize, edges.items.len);
        const in_storage = try arena.alloc(usize, edges.items.len);
        var out_at = try arena.alloc(usize, entries.len);
        var in_at = try arena.alloc(usize, entries.len);
        var running_out: usize = 0;
        var running_in: usize = 0;
        for (0..entries.len) |i| {
            out_at[i] = running_out;
            in_at[i] = running_in;
            running_out += out_counts[i];
            running_in += in_counts[i];
        }
        var out_filled = try arena.alloc(usize, entries.len);
        var in_filled = try arena.alloc(usize, entries.len);
        @memset(out_filled, 0);
        @memset(in_filled, 0);
        for (edges.items, 0..) |edge, e| {
            out_storage[out_at[edge.from] + out_filled[edge.from]] = e;
            out_filled[edge.from] += 1;
            in_storage[in_at[edge.to] + in_filled[edge.to]] = e;
            in_filled[edge.to] += 1;
        }
        for (0..entries.len) |i| {
            nodes[i].out = out_storage[out_at[i] .. out_at[i] + out_counts[i]];
            nodes[i].in = in_storage[in_at[i] .. in_at[i] + in_counts[i]];
        }

        return .{ .arena = arena, .nodes = nodes, .edges = edges.items };
    }

    /// Every edge points forwards. See the note at the top of this file: it is
    /// the property everything else here depends on.
    pub fn isTopological(self: Dag) bool {
        for (self.edges) |edge| {
            if (edge.from >= edge.to) return false;
        }
        return true;
    }

    /// What this event went on to affect, directly or not.
    ///
    /// The answer to "I changed this; what did it touch?".
    pub fn affects(self: Dag, index: usize) !std.ArrayList(usize) {
        return self.walk(index, .forwards);
    }

    /// What this event depended on, directly or not.
    ///
    /// The answer to "this failed; what was it built on?".
    pub fn dependsOn(self: Dag, index: usize) !std.ArrayList(usize) {
        return self.walk(index, .backwards);
    }

    const Direction = enum { forwards, backwards };

    fn walk(self: Dag, start: usize, direction: Direction) !std.ArrayList(usize) {
        var seen = try std.DynamicBitSetUnmanaged.initEmpty(self.arena, self.nodes.len);
        var out: std.ArrayList(usize) = .empty;
        var stack: std.ArrayList(usize) = .empty;
        try stack.append(self.arena, start);
        seen.set(start);
        while (stack.pop()) |current| {
            const list = switch (direction) {
                .forwards => self.nodes[current].out,
                .backwards => self.nodes[current].in,
            };
            for (list) |e| {
                const next = switch (direction) {
                    .forwards => self.edges[e].to,
                    .backwards => self.edges[e].from,
                };
                if (seen.isSet(next)) continue;
                seen.set(next);
                try out.append(self.arena, next);
                try stack.append(self.arena, next);
            }
        }
        std.mem.sort(usize, out.items, {}, std.sort.asc(usize));
        return out;
    }

    /// The path through the run that actually determined how long it took.
    ///
    /// Longest path by cost, in one backwards pass. Because every edge points
    /// forwards, a node's longest remaining path is its own cost plus the best
    /// of its successors, and every successor is already final by the time the
    /// node is reached. No search, no memo table beyond one array.
    ///
    /// This is the honest answer to "why was that slow": not the slowest single
    /// step, but the chain that nothing else could overtake.
    pub fn criticalPath(self: Dag) !std.ArrayList(usize) {
        if (self.nodes.len == 0) return .empty;

        const best = try self.arena.alloc(i64, self.nodes.len);
        const next = try self.arena.alloc(?usize, self.nodes.len);

        var i: usize = self.nodes.len;
        while (i > 0) {
            i -= 1;
            var longest: i64 = 0;
            var chosen: ?usize = null;
            for (self.nodes[i].out) |e| {
                const to = self.edges[e].to;
                if (best[to] > longest) {
                    longest = best[to];
                    chosen = to;
                }
            }
            best[i] = self.nodes[i].cost.ns + longest;
            next[i] = chosen;
        }

        var start: usize = 0;
        for (best, 0..) |value, index| {
            if (value > best[start]) start = index;
        }

        var path: std.ArrayList(usize) = .empty;
        var current: ?usize = start;
        while (current) |index| {
            try path.append(self.arena, index);
            current = next[index];
        }
        return path;
    }

    /// How long the critical path takes.
    pub fn criticalPathCost(self: Dag, path: []const usize) timeutil.Duration {
        var total: i64 = 0;
        for (path) |index| total += self.nodes[index].cost.ns;
        return .{ .ns = total };
    }

    /// Say, in words, why one event and another are connected.
    pub fn writeConnection(
        self: Dag,
        from: usize,
        to: usize,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        for (self.nodes[from].out) |e| {
            const edge = self.edges[e];
            if (edge.to != to) continue;
            try w.print("{s} {s} {s}", .{
                self.nodes[from].envelope.payload.kindName(),
                edge.kind.text(),
                self.nodes[to].envelope.payload.kindName(),
            });
            if (edge.through.len > 0) try w.print(", through {s}", .{edge.through});
            return;
        }
        try w.writeAll("nothing connects these two directly");
    }
};

/// How long an event itself took, where the record says.
fn costOf(entry: Envelope) timeutil.Duration {
    return switch (entry.payload) {
        .command_finished => |e| e.duration,
        .tool_finished => |e| e.duration,
        else => .{ .ns = 0 },
    };
}

/// Reachability for a chosen set of events, as bitsets.
///
/// One row per event, one bit per event: row `a` bit `b` is set when `a` can
/// reach `b`. Filled in one backwards pass, taking the union of each
/// successor's row, which the standard library does a machine word at a time.
///
/// Built for a subset rather than a whole log, because the memory is the square
/// of the count. `build` refuses a set it cannot hold rather than trying.
pub const Reach = struct {
    /// The events this was built for, in log order.
    members: []const usize,
    /// Row per member, in the same order.
    rows: []std.DynamicBitSetUnmanaged,
    /// Where each event index sits in `members`.
    position: std.AutoArrayHashMapUnmanaged(usize, usize),

    /// The largest set this will build a closure for.
    ///
    /// At this size the rows come to about 128 MiB, which is a lot but is a
    /// number somebody chose rather than one the machine discovered by running
    /// out. A larger question is answered by `Dag.affects`, one walk at a time.
    pub const max_members = 32_768;

    pub const Error = error{TooManyEvents} || std.mem.Allocator.Error;

    pub fn build(arena: std.mem.Allocator, dag: Dag, members: []const usize) Error!Reach {
        if (members.len > max_members) return error.TooManyEvents;

        var position: std.AutoArrayHashMapUnmanaged(usize, usize) = .empty;
        for (members, 0..) |member, slot| try position.put(arena, member, slot);

        const rows = try arena.alloc(std.DynamicBitSetUnmanaged, members.len);
        for (rows) |*row| row.* = try std.DynamicBitSetUnmanaged.initEmpty(arena, members.len);

        // Backwards, so every successor's row is already complete. `members` is
        // in log order and every edge points forwards, which is the whole
        // reason this is one pass and not a fixed point.
        var slot: usize = members.len;
        while (slot > 0) {
            slot -= 1;
            const node = members[slot];
            for (dag.nodes[node].out) |e| {
                const to = dag.edges[e].to;
                const to_slot = position.get(to) orelse continue;
                rows[slot].set(to_slot);
                rows[slot].setUnion(rows[to_slot]);
            }
        }

        return .{ .members = members, .rows = rows, .position = position };
    }

    /// Can `from` reach `to`?
    pub fn reaches(self: Reach, from: usize, to: usize) bool {
        const a = self.position.get(from) orelse return false;
        const b = self.position.get(to) orelse return false;
        return self.rows[a].isSet(b);
    }

    /// Neither one reaches the other: two pieces of work that could have
    /// happened in either order.
    pub fn concurrent(self: Reach, a: usize, b: usize) bool {
        if (a == b) return false;
        return !self.reaches(a, b) and !self.reaches(b, a);
    }

    /// How many events this one reaches. The blast radius of a change.
    pub fn reachCount(self: Reach, from: usize) usize {
        const slot = self.position.get(from) orelse return 0;
        return self.rows[slot].count();
    }
};

const testing = std.testing;
const idmod = @import("../core/id.zig");

/// A log built by hand, so a test can put events in a chosen relationship.
const Builder = struct {
    arena: std.mem.Allocator,
    log: log_mod.Log,
    ids: idmod.Generator,
    at: i64 = 1_700_000_000 * timeutil.ns_per_s,

    fn init(arena: std.mem.Allocator) Builder {
        return .{
            .arena = arena,
            .log = log_mod.Log.init(arena, 1),
            .ids = idmod.Generator.init(2, 0),
        };
    }

    fn append(
        self: *Builder,
        payload: event_mod.WorkspaceEvent,
        caused_by: ?EventId,
    ) !EventId {
        self.at += timeutil.ns_per_s;
        const envelope = try self.log.append(payload, .{
            .at = .{ .ns = self.at },
            .actor = .{
                .id = self.ids.next(idmod.ActorId),
                .kind = .person,
                .label = "you",
            },
            .causedBy = caused_by,
        });
        return envelope.id;
    }

    fn session(self: *Builder) idmod.SessionId {
        return self.ids.next(idmod.SessionId);
    }
};

test "a read depends on the last write of that file, and nothing earlier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const session = builder.session();

    // Two writes to one file, then a read. The read depends on the second
    // write only: the first was already replaced.
    _ = try builder.append(.{ .file_changed = .{
        .session = session,
        .path = "src/a.zig",
        .changeKind = .created,
    } }, null);
    _ = try builder.append(.{ .file_changed = .{
        .session = session,
        .path = "src/a.zig",
        .changeKind = .modified,
    } }, null);
    _ = try builder.append(.{ .file_opened = .{
        .session = session,
        .path = "src/a.zig",
        .contentHash = .zero,
    } }, null);

    const dag = try Dag.build(arena, builder.log);
    try testing.expect(dag.isTopological());

    // The reader depends on the second write, and reaches back to the first
    // through it, but has no direct edge to the first.
    const depends = try dag.dependsOn(2);
    try testing.expectEqual(@as(usize, 2), depends.items.len);
    try testing.expectEqual(@as(usize, 0), depends.items[0]);
    try testing.expectEqual(@as(usize, 1), depends.items[1]);

    var direct: usize = 0;
    for (dag.nodes[2].in) |e| {
        try testing.expectEqual(@as(usize, 1), dag.edges[e].from);
        direct += 1;
    }
    try testing.expectEqual(@as(usize, 1), direct);
}

test "a file that was deleted is not something a later read depends on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const session = builder.session();

    _ = try builder.append(.{ .file_changed = .{
        .session = session,
        .path = "gone.txt",
        .changeKind = .created,
    } }, null);
    _ = try builder.append(.{ .file_changed = .{
        .session = session,
        .path = "gone.txt",
        .changeKind = .deleted,
    } }, null);
    _ = try builder.append(.{ .file_opened = .{
        .session = session,
        .path = "gone.txt",
        .contentHash = .zero,
    } }, null);

    const dag = try Dag.build(arena, builder.log);
    // The delete depends on the create. The read that follows depends on
    // nothing, because there is nothing there to depend on: whatever it read,
    // this record does not say it came from here.
    try testing.expectEqual(@as(usize, 0), dag.nodes[2].in.len);
    try testing.expectEqual(@as(usize, 1), dag.nodes[1].in.len);
}

test "a diagnostic points back at the change that produced the file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const session = builder.session();

    _ = try builder.append(.{ .file_changed = .{
        .session = session,
        .path = "src/broken.zig",
        .changeKind = .modified,
    } }, null);
    _ = try builder.append(.{ .diagnostic = .{
        .session = session,
        .path = "src/broken.zig",
        .line = 12,
        .column = 3,
        .severity = .@"error",
        .source = "zig",
        .message = "expected type",
    } }, null);

    const dag = try Dag.build(arena, builder.log);
    const blame = try dag.dependsOn(1);
    try testing.expectEqual(@as(usize, 1), blame.items.len);
    try testing.expectEqual(@as(usize, 0), blame.items[0]);

    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try dag.writeConnection(0, 1, &w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "through src/broken.zig") != null);
}

test "work in two sessions is joined by the file that passed between them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const morning = builder.session();
    const afternoon = builder.session();

    // Nothing causes anything here: two separate sessions, hours apart. The
    // only thing joining them is the file, which is exactly the case the
    // causal forest cannot answer and this graph can.
    _ = try builder.append(.{ .file_changed = .{
        .session = morning,
        .path = "src/parser.zig",
        .changeKind = .modified,
    } }, null);
    _ = try builder.append(.{ .file_opened = .{
        .session = afternoon,
        .path = "src/parser.zig",
        .contentHash = .zero,
    } }, null);

    const dag = try Dag.build(arena, builder.log);
    const affected = try dag.affects(0);
    try testing.expectEqual(@as(usize, 1), affected.items.len);
    try testing.expectEqual(@as(usize, 1), affected.items[0]);

    // The causal graph, correctly, sees no relationship at all. The two graphs
    // answer different questions and neither replaces the other.
    const causal = try graph_mod.Graph.build(arena, builder.log);
    try testing.expect(!causal.causedBy(1, 0));
}

test "output and completion belong to the command that produced them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const session = builder.session();
    const block = builder.ids.next(idmod.BlockId);

    _ = try builder.append(.{ .command_submitted = .{
        .block = block,
        .session = session,
        .commandText = "zig build test",
        .workingDirectory = "/repo",
    } }, null);
    _ = try builder.append(.{ .process_output = .{
        .block = block,
        .session = session,
        .contentHash = .zero,
        .byteCount = 40,
    } }, null);
    _ = try builder.append(.{ .command_finished = .{
        .block = block,
        .session = session,
        .exitStatus = 1,
        .duration = .{ .ns = 4 * timeutil.ns_per_s },
    } }, null);

    const dag = try Dag.build(arena, builder.log);
    const affected = try dag.affects(0);
    try testing.expectEqual(@as(usize, 2), affected.items.len);
}

test "the critical path is the chain nothing could overtake" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const session = builder.session();

    // One command that leads to a slow one, and a fast one alongside it that
    // is not on the path even though it happened in between.
    const first = builder.ids.next(idmod.BlockId);
    const slow = builder.ids.next(idmod.BlockId);
    const quick = builder.ids.next(idmod.BlockId);

    const start = try builder.append(.{ .command_submitted = .{
        .block = first,
        .session = session,
        .commandText = "generate",
        .workingDirectory = "/repo",
    } }, null);
    _ = try builder.append(.{ .command_finished = .{
        .block = first,
        .session = session,
        .exitStatus = 0,
        .duration = .{ .ns = 1 * timeutil.ns_per_s },
    } }, null);
    _ = try builder.append(.{ .command_submitted = .{
        .block = quick,
        .session = session,
        .commandText = "fmt",
        .workingDirectory = "/repo",
    } }, start);
    _ = try builder.append(.{ .command_finished = .{
        .block = quick,
        .session = session,
        .exitStatus = 0,
        .duration = .{ .ns = 2 * timeutil.ns_per_s },
    } }, null);
    _ = try builder.append(.{ .command_submitted = .{
        .block = slow,
        .session = session,
        .commandText = "build",
        .workingDirectory = "/repo",
    } }, start);
    _ = try builder.append(.{ .command_finished = .{
        .block = slow,
        .session = session,
        .exitStatus = 0,
        .duration = .{ .ns = 30 * timeutil.ns_per_s },
    } }, null);

    const dag = try Dag.build(arena, builder.log);
    const path = try dag.criticalPath();
    const cost = dag.criticalPathCost(path.items);

    // Thirty seconds, not thirty-three. The first command's own one second and
    // the two seconds of formatting are branches off the start, not steps
    // before the build, so nothing waited for them. That is the difference
    // between a critical path and a total, and it is the reason to compute one.
    try testing.expectEqual(@as(i64, 30 * timeutil.ns_per_s), cost.ns);
    try testing.expectEqual(@as(usize, 3), path.items.len);
    try testing.expectEqual(@as(usize, 0), path.items[0]);
    try testing.expectEqual(@as(usize, 4), path.items[1]);
    try testing.expectEqual(@as(usize, 5), path.items[2]);

    // The formatting command is not on it, even though it took two seconds and
    // happened in the middle of the run.
    for (path.items) |index| try testing.expect(index != 3);
}

test "reachability answers about every pair at once, and says what is concurrent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const session = builder.session();

    // a.zig is changed, then read. b.zig is changed separately and never read.
    // The two lines of work are concurrent: neither reaches the other.
    _ = try builder.append(.{ .file_changed = .{
        .session = session,
        .path = "a.zig",
        .changeKind = .modified,
    } }, null);
    _ = try builder.append(.{ .file_changed = .{
        .session = session,
        .path = "b.zig",
        .changeKind = .modified,
    } }, null);
    _ = try builder.append(.{ .file_opened = .{
        .session = session,
        .path = "a.zig",
        .contentHash = .zero,
    } }, null);

    const dag = try Dag.build(arena, builder.log);
    const members = try arena.dupe(usize, &.{ 0, 1, 2 });
    const reach = try Reach.build(arena, dag, members);

    try testing.expect(reach.reaches(0, 2));
    try testing.expect(!reach.reaches(2, 0));
    try testing.expect(reach.concurrent(1, 0));
    try testing.expect(reach.concurrent(1, 2));
    try testing.expectEqual(@as(usize, 1), reach.reachCount(0));
    try testing.expectEqual(@as(usize, 0), reach.reachCount(1));
}

test "reachability refuses a set too large to hold rather than trying" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const builder = Builder.init(arena);
    const dag = try Dag.build(arena, builder.log);

    const members = try arena.alloc(usize, Reach.max_members + 1);
    @memset(members, 0);
    try testing.expectError(error.TooManyEvents, Reach.build(arena, dag, members));
}

test "reachability agrees with walking, on a chain long enough to tell" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = Builder.init(arena);
    const session = builder.session();

    // A chain of a hundred writes and reads of the same file. Every event
    // reaches every later one.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = try builder.append(.{ .file_changed = .{
            .session = session,
            .path = "chain.txt",
            .changeKind = .modified,
        } }, null);
    }

    const dag = try Dag.build(arena, builder.log);
    try testing.expect(dag.isTopological());

    const members = try arena.alloc(usize, 100);
    for (members, 0..) |*member, index| member.* = index;
    const reach = try Reach.build(arena, dag, members);

    // The two ways of asking must give the same answer, or one of them is
    // wrong and there is no way to tell which from either alone.
    const walked = try dag.affects(0);
    try testing.expectEqual(@as(usize, 99), walked.items.len);
    try testing.expectEqual(@as(usize, 99), reach.reachCount(0));
    for (walked.items) |target| {
        try testing.expect(reach.reaches(0, target));
    }
    try testing.expectEqual(@as(usize, 0), reach.reachCount(99));
}
