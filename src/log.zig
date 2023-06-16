/// Log an error message. This log level is intended to be used
/// when something has gone wrong. This might be recoverable or might
/// be followed by the program exiting.
pub fn err(
    comptime format: []const u8,
    args: anytype,
) void {
    @setCold(true);
    log(.err, format, args);
}

/// Log a warning message. This log level is intended to be used if
/// it is uncertain whether something has gone wrong or not, but the
/// circumstances would be worth investigating.
pub fn warn(
    comptime format: []const u8,
    args: anytype,
) void {
    log(.warn, format, args);
}

/// Log an info message. This log level is intended to be used for
/// general messages about the state of the program.
pub fn info(
    comptime format: []const u8,
    args: anytype,
) void {
    log(.info, format, args);
}

/// Log an info message. This log level is intended to be used for
/// general messages about the state of the program that are noisy
/// and are turned off by default.
pub fn infoVerbose(
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !verbose_logging) return;
    log(.info, format, args);
}

/// Log a debug message. This log level is intended to be used for
/// messages which are only useful for debugging.
pub fn debug(
    comptime format: []const u8,
    args: anytype,
) void {
    log(.debug, format, args);
}

/// Log a debug message. This log level is intended to be used for
/// messages which are only useful for debugging that are noisy and
/// are turned off by default.
pub fn debugVerbose(
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !verbose_logging) return;
    log(.debug, format, args);
}

const verbose_logging = if (@hasDecl(build_options, "verbose_logging"))
    build_options.verbose_logging
else
    false;

const level: std.log.Level = if (@hasDecl(build_options, "log_level"))
    std.enums.nameCast(std.log.Level, build_options.log_level)
else
    .warn;

fn log(
    comptime message_level: std.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !logEnabled(message_level)) return;

    std.options.logFn(message_level, .zimalloc, format, args);
}

fn logEnabled(comptime message_level: std.log.Level) bool {
    return @enumToInt(message_level) <= @enumToInt(level);
}

const std = @import("std");

const build_options = @import("build_options");
