//! Immutable storage for bytes referenced by workspace events.
//!
//! The event log carries a BLAKE3-256 digest instead of copying command output
//! into every projection. This store makes that reference real. It writes an
//! object before the event log can point to it, never replaces an existing
//! object, and verifies bytes again when they are read. A crash may leave an
//! unreferenced object, but it cannot leave a committed event that points to a
//! partially replaced object.

const std = @import("std");
const hashing = @import("../core/hash.zig");

pub const Hash = hashing.Hash;

pub const max_blob_bytes: usize = 64 * 1024 * 1024;
pub const objects_directory = ".workspace/objects/b3";
pub const private_file_permissions: std.Io.File.Permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
    std.Io.File.Permissions.fromMode(0o600)
else
    .default_file;
pub const private_directory_permissions: std.Io.File.Permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
    std.Io.File.Permissions.fromMode(0o700)
else
    .default_dir;

pub const Error = error{
    ContentMissing,
    ContentMismatch,
    ContentTooLarge,
    HashCollision,
    UnsafeObject,
};

/// One object whose canonical address was found in the store.
pub const Object = struct {
    hash: Hash,
    path: []const u8,
};

/// A content address and the byte count recorded by the event that refers to
/// it. Both values are part of replay integrity.
pub const Reference = struct {
    hash: Hash,
    byte_count: usize,
};

pub const SizeMismatch = struct {
    hash: Hash,
    expected_bytes: usize,
    actual_bytes: usize,
};

/// The result of inspecting the entire content store without changing it.
/// Missing and changed objects break replay. Unreferenced objects are retained
/// because they can be crash evidence, and unexpected entries are never
/// followed as though they were valid content.
pub const AuditReport = struct {
    references: usize,
    objects: usize,
    missing: []const Hash,
    changed: []const Object,
    size_mismatches: []const SizeMismatch,
    unreferenced: []const Object,
    unexpected: []const []const u8,

    pub fn issueCount(self: AuditReport) usize {
        return self.missing.len + self.changed.len + self.size_mismatches.len + self.unreferenced.len + self.unexpected.len;
    }

    pub fn isHealthy(self: AuditReport) bool {
        return self.issueCount() == 0;
    }
};

const Blob = struct {
    hash: Hash,
    bytes: []const u8,
};

const ExpectedObject = struct {
    hash: Hash,
    byte_counts: std.ArrayList(usize) = .empty,
    seen: bool = false,
};

pub const Store = struct {
    arena: std.mem.Allocator,
    root: []const u8,
    pending: std.ArrayList(Blob) = .empty,

    pub fn init(arena: std.mem.Allocator, root: []const u8) Store {
        return .{ .arena = arena, .root = root };
    }

    /// Stage bytes for durable storage and return their stable address.
    pub fn put(self: *Store, bytes: []const u8) !Hash {
        if (bytes.len > max_blob_bytes) return error.ContentTooLarge;
        const hash = Hash.of(bytes);
        for (self.pending.items) |blob| {
            if (!blob.hash.eql(hash)) continue;
            if (!std.mem.eql(u8, blob.bytes, bytes)) return error.HashCollision;
            return hash;
        }
        try self.pending.append(self.arena, .{
            .hash = hash,
            .bytes = try self.arena.dupe(u8, bytes),
        });
        return hash;
    }

    pub fn hasPending(self: Store) bool {
        return self.pending.items.len > 0;
    }

    /// Materialise every staged object. Existing objects are reused only after
    /// their bytes are checked against their address.
    pub fn flush(self: *Store, io: std.Io) !void {
        var cwd = std.Io.Dir.cwd();
        for (self.pending.items) |blob| {
            const path = try self.objectPath(blob.hash);
            if (try verifyIfPresent(io, path, blob.hash, blob.bytes.len)) continue;

            const parent = std.fs.path.dirname(path) orelse return error.ContentMissing;
            _ = try cwd.createDirPathStatus(io, parent, private_directory_permissions);

            var atomic = try cwd.createFileAtomic(io, path, .{
                .permissions = private_file_permissions,
            });
            defer atomic.deinit(io);
            try atomic.file.writeStreamingAll(io, blob.bytes);
            try atomic.file.sync(io);
            atomic.link(io) catch |err| switch (err) {
                // Another writer won the race. Its object is acceptable only
                // when it has the same address and byte count.
                error.PathAlreadyExists => {
                    if (!try verifyIfPresent(io, path, blob.hash, blob.bytes.len)) {
                        return error.ContentMissing;
                    }
                },
                else => |e| return e,
            };
        }
        self.pending.clearRetainingCapacity();
    }

    /// Read and verify one object. The returned bytes belong to this store's
    /// allocator.
    pub fn read(self: Store, io: std.Io, hash: Hash, limit: usize) ![]const u8 {
        const path = try self.objectPath(hash);
        const cap = @min(limit, max_blob_bytes);
        const bytes = readNoFollow(self.arena, io, path, cap) catch |err| switch (err) {
            error.FileNotFound => return error.ContentMissing,
            error.SymLinkLoop, error.IsDir => return error.UnsafeObject,
            else => |e| return e,
        };
        if (!Hash.of(bytes).eql(hash)) return error.ContentMismatch;
        return bytes;
    }

    /// Inspect every canonical object and compare it with the unique hashes
    /// referenced by the verified event-log prefix. This function never
    /// deletes or rewrites an entry.
    pub fn audit(self: Store, io: std.Io, references: []const Reference) !AuditReport {
        var expected: std.ArrayList(ExpectedObject) = .empty;
        var expected_by_hash = std.AutoHashMap(Hash, usize).init(self.arena);
        for (references) |reference| {
            const index = expected_by_hash.get(reference.hash) orelse blk: {
                const next = expected.items.len;
                try expected.append(self.arena, .{ .hash = reference.hash });
                try expected_by_hash.put(reference.hash, next);
                break :blk next;
            };
            var counts = &expected.items[index].byte_counts;
            if (std.mem.indexOfScalar(usize, counts.items, reference.byte_count) == null) {
                try counts.append(self.arena, reference.byte_count);
            }
        }

        var changed: std.ArrayList(Object) = .empty;
        var size_mismatches: std.ArrayList(SizeMismatch) = .empty;
        var unreferenced: std.ArrayList(Object) = .empty;
        var unexpected: std.ArrayList([]const u8) = .empty;
        var object_count: usize = 0;

        const root_path = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ self.root, objects_directory });
        var root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return .{
                .references = expected.items.len,
                .objects = 0,
                .missing = try expectedHashes(self.arena, expected.items),
                .changed = &.{},
                .size_mismatches = &.{},
                .unreferenced = &.{},
                .unexpected = &.{},
            },
            else => |e| return e,
        };
        defer root_dir.close(io);

        var buckets = root_dir.iterate();
        while (try buckets.next(io)) |bucket| {
            const bucket_path = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ root_path, bucket.name });
            if (bucket.kind != .directory or !isLowerHex(bucket.name, 2)) {
                try unexpected.append(self.arena, bucket_path);
                continue;
            }

            var bucket_dir = try root_dir.openDir(io, bucket.name, .{
                .iterate = true,
                .follow_symlinks = false,
            });
            defer bucket_dir.close(io);
            var entries = bucket_dir.iterate();
            while (try entries.next(io)) |entry| {
                const path = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ bucket_path, entry.name });
                if (entry.kind != .file or !isLowerHex(entry.name, 62)) {
                    try unexpected.append(self.arena, path);
                    continue;
                }

                var hash_text: [64]u8 = undefined;
                @memcpy(hash_text[0..2], bucket.name);
                @memcpy(hash_text[2..], entry.name);
                const hash = Hash.parse(&hash_text) catch {
                    try unexpected.append(self.arena, path);
                    continue;
                };
                object_count += 1;

                const reference_index = expected_by_hash.get(hash);
                if (reference_index) |index| {
                    expected.items[index].seen = true;
                } else {
                    try unreferenced.append(self.arena, .{ .hash = hash, .path = path });
                }

                const digest = digestNoFollow(io, path, max_blob_bytes) catch |err| switch (err) {
                    error.ContentTooLarge, error.ContentMismatch => {
                        try changed.append(self.arena, .{ .hash = hash, .path = path });
                        continue;
                    },
                    else => |e| return e,
                };
                if (!digest.hash.eql(hash)) {
                    try changed.append(self.arena, .{ .hash = hash, .path = path });
                } else if (reference_index) |index| {
                    for (expected.items[index].byte_counts.items) |byte_count| {
                        if (byte_count != digest.size) {
                            try size_mismatches.append(self.arena, .{
                                .hash = hash,
                                .expected_bytes = byte_count,
                                .actual_bytes = digest.size,
                            });
                        }
                    }
                }
            }
        }

        var missing: std.ArrayList(Hash) = .empty;
        for (expected.items) |item| {
            if (!item.seen) try missing.append(self.arena, item.hash);
        }
        return .{
            .references = expected.items.len,
            .objects = object_count,
            .missing = missing.items,
            .changed = changed.items,
            .size_mismatches = size_mismatches.items,
            .unreferenced = unreferenced.items,
            .unexpected = unexpected.items,
        };
    }

    pub fn objectPath(self: Store, hash: Hash) ![]const u8 {
        var text_buffer: [Hash.text_len]u8 = undefined;
        const body = hash.toText(&text_buffer)[3..];
        return std.fmt.allocPrint(self.arena, "{s}/{s}/{s}/{s}", .{
            self.root,
            objects_directory,
            body[0..2],
            body[2..],
        });
    }
};

fn expectedHashes(arena: std.mem.Allocator, expected: []const ExpectedObject) ![]const Hash {
    const hashes = try arena.alloc(Hash, expected.len);
    for (expected, hashes) |item, *hash| {
        hash.* = item.hash;
    }
    return hashes;
}

fn isLowerHex(text: []const u8, expected_length: usize) bool {
    if (text.len != expected_length) return false;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn verifyIfPresent(
    io: std.Io,
    path: []const u8,
    expected_hash: Hash,
    expected_size: usize,
) !bool {
    const digest = digestNoFollow(io, path, max_blob_bytes) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.SymLinkLoop, error.IsDir => return error.UnsafeObject,
        else => |e| return e,
    };
    if (digest.size != expected_size or !digest.hash.eql(expected_hash)) {
        return error.ContentMismatch;
    }
    return true;
}

const FileDigest = struct {
    hash: Hash,
    size: usize,
};

/// Hash a file in fixed-size chunks so a whole-store audit uses constant
/// working memory even when it inspects many large objects.
fn digestNoFollow(io: std.Io, path: []const u8, limit: usize) !FileDigest {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > limit) return error.ContentTooLarge;

    var hasher = std.crypto.hash.Blake3.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const count: usize = @intCast(@min(buffer.len, stat.size - offset));
        const read_count = try file.readPositionalAll(io, buffer[0..count], offset);
        if (read_count != count) return error.ContentMismatch;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    if ((try file.stat(io)).size != stat.size) return error.ContentMismatch;
    var hash: Hash = undefined;
    hasher.final(&hash.bytes);
    return .{ .hash = hash, .size = @intCast(stat.size) };
}

fn readNoFollow(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limit: usize,
) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > limit) return error.ContentTooLarge;
    const bytes = try arena.alloc(u8, @intCast(stat.size));
    const read_count = try file.readPositionalAll(io, bytes, 0);
    if (read_count != bytes.len or (try file.stat(io)).size != stat.size) return error.ContentMismatch;
    return bytes;
}

const testing = std.testing;

test "content is written once and verified when read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var store = Store.init(arena, root);

    const first = try store.put("command output\n");
    const duplicate = try store.put("command output\n");
    try testing.expect(first.eql(duplicate));
    try testing.expectEqual(@as(usize, 1), store.pending.items.len);

    try store.flush(io);
    try testing.expect(!store.hasPending());
    try testing.expectEqualStrings("command output\n", try store.read(io, first, 1024));
    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        const path = try store.objectPath(first);
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        try testing.expect((try file.stat(io)).permissions.toMode() & 0o077 == 0);
        const parent = std.fs.path.dirname(path).?;
        var dir = try std.Io.Dir.cwd().openDir(io, parent, .{});
        defer dir.close(io);
        try testing.expect((try dir.stat(io)).permissions.toMode() & 0o077 == 0);
    }

    // A second flush reuses the immutable object rather than replacing it.
    _ = try store.put("command output\n");
    try store.flush(io);
    try testing.expectEqualStrings("command output\n", try store.read(io, first, 1024));
}

test "changed object bytes are reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var store = Store.init(arena, root);
    const hash = try store.put("original");
    try store.flush(io);

    const path = try store.objectPath(hash);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "changed!" });
    try testing.expectError(error.ContentMismatch, store.read(io, hash, 1024));
}

test "a missing object is distinct from changed content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const store = Store.init(arena, root);
    try testing.expectError(error.ContentMissing, store.read(threaded.io(), Hash.of("never stored"), 1024));
}

test "an audit reports missing changed unreferenced and unexpected objects" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var store = Store.init(arena, root);
    const changed_hash = try store.put("changed later");
    const orphan_hash = try store.put("orphaned by a crash");
    try store.flush(io);

    const changed_path = try store.objectPath(changed_hash);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = changed_path, .data = "changed bytes" });
    const unexpected_path = try std.fmt.allocPrint(arena, "{s}/{s}/README", .{ root, objects_directory });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = unexpected_path, .data = "not an object" });

    const missing_hash = Hash.of("missing object");
    const report = try store.audit(io, &.{
        .{ .hash = changed_hash, .byte_count = "changed later".len },
        .{ .hash = changed_hash, .byte_count = "changed later".len },
        .{ .hash = missing_hash, .byte_count = 14 },
    });
    try testing.expectEqual(@as(usize, 2), report.references);
    try testing.expectEqual(@as(usize, 2), report.objects);
    try testing.expectEqual(@as(usize, 4), report.issueCount());
    try testing.expectEqual(@as(usize, 1), report.missing.len);
    try testing.expect(report.missing[0].eql(missing_hash));
    try testing.expectEqual(@as(usize, 1), report.changed.len);
    try testing.expect(report.changed[0].hash.eql(changed_hash));
    try testing.expectEqual(@as(usize, 1), report.unreferenced.len);
    try testing.expect(report.unreferenced[0].hash.eql(orphan_hash));
    try testing.expectEqual(@as(usize, 1), report.unexpected.len);
    try testing.expect(!report.isHealthy());
}

test "an absent store reports each unique reference as missing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const store = Store.init(arena, root);
    const hash = Hash.of("missing");
    const report = try store.audit(threaded.io(), &.{
        .{ .hash = hash, .byte_count = 7 },
        .{ .hash = hash, .byte_count = 7 },
    });
    try testing.expectEqual(@as(usize, 1), report.references);
    try testing.expectEqual(@as(usize, 1), report.missing.len);
    try testing.expect(!report.isHealthy());
}

test "an audit checks the byte count recorded by each reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var store = Store.init(arena, root);
    const hash = try store.put("four");
    try store.flush(io);

    const report = try store.audit(io, &.{.{ .hash = hash, .byte_count = 5 }});
    try testing.expectEqual(@as(usize, 1), report.size_mismatches.len);
    try testing.expectEqual(@as(usize, 5), report.size_mismatches[0].expected_bytes);
    try testing.expectEqual(@as(usize, 4), report.size_mismatches[0].actual_bytes);
    try testing.expect(!report.isHealthy());
}

test "content reads never follow a symbolic link" {
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
    const store = Store.init(arena, root);
    const hash = Hash.of("outside bytes");
    const object_path = try store.objectPath(hash);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(object_path).?);
    const outside_path = try std.fmt.allocPrint(arena, "{s}/outside", .{root});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = outside_path, .data = "outside bytes" });
    try std.Io.Dir.cwd().symLink(io, outside_path, object_path, .{});

    try testing.expectError(error.UnsafeObject, store.read(io, hash, 1024));
}
