// src/kernel/thread_queue.zig
const std = @import("std");

pub const ThreadQueue = struct {
    head: ?*Thread = null,
    tail: ?*Thread = null,
    count: u32 = 0,

    const Thread = @import("thread.zig").Thread;

    pub fn init() ThreadQueue {
        return .{};
    }

    pub fn enqueue(self: *ThreadQueue, thread: *Thread) void {
        thread.next_blocked = null;

        if (self.tail) |tail| {
            tail.next_blocked = thread;
            thread.prev_blocked = tail;
            self.tail = thread;
        } else {
            self.head = thread;
            self.tail = thread;
            thread.prev_blocked = null;
        }
        self.count += 1;
    }

    pub fn dequeue(self: *ThreadQueue) ?*Thread {
        if (self.head) |head| {
            self.head = head.next_blocked;
            if (self.head) |new_head| {
                new_head.prev_blocked = null;
            } else {
                self.tail = null;
            }

            head.next_blocked = null;
            head.prev_blocked = null;
            self.count -= 1;
            return head;
        }
        return null;
    }

    pub fn remove(self: *ThreadQueue, thread: *Thread) bool {
        var current = self.head;
        while (current) |curr| {
            if (curr == thread) {
                if (curr.prev_blocked) |prev| {
                    prev.next_blocked = curr.next_blocked;
                } else {
                    self.head = curr.next_blocked;
                }

                if (curr.next_blocked) |next| {
                    next.prev_blocked = curr.prev_blocked;
                } else {
                    self.tail = curr.prev_blocked;
                }

                curr.next_blocked = null;
                curr.prev_blocked = null;
                self.count -= 1;
                return true;
            }
            current = curr.next_blocked;
        }
        return false;
    }

    pub fn isEmpty(self: *ThreadQueue) bool {
        return self.head == null;
    }

    pub fn unblockAll(self: *ThreadQueue) void {
        const kernel = @import("kernel.zig");
        while (self.dequeue()) |thread| {
            thread.state = .READY;
            if (kernel.state.scheduler) |sched| {
                sched.addThread(thread) catch {};
            }
        }
    }

    pub fn unblockOne(self: *ThreadQueue) void {
        const kernel = @import("kernel.zig");
        if (self.dequeue()) |thread| {
            thread.state = .READY;
            if (kernel.state.scheduler) |sched| {
                sched.addThread(thread) catch {};
            }
        }
    }
};
