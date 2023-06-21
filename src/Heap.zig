thread_id: std.Thread.Id,
pages: [size_class_count]Page.List,
segments: ?Segment.Ptr,
huge_allocations: HugeAllocTable,

const Heap = @This();

pub fn init() Heap {
    return .{
        .thread_id = std.Thread.getCurrentId(),
        // WARNING: It is important that `isNullPageNode()` is used to check if the head of a page
        // list is null before any operation that may modify it or try to access the next/prev pages
        // as these pointers are undefined. Use of @constCast here should be safe as long as
        // `isNullPageNode()` is used to check before any modifications are attempted.
        .pages = .{Page.List{ .head = @constCast(&null_page_list_node) }} ** size_class_count,
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

pub const Alloc = struct {
    ptr: [*]u8,
    backing_size: usize,
};

pub fn allocate(self: *Heap, len: usize, log2_align: u8, ret_addr: usize) ?Alloc {
    if (len > constants.max_slot_size_large_page) {
        assert(@as(u32, 1) << @intCast(ShiftIntU32, log2_align) <= std.mem.page_size);
        self.huge_allocations.ensureUnusedCapacity(1) catch return null;
        const ptr = std.heap.page_allocator.rawAlloc(len, log2_align, ret_addr) orelse return null;
        self.huge_allocations.putAssumeCapacityNoClobber(@ptrToInt(ptr), {});
        return .{
            .ptr = ptr,
            .backing_size = std.mem.alignForward(len, std.mem.page_size),
        };
    }

    const aligned_size = slotSizeAligned(@intCast(u32, len), log2_align);
    const class = sizeClass(aligned_size);

    log.debugVerbose(
        "alloc: len={d}, log2_align={d}, size_class={d}",
        .{ len, log2_align, class },
    );

    const page_list = &self.pages[class];
    // we can use page_list.head is guaranteed non-null (see init())
    const page_node = page_list.head.?;

    if (page_node.data.allocSlotFast()) |buf| {
        log.debugVerbose("alloc fast path", .{});
        const aligned_address = std.mem.alignForwardLog2(@ptrToInt(buf.ptr), log2_align);
        return .{
            .ptr = @intToPtr([*]u8, aligned_address),
            .backing_size = buf.len,
        };
    }

    if (isNullPageNode(page_node)) unlikely() else {
        page_node.data.migrateFreeList();
    }

    if (page_node.data.allocSlotFast()) |buf| {
        log.debugVerbose("alloc slow path (first page)", .{});
        const aligned_address = std.mem.alignForwardLog2(@ptrToInt(buf.ptr), log2_align);
        return .{
            .ptr = @intToPtr([*]u8, aligned_address),
            .backing_size = buf.len,
        };
    }

    log.debugVerbose("alloc slow path", .{});
    const slot = slot: {
        if (isNullPageNode(page_node)) unlikely() else {
            const end = page_node;
            var node = page_node.next;
            var prev = page_node;
            while (node != end) {
                node.data.migrateFreeList();
                const in_use_count = node.data.used_count - node.data.other_freed;
                if (in_use_count == 0) {
                    deinitPage(node, page_list) catch |err|
                        log.warn("could not madvise page: {s}", .{@errorName(err)});
                    node = prev.next; // deinitPage changed prev.next to node.next
                    const segment = Segment.ofPtr(node);
                    if (segment.init_set.count() == 0) {
                        self.releaseSegment(segment);
                    }
                } else if (in_use_count < node.data.capacity) {
                    log.debugVerbose("found suitable page", .{});
                    // rotate page list
                    page_list.head = node;
                    break :slot node.data.allocSlotFast().?;
                } else {
                    prev = node;
                    node = node.next;
                }
            }
        }

        log.debugVerbose("no suitable pre-existing page found", .{});
        const new_page = self.initPage(aligned_size) catch return null;
        break :slot new_page.data.allocSlotFast().?;
    };
    const aligned_address = std.mem.alignForwardLog2(@ptrToInt(slot.ptr), log2_align);
    return .{
        .ptr = @intToPtr([*]u8, aligned_address),
        .backing_size = slot.len,
    };
}

pub fn canResize(self: *Heap, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
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

// returns the backing size of the `buf`
pub fn deallocate(self: *Heap, buf: []u8, log2_align: u8, ret_addr: usize) usize {
    log.debugVerbose(
        "free: buf.ptr={*}, buf.len={d}, log2_align={d}",
        .{ buf.ptr, buf.len, log2_align },
    );

    if (self.huge_allocations.contains(@ptrToInt(buf.ptr))) {
        log.debugVerbose("freeing huge allocation {*}", .{buf.ptr});
        std.heap.page_allocator.rawFree(buf, log2_align, ret_addr);
        assert(self.huge_allocations.remove(@ptrToInt(buf.ptr)));
        return std.mem.alignForward(buf.len, std.mem.page_size);
    }

    const segment = Segment.ofPtr(buf.ptr);
    const page_index = segment.pageIndex(buf.ptr);
    const page_node = &segment.pages[page_index];
    const page = &page_node.data;
    const slot = page.containingSlotSegment(segment, buf.ptr);
    if (std.Thread.getCurrentId() == self.thread_id) {
        log.debugVerbose("moving slot {*} to local freelist", .{slot.ptr});
        page.freeLocalAligned(slot);
    } else {
        log.debugVerbose("moving slot {*} to other freelist on thread {d}", .{ slot.ptr, self.thread_id });
        page.freeOtherAligned(slot);
    }
    return page.slot_size;
}

const HugeAllocTable = std.AutoHashMap(usize, void);

const ShiftIntU32 = std.math.Log2Int(u32);

fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
    const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), ctx));
    return if (self.allocate(len, log2_align, ret_addr)) |a| a.ptr else null;
}

fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
    const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), ctx));
    return self.canResize(buf, log2_align, new_len, ret_addr);
}

fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
    const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), ctx));
    _ = self.deallocate(buf, log2_align, ret_addr);
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

    var page_node = &segment.pages[index];
    page_node.next = page_node;
    page_node.prev = page_node;
    const page = &page_node.data;
    log.debug(
        "initialising page {d} with slot size {d} in segment {*}",
        .{ index, slot_size, segment },
    );
    page.init(slot_size, segment.pageSlice(index));
    segment.init_set.set(index);
    const class = sizeClass(slot_size);
    if (isNullPageNode(self.pages[class].head.?)) {
        // capcity == 0 means it's the null page
        unlikely();
        self.pages[class].head = page_node;
    } else {
        self.pages[class].prependOne(page_node);
    }
    return page_node;
}

fn deinitPage(
    page_node: *Page.List.Node,
    page_list: *Page.List,
) !void {
    assert(page_list.head != null);

    page_list.remove(page_node);

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

// this is used to represent an uninitialised page list so we can avoid
// a branch in the fast allocation path
const null_page_list_node = Page.List.Node{
    .data = Page{
        .local_free_list = .{ .first = null, .last = undefined },
        .alloc_free_list = .{ .first = null, .last = undefined },
        .other_free_list = .{ .first = null, .last = undefined },
        .used_count = 0,
        .other_freed = 0,
        .capacity = 0,
        .slot_size = 0,
    },
    .next = undefined,
    .prev = undefined,
};

fn isNullPageNode(page_node: *const Page.List.Node) bool {
    return page_node == &null_page_list_node;
}

// TODO: replace this attempted workaround when https://github.com/ziglang/zig/issues/5177
//       gets implemented
fn unlikely() void {
    @setCold(true);
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
