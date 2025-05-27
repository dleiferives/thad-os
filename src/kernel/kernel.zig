const std = @import("std");
const drivers = @import("drivers");
const mem = @import("mem.zig");
const multiboot = @import("multiboot.zig");
const arch = @import("arch");

const log = std.log.scoped(.kernel);

comptime {
    _ = mem.memset;
    _ = mem.memcpy;

    // early setting the container allocator to be linked to the kernel
    _ = mem.Manager;
}

pub var log_level: std.log.Level = std.log.Level.err;

pub export fn kmain() callconv(.C) void {
    main() catch |err| {
        log.err("Kernel main failed: {}", .{err});
        panic("Kernel main failed", null, null);
    };
}

pub fn main() !void {
    allowed_scopes = ALL_SCOPES[0..];

    state.mem_layout_init();
    arch.cpu.gdt.init();

    try arch.irq.irq.init();
    arch.irq.irq.enable();
    // Initilize the VGA driver
    state.vga_init(0xb8000);
    state.testing.vga = true;

    // Initialize interrupt system

    // Initialize the serial driver
    state.serial_log_init(drivers.serial_log.DEFAULT_BAUDRATE, .COM1);

    // // log.info("Info header {x}",.{@as(u64,@intFromPtr(multiboot.loadInfoHeader(state.mem_manager.memory_layout.kernel_offset)))});
    // log.info("Info header {}",.{multiboot.loadInfoHeader(state.mem_manager.memory_layout.kernel_offset)});
    // var mbi = multiboot.Multiboot2Info.init(multiboot.loadInfoHeader(state.mem_manager.memory_layout.kernel_offset));
    // mbi.dumpInfo(drivers.serial.writer(state.stdio_port)) catch {};

    try state.mem_manager_init();
    try arch.cpu.gdt.tester();

    // var ps2_ctrl = try drivers.ps2.Ps2Controller.init();
    // log.info("--- PS/2 Controller Initialized ---\n", .{});

    // Initialize the Keyboard Manager with the PS/2 Controller
    // var kbd_manager = try drivers.keyboard.KeyboardManager.init(&ps2_ctrl);
    // log.info("--- Keyboard Manager Initialized ---\n", .{});

    // if (kbd_manager.keyboard1 == null and kbd_manager.keyboard2 == null) {
    //     log.info("No keyboards detected. Exiting.\n", .{});
    //     return;
    // }

    // log.info("Starting keyboard input polling. Press keys to see them on screen. (Ctrl+C won't work here!)\n", .{});

    // Simple polling loop for "type to screen"
    // In a real OS, this would be event-driven or handled by interrupt routines.
    // while (true) {
    //     kbd_manager.pollAndProcessInput();

    //     // Add a small delay to prevent hogging CPU in a polling loop
    //     // This is a placeholder; a proper OS would have a scheduler or idle loop.
    //     var i: u32 = 0;
    //     while (i < 500) : (i += 1) { // Adjust delay as needed
    //         asm volatile ("" ::: "memory");
    //     }
    // }

    // Initialize kernel heap
    try state.initKernelHeap();

    // Now you can use the allocator
    if (state.getKernelAllocator()) |alloc| {
    //     // Test allocation
        const test_data = try alloc.alloc(u8, 1024 * 1024);
        log.info("Allocated 1MB of memory at {x}", .{@intFromPtr(test_data.ptr)});
    //     // defer alloc.free(test_data);

    //     // for (test_data) |*byte| {
    //     //     log.info("Allocating byte at {x}", .{@intFromPtr(byte)});
    //     //     byte.* = 0x42; // Fill with a test pattern
    //     // }
    //     // log.info("Successfully allocated and used {} bytes", .{test_data.len});

    }


    // Initialize UART
    try drivers.uart.init(.{
        .port = .COM1,
        .baud_rate = .B115200,
        .enable_interrupts = true,
    });

    // Enable interrupts

    log.info("Kernel loaded", .{});

    // Simple output
    try drivers.uart.print("Hello, World!\n",.{});
    // try drivers.uart.print("Enter commands (type 'help' for list):\n",.{});

    // var input_buffer: [128]u8 = undefined;

    // while (true) {
    //     try uart.print("> ");

    //     // Read a line from user
    //     const line = try uart.readLine(&input_buffer);
    //     const command = std.mem.trim(u8, line, " \t\r\n");

    //     if (std.mem.eql(u8, command, "help")) {
    //         try uart.print("Available commands:\n");
    //         try uart.print("  help    - Show this help\n");
    //         try uart.print("  echo    - Echo test\n");
    //         try uart.print("  status  - Show UART status\n");
    //         try uart.print("  quit    - Exit\n");
    //     } else if (std.mem.eql(u8, command, "echo")) {
    //         try uart.print("Echo test - type something: ");
    //         const echo_line = try uart.readLine(&input_buffer);
    //         try uart.print("You typed: {s}", .{echo_line});
    //     } else if (std.mem.eql(u8, command, "status")) {
    //         try uart.print("TX Ready: {}\n", .{uart.txReady()});
    //         try uart.print("RX Ready: {}\n", .{uart.rxReady()});
    //     } else if (std.mem.eql(u8, command, "quit")) {
    //         try uart.print("Goodbye!\n");
    //         break;
    //     } else if (command.len > 0) {
    //         try uart.print("Unknown command: {s}\n", .{command});
    //     }
    // }
    //
    try testDemandPaging();
     drivers.uart.deinit();
}


pub const Kernel = struct {
    testing: struct {
        vga: bool,

    },
    initilized: struct {
        mem_layout: bool = false,
        multiboot_info: bool = false,
        mem_manager: bool = false,
        vga: bool = false,
        serial_log: bool = false,
    },
    vga_addr: usize,
    stdio_port: drivers.serial_log.Port,
    stdio_baudrate: usize,
    stdio_init: bool,
    mem_manager: mem.Manager,
    multiboot_info: multiboot.Multiboot2Info,
    kernel_heap: ?mem.allocator.FreeListAllocator = null,

    pub inline fn mem_layout_init(self: *Kernel) void {
        if (self.initilized.mem_layout) {
            log.warn("Memory layout already initialized", .{});
            return;
        }
        self.mem_manager= mem.Manager.new();
        self.initilized.mem_layout = true;
        log.info("Memory layout initialized", .{});
    }

    pub inline fn mem_manager_init(self: *Kernel) !void {
        if (self.initilized.mem_manager) {
            log.warn("Memory manager already initialized", .{});
            return;
        }
        if (!self.initilized.mem_layout) {
            self.mem_manager= mem.Manager.new();
            self.initilized.mem_layout = true;
            return;
        }
        self.multiboot_info_init();
        self.multiboot_info.dumpInfo(drivers.serial_log.writer(self.stdio_port)) catch {};
        try self.mem_manager.init(self.multiboot_info);
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
        self.initilized.vga = true;
    }

    pub inline fn serial_log_init(self: *Kernel, baudrate: usize, port: drivers.serial_log.Port) void {
        log.debug("Initialising serial driver {} with baudrate {d}", .{port, baudrate});
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
                .present = false,
                .writable = true,
                .user_accessible = false,
                .demand_alloc = true, // Not demand paging for kernel heap
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
    _ = return_address;
    print("\n================ PANIC ================\n", .{});
    print("Message: {s}\n", .{msg});

    // Halt forever
    // TODO @(dleiferives,1ad01822-7fbc-4e0d-b952-2ba435ba3b9f): Make panic
    // relaunch the kernel! ~#
    while (true) {}
}


pub fn print(comptime format: []const u8, args: anytype) void {
    // Print logging protect via disabling interrupts
    if (drivers.vga.initialized) {
        drivers.vga.print(format, args) catch {};
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
    // Ignore all non-error logging from sources other than
    // .my_project, .nice_library and the default

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
    const prefix = if(scope == .default) prefix_level else prefix_scope;
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
    while (i < page_count) : (i += 1) {
        try mapper.mapDemand(current_addr, flags);
        current_addr += mem.PAGE_SIZE_4K;
    }

    log.info("Allocated {} pages with demand paging at 0x{X:0>16}", .{ page_count, virt_addr });
}

/// Test demand paging functionality
pub fn testDemandPaging() !void {
    log.info("Testing demand paging...", .{});

    // Allocate some virtual memory with demand paging
    const test_virt_addr: u64 = 0xFFFFFF8010000000; // Some unused virtual address
    const test_size: u64 = 4 * mem.PAGE_SIZE_4K; // 4 pages

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

    // Access second page
    const test_ptr2: *volatile u64 = @ptrFromInt(test_virt_addr + mem.PAGE_SIZE_4K);
    test_ptr2.* = 0xCAFEBABE;

    if (test_ptr2.* == 0xCAFEBABE) {
        log.info("Second page access successful!", .{});
    } else {
        log.err("Second page access failed!", .{});
        return error.DemandPagingTestFailed;
    }

    log.info("Demand paging test completed successfully!", .{});
}
