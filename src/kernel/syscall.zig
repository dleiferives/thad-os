const std = @import("std");
const thread = @import("thread.zig");
const arch = @import("arch");
const kernel = @import("kernel.zig");
const drivers = @import("drivers"); // Import drivers
const elf_loader = @import("elf_loader.zig");

// TODO @(dleiferives,6675cb9a-96bb-4de7-944b-60fcc32464da): add multi arguement
// syscalls! ~#
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
    PUTC = 5,
    GETC = 6,
    EXEC = 7,
    FORK = 8,
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
        .PUTC => {
            handlePutc(frame);
        },
        .GETC => {
            handleGetc(frame);
        },
        .EXEC => {
            handleExec(frame);
        },
        .FORK => {
            handleFork(frame);
        },
        .INVALID => {
            frame.rax = @intFromError(SyscallError.InvalidSyscall);
        },
    }
}

fn handlePutc(frame: *arch.irq.InterruptFrame) void {
    const char_to_print = @as(u8, @truncate(frame.rdi));
    kernel.kputc(char_to_print);
    std.log.debug("Putc syscall invoked with char: {}", .{char_to_print});
    frame.rax = char_to_print;
}

fn handleGetc(frame: *arch.irq.InterruptFrame) void {
    // This blocks...
    const char_read = drivers.keyboard.KeyboardBuffer.getc();
    std.log.debug("Getc syscall invoked, read char: {}", .{char_read});
    frame.rax = char_read;
}

const yield_log = std.log.scoped(.thread_yield);

fn handleThreadYield(frame: *arch.irq.InterruptFrame) void {
    // _ = frame;
    yield_log.debug("Thread yield syscall invoked", .{});
    if (kernel.state.scheduler) |*scheduler| {
        const stats = scheduler.getStats();
        const thread_count = stats.total_threads;
        yield_log.info("Yielding thread, total threads: {}", .{thread_count});
        if (thread_count > 1) {
            const current_thread = scheduler.current_thread;
            const next_thread = scheduler.selectNext() orelse {
                yield_log.err("No next thread to switch to", .{});
                return;
            };
            if (current_thread == null) {
                yield_log.err("No current thread to yield", .{});
            } else {
                // current_thread.?.context = frame.toThreadContext();
            }
            yield_log.info("Switching from thread {} to thread {}", .{ if (current_thread) |t| t.tid else 9999, next_thread.tid });
            // Do the context switch
            scheduler.current_thread = next_thread;
            thread.switchContext(current_thread, next_thread, frame);
        } else if (thread_count == 1) {
            if (stats.context_switches == 0) {
                // this is a unique case where we have only one thread running
                // we just need to switch to the next thread
                const next_thread = scheduler.selectNext() orelse {
                    yield_log.err("No next thread to switch to", .{});
                    return;
                };
                scheduler.current_thread = next_thread;
                thread.setCurrentThread(next_thread);
                thread.loadContext(&next_thread.context);
            }
            yield_log.debug("Only one thread running, yielding does nothing", .{});
            const next = scheduler.selectNext() orelse {
                yield_log.err("No current thread to yield", .{});
                return;
            };
            const current_thread = thread.getCurrentThread() orelse {
                yield_log.err("No current thread to yield", .{});
                return;
            };
            if (current_thread != next) {
                scheduler.current_thread = next;
                thread.switchContext(current_thread, next, frame);
            } else {
                thread.saveInterruptedContext(current_thread, frame);
                thread.loadContext(&current_thread.context);
            }
        }
    } else {
        yield_log.warn("No scheduler available, yielding does nothing", .{});
    }
}

// TODO @(dleiferives,613266f7-fffa-4d34-8b5d-da31ab0ae34c): Make scheduler hold
// dead threads to cleanup ~#
fn handleThreadExit(frame: *arch.irq.InterruptFrame) void {
    const exit_code = frame.rdi;

    if (kernel.state.scheduler) |*sched| {
        if (sched.current_thread) |cthread| {
            if (cthread.is_start) {
                std.log.info("Cannot exit the starting thread, exiting with code: {}", .{exit_code});
                frame.rax = @intFromError(SyscallError.InvalidArgument);
                @panic("Cannot exit the starting thread");
            } else {
                sched.removeThread(cthread) catch |err| {
                    std.log.err("Failed to remove thread {}: {}", .{ cthread.tid, err });
                    frame.rax = @intFromError(SyscallError.ResourceUnavailable);
                    return;
                };
                cthread.exit_code = @truncate(@as(i64, @intCast(exit_code)));
                const next = sched.selectNext() orelse {
                    std.log.err("No next thread to switch to, returning with code: {}", .{exit_code});
                    frame.rax = @intFromError(SyscallError.ResourceUnavailable);
                    return;
                };
                sched.current_thread = next;
                thread.setCurrentThread(next);
                next.state = .RUNNING;
                thread.loadContext(&next.context);
            }
        } else {
            // There is no current thread, just return
            std.log.err("No current thread to exit from, returning with code: {}", .{exit_code});
            frame.rax = @intFromError(SyscallError.InvalidArgument);
            const next = sched.selectNext() orelse {
                // std.log.err("No next thread to switch to, returning with code: {}", .{exit_code});
                frame.rax = @intFromError(SyscallError.ResourceUnavailable);
                return;
            };
            sched.current_thread = next;
            thread.setCurrentThread(next);
            next.state = .RUNNING;
            thread.loadContext(&next.context);
            return;
        }
    } else {
        // std.log.err("No scheduler available, cannot exit thread", .{});
        frame.rax = @intFromError(SyscallError.ResourceUnavailable);
        return;
    }
}

fn handleThreadCreate(frame: *arch.irq.InterruptFrame) void {
    const entry_fn = @as(*const fn (*anyopaque) callconv(.C) i32, @ptrFromInt(frame.rdi));
    const arg = @as(?*anyopaque, @ptrFromInt(frame.rsi));

    if (thread.getCurrentThread()) |current| {
        // Only allow kernel threads to create other kernel threads
        // User threads can only create user threads
        const new_thread = thread.Thread.create(
            entry_fn,
            arg,
            current.is_kernel,
            current.mapper, // Share address space for now... should like fix this
            current.owning_allocator,
            false,
            .NORMAL,
            true,
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
    @panic("Thread join syscall not implemented yet");
}

fn handleExec(frame: *arch.irq.InterruptFrame) void {
    const path_ptr = frame.rdi;
    const args_ptr = frame.rsi;
    _ = args_ptr;

    const path = std.mem.span(@as([*:0]const u8, @ptrFromInt(path_ptr)));

    elf_loader.loadAndRunProgram(path, null, false) catch |err| {
        std.log.err("Exec failed: {}", .{err});
        frame.rax = @intFromError(err);
        return;
    };

    // If successful, this should not return
    frame.rax = 0;
}

fn handleFork(frame: *arch.irq.InterruptFrame) void {
    // TODO: Implement fork() - create copy of current process
    _ = frame;
    @panic("fork syscall not implemented yet");
}
