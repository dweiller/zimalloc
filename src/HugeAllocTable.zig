hash_map: Map = .{},
mutex: std.Thread.Mutex = .{},

const HugeAllocTable = @This();

const Map = std.AutoHashMapUnmanaged(usize, usize);

pub fn deinit(self: *HugeAllocTable, allocator: Allocator) void {
    self.mutex.lock();
    self.hash_map.deinit(allocator);
    self.* = undefined;
}

pub fn lock(self: *HugeAllocTable) void {
    self.mutex.lock();
}

pub fn tryLock(self: *HugeAllocTable) void {
    self.mutex.tryLock();
}

pub fn unlock(self: *HugeAllocTable) void {
    self.mutex.unlock();
}

pub fn contains(self: *HugeAllocTable, ptr: *anyopaque) bool {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.containsRaw(ptr);
}

pub fn containsRaw(self: *HugeAllocTable, ptr: *anyopaque) bool {
    return self.hash_map.contains(@intFromPtr(ptr));
}

pub fn remove(self: *HugeAllocTable, ptr: *anyopaque) bool {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.removeRaw(ptr);
}

pub fn removeRaw(self: *HugeAllocTable, ptr: *anyopaque) bool {
    return self.hash_map.remove(@intFromPtr(ptr));
}

pub fn ensureUnusedCapacity(self: *HugeAllocTable, allocator: Allocator, additional_count: usize) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.ensureUnusedCapacityRaw(allocator, additional_count);
}

pub fn ensureUnusedCapacityRaw(self: *HugeAllocTable, allocator: Allocator, additional_count: u32) !void {
    return self.hash_map.ensureUnusedCapacity(allocator, additional_count);
}

pub fn putAssumeCapacityNoClobber(self: *HugeAllocTable, ptr: *anyopaque, size: usize) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.putAssumeCapacityNoClobberRaw(ptr, size);
}

pub fn putAssumeCapacityNoClobberRaw(self: *HugeAllocTable, ptr: *anyopaque, size: usize) void {
    return self.hash_map.putAssumeCapacityNoClobber(@intFromPtr(ptr), size);
}

pub fn putAssumeCapacity(self: *HugeAllocTable, ptr: *anyopaque, size: usize) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.putAssumeCapacityRaw(ptr, size);
}

pub fn putAssumeCapacityRaw(self: *HugeAllocTable, ptr: *anyopaque, size: usize) !void {
    return self.hash_map.putAssumeCapacity(@intFromPtr(ptr), size);
}

pub fn putNoClobber(self: *HugeAllocTable, allocator: Allocator, ptr: *anyopaque, size: usize) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.putNoClobberRaw(allocator, ptr, size);
}

pub fn putNoClobberRaw(self: *HugeAllocTable, allocator: Allocator, ptr: *anyopaque, size: usize) !void {
    return self.hash_map.putNoClobber(allocator, @intFromPtr(ptr), {}, size);
}

pub fn put(self: *HugeAllocTable, allocator: Allocator, ptr: *anyopaque, size: usize) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.putRaw(allocator, ptr, size);
}

pub fn putRaw(self: *HugeAllocTable, allocator: Allocator, ptr: *anyopaque, size: usize) !void {
    return self.hash_map.put(allocator, @intFromPtr(ptr), size);
}

pub fn get(self: *HugeAllocTable, ptr: *anyopaque) ?usize {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.getRaw(ptr);
}

pub fn getRaw(self: *HugeAllocTable, ptr: *anyopaque) ?usize {
    return self.hash_map.get(@intFromPtr(ptr));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
