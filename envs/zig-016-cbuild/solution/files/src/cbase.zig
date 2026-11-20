//! cbase: Zig wrappers over a small C library (base64 and CRC-32) built from c/.
const std = @import("std");
const c = @cImport({
    @cInclude("b64.h");
    @cInclude("crc32.h");
});

pub fn encodeAlloc(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, c.b64_encoded_len(data.len));
    c.b64_encode(data.ptr, data.len, out.ptr);
    return out;
}

pub const DecodeError = error{InvalidBase64} || std.mem.Allocator.Error;

/// Decodes canonical padded base64. Surrounding whitespace (spaces, tabs, CR, LF) is ignored.
pub fn decodeAlloc(allocator: std.mem.Allocator, text: []const u8) DecodeError![]u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    const buf = try allocator.alloc(u8, c.b64_decoded_max(t.len));
    errdefer allocator.free(buf);
    const n = c.b64_decode(t.ptr, t.len, buf.ptr);
    if (n < 0) return error.InvalidBase64;
    return allocator.realloc(buf, @intCast(n));
}

pub fn crc32Update(crc: u32, data: []const u8) u32 {
    return c.crc32_update(crc, data.ptr, data.len);
}

pub fn crc32(data: []const u8) u32 {
    return crc32Update(0, data);
}
