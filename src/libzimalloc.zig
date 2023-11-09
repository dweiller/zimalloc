var allocator_instance = zimalloc.Allocator(.{}){};

export fn malloc(len: usize) ?*anyopaque {
    log.debug("malloc {d}", .{len});
    return allocateBytes(len, 1, @returnAddress(), false, false, true);
}

export fn realloc(ptr_opt: ?*anyopaque, len: usize) ?*anyopaque {
    log.debug("realloc {?*} {d}", .{ ptr_opt, len });
    if (ptr_opt) |ptr| {
        const old_size = allocator_instance.usableSizePtr(ptr);

        const bytes_ptr: [*]u8 = @ptrCast(ptr);
        const old_slice = bytes_ptr[0..old_size];

        if (allocator_instance.canResize(old_slice, 0, len, @returnAddress())) {
            log.debug("keeping old pointer", .{});
            return ptr;
        }

        const new_mem = allocateBytes(len, 1, @returnAddress(), false, false, true) orelse
            return null;

        const copy_len = @min(len, old_slice.len);
        @memcpy(new_mem[0..copy_len], old_slice[0..copy_len]);

        allocator_instance.deallocate(old_slice, 0, @returnAddress());

        log.debug("reallocated pointer: {*}", .{new_mem});
        return new_mem;
    }
    return allocateBytes(len, 1, @returnAddress(), false, false, true);
}

export fn free(ptr_opt: ?*anyopaque) void {
    log.debug("free {?*}", .{ptr_opt});
    if (ptr_opt) |ptr| {
        const bytes_ptr: [*]u8 = @ptrCast(ptr);

        if (allocator_instance.huge_allocations.get(ptr)) |size| {
            assert.withMessage(@src(), size != 0, "BUG: huge allocation size should be > 0");
            const slice = bytes_ptr[0..size];
            @memset(slice, undefined);
            allocator_instance.freeHuge(slice, 0, @returnAddress(), false);
        } else {
            const heap = allocator_instance.getThreadHeap(ptr) orelse {
                invalid("invalid free: {*} - no valid heap", .{ptr});
                return;
            };

            allocator_instance.freeNonHugeFromHeap(heap, bytes_ptr, 0, @returnAddress());
        }
    }
}

export fn calloc(size: usize, count: usize) ?*anyopaque {
    log.debug("calloc {d} {d}", .{ size, count });
    const bytes = size * count;
    return allocateBytes(bytes, 1, @returnAddress(), true, false, true);
}

export fn aligned_alloc(alignment: usize, size: usize) ?*anyopaque {
    log.debug("aligned_alloc alignment={d}, size={d}", .{ alignment, size });
    return allocateBytes(size, alignment, @returnAddress(), false, true, true);
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

    if (allocateBytes(size, alignment, @returnAddress(), false, false, false)) |p| {
        ptr.* = p;
        return 0;
    }

    return @intFromEnum(std.os.E.NOMEM);
}

export fn memalign(alignment: usize, size: usize) ?*anyopaque {
    log.debug("memalign alignment={d}, size={d}", .{ alignment, size });
    return allocateBytes(size, alignment, @returnAddress(), false, true, true);
}

export fn valloc(size: usize) ?*anyopaque {
    log.debug("valloc {d}", .{size});
    return allocateBytes(size, std.mem.page_size, @returnAddress(), false, false, true);
}

export fn pvalloc(size: usize) ?*anyopaque {
    log.debug("pvalloc {d}", .{size});
    const aligned_size = std.mem.alignForward(usize, size, std.mem.page_size);
    return allocateBytes(aligned_size, std.mem.page_size, @returnAddress(), false, false, true);
}

export fn malloc_usable_size(ptr_opt: ?*anyopaque) usize {
    log.debug("malloc_usable_size {?*}", .{ptr_opt});
    if (ptr_opt) |ptr| {
        return allocator_instance.usableSizePtr(ptr);
    }
    return 0;
}

fn allocateBytes(
    byte_count: usize,
    alignment: usize,
    ret_addr: usize,
    comptime zero: bool,
    comptime check_alignment: bool,
    comptime set_errno: bool,
) ?[*]u8 {
    if (byte_count == 0) return null;

    if (check_alignment) {
        if (!set_errno) @compileError("check_alignment requires set_errno to be true");
        if (!std.mem.isValidAlign(alignment)) {
            invalid("invalid alignment: {d}", .{alignment});
            setErrno(.INVAL);
            return null;
        }
    }

    const log2_align = std.math.log2_int(usize, alignment);
    if (allocator_instance.allocate(byte_count, log2_align, ret_addr)) |ptr| {
        @memset(ptr[0..byte_count], if (zero) 0 else undefined);
        log.debug("allocated {*}", .{ptr});
        return ptr;
    }
    log.debug("out of memory", .{});
    if (set_errno) setErrno(.NOMEM);
    return null;
}

fn invalid(comptime fmt: []const u8, args: anytype) void {
    if (build_options.panic_on_invalid) {
        std.debug.panic(fmt, args);
    } else {
        log.err(fmt, args);
    }
}

fn setErrno(code: std.c.E) void {
    std.c._errno().* = @intFromEnum(code);
}

const std = @import("std");

const zimalloc = @import("zimalloc.zig");

const assert = @import("assert.zig");
const log = @import("log.zig");
const constants = @import("constants.zig");

const build_options = @import("build_options");

const Segment = @import("Segment.zig");
