// src/kernel/syscall.zig
const std = @import("std");
const thread = @import("thread.zig");
const arch = @import("arch");
const kernel = @import("kernel.zig");

pub const SyscallError = error{
    InvalidSyscall,
    InvalidArgument,
    PermissionDenied,
    ResourceUnavailable,
};

pub const SyscallNumber = enum(u64) {
    INVALID = 0,
    THREAD_YIELD = 1,
    THREAD_EXIT = 2,
    THREAD_CREATE = 3,
    THREAD_JOIN = 4,
};

pub fn handleSyscall(frame: *arch.irq.InterruptFrame) void {
    const syscall_num = @as(SyscallNumber, @enumFromInt(frame.rax));

    switch (syscall_num) {
        .THREAD_YIELD => {
            handleThreadYield(frame);
        },
        .THREAD_EXIT => {
            handleThreadExit(frame);
        },
        .THREAD_CREATE => {
            handleThreadCreate(frame);
        },
        .THREAD_JOIN => {
            handleThreadJoin(frame);
        },
        .INVALID => {
            frame.rax = @intFromError(SyscallError.InvalidSyscall);
        },
    }
}

fn handleThreadYield(frame: *arch.irq.InterruptFrame) void {
    // _ = frame;
    std.log.debug("Thread yield syscall invoked", .{});
    if (kernel.state.scheduler) |*scheduler| {
        const thread_count = scheduler.getStats().total_threads;
        std.log.info("Yielding thread, total threads: {}", .{thread_count});
        if (thread_count > 1){
            const current_thread = scheduler.current_thread;
            const next_thread = scheduler.selectNext() orelse {
                std.log.err("No next thread to switch to", .{});
                return;
            };
            if (current_thread == null){
                std.log.err("No current thread to yield", .{});

            }else{
                // current_thread.?.context = frame.toThreadContext();
            }
            std.log.info("Switching from thread {} to thread {}", .{if (current_thread) |t| t.tid else 9999, next_thread.tid});
            // Do the context switch
            scheduler.current_thread = next_thread;
            thread.switchContext(current_thread, next_thread, frame);
        } else if (thread_count == 1) {
            std.log.err("Only one thread running, yielding does nothing", .{});
            scheduler.current_thread = scheduler.selectNext() orelse {
                std.log.err("No current thread to yield", .{});
                return;
            };
        }
    } else {
        std.log.err("No scheduler available, yielding does nothing", .{});
    }
    // if (thread.getCurrentThread()) |current| {
    //     // Force a reschedule
    //     current.remaining_time = 0;
    //     if (thread.schedule()) |next_thread| {
    //         if (next_thread != current) {
    //             thread.switchContext(current, next_thread);
    //         }
    //     }
    // }
}

fn handleThreadExit(frame: *arch.irq.InterruptFrame) void {
    const exit_code = frame.rdi;

    std.log.debug("Thread exit syscall invoked with code: {}", .{exit_code});
    // if (thread.getCurrentThread()) |current| {
    //     current.exit_code = exit_code;
    //     current.state = .ZOMBIE;
    //     thread.addToZombieList(current);

    //     // Trigger cleanup
    //     thread.triggerCleanup();

    //     // Schedule next thread
    //     if (thread.schedule()) |next_thread| {
    //         thread.switchContext(current, next_thread);
    //     } else {
    //         // No threads to run, halt
    //         arch.cpu.halt();
    //     }
    // }
}

fn handleThreadCreate(frame: *arch.irq.InterruptFrame) void {
    const entry_fn = @as(*const fn(*anyopaque) callconv(.C) i32, @ptrFromInt(frame.rdi));
    const arg = @as(?*anyopaque, @ptrFromInt(frame.rsi));

    if (thread.getCurrentThread()) |current| {
        // Only allow kernel threads to create other kernel threads
        // User threads can only create user threads
        const new_thread = thread.Thread.create(
            entry_fn,
            arg,
            current.is_kernel,
            current.mapper, // Share address space for now
            current.owning_allocator,
            false,
            .NORMAL,
        ) catch {
            frame.rax = 0;
            return;
        };

        frame.rax = new_thread.tid;
    } else {
        frame.rax = 0;
    }
}

fn handleThreadJoin(frame: *arch.irq.InterruptFrame) void {
    const tid = frame.rdi;
    std.log.debug("Thread join syscall invoked for TID: {}", .{tid});
    // if (thread.getThreadByTid(tid)) |target_thread| {
    //     // Block current thread until target exits
    //     if (thread.getCurrentThread()) |current| {
    //         current.state = .BLOCKED;

    //         // Simple spin wait for now - in a real kernel you'd use a wait queue
    //         while (target_thread.state != .ZOMBIE and target_thread.state != .DEAD) {
    //             if (thread.schedule()) |next_thread| {
    //                 thread.switchContext(current, next_thread);
    //             }
    //         }

    //         frame.rax = @as(u64, @intCast(target_thread.exit_code orelse 0));
    //     }
    // } else {
    //     frame.rax = @as(u64, @intCast(@as(u32,@bitCast(@as(i32, -1))))); // Thread not found
    // }
}
