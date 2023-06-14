page_shift: u6,
pages: [small_page_count]Page.List.Node,
page_count: u32,
init_count: u32,
next: ?Ptr,
prev: ?Ptr,

const segment_alignment = 1 << 23; // 4 MiB
const segment_size = segment_alignment;

pub const small_page_size = 1 << 16; // 64 KiB
const small_page_count = segment_size / small_page_size;
pub const small_page_size_first = small_page_size - std.mem.alignForward(@sizeOf(@import("Segment.zig")), std.mem.page_size);

const small_page_shift = std.math.log2(small_page_size);
const large_page_shift = segment_alignment;

const max_slot_size_small_page = small_page_size / 8;
const max_slot_size_large_page = segment_size / 8;

pub const Ptr = *align(segment_alignment) @This();
pub const ConstPtr = *align(segment_alignment) const @This();

pub const PageSize = union(enum) {
    small,
    large,
    single: usize,
};

pub fn pageSize(slot_size: u32) PageSize {
    if (slot_size <= max_slot_size_small_page)
        return .small
    else
        todo("implment non-small page sizes");
}

pub fn ofPtr(ptr: *const anyopaque) Ptr {
    const address = std.mem.alignBackward(@ptrToInt(ptr), segment_alignment);
    return @intToPtr(Ptr, address);
}

pub fn init(page_size: PageSize) ?Ptr {
    const raw_ptr = allocateSegment() orelse return null;
    const self = @ptrCast(Ptr, raw_ptr);
    switch (page_size) {
        .small => {
            self.* = .{
                .pages = undefined,
                .page_shift = small_page_shift,
                .page_count = small_page_count,
                .init_count = 0,
                .next = null,
                .prev = null,
            };
        },
        .large => {
            todo("implement large page segments");
        },
        .single => |size| {
            _ = size;
            todo("implement single page segments");
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
    // TODO: handle non-small pages
    assert(self.page_shift == small_page_shift);

    if (index == 0) {
        const segment_end = @ptrToInt(self) + @sizeOf(@This());
        const address = std.mem.alignForward(segment_end, std.mem.page_size);
        return @alignCast(std.mem.page_size, @intToPtr([*]u8, address))[0..small_page_size_first];
    } else {
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

const std = @import("std");
const assert = std.debug.assert;

const Page = @import("Page.zig");

const todo = @import("util.zig").todo;
