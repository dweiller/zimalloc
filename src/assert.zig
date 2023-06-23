pub fn withMessage(ok: bool, message: []const u8) void {
    if (!ok) {
        log.err("assertion failure: {s}", .{message});
        std.os.exit(1);
    }
}

const std = @import("std");
const log = @import("log.zig");
