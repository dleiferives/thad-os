// src/kernel/mutex.zig
const std = @import("std");
const arch = @import("arch");
const ThreadQueue = @import("thread_queue.zig").ThreadQueue;

pub const Mutex = struct {
    locked: bool = false,
    owner: ?*Thread = null,
    blocked_queue: ThreadQueue = .{},

    const Thread = @import("thread.zig").Thread;
    const kernel = @import("kernel.zig");

    pub fn init() Mutex {
        return .{};
    }

    pub fn lock(self: *Mutex) void {
        arch.irq.irq.disable();

        while (self.locked) {
            if (Thread.getCurrentThread()) |current| {
                current.state = .BLOCKED_MUTEX;
                self.blocked_queue.enqueue(current);

                // Remove from scheduler
                if (kernel.state.scheduler) |sched| {
                    sched.removeThread(current) catch {};
                }

                arch.irq.irq.enable();
                Thread.yield();
                arch.irq.irq.disable();
            } else {
                arch.irq.irq.enable();
                return;
            }
        }

        self.locked = true;
        self.owner = Thread.getCurrentThread();
        arch.irq.irq.enable();
    }

    pub fn unlock(self: *Mutex) void {
        arch.irq.irq.disable();
        defer arch.irq.irq.enable();

        if (self.owner != Thread.getCurrentThread()) {
            @panic("Mutex unlock by non-owner");
        }

        self.locked = false;
        self.owner = null;

        // Unblock one waiting thread
        self.blocked_queue.unblockOne();
    }

    pub fn tryLock(self: *Mutex) bool {
        arch.irq.irq.disable();
        defer arch.irq.irq.enable();

        if (self.locked) {
            return false;
        }

        self.locked = true;
        self.owner = Thread.getCurrentThread();
        return true;
    }
};
