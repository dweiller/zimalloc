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
    assert.withMessage(@src(), slot_size <= max_slot_size_large_page, "slot size greater than maximum");
    if (slot_size <= max_slot_size_small_page)
        return .small
    else if (slot_size <= max_slot_size_large_page)
        return .large
    else
        unreachable;
}

pub fn ofPtr(ptr: *const anyopaque) Ptr {
    const address = std.mem.alignBackward(usize, @intFromPtr(ptr), segment_alignment);
    return @ptrFromInt(address);
}

pub fn init(heap: *Heap, page_size: PageSize) ?Ptr {
    const raw_ptr = allocateSegment() orelse return null;
    const self: Ptr = @ptrCast(raw_ptr);
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
    assert.withMessage(@src(), @intFromPtr(self) < @intFromPtr(ptr), "pointer address is lower than the page address");
    return (@intFromPtr(ptr) - @intFromPtr(self)) >> self.page_shift;
}

pub fn pageSlice(self: ConstPtr, index: usize) []align(std.mem.page_size) u8 {
    if (index == 0) {
        const segment_end = @intFromPtr(self) + @sizeOf(@This());
        const address = std.mem.alignForward(usize, segment_end, std.mem.page_size);
        const page_size = (@as(usize, 1) << self.page_shift) - segment_first_page_offset;
        const bytes_ptr: [*]align(std.mem.page_size) u8 = @ptrFromInt(address);
        return bytes_ptr[0..page_size];
    } else {
        assert.withMessage(@src(), self.page_shift == small_page_shift, "corrupt page_shift or index");
        const address = @intFromPtr(self) + index * small_page_size;
        const bytes_ptr: [*]align(std.mem.page_size) u8 = @ptrFromInt(address);
        return bytes_ptr[0..small_page_size];
    }
}

fn allocateSegment() ?*align(segment_alignment) [segment_size]u8 {
    const mmap_length = segment_size + segment_alignment - 1;
    const prot = std.os.PROT.READ | std.os.PROT.WRITE;
    const flags = std.os.MAP.PRIVATE | std.os.MAP.ANONYMOUS;
    const unaligned = std.os.mmap(null, mmap_length, prot, flags, -1, 0) catch return null;
    const unaligned_address = @intFromPtr(unaligned.ptr);
    const aligned_address = std.mem.alignForward(usize, unaligned_address, segment_alignment);
    if (aligned_address == unaligned_address) {
        std.os.munmap(unaligned[segment_size..]);
        return @alignCast(unaligned[0..segment_size]);
    } else {
        const offset = aligned_address - unaligned_address;
        std.os.munmap(unaligned[0..offset]);
        std.os.munmap(@alignCast(unaligned[offset + segment_size ..]));
        return @alignCast(unaligned[offset..][0..segment_size]);
    }
}

fn deallocateSegment(self: Ptr) void {
    const ptr: *align(segment_alignment) [segment_size]u8 = @ptrCast(self);
    std.os.munmap(ptr);
}

const PageBitSet = std.StaticBitSet(small_page_count);

const std = @import("std");

const assert = @import("assert.zig");

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
