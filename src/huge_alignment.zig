const builtin = @import("builtin");

pub usingnamespace switch (builtin.os.tag) {
    .linux => @import("huge_alignment/linux.zig"),
    .windows => @import("huge_alignment/windows.zig"),
    else => |tag| @compileError(@tagName(tag) ++ "is not supported yet"),
};
