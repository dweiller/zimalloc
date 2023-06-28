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
    ptr: [*]align(constants.min_slot_alignment) u8,
    backing_size: usize,
};

pub fn allocateHuge(self: *Heap, len: usize, log2_align: u8, ret_addr: usize) ?Alloc {
    assert.withMessage(@src(), self.thread_id == std.Thread.getCurrentId(), "tried to allocate from wrong thread");

    log.debug("allocate: huge allocation len={d}, log2_align={d}", .{ len, log2_align });
    assert.withMessage(
        @src(),
        @as(usize, 1) << @intCast(log2_align) <= std.mem.page_size,
        "requested alignment is greater than the system page size",
    );

    self.huge_allocations.lock();
    defer self.huge_allocations.unlock();

    self.huge_allocations.ensureUnusedCapacityRaw(1) catch {
        log.debug("could not expand huge alloc table", .{});
        return null;
    };
    const ptr = std.heap.page_allocator.rawAlloc(len, log2_align, ret_addr) orelse return null;
    self.huge_allocations.putAssumeCapacityNoClobberRaw(ptr, len);
    return .{
        .ptr = @alignCast(ptr),
        .backing_size = std.mem.alignForward(usize, len, std.mem.page_size),
    };
}

pub fn allocateSizeClass(self: *Heap, class: usize, log2_align: u8) ?Alloc {
    assert.withMessage(@src(), class < size_class_count, "requested size class is too big");

    log.debugVerbose(
        "allocate: size class={d}, log2_align={d}",
        .{ class, log2_align },
    );

    const page_list = &self.pages[class];
    // we can use page_list.head is guaranteed non-null (see init())
    const page_node = page_list.head.?;

    if (page_node.data.allocSlotFast()) |buf| {
        log.debugVerbose("alloc fast path", .{});
        const aligned_address = std.mem.alignForwardLog2(@intFromPtr(buf.ptr), log2_align);
        return .{
            .ptr = @ptrFromInt(aligned_address),
            .backing_size = buf.len,
        };
    }

    if (isNullPageNode(page_node)) unlikely() else {
        page_node.data.migrateFreeList();
    }

    if (page_node.data.allocSlotFast()) |buf| {
        log.debugVerbose("alloc slow path (first page)", .{});
        const aligned_address = std.mem.alignForwardLog2(@intFromPtr(buf.ptr), log2_align);
        return .{
            .ptr = @ptrFromInt(aligned_address),
            .backing_size = buf.len,
        };
    }

    log.debugVerbose("alloc slow path", .{});
    const slot = slot: {
        if (isNullPageNode(page_node)) unlikely() else {
            var node = page_node.next;
            var prev = page_node;
            while (node != page_node) {
                node.data.migrateFreeList();
                const other_freed = @atomicLoad(Page.SlotCountInt, &node.data.other_freed, .Unordered);
                const in_use_count = node.data.used_count - other_freed;
                if (in_use_count == 0) {
                    deinitPage(node, page_list) catch |err|
                        log.warn("could not madvise page: {s}", .{@errorName(err)});
                    node = prev.next; // deinitPage changed prev.next to node.next
                    const segment = Segment.ofPtr(node);
                    if (segment.init_set.count() == 0) {
                        self.releaseSegment(segment);
                    }
                } else if (node.data.allocSlotFast()) |slot| {
                    log.debugVerbose("found suitable page: {?*}", .{node.data.local_free_list.first});
                    // rotate page list
                    page_list.head = node;
                    break :slot slot;
                } else {
                    prev = node;
                    node = node.next;
                }
            }
        }

        log.debugVerbose("no suitable pre-existing page found", .{});
        const new_page = self.initPage(class) catch return null;
        break :slot new_page.data.allocSlotFast().?;
    };
    const aligned_address = std.mem.alignForwardLog2(@intFromPtr(slot.ptr), log2_align);
    return .{
        .ptr = @ptrFromInt(aligned_address),
        .backing_size = slot.len,
    };
}

pub fn allocate(self: *Heap, len: usize, log2_align: u8, ret_addr: usize) ?Alloc {
    assert.withMessage(@src(), self.thread_id == std.Thread.getCurrentId(), "tried to allocate from wrond thread");
    log.debugVerbose(
        "allocate: len={d}, log2_align={d}",
        .{ len, log2_align },
    );
    if (len > constants.max_slot_size_large_page) {
        return self.allocateHuge(len, log2_align, ret_addr);
    }

    const next_size = indexToSize(sizeClass(len));
    const next_size_log2_align = @ctz(next_size);

    const slot_size_min = if (log2_align <= next_size_log2_align)
        len
    else blk: {
        const alignment = @as(usize, 1) << @intCast(log2_align);
        break :blk len + alignment - 1;
    };

    const class = sizeClass(slot_size_min);

    return self.allocateSizeClass(class, log2_align);
}

pub fn resizeInPlace(self: *Heap, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
    log.debugVerbose(
        "can resize: buf.ptr={*}, buf.len={d}, log2_align={d}, new_len={d}",
        .{ buf.ptr, buf.len, log2_align, new_len },
    );

    if (self.huge_allocations.contains(buf.ptr)) {
        return std.heap.page_allocator.rawResize(buf, log2_align, new_len, ret_addr);
    }

    const segment = Segment.ofPtr(buf.ptr);
    const page_index = segment.pageIndex(buf.ptr);
    assert.withMessage(@src(), segment.init_set.isSet(page_index), "segment init_set corrupt with resizing");
    const page_node = &(segment.pages[page_index]);
    const page = &page_node.data;
    const slot = page.containingSlotSegment(segment, buf.ptr);
    return @intFromPtr(buf.ptr) + new_len <= @intFromPtr(slot.ptr) + slot.len;
}

/// returns the backing size of the `buf`; behaviour is undefined if
/// `self` and `segment` do not own `buf.ptr`.
pub fn deallocateInSegment(
    self: *Heap,
    segment: Segment.Ptr,
    buf: []u8,
    log2_align: u8,
    ret_addr: usize,
) usize {
    _ = ret_addr;
    log.debugVerbose(
        "deallocate in {*}: buf.ptr={*}, buf.len={d}, log2_align={d}",
        .{ segment, buf.ptr, buf.len, log2_align },
    );

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

/// returns the backing size of the `buf`; behaviour is undefined if
/// `self` does not own `buf` and it's not a large allocation
/// The caller must lock `self.huge_allocations`.
pub fn deallocateHuge(self: *Heap, buf: []u8, log2_align: u8, ret_addr: usize) usize {
    log.debug("deallocate huge allocation {*}", .{buf.ptr});
    std.heap.page_allocator.rawFree(buf, log2_align, ret_addr);

    assert.withMessage(@src(), self.huge_allocations.removeRaw(buf.ptr), "huge allocation table corrupt with deallocating");
    return std.mem.alignForward(usize, buf.len, std.mem.page_size);
}

// returns the backing size of the `buf`; behaviour is undefined if
// `self` does not own `buf.ptr`.
pub fn deallocate(self: *Heap, buf: []u8, log2_align: u8, ret_addr: usize) usize {
    if (self.huge_allocations.contains(buf.ptr)) {
        return self.deallocateHuge(buf, log2_align, ret_addr);
    }
    const segment = Segment.ofPtr(buf.ptr);
    return self.deallocateInSegment(segment, buf, log2_align, ret_addr);
}

fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
    const self: *@This() = @ptrCast(@alignCast(ctx));
    return if (self.allocate(len, log2_align, ret_addr)) |a| a.ptr else null;
}

fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
    const self: *@This() = @ptrCast(@alignCast(ctx));
    return self.resizeInPlace(buf, log2_align, new_len, ret_addr);
}

fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
    const self: *@This() = @ptrCast(@alignCast(ctx));
    _ = self.deallocate(buf, log2_align, ret_addr);
}

/// asserts that `slot_size <= max_slot_size_large_page`
fn initPage(self: *Heap, class: usize) error{OutOfMemory}!*Page.List.Node {
    const slot_size = indexToSize(class);

    assert.withMessage(@src(), slot_size <= constants.max_slot_size_large_page, "slot size of requested class too large");

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
            const segment = Segment.init(self, page_size) orelse
                return error.OutOfMemory;
            if (self.segments) |orig_head| {
                assert.withMessage(@src(), orig_head.prev == null, "segment list head is currupt");
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
    assert.withMessage(@src(), index < segment.page_count, "segment init_set is corrupt");

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
    assert.withMessage(@src(), page_list.head != null, "page list is empty");

    page_list.remove(page_node);

    defer page_node.* = undefined;
    try page_node.data.deinit();
}

fn releaseSegment(self: *Heap, segment: Segment.Ptr) void {
    assert.withMessage(@src(), self.segments != null, "heap owns no segments");

    log.debug("releasing segment {*}", .{segment});
    if (self.segments.? == segment) {
        self.segments = segment.next;
    }
    if (segment.prev) |prev| prev.next = segment.next;
    if (segment.next) |next| next.prev = segment.prev;
    segment.deinit();
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

const assert = @import("assert.zig");
const log = @import("log.zig");
const constants = @import("constants.zig");

const size_class = @import("size_class.zig");
const indexToSize = size_class.branching.toSize;
const sizeClass = size_class.branching.ofSize;

const HugeAllocTable = @import("HugeAllocTable.zig");
const Page = @import("Page.zig");
const Segment = @import("Segment.zig");

test "basic validation" {
    var heap = Heap.init();
    defer heap.deinit();

    const ally = heap.allocator();

    try std.heap.testAllocator(ally);
    try std.heap.testAllocatorAligned(ally);
    try std.heap.testAllocatorLargeAlignment(ally);
    try std.heap.testAllocatorAlignedShrink(ally);
}

test "create/destroy loop" {
    var heap = Heap.init();
    defer heap.deinit();
    const ally = heap.allocator();

    inline for (0..size_class_count) |class| {
        const size = comptime indexToSize(class);
        for (0..1000) |i| {
            std.log.debug("iteration {d}", .{i});
            var ptr = try ally.create([size]u8);
            ally.destroy(ptr);
        }
    }
}
