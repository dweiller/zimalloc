/// The `size` is  rounded up to a multiple of `std.heap.page_size_min`.
/// Can be freed with std.os.unmap
pub fn allocateOptions(
    size: usize,
    alignment: std.mem.Alignment,
    prot: u32,
    flags: std.posix.MAP,
) ?[]align(std.heap.page_size_min) u8 {
    assert.withMessage(
        @src(),
        alignment.toByteUnits() > std.heap.page_size_min,
        "alignment is not greater than the page size",
    );

    const mmap_length = size + alignment.toByteUnits() - 1;
    const unaligned = std.posix.mmap(null, mmap_length, prot, flags, -1, 0) catch return null;
    const unaligned_address = @intFromPtr(unaligned.ptr);
    const aligned_address = alignment.forward(unaligned_address);

    const aligned_size = std.mem.alignForward(usize, size, std.heap.page_size_min);

    if (aligned_address == unaligned_address) {
        std.posix.munmap(@alignCast(unaligned[aligned_size..]));
        return unaligned[0..aligned_size];
    } else {
        const offset = aligned_address - unaligned_address;
        assert.withMessage(@src(), std.mem.isAligned(offset, std.heap.page_size_min), "offset is not aligned");

        std.posix.munmap(unaligned[0..offset]);
        std.posix.munmap(@alignCast(unaligned[offset + aligned_size ..]));
        return @alignCast(unaligned[offset..][0..aligned_size]);
    }
}

/// Makes a readable, writeable, anonymous private mapping with size rounded up to
/// a multiple of `std.heap.page_size_min`. Should be freed with `deallocate()`.
pub fn allocate(size: usize, alignment: std.mem.Alignment) ?[]align(std.heap.page_size_min) u8 {
    return allocateOptions(
        size,
        alignment,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
    );
}

/// Rounds `buf.len` up to a multiple of `std.heap.page_size_min`.
pub fn deallocate(buf: []align(std.heap.page_size_min) const u8) void {
    const aligned_len = std.mem.alignForward(usize, buf.len, std.heap.page_size_min);
    std.posix.munmap(buf.ptr[0..aligned_len]);
}

pub fn resizeAllocation(buf: []align(std.heap.page_size_min) u8, new_len: usize) bool {
    const old_aligned_len = std.mem.alignForward(usize, buf.len, std.heap.page_size_min);
    const new_aligned_len = std.mem.alignForward(usize, new_len, std.heap.page_size_min);

    if (new_aligned_len == old_aligned_len) {
        return true;
    } else if (new_aligned_len < old_aligned_len) {
        const trailing_ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(buf.ptr + new_aligned_len);
        std.posix.munmap(trailing_ptr[0 .. old_aligned_len - new_aligned_len]);
        return true;
    } else {
        return false;
    }
}

const std = @import("std");

const assert = @import("assert.zig");
