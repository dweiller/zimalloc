pub fn todo(comptime message: []const u8) noreturn {
    const actual_message = "TODO: " ++ message;
    if (@import("builtin").mode == .Debug)
        @panic(actual_message)
    else
        @compileError(actual_message);
}
