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

    const cli = b.addExecutable(.{ .name = "zag", .root_module = cli_module });
    b.installArtifact(cli);

    // ---- Repository audit tool -------------------------------------------
    // Split out of `zag` so the workbench binary does not carry the standards
    // registry, the plain-language rules or the conformance generator. The
    // registry data ships here now, because these are the commands that read it.
    const audit_module = b.createModule(.{
        .root_source_file = b.path("src/audit/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zag", .module = zag }},
    });
    audit_module.addAnonymousImport("registry_language", .{ .root_source_file = b.path("standards/registry/language.toml") });
    audit_module.addAnonymousImport("registry_accessibility", .{ .root_source_file = b.path("standards/registry/accessibility.toml") });
    audit_module.addAnonymousImport("registry_knowledge", .{ .root_source_file = b.path("standards/registry/knowledge.toml") });
    audit_module.addAnonymousImport("registry_interoperability", .{ .root_source_file = b.path("standards/registry/interoperability.toml") });
    audit_module.addAnonymousImport("registry_governance", .{ .root_source_file = b.path("standards/registry/governance.toml") });
    audit_module.addAnonymousImport("registry_requirements", .{ .root_source_file = b.path("standards/registry/requirements.toml") });
    const audit = b.addExecutable(.{ .name = "zag-audit", .root_module = audit_module });
    b.installArtifact(audit);

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

    // ---- Benchmarks --------------------------------------------------------
    // Kept out of the test step: a measurement that runs on every build is a
    // measurement nobody reads, and it makes the tests slow enough to skip.
    const bench = b.addExecutable(.{
        .name = "zag-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zag", .module = zag }},
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    b.step("bench", "Measure the throughput of the parts that sit in a hot path").dependOn(&run_bench.step);

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

    const audit_tests = b.addTest(.{ .root_module = audit.root_module });
    const run_audit_tests = b.addRunArtifact(audit_tests);

    const test_step = b.step("test", "Run the library, command-line, audit and daemon tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_audit_tests.step);
    test_step.dependOn(&run_daemon_tests.step);

    // ---- Conformance gate ------------------------------------------------
    // `zig build check` is the release gate: it runs the tests and then makes
    // the tool audit the repository's own documentation, standards registry and
    // metadata. A build that cannot state its own conformance evidence fails.
    const fmt = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "--check", "build.zig", "src" });
    const self_check = b.addRunArtifact(audit);
    self_check.addArgs(&.{ "check", "--repo", "." });
    self_check.step.dependOn(test_step);
    const check_step = b.step("check", "Run tests, then audit the repository against its standards profile");
    check_step.dependOn(&fmt.step);
    check_step.dependOn(&self_check.step);

    // ---- Generated interchange artefacts ---------------------------------
    const emit = b.addRunArtifact(audit);
    emit.addArgs(&.{ "emit", "--out", "." });
    const emit_step = b.step("emit", "Regenerate schemas, vocabularies and the OpenAPI description");
    emit_step.dependOn(&emit.step);
}
