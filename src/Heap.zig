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
    const slot_size = slotSizeAligned(len, log2_align);
    const size_class = sizeClass(slot_size);

    if (size_class >= self.pages.len) {
        self.huge_allocations.ensureUnusedCapacity(1) catch return null;
        const ptr = std.heap.page_allocator.rawAlloc(len, log2_align, ret_addr) orelse return null;
        self.huge_allocations.putAssumeCapacityNoClobber(@ptrToInt(ptr), {});
        return ptr;
    }

    const page_list = &self.pages[size_class];
    const page_node = page_list.first orelse self.initPage(slot_size) catch return null;

    if (page_node.data.allocSlotFast()) |buf| {
        log.debug("alloc fast path", .{});
        return buf.ptr;
    }

    page_node.data.migrateFreeList();
    if (page_node.data.allocSlotFast()) |buf| {
        log.debug("alloc slow path (first page)", .{});
        return buf.ptr;
    }

    log.debug("alloc slow path", .{});
    var page_iter = page_node.next;
    var prev = page_node;
    const slot = slot: while (page_iter) |node| {
        node.data.migrateFreeList();
        const in_use_count = node.data.used_count - node.data.other_freed;
        if (in_use_count == 0) {
            deinitPage(node, page_list, prev) catch |err|
                log.warn("could not madvise page: {s}", .{@errorName(err)});
            page_iter = prev.next; // deinitPage changed prev.next to node.next
        } else if (in_use_count < node.data.capacity) {
            log.debug("found suitable page", .{});
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
        log.debug("no suitable pre-existing page found", .{});
        const new_page = self.initPage(slot_size) catch return null;
        break :slot new_page.data.allocSlotFast().?;
    };
    return slot.ptr;
}

fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
    const self = @ptrCast(*Heap, @alignCast(@alignOf(Heap), ctx));

    if (self.huge_allocations.contains(@ptrToInt(buf.ptr))) {
        return std.heap.page_allocator.rawResize(buf, log2_align, new_len, ret_addr);
    }

    const segment = Segment.ofPtr(buf.ptr);
    const page_index = segment.pageIndex(buf.ptr);
    assert(segment.init_set.isSet(page_index));
    const page_node = &(segment.pages[page_index]);
    const page = &page_node.data;
    const slot = page.alignedSlot(buf);
    return @ptrToInt(buf.ptr) + new_len <= @ptrToInt(slot.ptr) + slot.len;
}

fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
    const self = @ptrCast(*Heap, @alignCast(@alignOf(Heap), ctx));

    if (self.huge_allocations.contains(@ptrToInt(buf.ptr))) {
        std.heap.page_allocator.rawFree(buf, log2_align, ret_addr);
        assert(self.huge_allocations.remove(@ptrToInt(buf.ptr)));
        return;
    }

    const segment = Segment.ofPtr(buf.ptr);
    const page_index = segment.pageIndex(buf.ptr);
    const page_node = &(segment.pages[page_index]);
    const page = &page_node.data;
    const slot = page.alignedSlot(buf);
    if (std.Thread.getCurrentId() == self.thread_id) {
        page.freeLocalAligned(slot);
    } else {
        page.freeOtherAligned(slot);
    }
}

/// asserts that `slot_size <= Segment.max_slot_size_large_page`
fn initPage(self: *Heap, slot_size: u32) error{OutOfMemory}!*Page.List.Node {
    assert(slot_size <= Segment.max_slot_size_large_page);
    const segment: Segment.Ptr = segment: {
        var segment_iter = self.segments;
        while (segment_iter) |node| : (segment_iter = node.next) {
            if (node.init_set.count() < node.page_count) {
                break :segment node;
            }
        } else {
            log.debug("initialising new segment", .{});
            const page_size = Segment.pageSize(slot_size);
            const segment = Segment.init(page_size) orelse
                return error.OutOfMemory;
            if (self.segments) |orig_head| {
                assert(orig_head.prev == null);
                orig_head.prev = segment;
            }
            log.debug("new segment: {*}", .{segment});
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

    const capacity = capacity: {
        if (index == 0) {
            break :capacity @intCast(u16, Segment.small_page_size_first / slot_size);
        }
        break :capacity @intCast(u16, Segment.small_page_size / slot_size);
    };

    const page_node = &segment.pages[index];
    const page = &page_node.data;
    log.debug("initialising page {d} in segment {*}", .{ index, segment });
    page.init(slot_size, capacity, segment.pageSlice(index));
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

    const segment = Segment.ofPtr(page_node);
    const ptr_in_page = page_node.data.alloc_free_list.first orelse
        page_node.data.local_free_list.first orelse
        page_node.data.other_free_list.first.?;

    const page_index = segment.pageIndex(ptr_in_page);
    assert(&segment.pages[page_index] == page_node);

    log.debug("deiniting page {d} in segment {*}", .{ page_index, segment });

    const page_bytes = segment.pageSlice(page_index);

    if (page_list.last == page_node) {
        assert(page_node.next == null);
        page_list.last = prev_page_node;
    } else assert(page_node.next != null);
    prev_page_node.next = page_node.next;

    segment.init_set.unset(page_index);
    page_node.* = undefined;

    try std.os.madvise(page_bytes.ptr, page_bytes.len, std.os.MADV.DONTNEED);
}

fn slotSizeAligned(len: usize, log2_align: u8) u32 {
    const alignment = @as(usize, 1) << @intCast(ShiftInt, log2_align);
    return @intCast(u32, if (alignment <= len) len else len - 1 + alignment);
}

const size_class_count = sizeClass(Segment.max_slot_size_large_page);

const step_1_usize_count = 8;
const step_2_usize_count = 16;
const general_step_bits = 3;
const step_shift = general_step_bits - 1;
const step_divisions = 1 << step_shift;
const step_size_base = @sizeOf(usize) * step_2_usize_count / step_divisions;
const step_offset = offset: {
    const b = leading_bit_index(step_2_usize_count);
    const extra_bits = (step_2_usize_count + 1) >> (b - step_shift);
    break :offset (b << step_shift) + extra_bits - (last_special_index + 1);
};

const last_special_index = step_1_usize_count + (step_2_usize_count - step_1_usize_count) / 2 - 1;
const last_special_size = step_2_usize_count * @sizeOf(usize);

const ShiftInt = std.math.Log2Int(usize);

comptime {
    assert(sizeClass(last_special_size) + 1 == sizeClass(last_special_size + 1));
    assert(indexToSize(last_special_index) == last_special_size);
    assert(indexToSize(last_special_index + 1) == last_special_size + last_special_size / step_divisions);
}

fn indexToSize(index: usize) usize {
    if (index <= last_special_index) {
        if (index < step_1_usize_count) {
            return @sizeOf(usize) * (index + 1);
        } else {
            return (index - step_1_usize_count + 1) * 2 * @sizeOf(usize) +
                step_1_usize_count * @sizeOf(usize);
        }
    } else {
        const s = index - last_special_index;
        const size_shift = @intCast(ShiftInt, s / step_divisions);
        const i = s % step_divisions;

        return last_special_size + i * step_size_base * 1 << size_shift;
    }
}

fn sizeClass(len: usize) usize {
    const usize_count = (len + @sizeOf(usize) - 1) / @sizeOf(usize);
    if (usize_count <= step_1_usize_count) {
        return usize_count - 1;
    } else if (usize_count <= step_2_usize_count) {
        return (usize_count - step_1_usize_count - 1) / 2 + step_1_usize_count;
    } else {
        const b = leading_bit_index(usize_count - 1);
        const extra_bits = usize_count >> (b - step_shift);
        return ((@as(usize, b) << step_shift) + extra_bits) - step_offset;
    }
}

inline fn leading_bit_index(a: usize) std.math.Log2Int(usize) {
    return @intCast(std.math.Log2Int(usize), @bitSizeOf(usize) - 1 - @clz(a));
}

const log = std.log.scoped(.zimalloc);

const std = @import("std");
const assert = std.debug.assert;

const Page = @import("Page.zig");
const Segment = @import("Segment.zig");
