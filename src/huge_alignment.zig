pub fn allocateOptions(
    size: usize,
    alignment: usize,
    prot: u32,
    flags: u32,
) ?[]align(std.mem.page_size) u8 {
    assert.withMessage(@src(), alignment > std.mem.page_size, "alignment is not greater than the page size");
    const mmap_length = size + alignment - 1;
    const unaligned = std.os.mmap(null, mmap_length, prot, flags, -1, 0) catch return null;
    const unaligned_address = @intFromPtr(unaligned.ptr);
    const aligned_address = std.mem.alignForward(usize, unaligned_address, alignment);
    if (aligned_address == unaligned_address) {
        std.os.munmap(@alignCast(unaligned[size..]));
        return unaligned;
    } else {
        const offset = aligned_address - unaligned_address;
        std.os.munmap(unaligned[0..offset]);
        std.os.munmap(@alignCast(unaligned[offset + size ..]));
        return @alignCast(unaligned[offset..][0..size]);
    }
}

/// Makes a readable, writeable, anonymoust private mapping
pub fn allocate(size: usize, alignment: usize) ?[]align(std.mem.page_size) u8 {
    return allocateOptions(
        size,
        alignment,
        std.os.PROT.READ | std.os.PROT.WRITE,
        std.os.MAP.PRIVATE | std.os.MAP.ANONYMOUS,
    );
}

const std = @import("std");

const assert = @import("assert.zig");
