const std = @import("std");

const fbink_sources = &.{
    "third_party/FBInk/fbink.c",
    "third_party/FBInk/cutef8/utf8.c",
    "third_party/FBInk/cutef8/dfa.c",
    "third_party/FBInk/libunibreak/src/linebreak.c",
    "third_party/FBInk/libunibreak/src/linebreakdata.c",
    "third_party/FBInk/libunibreak/src/unibreakdef.c",
    "third_party/FBInk/libunibreak/src/linebreakdef.c",
    "third_party/FBInk/libunibreak/src/eastasianwidthdef.c",
};

pub fn build(b: *std.Build) void {
    const manifest_text = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "build.zig.zon",
        b.allocator,
        .limited(1024 * 1024),
    ) catch @panic("unable to read build.zig.zon");
    const manifest_z = b.allocator.dupeZ(u8, manifest_text) catch @panic("out of memory");
    const manifest = std.zon.parse.fromSliceAlloc(
        struct { version: []const u8 },
        b.allocator,
        manifest_z,
        null,
        .{ .ignore_unknown_fields = true },
    ) catch @panic("unable to parse version from build.zig.zon");
    const version = manifest.version;
    _ = std.SemanticVersion.parse(version) catch @panic("build.zig.zon version must be SemVer");
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption(bool, "host", true);
    const core_module = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    const host_xml = b.dependency("xml", .{ .target = b.graph.host, .optimize = .Debug });
    core_module.addImport("xml", host_xml.module("xml"));
    const host_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
        .imports = &.{
            .{ .name = "core", .module = core_module },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });
    const host = b.addExecutable(.{ .name = "kual-next", .root_module = host_module });
    const host_install = b.addInstallArtifact(host, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = "host/kual-next",
    });
    const host_step = b.step("host", "Build the host validator");
    host_step.dependOn(&host_install.step);
    b.getInstallStep().dependOn(&host_install.step);

    const unit = b.addTest(.{ .name = "kual-next-tests", .root_module = core_module });
    const run_unit = b.addRunArtifact(unit);
    const safe_core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    const safe_xml = b.dependency("xml", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
    safe_core.addImport("xml", safe_xml.module("xml"));
    const safe_unit = b.addTest(.{ .name = "kual-next-tests-safe", .root_module = safe_core });
    const run_safe_unit = b.addRunArtifact(safe_unit);
    const ui_logic_module = b.createModule(.{
        .root_source_file = b.path("src/ui_logic.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const ui_logic_tests = b.addTest(.{ .name = "kual-next-ui-logic-tests", .root_module = ui_logic_module });
    const run_ui_logic_tests = b.addRunArtifact(ui_logic_tests);
    const local_time_module = b.createModule(.{
        .root_source_file = b.path("src/local_time.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = true,
    });
    const local_time_tests = b.addTest(.{ .name = "kual-next-local-time-tests", .root_module = local_time_module });
    const run_local_time_tests = b.addRunArtifact(local_time_tests);
    const safe_local_time_module = b.createModule(.{
        .root_source_file = b.path("src/local_time.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    const safe_local_time_tests = b.addTest(.{ .name = "kual-next-local-time-tests-safe", .root_module = safe_local_time_module });
    const run_safe_local_time_tests = b.addRunArtifact(safe_local_time_tests);
    const parser_tests = b.addSystemCommand(&.{ "sh", "./tests/run.sh" });
    parser_tests.addArtifactArg(host);
    parser_tests.setEnvironmentVariable("KUAL_TEST_VERSION", version);
    const test_step = b.step("test", "Run host unit and compatibility tests");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&run_safe_unit.step);
    test_step.dependOn(&run_ui_logic_tests.step);
    test_step.dependOn(&run_local_time_tests.step);
    test_step.dependOn(&run_safe_local_time_tests.step);
    test_step.dependOn(&parser_tests.step);

    const kindle_target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .musleabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
    });
    const kindle_options = b.addOptions();
    kindle_options.addOption([]const u8, "version", version);
    kindle_options.addOption(bool, "host", false);
    const kindle_options_module = kindle_options.createModule();
    const kindle_core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = kindle_target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
        .strip = true,
    });
    const kindle_xml = b.dependency("xml", .{ .target = kindle_target, .optimize = .ReleaseSmall });
    kindle_core.addImport("xml", kindle_xml.module("xml"));
    const ui_module = b.createModule(.{
        .root_source_file = b.path("src/ui_fbink.zig"),
        .target = kindle_target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
        .strip = true,
        .imports = &.{
            .{ .name = "core", .module = kindle_core },
            .{ .name = "ui_logic", .module = b.createModule(.{ .root_source_file = b.path("src/ui_logic.zig"), .target = kindle_target, .optimize = .ReleaseSmall }) },
            .{ .name = "build_options", .module = kindle_options_module },
        },
    });
    ui_module.addIncludePath(b.path("third_party/FBInk"));
    const kindle_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = kindle_target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
        .strip = true,
        .imports = &.{
            .{ .name = "core", .module = kindle_core },
            .{ .name = "ui", .module = ui_module },
            .{ .name = "build_options", .module = kindle_options_module },
        },
    });
    const kindle = b.addExecutable(.{ .name = "kual-next", .root_module = kindle_module, .linkage = .static });
    kindle_module.linkLibrary(addFbink(b, kindle_target));
    kindle_module.linkSystemLibrary("m", .{});
    const kindle_install = b.addInstallArtifact(kindle, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = "kindle/kual-next",
    });
    const kindle_step = b.step("kindle", "Build the static Kindle executable");
    kindle_step.dependOn(&kindle_install.step);

    const verifier_module = b.createModule(.{
        .root_source_file = b.path("tools/verify_elf.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const verifier = b.addExecutable(.{ .name = "verify-elf", .root_module = verifier_module });
    const run_verifier = b.addRunArtifact(verifier);
    run_verifier.addArtifactArg(kindle);
    const shell_checks = b.addSystemCommand(&.{
        "sh",
        "-c",
        "sh tests/check-fonts.sh && sh tests/check-deploy.sh && sh tests/check-device-ui.sh && sh tests/check-release.sh && actionlint",
    });
    const check_step = b.step("check", "Run all tests and verify the Kindle executable");
    check_step.dependOn(test_step);
    check_step.dependOn(&run_verifier.step);
    check_step.dependOn(&shell_checks.step);

    const package_cmd = b.addSystemCommand(&.{ "sh", "./scripts/package.sh" });
    package_cmd.addArg(version);
    package_cmd.addArtifactArg(kindle);
    package_cmd.step.dependOn(check_step);
    const package_step = b.step("package", "Build and verify the Kindle package");
    package_step.dependOn(&package_cmd.step);

    const kindle_host = b.option([]const u8, "kindle-host", "SSH destination, for example root@kindle");
    const deploy_step = b.step("deploy", "Package and deploy to a Kindle (-Dkindle-host=USER@HOST)");
    const device_test_step = b.step("device-ui-test", "Run the interactive Kindle UI test (-Dkindle-host=USER@HOST)");
    if (kindle_host) |host_name| {
        const package_path = b.fmt("dist/kual-next-{s}-kindlehf.zip", .{version});
        const deploy_cmd = b.addSystemCommand(&.{ "sh", "./scripts/deploy-kindle.sh", host_name, package_path });
        deploy_cmd.step.dependOn(&package_cmd.step);
        deploy_step.dependOn(&deploy_cmd.step);

        const device_test_cmd = b.addSystemCommand(&.{ "sh", "./scripts/test-kindle-ui.sh", host_name });
        device_test_cmd.addArtifactArg(kindle);
        device_test_step.dependOn(&device_test_cmd.step);
    } else {
        const missing_deploy_host = missingKindleHostCommand(b, "deploy");
        deploy_step.dependOn(&missing_deploy_host.step);
        const missing_test_host = missingKindleHostCommand(b, "device-ui-test");
        device_test_step.dependOn(&missing_test_host.step);
    }
}

fn missingKindleHostCommand(b: *std.Build, step_name: []const u8) *std.Build.Step.Run {
    return b.addSystemCommand(&.{
        "sh",
        "-c",
        b.fmt("echo 'zig build {s} requires -Dkindle-host=USER@HOST' >&2; exit 2", .{step_name}),
    });
}

fn addFbink(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
    });
    module.addIncludePath(b.path("third_party/FBInk"));
    module.addIncludePath(b.path("third_party/FBInk/libunibreak/src"));
    const flags = &.{
        "-std=gnu11",
        "-D_GNU_SOURCE",
        "-D_REENTRANT=1",
        "-DNDEBUG",
        "-DFBINK_FOR_KINDLE",
        "-DFBINK_MINIMAL",
        "-DFBINK_WITH_BITMAP",
        "-DFBINK_WITH_DRAW",
        "-DFBINK_WITH_INPUT",
        "-DFBINK_WITH_OPENTYPE",
        "-DFBINK_VERSION=\"zig\"",
    };
    module.addCSourceFiles(.{ .files = fbink_sources, .flags = flags });
    return b.addLibrary(.{ .name = "fbink", .root_module = module });
}
