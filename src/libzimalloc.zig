var allocator_instance = zimalloc.Allocator(.{}){};
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
        // assert that the pointer was allocated
        const old_address = @ptrToInt(ptr);
        const alloc = metadata.get(old_address) orelse {
            invalid("invalid realloc: {*} - no valid heap", .{ptr});
            return null;
        };

        const slice = @ptrCast([*]u8, ptr)[0..alloc.size];

        const reallocated = allocator.realloc(slice, len) catch {
            log.debug("out of memory", .{});
            return null;
        };
        const new_address = @ptrToInt(reallocated.ptr);

        const new_alloc = AllocData{ .size = len };

        if (new_address == old_address) {
            metadata.put(new_address, new_alloc) catch unreachable;
        } else {
            assert(metadata.remove(old_address));
            metadata.putNoClobber(new_address, new_alloc) catch unreachable;
        }
        log.debug("reallocated pointer: {*}", .{reallocated});
        return reallocated.ptr;
    }
    log.debug("out of memory", .{});
    return null;
}

export fn free(ptr_opt: ?*anyopaque) void {
    log.debug("free {?*}", .{ptr_opt});
    if (ptr_opt) |ptr| {
        const alloc = metadata.get(@ptrToInt(ptr)) orelse {
            invalid("invalid free: {*} - no valid heap", .{ptr});
            return;
        };

        const slice = @ptrCast([*]u8, ptr)[0..alloc.size];
        allocator.free(slice);
        assert(metadata.remove(@ptrToInt(ptr)));
    }
}

export fn calloc(size: usize, count: usize) ?*anyopaque {
    log.debug("calloc {d} {d}", .{ size, count });
    const bytes = size * count;
    return allocateBytes(bytes, true);
}

fn allocateBytes(byte_count: usize, comptime zero: bool) ?*anyopaque {
    if (byte_count == 0) return null;
    metadata.ensureUnusedCapacity(1) catch {
        log.debug("could not allocate metadata", .{});
        return null;
    };

    if (allocator.rawAlloc(byte_count, 0, @returnAddress())) |ptr| {
        metadata.putAssumeCapacityNoClobber(@ptrToInt(ptr), .{ .size = byte_count });

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
