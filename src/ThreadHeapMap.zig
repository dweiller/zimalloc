list: List = .{},
lock: std.Thread.RwLock = .{},
pool: Pool = Pool.init(std.heap.page_allocator),

const ThreadHeapMap = @This();

const List = std.DoublyLinkedList;
const Pool = std.heap.MemoryPool(Entry);

pub const Entry = struct {
    heap: Heap,
    thread_id: std.Thread.Id,
    node: List.Node,
};

pub fn deinit(self: *ThreadHeapMap) void {
    self.lock.lock();

    self.pool.deinit();
    self.* = undefined;
}

pub fn initThreadHeap(self: *ThreadHeapMap, thread_id: std.Thread.Id) ?*Entry {
    log.debugVerbose("obtaining heap lock", .{});
    self.lock.lock();
    defer self.lock.unlock();

    const entry = self.pool.create() catch return null;
    entry.* = .{
        .heap = Heap.init(),
        .thread_id = thread_id,
        .node = .{},
    };

    self.list.prepend(&entry.node);

    return entry;
}

/// behaviour is undefined if `thread_id` is not present in the map
pub fn deinitThread(self: *ThreadHeapMap, thread_id: std.Thread.Id) void {
    var iter = self.iterator(.exclusive);
    defer iter.unlock();
    while (iter.next()) |entry| {
        if (entry.thread_id == thread_id) {
            entry.heap.deinit();
            self.list.remove(&entry.node);
            return;
        }
    }
}

pub fn ownsHeap(self: *ThreadHeapMap, heap: *const Heap) bool {
    var iter = self.constIterator(.shared);
    defer iter.unlock();
    while (iter.next()) |entry| {
        if (&entry.heap == heap) return true;
    }
    return false;
}

pub const LockType = enum {
    shared,
    exclusive,
};

pub fn constIterator(self: *ThreadHeapMap, comptime kind: LockType) ConstIterator(kind) {
    switch (kind) {
        .shared => self.lock.lockShared(),
        .exclusive => self.lock.lock(),
    }
    return .{
        .current = self.list.first,
        .lock = &self.lock,
    };
}

pub fn iterator(self: *ThreadHeapMap, comptime kind: LockType) Iterator(kind) {
    switch (kind) {
        .shared => self.lock.lockShared(),
        .exclusive => self.lock.lock(),
    }
    return .{
        .current = self.list.first,
        .lock = &self.lock,
    };
}

pub fn ConstIterator(comptime kind: LockType) type {
    return BaseIterator(*const List.Node, *const Entry, kind);
}

pub fn Iterator(comptime kind: LockType) type {
    return BaseIterator(*List.Node, *Entry, kind);
}

fn BaseIterator(comptime NodeType: type, comptime EntryType: type, comptime kind: LockType) type {
    return struct {
        current: ?NodeType,
        lock: *std.Thread.RwLock,

        pub fn next(self: *@This()) ?EntryType {
            const node = self.current orelse return null;
            const result: EntryType = @fieldParentPtr("node", node);
            self.current = node.next;
            return result;
        }

        pub fn unlock(self: @This()) void {
            switch (kind) {
                .shared => self.lock.unlockShared(),
                .exclusive => self.lock.unlock(),
            }
        }
    };
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const Heap = @import("Heap.zig");
const log = @import("log.zig");
