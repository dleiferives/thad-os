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
    ready_queue: std.ArrayListUnmanaged(*Thread),
    context_switches: u64,
    allocator: std.mem.Allocator,
    current_thread: ?*Thread = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .ready_queue = .{}, // Initialize an empty list
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

    fn addThread(ptr: *anyopaque, thread: *Thread) SchedulerError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Add to end of queue (FIFO) by appending to the list.
        // We catch and map the potential allocation error.
        try self.ready_queue.append(self.allocator, thread);

        thread.state = .READY;
        thread.remaining_time = std.math.maxInt(u32); // Infinite time slice
    }

    fn removeThread(ptr: *anyopaque, thread: *Thread) SchedulerError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // To remove a thread, we must find it in the list first.
        // This is an O(n) operation, a trade-off for a non-intrusive list.
        for (self.ready_queue.items, 0..) |t, i| {
            if (t == thread) {
                _ = self.ready_queue.orderedRemove(i);
                return; // Thread found and removed.
            }
        }
    }

    fn selectNext(ptr: *anyopaque) ?*Thread {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // If the queue is empty, there's no thread to select.
        if (self.ready_queue.items.len == 0) {
            return null;
        }

        // Remove from the front of the queue (FIFO).
        var thread = self.ready_queue.items[0];
        if(self.ready_queue.items.len > 1) {
            if (thread.is_start) {
                // If the thread is a start thread, we remove it from the queue.
                _ = self.ready_queue.orderedRemove(0);
                // then we put it back to the end of the queue.
                self.ready_queue.append(self.allocator, thread) catch {
                    @panic("Failed to re-add start thread to the queue");
                };
                thread = self.ready_queue.items[0];
            }
        }
        thread.state = .RUNNING;
        thread.remaining_time = std.math.maxInt(u32);
        self.context_switches += 1;

        return thread;
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
        const thread_count:u32 = @intCast(self.ready_queue.items.len);

        return SchedulerStats{
            .total_threads = thread_count,
            .ready_threads = thread_count, // In RTC, all threads are ready
            .context_switches = self.context_switches,
            .scheduler_type = .RunToCompletion,
        };
    }

    fn reset(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        // Clear the list and free its associated memory.
        self.ready_queue.clearAndFree(self.allocator);
        self.context_switches = 0;
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Deinitialize the internal list first to prevent memory leaks.
        self.ready_queue.deinit(self.allocator);
        allocator.destroy(self);
    }
};
