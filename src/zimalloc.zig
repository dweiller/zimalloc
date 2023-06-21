pub const Allocator = @import("allocator.zig").Allocator;
pub const Heap = @import("Heap.zig");

test {
    _ = Allocator(.{ .track_allocations = true, .memory_limit = 4096 });
    _ = @import("Heap.zig");
    _ = @import("list.zig");
    _ = @import("Page.zig");
    _ = @import("Segment.zig");
    _ = @import("size_class.zig");
    _ = @import("allocator.zig");
    _ = @import("libzimalloc.zig");
}

test "basic validation" {
    var gpa = Allocator(.{}){};
    defer gpa.deinit();

    const allocator = gpa.allocator();

    try std.heap.testAllocator(allocator);
    try std.heap.testAllocatorAligned(allocator);
    try std.heap.testAllocatorLargeAlignment(allocator);
    try std.heap.testAllocatorAlignedShrink(allocator);
}

test "create/destroy loop" {
    var gpa = Allocator(.{}){};
    defer gpa.deinit();
    const allocator = gpa.allocator();

    for (0..1000) |i| {
        std.log.debug("iteration {d}", .{i});
        var ptr = try allocator.create(u32);
        allocator.destroy(ptr);
    }
}

const std = @import("std");
