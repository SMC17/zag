//! dirstat: walk a directory tree and total file counts and sizes by extension.
const std = @import("std");

pub const ExtStat = struct {
    ext: []const u8,
    files: u64,
    bytes: u64,
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    by_ext: std.StringHashMap(ExtStat),
    names: std.ArrayList([]u8),
    total_files: u64 = 0,
    total_bytes: u64 = 0,
    dirs: u64 = 0,
    skipped_symlinks: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Report {
        return .{ .allocator = allocator, .by_ext = std.StringHashMap(ExtStat).init(allocator), .names = .{} };
    }

    pub fn deinit(self: *Report) void {
        for (self.names.items) |n| self.allocator.free(n);
        self.names.deinit(self.allocator);
        self.by_ext.deinit();
    }

    /// Extension of a file name: text after the last '.', lower-cased; "(none)" if there is
    /// no dot, or the only dot is the first character (".bashrc").
    pub fn extensionOf(name: []const u8, buf: []u8) []const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "(none)";
        if (dot == 0 or dot + 1 == name.len) return "(none)";
        const ext = name[dot + 1 ..];
        const n = @min(ext.len, buf.len);
        for (ext[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
        return buf[0..n];
    }

    pub fn add(self: *Report, name: []const u8, size: u64) !void {
        var buf: [64]u8 = undefined;
        const ext = extensionOf(name, &buf);
        const gop = try self.by_ext.getOrPut(ext);
        if (!gop.found_existing) {
            const owned = try self.allocator.dupe(u8, ext);
            errdefer self.allocator.free(owned);
            try self.names.append(self.allocator, owned);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = .{ .ext = owned, .files = 0, .bytes = 0 };
        }
        gop.value_ptr.files += 1;
        gop.value_ptr.bytes += size;
        self.total_files += 1;
        self.total_bytes += size;
    }

    /// Rows sorted by bytes descending, then extension ascending. Caller frees.
    pub fn sorted(self: *const Report, allocator: std.mem.Allocator) ![]ExtStat {
        var out: std.ArrayList(ExtStat) = .{};
        errdefer out.deinit(allocator);
        var it = self.by_ext.valueIterator();
        while (it.next()) |v| try out.append(allocator, v.*);
        std.mem.sort(ExtStat, out.items, {}, struct {
            fn lt(_: void, a: ExtStat, b: ExtStat) bool {
                if (a.bytes != b.bytes) return a.bytes > b.bytes;
                return std.mem.lessThan(u8, a.ext, b.ext);
            }
        }.lt);
        return out.toOwnedSlice(allocator);
    }
};

/// Walks `root` (files only, recursively). Symlinks are counted as skipped, never followed.
/// Hidden entries (names starting with '.') are included.
pub fn scan(allocator: std.mem.Allocator, root: std.fs.Dir, report: *Report) !void {
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const st = try entry.dir.statFile(entry.basename);
                try report.add(entry.basename, st.size);
            },
            .directory => report.dirs += 1,
            .sym_link => report.skipped_symlinks += 1,
            else => {},
        }
    }
}

/// Text report: one line per extension "EXT FILES BYTES", then
/// "TOTAL FILES BYTES", "DIRS N", "SYMLINKS_SKIPPED N".
pub fn render(w: *std.Io.Writer, report: *const Report, rows: []const ExtStat) !void {
    for (rows) |r| try w.print("{s} {d} {d}\n", .{ r.ext, r.files, r.bytes });
    try w.print("TOTAL {d} {d}\nDIRS {d}\nSYMLINKS_SKIPPED {d}\n", .{ report.total_files, report.total_bytes, report.dirs, report.skipped_symlinks });
}
