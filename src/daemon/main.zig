const std = @import("std");
const zag = @import("zag");
pub fn main() !void { std.debug.print("zagd {s}\n", .{zag.version}); }
