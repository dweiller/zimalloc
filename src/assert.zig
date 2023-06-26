pub fn withMessage(src_loc: std.builtin.SourceLocation, ok: bool, message: []const u8) void {
    if (!ok) {
        log.err("assertion failure: {s}:{d}:{d} {s}: {s}", .{
            src_loc.file,
            src_loc.line,
            src_loc.column,
            src_loc.fn_name,
            message,
        });
        std.os.exit(1);
    }
}

const std = @import("std");
const log = @import("log.zig");
