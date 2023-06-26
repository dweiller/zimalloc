pub const segment_alignment_log2 = 23;
pub const segment_alignment = 1 << segment_alignment_log2; // 8 MiB
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

// TODO: make this a compile option or work out how to detect it
pub const max_address_bits = 48;
pub const max_address = (1 << max_address_bits) - 1;

pub const total_segment_count_log2 = max_address_bits - segment_alignment_log2;
pub const total_segment_count = 1 << segment_alignment_log2;

const std = @import("std");
