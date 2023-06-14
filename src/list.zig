pub fn List(comptime T: type) type {
    return struct {
        first: ?*Node,
        /// only valid if first != null
        last: *Node,

        const Self = @This();

        pub const Node = struct {
            data: T,
            next: ?*Node,
        };

        pub fn popFirst(self: *Self) ?*Node {
            const node = self.first orelse return null;
            self.first = node.next;
            return node;
        }

        pub fn prepend(self: *Self, node: *Node) void {
            if (self.first == null) self.last = node;
            node.next = self.first;
            self.first = node;
        }

        pub fn append(self: *Self, node: *Node) void {
            self.last.next = node;
            var other_iter: *Node = node;
            while (other_iter.next) |n| : (other_iter = n) {}
            self.last = other_iter;
        }
    };
}

pub fn OffsetList(comptime T: type, comptime OffsetInt: type) type {
    return struct {
        first: ?OffsetInt,
        last: OffsetInt,

        const Self = @This();

        pub const Node = struct {
            data: T,
            next: ?OffsetInt,
        };

        pub fn popFirst(self: *Self, base: *anyopaque) ?*Node {
            const node_offset = self.first orelse return null;
            const node = @intToPtr(*Node, node_offset + @ptrToInt(base));
            self.first = node.next;
            return node;
        }

        // asserts that std.math.maxInt(OffsetInt) >= @ptrToInt(node) - @ptrToInt(base) >= 0;
        pub fn prepend(self: *Self, base: *anyopaque, node: *Node) void {
            node.next = self.first;
            self.first = offset(base, node);
        }

        pub fn appendList(self: *Self, other: *Self) void {
            self.last.next = other.first;
            self.last = other.last;
        }

        fn offset(base: *anyopaque, other: *anyopaque) OffsetInt {
            const base_address = @ptrToInt(base);
            const other_address = @ptrToInt(other);
            assert(base_address <= other_address);
            assert(other_address - base_address <= std.math.maxInt(OffsetInt));
            return @intCast(OffsetInt, other_address - base_address);
        }
    };
}

const std = @import("std");
const assert = std.debug.assert;
