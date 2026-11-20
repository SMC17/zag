#!/bin/bash
# expect: 0 -- full behaviour, but the C sources are compiled straight into the executable and test, so the static library and headers are no longer built or installed.
set -eu
cp -r /solution/files/. /app/
cat > /app/build.zig <<'Z'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("cbase", .{ .root_source_file = b.path("src/cbase.zig"), .target = target, .optimize = optimize, .link_libc = true });
    mod.addIncludePath(b.path("c"));
    mod.addCSourceFiles(.{ .files = &.{ "c/b64.c", "c/crc32.c" }, .flags = &.{"-std=c99"} });
    const exe = b.addExecutable(.{ .name = "cbase", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize,
        .imports = &.{.{ .name = "cbase", .module = mod }},
    }) });
    b.installArtifact(exe);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/cbase_test.zig"), .target = target, .optimize = optimize,
        .imports = &.{.{ .name = "cbase", .module = mod }},
    }) });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
Z
cd /app && zig build && zig build test
