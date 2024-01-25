pub fn ThreadHeapMap(comptime thread_data_prealloc: comptime_int) type {
    return struct {
        list: HeapList = .{},
        lock: std.Thread.RwLock = .{},

        const Self = @This();

        const HeapList = std.SegmentedList(Entry, thread_data_prealloc);

        pub const Entry = struct {
            heap: Heap,
            thread_id: std.Thread.Id,
        };

        pub fn deinit(self: *Self, allocator: Allocator) void {
            var iter = self.iterator(.exclusive);
            defer iter.unlock();

            while (iter.next()) |data| {
                data.heap.deinit();
            }
            self.list.deinit(allocator);
        }

        pub fn initThreadHeap(self: *Self, allocator: Allocator, thread_id: std.Thread.Id) ?*Entry {
            log.debugVerbose("obtaining heap lock", .{});
            self.lock.lock();
            defer self.lock.unlock();

            const new_ptr = self.list.addOne(allocator) catch return null;
            new_ptr.* = .{ .heap = Heap.init(), .thread_id = thread_id };

            return new_ptr;
        }

        pub fn ownsHeap(self: *Self, heap: *const Heap) bool {
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

        pub fn constIterator(self: *Self, comptime kind: LockType) ConstIterator(kind) {
            switch (kind) {
                .shared => self.lock.lockShared(),
                .exclusive => self.lock.lock(),
            }
            return .{
                .backing_iter = self.list.constIterator(0),
                .lock = &self.lock,
            };
        }

        pub fn iterator(self: *Self, comptime kind: LockType) Iterator(kind) {
            switch (kind) {
                .shared => self.lock.lockShared(),
                .exclusive => self.lock.lock(),
            }
            return .{
                .backing_iter = self.list.iterator(0),
                .lock = &self.lock,
            };
        }

        pub fn ConstIterator(comptime kind: LockType) type {
            return struct {
                backing_iter: HeapList.ConstIterator,
                lock: *std.Thread.RwLock,

                pub fn next(self: *@This()) ?*const Entry {
                    return self.backing_iter.next();
                }

                pub fn unlock(self: @This()) void {
                    switch (kind) {
                        .shared => self.lock.unlockShared(),
                        .exclusive => self.lock.unlock(),
                    }
                }
            };
        }

        pub fn Iterator(comptime kind: LockType) type {
            return struct {
                backing_iter: HeapList.Iterator,
                lock: *std.Thread.RwLock,

                pub fn next(self: *@This()) ?*Entry {
                    return self.backing_iter.next();
                }

                pub fn unlock(self: @This()) void {
                    switch (kind) {
                        .shared => self.lock.unlockShared(),
                        .exclusive => self.lock.unlock(),
                    }
                }
            };
        }
    };
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const Heap = @import("Heap.zig");
const log = @import("log.zig");
