//! Explicit recovery for a damaged workspace event log.
//!
//! Opening a workspace never repairs evidence. This module instead separates
//! inspection from mutation, keeps the exact original bytes under their
//! BLAKE3-256 address, checks the locked source twice, and truncates only at a
//! byte boundary produced by the original decoder. The caller must make the
//! approval decision; this code cannot infer consent from a damaged file.

const std = @import("std");
const hashing = @import("../core/hash.zig");
const log_mod = @import("log.zig");
const content_store = @import("content_store.zig");

pub const max_log_bytes: usize = log_mod.max_file_bytes;
pub const recovery_directory = ".workspace/recovery";

pub const Error = error{
    LogChanged,
    LogHealthy,
    EvidenceConflict,
    RecoveryVerificationFailed,
};

pub const Plan = struct {
    source_exists: bool,
    source_path: []const u8,
    evidence_path: []const u8,
    original_hash: hashing.Hash,
    original_bytes: usize,
    kept_bytes: usize,
    removed_bytes: usize,
    kept_events: usize,
    chain_break: ?log_mod.Break,
    torn_bytes: usize,
    malformed: ?log_mod.DecodeIssue,

    pub fn needsRecovery(self: Plan) bool {
        return self.chain_break != null or self.torn_bytes > 0 or self.malformed != null;
    }
};

/// Read and classify a log without changing it.
pub fn inspect(arena: std.mem.Allocator, io: std.Io, root: []const u8) !Plan {
    const source_path = try std.fmt.allocPrint(arena, "{s}/.workspace/events.jsonl", .{root});
    var file = std.Io.Dir.cwd().openFile(io, source_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            var plan = try inspectBytes(arena, source_path, "");
            plan.source_exists = false;
            return plan;
        },
        else => |open_err| return open_err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > max_log_bytes) return error.StreamTooLong;
    const source = try readLocked(arena, io, file, @intCast(stat.size));
    return inspectBytes(arena, source_path, source);
}

fn inspectBytes(arena: std.mem.Allocator, source_path: []const u8, source: []const u8) !Plan {
    const loaded = try log_mod.Log.loadJsonLines(arena, source, 1);
    const chain_break = try loaded.log.verify();
    const kept_events = if (chain_break) |broken| broken.index else loaded.recovered;
    const kept_bytes = if (kept_events == 0) 0 else loaded.entry_ends[kept_events - 1];
    const original_hash = hashing.Hash.of(source);
    var hash_buffer: [hashing.Hash.text_len]u8 = undefined;
    const hash_body = original_hash.toText(&hash_buffer)[3..];
    const parent = std.fs.path.dirname(source_path) orelse ".";
    const evidence_path = try std.fmt.allocPrint(arena, "{s}/recovery/events.{s}.jsonl", .{ parent, hash_body });
    return .{
        .source_exists = true,
        .source_path = source_path,
        .evidence_path = evidence_path,
        .original_hash = original_hash,
        .original_bytes = source.len,
        .kept_bytes = if (chain_break == null and loaded.torn_bytes == 0 and loaded.malformed == null) source.len else kept_bytes,
        .removed_bytes = if (chain_break == null and loaded.torn_bytes == 0 and loaded.malformed == null) 0 else source.len - kept_bytes,
        .kept_events = kept_events,
        .chain_break = chain_break,
        .torn_bytes = loaded.torn_bytes,
        .malformed = loaded.malformed,
    };
}

/// Apply a previously inspected plan. The exact original bytes are copied to
/// `evidence_path` before the source is shortened. A stale plan is rejected.
pub fn apply(arena: std.mem.Allocator, io: std.Io, plan: Plan) !void {
    if (!plan.needsRecovery()) return error.LogHealthy;

    var cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, plan.source_path, .{
        .mode = .read_write,
        .allow_directory = false,
        .lock = .exclusive,
        .follow_symlinks = false,
    });
    defer file.close(io);

    const source = try readLocked(arena, io, file, plan.original_bytes);
    if (!hashing.Hash.of(source).eql(plan.original_hash)) return error.LogChanged;
    const locked_plan = try inspectBytes(arena, plan.source_path, source);
    if (locked_plan.kept_bytes != plan.kept_bytes or locked_plan.kept_events != plan.kept_events) {
        return error.LogChanged;
    }

    const recovery_parent = std.fs.path.dirname(plan.evidence_path) orelse return error.EvidenceConflict;
    _ = try cwd.createDirPathStatus(io, recovery_parent, content_store.private_directory_permissions);
    try preserveEvidence(arena, io, plan.evidence_path, source, plan.original_hash);

    // Re-read after writing the evidence copy. Advisory locks coordinate zag
    // writers; this second comparison also catches a non-cooperating change in
    // the interval before truncation.
    const before_truncate = try readLocked(arena, io, file, plan.original_bytes);
    if (!hashing.Hash.of(before_truncate).eql(plan.original_hash)) return error.LogChanged;

    try file.setLength(io, plan.kept_bytes);
    try file.sync(io);

    const recovered = try readLocked(arena, io, file, plan.kept_bytes);
    const verified = try inspectBytes(arena, plan.source_path, recovered);
    if (verified.needsRecovery() or verified.original_bytes != plan.kept_bytes) {
        return error.RecoveryVerificationFailed;
    }
}

fn readLocked(arena: std.mem.Allocator, io: std.Io, file: std.Io.File, expected_size: usize) ![]const u8 {
    const stat = try file.stat(io);
    if (stat.size != expected_size or stat.size > max_log_bytes) return error.LogChanged;
    const bytes = try arena.alloc(u8, expected_size);
    const count = try file.readPositionalAll(io, bytes, 0);
    if (count != bytes.len) return error.LogChanged;
    if ((try file.stat(io)).size != expected_size) return error.LogChanged;
    return bytes;
}

fn preserveEvidence(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    source: []const u8,
    expected_hash: hashing.Hash,
) !void {
    var cwd = std.Io.Dir.cwd();
    if (try evidenceMatches(arena, io, path, source.len, expected_hash)) return;

    var atomic = try cwd.createFileAtomic(io, path, .{
        .permissions = content_store.private_file_permissions,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, source);
    try atomic.file.sync(io);
    atomic.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if (!try evidenceMatches(arena, io, path, source.len, expected_hash)) {
                return error.EvidenceConflict;
            }
        },
        else => |e| return e,
    };
}

fn evidenceMatches(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    expected_size: usize,
    expected_hash: hashing.Hash,
) !bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size != expected_size or stat.size > max_log_bytes) return error.EvidenceConflict;
    const contents = try arena.alloc(u8, expected_size);
    const count = try file.readPositionalAll(io, contents, 0);
    if (count != contents.len or (try file.stat(io)).size != stat.size) return error.EvidenceConflict;
    if (!hashing.Hash.of(contents).eql(expected_hash)) return error.EvidenceConflict;
    return true;
}

const testing = std.testing;

fn testActor(gen: *@import("../core/id.zig").Generator) log_mod.Actor {
    return .{ .id = gen.next(@import("../core/id.zig").ActorId), .kind = .person, .label = "tester" };
}

test "inspection treats an absent event log as healthy and creates nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const plan = try inspect(arena, io, root);
    try testing.expect(!plan.source_exists);
    try testing.expect(!plan.needsRecovery());
    try testing.expectEqual(@as(usize, 0), plan.original_bytes);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, plan.source_path, .{}));
}

test "recovery preserves exact evidence then truncates to a verified boundary" {
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
    try std.Io.Dir.cwd().createDirPath(io, workspace);

    var gen: @import("../core/id.zig").Generator = .init(81, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 82);
    const actor = testActor(&gen);
    const session = gen.next(@import("../core/id.zig").SessionId);
    const at = try @import("../core/time.zig").Timestamp.parseIso("2026-09-05T12:00:00Z");
    _ = try log.append(.{ .session_opened = .{ .session = session, .workingDirectory = root } }, .{ .at = at, .actor = actor });
    _ = try log.append(.{ .user_message = .{ .session = session, .text = "keep this" } }, .{ .at = at, .actor = actor });
    var encoded: std.Io.Writer.Allocating = .init(arena);
    try log.writeJsonLines(&encoded.writer);
    const complete = encoded.written();
    const damaged = try std.fmt.allocPrint(arena, "{s}{{torn", .{complete});
    const source_path = try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{workspace});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = damaged });

    const plan = try inspect(arena, io, root);
    try testing.expect(plan.needsRecovery());
    try testing.expectEqual(@as(usize, 2), plan.kept_events);
    try testing.expectEqual(complete.len, plan.kept_bytes);
    try testing.expectEqual(@as(usize, 5), plan.removed_bytes);
    try apply(arena, io, plan);

    const recovered = try std.Io.Dir.cwd().readFileAlloc(io, source_path, arena, .limited(max_log_bytes));
    try testing.expectEqualStrings(complete, recovered);
    const evidence = try std.Io.Dir.cwd().readFileAlloc(io, plan.evidence_path, arena, .limited(max_log_bytes));
    try testing.expectEqualStrings(damaged, evidence);
    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        var evidence_file = try std.Io.Dir.cwd().openFile(io, plan.evidence_path, .{});
        defer evidence_file.close(io);
        try testing.expect((try evidence_file.stat(io)).permissions.toMode() & 0o077 == 0);

        const evidence_parent = std.fs.path.dirname(plan.evidence_path).?;
        var evidence_dir = try std.Io.Dir.cwd().openDir(io, evidence_parent, .{});
        defer evidence_dir.close(io);
        try testing.expect((try evidence_dir.stat(io)).permissions.toMode() & 0o077 == 0);
    }
    try testing.expect(!(try inspect(arena, io, root)).needsRecovery());
}

test "recovery rejects a stale plan before changing the log" {
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
    try std.Io.Dir.cwd().createDirPath(io, workspace);
    const source_path = try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{workspace});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = "broken" });
    const plan = try inspect(arena, io, root);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = "changed" });

    try testing.expectError(error.LogChanged, apply(arena, io, plan));
    const source = try std.Io.Dir.cwd().readFileAlloc(io, source_path, arena, .limited(max_log_bytes));
    try testing.expectEqualStrings("changed", source);
}

test "recovery never replaces conflicting evidence" {
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
    try std.Io.Dir.cwd().createDirPath(io, workspace);
    const source_path = try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{workspace});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = "torn" });
    const plan = try inspect(arena, io, root);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(plan.evidence_path).?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = plan.evidence_path, .data = "other" });

    try testing.expectError(error.EvidenceConflict, apply(arena, io, plan));
    try testing.expectEqualStrings("torn", try std.Io.Dir.cwd().readFileAlloc(io, source_path, arena, .limited(16)));
    try testing.expectEqualStrings("other", try std.Io.Dir.cwd().readFileAlloc(io, plan.evidence_path, arena, .limited(16)));
}

test "recovery inspection never follows an event-log symbolic link" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

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
    try std.Io.Dir.cwd().createDirPath(io, workspace);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/outside", .{root}),
        .data = "outside bytes",
    });
    try std.Io.Dir.cwd().symLink(io, "../outside", try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{workspace}), .{});

    try testing.expectError(error.SymLinkLoop, inspect(arena, io, root));
}

test "a chain break keeps only events before the first broken entry" {
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
    try std.Io.Dir.cwd().createDirPath(io, workspace);

    var gen: @import("../core/id.zig").Generator = .init(83, 1_788_000_000_000);
    var log = log_mod.Log.init(arena, 84);
    const actor = testActor(&gen);
    const session = gen.next(@import("../core/id.zig").SessionId);
    const at = try @import("../core/time.zig").Timestamp.parseIso("2026-09-05T12:00:00Z");
    _ = try log.append(.{ .session_opened = .{ .session = session, .workingDirectory = root } }, .{ .at = at, .actor = actor });
    _ = try log.append(.{ .user_message = .{ .session = session, .text = "original" } }, .{ .at = at, .actor = actor });
    log.entries.items[1].payload = .{ .user_message = .{ .session = session, .text = "tampered" } };
    var encoded: std.Io.Writer.Allocating = .init(arena);
    try log.writeJsonLines(&encoded.writer);
    const source_path = try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{workspace});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = encoded.written() });

    const loaded = try log_mod.Log.loadJsonLines(arena, encoded.written(), 1);
    const first_event_end = loaded.entry_ends[0];
    const plan = try inspect(arena, io, root);
    try testing.expect(plan.chain_break != null);
    try testing.expectEqual(@as(usize, 1), plan.kept_events);
    try testing.expectEqual(first_event_end, plan.kept_bytes);
    try apply(arena, io, plan);

    const recovered = try std.Io.Dir.cwd().readFileAlloc(io, source_path, arena, .limited(max_log_bytes));
    try testing.expectEqualStrings(encoded.written()[0..first_event_end], recovered);
    try testing.expect(!(try inspect(arena, io, root)).needsRecovery());
}
