/// The `size` is  rounded up to a multiple of `std.mem.page_size`.
/// Can be freed with std.os.unmap
pub fn allocateOptions(
    size: usize,
    alignment: usize,
    prot: u32,
    flags: u32,
) ?[]align(std.mem.page_size) u8 {
    assert.withMessage(@src(), alignment > std.mem.page_size, "alignment is not greater than the page size");
    assert.withMessage(@src(), std.mem.isValidAlign(alignment), "alignment is not a power of two");

    const mmap_length = size + alignment - 1;
    const unaligned = std.os.mmap(null, mmap_length, prot, flags, -1, 0) catch return null;
    const unaligned_address = @intFromPtr(unaligned.ptr);
    const aligned_address = std.mem.alignForward(usize, unaligned_address, alignment);

    const aligned_size = std.mem.alignForward(usize, size, std.mem.page_size);

    if (aligned_address == unaligned_address) {
        std.os.munmap(@alignCast(unaligned[aligned_size..]));
        return unaligned[0..aligned_size];
    } else {
        const offset = aligned_address - unaligned_address;
        assert.withMessage(@src(), std.mem.isAligned(offset, std.mem.page_size), "offset is not aligned");

        std.os.munmap(unaligned[0..offset]);
        std.os.munmap(@alignCast(unaligned[offset + aligned_size ..]));
        return @alignCast(unaligned[offset..][0..aligned_size]);
    }
}

/// Makes a readable, writeable, anonymous private mapping with size rounded up to
/// a multiple of `std.mem.page_size`. Should be freed with `deallocate()`.
pub fn allocate(size: usize, alignment: usize) ?[]align(std.mem.page_size) u8 {
    return allocateOptions(
        size,
        alignment,
        std.os.PROT.READ | std.os.PROT.WRITE,
        std.os.MAP.PRIVATE | std.os.MAP.ANONYMOUS,
    );
}

/// Rounds `buf.len` up to a multiple of `std.mem.page_size`.
pub fn deallocate(buf: []align(std.mem.page_size) const u8) void {
    const aligned_len = std.mem.alignForward(usize, buf.len, std.mem.page_size);
    std.os.munmap(buf.ptr[0..aligned_len]);
}

const std = @import("std");

const assert = @import("assert.zig");
