local_free_list: FreeList,
alloc_free_list: FreeList,
other_free_list: FreeList,
used_count: u16,
other_freed: u16,
capacity: u16, // number of slots
slot_size: u32,

const Page = @This();

pub const List = @import("list.zig").List(Page);

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

pub const Slot = []align(8) u8;

pub fn allocSlotFast(self: *Page) ?Slot {
    const node_ptr = self.alloc_free_list.popFirst() orelse return null;
    self.used_count += 1;
    return @ptrCast([*]u8, node_ptr)[0..self.slot_size];
}

pub fn migrateFreeList(self: *Page) void {
    assert(self.alloc_free_list.first == null);
    self.alloc_free_list = self.local_free_list;
    self.local_free_list.first = null;

    var other_free_list_head = self.other_free_list.first;
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
    if (other_free_list_head) |head| self.alloc_free_list.append(head);
}

/// returns the `Slot` containing `bytes.ptr`
pub fn containingSlot(self: *const Page, ptr: *anyopaque) Slot {
    const segment = Segment.ofPtr(self);
    return self.containingSlotSegment(segment, ptr);
}

/// returns the `Slot` containing `bytes.ptr`
pub fn containingSlotSegment(self: *const Page, segment: Segment.Ptr, ptr: *anyopaque) Slot {
    const page_slice = segment.pageSlice(segment.pageIndex(ptr));
    const page_address = @ptrToInt(page_slice.ptr);
    const bytes_address = @ptrToInt(ptr);
    const index = (bytes_address - page_address) / self.slot_size;
    const slot_address = page_address + index * self.slot_size;
    const slot = @intToPtr([*]align(8) u8, slot_address)[0..self.slot_size];
    assert(slot_address <= bytes_address);
    return slot;
}

pub fn freeLocalAligned(self: *Page, slot: Slot) void {
    assert(self.containingSlot(slot.ptr).ptr == slot.ptr);
    assert(self.used_count > 0);

    const node_ptr = @ptrCast(*FreeList.Node, slot);
    self.local_free_list.prepend(node_ptr);
    self.used_count -= 1;
}

pub fn freeOtherAligned(self: *Page, slot: Slot) void {
    assert(self.containingSlot(slot.ptr).ptr == slot.ptr);

    const node = @ptrCast(*FreeList.Node, slot);
    node.next = self.other_free_list.first;
    // TODO: figure out correct atomic orders
    while (@cmpxchgWeak(
        ?*FreeList.Node,
        &self.other_free_list.first,
        node.next,
        node,
        .Monotonic,
        .Monotonic,
    )) |old_value| {
        node.next = old_value;
    }
    // TODO: figure out correct atomic order
    _ = @atomicRmw(u16, &self.other_freed, .Add, 1, .Monotonic);
}

const FreeList = @import("list.zig").List(void);
const ThreadSafeFreeList = struct {};

const min_slot_size = @sizeOf(FreeList.Node);

const std = @import("std");
const assert = std.debug.assert;

const options = @import("options");

const Segment = @import("Segment.zig");
