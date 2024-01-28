pub const Config = struct {
    thread_data_prealloc: usize = 128,
    thread_safe: bool = !builtin.single_threaded,
    safety_checks: bool = builtin.mode == .Debug,
    store_huge_alloc_size: bool = false,
};

pub fn Allocator(comptime config: Config) type {
    return struct {
        backing_allocator: std.mem.Allocator = std.heap.page_allocator,
        thread_heaps: std.SegmentedList(HeapData, config.thread_data_prealloc) = .{},
        thread_heaps_lock: std.Thread.RwLock = .{},
        huge_allocations: HugeAllocTable(config.store_huge_alloc_size) = .{},
        // TODO: atomic access

        const Self = @This();

        const HeapData = struct {
            heap: Heap,
            thread_id: std.Thread.Id,
        };

        pub fn init(backing_allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            return .{
                .backing_allocator = backing_allocator,
                .thread_heaps = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.thread_heaps_lock.lock();
            var heap_iter = self.thread_heaps.iterator(0);
            while (heap_iter.next()) |data| {
                data.heap.deinit();
            }
            self.thread_heaps.deinit(self.backing_allocator);
            self.huge_allocations.deinit(std.heap.page_allocator);
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

            new_ptr.* = .{ .heap = Heap.init(), .thread_id = thread_id };

            log.debug("heap initialised: {*}", .{&new_ptr.heap});
            return &new_ptr.heap;
        }

        fn ownsHeap(self: *Self, heap: *const Heap) bool {
            self.thread_heaps_lock.lockShared();
            defer self.thread_heaps_lock.unlockShared();
            var iter = self.thread_heaps.constIterator(0);
            while (iter.next()) |child_data| {
                if (&child_data.heap == heap) return true;
            }
            return false;
        }

        pub fn getThreadHeap(
            self: *Self,
            ptr: *const anyopaque,
        ) ?*Heap {
            const segment = Segment.ofPtr(ptr);
            const heap = segment.heap;

            if (config.safety_checks) {
                if (!self.ownsHeap(heap)) return null;
            }

            return heap;
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

            if (Heap.requiredSlotSize(len, log2_align) > constants.max_slot_size_large_page) {
                return self.allocateHuge(len, log2_align, ret_addr);
            }

            const thread_id = std.Thread.getCurrentId();

            log.debugVerbose("obtaining shared thread heaps lock", .{});
            self.thread_heaps_lock.lockShared();

            var iter = self.thread_heaps.iterator(0);
            while (iter.next()) |data| {
                if (data.thread_id == thread_id) {
                    self.thread_heaps_lock.unlockShared();
                    return self.allocInHeap(&data.heap, len, log2_align, ret_addr);
                }
            } else {
                self.thread_heaps_lock.unlockShared();
                const heap = self.initHeapForThread() orelse return null;
                return self.allocInHeap(heap, len, log2_align, ret_addr);
            }
        }

        pub fn allocateHuge(self: *Self, len: usize, log2_align: u8, ret_addr: usize) ?[*]align(std.mem.page_size) u8 {
            log.debug("allocateHuge: len={d}, log2_align={d}", .{ len, log2_align });

            self.huge_allocations.lock();
            defer self.huge_allocations.unlock();

            self.huge_allocations.ensureUnusedCapacityRaw(std.heap.page_allocator, 1) catch {
                log.debug("could not expand huge alloc table", .{});
                return null;
            };

            const ptr = if (@as(usize, 1) << @intCast(log2_align) > std.mem.page_size)
                (huge_alignment.allocate(len, @as(usize, 1) << @intCast(log2_align)) orelse return null).ptr
            else
                std.heap.page_allocator.rawAlloc(len, log2_align, ret_addr) orelse return null;

            self.huge_allocations.putAssumeCapacityNoClobberRaw(ptr, len);
            return @alignCast(ptr);
        }

        fn allocInHeap(
            self: *Self,
            heap: *Heap,
            len: usize,
            log2_align: u8,
            ret_addr: usize,
        ) ?[*]align(constants.min_slot_alignment) u8 {
            _ = self;
            assert.withMessage(
                @src(),
                @fieldParentPtr(HeapData, "heap", heap).thread_id == std.Thread.getCurrentId(),
                "tried to allocated from wrong thread",
            );

            return heap.allocate(len, log2_align, ret_addr);
        }

        pub fn deallocate(
            self: *Self,
            buf: []u8,
            log2_align: u8,
            ret_addr: usize,
        ) void {
            log.debugVerbose("deallocate: buf=({*}, {d}) log2_align={d}", .{ buf.ptr, buf.len, log2_align });
            // TODO: check this is valid on windows
            // this check also covers buf.len > constants.max_slot_size_large_page
            if (std.mem.isAligned(@intFromPtr(buf.ptr), std.mem.page_size)) {
                self.huge_allocations.lock();
                defer self.huge_allocations.unlock();
                if (self.huge_allocations.containsRaw(buf.ptr)) {
                    self.freeHuge(buf, log2_align, ret_addr, true);
                    return;
                }
            }
            assert.withMessage(@src(), buf.len <= constants.max_slot_size_large_page, "tried to free unowned pointer");

            const segment = Segment.ofPtr(buf.ptr);
            const heap = segment.heap;

            self.freeNonHugeFromHeap(heap, buf.ptr, log2_align, ret_addr);
        }

        pub fn freeNonHugeFromHeap(self: *Self, heap: *Heap, ptr: [*]u8, log2_align: u8, ret_addr: usize) void {
            log.debug("freeing non-huge allocation", .{});
            if (config.safety_checks) if (!self.ownsHeap(heap)) {
                log.err("invalid free: {*} is not part of an owned heap", .{ptr});
                return;
            };

            _ = log2_align;
            _ = ret_addr;
            const segment = Segment.ofPtr(ptr);
            log.debugVerbose("deallocate in heap {*}: segment={*}, ptr={*}", .{ heap, segment, ptr });

            const page_index = segment.pageIndex(ptr);
            const page_node = &segment.pages[page_index];
            const page = &page_node.data;
            const slot = page.containingSlotSegment(segment, ptr);

            const thread_id = @fieldParentPtr(HeapData, "heap", heap).thread_id;

            if (std.Thread.getCurrentId() == thread_id) {
                log.debugVerbose("moving slot {*} to local freelist", .{slot.ptr});
                page.freeLocalAligned(slot);
            } else {
                log.debugVerbose("moving slot {*} to other freelist on thread {d}", .{ slot.ptr, thread_id });
                page.freeOtherAligned(slot);
            }
        }

        pub fn freeHuge(
            self: *Self,
            buf: []u8,
            log2_align: u8,
            ret_addr: usize,
            comptime lock_held: bool,
        ) void {
            if (!lock_held) self.huge_allocations.lock();
            defer if (!lock_held) self.huge_allocations.unlock();

            if (self.huge_allocations.containsRaw(buf.ptr)) {
                log.debug("deallocate huge allocation {*}", .{buf.ptr});
                if (@as(usize, 1) << @intCast(log2_align) > std.mem.page_size)
                    huge_alignment.deallocate(@alignCast(buf))
                else
                    std.heap.page_allocator.rawFree(buf, log2_align, ret_addr);

                assert.withMessage(@src(), self.huge_allocations.removeRaw(buf.ptr), "huge allocation table corrupt with deallocating");
            } else {
                log.err("invalid free: {*} is not part of an owned heap", .{buf.ptr});
            }
        }

        pub fn usableSizeInSegment(self: *Self, ptr: *const anyopaque) usize {
            const segment = Segment.ofPtr(ptr);

            if (config.safety_checks) if (!self.ownsHeap(segment.heap)) {
                log.err("invalid pointer: {*} is not part of an owned heap", .{ptr});
                return 0;
            };

            const page_index = segment.pageIndex(ptr);
            const page_node = &segment.pages[page_index];
            const page = &page_node.data;
            const slot = page.containingSlotSegment(segment, ptr);
            const offset = @intFromPtr(ptr) - @intFromPtr(slot.ptr);
            return slot.len - offset;
        }

        /// Returns 0 if `ptr` is not  owned by `self`.
        pub fn usableSize(self: *Self, buf: []const u8) usize {
            if (buf.len <= constants.max_slot_size_large_page) {
                return self.usableSizeInSegment(buf.ptr);
            }
            return self.huge_allocations.get(buf.ptr) orelse 0;
        }

        pub fn usableSizePtr(self: *Self, ptr: *const anyopaque) usize {
            if (std.mem.isAligned(@intFromPtr(ptr), std.mem.page_size)) {
                if (self.huge_allocations.get(ptr)) |size| {
                    // WARNING: this depends on the implementation of std.heap.PageAllocator
                    // aligning allocated lengths to the page size
                    return std.mem.alignForward(usize, size, std.mem.page_size);
                }
            }
            return self.usableSizeInSegment(ptr);
        }

        /// Behaviour is undefined if `buf` is not an allocation returned by `self`.
        pub fn canResize(self: *Self, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
            if (buf.len <= constants.max_slot_size_large_page) {
                const owning_heap = self.getThreadHeap(buf.ptr) orelse {
                    if (config.safety_checks) {
                        log.err("invalid resize: {*} is not part of an owned heap", .{buf});
                        return false;
                    } else unreachable;
                };

                return owning_heap.canResizeInPlace(buf, log2_align, new_len, ret_addr);
            }
            if (self.huge_allocations.contains(buf.ptr)) {
                if (new_len <= constants.max_slot_size_large_page) return false;

                const slice: []align(std.mem.page_size) u8 = @alignCast(buf);
                const can_resize = if (@as(usize, 1) << @intCast(log2_align) > std.mem.page_size)
                    huge_alignment.resizeAllocation(slice, new_len)
                else
                    std.heap.page_allocator.rawResize(slice, log2_align, new_len, ret_addr);
                if (can_resize) {
                    const new_aligned_len = std.mem.alignForward(usize, new_len, std.mem.page_size);
                    self.huge_allocations.putAssumeCapacity(buf.ptr, new_aligned_len);
                    return true;
                }
            }
            return false;
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

const size_class = @import("size_class.zig");
const indexToSize = size_class.branching.toSize;

test "allocate with larger alignment" {
    var gpa = Allocator(.{}){};
    defer gpa.deinit();

    for (0..size_class.count) |class| {
        const size = (3 * indexToSize(class)) / 2;
        const slot_log2_align = @ctz(indexToSize(class));
        const log2_align = slot_log2_align + 1;
        const ptr = gpa.allocate(size, @intCast(log2_align), 0) orelse {
            log.err("failed to allocate size {d} with log2_align {d} (class {d})", .{ size, log2_align, class });
            return error.BadSizeClass;
        };
        const actual_log2_align: std.math.Log2Int(usize) = @intCast(@ctz(@intFromPtr(ptr)));
        try std.testing.expect(@ctz(indexToSize(class)) <= actual_log2_align);
    }
}

test "huge allocation alignment - allocateHuge" {
    var gpa = Allocator(.{}){};
    defer gpa.deinit();

    const log2_align_start = std.math.log2_int(usize, std.mem.page_size);
    const log2_align_end = std.math.log2_int(usize, constants.segment_alignment) + 1;
    for (log2_align_start..log2_align_end) |log2_align| {
        const ptr = gpa.allocateHuge(@as(usize, 1) << @intCast(log2_align), @intCast(log2_align), 0) orelse {
            log.err("failed to allocate with log2_align {d}", .{log2_align});
            return error.BadAlignment;
        };
        try std.testing.expect(std.mem.isAlignedLog2(@intFromPtr(ptr), @intCast(log2_align)));
    }
}

test "huge allocation alignment - allocate" {
    var gpa = Allocator(.{}){};
    defer gpa.deinit();

    const log2_align_start = std.math.log2_int(usize, std.mem.page_size);
    const log2_align_end = std.math.log2_int(usize, constants.segment_alignment) + 1;
    for (log2_align_start..log2_align_end) |log2_align| {
        const ptr = gpa.allocate(@as(usize, 1) << @intCast(log2_align), @intCast(log2_align), 0) orelse {
            log.err("failed to allocate with log2_align {d}", .{log2_align});
            return error.BadAlignment;
        };
        try std.testing.expect(std.mem.isAlignedLog2(@intFromPtr(ptr), @intCast(log2_align)));
    }
}

test "non-huge size with huge alignment" {
    var gpa = Allocator(.{}){};
    defer gpa.deinit();

    const start_log_align = @ctz(@as(usize, constants.max_slot_size_large_page)) + 1;
    for (start_log_align..start_log_align + 4) |log2_align| {
        const ptr = gpa.allocate(indexToSize(5), @intCast(log2_align), 0) orelse {
            log.err("failed to allocate with log2_align {d}", .{log2_align});
            return error.BadAlignment;
        };
        try std.testing.expect(std.mem.isAlignedLog2(@intFromPtr(ptr), @intCast(log2_align)));
    }
}

const std = @import("std");

const builtin = @import("builtin");

const assert = @import("assert.zig");
const constants = @import("constants.zig");
const log = @import("log.zig");
const huge_alignment = @import("huge_alignment.zig");

const Heap = @import("Heap.zig");
const Segment = @import("Segment.zig");
const HugeAllocTable = @import("HugeAllocTable.zig").HugeAllocTable;
