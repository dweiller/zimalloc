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

    const panic_on_invalid = b.option(
        bool,
        "panic",
        "Panic on invalid calls to free and realloc in libzimalloc (default: false)",
    ) orelse false;

    const build_options = b.addOptions();

    if (verbose_logging) |verbose|
        build_options.addOption(bool, "verbose_logging", verbose);

    if (log_level) |level|
        build_options.addOption(std.log.Level, "log_level", level);

    build_options.addOption(bool, "panic_on_invalid", panic_on_invalid);

    const zimalloc_options = build_options.createModule();
    const zimalloc = b.addModule("zimalloc", .{
        .root_source_file = .{ .path = "src/zimalloc.zig" },
        .imports = &.{
            .{ .name = "build_options", .module = zimalloc_options },
        },
    });

    const libzimalloc_step = b.step("libzimalloc", "Build the libzimalloc shared library");

    const libzimalloc = addLibzimalloc(b, .{
        .target = target,
        .optimize = optimize,
        .zimalloc_options = zimalloc_options,
    });

    const libzimalloc_install = b.addInstallArtifact(libzimalloc, .{});
    b.getInstallStep().dependOn(&libzimalloc_install.step);
    libzimalloc_step.dependOn(&libzimalloc_install.step);

    const libzimalloc_test_builds_step = b.step(
        "libzimalloc-builds",
        "Build libzimalloc with different configurations for testing",
    );
    for (test_configs) |config| {
        const options = b.addOptions();
        options.addOption(bool, "verbose_logging", config.verbose);
        options.addOption(std.log.Level, "log_level", config.log_level);
        options.addOption(bool, "panic_on_invalid", config.panic_on_invalid);
        const options_module = options.createModule();
        const compile = addLibzimalloc(b, .{
            .target = target,
            .optimize = config.optimize,
            .zimalloc_options = options_module,
        });

        const install = b.addInstallArtifact(compile, .{
            .dest_dir = .{
                .override = .{ .custom = b.pathJoin(&.{ "test", @tagName(config.optimize) }) },
            },
            .dest_sub_path = config.name(b.allocator),
            .dylib_symlinks = false,
        });
        libzimalloc_test_builds_step.dependOn(&install.step);
    }

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/zimalloc.zig" },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests.root_module.addImport("build_options", zimalloc_options);

    const tests_run = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&tests_run.step);

    b.default_step = test_step;

    const standalone_test_step = b.step("standalone", "Run the standalone tests");
    const standalone_test_build_step = b.step("standalone-build", "Build the standalone tests");

    const standalone_options = b.addOptions();
    const standalone_pauses = b.option(
        bool,
        "pauses",
        "Insert pauses into standalone tests (default: false)",
    ) orelse false;
    standalone_options.addOption(bool, "pauses", standalone_pauses);

    for (standalone_tests) |test_name| {
        const exe_name = test_name[0 .. test_name.len - 4];
        const test_exe = b.addExecutable(.{
            .name = exe_name,
            .target = target,
            .root_source_file = .{ .path = b.pathJoin(&.{ "test", test_name }) },
            .optimize = optimize,
        });
        test_exe.root_module.addImport("zimalloc", zimalloc);
        test_exe.root_module.addOptions("build_options", standalone_options);

        const install_step = b.addInstallArtifact(test_exe, .{
            .dest_dir = .{ .override = .{ .custom = "test" } },
        });
        standalone_test_build_step.dependOn(&install_step.step);

        const run_step = b.addRunArtifact(test_exe);
        run_step.step.dependOn(&install_step.step);
        standalone_test_step.dependOn(&run_step.step);
    }
}

const LibzimallocOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
    zimalloc_options: *std.Build.Module,
    linkage: std.Build.Step.Compile.Linkage = .dynamic,
    pic: ?bool = true,
};

fn addLibzimalloc(b: *std.Build, options: LibzimallocOptions) *std.Build.Step.Compile {
    const libzimalloc_version = std.SemanticVersion{ .major = 0, .minor = 0, .patch = 0 };
    const libzimalloc = switch (options.linkage) {
        .dynamic => b.addSharedLibrary(.{
            .name = "zimalloc",
            .root_source_file = .{ .path = "src/libzimalloc.zig" },
            .version = libzimalloc_version,
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
            .pic = options.pic,
        }),
        .static => b.addStaticLibrary(.{
            .name = "zimalloc",
            .root_source_file = .{ .path = "src/libzimalloc.zig" },
            .version = libzimalloc_version,
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
            .pic = options.pic,
        }),
    };

    libzimalloc.root_module.addImport("build_options", options.zimalloc_options);
    return libzimalloc;
}

const standalone_tests = [_][]const u8{
    "create-destroy-loop.zig",
};

const TestBuildConfig = struct {
    optimize: std.builtin.OptimizeMode,
    verbose: bool,
    log_level: std.log.Level,
    panic_on_invalid: bool,

    fn name(self: TestBuildConfig, allocator: std.mem.Allocator) []const u8 {
        var parts: [4][]const u8 = undefined;
        var i: usize = 0;
        parts[i] = "libzimalloc";
        i += 1;
        if (self.verbose) {
            parts[i] = "verbose";
            i += 1;
        }
        if (self.log_level != .warn) {
            parts[i] = @tagName(self.log_level);
            i += 1;
        }
        if (self.panic_on_invalid) {
            parts[i] = "panic";
            i += 1;
        }
        return std.mem.join(allocator, "-", parts[0..i]) catch @panic("OOM");
    }
};

// zig fmt: off
const test_configs = [_]TestBuildConfig{
    .{ .optimize = .ReleaseSafe,  .verbose = false, .log_level = .warn,  .panic_on_invalid = false },
    .{ .optimize = .ReleaseSafe,  .verbose = true,  .log_level = .debug, .panic_on_invalid = false },
    .{ .optimize = .ReleaseFast,  .verbose = false, .log_level = .warn,  .panic_on_invalid = false },
};
// zig fmt: on
