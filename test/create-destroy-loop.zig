const std = @import("std");
const build_options = @import("build_options");
const ZiAllocator = @import("zimalloc").Allocator;

pub fn main() !void {
    var zigpa = ZiAllocator(.{}){};
    defer zigpa.deinit();

    const allocator = zigpa.allocator();

    if (comptime build_options.pauses) {
        waitForInput("enter loop");
    }

    inline for (.{ 1, 2, 3, 4 }) |_| {
        var buf: [50000]*[256]u8 = undefined; // pointers to 12 MiB of data

        for (&buf) |*ptr| {
            const b = try allocator.create([256]u8);
            b.* = [1]u8{1} ** 256;
            ptr.* = b;
        }

        if (comptime build_options.pauses) {
            std.debug.print("memory allocated\n", .{});
            waitForInput("free memory");
            std.debug.print("freeing memory\n", .{});
        }

        for (buf) |ptr| {
            allocator.destroy(ptr);
        }
        if (comptime build_options.pauses) {
            std.debug.print("memory freed\n", .{});
            waitForInput("continue");
        }
    }
}

fn waitForInput(action: []const u8) void {
    std.debug.print("hit [enter] to {s}\n", .{action});
    const stdin = std.io.getStdIn().reader();
    var buf: [64]u8 = undefined;
    _ = stdin.readUntilDelimiter(&buf, '\n') catch return;
}
