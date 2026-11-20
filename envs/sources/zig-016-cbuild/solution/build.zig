const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The C library, built as a static library and installed with its headers.
    const clib = b.addLibrary(.{
        .name = "cbase_c",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    clib.root_module.addCSourceFiles(.{ .files = &.{ "c/b64.c", "c/crc32.c" }, .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" } });
    clib.root_module.addIncludePath(b.path("c"));
    clib.installHeader(b.path("c/b64.h"), "b64.h");
    clib.installHeader(b.path("c/crc32.h"), "crc32.h");
    b.installArtifact(clib);

    // The Zig module that wraps it.
    const mod = b.addModule("cbase", .{ .root_source_file = b.path("src/cbase.zig"), .target = target, .optimize = optimize });
    mod.addIncludePath(b.path("c"));

    const exe = b.addExecutable(.{ .name = "cbase", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "cbase", .module = mod }},
    }) });
    exe.root_module.linkLibrary(clib);
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/cbase_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "cbase", .module = mod }},
    }) });
    tests.root_module.linkLibrary(clib);
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);

    const run = b.addRunArtifact(exe);
    if (b.args) |a| run.addArgs(a);
    b.step("run", "Run cbase").dependOn(&run.step);
}
