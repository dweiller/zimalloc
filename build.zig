const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zimalloc = b.addModule("zimalloc", .{
        .source_file = .{ .path = "src/zimalloc.zig" },
    });

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/zimalloc.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);

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
