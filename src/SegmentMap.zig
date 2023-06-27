min_address: usize,
max_address: usize,

pub const Ptr = *align(std.mem.page_size) @This();
pub const ConstPtr = *align(std.mem.page_size) const @This();

pub const SegmentDescriptor = struct {
    in_use: bool,
    is_huge: bool,
    segment: Segment,
    heap: *Heap,
    pages: [constants.small_page_count]Page.List.Node,
    init_set: PageBitSet,
};

pub const PageBitSet = std.StaticBitSet(constants.small_page_count);

const padding = std.mem.alignForward(usize, @sizeOf(@This()), @alignOf(SegmentDescriptor)) - @sizeOf(@This());

// This function depends on std.os.mmap returning zero-ed memory (and ideally not
// committing/faulting pages until they are access)
pub fn init(min_address: usize, max_address: usize) !Ptr {
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
    assert.withMessage(
        @src(),
        max_address > min_address,
        "max_address must be higher than min_address",
    );

    const segment_count = ((max_address - min_address) + 1) / constants.segment_size;
    const byte_count = @sizeOf(@This()) + padding + @sizeOf(SegmentDescriptor) * segment_count;

    const byte_ptr = std.os.mmap(
        null,
        byte_count,
        std.os.PROT.READ | std.os.PROT.WRITE,
        std.os.MAP.PRIVATE | std.os.MAP.NORESERVE | std.os.MAP.ANONYMOUS,
        -1,
        0,
    ) catch @panic("could not mmap segment map");

    const map: Ptr = @ptrCast(byte_ptr.ptr);

    map.min_address = min_address;
    map.max_address = max_address;

    return map;
}

pub fn deinit(self: Ptr) void {
    const byte_ptr: [*]align(std.mem.page_size) u8 = @ptrCast(self);
    std.os.munmap(byte_ptr[0..@sizeOf(@This())]);
}

pub fn segmentIndex(self: ConstPtr, ptr: Segment.ConstPtr) usize {
    assert.withMessage(@src(), self.min_address <= @intFromPtr(ptr), "address is too small");
    assert.withMessage(@src(), @intFromPtr(ptr) <= self.max_address, "address is too large");

    const address = @intFromPtr(Segment.startPtr(ptr));
    const adjusted_address = address - constants.min_address;

    return adjusted_address / constants.segment_size;
}

pub fn provision(self: Ptr, heap: *Heap, segment: Segment) *SegmentDescriptor {
    const index = self.segmentIndex(segment.start);

    const descriptor = &self.descriptors()[index];
    // assert.withMessage(@src(), !self.descriptors()[index].in_use, "descriptor is already in use");

    descriptor.in_use = true;
    descriptor.is_huge = false;
    descriptor.segment = segment;
    descriptor.heap = heap;
    descriptor.init_set = PageBitSet.initEmpty();
    return descriptor;
}

pub fn descriptorIndex(self: ConstPtr, ptr: *const anyopaque) usize {
    const start = Segment.startPtr(ptr);
    return self.segmentIndex(start);
}

pub fn descriptorOfPtr(self: Ptr, ptr: *const anyopaque) *SegmentDescriptor {
    return &self.descriptors()[self.descriptorIndex(ptr)];
}

fn descriptors(self: Ptr) []SegmentDescriptor {
    const count = ((self.max_address - self.min_address) + 1) / constants.segment_size;
    const ptr: [*]SegmentDescriptor = @ptrFromInt(@intFromPtr(self) + padding);
    return ptr[0..count];
}

const std = @import("std");

const assert = @import("assert.zig");
const constants = @import("constants.zig");
const Heap = @import("Heap.zig");
const Page = @import("Page.zig");
const Segment = @import("Segment.zig");

test {
    std.testing.refAllDecls(@This());
}
