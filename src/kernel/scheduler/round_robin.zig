const std = @import("std");
const Scheduler = @import("../scheduler.zig");
const Thread = @import("../thread.zig");
const Self = @This();

current_thread: ?*Thread,
thread_list: Thread.Queue(*Thread),
calling_thread: *Thread, // the thread that called the scheduler functions


pub fn create(allocator: std.mem.Allocator, calling_thread: *Thread) !*Self{
    const result = allocator.create(Self);
    result.* = Self{
        .current_thread = null,
        .calling_thread = calling_thread,
        .thread_list = Thread.Queue(*Thread),
    };
    return result;
}

pub fn scheduler(self: *Self) !Scheduler{
    return .{
        .ptr = self,
        .calling_thread = self.calling_thread,
        .current_thread = self.current_thread,
        .VTable = .{
            .schedule = schedule,
            .next_thread = next_thread,
            .remove_thread = remove_thread,
            .current_thread = get_current_thread,
        },
    };
}

pub fn schedule(self_: *anyopaque, thread: *Thread, allocator: std.mem.Allocator) Scheduler.SchedulerError!void{
    const self: *Self = @ptrCast(self_);
    try self.thread_list.enqueue(thread, allocator);
}


pub fn next_thread (self_: *anyopaque, allocator: std.mem.Allocator) Scheduler.SchedulerError!void{
    _ = self_;
    _ = allocator; // Unused for now, but may be used later
}


pub fn get_current_thread (self_: *anyopaque) ?*Thread{
    const self: *Self = @ptrCast(self_);
    return self.current_thread;
}


pub fn remove_thread (self_: *anyopaque, allocator: std.mem.Allocator, thread: *Thread) Scheduler.SchedulerError!void{
    const self: *Self = @ptrCast(self_);
    if (thread.tid == 0) {
        return Scheduler.SchedulerError.CannotRemoveKernelThread;
    }
    if (thread.tid == self.calling_thread.tid) {
        return Scheduler.SchedulerError.CannotRemoveCallingThread;
    }

    const iterator = self.thread_list.toIterator();
    while(iterator.next()) |t| {
        if (t.tid == thread.tid) {
            try self.thread_list.remove(t, allocator);
            return;
        }
    }
}


// self: ourselves
// allocator: the allocator that allocated us in create
pub fn destroy (self: *Self, allocator: std.mem.Allocator) !void{
    while(self.thread_list.dequeue(allocator)) {}
    try allocator.destroy(self);
}
