const std = @import("std");
const Mutex = @import("mutex.zig").Mutex;

// Simple wrapper around the std.HashMap lol
pub fn Cache(comptime K: type, comptime V: type, comptime V_cleanup: ?*const fn (val: *V) void) type {
    return struct {
        const Node = struct {
            key: K,
            value: V,
            prev: ?*Node = null,
            next: ?*Node = null,
        };

        const Self = @This();
        const HashMap = std.AutoHashMap(K, *Node);
        const value_cleanup: ?*const fn (val: *V) void = if (V_cleanup) |f| f else null;

        allocator: std.mem.Allocator,
        map: HashMap,
        head: ?*Node = null,
        tail: ?*Node = null,
        capacity: usize,
        size: usize = 0,
        mutex: Mutex = .{},

        pub fn init(allocator: std.mem.Allocator, capacity: usize) Self {
            return Self{
                .allocator = allocator,
                .map = HashMap.init(allocator),
                .capacity = capacity,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var current = self.head;
            while (current) |node| {
                const next = node.next;
                if (value_cleanup) |cleanup| {
                    cleanup(&node.value);
                }
                self.allocator.destroy(node);
                current = next;
            }
            self.map.deinit();
        }

        pub fn contains(self: *Self, key: K) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.map.contains(key);
        }

        pub fn get(self: *Self, key: K) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.get(key)) |node| {
                self.moveToHead(node);
                return node.value;
            }
            return null;
        }

        /// Puts a key-value pair into the cache.
        pub fn put(self: *Self, key: K, value: V) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.get(key)) |node| {
                // Update existing
                if (value_cleanup) |cleanup| cleanup(&node.value);
                node.value = value;
                self.moveToHead(node);
                return;
            }

            // Create new node
            const node = try self.allocator.create(Node);
            errdefer self.allocator.destroy(node);
            node.* = Node{ .key = key, .value = value };

            if (self.size >= self.capacity) {
                // Evict LRU
                if (self.tail) |lru| {
                    _ = self.map.remove(lru.key);
                    self.removeNode(lru);
                    if (value_cleanup) |cleanup| cleanup(&lru.value);
                    self.allocator.destroy(lru);
                    self.size -= 1;
                }
            }

            try self.map.put(key, node);
            self.addToHead(node);
            self.size += 1;
        }

        pub fn remove(self: *Self, key: K) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.fetchRemove(key)) |entry| {
                const node = entry.value;
                const value = node.value;
                self.removeNode(node);
                self.allocator.destroy(node);
                self.size -= 1;
                // Ownership transfers to the caller; cleaning here would
                // return a dangling value for owning cache element types.
                return value;
            }
            return null;
        }

        pub fn clear(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var current = self.head;
            while (current) |node| {
                const next = node.next;
                if (value_cleanup) |cleanup| {
                    cleanup(&node.value);
                }
                self.allocator.destroy(node);
                current = next;
            }

            self.map.clearAndFree();
            self.head = null;
            self.tail = null;
            self.size = 0;
        }

        fn addToHead(self: *Self, node: *Node) void {
            node.prev = null;
            node.next = self.head;

            if (self.head) |head| {
                head.prev = node;
            } else {
                self.tail = node;
            }
            self.head = node;
        }

        fn removeNode(self: *Self, node: *Node) void {
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = node.next;
            }

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = node.prev;
            }
        }

        fn moveToHead(self: *Self, node: *Node) void {
            if (self.head == node) return;

            self.removeNode(node);
            self.addToHead(node);
        }
    };
}
