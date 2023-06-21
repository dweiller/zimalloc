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
    return allocateBytes(len, false);
}

export fn realloc(ptr_opt: ?*anyopaque, len: usize) ?*anyopaque {
    log.debug("realloc {?*} {d}", .{ ptr_opt, len });
    if (ptr_opt) |ptr| {
        const alloc = allocator_instance.getMetadata(ptr) catch {
            invalid("invalid realloc: {*} - no valid heap", .{ptr});
            return null;
        } orelse {
            invalid("invalid realloc: {*}", .{ptr});
            return null;
        };

        const old_slice = @ptrCast([*]u8, ptr)[0..alloc.size];

        if (allocator.rawResize(old_slice, 0, len, @returnAddress())) {
            log.debug("keeping old pointer", .{});
            return ptr;
        }

        const new_mem = allocator.rawAlloc(len, 0, @returnAddress()) orelse {
            log.debug("out of memory", .{});
            return null;
        };

        const copy_len = @min(len, old_slice.len);
        @memcpy(new_mem[0..copy_len], old_slice);

        allocator.rawFree(old_slice, 0, @returnAddress());

        log.debug("reallocated pointer: {*}", .{new_mem});
        return new_mem;
    }
    return allocateBytes(len, false);
}

export fn free(ptr_opt: ?*anyopaque) void {
    log.debug("free {?*}", .{ptr_opt});
    if (ptr_opt) |ptr| {
        const alloc = allocator_instance.getMetadata(ptr) catch {
            invalid("invalid free: {*} - no valid heap", .{ptr});
            return;
        } orelse {
            invalid("invalid free: {*}", .{ptr});
            return;
        };

        const slice = @ptrCast([*]u8, ptr)[0..alloc.size];
        allocator.free(slice);
    }
}

export fn calloc(size: usize, count: usize) ?*anyopaque {
    log.debug("calloc {d} {d}", .{ size, count });
    const bytes = size * count;
    return allocateBytes(bytes, true);
}

fn allocateBytes(byte_count: usize, comptime zero: bool) ?*anyopaque {
    if (byte_count == 0) return null;

    if (allocator.rawAlloc(byte_count, 0, @returnAddress())) |ptr| {
        const min_alignment = constants.min_slot_size_usize_count * @sizeOf(usize);
        const casted_ptr = @alignCast(min_alignment, ptr);
        @memset(casted_ptr[0..byte_count], if (zero) 0 else undefined);
        log.debug("allocated {*}", .{casted_ptr});
        return casted_ptr;
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
const assert = std.debug.assert;

const zimalloc = @import("zimalloc.zig");
const constants = @import("constants.zig");

const log = @import("log.zig");

const build_options = @import("build_options");

const Segment = @import("Segment.zig");
