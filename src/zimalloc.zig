pub const Allocator = @import("allocator.zig").Allocator;
pub const Config = @import("allocator.zig").Config;
pub const Heap = @import("Heap.zig");

test {
    _ = Allocator(.{});
    _ = @import("Heap.zig");
    _ = @import("list.zig");
    _ = @import("Page.zig");
    _ = @import("Segment.zig");
    _ = @import("size_class.zig");
    _ = @import("allocator.zig");
    _ = @import("libzimalloc.zig");
}

const configs = configs: {
    const safety_checks = [_]bool{ false, true };

    const config_count = safety_checks.len;
    var result: [config_count]Config = undefined;

    var index = 0;

    for (safety_checks) |safety| {
        result[index] = Config{
            .safety_checks = safety,
        };
        index += 1;
    }
    break :configs result;
};

fn testValidateConfig(comptime config: Config) !void {
    var gpa = Allocator(config){};
    defer gpa.deinit();

    const allocator = gpa.allocator();

    try std.heap.testAllocator(allocator);
    try std.heap.testAllocatorAligned(allocator);
    try std.heap.testAllocatorLargeAlignment(allocator);
    try std.heap.testAllocatorAlignedShrink(allocator);
}

test "basic validation" {
    inline for (configs) |config| try testValidateConfig(config);
}

fn testCreateDestroyLoop(comptime config: Config) !void {
    var gpa = Allocator(config){};
    defer gpa.deinit();
    const allocator = gpa.allocator();

    for (0..1000) |i| {
        std.log.debug("iteration {d}", .{i});
        var ptr = try allocator.create(u32);
        allocator.destroy(ptr);
    }
}

test "create/destroy loop" {
    inline for (configs) |config| try testCreateDestroyLoop(config);
}

const std = @import("std");
