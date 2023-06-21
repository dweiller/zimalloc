pub const Config = struct {
    // TODO: make the number of allowed threads dynamic
    memory_limit: ?usize = null,
    thread_data_prealloc: usize = 128,
    thread_safe: bool = !builtin.single_threaded,
    track_allocations: bool = false, // TODO: use this to assert usage/invariants
};

pub fn Allocator(comptime config: Config) type {
    return struct {
        backing_allocator: std.mem.Allocator = std.heap.page_allocator,
        thread_heaps: std.SegmentedList(ThreadHeapData, config.thread_data_prealloc) = .{},
        heaps_mutex: std.Thread.Mutex = .{},
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
            metadata: Metadata = if (config.track_allocations) .{} else {},
        };

        pub fn init(backing_allocator: std.mem.Allocator, thread_count: usize) error{OutOfMemory}!Self {
            return .{
                .backing_allocator = backing_allocator,
                .thread_heaps = try backing_allocator.alloc(ThreadHeapData, thread_count),
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        fn initHeapForThread(
            self: *Self,
        ) ?*ThreadHeapData {
            const thread_id = std.Thread.getCurrentId();
            log.debug("initialising heap for thread {d}", .{thread_id});

            // TODO: can probably make this lock-free by re-implementing addOne()
            self.heaps_mutex.lock();
            defer self.heaps_mutex.unlock();

            // TODO: work out a better way to grow the thread_heaps slice
            const new_ptr = self.thread_heaps.addOne(self.backing_allocator) catch return null;

            new_ptr.* = .{
                .heap = Heap.init(),
            };

            log.debug("heap initialised: {*}", .{new_ptr});
            return new_ptr;
        }

        fn heapIndex(self: *const Self, heap: *const Heap) ?usize {
            var index: usize = 0;
            var iter = self.thread_heaps.constIterator(0);
            while (iter.next()) |heap_data| : (index += 1) {
                if (&heap_data.heap == heap) return index;
            }
            return null;
        }

        pub usingnamespace if (config.track_allocations) struct {
            pub fn getMetadata(self: *Self, ptr: *anyopaque) !?AllocData {
                const segment = Segment.ofPtr(ptr);
                const owning_heap = segment.heap;

                const heap_index = self.heapIndex(owning_heap) orelse return error.BadHeap;

                const metadata = &self.thread_heaps.uncheckedAt(heap_index).metadata;
                metadata.mutex.lock();
                defer metadata.mutex.unlock();
                return metadata.map.get(@ptrToInt(ptr));
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

        fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
            assert(std.mem.isAligned(@ptrToInt(ctx), @alignOf(@This())));
            const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), ctx));

            if (config.memory_limit) |limit| {
                assert(self.stats.total_allocated_memory <= limit);
                log.warn("allocation would exceed memory limit", .{});
                if (len + limit > self.stats.total_allocated_memory) return null;
            }

            const thread_id = std.Thread.getCurrentId();

            var iter = self.thread_heaps.iterator(0);
            while (iter.next()) |heap_data| {
                if (heap_data.heap.thread_id == thread_id) {
                    return self.allocInHeap(heap_data, len, log2_align, ret_addr);
                }
            } else {
                const heap_data = self.initHeapForThread() orelse return null;
                return self.allocInHeap(heap_data, len, log2_align, ret_addr);
            }
        }

        inline fn allocInHeap(self: *Self, heap_data: *ThreadHeapData, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
            const heap = &heap_data.heap;
            const metadata = &heap_data.metadata;

            assert(heap.thread_id == std.Thread.getCurrentId());

            if (config.track_allocations) {
                metadata.mutex.lock();
                metadata.map.ensureUnusedCapacity(self.backing_allocator, 1) catch {
                    log.debug("could not allocate metadata", .{});
                    return null;
                };
            }

            const allocation = heap.allocate(len, log2_align, ret_addr) orelse return null;

            if (config.memory_limit) |limit| {
                self.stats.total_allocated_memory += allocation.backing_size;
                // TODO: this shouldn't be possible, heap.allocate() should respect
                //       the limit, and this if statement can be replaced with an assert
                if (self.stats.total_allocated_memory > limit) {
                    heap.deallocate(allocation.ptr, log2_align, ret_addr);
                    self.stats.total_allocated_memory -= allocation.backing_size;
                    return null;
                }
            }

            if (config.track_allocations) {
                metadata.map.putAssumeCapacityNoClobber(@ptrToInt(allocation.ptr), .{ .size = len });
                metadata.mutex.unlock();
            }

            return allocation.ptr;
        }

        fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
            assert(std.mem.isAligned(@ptrToInt(ctx), @alignOf(@This())));
            const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), ctx));

            const new_total_allocated_memory = if (config.memory_limit) |_|
                (self.stats.total_allocated_memory - buf.len + new_len)
            else {};

            if (config.memory_limit) |limit| {
                if (new_total_allocated_memory > limit) {
                    return false;
                }
            }

            const segment = Segment.ofPtr(buf.ptr);
            const owning_heap = segment.heap;

            if (self.heapIndex(owning_heap) == null) std.debug.panic("invalid resize: {*}", .{buf});

            const can_resize = owning_heap.canResize(buf, log2_align, new_len, ret_addr);

            // BUG: there is a bug for memory limiting here if `buf` is a huge allocation
            //      that gets shrunk to a lower os page count (see std.heap.PageAllocator.resize)

            return can_resize;
        }

        fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
            assert(std.mem.isAligned(@ptrToInt(ctx), @alignOf(@This())));
            const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), ctx));

            const segment = Segment.ofPtr(buf.ptr);
            const owning_heap = segment.heap;

            const heap_index = self.heapIndex(owning_heap) orelse {
                log.warn("invalid free: {*}", .{buf.ptr});
                return;
            };

            if (config.memory_limit) |_| {
                const size = owning_heap.deallocateInSegment(segment, buf, log2_align, ret_addr);
                self.stats.total_allocated_memory -= size;
            } else {
                _ = owning_heap.deallocateInSegment(segment, buf, log2_align, ret_addr);
            }

            if (config.track_allocations) {
                const heap_data = self.thread_heaps.uncheckedAt(heap_index);
                heap_data.metadata.mutex.lock();
                assert(heap_data.metadata.map.remove(@ptrToInt(buf.ptr)));
                heap_data.metadata.mutex.unlock();
            }

            return;
        }
    };
}

const std = @import("std");
const assert = std.debug.assert;

const builtin = @import("builtin");

const log = @import("log.zig");

const Heap = @import("Heap.zig");
const Segment = @import("Segment.zig");
