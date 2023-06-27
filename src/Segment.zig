page_shift: std.math.Log2Int(usize),
page_count: u32,
start: Ptr,
next: ?*Segment,
prev: ?*Segment,

const Segment = @This();

pub const Ptr = [*]align(segment_alignment) u8;
pub const ConstPtr = [*]align(segment_alignment) const u8;

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

pub fn startPtr(ptr: *const anyopaque) Ptr {
    const address = std.mem.alignBackward(usize, @intFromPtr(ptr), segment_alignment);
    return @ptrFromInt(address);
}

pub fn init(page_size: PageSize) ?Segment {
    const raw_ptr = allocateSegment() orelse return null;
    switch (page_size) {
        .small => return .{
            .page_shift = small_page_shift,
            .page_count = small_page_count,
            .start = raw_ptr,
            .next = null,
            .prev = null,
        },
        .large => return .{
            .page_shift = large_page_shift,
            .page_count = 1,
            .start = raw_ptr,
            .next = null,
            .prev = null,
        },
    }
}

pub fn deinit(self: *Segment) void {
    deallocateSegment(self.start);
    self.page_shift = 0;
    self.page_count = 0;
    self.start = undefined;
}

pub fn pageIndex(self: Segment, ptr: *const anyopaque) usize {
    assert.withMessage(
        @src(),
        @intFromPtr(self.start) <= @intFromPtr(ptr),
        "pointer address is lower than the segment start address",
    );
    assert.withMessage(
        @src(),
        @intFromPtr(ptr) < @intFromPtr(self.start) + constants.segment_size,
        "pointer address is greater than the segment end address",
    );

    return (@intFromPtr(ptr) - @intFromPtr(self.start)) >> self.page_shift;
}

pub fn pageSlice(self: Segment, index: usize) []align(std.mem.page_size) u8 {
    const page_size = @as(usize, 1) << self.page_shift;
    const address: usize = page_size * index + @intFromPtr(self.start);
    const slice_ptr: [*]u8 = @ptrFromInt(address);
    return @alignCast(slice_ptr[0..page_size]);
}

fn allocateSegment() ?*align(segment_alignment) [segment_size]u8 {
    return if (huge_alignment.allocate(segment_size, segment_alignment)) |ptr|
        @alignCast(ptr[0..segment_size])
    else
        null;
}

fn deallocateSegment(ptr: Ptr) void {
    huge_alignment.deallocate(ptr[0..constants.segment_size]);
}

const PageBitSet = std.StaticBitSet(small_page_count);

const std = @import("std");

const assert = @import("assert.zig");
const huge_alignment = @import("huge_alignment.zig");

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
