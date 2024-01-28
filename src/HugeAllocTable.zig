pub fn HugeAllocTable(comptime store_size: bool) type {
    return struct {
        hash_map: Map = .{},
        rwlock: std.Thread.RwLock = .{},

        const Self = @This();

        const Map = std.AutoHashMapUnmanaged(usize, if (store_size) usize else void);

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.rwlock.lock();
            self.hash_map.deinit(allocator);
            self.* = undefined;
        }

        pub fn lock(self: *Self) void {
            self.rwlock.lock();
        }

        pub fn tryLock(self: *Self) void {
            self.rwlock.tryLock();
        }

        pub fn unlock(self: *Self) void {
            self.rwlock.unlock();
        }

        pub fn tryLockShared(self: *Self) bool {
            return self.rwlock.tryLockShared();
        }

        pub fn lockShared(self: *Self) void {
            self.rwlock.lockShared();
        }

        pub fn unlockShared(self: *Self) void {
            self.rwlock.unlockShared();
        }

        pub fn contains(self: *Self, ptr: *const anyopaque) bool {
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

            return self.containsRaw(ptr);
        }

        pub fn containsRaw(self: *Self, ptr: *const anyopaque) bool {
            return self.hash_map.contains(@intFromPtr(ptr));
        }

        pub fn remove(self: *Self, ptr: *const anyopaque) bool {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            return self.removeRaw(ptr);
        }

        pub fn removeRaw(self: *Self, ptr: *const anyopaque) bool {
            return self.hash_map.remove(@intFromPtr(ptr));
        }

        pub fn ensureUnusedCapacity(self: *Self, allocator: Allocator, additional_count: usize) !void {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            return self.ensureUnusedCapacityRaw(allocator, additional_count);
        }

        pub fn ensureUnusedCapacityRaw(self: *Self, allocator: Allocator, additional_count: u32) !void {
            return self.hash_map.ensureUnusedCapacity(allocator, additional_count);
        }

        pub fn putAssumeCapacityNoClobber(self: *Self, ptr: *const anyopaque, size: usize) !void {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            return self.putAssumeCapacityNoClobberRaw(ptr, size);
        }

        pub fn putAssumeCapacityNoClobberRaw(self: *Self, ptr: *const anyopaque, size: usize) void {
            return self.hash_map.putAssumeCapacityNoClobber(@intFromPtr(ptr), if (store_size) size else {});
        }

        pub fn putAssumeCapacity(self: *Self, ptr: *const anyopaque, size: usize) void {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            return self.putAssumeCapacityRaw(ptr, size);
        }

        pub fn putAssumeCapacityRaw(self: *Self, ptr: *const anyopaque, size: usize) void {
            return self.hash_map.putAssumeCapacity(@intFromPtr(ptr), if (store_size) size else {});
        }

        pub fn putNoClobber(self: *Self, allocator: Allocator, ptr: *const anyopaque, size: usize) !void {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            return self.putNoClobberRaw(allocator, ptr, size);
        }

        pub fn putNoClobberRaw(self: *Self, allocator: Allocator, ptr: *const anyopaque, size: usize) !void {
            return self.hash_map.putNoClobber(allocator, @intFromPtr(ptr), {}, if (store_size) size else {});
        }

        pub fn put(self: *Self, allocator: Allocator, ptr: *const anyopaque, size: usize) !void {
            self.rwlock.lock();
            defer self.rwlock.unlock();

            return self.putRaw(allocator, ptr, size);
        }

        pub fn putRaw(self: *Self, allocator: Allocator, ptr: *const anyopaque, size: usize) !void {
            return self.hash_map.put(allocator, @intFromPtr(ptr), if (store_size) size else {});
        }

        pub fn get(self: *Self, ptr: *const anyopaque) ?usize {
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();

            return self.getRaw(ptr);
        }

        pub fn getRaw(self: *Self, ptr: *const anyopaque) ?usize {
            if (!store_size) @compileError("cannot call get() or getRaw() when not storing size");
            return self.hash_map.get(@intFromPtr(ptr));
        }
    };
}
const std = @import("std");
const Allocator = std.mem.Allocator;
