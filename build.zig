const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const verbose_logging = b.option(
        bool,
        "verbose-logging",
        "Enable verbose logging",
    );

    const log_level = b.option(
        std.log.Level,
        "log-level",
        "Override the default log level",
    );

    const build_options = b.addOptions();
    if (verbose_logging) |verbose|
        build_options.addOption(bool, "verbose_logging", verbose);
    if (log_level) |level|
        build_options.addOption(std.log.Level, "log_level", level);

    const zimalloc_options = build_options.createModule();
    const zimalloc = b.addModule("zimalloc", .{
        .source_file = .{ .path = "src/zimalloc.zig" },
        .dependencies = &.{
            .{ .name = "build_options", .module = zimalloc_options },
        },
    });

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/zimalloc.zig" },
        .target = target,
        .optimize = optimize,
    });
    tests.addModule("build_options", zimalloc_options);

    const tests_run = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&tests_run.step);

    b.default_step = test_step;

    const standalone_test_step = b.step("standalone", "Build the standalone tests");

    const standalone_options = b.addOptions();
    const standalone_pauses = b.option(bool, "pauses", "Insert pauses into standalone tests (default: false)") orelse false;
    standalone_options.addOption(bool, "pauses", standalone_pauses);

    for (standalone_tests) |test_name| {
        const exe_name = test_name[0 .. test_name.len - 4];
        const test_exe = b.addExecutable(.{
            .name = exe_name,
            .root_source_file = .{ .path = b.pathJoin(&.{ "test", test_name }) },
            .optimize = optimize,
        });
        test_exe.addModule("zimalloc", zimalloc);
        test_exe.addOptions("build_options", standalone_options);
        test_exe.override_dest_dir = .{ .custom = "test" };

        const install_step = b.addInstallArtifact(test_exe);
        standalone_test_step.dependOn(&install_step.step);
    }
}

const standalone_tests = [_][]const u8{
    "create-destroy-loop.zig",
};
