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
            metadata: Metadata = if (config.track_allocations) .{} else {},
            owner: *Self,
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
            pub fn getMetadata(self: *Self, ptr: *anyopaque) !?AllocData {
                // TODO: check this is valid on windows
                // this check also covers buf.len > constants.max_slot_size_large_page

                if (std.mem.isAligned(@intFromPtr(ptr), std.mem.page_size)) {
                    var heap_iter = self.thread_heaps.iterator(0);
                    while (heap_iter.next()) |heap_data| {
                        if (heap_data.heap.huge_allocations.contains(ptr)) {
                            const metadata = &heap_data.metadata;
                            metadata.mutex.lock();
                            defer metadata.mutex.unlock();
                            const data = metadata.map.get(@intFromPtr(ptr)) orelse return null;
                            assert(data.is_huge);
                            return data;
                        }
                    }
                }

                const segment = Segment.ofPtr(ptr);
                const owning_heap = segment.heap;

                if (config.safety_checks) if (!self.ownsHeap(owning_heap)) return error.BadHeap;
                const metadata = self.heapMetadataUnsafe(owning_heap);
                metadata.mutex.lock();
                defer metadata.mutex.unlock();
                return metadata.map.get(@intFromPtr(ptr));
            }

            fn heapMetadataUnsafe(self: *Self, heap: *Heap) *Metadata {
                const thread_heap_data = @fieldParentPtr(ThreadHeapData, "heap", heap);
                assert(self == thread_heap_data.owner);
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

        fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
            assert(std.mem.isAligned(@intFromPtr(ctx), @alignOf(@This())));
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
                metadata.map.putAssumeCapacity(
                    @intFromPtr(allocation.ptr),
                    .{
                        .size = len,
                        .is_huge = len > constants.max_slot_size_large_page,
                    },
                );
                metadata.mutex.unlock();
            }

            return allocation.ptr;
        }

        fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
            assert(std.mem.isAligned(@intFromPtr(ctx), @alignOf(@This())));
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
            assert(std.mem.isAligned(@intFromPtr(ctx), @alignOf(@This())));
            const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), ctx));

            // TODO: check this is valid on windows
            // this check also covers buf.len > constants.max_slot_size_large_page
            if (std.mem.isAligned(@intFromPtr(buf.ptr), std.mem.page_size)) {
                var heap_iter = self.thread_heaps.iterator(0);
                while (heap_iter.next()) |heap_data| {
                    heap_data.heap.huge_allocations.lock();
                    defer heap_data.heap.huge_allocations.unlock();

                    if (heap_data.heap.huge_allocations.containsRaw(buf.ptr)) {
                        const size = heap_data.heap.deallocateHuge(buf, log2_align, ret_addr);

                        if (config.memory_limit) |_| {
                            self.stats.total_allocated_memory -= size;
                        }

                        if (config.track_allocations) {
                            heap_data.metadata.mutex.lock();
                            defer heap_data.metadata.mutex.unlock();
                            assert(heap_data.metadata.map.remove(@intFromPtr(buf.ptr)));
                        }
                        return;
                    }
                }
            }
            assert(buf.len <= constants.max_slot_size_large_page);

            const segment = Segment.ofPtr(buf.ptr);
            const owning_heap = segment.heap;

            if (config.safety_checks) if (!self.ownsHeap(owning_heap)) {
                log.err("invalid free: {*} is not part of an owned heap", .{buf.ptr});
                return;
            };

            const backing_size = owning_heap.deallocateInSegment(segment, buf, log2_align, ret_addr);

            if (config.memory_limit) |_| {
                self.stats.total_memory_allocated -= backing_size;
            }

            if (config.track_allocations) {
                const metadata = self.heapMetadataUnsafe(owning_heap);

                metadata.mutex.lock();
                defer metadata.mutex.unlock();

                assert(metadata.map.remove(@intFromPtr(buf.ptr)));
            }

            return;
        }
    };
}

const std = @import("std");
const assert = std.debug.assert;

const builtin = @import("builtin");

const constants = @import("constants.zig");
const log = @import("log.zig");

const Heap = @import("Heap.zig");
const Segment = @import("Segment.zig");
