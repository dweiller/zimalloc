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
pub const FreeList = list.Appendable(void);

comptime {
    if (@sizeOf(FreeList.Node) > constants.min_slot_size_usize_count * @sizeOf(usize)) {
        @compileError("FreeList.Node must fit inside the minimum slot size");
    }
    if (@alignOf(FreeList.Node) > constants.min_slot_size_usize_count * @sizeOf(usize)) {
        @compileError("FreeList.Node must have alignment no greater than the minimum slot size");
    }
}

pub fn init(self: *Page, slot_size: u32, bytes: []align(std.mem.page_size) u8) void {
    const capacity = @intCast(u16, bytes.len / slot_size);
    self.* = .{
        .local_free_list = .{ .first = null, .last = undefined },
        .alloc_free_list = .{ .first = null, .last = undefined },
        .other_free_list = .{ .first = null, .last = undefined },
        .used_count = 0,
        .other_freed = 0,
        .capacity = capacity,
        .slot_size = slot_size,
    };
    // initialise free list
    var slot_index = capacity;
    while (slot_index > 0) {
        slot_index -= 1;
        const byte_index = slot_index * slot_size;
        const slot = @alignCast(@alignOf(FreeList.Node), bytes[byte_index..][0..slot_size]);
        const node_ptr = @ptrCast(*FreeList.Node, slot);
        node_ptr.* = .{ .next = null, .data = {} };

        self.alloc_free_list.prepend(node_ptr);
    }
}

pub fn deinit(self: *Page) !void {
    const segment = Segment.ofPtr(self);
    const ptr_in_page = self.alloc_free_list.first orelse
        self.local_free_list.first orelse
        self.other_free_list.first.?;

    const page_index = segment.pageIndex(ptr_in_page);
    assert.withMessage(@src(), &segment.pages[page_index].data == self, "freelists are corrupt");

    log.debug("deiniting page {d} in segment {*}", .{ page_index, segment });
    segment.init_set.unset(page_index);

    const page_bytes = segment.pageSlice(page_index);
    try std.os.madvise(page_bytes.ptr, page_bytes.len, std.os.MADV.DONTNEED);
}

pub const Slot = []align(8) u8;

pub fn allocSlotFast(self: *Page) ?Slot {
    const node_ptr = self.alloc_free_list.popFirst() orelse return null;
    self.used_count += 1;
    return @ptrCast([*]u8, node_ptr)[0..self.slot_size];
}

pub fn migrateFreeList(self: *Page) void {
    log.debug("migrating free list: local={?*}, other_free={?*}, other_free_last={*}", .{
        self.local_free_list.first,
        self.other_free_list.first,
        self.other_free_list.last,
    });

    assert.withMessage(
        @src(),
        self.alloc_free_list.first == null,
        "migrating free lists when alloc_free_list is not empty",
    );

    var other_free_list_head = @atomicLoad(?*FreeList.Node, &self.other_free_list.first, .Monotonic);

    const other_free_list_last = self.other_free_list.last;

    while (@cmpxchgWeak(
        ?*FreeList.Node,
        &self.other_free_list.first,
        other_free_list_head,
        null,
        .Monotonic, // TODO: figure out correct atomic order
        .Monotonic, // TODO: figure out correct atomic order
    )) |head| {
        other_free_list_head = head;
    }

    if (other_free_list_head) |head| {
        const count: SlotCountInt = count: {
            var c: SlotCountInt = 1;
            var node = head.next;
            while (node) |n| : (node = n.next) c += 1;
            break :count c;
        };
        log.debug("updating other_freed: {d}, other_last: {*}", .{ count, other_free_list_last });
        _ = @atomicRmw(SlotCountInt, &self.other_freed, .Sub, count, .AcqRel);

        self.alloc_free_list = .{ .first = head, .last = other_free_list_last };
        self.alloc_free_list.appendList(self.local_free_list);

        self.used_count -= count;
    } else {
        self.alloc_free_list = self.local_free_list;
    }

    self.local_free_list.first = null;
    log.debug("finished migrating free list", .{});
}

/// returns the `Slot` containing `bytes.ptr`
pub fn containingSlot(self: *const Page, ptr: *anyopaque) Slot {
    const segment = Segment.ofPtr(self);
    return self.containingSlotSegment(segment, ptr);
}

/// returns the `Slot` containing `bytes.ptr`
pub fn containingSlotSegment(self: *const Page, segment: Segment.Ptr, ptr: *anyopaque) Slot {
    const page_slice = segment.pageSlice(segment.pageIndex(ptr));
    const page_address = @intFromPtr(page_slice.ptr);
    const bytes_address = @intFromPtr(ptr);
    const index = (bytes_address - page_address) / self.slot_size;
    const slot_address = page_address + index * self.slot_size;
    const slot = @ptrFromInt([*]align(8) u8, slot_address)[0..self.slot_size];
    return slot;
}

pub fn freeLocalAligned(self: *Page, slot: Slot) void {
    assert.withMessage(@src(), self.containingSlot(slot.ptr).ptr == slot.ptr, "tried to free local slot not in the page");
    assert.withMessage(@src(), self.used_count > 0, "tried to free local slot while used_count is 0");

    const node_ptr = @ptrCast(*FreeList.Node, slot);
    self.local_free_list.prepend(node_ptr);
    self.used_count -= 1;
}

pub fn freeOtherAligned(self: *Page, slot: Slot) void {
    assert.withMessage(@src(), self.containingSlot(slot.ptr).ptr == slot.ptr, "tried to free foreign slot not in the page");
    assert.withMessage(@src(), self.used_count > 0, "tried to free foreign slot while used_count is 0");

    const node = @ptrCast(*FreeList.Node, slot);
    node.next = @atomicLoad(?*FreeList.Node, &self.other_free_list.first, .Monotonic);
    // TODO: figure out correct atomic orders
    _ = @atomicRmw(SlotCountInt, &self.other_freed, .Add, 1, .AcqRel);
    while (@cmpxchgWeak(
        ?*FreeList.Node,
        &self.other_free_list.first,
        node.next,
        node,
        .Monotonic,
        .Monotonic,
    )) |old_value| node.next = old_value;

    if (node.next == null) self.other_free_list.last = node;
}

const std = @import("std");

const assert = @import("assert.zig");
const constants = @import("constants.zig");
const list = @import("list.zig");
const log = @import("log.zig");

const Segment = @import("Segment.zig");
