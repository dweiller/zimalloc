pages: [size_class_count]list.Circular,
// TODO: Not using ?Segment.Ptr is a workaroiund for a compiler issue.
//       Revert this when possible, see github.com/dweiller/zimalloc/issues/15
segments: ?*align(constants.segment_alignment) Segment,

const Heap = @This();

pub fn init() Heap {
    return .{
        // WARNING: It is important that `isNullPageNode()` is used to check if the head of a page
        // list is null before any operation that may modify it or try to access the next/prev pages
        // as these pointers are undefined. Use of @constCast here should be safe as long as
        // `isNullPageNode()` is used to check before any modifications are attempted.
        .pages = .{list.Circular{ .head = @constCast(null_page_list_node) }} ** size_class_count,
        .segments = null,
    };
}

pub fn deinit(self: *Heap) void {
    var segment_iter = self.segments;
    while (segment_iter) |segment| {
        segment_iter = segment.next;
        segment.deinit();
    }
}

pub fn allocator(self: *Heap) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

pub fn allocateSizeClass(
    self: *Heap,
    class: usize,
    alignment: Alignment,
) ?[*]align(constants.min_slot_alignment) u8 {
    assert.withMessage(@src(), class < size_class_count, "requested size class is too big");

    log.debugVerbose(
        "allocateSizeClass: size class={d}, alignment={d}",
        .{ class, alignment.toByteUnits() },
    );

    const page_list = &self.pages[class];
    // page_list.head is guaranteed non-null (see init())
    const page_node = page_list.head.?;

    const head_page: *Page = @fieldParentPtr("node", page_node);

    if (head_page.allocSlotFast()) |buf| {
        log.debugVerbose("alloc fast path", .{});
        const aligned_address = alignment.forward(@intFromPtr(buf.ptr));
        return @ptrFromInt(aligned_address);
    }

    if (!isNullPageNode(page_node)) {
        head_page.migrateFreeList();
    }

    if (head_page.allocSlotFast()) |buf| {
        log.debugVerbose("alloc slow path (first page)", .{});
        const aligned_address = alignment.forward(@intFromPtr(buf.ptr));
        return @ptrFromInt(aligned_address);
    }

    log.debugVerbose("alloc slow path", .{});
    const slot = slot: {
        if (!isNullPageNode(page_node)) {
            var node = page_node.next;
            var prev = page_node;
            while (node != page_node) {
                const page: *Page = @fieldParentPtr("node", node);
                page.migrateFreeList();
                const other_freed = @atomicLoad(Page.SlotCountInt, &page.other_freed, .unordered);
                const in_use_count = page.used_count - other_freed;
                if (in_use_count == 0) {
                    deinitPage(page, page_list) catch |err|
                        log.warn("could not madvise page: {s}", .{@errorName(err)});
                    node = prev.next; // deinitPage changed prev.next to node.next
                    const segment = Segment.ofPtr(node);
                    if (segment.init_set.count() == 0) {
                        self.releaseSegment(segment);
                    }
                } else if (page.allocSlotFast()) |slot| {
                    log.debugVerbose("found suitable page with empty slot at {*}", .{slot.ptr});
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
        break :slot new_page.allocSlotFast().?;
    };
    const aligned_address = alignment.forward(@intFromPtr(slot.ptr));
    return @ptrFromInt(aligned_address);
}

pub fn allocate(
    self: *Heap,
    len: usize,
    alignment: Alignment,
    ret_addr: usize,
) ?[*]align(constants.min_slot_alignment) u8 {
    _ = ret_addr;
    log.debugVerbose(
        "allocate: len={d}, alignment={d}",
        .{ len, alignment.toByteUnits() },
    );

    const slot_size = requiredSlotSize(len, alignment);

    assert.withMessage(
        @src(),
        slot_size <= constants.max_slot_size_large_page,
        "slot size required is greater than maximum slot size",
    );

    const class = sizeClass(slot_size);

    return self.allocateSizeClass(class, alignment);
}

pub fn requiredSlotSize(len: usize, alignment: Alignment) usize {
    const next_size = indexToSize(sizeClass(len));
    const next_size_log2_align = @ctz(next_size);

    return if (@intFromEnum(alignment) <= next_size_log2_align)
        len
    else
        len + alignment.toByteUnits() - 1;
}

pub fn canResizeInPlace(
    self: *Heap,
    buf: []u8,
    alignment: Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    _ = self;
    _ = ret_addr;
    log.debugVerbose(
        "canResizeInPlace: buf.ptr={*}, buf.len={d}, alignment={d}, new_len={d}",
        .{ buf.ptr, buf.len, alignment.toByteUnits(), new_len },
    );

    const segment = Segment.ofPtr(buf.ptr);
    const page_index = segment.pageIndex(buf.ptr);
    assert.withMessage(
        @src(),
        segment.init_set.isSet(page_index),
        "segment init_set corrupt with resizing",
    );
    const page = &(segment.pages[page_index]);
    const slot = page.containingSlotSegment(segment, buf.ptr);
    return @intFromPtr(buf.ptr) + new_len <= @intFromPtr(slot.ptr) + slot.len;
}

//  behaviour is undefined if `self` does not own `buf.ptr`.
pub fn deallocate(self: *Heap, ptr: [*]u8, alignment: Alignment, ret_addr: usize) void {
    _ = self;
    _ = alignment;
    _ = ret_addr;
    const segment = Segment.ofPtr(ptr);
    log.debugVerbose("Heap.deallocate in {*}: ptr={*}", .{ segment, ptr });

    const page_index = segment.pageIndex(ptr);
    const page = &segment.pages[page_index];
    const slot = page.containingSlotSegment(segment, ptr);

    log.debugVerbose("moving slot {*} to local freelist", .{slot.ptr});
    page.freeLocalAligned(slot);
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *@This() = @ptrCast(@alignCast(ctx));
    return self.allocate(len, alignment, ret_addr);
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *@This() = @ptrCast(@alignCast(ctx));
    return self.canResizeInPlace(buf, alignment, new_len, ret_addr);
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ctx, buf, alignment, new_len, ret_addr)) buf.ptr else null;
}

fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
    const self: *@This() = @ptrCast(@alignCast(ctx));
    self.deallocate(buf.ptr, alignment, ret_addr);
}

fn getSegmentWithEmptySlot(self: *Heap, slot_size: u32) ?Segment.Ptr {
    var segment_iter = self.segments;
    while (segment_iter) |node| : (segment_iter = node.next) {
        const page_size = @as(usize, 1) << node.page_shift;
        const segment_max_slot_size = page_size / constants.min_slots_per_page;
        if (node.init_set.count() < node.page_count and segment_max_slot_size >= slot_size) {
            return node;
        }
    }
    return null;
}

fn initNewSegmentForSlotSize(self: *Heap, slot_size: u32) !Segment.Ptr {
    const page_size = Segment.pageSize(slot_size);
    const segment = Segment.init(self, page_size) orelse
        return error.OutOfMemory;
    if (self.segments) |orig_head| {
        assert.withMessage(@src(), orig_head.prev == null, "segment list head is currupt");
        orig_head.prev = segment;
    }
    log.debug("initialised new segment {*} with {s} pages", .{ segment, @tagName(page_size) });
    segment.next = self.segments;
    self.segments = segment;
    return segment;
}

/// asserts that `slot_size <= max_slot_size_large_page`
fn initPage(self: *Heap, class: usize) error{OutOfMemory}!*Page {
    const slot_size = indexToSize(class);

    assert.withMessage(
        @src(),
        slot_size <= constants.max_slot_size_large_page,
        "slot size of requested class too large",
    );

    const segment: Segment.Ptr = self.getSegmentWithEmptySlot(slot_size) orelse
        try self.initNewSegmentForSlotSize(slot_size);

    const index = index: {
        var iter = segment.init_set.iterator(.{ .kind = .unset });
        break :index iter.next().?; // segment is guaranteed to have an uninitialised page
    };
    assert.withMessage(@src(), index < segment.page_count, "segment init_set is corrupt");

    var page = &segment.pages[index];
    page.node.next = &page.node;
    page.node.prev = &page.node;
    log.debug(
        "initialising page {d} with slot size {d} in segment {*}",
        .{ index, slot_size, segment },
    );
    page.init(slot_size, segment.pageSlice(index));
    segment.init_set.set(index);

    if (isNullPageNode(self.pages[class].head.?)) {
        // capcity == 0 means it's the null page
        self.pages[class].head = &page.node;
    } else {
        self.pages[class].prependOne(&page.node);
    }
    return page;
}

fn deinitPage(
    page: *Page,
    page_list: *list.Circular,
) !void {
    assert.withMessage(@src(), page_list.head != null, "page list is empty");

    page_list.remove(&page.node);

    defer page.* = undefined;
    try page.deinit();
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
const null_page: Page = .{
    .local_free_list = .{ .first = null },
    .alloc_free_list = .{ .first = null },
    .other_free_list = .{ .first = null },
    .used_count = 0,
    .other_freed = 0,
    .capacity = 0,
    .slot_size = 0,
    .node = undefined,
};

const null_page_list_node = &null_page.node;

fn isNullPageNode(page_node: *const list.Circular.Node) bool {
    return page_node == null_page_list_node;
}

const size_class_count = size_class.count;

const std = @import("std");
const Alignment = std.mem.Alignment;

const assert = @import("assert.zig");
const list = @import("list.zig");
const log = @import("log.zig");
const constants = @import("constants.zig");

const size_class = @import("size_class.zig");
const indexToSize = size_class.branching.toSize;
const sizeClass = size_class.branching.ofSize;

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
            const ptr = try ally.create([size]u8);
            ally.destroy(ptr);
        }
    }
}

test "slot alignment" {
    var heap = Heap.init();
    defer heap.deinit();

    for (0..size_class_count) |class| {
        const ptr = heap.allocateSizeClass(class, .@"1") orelse {
            log.err("failed to allocate size class {d}", .{class});
            return error.BadSizeClass;
        };
        const actual_log2_align: std.math.Log2Int(usize) = @intCast(@ctz(@intFromPtr(ptr)));
        try std.testing.expect(@ctz(indexToSize(class)) <= actual_log2_align);
    }
    for (0..size_class_count) |class| {
        const alignment: Alignment = @enumFromInt(@ctz(indexToSize(class)));
        const ptr = heap.allocateSizeClass(class, alignment) orelse {
            log.err("failed to allocate size class {d}", .{class});
            return error.BadSizeClass;
        };
        try std.testing.expect(alignment.check(@intFromPtr(ptr)));
    }
}

test "allocate with larger alignment" {
    var heap = Heap.init();
    defer heap.deinit();

    for (0..size_class_count) |class| {
        const size = indexToSize(class);
        const slot_log2_align = @ctz(size);
        for (0..slot_log2_align) |log2_align| {
            const alignment: Alignment = @enumFromInt(log2_align);
            const ptr = heap.allocate(size, alignment, 0) orelse {
                log.err("failed to allocate size {d} with log2_align {d} (class {d})", .{
                    size, log2_align, class,
                });
                return error.BadSizeClass;
            };
            const actual_log2_align: std.math.Log2Int(usize) = @intCast(@ctz(@intFromPtr(ptr)));
            try std.testing.expect(@ctz(indexToSize(class)) <= actual_log2_align);
        }
    }

    for (0..size_class_count - 1) |class| {
        const size = indexToSize(class) / 2;
        const slot_log2_align = @ctz(size);
        const log2_align = slot_log2_align + 1;
        const ptr = heap.allocate(size, @enumFromInt(log2_align), 0) orelse {
            log.err("failed to allocate size {d} with log2_align {d} (class {d})", .{
                size, log2_align, class,
            });
            return error.BadSizeClass;
        };
        const actual_log2_align: std.math.Log2Int(usize) = @intCast(@ctz(@intFromPtr(ptr)));
        try std.testing.expect(@ctz(indexToSize(class)) <= actual_log2_align);
    }
}
