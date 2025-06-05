// src/kernel/scheduler.zig
const std = @import("std");
const thread_s = @import("thread.zig");
const Thread = thread_s.Thread;
pub const RoundRobinScheduler = @import("scheduler/round_robin.zig").RoundRobinScheduler;
pub const RunToCompletionScheduler = @import("scheduler/run_to_completion.zig").RunToCompletionScheduler;
pub const TimeSharingScheduler= @import("scheduler/time_sharing.zig").TimeSharingScheduler;


pub const SchedulerError = error{
    NoThreadsReady,
    InvalidThread,
    OutOfMemory,
    ThreadNotFound,
};

pub const SchedulerType = enum {
    RoundRobin,
    RunToCompletion,
    TimeSharing,
    Priority,
};

pub const SchedulerVTable = struct {
    /// Add a thread to the scheduler
    addThread: *const fn (self: *anyopaque, thread: *Thread) SchedulerError!void,

    /// Remove a thread from the scheduler
    removeThread: *const fn (self: *anyopaque, thread: *Thread) SchedulerError!void,

    /// Select the next thread to run
    selectNext: *const fn (self: *anyopaque) ?*Thread,

    /// Handle timer tick (for preemptive schedulers)
    timerTick: *const fn (self: *anyopaque, current_thread: ?*Thread) bool,

    /// Check if current thread should be preempted
    shouldPreempt: *const fn (self: *anyopaque, current_thread: *Thread) bool,

    /// Get scheduler statistics
    getStats: *const fn (self: *anyopaque) SchedulerStats,

    /// Reset scheduler state
    reset: *const fn (self: *anyopaque) void,

    /// Cleanup scheduler resources
    deinit: *const fn (self: *anyopaque, allocator: std.mem.Allocator) void,
};

pub const SchedulerStats = struct {
    total_threads: u32,
    ready_threads: u32,
    context_switches: u64,
    scheduler_type: SchedulerType,
};

pub const Scheduler = struct {
    ptr: *anyopaque,
    vtable: *const SchedulerVTable,
    scheduler_type: SchedulerType,
    current_thread: ?*Thread,

    pub fn addThread(self: *const Scheduler, thread: *Thread) SchedulerError!void {
        return self.vtable.addThread(self.ptr, thread);
    }

    pub fn removeThread(self: *const Scheduler, thread: *Thread) SchedulerError!void {
        return self.vtable.removeThread(self.ptr, thread);
    }

    pub fn selectNext(self: *const Scheduler) ?*Thread {
        return self.vtable.selectNext(self.ptr);
    }

    pub fn timerTick(self: *const Scheduler, current_thread: ?*Thread) bool {
        return self.vtable.timerTick(self.ptr, current_thread);
    }

    pub fn shouldPreempt(self: *const Scheduler, current_thread: *Thread) bool {
        return self.vtable.shouldPreempt(self.ptr, current_thread);
    }

    pub fn getStats(self: *const Scheduler) SchedulerStats {
        return self.vtable.getStats(self.ptr);
    }

    pub fn reset(self: *Scheduler) void {
        self.vtable.reset(self.ptr);
    }

    pub fn deinit(self: *Scheduler, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

pub fn swapScheduler(
    allocator: std.mem.Allocator,
    old_scheduler: *Scheduler,
    new_scheduler: SchedulerType,
) !Scheduler {
    const scheduler = switch (new_scheduler) {
        .RoundRobin => (try RoundRobinScheduler.init(allocator, 100)).scheduler(),
        .RunToCompletion => (try RunToCompletionScheduler.init(allocator)).scheduler(),
        .TimeSharing => (try TimeSharingScheduler.init(allocator,100)).scheduler(),
        else => return error.InvalidThread,
    };
    while (old_scheduler.selectNext()) |thread| {
        std.log.debug("Migrating thread {}", .{thread.tid});
        try scheduler.addThread(thread);
        std.log.debug("number of threads is now {}",.{scheduler.getStats().total_threads});
        try old_scheduler.removeThread(thread);
    }
    old_scheduler.deinit(allocator);
    return scheduler;
}
