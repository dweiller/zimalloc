pub const Allocator = @import("Heap.zig");

test {
    _ = @import("Heap.zig");
    _ = @import("list.zig");
    _ = @import("Page.zig");
    _ = @import("Segment.zig");
    _ = @import("size_class.zig");
}

test "basic validation" {
    var gpa = Allocator.init();
    defer gpa.deinit();

    const allocator = gpa.allocator();

    try std.heap.testAllocator(allocator);
    try std.heap.testAllocatorAligned(allocator);
    try std.heap.testAllocatorLargeAlignment(allocator);
    try std.heap.testAllocatorAlignedShrink(allocator);
}

test "create/destroy loop" {
    var gpa = Allocator.init();
    defer gpa.deinit();
    const allocator = gpa.allocator();

    for (0..1000) |i| {
        std.log.debug("iteration {d}", .{i});
        var ptr = try allocator.create(u32);
        allocator.destroy(ptr);
    }
}

const std = @import("std");
