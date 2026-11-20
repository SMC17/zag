//! Hidden behavioural suite for zig-016-kvd (Zig 0.16 API).
const std = @import("std");
const testing = std.testing;
const kvd = @import("kvd");

fn run(store: *kvd.Store, input: []const u8, out: []u8) !struct { act: kvd.Action, text: []const u8 } {
    var r: std.Io.Reader = .fixed(input);
    var w: std.Io.Writer = .fixed(out);
    const act = try kvd.serveConnection(store, &r, &w);
    return .{ .act = act, .text = w.buffered() };
}

test "store: overwrite frees the old value, keys are owned, no leaks" {
    var s = kvd.Store.init(testing.allocator);
    defer s.deinit();
    var key = "abc".*;
    try s.set(&key, "1");
    key[0] = 'z';
    try s.set("abc", "22");
    try testing.expectEqualStrings("22", s.get("abc").?);
    try testing.expect(s.get("zbc") == null);
    try testing.expectEqual(@as(usize, 1), s.count());
    try testing.expect(!s.del("nope"));
}

test "protocol: every response, in order" {
    var s = kvd.Store.init(testing.allocator);
    defer s.deinit();
    var buf: [1024]u8 = undefined;
    const r = try run(&s, "SET a  one two \r\nGET a\nGET\nDEL a\nDEL a\nCOUNT\nCOUNT x\nSET b\n\nNOPE\nQUIT\nSET never 1\n", &buf);
    try testing.expectEqual(kvd.Action.close, r.act);
    try testing.expectEqualStrings(
        "OK\nVALUE one two\nERR usage: GET <key>\nDELETED\nNOTFOUND\nCOUNT 0\nERR unknown command\nERR usage: SET <key> <value>\nERR unknown command\nBYE\n",
        r.text,
    );
    try testing.expect(s.get("never") == null);
}

test "protocol: limits and shutdown" {
    var s = kvd.Store.init(testing.allocator);
    defer s.deinit();
    var buf: [2048]u8 = undefined;
    const input = "SET " ++ "k" ** 64 ++ " v\nSET " ++ "k" ** 65 ++ " v\nSET x " ++ "y" ** 256 ++ "\nSET x " ++ "y" ** 257 ++ "\nSHUTDOWN\n";
    const r = try run(&s, input, &buf);
    try testing.expectEqual(kvd.Action.shutdown, r.act);
    try testing.expectEqualStrings("OK\nERR bad key\nOK\nERR bad value\nBYE\n", r.text);
    try testing.expectEqual(@as(usize, 2), s.count());
}

test "end of input without QUIT closes" {
    var s = kvd.Store.init(testing.allocator);
    defer s.deinit();
    var buf: [64]u8 = undefined;
    const r = try run(&s, "SET a 1\n", &buf);
    try testing.expectEqual(kvd.Action.close, r.act);
    try testing.expectEqualStrings("OK\n", r.text);
}
