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

pub const TimeSharingScheduler = struct {
    priority_queues: []std.ArrayListUnmanaged(*Thread),
    total_threads: u32,
    context_switches: u64,
    base_time_slice: u32,
    aging_threshold: u32,
    aging_counter: u32,
    allocator: std.mem.Allocator,
    current_thread: ?*Thread = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, base_time_slice: u32) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .priority_queues = try allocator.alloc(std.ArrayListUnmanaged(*Thread), 5),
            .total_threads = 0,
            .context_switches = 0,
            .base_time_slice = base_time_slice,
            .aging_threshold = 100,
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
            .current_thread = self.current_thread,
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
        const queue = &self.priority_queues[priority_index];

        try queue.append(self.allocator, thread);

        self.total_threads += 1;
        thread.state = .READY;
        thread.remaining_time = self.getTimeSliceForPriority(thread.priority);
    }

    fn removeThread(ptr: *anyopaque, thread: *Thread) SchedulerError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const priority_index = @intFromEnum(thread.priority);
        const queue = &self.priority_queues[priority_index];

        for (queue.items, 0..) |t, i| {
            if (t == thread) {
                _ = queue.orderedRemove(i);
                if (self.total_threads > 0) {
                    self.total_threads -= 1;
                }
                return;
            }
        }
    }

    fn selectNext(ptr: *anyopaque) ?*Thread {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Find highest priority non-empty queue
        var priority_level: i32 = 4; // Start from KERNEL
        while (priority_level >= 0) : (priority_level -= 1) {
            const queue_index = @as(usize, @intCast(priority_level));
            const queue = &self.priority_queues[queue_index];

            if (queue.items.len > 0) {
                // Dequeue from the front (FIFO within a priority level)
                const thread = queue.orderedRemove(0);
                thread.state = .RUNNING;
                thread.remaining_time = self.getTimeSliceForPriority(thread.priority);
                self.context_switches += 1;
                return thread;
            }
        }

        return null;
    }

    fn timerTick(ptr: *anyopaque, current_thread: ?*Thread) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        self.aging_counter += 1;

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

        return true;
    }

    fn performAging(self: *Self) void {
        // Iterate from lowest to highest priority, promoting some threads
        // to prevent starvation. We don't age threads into or out of KERNEL.
        var priority_level: usize = 0;
        while (priority_level < 3) : (priority_level += 1) {
            const old_queue = &self.priority_queues[priority_level];
            var threads_to_promote = old_queue.items.len / 4; // Promote 25%

            var i = old_queue.items.len;
            while (i > 0 and threads_to_promote > 0) {
                i -= 1;
                const thread = old_queue.items[i];
                const new_priority:thread_s.Priority = @enumFromInt(priority_level + 1);
                const new_queue = &self.priority_queues[priority_level + 1];

                if (new_queue.append(self.allocator, thread)) |_| {
                    _ = old_queue.orderedRemove(i);
                    thread.priority = new_priority;
                    threads_to_promote -= 1;
                } else |_| {
                    // can skip
                }
            }
        }
    }

    fn shouldPreempt(ptr: *anyopaque, current_thread: *Thread) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Preempt if time slice expired
        if (current_thread.remaining_time == 0) {
            return true;
        }

        // Check if there's a higher priority thread waiting
        const current_priority_val = @intFromEnum(current_thread.priority);
        var priority_level = current_priority_val + 1;
        while (priority_level < 5) : (priority_level += 1) {
            if (self.priority_queues[priority_level].items.len > 0) {
                return true; // Higher priority thread is ready
            }
        }

        return false;
    }

    fn getStats(ptr: *anyopaque) SchedulerStats {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return SchedulerStats{
            .total_threads = self.total_threads,
            .ready_threads = self.total_threads,
            .context_switches = self.context_switches,
            .scheduler_type = .TimeSharing,
        };
    }

    fn reset(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        for (self.priority_queues) |*queue| {
            queue.clearAndFree(self.allocator);
        }
        self.total_threads = 0;
        self.context_switches = 0;
        self.aging_counter = 0;
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Deinit all internal lists before destroying the scheduler itself.
        for (self.priority_queues) |*queue| {
            queue.deinit(self.allocator);
        }
        allocator.destroy(self);
    }
};
