hash_map: Map,
mutex: std.Thread.Mutex,

const HugeAllocTable = @This();

const Map = std.AutoHashMap(usize, usize);

pub fn init(allocator: std.mem.Allocator) HugeAllocTable {
    return .{
        .hash_map = Map.init(allocator),
        .mutex = .{},
    };
}

pub fn deinit(self: *HugeAllocTable) void {
    self.mutex.lock();
    self.hash_map.deinit();
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

pub fn ensureUnusedCapacity(self: *HugeAllocTable, additional_count: usize) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.ensureUnusedCapacityRaw(additional_count);
}

pub fn ensureUnusedCapacityRaw(self: *HugeAllocTable, additional_count: u32) !void {
    return self.hash_map.ensureUnusedCapacity(additional_count);
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

pub fn putNoClobber(self: *HugeAllocTable, ptr: *anyopaque, size: usize) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.putNoClobberRaw(ptr, size);
}

pub fn putNoClobberRaw(self: *HugeAllocTable, ptr: *anyopaque, size: usize) !void {
    return self.hash_map.putNoClobber(@intFromPtr(ptr), {}, size);
}

pub fn put(self: *HugeAllocTable, ptr: *anyopaque, size: usize) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    return self.putRaw(ptr, size);
}

pub fn putRaw(self: *HugeAllocTable, ptr: *anyopaque, size: usize) !void {
    return self.hash_map.put(@intFromPtr(ptr), size);
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
