// src/kernel/schedulers/run_to_completion.zig
const std = @import("std");
const thread_s = @import("../thread.zig");
const scheduler = @import("../scheduler.zig");
const Thread = thread_s.Thread;
const Scheduler = scheduler.Scheduler;
const SchedulerError = scheduler.SchedulerError;
const SchedulerStats = scheduler.SchedulerStats;
const SchedulerVTable = scheduler.SchedulerVTable;

pub const RunToCompletionScheduler = struct {
    ready_queue: ?*Thread,
    queue_tail: ?*Thread,
    total_threads: u32,
    context_switches: u64,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .ready_queue = null,
            .queue_tail = null,
            .total_threads = 0,
            .context_switches = 0,
            .allocator = allocator,
        };
        return self;
    }

    pub fn scheduler(self: *Self) Scheduler {
        return Scheduler{
            .ptr = self,
            .vtable = &vtable,
            .scheduler_type = .RunToCompletion,
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

        // Add to end of queue (FIFO)
        thread.next = null;
        thread.prev = self.queue_tail;

        if (self.queue_tail) |tail| {
            tail.next = thread;
            self.queue_tail = thread;
        } else {
            self.ready_queue = thread;
            self.queue_tail = thread;
        }

        self.total_threads += 1;
        thread.state = .READY;
        thread.remaining_time = std.math.maxInt(u32); // Infinite time slice
    }

    fn removeThread(ptr: *anyopaque, thread: *Thread) SchedulerError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (thread.prev) |prev| {
            prev.next = thread.next;
        } else {
            self.ready_queue = thread.next;
        }

        if (thread.next) |next| {
            next.prev = thread.prev;
        } else {
            self.queue_tail = thread.prev;
        }

        thread.next = null;
        thread.prev = null;

        if (self.total_threads > 0) {
            self.total_threads -= 1;
        }
    }

    fn selectNext(ptr: *anyopaque) ?*Thread {
        const self: *Self = @ptrCast(@alignCast(ptr));

        if (self.ready_queue) |thread| {
            // Remove from front (FIFO)
            self.ready_queue = thread.next;
            if (self.ready_queue) |next| {
                next.prev = null;
            } else {
                self.queue_tail = null;
            }

            thread.next = null;
            thread.prev = null;
            thread.state = .RUNNING;
            thread.remaining_time = std.math.maxInt(u32);
            self.context_switches += 1;

            return thread;
        }

        return null;
    }

    fn timerTick(ptr: *anyopaque, current_thread: ?*Thread) bool {
        _ = ptr;
        _ = current_thread;
        // Never preempt on timer tick in run-to-completion
        return false;
    }

    fn shouldPreempt(ptr: *anyopaque, current_thread: *Thread) bool {
        _ = ptr;
        _ = current_thread;
        // Never preempt in run-to-completion
        return false;
    }

    fn getStats(ptr: *anyopaque) SchedulerStats {
        const self: *Self = @ptrCast(@alignCast(ptr));

        return SchedulerStats{
            .total_threads = self.total_threads,
            .ready_threads = self.total_threads,
            .context_switches = self.context_switches,
            .scheduler_type = .RunToCompletion,
        };
    }

    fn reset(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        self.ready_queue = null;
        self.queue_tail = null;
        self.total_threads = 0;
        self.context_switches = 0;
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};
