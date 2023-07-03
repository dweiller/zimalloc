pub const Config = struct {
    // TODO: make the number of allowed threads dynamic
    memory_limit: ?usize = null,
    thread_data_prealloc: usize = 128,
    thread_safe: bool = !builtin.single_threaded,
    track_allocations: bool = false, // TODO: use this to assert usage/invariants
    safety_checks: bool = true,
};

pub fn Allocator(comptime config: Config) type {
    return struct {
        backing_allocator: std.mem.Allocator = std.heap.page_allocator,
        thread_heaps: std.SegmentedList(ThreadHeapData, config.thread_data_prealloc) = .{},
        thread_heaps_lock: std.Thread.RwLock = .{},
        // TODO: atomic access
        stats: Stats = if (config.memory_limit != null) .{} else {},

        const Self = @This();

        pub const Stats = if (config.memory_limit != null)
            struct {
                total_allocated_memory: usize = 0,
            }
        else
            void;

        const AllocData = struct {
            size: usize,
            is_huge: bool,
        };

        const Metadata = if (config.track_allocations)
            struct {
                map: std.AutoHashMapUnmanaged(usize, AllocData) = .{},
                mutex: std.Thread.Mutex = .{},
            }
        else
            void;

        const ThreadHeapData = struct {
            heap: Heap,
            huge_allocations: HugeAllocTable = .{},
            metadata: Metadata = if (config.track_allocations) .{} else {},
            owner: *Self,
        };

        pub fn init(backing_allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            return .{
                .backing_allocator = backing_allocator,
                .thread_heaps = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            var heap_iter = self.thread_heaps.iterator(0);
            while (heap_iter.next()) |heap_data| {
                if (config.track_allocations) {
                    heap_data.metadata.mutex.lock();
                    heap_data.metadata.map.deinit(self.backing_allocator);
                }
                heap_data.heap.deinit();
            }
            self.thread_heaps.deinit(self.backing_allocator);
            self.* = undefined;
        }

        fn initHeapForThread(
            self: *Self,
        ) ?*ThreadHeapData {
            const thread_id = std.Thread.getCurrentId();
            log.debug("initialising heap for thread {d}", .{thread_id});

            log.debugVerbose("obtaining heap lock", .{});
            self.thread_heaps_lock.lock();
            defer self.thread_heaps_lock.unlock();

            const new_ptr = self.thread_heaps.addOne(self.backing_allocator) catch return null;

            new_ptr.* = .{
                .heap = Heap.init(),
                .owner = self,
            };

            log.debug("heap initialised: {*}", .{new_ptr});
            return new_ptr;
        }

        fn ownsHeap(self: *const Self, heap: *const Heap) bool {
            var index: usize = 0;
            var iter = self.thread_heaps.constIterator(0);
            while (iter.next()) |heap_data| : (index += 1) {
                if (&heap_data.heap == heap) return true;
            }
            return false;
        }

        pub usingnamespace if (config.track_allocations) struct {
            pub fn getThreadData(
                self: *Self,
                ptr: *anyopaque,
                comptime hold_lock: bool,
            ) !*ThreadHeapData {
                // TODO: check this is valid on windows
                // this check also covers buf.len > constants.max_slot_size_large_page

                if (std.mem.isAligned(@intFromPtr(ptr), std.mem.page_size)) {
                    var heap_iter = self.thread_heaps.iterator(0);
                    while (heap_iter.next()) |heap_data| {
                        if (heap_data.heap.huge_allocations.contains(ptr)) {
                            const metadata = &heap_data.metadata;

                            metadata.mutex.lock();
                            defer if (!hold_lock) metadata.mutex.unlock();

                            const data = metadata.map.get(@intFromPtr(ptr)) orelse {
                                @panic("large allocation metadata is missing");
                            };
                            assert.withMessage(@src(), data.is_huge, "metadata flag is_huge is not set");
                            return heap_data;
                        }
                    }
                }

                const segment = Segment.ofPtr(ptr);
                const owning_heap = segment.heap;
                const heap_data = @fieldParentPtr(ThreadHeapData, "heap", owning_heap);
                assert.withMessage(@src(), &heap_data.heap == owning_heap, "heap metadata corrupt");

                if (config.safety_checks) if (!self.ownsHeap(owning_heap)) return error.BadHeap;

                if (hold_lock) heap_data.metadata.mutex.lock();

                return heap_data;
            }

            fn heapMetadataUnsafe(self: *Self, heap: *Heap) *Metadata {
                const thread_heap_data = @fieldParentPtr(ThreadHeapData, "heap", heap);
                assert.withMessage(@src(), self == thread_heap_data.owner, "heap not owned by allocator");
                return &thread_heap_data.metadata;
            }
        } else struct {};

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
            comptime lock_held: bool,
        ) ?[*]align(constants.min_slot_alignment) u8 {
            if (config.memory_limit) |limit| {
                assert.withMessage(@src(), self.stats.total_allocated_memory <= limit, "corrupt stats");
                if (len + self.stats.total_allocated_memory > limit) {
                    log.warn("allocation would exceed memory limit", .{});
                    return null;
                }
            }

            const thread_id = std.Thread.getCurrentId();

            log.debugVerbose("obtaining shared thread heaps lock", .{});
            self.thread_heaps_lock.lockShared();

            var iter = self.thread_heaps.iterator(0);
            while (iter.next()) |heap_data| {
                if (heap_data.heap.thread_id == thread_id) {
                    self.thread_heaps_lock.unlockShared();
                    return self.allocInHeap(heap_data, len, log2_align, ret_addr, lock_held);
                }
            } else {
                self.thread_heaps_lock.unlockShared();
                const heap_data = self.initHeapForThread() orelse return null;
                return self.allocInHeap(heap_data, len, log2_align, ret_addr, lock_held);
            }
        }

        inline fn allocInHeap(
            self: *Self,
            heap_data: *ThreadHeapData,
            len: usize,
            log2_align: u8,
            ret_addr: usize,
            comptime lock_held: bool,
        ) ?[*]align(constants.min_slot_alignment) u8 {
            const heap = &heap_data.heap;
            const metadata = &heap_data.metadata;

            assert.withMessage(
                @src(),
                heap.thread_id == std.Thread.getCurrentId(),
                "tried to allocated from wrong thread",
            );

            if (config.track_allocations) {
                if (!lock_held) metadata.mutex.lock();
                metadata.map.ensureUnusedCapacity(self.backing_allocator, 1) catch {
                    log.debug("could not allocate metadata", .{});
                    return null;
                };
            }
            defer if (config.track_allocations) if (!lock_held) {
                metadata.mutex.unlock();
            };

            const allocation = heap.allocate(len, log2_align, ret_addr) orelse return null;

            if (config.memory_limit) |limit| {
                self.stats.total_allocated_memory += allocation.backing_size;
                // TODO: this shouldn't be possible, heap.allocate() should respect
                //       the limit, and this if statement can be replaced with an assert
                if (self.stats.total_allocated_memory > limit) {
                    _ = heap.deallocate(allocation.ptr[0..len], log2_align, ret_addr);
                    self.stats.total_allocated_memory -= allocation.backing_size;
                    return null;
                }
            }

            if (config.track_allocations) {
                metadata.map.putAssumeCapacity(
                    @intFromPtr(allocation.ptr),
                    .{
                        .size = len,
                        .is_huge = len > constants.max_slot_size_large_page,
                    },
                );
            }

            return allocation.ptr;
        }

        pub fn deallocate(
            self: *Self,
            buf: []u8,
            log2_align: u8,
            ret_addr: usize,
            comptime lock_held: bool,
        ) void {
            // TODO: check this is valid on windows
            // this check also covers buf.len > constants.max_slot_size_large_page
            if (std.mem.isAligned(@intFromPtr(buf.ptr), std.mem.page_size)) {
                var heap_iter = self.thread_heaps.iterator(0);
                while (heap_iter.next()) |heap_data| {
                    if (!lock_held) heap_data.heap.huge_allocations.lock();
                    defer if (!lock_held) heap_data.heap.huge_allocations.unlock();

                    if (heap_data.heap.huge_allocations.containsRaw(buf.ptr)) {
                        if (config.track_allocations) {
                            heap_data.metadata.mutex.lock();
                            defer heap_data.metadata.mutex.unlock();
                            self.freeHugeFromHeap(&heap_data.heap, buf, log2_align, ret_addr);
                            return;
                        }

                        self.freeHugeFromHeap(&heap_data.heap, buf, log2_align, ret_addr);
                        return;
                    }
                }
            }
            assert.withMessage(@src(), buf.len <= constants.max_slot_size_large_page, "tried to free unowned pointer");

            const segment = Segment.ofPtr(buf.ptr);
            const heap = segment.heap;

            if (config.track_allocations) {
                const metadata = self.heapMetadataUnsafe(heap);

                if (!lock_held) metadata.mutex.lock();
                defer if (!lock_held) metadata.mutex.unlock();
                self.freeNonHugeFromHeap(heap, buf, log2_align, ret_addr);
                return;
            }

            self.freeNonHugeFromHeap(heap, buf, log2_align, ret_addr);
        }

        /// if tracking allocations, caller must hold metadata lock of heap owning `buf`
        pub fn freeNonHugeFromHeap(self: *Self, heap: *Heap, buf: []u8, log2_align: u8, ret_addr: usize) void {
            const segment = Segment.ofPtr(buf.ptr);

            if (config.safety_checks) if (!self.ownsHeap(heap)) {
                log.err("invalid free: {*} is not part of an owned heap", .{buf.ptr});
                return;
            };

            if (config.track_allocations) {
                const metadata = self.heapMetadataUnsafe(heap);
                assert.withMessage(@src(), metadata.map.remove(@intFromPtr(buf.ptr)), "allocation metadata is missing");
            }

            const backing_size = heap.deallocateInSegment(segment, buf, log2_align, ret_addr);

            if (config.memory_limit) |_| {
                // this might race with concurrernt alloc
                self.stats.total_allocated_memory -= backing_size;
            }
        }

        /// if tracking allocations, caller must hold metadata lock of heap owning `buf`
        pub fn freeHugeFromHeap(self: *Self, heap: *Heap, buf: []u8, log2_align: u8, ret_addr: usize) void {
            if (config.safety_checks) if (!self.ownsHeap(heap)) {
                log.err("invalid free: {*} is not part of an owned heap", .{buf.ptr});
                return;
            };

            const size = heap.deallocateHuge(buf, log2_align, ret_addr);

            if (config.memory_limit) |_| {
                self.stats.total_allocated_memory -= size;
            }

            if (config.track_allocations) {
                const metadata = self.heapMetadataUnsafe(heap);
                assert.withMessage(@src(), metadata.map.remove(@intFromPtr(buf.ptr)), "huge allocation metadata is missing");
            }
        }

        pub fn usableSizeSegment(self: *Self, ptr: *anyopaque) ?usize {
            const segment = Segment.ofPtr(ptr);

            if (config.safety_checks) if (!self.ownsHeap(segment.heap)) {
                log.err("invalid pointer: {*} is not part of an owned heap", .{ptr});
                return null;
            };

            const page_index = segment.pageIndex(ptr);
            const page_node = &segment.pages[page_index];
            const page = &page_node.data;
            const slot = page.containingSlotSegment(segment, ptr);
            const offset = @intFromPtr(ptr) - @intFromPtr(slot.ptr);
            return slot.len - offset;
        }

        pub fn usableSize(self: *Self, ptr: *anyopaque, comptime lock_held: bool) ?usize {
            if (std.mem.isAligned(@intFromPtr(ptr), std.mem.page_size)) {
                var heap_iter = self.thread_heaps.iterator(0);
                while (heap_iter.next()) |heap_data| {
                    if (!lock_held) heap_data.heap.huge_allocations.lock();
                    defer if (!lock_held) heap_data.heap.huge_allocations.unlock();

                    if (heap_data.heap.huge_allocations.getRaw(ptr)) |size| {
                        // WARNING: this depends on the implementation of std.heap.PageAllocator
                        // aligning allocated lengths to the page size
                        return std.mem.alignForward(usize, size, std.mem.page_size);
                    }
                }
            }
            return self.usableSizeSegment(ptr);
        }

        fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
            assert.withMessage(@src(), std.mem.isAligned(@intFromPtr(ctx), @alignOf(@This())), "ctx is not aligned");
            const self: *@This() = @ptrCast(@alignCast(ctx));

            return self.allocate(len, log2_align, ret_addr, false);
        }

        fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
            assert.withMessage(@src(), std.mem.isAligned(@intFromPtr(ctx), @alignOf(@This())), "ctx is not aligned");
            const self: *@This() = @ptrCast(@alignCast(ctx));

            if (config.memory_limit) |limit| {
                const new_total = self.stats.total_allocated_memory - buf.len + new_len;
                if (new_total > limit) {
                    return false;
                }
            }

            const segment = Segment.ofPtr(buf.ptr);
            const owning_heap = segment.heap;

            if (config.safety_checks) if (!self.ownsHeap(owning_heap)) {
                log.err("invalid resize: {*} is not part of an owned heap", .{buf});
                return false;
            };

            const can_resize = owning_heap.resizeInPlace(buf, log2_align, new_len, ret_addr);

            // BUG: there is a bug for memory limiting here if `buf` is a huge allocation
            //      that gets shrunk to a lower os page count (see std.heap.PageAllocator.resize)

            return can_resize;
        }

        fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
            assert.withMessage(@src(), std.mem.isAligned(@intFromPtr(ctx), @alignOf(@This())), "ctx is not aligned");
            const self: *@This() = @ptrCast(@alignCast(ctx));

            self.deallocate(buf, log2_align, ret_addr, false);
        }
    };
}

const std = @import("std");

const builtin = @import("builtin");

const assert = @import("assert.zig");
const constants = @import("constants.zig");
const log = @import("log.zig");

const Heap = @import("Heap.zig");
const HugeAllocTable = @import("HugeAllocTable.zig");
const Segment = @import("Segment.zig");
