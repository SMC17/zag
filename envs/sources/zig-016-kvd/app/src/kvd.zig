//! kvd: an in-memory key-value store and its line protocol, served over TCP by src/main.zig.
//!
//! Protocol, one command per line (LF or CRLF):
//!   SET <key> <value>   -> OK            (value is the rest of the line, 1..256 bytes)
//!   GET <key>           -> VALUE <value> | NOTFOUND
//!   DEL <key>           -> DELETED | NOTFOUND
//!   COUNT               -> COUNT <n>
//!   QUIT                -> BYE, then the connection closes
//!   SHUTDOWN            -> BYE, then the server exits
//! Keys are 1..64 bytes without spaces. Blank lines are ignored. Anything else gets one
//! "ERR <reason>" line and the connection stays open.
const std = @import("std");

pub const max_key = 64;
pub const max_value = 256;

pub const Store = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]u8) = .{},

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    pub fn set(self: *Store, key: []const u8, value: []const u8) !void {
        const v = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(v);
        const gop = try self.map.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, key) catch |e| {
                self.map.removeByPtr(gop.key_ptr);
                return e;
            };
        }
        gop.value_ptr.* = v;
    }

    pub fn get(self: *const Store, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn del(self: *Store, key: []const u8) bool {
        const kv = self.map.fetchRemove(key) orelse return false;
        self.allocator.free(kv.key);
        self.allocator.free(kv.value);
        return true;
    }

    pub fn count(self: *const Store) usize {
        return self.map.count();
    }
};

pub const Action = enum { keep_open, close, shutdown };

fn validKey(k: []const u8) bool {
    return k.len >= 1 and k.len <= max_key;
}

/// Executes one protocol line and writes exactly one response line (none for a blank line).
pub fn handleLine(store: *Store, raw: []const u8, w: *std.Io.Writer) !Action {
    const line = std.mem.trim(u8, raw, " \r\n");
    if (line.len == 0) return .keep_open;
    const sp = std.mem.indexOfScalar(u8, line, ' ');
    const cmd = if (sp) |i| line[0..i] else line;
    const rest = if (sp) |i| std.mem.trimLeft(u8, line[i + 1 ..], " ") else "";

    if (std.mem.eql(u8, cmd, "SET")) {
        const ksp = std.mem.indexOfScalar(u8, rest, ' ') orelse {
            try w.writeAll("ERR usage: SET <key> <value>\n");
            return .keep_open;
        };
        const key = rest[0..ksp];
        const value = std.mem.trimLeft(u8, rest[ksp + 1 ..], " ");
        if (!validKey(key)) {
            try w.writeAll("ERR bad key\n");
        } else if (value.len == 0 or value.len > max_value) {
            try w.writeAll("ERR bad value\n");
        } else {
            try store.set(key, value);
            try w.writeAll("OK\n");
        }
    } else if (std.mem.eql(u8, cmd, "GET") or std.mem.eql(u8, cmd, "DEL")) {
        if (!validKey(rest) or std.mem.indexOfScalar(u8, rest, ' ') != null) {
            try w.print("ERR usage: {s} <key>\n", .{cmd});
        } else if (cmd[0] == 'G') {
            if (store.get(rest)) |v| try w.print("VALUE {s}\n", .{v}) else try w.writeAll("NOTFOUND\n");
        } else {
            try w.writeAll(if (store.del(rest)) "DELETED\n" else "NOTFOUND\n");
        }
    } else if (std.mem.eql(u8, cmd, "COUNT") and rest.len == 0) {
        try w.print("COUNT {d}\n", .{store.count()});
    } else if (std.mem.eql(u8, cmd, "QUIT") and rest.len == 0) {
        try w.writeAll("BYE\n");
        return .close;
    } else if (std.mem.eql(u8, cmd, "SHUTDOWN") and rest.len == 0) {
        try w.writeAll("BYE\n");
        return .shutdown;
    } else {
        try w.writeAll("ERR unknown command\n");
    }
    return .keep_open;
}

/// Serves one connection until QUIT, SHUTDOWN or end of input. Responses are flushed after
/// every line. A line longer than the reader's buffer gets "ERR line too long" and closes.
pub fn serveConnection(store: *Store, r: *std.Io.Reader, w: *std.Io.Writer) !Action {
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => return .close,
            error.StreamTooLong => {
                try w.writeAll("ERR line too long\n");
                try w.flush();
                return .close;
            },
            else => |x| return x,
        };
        const act = try handleLine(store, line, w);
        try w.flush();
        if (act != .keep_open) return act;
    }
}
