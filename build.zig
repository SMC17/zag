//! Build graph for zag.
//!
//! One library module (`zag`) holds the whole substrate. Every surface — the
//! command-line tool, the workspace daemon, and later the desktop application
//! and a WASM client — is a thin binary over that module. Keeping the surfaces
//! thin is what lets the same event model, security model and standards control
//! plane run locally, remotely and in continuous integration.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zag = b.addModule("zag", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- Command-line surface -------------------------------------------
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zag", .module = zag }},
    });
    // The standards registry is data, and it ships inside the binary so that
    // `zag standards` and `zag check` work from any directory.
    cli_module.addAnonymousImport("registry_language", .{ .root_source_file = b.path("standards/registry/language.toml") });
    cli_module.addAnonymousImport("registry_accessibility", .{ .root_source_file = b.path("standards/registry/accessibility.toml") });
    cli_module.addAnonymousImport("registry_knowledge", .{ .root_source_file = b.path("standards/registry/knowledge.toml") });
    cli_module.addAnonymousImport("registry_interoperability", .{ .root_source_file = b.path("standards/registry/interoperability.toml") });
    cli_module.addAnonymousImport("registry_governance", .{ .root_source_file = b.path("standards/registry/governance.toml") });
    cli_module.addAnonymousImport("registry_requirements", .{ .root_source_file = b.path("standards/registry/requirements.toml") });

    const cli = b.addExecutable(.{ .name = "zag", .root_module = cli_module });
    b.installArtifact(cli);

    // ---- Workspace daemon ------------------------------------------------
    const daemon = b.addExecutable(.{
        .name = "zagd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zag", .module = zag }},
        }),
    });
    b.installArtifact(daemon);

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cli.addArgs(args);
    b.step("run", "Run the zag command-line tool").dependOn(&run_cli.step);

    // ---- Tests -----------------------------------------------------------
    const lib_tests = b.addTest(.{ .root_module = zag });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const cli_tests = b.addTest(.{ .root_module = cli.root_module });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const daemon_tests = b.addTest(.{ .root_module = daemon.root_module });
    const run_daemon_tests = b.addRunArtifact(daemon_tests);

    const test_step = b.step("test", "Run the library, command-line and daemon tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_daemon_tests.step);

    // ---- Conformance gate ------------------------------------------------
    // `zig build check` is the release gate: it runs the tests and then makes
    // the tool audit the repository's own documentation, standards registry and
    // metadata. A build that cannot state its own conformance evidence fails.
    const self_check = b.addRunArtifact(cli);
    self_check.addArgs(&.{ "check", "--repo", "." });
    self_check.step.dependOn(&run_lib_tests.step);
    const check_step = b.step("check", "Run tests, then audit the repository against its standards profile");
    check_step.dependOn(&self_check.step);

    // ---- Generated interchange artefacts ---------------------------------
    const emit = b.addRunArtifact(cli);
    emit.addArgs(&.{ "emit", "--out", "." });
    const emit_step = b.step("emit", "Regenerate schemas, vocabularies and the OpenAPI description");
    emit_step.dependOn(&emit.step);
}
