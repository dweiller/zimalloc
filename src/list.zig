pub fn Appendable(comptime T: type) type {
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

pub fn Circular(comptime T: type) type {
    return struct {
        head: ?*Node,

        const Self = @This();

        pub const Node = struct {
            data: T,
            next: *Node,
            prev: *Node,

            /// join the lists containing `self` and `other` so that `self.next == other`
            /// ┌─self.prev──self──other──other.next─┐
            /// │                                    │
            /// └────────self.next──other.prev───────┘
            pub fn insertAfter(self: *Node, other: *Node) void {
                self.next.prev = other.prev;
                other.prev.next = self.next;

                self.next = other;
                other.prev = self;
            }

            /// join the lists containing `self` and `other` so that `self.prev == other`
            /// ┌─other.prev──other──self──self.next─┐
            /// │                                    │
            /// └────────other.next──self.prev───────┘
            pub fn insertBefore(self: *Node, other: *Node) void {
                other.insertAfter(self);
            }

            pub fn remove(self: *Node) void {
                self.prev.next = self.next;
                self.next.prev = self.prev;

                self.next = self;
                self.prev = self;
            }
        };

        pub fn popFirst(self: *Self) ?*Node {
            if (self.head) |node| {
                node.remove();
                return node;
            }
            return null;
        }

        pub fn popLast(self: *Self) ?*Node {
            if (self.head) |node| {
                const last = node.prev;
                last.remove();
                return last;
            }
            return null;
        }

        pub fn remove(self: *Self, node: *Node) void {
            if (node.next == node) {
                assert(node.prev == node);
                self.head = null;
                return;
            }
            node.remove();
        }

        pub fn prependNodes(self: *Self, node: *Node) void {
            if (self.head) |first| {
                first.insertBefore(node.prev);
            }
            self.head = node;
        }

        pub fn prependOne(self: *Self, node: *Node) void {
            assert(node.next == node and node.prev == node);
            self.prependNodes(node);
        }

        pub fn appendNodes(self: *Self, node: *Node) void {
            if (self.head) |first| {
                first.insertBefore(node.prev);
            } else {
                self.head = node;
            }
        }

        pub fn appendOne(self: *Self, node: *Node) void {
            assert(node.next == node and node.prev == node);
            self.appendNodes(node);
        }

    };
}

const std = @import("std");
const assert = std.debug.assert;
