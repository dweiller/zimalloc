local_free_list: FreeList,
alloc_free_list: FreeList,
other_free_list: FreeList,
used_count: SlotCountInt,
other_freed: SlotCountInt,
capacity: u16, // number of slots
slot_size: u32,

const Page = @This();

pub const SlotCountInt = std.math.IntFittingRange(0, constants.small_page_size / @sizeOf(usize));

pub const List = list.Circular(Page);
const FreeList = std.SinglyLinkedList;

comptime {
    if (@sizeOf(FreeList.Node) > constants.min_slot_size) {
        @compileError("FreeList.Node must fit inside the minimum slot size");
    }
    if (@alignOf(FreeList.Node) > constants.min_slot_alignment) {
        @compileError("FreeList.Node must have alignment no greater than the minimum slot alignment");
    }
}

pub fn init(self: *Page, slot_size: u32, bytes: []align(std.heap.page_size_min) u8) void {
    log.debug("initialising page with slot size {d} at {*} ({d} bytes)", .{
        slot_size, bytes.ptr, bytes.len,
    });
    const first_slot_address = firstSlotAddress(@intFromPtr(bytes.ptr), slot_size);
    const offset = first_slot_address - @intFromPtr(bytes.ptr);
    const capacity: u16 = @intCast((bytes.len - offset) / slot_size);
    assert.withMessage(@src(), capacity == bytes.len / slot_size, "capacity not correct");
    self.* = .{
        .local_free_list = .{ .first = null },
        .alloc_free_list = .{ .first = null },
        .other_free_list = .{ .first = null },
        .used_count = 0,
        .other_freed = 0,
        .capacity = capacity,
        .slot_size = slot_size,
    };
    // initialise free list
    var slot_index = capacity;
    while (slot_index > 0) {
        slot_index -= 1;
        const slot = slotAtIndex(first_slot_address, slot_index, slot_size);
        const node_ptr: *FreeList.Node = @alignCast(@ptrCast(slot));
        node_ptr.next = null;

        self.alloc_free_list.prepend(node_ptr);
    }
}

pub fn deinit(self: *Page) !void {
    const segment = Segment.ofPtr(self);
    const ptr_in_page = self.getPtrInFreeSlot();

    const page_index = segment.pageIndex(ptr_in_page);
    assert.withMessage(@src(), &segment.pages[page_index].data == self, "freelists are corrupt");

    log.debug("deiniting page {d} in segment {*}", .{ page_index, segment });
    segment.init_set.unset(page_index);

    const page_bytes = segment.pageSlice(page_index);
    try std.posix.madvise(page_bytes.ptr, page_bytes.len, std.posix.MADV.DONTNEED);
}

pub fn getPtrInFreeSlot(self: *const Page) *align(constants.min_slot_alignment) anyopaque {
    return self.alloc_free_list.first orelse
        self.local_free_list.first orelse
        self.other_free_list.first orelse {
        assert.withMessage(@src(), false, "all freelists are empty");
        unreachable;
    };
}

pub const Slot = []align(constants.min_slot_alignment) u8;

pub fn allocSlotFast(self: *Page) ?Slot {
    const node_ptr = self.alloc_free_list.popFirst() orelse return null;
    const casted_ptr: [*]align(constants.min_slot_alignment) u8 = @ptrCast(node_ptr);
    self.used_count += 1;
    @memset(casted_ptr[0..self.slot_size], undefined);
    return @ptrCast(casted_ptr[0..self.slot_size]);
}

pub fn migrateFreeList(self: *Page) void {
    log.debug("migrating free list: local={?*}, other_free={?*}", .{
        self.local_free_list.first,
        self.other_free_list.first,
    });

    assert.withMessage(
        @src(),
        self.alloc_free_list.first == null,
        "migrating free lists when alloc_free_list is not empty",
    );

    const other_free_list_head = @atomicRmw(
        ?*FreeList.Node,
        &self.other_free_list.first,
        .Xchg,
        null,
        .monotonic,
    );

    self.alloc_free_list.first = self.local_free_list.first;
    self.local_free_list.first = null;

    if (other_free_list_head) |head| {
        var count: SlotCountInt = 0;
        var node: ?*FreeList.Node = head;
        while (node) |n| {
            node = n.next; // an infinite loop occurs if this happends after prepend() below
            count += 1;
            self.alloc_free_list.prepend(n);
        }
        log.debug("updating other_freed: {d}", .{count});
        _ = @atomicRmw(SlotCountInt, &self.other_freed, .Sub, count, .acq_rel);

        self.used_count -= count;
    }

    log.debug("finished migrating free list", .{});
}

fn firstSlotAddress(page_address: usize, slot_size: usize) usize {
    return std.mem.alignForwardLog2(page_address, @ctz(slot_size));
}

fn slotAtIndex(first_slot_address: usize, index: usize, slot_size: usize) Slot {
    const slot_address = first_slot_address + index * slot_size;
    const slot_ptr: [*]align(constants.min_slot_alignment) u8 = @ptrFromInt(slot_address);
    return slot_ptr[0..slot_size];
}

fn slotIndexOfPtr(first_slot_address: usize, slot_size: usize, ptr: *const anyopaque) usize {
    const bytes_address = @intFromPtr(ptr);
    return (bytes_address - first_slot_address) / slot_size;
}

/// returns the `Slot` containing `bytes.ptr`
pub fn containingSlot(self: *const Page, ptr: *const anyopaque) Slot {
    const segment = Segment.ofPtr(self);
    return self.containingSlotSegment(segment, ptr);
}

/// returns the `Slot` containing `bytes.ptr`
pub fn containingSlotSegment(self: *const Page, segment: Segment.Ptr, ptr: *const anyopaque) Slot {
    const page_slice = segment.pageSlice(segment.pageIndex(ptr));
    const first_slot_address = firstSlotAddress(@intFromPtr(page_slice.ptr), self.slot_size);
    const index = slotIndexOfPtr(first_slot_address, self.slot_size, ptr);
    return slotAtIndex(first_slot_address, index, self.slot_size);
}

pub fn freeLocalAligned(self: *Page, slot: Slot) void {
    assert.withMessage(
        @src(),
        self.containingSlot(slot.ptr).ptr == slot.ptr,
        "tried to free local slot not in the page",
    );
    assert.withMessage(@src(), self.used_count > 0, "tried to free local slot while used_count is 0");

    const node_ptr: *FreeList.Node = @ptrCast(slot);
    self.local_free_list.prepend(node_ptr);
    self.used_count -= 1;
}

pub fn freeOtherAligned(self: *Page, slot: Slot) void {
    assert.withMessage(
        @src(),
        self.containingSlot(slot.ptr).ptr == slot.ptr,
        "tried to free foreign slot not in the page",
    );
    assert.withMessage(@src(), self.used_count > 0, "tried to free foreign slot while used_count is 0");

    const node: *FreeList.Node = @ptrCast(slot);
    node.next = @atomicLoad(?*FreeList.Node, &self.other_free_list.first, .monotonic);
    // TODO: figure out correct atomic orders
    _ = @atomicRmw(SlotCountInt, &self.other_freed, .Add, 1, .acq_rel);
    while (@cmpxchgWeak(
        ?*FreeList.Node,
        &self.other_free_list.first,
        node.next,
        node,
        .monotonic,
        .monotonic,
    )) |old_value| node.next = old_value;
}

const std = @import("std");

const assert = @import("assert.zig");
const constants = @import("constants.zig");
const list = @import("list.zig");
const log = @import("log.zig");

const Segment = @import("Segment.zig");
