// src/kernel/schedulers/time_sharing.zig
const std = @import("std");
const thread_s = @import("../thread.zig");
const scheduler = @import("../scheduler.zig");
const Thread = thread_s.Thread;
const Priority = thread_s.Priority;
const Scheduler = scheduler.Scheduler;
const SchedulerError = scheduler.SchedulerError;
const SchedulerStats = scheduler.SchedulerStats;
const SchedulerVTable = scheduler.SchedulerVTable;

const PriorityQueue = struct {
    head: ?*Thread,
    tail: ?*Thread,
    count: u32,

    fn init() PriorityQueue {
        return PriorityQueue{
            .head = null,
            .tail = null,
            .count = 0,
        };
    }

    fn enqueue(self: *PriorityQueue, thread: *Thread) void {
        thread.next = null;
        thread.prev = self.tail;

        if (self.tail) |tail| {
            tail.next = thread;
            self.tail = thread;
        } else {
            self.head = thread;
            self.tail = thread;
        }

        self.count += 1;
    }

    fn dequeue(self: *PriorityQueue) ?*Thread {
        if (self.head) |thread| {
            self.head = thread.next;
            if (self.head) |next| {
                next.prev = null;
            } else {
                self.tail = null;
            }

            thread.next = null;
            thread.prev = null;
            self.count -= 1;

            return thread;
        }
        return null;
    }

    fn remove(self: *PriorityQueue, thread: *Thread) void {
        if (thread.prev) |prev| {
            prev.next = thread.next;
        } else {
            self.head = thread.next;
        }

        if (thread.next) |next| {
            next.prev = thread.prev;
        } else {
            self.tail = thread.prev;
        }

        thread.next = null;
        thread.prev = null;

        if (self.count > 0) {
            self.count -= 1;
        }
    }

    fn isEmpty(self: *const PriorityQueue) bool {
        return self.head == null;
    }
};

pub const TimeSharingScheduler = struct {
    priority_queues: [5]PriorityQueue, // One queue per priority level
    total_threads: u32,
    context_switches: u64,
    base_time_slice: u32,
    aging_threshold: u32,
    aging_counter: u32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, base_time_slice: u32) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .priority_queues = [_]PriorityQueue{PriorityQueue.init()} ** 5,
            .total_threads = 0,
            .context_switches = 0,
            .base_time_slice = base_time_slice,
            .aging_threshold = 100, // Promote threads after 100 ticks
            .aging_counter = 0,
            .allocator = allocator,
        };
        return self;
    }

    pub fn scheduler(self: *Self) Scheduler {
        return Scheduler{
            .ptr = self,
            .vtable = &vtable,
            .scheduler_type = .TimeSharing,
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

    fn getTimeSliceForPriority(self: *Self, priority: Priority) u32 {
        return switch (priority) {
            .IDLE => self.base_time_slice / 4,
            .LOW => self.base_time_slice / 2,
            .NORMAL => self.base_time_slice,
            .HIGH => self.base_time_slice * 2,
            .KERNEL => self.base_time_slice * 4,
        };
    }

    fn addThread(ptr: *anyopaque, thread: *Thread) SchedulerError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const priority_index = @intFromEnum(thread.priority);
        self.priority_queues[priority_index].enqueue(thread);
        self.total_threads += 1;
        thread.state = .READY;
        thread.remaining_time = self.getTimeSliceForPriority(thread.priority);
    }

    fn removeThread(ptr: *anyopaque, thread: *Thread) SchedulerError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const priority_index = @intFromEnum(thread.priority);
        self.priority_queues[priority_index].remove(thread);

        if (self.total_threads > 0) {
            self.total_threads -= 1;
        }
    }

    fn selectNext(ptr: *anyopaque) ?*Thread {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Find highest priority non-empty queue
        var priority_level: i32 = 4; // Start from highest priority
        while (priority_level >= 0) : (priority_level -= 1) {
            const queue_index = @as(usize, @intCast(priority_level));
            if (!self.priority_queues[queue_index].isEmpty()) {
                if (self.priority_queues[queue_index].dequeue()) |thread| {
                    thread.state = .RUNNING;
                    thread.remaining_time = self.getTimeSliceForPriority(thread.priority);
                    self.context_switches += 1;
                    return thread;
                }
            }
        }

        return null;
    }

    fn timerTick(ptr: *anyopaque, current_thread: ?*Thread) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        self.aging_counter += 1;

        // Perform aging every aging_threshold ticks
        if (self.aging_counter >= self.aging_threshold) {
            self.aging_counter = 0;
            self.performAging();
        }

        if (current_thread) |thread| {
            if (thread.remaining_time > 0) {
                thread.remaining_time -= 1;
                return thread.remaining_time == 0;
            }
        }

        return false;
    }

    fn performAging(self: *Self) void {
        // Move some threads from lower priority queues to higher ones
        // to prevent starvation
        var priority_level: usize = 0;
        while (priority_level < 3) : (priority_level += 1) { // Don't age KERNEL priority
            var queue = &self.priority_queues[priority_level];
            var thread = queue.head;
            var threads_to_promote: u32 = queue.count / 4; // Promote 25% of threads

            while (thread != null and threads_to_promote > 0) {
                const next_thread = thread.?.next;

                // Remove from current queue
                queue.remove(thread.?);

                // Promote priority
                if (@intFromEnum(thread.?.priority) < 4) {
                    thread.?.priority = @enumFromInt(@intFromEnum(thread.?.priority) + 1);
                }

                // Add to higher priority queue
                const new_priority_index = @intFromEnum(thread.?.priority);
                self.priority_queues[new_priority_index].enqueue(thread.?);

                thread = next_thread;
                threads_to_promote -= 1;
            }
        }
    }

    fn shouldPreempt(ptr: *anyopaque, current_thread: *Thread) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Check if there's a higher priority thread waiting
        const current_priority = @intFromEnum(current_thread.priority);
        var priority_level: usize = current_priority + 1;
        while (priority_level < 5) : (priority_level += 1) {
            if (!self.priority_queues[priority_level].isEmpty()) {
                return true; // Higher priority thread available
            }
        }

        // Preempt if time slice expired
        return current_thread.remaining_time == 0;
    }

    fn getStats(ptr: *anyopaque) SchedulerStats {
        const self: *Self = @ptrCast(@alignCast(ptr));

        var ready_threads: u32 = 0;
        for (self.priority_queues) |queue| {
            ready_threads += queue.count;
        }

        return SchedulerStats{
            .total_threads = self.total_threads,
            .ready_threads = ready_threads,
            .context_switches = self.context_switches,
            .scheduler_type = .TimeSharing,
        };
    }

    fn reset(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        for (&self.priority_queues) |*queue| {
            queue.* = PriorityQueue.init();
        }
        self.total_threads = 0;
        self.context_switches = 0;
        self.aging_counter = 0;
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};
