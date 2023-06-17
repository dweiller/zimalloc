thread_id: std.Thread.Id,
pages: [size_class_count]Page.List,
segments: ?Segment.Ptr,
huge_allocations: HugeAllocTable,

const Heap = @This();

pub const Options = struct {};

pub fn init(options: Options) Heap {
    _ = options;
    return .{
        .thread_id = std.Thread.getCurrentId(),
        .pages = .{Page.List{ .first = null, .last = undefined }} ** size_class_count,
        .segments = null,
        .huge_allocations = HugeAllocTable.init(std.heap.page_allocator),
    };
}

pub fn deinit(self: *Heap) void {
    var segment_iter = self.segments;
    while (segment_iter) |segment| {
        segment_iter = segment.next;
        segment.deinit();
    }
    self.huge_allocations.deinit();
}

pub fn allocator(self: *Heap) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        },
    };
}

const HugeAllocTable = std.AutoHashMap(usize, void);

fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
    const self = @ptrCast(*Heap, @alignCast(@alignOf(Heap), ctx));

    const aligned_size = slotSizeAligned(len, log2_align);
    const size_class = sizeClass(aligned_size);

    if (size_class >= self.pages.len) {
        assert(@as(usize, 1) << @intCast(ShiftInt, log2_align) <= std.mem.page_size);
        self.huge_allocations.ensureUnusedCapacity(1) catch return null;
        const ptr = std.heap.page_allocator.rawAlloc(len, log2_align, ret_addr) orelse return null;
        self.huge_allocations.putAssumeCapacityNoClobber(@ptrToInt(ptr), {});
        return ptr;
    }

    log.debugVerbose(
        "alloc: len={d}, log2_align={d}, size_class={d}",
        .{ len, log2_align, size_class },
    );

    const page_list = &self.pages[size_class];
    const page_node = page_list.first orelse page_node: {
        @setCold(true);
        log.debug("no pages with size class {d}", .{size_class});
        break :page_node self.initPage(aligned_size) catch return null;
    };

    if (page_node.data.allocSlotFast()) |buf| {
        log.debugVerbose("alloc fast path", .{});
        const aligned_address = std.mem.alignForwardLog2(@ptrToInt(buf.ptr), log2_align);
        return @intToPtr([*]u8, aligned_address);
    }

    page_node.data.migrateFreeList();
    if (page_node.data.allocSlotFast()) |buf| {
        log.debugVerbose("alloc slow path (first page)", .{});
        const aligned_address = std.mem.alignForwardLog2(@ptrToInt(buf.ptr), log2_align);
        return @intToPtr([*]u8, aligned_address);
    }

    log.debugVerbose("alloc slow path", .{});
    var page_iter = page_node.next;
    var prev = page_node;
    const slot = slot: while (page_iter) |node| {
        node.data.migrateFreeList();
        const in_use_count = node.data.used_count - node.data.other_freed;
        if (in_use_count == 0) {
            deinitPage(node, page_list, prev) catch |err|
                log.warn("could not madvise page: {s}", .{@errorName(err)});
            page_iter = prev.next; // deinitPage changed prev.next to node.next
            const segment = Segment.ofPtr(node);
            if (segment.init_set.count() == 0) {
                self.releaseSegment(segment);
            }
        } else if (in_use_count < node.data.capacity) {
            log.debugVerbose("found suitable page", .{});
            // rotate free list
            if (page_list.first) |first| {
                page_list.last.next = first;
            }
            prev.next = null;
            page_list.last = prev;
            page_list.first = node;
            break :slot node.data.allocSlotFast().?;
        } else {
            prev = node;
            page_iter = node.next;
        }
    } else {
        log.debugVerbose("no suitable pre-existing page found", .{});
        const new_page = self.initPage(aligned_size) catch return null;
        break :slot new_page.data.allocSlotFast().?;
    };
    const aligned_address = std.mem.alignForwardLog2(@ptrToInt(slot.ptr), log2_align);
    return @intToPtr([*]u8, aligned_address);
}

fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
    const self = @ptrCast(*Heap, @alignCast(@alignOf(Heap), ctx));

    log.debugVerbose(
        "resize: buf.ptr={*}, buf.len={d}, log2_align={d}, new_len={d}",
        .{ buf.ptr, buf.len, log2_align, new_len },
    );

    if (self.huge_allocations.contains(@ptrToInt(buf.ptr))) {
        return std.heap.page_allocator.rawResize(buf, log2_align, new_len, ret_addr);
    }

    const segment = Segment.ofPtr(buf.ptr);
    const page_index = segment.pageIndex(buf.ptr);
    assert(segment.init_set.isSet(page_index));
    const page_node = &(segment.pages[page_index]);
    const page = &page_node.data;
    const slot = page.containingSlotSegment(segment, buf.ptr);
    return @ptrToInt(buf.ptr) + new_len <= @ptrToInt(slot.ptr) + slot.len;
}

fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
    const self = @ptrCast(*Heap, @alignCast(@alignOf(Heap), ctx));

    log.debugVerbose(
        "free: buf.ptr={*}, buf.len={d}, log2_align={d}",
        .{ buf.ptr, buf.len, log2_align },
    );

    if (self.huge_allocations.contains(@ptrToInt(buf.ptr))) {
        log.debugVerbose("freeing huge allocation {*}", .{buf.ptr});
        std.heap.page_allocator.rawFree(buf, log2_align, ret_addr);
        assert(self.huge_allocations.remove(@ptrToInt(buf.ptr)));
        return;
    }

    const segment = Segment.ofPtr(buf.ptr);
    const page_index = segment.pageIndex(buf.ptr);
    const page_node = &segment.pages[page_index];
    const page = &page_node.data;
    const slot = page.containingSlotSegment(segment, buf.ptr);
    if (std.Thread.getCurrentId() == self.thread_id) {
        log.debugVerbose("freeing slot {*} to local freelist", .{slot.ptr});
        page.freeLocalAligned(slot);
    } else {
        log.debugVerbose("freeing slot {*} to other freelist", .{slot.ptr});
        page.freeOtherAligned(slot);
    }
}

/// asserts that `slot_size <= max_slot_size_large_page`
fn initPage(self: *Heap, size: u32) error{OutOfMemory}!*Page.List.Node {
    const slot_size = indexToSize(sizeClass(size));

    assert(slot_size <= constants.max_slot_size_large_page);

    const segment: Segment.Ptr = segment: {
        var segment_iter = self.segments;
        while (segment_iter) |node| : (segment_iter = node.next) {
            const page_size = @as(usize, 1) << node.page_shift;
            const segment_max_slot_size = page_size / constants.min_slots_per_page;
            if (node.init_set.count() < node.page_count and segment_max_slot_size >= slot_size) {
                break :segment node;
            }
        } else {
            const page_size = Segment.pageSize(slot_size);
            const segment = Segment.init(page_size) orelse
                return error.OutOfMemory;
            if (self.segments) |orig_head| {
                assert(orig_head.prev == null);
                orig_head.prev = segment;
            }
            log.debug("initialised new segment: {*}", .{segment});
            segment.next = self.segments;
            self.segments = segment;
            break :segment segment;
        }
    };
    const index = index: {
        var iter = segment.init_set.iterator(.{ .kind = .unset });
        break :index iter.next().?; // segment is guaranteed to have an uninitialised page
    };
    assert(index < segment.page_count);

    const page_node = &segment.pages[index];
    const page = &page_node.data;
    log.debug(
        "initialising page {d} with slot size {d} in segment {*}",
        .{ index, slot_size, segment },
    );
    page.init(slot_size, segment.pageSlice(index));
    segment.init_set.set(index);
    self.pages[sizeClass(slot_size)].prepend(page_node);
    return page_node;
}

fn deinitPage(
    page_node: *Page.List.Node,
    page_list: *Page.List,
    prev_page_node: *Page.List.Node,
) !void {
    assert(page_list.first != null);

    if (page_list.last == page_node) {
        assert(page_node.next == null);
        page_list.last = prev_page_node;
    } else assert(page_node.next != null);
    prev_page_node.next = page_node.next;

    defer page_node.* = undefined;
    try page_node.data.deinit();
}

fn releaseSegment(self: *Heap, segment: Segment.Ptr) void {
    assert(self.segments != null);

    log.debug("releasing segment {*}", .{segment});
    if (self.segments.? == segment) {
        self.segments = segment.next;
    }
    if (segment.prev) |prev| prev.next = segment.next;
    if (segment.next) |next| next.prev = segment.prev;
    segment.deinit();
}

fn slotSizeAligned(len: usize, log2_align: u8) u32 {
    const next_size = indexToSize(sizeClass(len));
    const next_size_log2_align = @ctz(next_size);
    const alignment = @as(usize, 1) << @intCast(ShiftInt, log2_align);
    return if (log2_align <= next_size_log2_align)
        @intCast(u32, len)
    else
        @intCast(u32, len - 1 + alignment);
}

const size_class_count = sizeClass(constants.max_slot_size_large_page);

const step_1_usize_count = 8;
const step_2_usize_count = 16;
const general_step_bits = 3;
const step_shift = general_step_bits - 1;
const step_divisions = 1 << step_shift;
const step_size_base = @sizeOf(usize) * step_2_usize_count / step_divisions;
const step_offset = offset: {
    const b = leading_bit_index(step_2_usize_count);
    const extra_bits = (step_2_usize_count + 1) >> (b - step_shift);
    break :offset (b << step_shift) + extra_bits - first_general_index;
};

const first_general_index = step_1_usize_count + (step_2_usize_count - step_1_usize_count) / 2;
const last_special_size = step_2_usize_count * @sizeOf(usize);

const ShiftInt = std.math.Log2Int(usize);

fn indexToSize(index: usize) u32 {
    if (index < first_general_index) {
        if (index < step_1_usize_count) {
            return @intCast(u32, @sizeOf(usize) * (index + 1));
        } else {
            return @intCast(u32, (index - step_1_usize_count + 1) * 2 * @sizeOf(usize) +
                step_1_usize_count * @sizeOf(usize));
        }
    } else {
        const s = index - first_general_index + 1;
        const size_shift = @intCast(ShiftInt, s / step_divisions);
        const i = s % step_divisions;

        return @intCast(u32, last_special_size + i * step_size_base * 1 << size_shift);
    }
}

fn sizeClass(len: usize) usize {
    assert(len > 0);
    const usize_count = (len + @sizeOf(usize) - 1) / @sizeOf(usize);
    if (usize_count <= step_1_usize_count) {
        return usize_count - 1;
    } else if (usize_count <= step_2_usize_count) {
        return (usize_count - step_1_usize_count - 1) / 2 + step_1_usize_count;
    } else {
        const b = leading_bit_index(usize_count - 1);
        const extra_bits = (usize_count - 1) >> (b - step_shift);
        return ((@as(usize, b) << step_shift) + extra_bits) - step_offset;
    }
}

inline fn leading_bit_index(a: usize) ShiftInt {
    return @intCast(ShiftInt, @bitSizeOf(usize) - 1 - @clz(a));
}

test indexToSize {
    try std.testing.expectEqual(indexToSize(first_general_index - 1), last_special_size);
    try std.testing.expectEqual(
        indexToSize(first_general_index),
        last_special_size + last_special_size / step_divisions,
    );

    for (0..step_1_usize_count) |i| {
        try std.testing.expectEqual((i + 1) * @sizeOf(usize), indexToSize(i));
    }
    for (step_1_usize_count..first_general_index) |i| {
        try std.testing.expectEqual(
            ((step_1_usize_count) + (i - step_1_usize_count + 1) * 2) * @sizeOf(usize),
            indexToSize(i),
        );
    }
    for (first_general_index..size_class_count) |i| {
        const extra = (i - first_general_index) % step_divisions + 1;
        const rounded_index = step_divisions * ((i - first_general_index) / step_divisions);
        const base = first_general_index + rounded_index;
        const base_size = indexToSize(base - 1);
        try std.testing.expectEqual(base_size + extra * base_size / step_divisions, indexToSize(i));
    }
}

test sizeClass {
    try std.testing.expectEqual(sizeClass(last_special_size) + 1, sizeClass(last_special_size + 1));
    try std.testing.expectEqual(@as(usize, first_general_index - 1), sizeClass(last_special_size));
    try std.testing.expectEqual(@as(usize, first_general_index), sizeClass(last_special_size + 1));
    try std.testing.expectEqual(
        @as(usize, first_general_index),
        sizeClass(last_special_size + last_special_size / step_divisions - 1),
    );
}

test "sizeClass inverse of indexToSize" {
    for (0..size_class_count) |i| {
        try std.testing.expectEqual(i, sizeClass(indexToSize(i)));
    }

    for (1..@sizeOf(usize) + 1) |size| {
        try std.testing.expectEqual(indexToSize(0), indexToSize(sizeClass(size)));
    }
    for (1..size_class_count) |i| {
        for (indexToSize(i - 1) + 1..indexToSize(i) + 1) |size| {
            try std.testing.expectEqual(indexToSize(i), indexToSize(sizeClass(size)));
        }
    }
}

const std = @import("std");
const assert = std.debug.assert;

const log = @import("log.zig");

const constants = @import("constants.zig");

const Page = @import("Page.zig");
const Segment = @import("Segment.zig");
