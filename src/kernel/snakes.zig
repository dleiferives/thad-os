const std = @import("std");
const kernel = @import("kernel.zig");
const thread = @import("thread.zig");
const drivers = @import("drivers");

pub export fn kfree(addr: *allowzero anyopaque) callconv(.C) void {
    const mem: [*]u8 = @ptrCast(addr);
    const ptr: []u8 = mem[0..0];

    kernel.state.getKernelAllocator().?.free(ptr);
}
pub export fn kmalloc(size: usize) callconv(.C) *allowzero anyopaque {
    const allocator = kernel.state.getKernelAllocator().?;
    const ptr = allocator.alloc(u8, size) catch |err| {
        std.log.err("Failed to allocate {} bytes: {s}", .{ size, @errorName(err) });
        return @ptrFromInt(0);
    };
    return @ptrCast(ptr);
}

pub export fn yield() callconv(.C) void {
    thread.Thread.yield();
}

pub export fn VGA_clear() callconv(.C) void {
    drivers.vga.clear();
}

pub export fn VGA_row_count() callconv(.C) u32 {
    return @truncate(drivers.vga.HEIGHT);
}

pub export fn VGA_col_count() callconv(.C) u32 {
    return @truncate(drivers.vga.WIDTH);
}

pub export fn kexit() callconv(.C) void {
    thread.Thread.exit(0);
}

pub export fn VGA_display_attr_char(x: i32, y: i32, c: u8, fg: u32, bg: u32) callconv(.C) void {
    const xu: usize = @intCast(x);
    const yu: usize = @intCast(y);
    drivers.vga.setCell(xu, yu, c, @truncate(fg), @truncate(bg));
}

pub export fn PROC_create_kthread(entry_point: *const fn (*anyopaque) callconv(.C) void, arg: *allowzero anyopaque) i32 {
    const mt = thread.Thread.create(
        @ptrCast(entry_point),
        @ptrCast(arg),
        true, // kernel thread
        kernel.state.mem_manager.mapper.?,
        kernel.state.getKernelAllocator().?,
        false, // not the main thread
        .NORMAL,
        true,
    ) catch |err| {
        std.log.err("Failed to create kernel thread: {s}", .{@errorName(err)});
        return 0;
    };

    // now we have a thread, we can add it to the kernel's thread list
    kernel.state.scheduler.?.addThread(mt) catch |err| {
        std.log.err("Failed to add thread to scheduler: {s}", .{@errorName(err)});
        return 0;
    };

    return @truncate(@as(i64, @intCast(mt.tid)));
}

pub export fn PROC_get_current_pid() callconv(.C) u64 {
    return kernel.state.scheduler.?.current_thread.?.tid;
}

pub const Proccess = extern struct {
    pid: u64,
};

pub const csnakes = struct {
    pub extern fn setup_snakes(hungry: i32) callconv(.C) void;
    pub extern fn kill_snake() callconv(.C) void;
    pub extern fn snakes_running() callconv(.C) i32;
};
