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

const ShiftIntU32 = std.math.Log2Int(u32);

fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
    const self = @ptrCast(*Heap, @alignCast(@alignOf(Heap), ctx));

    if (len > constants.max_slot_size_large_page) {
        assert(@as(u32, 1) << @intCast(ShiftIntU32, log2_align) <= std.mem.page_size);
        self.huge_allocations.ensureUnusedCapacity(1) catch return null;
        const ptr = std.heap.page_allocator.rawAlloc(len, log2_align, ret_addr) orelse return null;
        self.huge_allocations.putAssumeCapacityNoClobber(@ptrToInt(ptr), {});
        return ptr;
    }

    const aligned_size = slotSizeAligned(@intCast(u32, len), log2_align);
    const class = sizeClass(aligned_size);

    log.debugVerbose(
        "alloc: len={d}, log2_align={d}, size_class={d}",
        .{ len, log2_align, class },
    );

    const page_list = &self.pages[class];
    const page_node = page_list.first orelse page_node: {
        @setCold(true);
        log.debug("no pages with size class {d}", .{class});
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

fn slotSizeAligned(len: u32, log2_align: u8) u32 {
    const next_size = indexToSize(sizeClass(len));
    const next_size_log2_align = @ctz(next_size);
    if (log2_align <= next_size_log2_align)
        return @intCast(u32, len)
    else {
        const alignment = @as(u32, 1) << @intCast(ShiftIntU32, log2_align);
        return len + alignment - 1;
    }
}

const size_class_count = size_class.count;

const std = @import("std");
const assert = std.debug.assert;

const log = @import("log.zig");

const constants = @import("constants.zig");

const size_class = @import("size_class.zig");
const indexToSize = size_class.branching.toSize;
const sizeClass = size_class.branching.ofSize;

const Page = @import("Page.zig");
const Segment = @import("Segment.zig");
