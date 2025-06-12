// src/kernel/thread.zig
const std = @import("std");
const mem = @import("mem.zig");
const arch = @import("arch");
const Self = @This();
const log = std.log.scoped(.kernel_thread);
const vfs = @import("vfs.zig");
const syscall = @import("syscall.zig");

pub const NUM_THREADS = 512;
pub const THREAD_CLEANUP_VECTOR = 129; // Dedicated interrupt for thread cleanup

// Thread states
pub const ThreadState = enum {
    READY, // Ready to run
    RUNNING, // Currently executing
    ZOMBIE, // Terminated but not cleaned up
    DEAD, // Completely cleaned up
    BLOCKED_IO,
    BLOCKED_MUTEX,
    BLOCKED_KEYBOARD,
    BLOCKED_GENERAL,
};

// Thread priorities
pub const Priority = enum(u8) {
    IDLE = 0,
    LOW = 1,
    NORMAL = 2,
    HIGH = 3,
    KERNEL = 4,
};

// TODO @(dleiferives,a798b266-084e-4cac-939c-7d6721f270af): should be set in arch
// or something like that... ~#
pub const ThreadContext = extern struct {
    // General purpose registers
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    rsp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,

    // Segment registers
    cs: u64,
    ds: u64,
    es: u64,
    fs: u64,
    gs: u64,
    ss: u64,

    // Control registers
    rip: u64,
    rflags: u64,

    // FPU/SSE state pointer (allocated separately)
    fpu_state: [512]u8,

    pub fn log(self: *@This()) void {
        std.log.info("rax 0x{X:0>16}",.{self.rax});
        std.log.info("rbx 0x{X:0>16}",.{self.rbx});
        std.log.info("rcx 0x{X:0>16}",.{self.rcx});
        std.log.info("rdx 0x{X:0>16}",.{self.rdx});
        std.log.info("rsi 0x{X:0>16}",.{self.rsi});
        std.log.info("rdi 0x{X:0>16}",.{self.rdi});
        std.log.info("rbp 0x{X:0>16}",.{self.rbp});
        std.log.info("rsp 0x{X:0>16}",.{self.rsp});
        std.log.info("rip 0x{X:0>16}",.{self.rip});
    }
};

pub const Thread = struct {
    tid: u64,
    state: ThreadState,
    priority: Priority,

    // Memory management
    kernel_stack: []u8,
    user_stack: ?[]u8,
    mapper: *mem.Mapper,

    // Context
    context: ThreadContext,
    is_kernel: bool,
    is_start: bool,

    // Scheduling
    time_slice: u32,
    remaining_time: u32,

    // Lifecycle
    parent_tid: ?u64,
    exit_code: ?i32,
    owning_allocator: std.mem.Allocator,
    creating_thread: bool = false,
    creating_thread_mapper: *mem.Mapper = undefined,

    // Entry point for user threads
    entry_point: ?*const fn (*anyopaque) callconv(.C) i32,
    entry_arg: ?*anyopaque,

    // Linked list pointers for scheduling blocks
    next_blocked: ?*Thread = null,
    prev_blocked: ?*Thread = null,

    // File system
    fd_table: vfs.FdTable,

    const ThreadError = error{
        ThreadingNotInitialized,
        OutOfMemory,
        InvalidThreadId,
        MainThreadAlreadyExists,
        MainThreadNotKernel,
        ThreadTableFull,
        InvalidState,
        PermissionDenied,
    };

    pub fn init(allocator: std.mem.Allocator) !void {
        if (initialized) return;

        // Initialize thread table
        for (0..NUM_THREADS) |i| {
            thread_table[i] = null;
        }

        // Initialize lists
        ready_list = null;
        zombie_list = null;

        log.info("trying to create a cleanup Thread",.{});
        // Create cleanup thread
        try createCleanupThread(allocator);
        log.info("Created a cleanup Thread",.{});

        initialized = true;
    }

    pub fn create(
        entry_fn: ?*const fn (*anyopaque) callconv(.C) i32,
        arg: ?*anyopaque,
        is_kernel: bool,
        mapper: *mem.Mapper,
        allocator: std.mem.Allocator,
        is_main: bool,
        priority: Priority,
        create_stack: bool,
    ) !*Thread {
        const thread = try allocator.create(Thread);
        errdefer allocator.destroy(thread);

        // Find free slot
        const slot = if (is_main) 0 else findFreeSlot() orelse return ThreadError.ThreadTableFull;

        log.info("creating a thread",.{});
        thread.* = Thread{
            .tid = if (is_main) 0 else getNextTid(),
            .state = .READY,
            .priority = priority,
            .kernel_stack = undefined,
            .user_stack = null,
            .mapper = mapper,
            .context = std.mem.zeroes(ThreadContext),
            .is_kernel = is_kernel,
            .is_start = is_main,
            .time_slice = getTimeSlice(priority),
            .remaining_time = 0,
            .parent_tid = if (current_thread) |ct| ct.tid else null,
            .exit_code = null,
            .owning_allocator = allocator,
            .entry_point = entry_fn,
            .entry_arg = arg,
            .fd_table = vfs.FdTable.init(allocator),
        };

        // Allocate kernel stack
        if (create_stack) {
            try allocateKernelStack(thread, slot);
            log.info("allocated kernel stack",.{});
        } else {
            log.info("not allocating kernel stack",.{});
        }
        // note that we will be moving off the boot stack for the main thread
        // at this point!


        // Allocate user stack if needed
        if (!is_kernel) {
            log.info("allocating user stack",.{});
            try allocateUserStack(thread);
        }

        // Set up initial context
        log.info("setting up context",.{});
        if(!is_main){
            try setupInitialContext(thread);
        } else {
            try setupInitialContext(thread);
        }
        log.info("setup context",.{});

        // Add to thread table
        thread_table[slot] = thread;

        return thread;
    }

    pub fn yield() void {
        asm volatile ("int $128"
            :
            : [syscall] "{rax}" (@as(u64, 1)),
            : "memory"
        );
    }

    pub fn exit(exit_code: i32) noreturn {
        asm volatile ("int $128"
            :
            : [syscall] "{rax}" (@as(u64, 2)),
              [code] "{rdi}" (exit_code),
            : "memory", "rdi", "rax"
        );
        unreachable;
    }

    pub fn createUserThread(entry: *const fn (*anyopaque) callconv(.C) void, arg: ?*anyopaque) !u64 {
        return asm volatile ("int $128"
            : [ret] "={rax}" (-> u64),
            : [syscall] "{rax}" (@as(u64, 3)),
              [entry] "{rdi}" (entry),
              [arg] "{rsi}" (arg),
            : "memory"
        );
    }

    pub fn join(tid: u64) !i32 {
        return asm volatile ("int $128"
            : [ret] "={rax}" (-> i32),
            : [syscall] "{rax}" (@as(u64, 4)),
              [tid] "{rdi}" (tid),
            : "memory"
        );
    }

        pub fn putc(char: u8) void {
            asm volatile ("int $128"
                :
                : [syscall] "{rax}" (@as(u64, @intFromEnum(syscall.SyscallNumber.PUTC))),
                [arg1] "{rdi}" (char),
                : "memory", "rax", "rdi"
            );
        }

        pub fn getc() u8 {
            return asm volatile ("int $128"
                : [ret] "={rax}" (-> u8),
                : [syscall] "{rax}" (@as(u64, @intFromEnum(syscall.SyscallNumber.GETC))),
                : "memory", "rax"
            );
        }

    pub fn exec(path: []const u8) !void {
        return asm volatile ("int $128"
        :
        : [syscall] "{rax}" (@as(u64, @intFromEnum(syscall.SyscallNumber.EXEC))),
          [path] "{rdi}" (path.ptr),
          [args] "{rsi}" (@as(u64, 0)),
                         : "memory", "rax", "rdi", "rsi"
    );
}

    pub fn blockOn(queue: *@import("thread_queue.zig").ThreadQueue, enable_interrupts: bool) void {
        if (getCurrentThread()) |current| {
            arch.irq.irq.disable();
            current.state = .BLOCKED_GENERAL;
            queue.enqueue(current);

            // Remove from scheduler
            const kernel = @import("kernel.zig");
            if (kernel.state.scheduler) |sched| {
                sched.removeThread(current) catch {};
            }

            if (enable_interrupts) {
                arch.irq.irq.enable();
            }

            Thread.yield();
        }
    }
};

// Global state
pub var thread_table: [NUM_THREADS]?*Thread = undefined;
pub var initialized: bool = false;
pub var next_tid: u64 = 1;
pub var current_thread: ?*Thread = null;
pub var ready_list: ?*Thread = null;
pub var zombie_list: ?*Thread = null;
pub var cleanup_thread: ?*Thread = null;

// Cleanup thread stack
var cleanup_stack: [16 * 1024]u8 align(16) = undefined;

// Helper functions
inline fn getKernelStackSize() usize {
    return 1 + (mem.types.MEMORY_LAYOUT.KERNEL_VIRTUAL_STACKS_END -
        mem.types.MEMORY_LAYOUT.KERNEL_VIRTUAL_STACKS_START) / NUM_THREADS;
}

inline fn getNextTid() u64 {
    defer next_tid += 1;
    return next_tid;
}

fn findFreeSlot() ?usize {
    for (1..NUM_THREADS) |i| { // Skip 0, reserved for main thread
        if (thread_table[i] == null) return i;
    }
    return null;
}

fn getTimeSlice(priority: Priority) u32 {
    return switch (priority) {
        .IDLE => 10,
        .LOW => 20,
        .NORMAL => 50,
        .HIGH => 100,
        .KERNEL => 200,
    };
}

fn allocateKernelStack(thread: *Thread, slot: usize) !void {
    const stack_start = mem.types.MEMORY_LAYOUT.KERNEL_VIRTUAL_STACKS_START +
        (getKernelStackSize() * slot);
    const stack_size = getKernelStackSize();

    log.info("Creating kernel stack",.{});
    // Allocate virtual memory for kernel stack
    thread.mapper.mapRange(stack_start, stack_start + stack_size, mem.PageFlags{
        .present = true,
        .writable = true,
        .user_accessible = false,
        .demand_alloc = false,
    }) catch |err| {
        switch(err) {
            error.AlreadyMapped => {},
            else => {return err;}
        }
    };

    const ptr: [*]u8 = @ptrFromInt(stack_start);
    thread.kernel_stack = ptr[0..stack_size];
}

fn allocateUserStack(thread: *Thread) !void {
    const stack_size = 2 * 1024 * 1024; // 2MB user stack
    const stack_start = mem.types.MEMORY_LAYOUT.USER_VIRTUAL_STACK_INITIAL_START - stack_size;

    _ = try thread.mapper.mapDemandRange(
        stack_start,
        stack_size,
        mem.PageFlags{
            .present = true,
            .writable = true,
            .user_accessible = true,
            .execute_disable = true,
            .demand_alloc = true,
        },
    );

    // TODO @(dleiferives,ac1bd1ab-e711-429f-80e6-956a6830ad4c): this will break
    // ~#
    @panic("fix this user stack stuff");
    // const ptr: [*]u8 = @ptrFromInt(stack_start);
    // thread.user_stack = ptr[0..stack_size];
}

fn setupInitialContext(thread: *Thread) !void {
    // Set up stack pointers
    if (thread.is_kernel) {
        log.info("context is kernel",.{});
        // Kernel thread setup

        const stack_top = @intFromPtr(thread.kernel_stack.ptr) + thread.kernel_stack.len;
        if(stack_top <= 16) {
            std.log.err("Kernel stack too small, must be at least 16 bytes is {}", .{stack_top});
            @panic("Kernel stack too small, must be at least 16 bytes");
        }
        thread.context.rsp = (stack_top - 16) & ~@as(u64, 15);
        thread.context.cs = arch.cpu.gdt.SELECTOR.KERNEL_CODE;
        thread.context.ds = arch.cpu.gdt.SELECTOR.KERNEL_DATA;
        thread.context.ss = arch.cpu.gdt.SELECTOR.KERNEL_DATA;

        // If this has an entry point, set up a wrapper
        if (thread.entry_point) |entry| {

            log.info("setup entrypoint ",.{});
            thread.context.rip = @intFromPtr(&kernelThreadWrapper);
            // Push entry point and args onto stack for wrapper
            thread.context.rdi = @intFromPtr(entry);
            if(thread.entry_arg) |arg|{
                thread.context.rsi = @intFromPtr(arg);
            } else {
                thread.context.rsi = 0;
            }
            // log.info("accessintg stack {*}",.{stack_ptr});
            // stack_ptr[0] = @intFromPtr(entry);
            // log.info("wrote ",.{});
            // stack_ptr[1] = @intFromPtr(thread.entry_arg orelse @as(*allowzero anyopaque, @ptrFromInt(0)));
            // log.info("done stack",.{});
            // log.info("stack entry 0 {*} 1 {*}",.{&stack_ptr[0],&stack_ptr[1]});
            // thread.context.rsp -= 16; // Adjust for pushed values
        }

        log.info("end kernel specific ",.{});
    } else {
        log.info("context is user",.{});
        // User thread setup
        if (thread.user_stack) |stack| {
            const stack_top = @intFromPtr(stack.ptr) + stack.len;
            thread.context.rsp = stack_top - 16;
        }
        thread.context.cs = arch.cpu.gdt.SELECTOR.USER_CODE;
        thread.context.ds = arch.cpu.gdt.SELECTOR.USER_DATA;
        thread.context.ss = arch.cpu.gdt.SELECTOR.USER_DATA;

        if (thread.entry_point) |entry| {
            thread.context.rip = @intFromPtr(&userThreadWrapper);

            // Set up user stack with entry point
            const stack_ptr = @as([*]u64, @ptrFromInt(thread.context.rsp));
            stack_ptr[0] = @intFromPtr(entry);
            stack_ptr[1] = @intFromPtr(thread.entry_arg orelse @as(*allowzero anyopaque, @ptrFromInt(0)));
            thread.context.rsp -= 16;
        }
    }

    log.info("rflags setting fpu",.{});
    // Enable interrupts
    thread.context.rflags = 0x202; // IF flag set
}

// Thread wrapper functions
pub fn kernelThreadWrapper() callconv(.C) noreturn {
    // Get entry point and args from stack

    const entry_raw: u64= asm volatile ("mov %%rdi, %[rdi]" : [rdi] "={rax}" (-> u64));
    const arg_raw: u64= asm volatile ("mov %%rsi, %[rsi]" : [rsi] "={rax}" (-> u64));
    log.info("entry raw i 0x{X:0>16}",.{entry_raw});
    log.info("arg raw i 0x{X:0>16}",.{arg_raw});

    const entry_fn: *const fn (*allowzero anyopaque) callconv(.C) i32 = @ptrFromInt(entry_raw);
    const arg: *allowzero anyopaque = @ptrFromInt(arg_raw);
    // Call the actual thread function

    // Thread finished, exit
    Thread.exit(entry_fn(arg));
}

fn userThreadWrapper() callconv(.C) noreturn {
    // Similar to kernel wrapper but for user threads
    const rsp = asm volatile ("mov %%rsp, %[rsp]" : [rsp] "=r" (-> u64));
    const stack_ptr = @as([*]u64, @ptrFromInt(rsp));

    const entry_fn = @as(*const fn(*anyopaque) callconv(.C) void, @ptrFromInt(stack_ptr[2]));
    const arg = @as(*anyopaque, @ptrFromInt(stack_ptr[3]));

    // Call the actual thread function
    entry_fn(arg);

    // Thread finished, exit
    Thread.exit(0);
}


pub fn addToZombieList(thread: *Thread) void {
    thread.state = .ZOMBIE;
    thread.next = zombie_list;
    zombie_list = thread;
}

pub fn switchContext(from: ?*Thread, to: *Thread, frame: *arch.irq.InterruptFrame) void {
    log.debug("Context switch: {any} -> {any}", .{
        if (from) |f| f.tid else @as(u64, 0),
        to.tid
    });

    // Save current context if there is one
    if (from) |old_thread| {
        // Save current register state
        old_thread.context = frame.toThreadContext();
        // saveContext(&old_thread.context);
    }

    // Switch to new thread's address space if different
    if (from == null or from.?.mapper != to.mapper) {
        mem.Mapper.loadPML4(to.mapper.pml4_phys_addr);
    }

    // Update current thread pointer
    current_thread = to;
    to.state = .RUNNING;

    // Update TSS for kernel stack
    // arch.cpu.gdt.setKernelStack(@intFromPtr(to.kernel_stack.ptr) + to.kernel_stack.len);

    // Load new context and jump to thread
    log.debug("switching context!",.{});
    to.context.log();
    loadContext(&to.context);
}





// TODO @(dleiferives,ad3ea549-b9cc-4c76-923c-3a555961263f): should put these
// inside of arch ~#
// Context switching assembly functions
pub extern fn saveContext(ctx: *ThreadContext) void;
pub extern fn loadContext(ctx: *ThreadContext) noreturn;

// Cleanup thread
fn createCleanupThread(allocator_owner: std.mem.Allocator) !void {
    const allocator = allocator_owner;
    cleanup_thread = try allocator.create(Thread);

    cleanup_thread.?.* = Thread{
        .tid = 0xFFFFFFFFFFFFFFFF, // Special TID for cleanup thread
        .state = .READY,
        .priority = .KERNEL,
        .kernel_stack = cleanup_stack[0..],
        .user_stack = null,
        .mapper = undefined, // Will be set later
        .context = std.mem.zeroes(ThreadContext),
        .is_kernel = true,
        .time_slice = 1000,
        .remaining_time = 0,
        .parent_tid = null,
        .exit_code = null,
        .owning_allocator = allocator,
        .entry_point = null,
        .entry_arg = null,
        .next = null,
        .prev = null,
    };

    // Set up cleanup thread context
    cleanup_thread.?.context.rsp = @intFromPtr(&cleanup_stack) + cleanup_stack.len - 16;
    cleanup_thread.?.context.rip = @intFromPtr(&cleanupThreadEntry);
    cleanup_thread.?.context.cs = arch.cpu.gdt.SELECTOR.KERNEL_CODE;
    cleanup_thread.?.context.ds = arch.cpu.gdt.SELECTOR.KERNEL_DATA;
    cleanup_thread.?.context.ss = arch.cpu.gdt.SELECTOR.KERNEL_DATA;
    cleanup_thread.?.context.rflags = 0x202;
}

fn cleanupThreadEntry() callconv(.C) noreturn {
    while (true) {
        // Process zombie list
        while (zombie_list) |zombie| {
            zombie_list = zombie.next;
            cleanupThread(zombie);
        }

        // Sleep until needed
        asm volatile ("hlt");
    }
}

fn cleanupThread(thread: *Thread) void {

    // Get ride of file descriptors
    thread.fd_table.deinit();

    // Free user stack if exists
    if (thread.user_stack) |stack| {
        const start = @intFromPtr(stack.ptr);
        const end = start + stack.len;
        thread.mapper.unmapAndFreeRangeFull(start, end) catch {};
    }

    // Free kernel stack
    const start = @intFromPtr(thread.kernel_stack.ptr);
    const end = start + thread.kernel_stack.len;
    thread.mapper.unmapAndFreeRangeFull(start, end) catch {};

    // Free FPU state
    if (thread.context.fpu_state) |fpu| {
        thread.owning_allocator.destroy(fpu);
    }

    // Remove from thread table
    for (thread_table, 0..) |entry, i| {
        if (entry == thread) {
            thread_table[i] = null;
            break;
        }
    }

    // Free thread structure
    thread.owning_allocator.destroy(thread);
}

pub fn triggerCleanup() void {
    // Trigger cleanup interrupt
    asm volatile ("int $129");
}

// Public interface
pub fn setCurrentThread(t: *Thread) void {
    current_thread = t;
}

pub fn getCurrentThread() ?*Thread {
    return current_thread;
}


pub fn getThreadByTid(tid: u64) ?*Thread {
    for (thread_table) |entry| {
        if (entry) |thread| {
            if (thread.tid == tid) return thread;
        }
    }
    return null;
}
