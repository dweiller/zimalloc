pub const Config = struct {
    thread_data_prealloc: usize = 128,
    thread_safe: bool = !builtin.single_threaded,
    safety_checks: bool = builtin.mode == .Debug,
    store_huge_alloc_size: bool = false,
};

pub fn Allocator(comptime config: Config) type {
    return struct {
        backing_allocator: std.mem.Allocator = std.heap.page_allocator,
        thread_heaps: ThreadHeapMap = .{},
        huge_allocations: HugeAllocTable(config.store_huge_alloc_size) = .{},
        // TODO: atomic access

        const Self = @This();

        pub fn init(backing_allocator: std.mem.Allocator) error{OutOfMemory}!Self {
            return .{
                .backing_allocator = backing_allocator,
                .thread_heaps = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.thread_heaps.deinit();
            self.huge_allocations.deinit(std.heap.page_allocator);
            self.* = undefined;
        }

        fn initHeapForThread(
            self: *Self,
        ) ?*Heap {
            const thread_id = std.Thread.getCurrentId();
            log.debug("initialising heap for thread {d}", .{thread_id});

            if (self.thread_heaps.initThreadHeap(thread_id)) |entry| {
                log.debug("heap added to thread map: {*}", .{&entry.heap});
                return &entry.heap;
            }

            return null;
        }

        pub fn getThreadHeap(
            self: *Self,
            ptr: *const anyopaque,
        ) ?*Heap {
            const segment = Segment.ofPtr(ptr);
            const heap = segment.heap;

            if (config.safety_checks) {
                if (!self.thread_heaps.ownsHeap(heap)) return null;
            }

            return heap;
        }

        /// behaviour is undefined if `thread_id` is not used by the allocator
        pub fn deinitThreadHeap(self: *Self, thread_id: std.Thread.Id) void {
            self.thread_heaps.deinitThread(thread_id);
        }

        pub fn deinitCurrentThreadHeap(self: *Self) void {
            self.deinitThreadHeap(std.Thread.getCurrentId());
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }

        pub fn allocate(
            self: *Self,
            len: usize,
            alignment: Alignment,
            ret_addr: usize,
        ) ?[*]align(constants.min_slot_alignment) u8 {
            log.debugVerbose("allocate: len={d} alignment={d}", .{ len, @intFromEnum(alignment) });

            if (Heap.requiredSlotSize(len, alignment) > constants.max_slot_size_large_page) {
                return self.allocateHuge(len, alignment, ret_addr);
            }

            const thread_id = std.Thread.getCurrentId();

            log.debugVerbose("obtaining shared thread heaps lock", .{});

            if (self.thread_heaps.get(thread_id)) |heap| {
                return self.allocInHeap(heap, len, alignment, ret_addr);
            } else {
                const heap = self.initHeapForThread() orelse return null;
                return self.allocInHeap(heap, len, alignment, ret_addr);
            }
        }

        pub fn allocateHuge(
            self: *Self,
            len: usize,
            alignment: Alignment,
            ret_addr: usize,
        ) ?[*]align(std.heap.page_size_min) u8 {
            log.debug("allocateHuge: len={d}, alignment={d}", .{ len, @intFromEnum(alignment) });

            self.huge_allocations.lock();
            defer self.huge_allocations.unlock();

            self.huge_allocations.ensureUnusedCapacityRaw(std.heap.page_allocator, 1) catch {
                log.debug("could not expand huge alloc table", .{});
                return null;
            };

            const alignment_bytes = alignment.toByteUnits();
            const ptr = if (alignment_bytes > std.heap.page_size_min)
                (huge_alignment.allocate(len, alignment) orelse return null).ptr
            else
                std.heap.page_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;

            self.huge_allocations.putAssumeCapacityNoClobberRaw(ptr, len);
            return @alignCast(ptr);
        }

        fn allocInHeap(
            self: *Self,
            heap: *Heap,
            len: usize,
            alignment: Alignment,
            ret_addr: usize,
        ) ?[*]align(constants.min_slot_alignment) u8 {
            _ = self;
            const entry: *const ThreadHeapMap.Entry = @fieldParentPtr("heap", heap);
            assert.withMessage(
                @src(),
                entry.thread_id == std.Thread.getCurrentId(),
                "tried to allocated from wrong thread",
            );

            return heap.allocate(len, alignment, ret_addr);
        }

        pub fn deallocate(
            self: *Self,
            buf: []u8,
            alignment: Alignment,
            ret_addr: usize,
        ) void {
            log.debugVerbose("deallocate: buf=({*}, {d}) alignment={d}", .{
                buf.ptr,
                buf.len,
                @intFromEnum(alignment),
            });
            // TODO: check this is valid on windows
            // this check also covers buf.len > constants.max_slot_size_large_page
            if (std.mem.isAligned(@intFromPtr(buf.ptr), std.heap.page_size_min)) {
                self.huge_allocations.lock();
                defer self.huge_allocations.unlock();
                if (self.huge_allocations.containsRaw(buf.ptr)) {
                    self.freeHuge(buf, alignment, ret_addr, true);
                    return;
                }
            }
            assert.withMessage(
                @src(),
                buf.len <= constants.max_slot_size_large_page,
                "tried to free unowned pointer",
            );

            self.freeNonHuge(buf.ptr, alignment, ret_addr);
        }

        pub fn freeNonHuge(self: *Self, ptr: [*]u8, alignment: Alignment, ret_addr: usize) void {
            log.debug("freeing non-huge allocation {*}", .{ptr});

            _ = alignment;
            _ = ret_addr;

            const segment = Segment.ofPtr(ptr);
            const heap = segment.heap;
            log.debugVerbose("free non-huge: heap {*}, segment={*}, ptr={*}", .{ heap, segment, ptr });

            if (config.safety_checks) if (!self.thread_heaps.ownsHeap(heap)) {
                log.err("invalid free: {*} is not part of an owned heap", .{ptr});
                return;
            };

            const page_index = segment.pageIndex(ptr);
            const page = &segment.pages[page_index];
            const slot = page.containingSlotSegment(segment, ptr);

            const thread_id = @as(*ThreadHeapMap.Entry, @fieldParentPtr("heap", heap)).thread_id;

            if (std.Thread.getCurrentId() == thread_id) {
                log.debugVerbose("moving slot {*} to local freelist", .{slot.ptr});
                page.freeLocalAligned(slot);
            } else {
                log.debugVerbose("moving slot {*} to other freelist on thread {d}", .{
                    slot.ptr, thread_id,
                });
                page.freeOtherAligned(slot);
            }
        }

        pub fn freeHuge(
            self: *Self,
            buf: []u8,
            alignment: Alignment,
            ret_addr: usize,
            comptime lock_held: bool,
        ) void {
            if (!lock_held) self.huge_allocations.lock();
            defer if (!lock_held) self.huge_allocations.unlock();

            if (self.huge_allocations.containsRaw(buf.ptr)) {
                log.debug("deallocate huge allocation {*}", .{buf.ptr});
                if (alignment.toByteUnits() > std.heap.page_size_min)
                    huge_alignment.deallocate(@alignCast(buf))
                else
                    std.heap.page_allocator.rawFree(buf, alignment, ret_addr);

                assert.withMessage(
                    @src(),
                    self.huge_allocations.removeRaw(buf.ptr),
                    "huge allocation table corrupt with deallocating",
                );
            } else {
                log.err("invalid huge free: {*} is not part of an owned heap", .{buf.ptr});
            }
        }

        pub fn usableSizeInSegment(self: *Self, ptr: *const anyopaque) usize {
            const segment = Segment.ofPtr(ptr);

            if (config.safety_checks) if (!self.thread_heaps.ownsHeap(segment.heap)) {
                log.err("invalid pointer: {*} is not part of an owned heap", .{ptr});
                return 0;
            };

            const page_index = segment.pageIndex(ptr);
            const page = &segment.pages[page_index];
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
            if (std.mem.isAligned(@intFromPtr(ptr), std.heap.page_size_min)) {
                if (self.huge_allocations.get(ptr)) |size| {
                    // WARNING: this depends on the implementation of std.heap.PageAllocator
                    // aligning allocated lengths to the page size
                    return std.mem.alignForward(usize, size, std.heap.page_size_min);
                }
            }
            return self.usableSizeInSegment(ptr);
        }

        /// Behaviour is undefined if `buf` is not an allocation returned by `self`.
        pub fn canResize(
            self: *Self,
            buf: []u8,
            alignment: Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            if (buf.len <= constants.max_slot_size_large_page) {
                const owning_heap = self.getThreadHeap(buf.ptr) orelse {
                    if (config.safety_checks) {
                        log.err("invalid resize: {*} is not part of an owned heap", .{buf});
                        return false;
                    } else unreachable;
                };

                return owning_heap.canResizeInPlace(buf, alignment, new_len, ret_addr);
            }
            if (self.huge_allocations.contains(buf.ptr)) {
                if (new_len <= constants.max_slot_size_large_page) return false;

                const slice: []align(std.heap.page_size_min) u8 = @alignCast(buf);
                const can_resize = if (alignment.toByteUnits() > std.heap.page_size_min)
                    huge_alignment.resizeAllocation(slice, new_len)
                else
                    std.heap.page_allocator.rawResize(slice, alignment, new_len, ret_addr);
                if (can_resize) {
                    const new_aligned_len = std.mem.alignForward(usize, new_len, std.heap.page_size_min);
                    self.huge_allocations.putAssumeCapacity(buf.ptr, new_aligned_len);
                    return true;
                }
            }
            return false;
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            assert.withMessage(
                @src(),
                std.mem.isAligned(@intFromPtr(ctx), @alignOf(@This())),
                "ctx is not aligned",
            );
            const self: *@This() = @ptrCast(@alignCast(ctx));

            return self.allocate(len, alignment, ret_addr);
        }

        fn resize(
            ctx: *anyopaque,
            buf: []u8,
            alignment: Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            assert.withMessage(
                @src(),
                std.mem.isAligned(@intFromPtr(ctx), @alignOf(@This())),
                "ctx is not aligned",
            );
            const self: *@This() = @ptrCast(@alignCast(ctx));

            return self.canResize(buf, alignment, new_len, ret_addr);
        }

        fn remap(
            ctx: *anyopaque,
            buf: []u8,
            alignment: Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            return if (resize(ctx, buf, alignment, new_len, ret_addr)) buf.ptr else null;
        }

        fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
            assert.withMessage(
                @src(),
                std.mem.isAligned(@intFromPtr(ctx), @alignOf(@This())),
                "ctx is not aligned",
            );
            const self: *@This() = @ptrCast(@alignCast(ctx));

            self.deallocate(buf, alignment, ret_addr);
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
        const ptr = gpa.allocate(size, @enumFromInt(log2_align), 0) orelse {
            log.err("failed to allocate size {d} with log2_align {d} (class {d})", .{
                size, log2_align, class,
            });
            return error.BadSizeClass;
        };
        const actual_log2_align: std.math.Log2Int(usize) = @intCast(@ctz(@intFromPtr(ptr)));
        try std.testing.expect(@ctz(indexToSize(class)) <= actual_log2_align);
    }
}

test "huge allocation alignment - allocateHuge" {
    var gpa = Allocator(.{}){};
    defer gpa.deinit();

    const log2_align_start = std.math.log2_int(usize, std.heap.page_size_min);
    const log2_align_end = std.math.log2_int(usize, constants.segment_alignment) + 1;
    for (log2_align_start..log2_align_end) |log2_align| {
        const alignment: Alignment = @enumFromInt(log2_align);
        const ptr = gpa.allocateHuge(alignment.toByteUnits(), alignment, 0) orelse {
            log.err("failed to allocate with log2_align {d}", .{log2_align});
            return error.BadAlignment;
        };
        try std.testing.expect(alignment.check(@intFromPtr(ptr)));
    }
}

test "huge allocation alignment - allocate" {
    var gpa = Allocator(.{}){};
    defer gpa.deinit();

    const log2_align_start = std.math.log2_int(usize, std.heap.page_size_min);
    const log2_align_end = std.math.log2_int(usize, constants.segment_alignment) + 1;
    for (log2_align_start..log2_align_end) |log2_align| {
        const alignment: Alignment = @enumFromInt(log2_align);
        const ptr = gpa.allocate(alignment.toByteUnits(), alignment, 0) orelse {
            log.err("failed to allocate with log2_align {d}", .{log2_align});
            return error.BadAlignment;
        };
        try std.testing.expect(alignment.check(@intFromPtr(ptr)));
    }
}

test "non-huge size with huge alignment" {
    var gpa = Allocator(.{}){};
    defer gpa.deinit();

    const start_log_align = @ctz(@as(usize, constants.max_slot_size_large_page)) + 1;
    for (start_log_align..start_log_align + 4) |log2_align| {
        const alignment: Alignment = @enumFromInt(log2_align);
        const ptr = gpa.allocate(indexToSize(5), alignment, 0) orelse {
            log.err("failed to allocate with log2_align {d}", .{log2_align});
            return error.BadAlignment;
        };
        try std.testing.expect(alignment.check(@intFromPtr(ptr)));
    }
}

const std = @import("std");
const Alignment = std.mem.Alignment;

const builtin = @import("builtin");

const assert = @import("assert.zig");
const constants = @import("constants.zig");
const log = @import("log.zig");
const huge_alignment = @import("huge_alignment.zig");

const Heap = @import("Heap.zig");
const Segment = @import("Segment.zig");
const HugeAllocTable = @import("HugeAllocTable.zig").HugeAllocTable;
const ThreadHeapMap = @import("ThreadHeapMap.zig");
