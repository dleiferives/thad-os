// src/kernel/schedulers/round_robin.zig
const std = @import("std");
const thread_s = @import("../thread.zig");
const thread_queue = @import("../thread_queue.zig");
const ThreadQueue = thread_queue.ThreadQueue;
const scheduler = @import("../scheduler.zig");
const Thread = thread_s.Thread;
const Scheduler = scheduler.Scheduler;
const SchedulerError = scheduler.SchedulerError;
const SchedulerStats = scheduler.SchedulerStats;
const SchedulerVTable = scheduler.SchedulerVTable;

pub const RoundRobinScheduler = struct {
    ready_queue: std.DoublyLinkedList(*Thread),
    blocked_queues: std.AutoHashMap(u32, ThreadQueue),
    current_time_slice: u32,
    default_time_slice: u32,
    total_threads: u32,
    context_switches: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, time_slice: u32) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .ready_queue = std.DoublyLinkedList(*Thread){},
            .current_time_slice = time_slice,
            .default_time_slice = time_slice,
            .total_threads = 0,
            .context_switches = 0,
            .allocator = allocator,
            .blocked_queues = std.AutoHashMap(u32, ThreadQueue).init(allocator),
        };
        return self;
    }

    pub fn scheduler(self: *Self) Scheduler {
        return Scheduler{
            .ptr = self,
            .vtable = &vtable,
            .scheduler_type = .RoundRobin,
            .current_thread = null,
        };
    }

    const vtable = SchedulerVTable{
        .addThread = addThread,
        .removeThread = removeThread,
        .selectNext = selectNext,
        .timerTick = timerTick,
        .shouldPreempt = shouldPreempt,
        .getStats = getStats,
        .reset = reset,
        .deinit = deinit,
    };

    fn addThread(ptr: *anyopaque, thread: *Thread) SchedulerError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Create node and add to end of queue
        const node = self.allocator.create(std.DoublyLinkedList(*Thread).Node) catch {
            return SchedulerError.OutOfMemory;
        };
        node.data = thread;

        self.ready_queue.append(node);
        self.total_threads += 1;
        thread.state = .READY;
        thread.remaining_time = self.default_time_slice;
    }

    fn removeThread(ptr: *anyopaque, thread: *Thread) SchedulerError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Find and remove the thread from the queue
        var it = self.ready_queue.first;
        while (it) |node| {
            if (node.data == thread) {
                self.ready_queue.remove(node);
                self.allocator.destroy(node);
                if (self.total_threads > 0) {
                    self.total_threads -= 1;
                }
                return;
            }
            it = node.next;
        }
    }

    fn selectNext(ptr: *anyopaque) ?*Thread {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Pop from front of queue
        if (self.ready_queue.popFirst()) |node| {
            const thread = node.data;

            // Add back to end of queue (round robin behavior)
            self.ready_queue.append(node);

            thread.state = .RUNNING;
            thread.remaining_time = self.default_time_slice;
            self.context_switches += 1;

            return thread;
        }

        return null;
    }

    fn timerTick(ptr: *anyopaque, current_thread: ?*Thread) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;

        if (current_thread) |thread| {
            if (thread.remaining_time > 0) {
                thread.remaining_time -= 1;
                return thread.remaining_time == 0;
            }
        }

        return false;
    }

    fn shouldPreempt(ptr: *anyopaque, current_thread: *Thread) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Preempt if time slice expired and there are other threads waiting
        return current_thread.remaining_time == 0 and self.ready_queue.len > 0;
    }

    fn getStats(ptr: *anyopaque) SchedulerStats {
        const self: *Self = @ptrCast(@alignCast(ptr));

        return SchedulerStats{
            .total_threads = self.total_threads,
            .ready_threads = @intCast(self.ready_queue.len),
            .context_switches = self.context_switches,
            .scheduler_type = .RoundRobin,
        };
    }

    fn reset(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Clean up all nodes
        while (self.ready_queue.popFirst()) |node| {
            self.allocator.destroy(node);
        }

        self.total_threads = 0;
        self.context_switches = 0;
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Clean up any remaining nodes
        while (self.ready_queue.popFirst()) |node| {
            self.allocator.destroy(node);
        }

        allocator.destroy(self);
    }

    pub fn addBlockedQueue(self: *Self, queue_id: u32) !void {
        try self.blocked_queues.put(queue_id, ThreadQueue.init());
    }

    pub fn getBlockedQueue(self: *Self, queue_id: u32) ?*ThreadQueue {
        return self.blocked_queues.getPtr(queue_id);
    }

};
