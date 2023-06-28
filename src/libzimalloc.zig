var allocator_instance = zimalloc.Allocator(.{
    .track_allocations = true,
}){};
const allocator = allocator_instance.allocator();

const AllocData = struct {
    size: usize,
};

var metadata = std.AutoHashMap(usize, AllocData){
    .unmanaged = .{},
    .allocator = std.heap.page_allocator,
    .ctx = undefined, // safe becuase AutoHashMap context type is zero sized
};

export fn malloc(len: usize) ?*anyopaque {
    log.debug("malloc {d}", .{len});
    return allocateBytes(len, 1, @returnAddress(), false, false);
}

export fn realloc(ptr_opt: ?*anyopaque, len: usize) ?*anyopaque {
    log.debug("realloc {?*} {d}", .{ ptr_opt, len });
    if (ptr_opt) |ptr| {
        const heap_data = allocator_instance.getThreadData(ptr, false) catch {
            invalid("invalid realloc: {*} - no valid heap", .{ptr});
            return null;
        };
        // defer heap_data.metadata.mutex.unlock();

        const alloc = heap_data.metadata.map.get(@intFromPtr(ptr)) orelse {
            invalid("invalid resize: {*}", .{ptr});
            return null;
        };

        const bytes_ptr: [*]u8 = @ptrCast(ptr);
        const old_slice = bytes_ptr[0..alloc.size];

        if (allocator.rawResize(old_slice, 0, len, @returnAddress())) {
            log.debug("keeping old pointer", .{});
            return ptr;
        }

        const new_mem = allocateBytes(len, 1, @returnAddress(), false, false) orelse
            return null;

        const copy_len = @min(len, old_slice.len);
        @memcpy(new_mem[0..copy_len], old_slice);

        allocator_instance.deallocate(old_slice, 0, @returnAddress(), false);

        log.debug("reallocated pointer: {*}", .{new_mem});
        return new_mem;
    }
    return allocateBytes(len, 1, @returnAddress(), false, false);
}

export fn free(ptr_opt: ?*anyopaque) void {
    log.debug("free {?*}", .{ptr_opt});
    if (ptr_opt) |ptr| {
        const heap_data = allocator_instance.getThreadData(ptr, true) catch {
            invalid("invalid free: {*} - no valid heap", .{ptr});
            return;
        };
        defer heap_data.metadata.mutex.unlock();

        const alloc = heap_data.metadata.map.get(@intFromPtr(ptr)) orelse {
            invalid("invalid free: {*}", .{ptr});
            return;
        };

        const bytes_ptr: [*]u8 = @ptrCast(ptr);
        const slice = bytes_ptr[0..alloc.size];
        if (slice.len == 0) return;

        @memset(slice, undefined);

        if (alloc.is_huge) {
            allocator_instance.freeHugeFromHeap(&heap_data.heap, slice, 0, @returnAddress());
            return;
        }

        allocator_instance.freeNonHugeFromHeap(&heap_data.heap, slice, 0, @returnAddress());
    }
}

export fn calloc(size: usize, count: usize) ?*anyopaque {
    log.debug("calloc {d} {d}", .{ size, count });
    const bytes = size * count;
    return allocateBytes(bytes, 1, @returnAddress(), true, false);
}

export fn aligned_alloc(alignment: usize, size: usize) ?*anyopaque {
    log.debug("aligned_alloc alignment={d}, size={d}", .{ alignment, size });
    return allocateBytes(size, alignment, @returnAddress(), false, true);
}

export fn posix_memalign(ptr: *?*anyopaque, alignment: usize, size: usize) c_int {
    log.debug("posix_memalign ptr={*}, alignment={d}, size={d}", .{ ptr, alignment, size });

    if (size == 0) {
        ptr.* = null;
        return 0;
    }

    if (@popCount(alignment) != 1 or alignment < @sizeOf(*anyopaque)) {
        return @intFromEnum(std.os.E.INVAL);
    }

    if (allocateBytes(size, alignment, @returnAddress(), false, true)) |p| {
        ptr.* = p;
        return 0;
    }

    return @intFromEnum(std.os.E.NOMEM);
}

export fn memalign(alignment: usize, size: usize) ?*anyopaque {
    log.debug("memalign alignment={d}, size={d}", .{ alignment, size });
    return allocateBytes(size, alignment, @returnAddress(), false, true);
}

export fn valloc(size: usize) ?*anyopaque {
    log.debug("valloc {d}", .{size});
    return allocateBytes(size, std.mem.page_size, @returnAddress(), false, false);
}

export fn pvalloc(size: usize) ?*anyopaque {
    log.debug("pvalloc {d}", .{size});
    const aligned_size = std.mem.alignForward(usize, size, std.mem.page_size);
    return allocateBytes(aligned_size, std.mem.page_size, @returnAddress(), false, false);
}

fn allocateBytes(
    byte_count: usize,
    alignment: usize,
    ret_addr: usize,
    comptime zero: bool,
    comptime check_alignment: bool,
) ?[*]u8 {
    if (byte_count == 0) return null;

    if (check_alignment) {
        if (!std.mem.isValidAlign(alignment)) {
            invalid("invalid alignment: {d}", .{alignment});
            return null;
        }
    }

    const log2_align = std.math.log2_int(usize, alignment);
    if (allocator_instance.allocate(byte_count, log2_align, ret_addr, false)) |ptr| {
        @memset(ptr[0..byte_count], if (zero) 0 else undefined);
        log.debug("allocated {*}", .{ptr});
        return ptr;
    }
    log.debug("out of memory", .{});
    return null;
}

fn invalid(comptime fmt: []const u8, args: anytype) void {
    if (build_options.panic_on_invalid) {
        std.debug.panic(fmt, args);
    } else {
        log.err(fmt, args);
    }
}

const std = @import("std");

const zimalloc = @import("zimalloc.zig");

const assert = @import("assert.zig");
const log = @import("log.zig");
const constants = @import("constants.zig");

const build_options = @import("build_options");

const Segment = @import("Segment.zig");
