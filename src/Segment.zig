page_shift: u6,
init_set: PageBitSet,
pages: [small_page_count]Page.List.Node,
page_count: u32,
heap: *Heap,
next: ?Ptr,
prev: ?Ptr,

pub const Ptr = *align(segment_alignment) @This();
pub const ConstPtr = *align(segment_alignment) const @This();

pub const PageSize = union(enum) {
    small,
    large,
};

/// asserts that `slot_size <= max_slot_size_large_page`
pub fn pageSize(slot_size: u32) PageSize {
    assert(slot_size <= max_slot_size_large_page);
    if (slot_size <= max_slot_size_small_page)
        return .small
    else if (slot_size <= max_slot_size_large_page)
        return .large
    else
        unreachable;
}

pub fn ofPtr(ptr: *const anyopaque) Ptr {
    const address = std.mem.alignBackward(@ptrToInt(ptr), segment_alignment);
    return @intToPtr(Ptr, address);
}

pub fn init(heap: *Heap, page_size: PageSize) ?Ptr {
    const raw_ptr = allocateSegment() orelse return null;
    const self = @ptrCast(Ptr, raw_ptr);
    switch (page_size) {
        .small => {
            self.* = .{
                .pages = undefined,
                .page_shift = small_page_shift,
                .page_count = small_page_count,
                .init_set = PageBitSet.initEmpty(),
                .heap = heap,
                .next = null,
                .prev = null,
            };
        },
        .large => {
            self.* = .{
                .pages = undefined,
                .page_shift = large_page_shift,
                .page_count = 1,
                .init_set = PageBitSet.initEmpty(),
                .heap = heap,
                .next = null,
                .prev = null,
            };
        },
    }
    return self;
}

pub fn deinit(self: Ptr) void {
    self.deallocateSegment();
}

pub fn pageIndex(self: ConstPtr, ptr: *anyopaque) usize {
    assert(@ptrToInt(self) < @ptrToInt(ptr));
    return (@ptrToInt(ptr) - @ptrToInt(self)) >> self.page_shift;
}

pub fn pageSlice(self: ConstPtr, index: usize) []align(std.mem.page_size) u8 {
    if (index == 0) {
        const segment_end = @ptrToInt(self) + @sizeOf(@This());
        const address = std.mem.alignForward(segment_end, std.mem.page_size);
        const page_size = (@as(usize, 1) << self.page_shift) - segment_first_page_offset;
        return @alignCast(std.mem.page_size, @intToPtr([*]u8, address))[0..page_size];
    } else {
        assert(self.page_shift == small_page_shift);
        const address = @ptrToInt(self) + index * small_page_size;
        return @alignCast(std.mem.page_size, @intToPtr([*]u8, address))[0..small_page_size];
    }
}

fn allocateSegment() ?*align(segment_alignment) [segment_size]u8 {
    const mmap_length = segment_size + segment_alignment - 1;
    const prot = std.os.PROT.READ | std.os.PROT.WRITE;
    const flags = std.os.MAP.PRIVATE | std.os.MAP.ANONYMOUS;
    const unaligned = std.os.mmap(null, mmap_length, prot, flags, -1, 0) catch return null;
    const unaligned_address = @ptrToInt(unaligned.ptr);
    const aligned_address = std.mem.alignForward(unaligned_address, segment_alignment);
    if (aligned_address == unaligned_address) {
        std.os.munmap(unaligned[segment_size..]);
        return @alignCast(segment_alignment, unaligned[0..segment_size]);
    } else {
        const offset = aligned_address - unaligned_address;
        std.os.munmap(unaligned[0..offset]);
        std.os.munmap(@alignCast(std.mem.page_size, unaligned[offset + segment_size ..]));
        return @alignCast(segment_alignment, unaligned[offset..][0..segment_size]);
    }
}

fn deallocateSegment(self: Ptr) void {
    const ptr = @ptrCast(*align(segment_alignment) [segment_size]u8, self);
    std.os.munmap(ptr);
}

const PageBitSet = std.StaticBitSet(small_page_count);

const std = @import("std");
const assert = std.debug.assert;

const Heap = @import("Heap.zig");
const Page = @import("Page.zig");

const constants = @import("constants.zig");
const segment_alignment = constants.segment_alignment;
const segment_size = constants.segment_size;
const small_page_count = constants.small_page_count;
const small_page_size = constants.small_page_size;
const max_slot_size_small_page = constants.max_slot_size_small_page;
const max_slot_size_large_page = constants.max_slot_size_large_page;
const small_page_shift = constants.small_page_shift;
const large_page_shift = constants.large_page_shift;
const segment_first_page_offset = constants.segment_first_page_offset;
