pub const Config = struct {
    memory_limit: ?usize = null,
    thread_safe: bool = !builtin.single_threaded,
};

pub fn Allocator(comptime config: Config) type {
    return struct {
        backing_allocator: std.mem.Allocator = std.heap.page_allocator,
        thread_heaps: []Heap = &.{},
        thread_heaps_len: usize = 0,
        stats: Stats = if (config.memory_limit != null) .{} else {},

        const Self = @This();

        pub const Stats = if (config.memory_limit != null)
            struct {
                total_allocated_memory: usize = 0,
            }
        else
            void;

        pub fn init(backing_allocator: std.mem.Allocator, thread_count: usize) error{OutOfMemory}!Self {
            return .{
                .backing_allocator = backing_allocator,
                .thread_heaps = try backing_allocator.alloc(Heap, thread_count),
                .thread_heaps_len = thread_count,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn initHeapForThread(
            self: *Self,
            thread_id: std.Thread.Id,
        ) error{OutOfMemory}!*Heap {
            assert(self.thread_heaps_len <= self.thread_heaps.len);

            for (self.thread_heaps) |heap| {
                assert(heap.thread_id != thread_id);
            }

            const index = self.thread_heaps_len;

            if (self.thread_heaps.len == self.thread_heaps_len) {
                const new_count = self.thread_heaps_len + 1;
                const new_list = try self.backing_allocator.realloc(self.thread_heaps, new_count);
                self.thread_heaps = new_list;
            }

            self.thread_heaps[index] = Heap.init();
            self.thread_heaps_len += 1;
            return &self.thread_heaps[index];
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

        fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
            assert(std.mem.isAligned(@ptrToInt(ctx), @alignOf(@This())));
            const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), ctx));

            if (config.memory_limit) |limit| {
                assert(self.stats.total_allocated_memory <= limit);
                if (len + limit > self.stats.total_allocated_memory) return null;
            }

            const thread_id = std.Thread.getCurrentId();

            for (self.thread_heaps) |*heap| {
                if (heap.thread_id == thread_id) {
                    return self.allocInHeap(heap, len, log2_align, ret_addr);
                }
            } else {
                const heap = self.initHeapForThread(thread_id) catch return null;
                return self.allocInHeap(heap, len, log2_align, ret_addr);
            }
        }

        inline fn allocInHeap(self: *Self, heap: *Heap, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
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

            const thread_id = std.Thread.getCurrentId();

            for (self.thread_heaps) |*heap| {
                if (heap.thread_id == thread_id) {
                    const can_resize = heap.canResize(buf, log2_align, new_len, ret_addr);

                    if (config.memory_limit) |_| if (can_resize) {
                        self.stats.total_allocated_memory = new_total_allocated_memory;
                    };

                    return can_resize;
                }
            } else {
                // invalid resize
                @panic("invalid free");
            }
        }

        fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
            assert(std.mem.isAligned(@ptrToInt(ctx), @alignOf(@This())));
            const self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), ctx));

            const thread_id = std.Thread.getCurrentId();

            for (self.thread_heaps) |*heap| {
                if (heap.thread_id == thread_id) {
                    if (config.memory_limit) |_| {
                        const size = heap.deallocate(buf, log2_align, ret_addr);
                        self.stats.total_allocated_memory -= size;
                    } else {
                        _ = heap.deallocate(buf, log2_align, ret_addr);
                    }
                    return;
                }
            } else {
                // invalid free
            }
        }
    };
}
const std = @import("std");
const assert = std.debug.assert;

const builtin = @import("builtin");

const Heap = @import("Heap.zig");
