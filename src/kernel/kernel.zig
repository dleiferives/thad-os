const std = @import("std");
const drivers = @import("drivers");
const mem = @import("mem.zig");
const multiboot = @import("multiboot.zig");
const arch = @import("arch");
const config = @import("config");
pub const thread = @import("thread.zig");
pub const syscall = @import("syscall.zig");
const scheduler = @import("scheduler.zig");
const snakes = @import("snakes.zig");

const log = std.log.scoped(.kernel);

comptime {
    _ = mem.memset;
    _ = mem.memcpy;

    // early setting the container allocator to be linked to the kernel
    _ = mem.Manager;
    _ = snakes.kfree;
    _ = snakes.kmalloc;
    _ = snakes.VGA_clear;
    _ = snakes.VGA_row_count;
    _ = snakes.VGA_col_count;
    _ = snakes.kexit;
    _ = snakes.VGA_display_attr_char;
    _ = snakes.PROC_create_kthread;
}

pub var log_level: std.log.Level = std.log.Level.err;

/// The 64 bit kernel's entry point
/// Really just calls panic if the true main loop fails!
pub export fn kmain() callconv(.C) void {
    main() catch |err| {
        log.err("Kernel main failed: {}", .{err});
        panic("Kernel main failed", null, null);
    };
}


/// The main function of the kernel
/// Sets up base drivers, memory management, then initiates threading.
pub fn main() !void {
    allowed_scopes = ALL_SCOPES[0..];
    // enable testing
    {
        state.testing.vga = config.test_vga;
        state.testing.page_bitfield = config.test_pagebitfield;
        state.testing.mapper = config.test_mapper;
        state.testing.map_dispatch = config.test_map_dispatch;
        state.testing.allocator = config.test_allocator;
        state.testing.threading_increment = config.test_threading_increment;
        state.testing.threading_snakes = config.test_threading_snakes;
        state.testing.threading_snakes_hungry = config.test_threading_snakes_hungry;
        state.testing.change_scheduler = config.test_change_scheduler;
    }

    try state.mem_layout_init();
    arch.cpu.gdt.init();

    // Initialize interrupt system
    try arch.irq.irq.init();
    arch.irq.irq.enable();
    // Initilize the VGA driver
    state.vga_init(0xb8000);


    // Initialize the serial driver
    state.serial_log_init(drivers.serial_log.DEFAULT_BAUDRATE, .COM1);

    // Initilize the memory manager
    try state.mem_manager_init();
    if (state.testing.mapper) {
        try state.mem_manager.test_mapper(0xFFFFFF8010000000);
    }
    // state.options.polling_keyboard =true;
    // try arch.cpu.gdt.tester();

    var ps2_ctrl = try drivers.ps2.Ps2Controller.init();
    log.info("--- PS/2 Controller Initialized ---\n", .{});

    // Initialize the Keyboard Manager with the PS/2 Controller
    var kbd_manager = try drivers.keyboard.KeyboardManager.init(&ps2_ctrl);
    log.info("--- Keyboard Manager Initialized ---\n", .{});

    if (kbd_manager.keyboard1 == null and kbd_manager.keyboard2 == null) {
        log.info("No keyboards detected. Exiting.\n", .{});
        return;
    }


    if (state.options.polling_keyboard) {
        log.info("Starting keyboard input polling. Press keys to see them on screen. (Ctrl+C won't work here!)\n", .{});
        while (true) {
            kbd_manager.pollAndProcessInput();

            // Add a small delay to prevent hogging CPU in a polling loop
            var i: u32 = 0;
            while (i < 500) : (i += 1) {
                asm volatile ("" ::: "memory");
            }
        }
    }
    try drivers.keyboard.setup_irq(&ps2_ctrl, &kbd_manager);


    // Initialize kernel heap
    try state.initKernelHeap();

    // // Now you can use the allocator
    if (state.testing.allocator) {
        if (state.getKernelAllocator()) |alloc| {
            const pre_pages = state.mem_manager.page_bitfield.getFreePages();
            {
                const test_data = try alloc.alloc(u8, 1024);
                defer alloc.free(test_data);
                log.info("Allocated 1Kb of memory at {x}", .{@intFromPtr(test_data.ptr)});
                // Test allocation
                // TODO @(dleiferives,1f09e808-18f6-4350-af6a-ad185691bfb0): Make sure
                // that alloc checks if there is enough free space ~#
                const test_data_large = try alloc.alloc(u8, 16 * 1024 * 1024);
                log.info("Allocated 16MB of memory at {x}", .{@intFromPtr(test_data_large.ptr)});
                defer alloc.free(test_data_large);

                for (test_data, 0..) |*byte, i| {
                    byte.* = @as(u8, @truncate(i)); // Fill with a test pattern
                }
                log.warn("\n", .{});
                log.info("Successfully allocated and used {} bytes", .{test_data.len});
                // read back the data
                for (test_data, 0..) |byte, i| {
                    if (byte != @as(u8, @truncate(i))) {
                        log.err("Allocation at {} in test data does not match index...", .{i});
                        while (true) {}
                    }
                }

                log.info("Now writing and reading to large memory", .{});
                for (test_data_large, 0..) |*byte, i| {
                    byte.* = @as(u8, @intCast(i & 0xFF)); // Fill with a test pattern
                }

                for (test_data, 0..) |byte, i| {
                    if (byte != @as(u8, @intCast(i & 0xFF))) {
                        log.err("Allocation at {} in test data long does not match index...", .{i});
                        while (true) {}
                    }
                }
            }
            const post_pages = state.mem_manager.page_bitfield.getFreePages();
            log.info("pages before {}, pages after {}, (note allocator holds interal free list)", .{ pre_pages, post_pages });
            log.info("finished allocator tests", .{});
        }
    }

    // Initialize UART

    arch.irq.irq.disable();
    try drivers.uart.init(.{
        .port = .COM1,
        .baud_rate = .B115200,
        .enable_interrupts = true,
    });
    defer drivers.uart.deinit();
    arch.irq.irq.enable();

    // // Enable interrupts

    // // Simple output
    try drivers.uart.print("Hello, World!\n",.{});

    if (state.testing.map_dispatch) {
        try testDemandPaging();
    }

    log.info("Kernel loaded", .{});
    log.info("Setting up threading", .{});
    state.scheduler = (try scheduler.RoundRobinScheduler.init(
        state.getKernelAllocator() orelse return error.KernelHeapNotInitialized,
        1000,
)).scheduler();

    arch.irq.exceptions.initThreading();

    const ctx = try state.kernel_heap.?.allocator().create(thread.ThreadContext);
    log.info("saving context",.{});
    thread.saveContext(ctx);
    log.info("starting to log context",.{});
    ctx.log();
    // ctx.rip = @intFromPtr(&testKernelThread);
    // thread.loadContext(ctx);

    const main_thread = thread.Thread.create(
        &kernelThreadMain,
        @ptrFromInt(10),
        true, // Kernel thread
        state.mem_manager.mapper.?, // Use the kernel's address space
        state.getKernelAllocator() orelse return error.KernelHeapNotInitialized,
        true,
        .KERNEL,
    ) catch |err| {
        log.err("Failed to create kernel thread: {}", .{err});
        return err;
    };


    try state.scheduler.?.addThread(main_thread);

    if (state.testing.threading_increment){
        var counter: u64 = 1;
        const test_thread = thread.Thread.create(
            &testKernelThread,
            &counter,
            true, // Kernel thread
            state.mem_manager.mapper.?, // Use the kernel's address space
            state.getKernelAllocator() orelse return error.KernelHeapNotInitialized,
            false,
            .KERNEL,
        ) catch |err| {
            log.err("Failed to create kernel thread: {}", .{err});
            return err;
        };
        try state.scheduler.?.addThread(test_thread);
    }
    // state.scheduler.?.current_thread = main_thread;

    thread.Thread.yield();

    // begin testing for threading
    while(true){
        arch.cpu.halt();
    }
}


fn testKernelThread(arg: *allowzero anyopaque) callconv(.C) i32{
    const end: *u64 = @ptrCast(@alignCast(arg));
    var i: u32 = 0;
    while (i < end.*) : (i += 1) {
        log.info("Test kernel thread: iteration {}", .{i});

        // Do some work
        var j: u32 = 0;
        while (j < 1000000) : (j += 1) {
            asm volatile ("" ::: "memory"); // Prevent optimization
        }

        if (i % 10 == 0) {
            thread.Thread.yield(); // Yield every 10 iterations
        }
    }
    log.info("Test kernel thread exiting", .{});

    return -1;
}

pub fn kernelThreadMain(arg: *allowzero anyopaque) callconv(.C) i32{
    _ = arg;


    if (state.testing.threading_snakes) {
        state.options.vga_printing = false;
        snakes.csnakes.setup_snakes(0);
    }

    if (state.testing.threading_snakes_hungry) {
        state.options.vga_printing = false;
        snakes.csnakes.setup_snakes(1);
    }

    if (state.testing.change_scheduler) {
        log.info("Changing scheduler to RunToCompletionScheduler", .{});
        const new_scheduler = scheduler.swapScheduler(
            state.getKernelAllocator() orelse @panic("could not get allocator when trying to test changing scheduler"),
            &state.scheduler.?,
            .RunToCompletion,
        ) catch |err| {
            log.err("Failed to change scheduler: {}", .{err});
            @panic("Failed to change scheduler");
        };
        state.scheduler = new_scheduler;
        log.info("Scheduler changed to RunToCompletionScheduler", .{});
    }


    var i: u64 = 0;
    while(true){
        log.info("idle loop {}",.{i});
        thread.Thread.yield();
        // arch.cpu.halt();
        i+=1;
    }
}

pub const Kernel = struct {
    testing: struct {
        vga: bool = false,
        page_bitfield: bool,
        mapper: bool = false,
        map_dispatch: bool = false,
        allocator: bool = false,
        threading_increment: bool = false,
        threading_snakes: bool = false,
        threading_snakes_hungry: bool = false,
        change_scheduler: bool = false,
    },
    initilized: struct {
        mem_layout: bool = false,
        multiboot_info: bool = false,
        mem_manager: bool = false,
        vga: bool = false,
        serial_log: bool = false,
    },
    options: struct {
        polling_keyboard: bool = false,
        vga_printing: bool = true, // Enable VGA printing by default
    },

    vga_addr: usize,
    stdio_port: drivers.serial_log.Port,
    stdio_baudrate: usize,
    stdio_init: bool,
    mem_manager: *mem.Manager,
    multiboot_info: multiboot.Multiboot2Info,
    kernel_heap: ?mem.allocator.FreeListAllocator = null,
    scheduler: ?scheduler.Scheduler = null,

    pub inline fn mem_layout_init(self: *Kernel) !void {
        if (self.initilized.mem_layout) {
            log.warn("Memory layout already initialized", .{});
            return;
        }
        self.mem_manager = try mem.Manager.new();
        self.initilized.mem_layout = true;
        log.info("Memory layout initialized", .{});
    }

    pub inline fn mem_manager_init(self: *Kernel) !void {
        if (self.initilized.mem_manager) {
            log.warn("Memory manager already initialized", .{});
            return;
        }
        if (!self.initilized.mem_layout) {
            self.mem_manager = try mem.Manager.new();
            self.initilized.mem_layout = true;
            return;
        }
        self.multiboot_info_init();
        self.multiboot_info.dumpInfo(drivers.serial_log.writer(self.stdio_port)) catch {};
        try self.mem_manager.init(self.multiboot_info, self.testing.page_bitfield);
        self.initilized.mem_manager = true;
    }

    /// Initialize the multiboot info
    /// implicitly called by the memory manager initialization
    /// as we need to see what memory is available
    pub inline fn multiboot_info_init(self: *Kernel) void {
        if (!self.initilized.mem_layout) {
            log.warn("Multiboot info not initialised, memory layout not set", .{});
            return;
        }
        self.multiboot_info = multiboot.Multiboot2Info.init(multiboot.loadInfoHeader(state.mem_manager.memory_layout.kernel_offset));
        self.initilized.multiboot_info = true;
    }

    pub inline fn vga_init(self: *Kernel, addr: usize) void {
        if (!self.initilized.mem_layout) {
            log.warn("VGA driver not initialised, memory layout not set", .{});
            return;
        }
        log.debug("Initialising VGA driver at 0x{x}", .{addr});
        self.vga_addr = addr | self.mem_manager.memory_layout.kernel_offset;
        drivers.vga.init(self.vga_addr);
        if (self.testing.vga) {
            drivers.vga.test_vga() catch {};
        }
        log.info("VGA driver initialised", .{});
        // while(true){}
        self.initilized.vga = true;
    }

    pub inline fn serial_log_init(self: *Kernel, baudrate: usize, port: drivers.serial_log.Port) void {
        log.debug("Initialising serial driver {} with baudrate {d}", .{ port, baudrate });
        self.stdio_init = true;
        self.stdio_port = port;
        self.stdio_baudrate = baudrate;
        drivers.serial_log.init(baudrate, port) catch {};
        log.info("Serial driver initialised", .{});
        self.initilized.serial_log = true;
    }
    pub fn initKernelHeap(self: *Kernel) !void {
        if (!self.initilized.mem_manager) {
            return error.MemoryManagerNotInitialized;
        }

        const mapper = self.mem_manager.mapper orelse return error.MapperNotInitialized;

        // Create kernel heap in virtual address space
        const heap_start = mem.types.MEMORY_LAYOUT.KERNEL_VIRTUAL_HEAP_START;
        const heap_size = 64 * 1024 * 1024; // 64MB heap

        self.kernel_heap = try mem.allocator.FreeListAllocator.init(
            heap_start,
            heap_size,
            mapper,
            mem.PageFlags{
                .present = true,
                .writable = true,
                .user_accessible = false,
                .demand_alloc = false, // Not demand paging for kernel heap
            },
        );

        // Test the heap
        try self.kernel_heap.?.tester();

        log.info("Kernel heap initialized", .{});
    }

    pub fn getKernelAllocator(self: *Kernel) ?std.mem.Allocator {
        if (self.kernel_heap) |*heap| {
            return heap.allocator();
        }
        return null;
    }
};

pub var state: Kernel = undefined;

/// helpers
/// NOTE: logging is going to have error levels basically
/// debug = everything
/// log = some stuff
/// warn = information / base level
/// error = errors
pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = trace;
    print("\n================ PANIC ================\n", .{});
    print("Message: {s}\n", .{msg});
    if (return_address) |addr| {
        print("Return address: 0x{X}\n", .{addr});
    } else {
        print("No return address available.\n", .{});
    }
    // std.debug.dumpCurrentStackTrace();

    // Halt forever
    // TODO @(dleiferives,1ad01822-7fbc-4e0d-b952-2ba435ba3b9f): Make panic
    // relaunch the kernel! ~#
    while (true) {}
}

pub fn print(comptime format: []const u8, args: anytype) void {
    // Print logging protect via disabling interrupts
    // arch.cpu.cli();
    if (drivers.vga.initialized) {
        if(state.options.vga_printing) {
            // Print to VGA
            drivers.vga.print(format, args) catch {};
        }
    }
    if (state.stdio_init) {
        if (drivers.serial_log.isInitialised(state.stdio_port)) {
            drivers.serial_log.print(state.stdio_port, format, args) catch {};
        }
    }
    // and then re-enable interrupts
    // arch.cpu.sti();
}

pub const LogScope = enum {
    drivers_vga,
    drivers_serial_log,
    drivers_ps2,
    drivers_ps2_verbose,
    drivers_keyboard,
    drivers_keyboard_verbose,
    drivers_uart_verbose,
    drivers_uart,
    arch_gdt,
    kernel,
    kernel_main,
    mem,
    mem_verbose,
    mem_layout,
    mem_manager,
    mem_manager_verbose,
    mem_manager_mapper,
    mem_manager_mapper_verbose,
    mem_manager_mapper_translate,
    mem_allocator,
    mem_allocator_verbose,
    mem_page_bitfield,
    mem_page_bitfield_verbose,
    irq_page_fault,
    irq,
    std_log_default_scope,
};

pub var allowed_scopes: ?[]const LogScope = null;
pub const ALL_SCOPES = [_]LogScope{
    .mem_page_bitfield_verbose,
    .mem_page_bitfield,
    .mem,
    .mem_verbose,
    .mem_layout,
    .mem_manager,
    // .mem_manager_verbose,
    .mem_manager_mapper,
    // .mem_manager_mapper_verbose,
    // .mem_manager_mapper_translate,
    .mem_allocator,
    .mem_allocator_verbose,
    .irq,
    .irq_page_fault,
    .drivers_vga,
    .drivers_serial_log,
    .drivers_ps2,
    .drivers_ps2_verbose,
    .drivers_keyboard,
    // .drivers_keyboard_verbose,
    .drivers_uart_verbose,
    .drivers_uart,
    .kernel,
    .arch_gdt,
    .kernel_main,
    .std_log_default_scope,
};

pub fn logger(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!std.mem.eql(u8, @tagName(scope), @tagName(.default))) {
        if (allowed_scopes) |allowed| {
            var found = false;
            for (allowed) |allowed_scope| {
                if (std.mem.eql(u8, @tagName(scope), @tagName(allowed_scope))) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return;
            }
        }
    }
    const prefix_scope = "[" ++ @tagName(scope) ++ "]: ";
    const prefix_level = "[" ++ comptime level.asText() ++ "]: ";
    const prefix = if (scope == .default) prefix_level else prefix_scope;
    switch (level) {
        .debug => {
            if (@intFromEnum(log_level) <= @intFromEnum(std.log.Level.debug)) {
                print("{s}", .{prefix});
                print(format ++ "\n", args);
            }
        },
        .info => {
            if (@intFromEnum(log_level) <= @intFromEnum(std.log.Level.info)) {
                print("{s}", .{prefix});
                print(format ++ "\n", args);
            }
        },
        .warn => {
            if (@intFromEnum(log_level) <= @intFromEnum(std.log.Level.warn)) {
                print(format, args);
            }
        },
        .err => {
            if (@intFromEnum(log_level) <= @intFromEnum(std.log.Level.err)) {
                print("{s}", .{prefix});
                print(format ++ "\n", args);
            }
        },
    }
}

/// Allocate virtual memory with demand paging
pub fn allocateVirtualMemoryDemand(virt_addr: u64, size: u64, flags: mem.PageFlags) !void {
    if (!state.initilized.mem_manager) {
        return error.MemoryManagerNotInitialized;
    }

    var mapper = state.mem_manager.mapper orelse return error.MapperNotInitialized;

    const page_count = (size + mem.PAGE_SIZE_4K - 1) / mem.PAGE_SIZE_4K;
    var current_addr = virt_addr & ~mem.PAGE_MASK_4K;

    var i: u64 = 0;
    log.warn("Allocating {} pages with demand paging at 0x{X:0>16} - 0x{X:0>16}\n", .{ page_count, virt_addr, virt_addr + size });
    while (i < page_count) : (i += 1) {
        try mapper.mapDemand(current_addr, flags);
        if (i & 0x3FF == 0) log.warn("~{d:0>6}/{d:0>6}\r", .{ i, page_count });
        current_addr += mem.PAGE_SIZE_4K;
    }
    log.info("Allocated {} pages with demand paging at 0x{X:0>16}", .{ page_count, virt_addr });
}

/// Test demand paging functionality
pub fn testDemandPaging() !void {
    log.info("Testing demand paging...", .{});

    // Allocate some virtual memory with demand paging
    const test_virt_addr: u64 = 0xFFFFFF8010000000; // Some unused virtual address
    const test_size: u64 = 64 * 1024 * mem.PAGE_SIZE_4K; // 4 pages
    const pages_start = state.mem_manager.page_bitfield.getFreePages();

    const flags = mem.PageFlags{
        .present = false, // Will be set by demand handler
        .writable = true,
        .user_accessible = false,
        .demand_alloc = true,
    };

    try allocateVirtualMemoryDemand(test_virt_addr, test_size, flags);
    log.info("Demand pages allocated, now testing access...", .{});

    // Try to access the first page - should trigger demand allocation
    const test_ptr: *volatile u64 = @ptrFromInt(test_virt_addr);
    test_ptr.* = 0xDEADBEEF;

    if (test_ptr.* == 0xDEADBEEF) {
        log.info("First page access successful - demand allocation worked!", .{});
    } else {
        log.err("First page access failed!", .{});
        return error.DemandPagingTestFailed;
    }

    // Access other pages
    log.info("Accessing the other {d} pages to trigger demand paging...", .{test_size / mem.PAGE_SIZE_4K});
    const pages_to_access = @min(state.mem_manager.page_bitfield.getFreePages() * 8 / 10, test_size / mem.PAGE_SIZE_4K);
    log.info("We only have {} pages actually available, so we will access 80% ({}) of them", .{ state.mem_manager.page_bitfield.getFreePages(), pages_to_access });
    for (1..pages_to_access) |i| {
        const test_ptr2: *volatile u64 = @ptrFromInt(test_virt_addr + mem.PAGE_SIZE_4K * i);
        if (i & 0xFF == 0) log.warn("~0x{X:0>16} {d:0>6}/{d:0>6}\r", .{ @intFromPtr(test_ptr2), i, pages_to_access });
        test_ptr2.* = 0xCAFEBABE;
        // if( i & 0xFF == 0) log.warn(" w", .{});
        // log.info("Accessing second page at 0x{X:0>16} {}", .{@intFromPtr(test_ptr2), i});

        if (test_ptr2.* == 0xCAFEBABE) {
            // if( i & 0xFF == 0) log.warn(" r\r", .{});
        } else {
            log.warn("\n", .{});
            log.err("Page access failed!", .{});
            return error.DemandPagingTestFailed;
        }
    }

    log.info("All {} pages accessed successfully!", .{pages_to_access});
    log.info("Now freeing the allocated pages...", .{});
    state.mem_manager.mapper.?.unmapAndFreeRangeFull(test_virt_addr, test_virt_addr + test_size) catch |err| {
        log.err("Failed to unmap and free pages: {any}", .{err});
        return err;
    };
    const final_pages = state.mem_manager.page_bitfield.getFreePages();
    log.info("Demand paging test completed, freed pages: {d} -> {d}", .{ pages_start, final_pages });
    if (final_pages < pages_start) {
        log.err("Page count mismatch after freeing: expected {}, got {}", .{ pages_start, final_pages });
        return error.DemandPagingTestFailed;
    }

    log.info("Demand paging test completed successfully!", .{});
}
