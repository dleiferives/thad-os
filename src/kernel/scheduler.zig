// this file is the "Scheduler" struct in zig. consider it as such
const std = @import("std");
const thread = @import("thread.zig");
const mem = @import("mem.zig");
const Self = @This();



/// The type erased pointer to the allocator implementation.
///
/// Any comparison of this field may result in illegal behavior, since it may
/// be set to `undefined` in cases where the allocator implementation does not
/// have any associated state.
ptr: *anyopaque,
vtable: *const VTable,
current_thread: ?*thread,
calling_thread: *thread, // the thread that called the scheduler functions

pub const SchedulerError = error {
    NotInitialized,
    OutOfMemory,
    InvalidThreadId,
    ThreadTableFull,
    ThreadNotFound,
    ThreadAlreadyExists,
    SchedulerNotKernel,
    CannotRemoveKernelThread,
    CannotRemoveCallingThread,
    ThreadNotInScheduler,
} || std.mem.Allocator.Error;


pub const VTable = struct {

    // Schedules a thread to run
    schedule: fn (*anyopaque, thread: *thread, allocator: *std.mem.Allocator) SchedulerError!void,

    // Next thread to run.
    next_thread: fn (*anyopaque, allocator: *std.mem.Allocator) SchedulerError!*thread.Thread,

    // Removes a thread from the scheduler.
    remove_thread: fn (*anyopaque, allocator: *std.mem.Allocator, thread: *thread) SchedulerError!void,

    current_thread: fn (*anyopaque) ?*thread,

};
