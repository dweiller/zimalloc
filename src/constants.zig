pub const segment_alignment = 1 << 23; // 8 MiB
pub const segment_size = segment_alignment;

pub const small_page_size = 1 << 16; // 64 KiB
pub const small_page_count = segment_size / small_page_size;

pub const segment_metadata_bytes = @sizeOf(@import("Segment.zig"));
pub const segment_first_page_offset = std.mem.alignForward(usize, segment_metadata_bytes, std.mem.page_size);
pub const small_page_size_first = small_page_size - segment_first_page_offset;

pub const small_page_shift = std.math.log2(small_page_size);
pub const large_page_shift = std.math.log2(segment_alignment);

pub const min_slot_size_usize_count = 1;
pub const min_slot_size = min_slot_size_usize_count * @sizeOf(usize);

pub const min_slot_alignment_log2 = @ctz(@as(usize, min_slot_size));
pub const min_slot_alignment = 1 << min_slot_alignment_log2;

pub const min_slots_per_page = 8;
pub const max_slot_size_small_page = small_page_size / min_slots_per_page;
pub const max_slot_size_large_page = segment_size / min_slots_per_page;

const std = @import("std");
