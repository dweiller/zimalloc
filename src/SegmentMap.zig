descriptors: [constants.total_segment_count]SegmentDescriptor = undefined,
min_address: usize = 0,
max_address: usize = 0,

const SegmentMap = @This();

pub const SegmentDescriptor = struct {
    in_use: bool,
    is_huge: bool,
    segment: *Segment,
};

/// If `backing_allocator` does not return zeroed memory, then the caller must handle
/// initialising the `.in_use` flags of the `SegmentDescriptor`s in the returned map.
pub fn init(allocator: std.mem.Allocator, min_address: usize, max_address: usize) !*SegmentMap {
    assert.withMessage(
        @src(),
        std.mem.isAlignedLog2(min_address, constants.segment_alignment_log2),
        "min_address is not aligned to a segment boundary",
    );
    assert.withMessage(
        @src(),
        std.mem.isAlignedLog2(max_address +% 1, constants.segment_alignment_log2),
        "max_address is not 1 smaller than a segment boundary",
    );

    const map = try allocator.create(SegmentMap);

    map.min_address = min_address;
    map.max_address = max_address;

    return map;
}

pub fn segmentIndex(self: SegmentMap, ptr: Segment.ConstPtr) usize {
    assert.withMessage(@src(), self.min_address <= @intFromPtr(ptr), "address is too small");
    assert.withMessage(@src(), @intFromPtr(ptr) <= self.max_address, "address is too large");

    return (@intFromPtr(Segment.ofPtr(ptr)) - self.min_address) / constants.segment_size;
}

pub fn provision(self: *SegmentMap, segment: *Segment, ptr: Segment.ConstPtr) void {
    assert.withMessage(@src(), !self.descriptors[self.segmentIndex(ptr)].in_use, "descriptor is already in use");

    self.descriptors[self.segmentIndex(ptr)] = .{
        .in_use = true,
        .is_huge = false,
        .segment = segment,
    };
}

const std = @import("std");

const assert = @import("assert.zig");
const constants = @import("constants.zig");
const Segment = @import("Segment.zig");

test {
    std.testing.refAllDecls(@This());
}
