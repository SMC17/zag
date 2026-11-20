const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.addModule("dirstat", .{ .root_source_file = b.path("src/dirstat.zig"), .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "dirstat", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "dirstat", .module = lib }},
    }) });
    b.installArtifact(exe);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/dirstat_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "dirstat", .module = lib }},
    }) });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
    const run = b.addRunArtifact(exe);
    if (b.args) |a| run.addArgs(a);
    b.step("run", "Run dirstat").dependOn(&run.step);
}
