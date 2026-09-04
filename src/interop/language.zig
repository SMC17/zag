//! Language tags.
//!
//! Content, terminology and audience profiles all carry a language. The tag is
//! validated against ISO 639-1 (language), ISO 15924 (script) and ISO 3166-1
//! (region) so that a document cannot be labelled `en-Latin-UK` and then fail
//! to match anything at publication time.

const std = @import("std");
const data = @import("iso639_data.zig");
const countries = @import("countries.zig");

pub const Error = error{ UnknownLanguage, UnknownScript, UnknownRegion, MalformedTag };

pub fn languageName(code: []const u8) ?[]const u8 {
    if (code.len != 2) return null;
    var key: [2]u8 = undefined;
    for (code, 0..) |c, i| key[i] = std.ascii.toLower(c);
    var low: usize = 0;
    var high: usize = data.languages.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, &data.languages[mid].code, &key)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return data.languages[mid].name,
        }
    }
    return null;
}

pub fn scriptName(code: []const u8) ?[]const u8 {
    if (code.len != 4) return null;
    var key: [4]u8 = undefined;
    key[0] = std.ascii.toUpper(code[0]);
    for (code[1..], 1..) |c, i| key[i] = std.ascii.toLower(c);
    for (data.scripts) |s| {
        if (std.mem.eql(u8, &s.code, &key)) return s.name;
    }
    return null;
}

/// A validated language tag in the `language[-Script][-REGION]` shape.
pub const Tag = struct {
    language: [2]u8,
    script: ?[4]u8 = null,
    region: ?[2]u8 = null,

    pub const english: Tag = .{ .language = "en".* };

    pub fn parse(text: []const u8) Error!Tag {
        var it = std.mem.splitScalar(u8, text, '-');
        const lang = it.next() orelse return error.MalformedTag;
        if (lang.len != 2) return error.MalformedTag;
        if (languageName(lang) == null) return error.UnknownLanguage;
        var tag: Tag = .{ .language = .{ std.ascii.toLower(lang[0]), std.ascii.toLower(lang[1]) } };

        while (it.next()) |part| {
            if (part.len == 4) {
                if (scriptName(part) == null) return error.UnknownScript;
                var s: [4]u8 = undefined;
                s[0] = std.ascii.toUpper(part[0]);
                for (part[1..], 1..) |c, i| s[i] = std.ascii.toLower(c);
                tag.script = s;
            } else if (part.len == 2) {
                const country = countries.byAlpha2(part) orelse return error.UnknownRegion;
                tag.region = country.alpha2;
            } else return error.MalformedTag;
        }
        return tag;
    }

    pub fn format(self: Tag, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(&self.language);
        if (self.script) |s| try w.print("-{s}", .{&s});
        if (self.region) |r| try w.print("-{s}", .{&r});
    }

    pub fn eql(a: Tag, b: Tag) bool {
        return std.meta.eql(a, b);
    }
};

test "language and script lookup" {
    try std.testing.expectEqualStrings("English", languageName("en").?);
    try std.testing.expect(languageName("zz") == null);
    try std.testing.expect(scriptName("Latn") != null);
    try std.testing.expect(scriptName("Zzzz9") == null);
}

test "language tags validate every subtag" {
    const gpa = std.testing.allocator;
    const tag = try Tag.parse("en-Latn-GB");
    const text = try std.fmt.allocPrint(gpa, "{f}", .{tag});
    defer gpa.free(text);
    try std.testing.expectEqualStrings("en-Latn-GB", text);

    try std.testing.expectError(error.UnknownLanguage, Tag.parse("zz-GB"));
    try std.testing.expectError(error.UnknownRegion, Tag.parse("en-ZZ"));
    try std.testing.expectError(error.UnknownScript, Tag.parse("en-Qqqq"));
    try std.testing.expectError(error.MalformedTag, Tag.parse("english"));
}
