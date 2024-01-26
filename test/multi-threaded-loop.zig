var zigpa = ZiAllocator(.{}){};

pub fn main() !void {
    defer zigpa.deinit();

    const max_spawn_count = 128 * 5;
    var threads: [max_spawn_count]std.Thread = undefined;

    const concurrency_limit = try std.Thread.getCpuCount();
    const spawn_count = 5 * concurrency_limit;

    var semaphore = std.Thread.Semaphore{};

    var wg = std.Thread.WaitGroup{};

    var init_count = std.atomic.Value(usize).init(spawn_count);

    for (threads[0..spawn_count], 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, run, .{ i, &wg, &semaphore, &init_count });
    }

    while (init_count.load(.Acquire) != 0) {
        std.atomic.spinLoopHint();
    }

    std.log.debug("starting loops", .{});
    {
        semaphore.mutex.lock();
        defer semaphore.mutex.unlock();
        semaphore.permits = concurrency_limit;
        semaphore.cond.broadcast();
    }

    wg.wait();

    std.log.debug("joining threads", .{});
    for (threads[0..spawn_count]) |thread| {
        thread.join();
    }
}

threadlocal var thread_index: ?usize = null;

fn run(index: usize, wg: *std.Thread.WaitGroup, semaphore: *std.Thread.Semaphore, init: *std.atomic.Value(usize)) !void {
    wg.start();
    defer wg.finish();

    defer zigpa.deinitCurrentThreadHeap();

    thread_index = index;
    std.log.debug("starting thread", .{});

    const allocator = zigpa.allocator();

    _ = init.fetchSub(1, .Release);

    for (1..5) |i| {
        semaphore.wait();
        defer semaphore.post();

        std.log.debug("running iteration {d}", .{i});

        var buf: [50000]*[256]u8 = undefined; // pointers to 12 MiB of data

        for (&buf) |*ptr| {
            const b = try allocator.create([256]u8);
            b.* = [1]u8{1} ** 256;
            ptr.* = b;
        }

        for (buf) |ptr| {
            allocator.destroy(ptr);
        }

        std.log.debug("finished iteration {d}", .{i});
    }
}

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !std.log.logEnabled(message_level, scope)) return;

    const level_txt = comptime message_level.asText();
    const prefix1 = "[Thread {?d}-{d}] ";
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const stderr = std.io.getStdErr().writer();
    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    nosuspend stderr.print(
        prefix1 ++ level_txt ++ prefix2 ++ format ++ "\n",
        .{ thread_index, std.Thread.getCurrentId() } ++ args,
    ) catch return;
}

const std = @import("std");

const build_options = @import("build_options");
const ZiAllocator = @import("zimalloc").Allocator;
