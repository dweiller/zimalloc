/// Makes a readable, writeable, anonymous private mapping with size rounded up to
/// a multiple of `std.mem.page_size`. Should be freed with `deallocate()`.
pub fn allocate(size: usize, alignment: usize) ?[]align(std.mem.page_size) u8 {
    return allocateOptions(
        size,
        alignment,
        windows.PAGE_READWRITE,
        windows.MEM_COMMIT | windows.MEM_RESERVE,
    );
}

/// Rounds `buf.len` up to a multiple of `std.mem.page_size`.
pub fn deallocate(buf: []align(std.mem.page_size) u8) void {
    windows.VirtualFree(@ptrCast(buf.ptr), 0, windows.MEM_RELEASE);
}

pub fn resizeAllocation(buf: []align(std.mem.page_size) u8, new_len: usize) bool {
    const old_aligned_len = std.mem.alignForward(usize, buf.len, std.mem.page_size);
    const new_aligned_len = std.mem.alignForward(usize, new_len, std.mem.page_size);

    if (new_aligned_len == old_aligned_len) {
        return true;
    } else if (new_aligned_len < old_aligned_len) {
        const trailing_ptr: [*]align(std.mem.page_size) u8 = @alignCast(buf.ptr + new_aligned_len);
        windows.VirtualFree(trailing_ptr, old_aligned_len - new_aligned_len, windows.MEM_DECOMMIT);
        return true;
    } else {
        return false;
    }
}

const kernel32 = struct {
    extern "kernel32" fn VirtualAlloc2(Process: ?HANDLE, BaseAddress: ?PVOID, Size: SIZE_T, AllocationType: ULONG, PageProtection: ULONG, ExtendedParameters: [*]MEM_EXTENDED_PARAMETER, ParameterCount: ULONG) callconv(WINAPI) ?PVOID;
};

pub const VirtualAlloc2Error = error{Unexpected};

fn VirtualAlloc2(
    process: ?HANDLE,
    base_address: ?PVOID,
    size: SIZE_T,
    allocation_type: ULONG,
    prot: ULONG,
    extended_parameters: []MEM_EXTENDED_PARAMETER,
) VirtualAlloc2Error!PVOID {
    return kernel32.VirtualAlloc2(
        process,
        base_address,
        size,
        allocation_type,
        prot,
        extended_parameters.ptr,
        @intCast(extended_parameters.len),
    ) orelse {
        switch (windows.kernel32.GetLastError()) {
            // TODO: handle errors that can happen
            else => |err| return windows.unexpectedError(err),
        }
    };
}

fn allocateOptions(
    size: usize,
    alignment: usize,
    prot: ULONG,
    alloc_type: ULONG,
) ?[]align(std.mem.page_size) u8 {
    assert.withMessage(@src(), alignment > std.mem.page_size, "alignment is not greater than the page size");
    assert.withMessage(@src(), std.mem.isValidAlign(alignment), "alignment is not a power of two");

    var mem_address_requirements = _MEM_ADDRESS_REQUIREMENTS{
        .lowest_address = null,
        .highest_address = null,
        .alignment = alignment,
    };

    var extended_parameters = [_]MEM_EXTENDED_PARAMETER{
        .{
            .dummy = .{ .Type = .address_requirements },
            .param = .{ .Pointer = &mem_address_requirements },
        },
    };

    const aligned_size = std.mem.alignForward(usize, size, std.mem.page_size);
    const ptr = VirtualAlloc2(null, null, aligned_size, alloc_type, prot, &extended_parameters) catch
        return null;
    return @alignCast(@as([*]u8, @ptrCast(ptr))[0..aligned_size]);
}

// TODO: figure out how to deallocate - problem is that VirtualFree with MEM_RELEASE requires
// the originally returned base pointer which does not play well with forcing alignment greater
// than VirtualAlloc guarantees

const std = @import("std");

const windows = std.os.windows;

const DWORD64 = windows.DWORD64;
const DWORD = windows.DWORD;
const SIZE_T = windows.SIZE_T;
const HANDLE = windows.HANDLE;
const PVOID = windows.PVOID;
const ULONG = windows.ULONG;
const WINAPI = windows.WINAPI;

const MEM_EXTENDED_PARAMETER_BITS = 8;
const MEM_EXTENDED_PARAMETER = extern struct {
    dummy: packed struct(u64) {
        Type: MEM_EXTENDED_PARAMETER_TYPE,
        RESERVED: std.meta.Int(.unsigned, 64 - MEM_EXTENDED_PARAMETER_BITS) = 0,
    },
    param: extern union {
        ULong64: DWORD64,
        Pointer: PVOID,
        Size: SIZE_T,
        Handle: HANDLE,
        ULong: DWORD,
    },
};

const MEM_EXTENDED_PARAMETER_TYPE = enum(std.meta.Int(.unsigned, MEM_EXTENDED_PARAMETER_BITS)) {
    invalid,
    address_requirements,
    numa_node,
    partition_handle,
    user_physical_handle,
    attribute_flags,
    image_machine,
    max,
};

const _MEM_ADDRESS_REQUIREMENTS = extern struct {
    lowest_address: ?PVOID,
    highest_address: ?PVOID,
    alignment: SIZE_T,
};

const assert = @import("../assert.zig");

comptime {
    _ = std.testing.refAllDecls(@This());
}
