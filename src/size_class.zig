const ShiftInt = std.math.Log2Int(usize);

pub const count = branching.ofSize(constants.max_slot_size_large_page) + 1;

const log2_divisions = 2;
const step_divisions = 1 << log2_divisions;

inline fn usizeCount(bytes: usize) usize {
    return (bytes + @sizeOf(usize) - 1) / @sizeOf(usize);
}

pub const branchless = struct {
    pub fn toSize(index: usize) u32 {
        const a = index -| step_divisions;
        const b = step_divisions -| index;
        const c = step_divisions - b;
        const base = (c + 1) * @sizeOf(usize);
        const size_shift = @intCast(ShiftInt, a / step_divisions);
        const i = a % step_divisions;
        return @intCast(u32, base + i * @sizeOf(usize) * 1 << size_shift);
    }

    /// asserts `len > 0`
    pub fn ofSizeNoSaturatingSub(len: usize) usize {
        // this version doesn't need saturating subtraction
        assert(len > 0);
        const usize_count = usizeCount(len);
        const b = leading_bit_index(usize_count);
        const extra_bits = (usize_count - 1) >> (@max(b, log2_divisions) - log2_divisions);

        const r = (@as(usize, b) << log2_divisions) + extra_bits;
        const offset = @as(usize, @min(b, log2_divisions)) * step_divisions;
        return r - offset;
    }

    /// asserts `len > 0`
    pub fn ofSize(len: usize) usize {
        assert(len > 0);
        const usize_count = usizeCount(len);
        const b = leading_bit_index(usize_count);
        const extra_bits = (usize_count - 1) >> (@max(b, log2_divisions) - log2_divisions);
        return ((@as(usize, b) -| log2_divisions) << log2_divisions) + extra_bits;
    }

    test toSize {
        for (0..step_divisions) |i| {
            try std.testing.expectEqual((i + 1) * @sizeOf(usize), toSize(i));
        }

        const last_special_size = toSize(step_divisions - 1);
        try std.testing.expectEqual(
            last_special_size + last_special_size / step_divisions,
            toSize(step_divisions),
        );

        for (step_divisions..count) |i| {
            const extra = (i - step_divisions) % step_divisions + 1;
            const rounded_index = step_divisions * ((i - step_divisions) / step_divisions);
            const base = step_divisions + rounded_index;
            const base_size = toSize(base - 1);
            try std.testing.expectEqual(base_size + extra * base_size / step_divisions, toSize(i));
        }
    }

    test ofSize {
        const last_special_size = toSize(step_divisions - 1);

        try std.testing.expectEqual(ofSize(last_special_size) + 1, ofSize(last_special_size + 1));
        try std.testing.expectEqual(@as(usize, step_divisions - 1), ofSize(last_special_size));
        try std.testing.expectEqual(@as(usize, step_divisions), ofSize(last_special_size + 1));
        try std.testing.expectEqual(
            @as(usize, step_divisions),
            ofSize(last_special_size + last_special_size / step_divisions - 1),
        );
    }

    test "indexToSize is monotonic" {
        for (0..count - 1) |i| {
            try std.testing.expect(toSize(i) < toSize(i + 1));
        }
    }

    test "sizeClass is weakly monotonic" {
        for (1..constants.max_slot_size_large_page - 1) |size| {
            try std.testing.expect(ofSize(size) <= ofSize(size + 1));
        }
    }

    test "sizeClass left inverse to indexToSize" {
        for (0..count) |i| {
            try std.testing.expectEqual(i, ofSize(toSize(i)));
        }

        for (1..@sizeOf(usize) + 1) |size| {
            try std.testing.expectEqual(toSize(0), toSize(ofSize(size)));
        }
        for (1..count) |i| {
            for (toSize(i - 1) + 1..toSize(i) + 1) |size| {
                try std.testing.expectEqual(toSize(i), toSize(ofSize(size)));
            }
        }
    }

    test "ofSizeNoSaturatingSub equals ofSize" {
        for (1..constants.max_slot_size_large_page + 1) |size| {
            try std.testing.expectEqual(branchless.ofSize(size), branchless.ofSizeNoSaturatingSub(size));
        }
    }
};

pub const branching = struct {
    const step_1_usize_count = 2 << log2_divisions;
    const step_divs = 1 << log2_divisions;
    const step_size_base = @sizeOf(usize) * step_1_usize_count / step_divs;
    const size_class_count = ofSize(constants.max_slot_size_large_page);
    const step_offset: usize = offset: {
        const b = @as(usize, leading_bit_index(step_1_usize_count));
        const extra_bits = (step_1_usize_count + 1) >> (b - log2_divisions);
        break :offset (b << log2_divisions) + extra_bits - first_general_index;
    };

    const first_general_index = step_1_usize_count;
    const last_special_size = step_1_usize_count * @sizeOf(usize);

    pub fn toSize(index: usize) u32 {
        if (index < first_general_index) {
            return @intCast(u32, @sizeOf(usize) * (index + 1));
        } else {
            const s = index - first_general_index + 1;
            const size_shift = @intCast(ShiftInt, s / step_divs);
            const i = s % step_divs;

            return @intCast(u32, last_special_size + i * step_size_base * 1 << size_shift);
        }
    }

    pub fn ofSize(len: usize) usize {
        assert(len > 0);
        const usize_count = usizeCount(len);
        if (usize_count < 2 << log2_divisions) {
            return usize_count - 1;
        } else {
            const b = leading_bit_index(usize_count - 1);
            const extra_bits = (usize_count - 1) >> (b - log2_divisions);
            return ((@as(usize, b) << log2_divisions) + extra_bits) - step_offset;
        }
    }

    test toSize {
        try std.testing.expectEqual(toSize(first_general_index - 1), last_special_size);
        try std.testing.expectEqual(
            toSize(first_general_index),
            last_special_size + last_special_size / step_divs,
        );

        for (0..step_1_usize_count) |i| {
            try std.testing.expectEqual((i + 1) * @sizeOf(usize), toSize(i));
        }
        for (step_1_usize_count..first_general_index) |i| {
            try std.testing.expectEqual(
                ((step_1_usize_count) + (i - step_1_usize_count + 1) * 2) * @sizeOf(usize),
                toSize(i),
            );
        }
        for (first_general_index..size_class_count) |i| {
            const extra = (i - first_general_index) % step_divs + 1;
            const rounded_index = step_divs * ((i - first_general_index) / step_divs);
            const base = first_general_index + rounded_index;
            const base_size = toSize(base - 1);
            try std.testing.expectEqual(base_size + extra * base_size / step_divs, toSize(i));
        }
    }

    test ofSize {
        try std.testing.expectEqual(ofSize(last_special_size) + 1, ofSize(last_special_size + 1));
        try std.testing.expectEqual(@as(usize, first_general_index - 1), ofSize(last_special_size));
        try std.testing.expectEqual(@as(usize, first_general_index), ofSize(last_special_size + 1));
        try std.testing.expectEqual(
            @as(usize, first_general_index),
            ofSize(last_special_size + last_special_size / step_divs - 1),
        );
    }

    test "sizeClassOld inverse of indexToSizeOld" {
        for (0..size_class_count) |i| {
            try std.testing.expectEqual(i, ofSize(toSize(i)));
        }

        for (1..@sizeOf(usize) + 1) |size| {
            try std.testing.expectEqual(toSize(0), toSize(ofSize(size)));
        }
        for (1..size_class_count) |i| {
            for (toSize(i - 1) + 1..toSize(i) + 1) |size| {
                try std.testing.expectEqual(toSize(i), toSize(ofSize(size)));
            }
        }
    }
};

inline fn leading_bit_index(a: usize) ShiftInt {
    return @intCast(ShiftInt, @bitSizeOf(usize) - 1 - @clz(a));
}

const std = @import("std");
const assert = std.debug.assert;

const constants = @import("constants.zig");

test {
    _ = branching;
    _ = branchless;
}

test "branchless equals branching" {
    for (1..constants.max_slot_size_large_page + 1) |size| {
        try std.testing.expectEqual(branchless.ofSize(size), branching.ofSize(size));
    }

    for (0..count) |i| {
        try std.testing.expectEqual(branchless.toSize(i), branching.toSize(i));
    }
}
