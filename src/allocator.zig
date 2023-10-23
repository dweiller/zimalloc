pub const Config = struct {
    thread_data_prealloc: usize = 128,
    thread_safe: bool = !builtin.single_threaded,
    safety_checks: bool = builtin.mode == .Debug,
};

pub fn Allocator(comptime config: Config) type {
    return struct {
        backing_allocator: std.mem.Allocator = std.heap.page_allocator,
        thread_heaps: std.SegmentedList(Heap, config.thread_data_prealloc) = .{},
        thread_heaps_lock: std.Thread.RwLock = .{},
        // TODO: atomic access
        segment_map: SegmentMap.Ptr,

        const Self = @This();

        pub fn init(backing_allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            return .{
                .backing_allocator = backing_allocator,
                .thread_heaps = .{},
                .segment_map = try SegmentMap.init(constants.min_address, constants.max_address),
            };
        }

        pub fn deinit(self: *Self) void {
            self.thread_heaps_lock.lock();
            var heap_iter = self.thread_heaps.iterator(0);
            while (heap_iter.next()) |heap| {
                heap.deinit();
            }
            self.thread_heaps.deinit(self.backing_allocator);
            self.segment_map.deinit();
            self.* = undefined;
        }

        fn initHeapForThread(
            self: *Self,
        ) ?*Heap {
            const thread_id = std.Thread.getCurrentId();
            log.debug("initialising heap for thread {d}", .{thread_id});

            log.debugVerbose("obtaining heap lock", .{});
            self.thread_heaps_lock.lock();
            defer self.thread_heaps_lock.unlock();

            const new_ptr = self.thread_heaps.addOne(self.backing_allocator) catch return null;

            new_ptr.* = Heap.init();

            log.debug("heap initialised: {*}", .{new_ptr});
            return new_ptr;
        }

        fn ownsHeap(self: *Self, heap: *const Heap) bool {
            var index: usize = 0;
            self.thread_heaps_lock.lockShared();
            defer self.thread_heaps_lock.unlockShared();
            var iter = self.thread_heaps.constIterator(0);
            while (iter.next()) |child_heap| : (index += 1) {
                if (child_heap == heap) return true;
            }
            return false;
        }

        pub const HeapAllocKind = struct {
            heap: *Heap,
            kind: union(enum) { huge: usize, segment: void },
        };

        pub const LockRetention = enum {
            drop,
            retain_shared,
            retain_exclusive,
        };

        /// Behaviour is undefined if `buf` is not owned by `self`.
        pub fn getThreadHeap(
            self: *Self,
            buf: []const u8,
            comptime locking: LockRetention,
        ) HeapAllocKind {
            if (buf.len > constants.max_slot_size_large_page) {
                self.thread_heaps_lock.lockShared();
                defer self.thread_heaps_lock.unlockShared();
                var heap_iter = self.thread_heaps.iterator(0);
                while (heap_iter.next()) |heap| {
                    switch (locking) {
                        .retain_shared, .drop => heap.huge_allocations.lockShared(),
                        .retain_exclusive => heap.huge_allocations.lock(),
                    }

                    if (heap.huge_allocations.getRaw(buf.ptr)) |size| {
                        if (locking == .drop) heap.huge_allocations.unlockShared();
                        return .{ .heap = heap, .kind = .{ .huge = size } };
                    }

                    switch (locking) {
                        .retain_shared, .drop => heap.huge_allocations.unlockShared(),
                        .retain_exclusive => heap.huge_allocations.unlock(),
                    }
                }
            }

            const descriptor = self.segment_map.descriptorOfPtr(buf.ptr);
            assert.withMessage(@src(), descriptor.in_use, "descriptor.in_use is not set");
            const heap = descriptor.heap;

            assert.withMessage(@src(), descriptor.in_use, "slice is not owned by the allocator");
            assert.withMessage(@src(), !descriptor.is_huge, "corrupt huge allocation table or segment descriptor");

            if (config.safety_checks) {
                assert.withMessage(@src(), self.ownsHeap(heap), "slice is not owned by the allocator");
            }

            return .{ .heap = heap, .kind = .segment };
        }

        pub fn getThreadHeapPtr(
            self: *Self,
            ptr: *const anyopaque,
            comptime locking: LockRetention,
        ) ?HeapAllocKind {
            // TODO: check this is valid on windows
            // this check also covers buf.len > constants.max_slot_size_large_page

            if (std.mem.isAligned(@intFromPtr(ptr), std.mem.page_size)) {
                self.thread_heaps_lock.lockShared();
                defer self.thread_heaps_lock.unlockShared();
                var heap_iter = self.thread_heaps.iterator(0);
                while (heap_iter.next()) |heap| {
                    switch (locking) {
                        .retain_shared, .drop => heap.huge_allocations.lockShared(),
                        .retain_exclusive => heap.huge_allocations.lock(),
                    }

                    if (heap.huge_allocations.getRaw(ptr)) |size| {
                        if (locking == .drop) heap.huge_allocations.unlockShared();
                        return .{ .heap = heap, .kind = .{ .huge = size } };
                    }

                    switch (locking) {
                        .retain_shared, .drop => heap.huge_allocations.unlockShared(),
                        .retain_exclusive => heap.huge_allocations.unlock(),
                    }
                }
            }

            const descriptor = self.segment_map.descriptorOfPtr(ptr);
            assert.withMessage(@src(), descriptor.in_use, "descriptor.in_use is not set");
            const heap = descriptor.heap;

            if (!descriptor.in_use) return null;
            assert.withMessage(@src(), !descriptor.is_huge, "corrupt huge allocation table or segment descriptor");

            if (config.safety_checks) {
                if (!self.ownsHeap(heap)) return null;
            }

            return .{ .heap = heap, .kind = .segment };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .free = free,
                },
            };
        }

        pub fn allocate(
            self: *Self,
            len: usize,
            log2_align: u8,
            ret_addr: usize,
        ) ?[*]align(constants.min_slot_alignment) u8 {
            log.debugVerbose("allocate: len={d} log2_align={d}", .{ len, log2_align });

            const thread_id = std.Thread.getCurrentId();

            log.debugVerbose("obtaining shared thread heaps lock", .{});
            self.thread_heaps_lock.lockShared();

            var iter = self.thread_heaps.iterator(0);
            while (iter.next()) |heap| {
                if (heap.thread_id == thread_id) {
                    self.thread_heaps_lock.unlockShared();
                    return self.allocInHeap(heap, len, log2_align, ret_addr);
                }
            } else {
                self.thread_heaps_lock.unlockShared();
                const heap = self.initHeapForThread() orelse return null;
                return self.allocInHeap(heap, len, log2_align, ret_addr);
            }
        }

        fn allocInHeap(
            self: *Self,
            heap: *Heap,
            len: usize,
            log2_align: u8,
            ret_addr: usize,
        ) ?[*]align(constants.min_slot_alignment) u8 {
            assert.withMessage(
                @src(),
                heap.thread_id == std.Thread.getCurrentId(),
                "tried to allocated from wrong thread",
            );

            const allocation = heap.allocate(self.segment_map, len, log2_align, ret_addr) orelse return null;

            return allocation.ptr;
        }

        pub fn deallocate(
            self: *Self,
            buf: []u8,
            log2_align: u8,
            ret_addr: usize,
        ) void {
            log.debugVerbose("deallocate: buf=({*}, {d}) log2_align={d}", .{ buf.ptr, buf.len, log2_align });
            const heap_kind = self.getThreadHeap(buf, .retain_exclusive);
            const heap = heap_kind.heap;

            switch (heap_kind.kind) {
                .huge => |_| {
                    self.freeHugeFromHeap(heap, buf, log2_align, ret_addr, true);
                    heap.huge_allocations.unlock();
                },
                .segment => {
                    assert.withMessage(@src(), buf.len <= constants.max_slot_size_large_page, "tried to free unowned pointer");
                    self.freeNonHugeFromHeap(heap, buf.ptr, log2_align, ret_addr);
                },
            }
        }

        pub fn freeNonHugeFromHeap(self: *Self, heap: *Heap, ptr: [*]u8, log2_align: u8, ret_addr: usize) void {
            log.debug("freeing non-huge allocation", .{});
            if (config.safety_checks) if (!self.ownsHeap(heap)) {
                log.err("invalid free: {*} is not part of an owned heap", .{ptr});
                return;
            };

            heap.deallocateInSegment(self.segment_map, ptr, log2_align, ret_addr);
        }

        pub fn freeHugeFromHeap(
            self: *Self,
            heap: *Heap,
            buf: []u8,
            log2_align: u8,
            ret_addr: usize,
            comptime lock_held: bool,
        ) void {
            if (config.safety_checks) if (!self.ownsHeap(heap)) {
                log.err("invalid free: {*} is not part of an owned heap", .{buf.ptr});
                return;
            };

            if (!lock_held) heap.huge_allocations.lock();
            heap.deallocateHuge(buf, log2_align, ret_addr);
            if (!lock_held) heap.huge_allocations.unlock();
        }

        pub fn usableSizeInSegment(self: *Self, ptr: *const anyopaque) usize {
            const descriptor = self.segment_map.descriptorOfPtr(ptr);
            assert.withMessage(@src(), descriptor.in_use, "descriptor.in_use is not set");
            const segment = descriptor.segment;

            if (config.safety_checks) if (!self.ownsHeap(descriptor.heap)) {
                log.err("invalid pointer: {*} is not part of an owned heap", .{ptr});
                return 0;
            };

            const page_index = segment.pageIndex(ptr);
            const page_node = &descriptor.pages[page_index];
            const page = &page_node.data;
            const slot = page.containingSlot(segment, ptr);
            const offset = @intFromPtr(ptr) - @intFromPtr(slot.ptr);
            return slot.len - offset;
        }

        /// Behaviour is undefined if `buf` is not owned by `self`.
        pub fn usableSize(self: *Self, buf: []const u8) usize {
            const heap_kind = self.getThreadHeap(buf, .retain_shared);
            switch (heap_kind.kind) {
                .huge => |size| {
                    heap_kind.heap.huge_allocations.unlockShared();
                    return std.mem.alignForward(usize, size, std.mem.page_size);
                },
                .segment => return self.usableSizeInSegment(buf.ptr),
            }
        }

        /// Returns zero if `ptr` is not owned by `self`
        pub fn usableSizePtr(self: *Self, ptr: *const anyopaque) usize {
            if (self.getThreadHeapPtr(ptr, .retain_shared)) |heap_kind| {
                switch (heap_kind.kind) {
                    .huge => |size| {
                        heap_kind.heap.huge_allocations.unlockShared();
                        return std.mem.alignForward(usize, size, std.mem.page_size);
                    },
                    .segment => return self.usableSizeInSegment(ptr),
                }
            }
            return 0;
        }

        /// Behaviour is undefined if `buf` is not owned by `self`.
        pub fn canResize(self: *Self, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
            // TODO: this implementation locks the huge allocation table of a containing heap twice
            const heap_kind = self.getThreadHeap(buf, .drop);
            return heap_kind.heap.resizeWithMap(self.segment_map, buf, log2_align, new_len, ret_addr);
        }

        fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
            assert.withMessage(@src(), std.mem.isAligned(@intFromPtr(ctx), @alignOf(@This())), "ctx is not aligned");
            const self: *@This() = @ptrCast(@alignCast(ctx));

            return self.allocate(len, log2_align, ret_addr);
        }

        fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
            assert.withMessage(@src(), std.mem.isAligned(@intFromPtr(ctx), @alignOf(@This())), "ctx is not aligned");
            const self: *@This() = @ptrCast(@alignCast(ctx));

            return self.canResize(buf, log2_align, new_len, ret_addr);
        }

        fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
            assert.withMessage(@src(), std.mem.isAligned(@intFromPtr(ctx), @alignOf(@This())), "ctx is not aligned");
            const self: *@This() = @ptrCast(@alignCast(ctx));

            self.deallocate(buf, log2_align, ret_addr);
        }
    };
}

const std = @import("std");

const builtin = @import("builtin");

const assert = @import("assert.zig");
const constants = @import("constants.zig");
const log = @import("log.zig");

const Heap = @import("Heap.zig");
const Segment = @import("Segment.zig");
const SegmentMap = @import("SegmentMap.zig");
