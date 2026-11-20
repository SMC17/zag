const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ledger_mod = b.addModule("ledger", .{
        .root_source_file = b.path("src/ledger.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "ledger", .module = ledger_mod }},
    });
    const exe = b.addExecutable(.{ .name = "ledger", .root_module = exe_mod });
    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/ledger_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ledger", .module = ledger_mod }},
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the CLI").dependOn(&run.step);
}
