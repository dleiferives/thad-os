const std = @import("std");
const drivers = @import("drivers");
pub const mem = @import("mem.zig");
const multiboot = @import("multiboot.zig");
const arch = @import("arch");
const config = @import("config");
pub const thread = @import("thread.zig");
pub const syscall = @import("syscall.zig");
pub const mutex = @import("mutex.zig");
pub const thread_queue = @import("thread_queue.zig");
const scheduler = @import("scheduler.zig");
const snakes = @import("snakes.zig");
const mbr = @import("mbr.zig");
const ext2 = @import("ext2.zig");
const vfs = @import("vfs.zig");
const simple_fs = @import("simple_fs.zig");
const elf = @import("elf.zig");
const elf_loader = @import("elf_loader.zig");
const arcade = @import("arcade.zig");
const builtin = @import("builtin");
pub const cache = @import("lru_cache.zig");

const log = std.log.scoped(.kernel);

// Required forward declarations / uses such that teh compiler will have the
// symbols ready for linking at the right time.
comptime {
    _ = mem.memset;
    _ = mem.memcpy;
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

/// Maximum verbosity emitted by the normal scoped logger. Error messages are
/// always emitted even when their scope is disabled.
pub var log_level: std.log.Level = .info;
var configured_log_scopes: [256]u8 = undefined;
var configured_log_scopes_len: usize = 0;

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
    // `state` lives in BSS as undefined because several required fields are
    // populated during staged boot. Explicitly initialize every field that is
    // read as state before its subsystem assigns the final value.
    state.initilized = .{};
    state.options = .{};
    state.stdio_init = false;
    state.keyboard_manager = null;
    state.ps2_ctrl = null;
    state.kernel_heap = null;
    state.kernel_allocator = null;
    state.scheduler = null;

    // TODO: Give Kernel a complete initializer so adding a new state field
    // cannot silently introduce another undefined early-boot read.
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

    initMacbookEarlyConsole();
    macbookEarlyLog("[entry] Zig kernel entered\n");
    try state.mem_layout_init();
    macbookEarlyLog("[memory] layout metadata ready\n");
    arch.cpu.gdt.init();
    macbookEarlyLog("[cpu] GDT ready\n");

    // Initialize interrupt system
    try arch.irq.irq.init();
    arch.irq.irq.enable();
    macbookEarlyLog("[cpu] IDT and interrupts ready\n");
    // Initilize the VGA driver
    state.vga_init(0xb8000);

    // Initialize the serial driver
    state.serial_log_init(drivers.serial_log.DEFAULT_BAUDRATE, .COM1);
    macbookEarlyLog("[console] legacy devices initialized\n");

    // Initilize the memory manager
    macbookEarlyLog("[memory] entering page-map rebuild...\n");
    try state.mem_manager_init();
    configureLogging();
    initBootFramebuffer() catch |err| {
        log.warn("Framebuffer console unavailable: {}", .{err});
    };
    if (drivers.vga.hasFramebuffer()) {
        drivers.vga.clear();
        drivers.vga.setColor(.LIGHT_CYAN, .BLACK);
        drivers.vga.print("THAD-OS hardware boot\n\n", .{}) catch {};
        bootStatus("framebuffer ready", .{});
    }
    if (state.testing.mapper) {
        try state.mem_manager.test_mapper(0xFFFFFF8010000000);
    }
    // state.options.polling_keyboard =true;
    // try arch.cpu.gdt.tester();

    // Initialize the kernel heap before optional peripheral drivers. Storage
    // needs it, and storage must be available early enough to persist failures
    // from input and other later boot stages.
    bootStatus("initializing kernel heap", .{});
    try state.initKernelHeap();
    bootStatus("kernel heap ready", .{});

    bootStatus("probing AHCI storage", .{});
    drivers.ahci.init() catch |err| {
        log.warn("AHCI driver unavailable: {}", .{err});
    };
    bootStatus("AHCI probe finished", .{});
    flushPersistentBootLog() catch |err| {
        log.warn("Could not persist hardware boot log: {}", .{err});
    };

    state.ps2_ctrl = null;
    state.keyboard_manager = null;
    var ps2_ctrl_storage: drivers.ps2.Ps2Controller = undefined;
    var kbd_manager_storage: drivers.keyboard.KeyboardManager = undefined;
    if (hasBootFlag("thad-macbook41")) {
        // MacBook4,1 exposes its built-in keyboard and trackpad as USB devices;
        // touching an absent/firmware-emulated i8042 controller can stall boot.
        bootStatus("PS/2 skipped; USB input required", .{});
        // TODO: Add UHCI/EHCI enumeration and a USB HID boot-keyboard backend,
        // then feed its key events into KeyboardBuffer.
        // TODO: Parse the ACPI FADT i8042 boot-architecture flag instead of
        // relying on a machine-specific kernel command-line flag.
    } else if (drivers.ps2.Ps2Controller.init()) |controller| {
        ps2_ctrl_storage = controller;
        bootStatus("PS/2 controller ready", .{});
        log.info("--- PS/2 Controller Initialized ---\n", .{});

        if (drivers.keyboard.KeyboardManager.init(&ps2_ctrl_storage)) |manager| {
            kbd_manager_storage = manager;
            log.info("--- Keyboard Manager Initialized ---\n", .{});
            if (kbd_manager_storage.keyboard1 == null and
                kbd_manager_storage.keyboard2 == null)
            {
                bootStatus("PS/2 has no keyboard; continuing", .{});
            } else {
                state.keyboard_manager = &kbd_manager_storage;
                state.ps2_ctrl = &ps2_ctrl_storage;
                try drivers.keyboard.setup_irq(&ps2_ctrl_storage, &kbd_manager_storage);
            }
        } else |err| {
            log.warn("Keyboard manager unavailable: {}", .{err});
            bootStatus("PS/2 keyboard unavailable; continuing", .{});
        }
    } else |err| {
        log.warn("PS/2 controller unavailable: {}", .{err});
        bootStatus("PS/2 unavailable; continuing", .{});
    }

    if (state.options.polling_keyboard and state.keyboard_manager != null) {
        log.info("Starting keyboard input polling. Press keys to see them on screen. (Ctrl+C won't work here!)\n", .{});
        while (true) {
            state.keyboard_manager.?.pollAndProcessInput();

            // Add a small delay to prevent hogging CPU in a polling loop
            var i: u32 = 0;
            while (i < 500) : (i += 1) {
                asm volatile ("" ::: "memory");
            }
        }
    }

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

    try drivers.uart.print("Hello, World!\n", .{});

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

    const ctx = try state.getKernelAllocator().?.create(thread.ThreadContext);
    log.info("saving context", .{});
    thread.saveContext(ctx);
    log.info("starting to log context", .{});
    ctx.log();

    const main_thread = thread.Thread.create(
        &kernelThreadMain,
        @ptrFromInt(10),
        true, // Kernel thread
        state.mem_manager.mapper.?, // Use the kernel's address space
        state.getKernelAllocator() orelse return error.KernelHeapNotInitialized,
        true,
        .KERNEL,
        true,
    ) catch |err| {
        log.err("Failed to create kernel thread: {}", .{err});
        return err;
    };

    try state.scheduler.?.addThread(main_thread);

    if (state.testing.threading_increment) {
        var counter: u64 = 1;
        const test_thread = thread.Thread.create(
            &testKernelThread,
            &counter,
            true, // Kernel thread
            state.mem_manager.mapper.?, // Use the kernel's address space
            state.getKernelAllocator() orelse return error.KernelHeapNotInitialized,
            false,
            .KERNEL,
            true,
        ) catch |err| {
            log.err("Failed to create kernel thread: {}", .{err});
            return err;
        };
        try state.scheduler.?.addThread(test_thread);
    }
    // state.scheduler.?.current_thread = main_thread;

    thread.Thread.yield();

    while (true) {
        arch.cpu.halt();
    }
}

fn initMacbookEarlyConsole() void {
    if (!config.macbook_early_fb) return;
    drivers.vga.init(0xFFFF_FF80_000B_8000);
    drivers.vga.initFramebuffer(
        0xFFFF_FF80_A000_0000,
        1280,
        800,
        8192,
        32,
        16,
        8,
        8,
        8,
        0,
        8,
    ) catch return;
    drivers.vga.clear();
    drivers.vga.setColor(.LIGHT_CYAN, .BLACK);
    drivers.vga.putStrEarly("THAD-OS EARLY BOOT LOG\n\n");

    // TODO: Feed this early console from a structured ring buffer so messages
    // can be replayed to later console and persistent diagnostic backends.
}

fn macbookEarlyLog(message: []const u8) void {
    recordPersistentBootLog(message);
    if (!config.macbook_early_fb or !drivers.vga.hasFramebuffer()) return;
    drivers.vga.setColor(.LIGHT_GRAY, .BLACK);
    drivers.vga.putStrEarly(message);
}

pub fn keyboardIOThread(arg: *allowzero anyopaque) callconv(.C) i32 {
    _ = arg;
    log.info("Keyboard I/O thread started - type characters to see them echoed", .{});

    while (true) {
        const ch = drivers.keyboard.KeyboardBuffer.getc();
        log.info("Keyboard thread got: '{c}' (0x{X:0>2})", .{ ch, ch });

        // Echo the character to VGA
        print("Echo: {c}\n", .{ch});

        // Handle special keys
        if (ch == '\r' or ch == '\n') {
            print("--- Line End ---\n", .{});
        }
    }
}

fn testKernelThread(arg: *allowzero anyopaque) callconv(.C) i32 {
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

pub fn kernelThreadMain(arg: *allowzero anyopaque) callconv(.C) i32 {
    _ = arg;

    // Create keyboard I/O test thread
    if (state.ps2_ctrl != null and state.keyboard_manager != null) {
        drivers.keyboard.KeyboardBuffer.setup_irq(
            state.ps2_ctrl.?,
            state.keyboard_manager.?,
        ) catch |err| {
            log.warn("Failed to switch PS/2 keyboard to buffered IRQ input: {}", .{err});
        };
    }
    // const kbd_thread = thread.Thread.create(
    //     &keyboardIOThread,
    //     null,
    //     true, // kernel thread
    //     state.mem_manager.mapper.?,
    //     state.getKernelAllocator().?,
    //     false,
    //     .NORMAL,
    // ) catch |err| {
    //     log.err("Failed to create keyboard I/O thread: {}", .{err});
    //     @panic("Failed to create keyboard I/O thread");
    // };

    // state.scheduler.?.addThread(kbd_thread) catch |err| {
    //     log.err("Failed to add keyboard I/O thread to scheduler: {}", .{err});
    //     @panic("Failed to add keyboard I/O thread to scheduler");
    // };

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

    // AHCI normally came up before optional input initialization so boot
    // failures could already be persisted. Keep this idempotent call for
    // configurations where early initialization was unavailable.
    drivers.ahci.init() catch |err| {
        log.warn("AHCI driver unavailable: {}", .{err});
    };
    flushPersistentBootLog() catch |err| {
        log.warn("Could not persist hardware boot log: {}", .{err});
    };

    drivers.ata.init() catch |err| {
        // Some EFI systems expose their SATA disk only through AHCI. A GRUB
        // Multiboot root module lets thad-os boot there until an AHCI driver is
        // available.
        log.warn("ATA driver unavailable: {}", .{err});
    };

    drivers.multiboot_module.init() catch |err| switch (err) {
        error.RootModuleNotFound => {},
        else => log.warn("Could not register Multiboot root module: {}", .{err}),
    };

    // drivers.ata.testRead() catch |err| {
    //     log.err("ATA read test failed: {}", .{err});
    //     @panic("ATA read test failed");
    // };

    // drivers.ata.testWrite() catch |err| {
    //     log.err("Failed to write to ATA device: {}", .{err});
    //     @panic("Failed to write to ATA device");
    // };
    mbr.logAllMBR() catch |err| {
        log.err("Failed to log MBR: {}", .{err});
        bootStatus("partition diagnostics failed: {}; continuing", .{err});
    };

    log.info("starting to create filesystems", .{});
    // Initialize VFS
    log.info("Initializing VFS", .{});
    vfs.init(state.getKernelAllocator() orelse @panic("could not get allocator for VFS"));

    log.info("starting to create filesystems", .{});

    bootStatus("searching for an ext2 root", .{});
    var ext2_iter = ext2.Ext2FilesystemIterator.init(state.getKernelAllocator() orelse @panic("could not get allocator when trying to test ext2 filesystem")) catch |err| {
        log.err("Failed to initialize ext2 filesystem iterator: {}", .{err});
        @panic("Failed to initialize ext2 filesystem iterator");
    };
    bootStatus("ext2 iterator ready", .{});

    var mounted_ext2 = false;
    const run_elf_boot_test = hasBootFlag("thad-test-elf");
    while (ext2_iter.next()) |fs| {
        bootStatus("ext2 root found at LBA {}", .{fs.partition_entry.lba_first_absolute});
        log.info("found ext2 filesystem: {s}", .{fs.superblock.volume_name});
        log.info("There are {} blocks in this filesystem", .{fs.superblock.blocks_count});
        log.info("There are {} block groups in this filesystem", .{fs.block_groups.len});

        // Mount the first ext2 filesystem as root
        if (!mounted_ext2) {
            log.info("Mounting ext2 filesystem as VFS root", .{});
            bootStatus("mounting ext2 root", .{});
            simple_fs.mountExt2Root(state.getKernelAllocator() orelse @panic("no allocator"), fs) catch |err| {
                log.err("Failed to mount ext2 as root: {}", .{err});
                bootStatus("ext2 root mount failed: {}", .{err});
                continue;
            };
            mounted_ext2 = true;
            bootStatus("VFS root mounted", .{});

            if (run_elf_boot_test) {
                log.info("Testing VFS operations", .{});
                testVfsOperations() catch |err| {
                    log.err("VFS tests failed: {}", .{err});
                    @panic("VFS test failed");
                };
                testMd5Checksum() catch |err| {
                    log.err("MD5 checksum test failed: {}", .{err});
                    @panic("MD5 checksum test failed");
                };
                log.info("Testing ELF program loading...", .{});
                elf_loader.loadAndRunProgram("/bin/program", null, true) catch |err| {
                    log.err("Failed to load ELF program: {}", .{err});
                };
                allowed_scopes = MAP_TEST_SCOPES[0..];
                while (true) thread.Thread.yield();
            }

            bootStatus("root mounted; starting arcade", .{});
            flushPersistentBootLog() catch {};
            arcade.run();
        }
    }

    // If no ext2 found, create simple root
    if (!mounted_ext2) {
        bootStatus("no labeled ext2 root found", .{});
        @panic("No ext2 filesystem found, cannot mount root");
    }

    // allowed_scopes = MAP_TEST_SCOPES[0..];
    // mem.tests.runMapperTests(state.getKernelAllocator() orelse @panic("no allocator"), state.mem_manager.mapper.?) catch |err| {
    //     log.err("Mapper tests failed: {}", .{err});
    //     @panic("Mapper tests failed");
    // };
    // // allowed_scopes = ALL_SCOPES[0..];

    var i: u64 = 0;
    while (true) {
        log.debug("idle loop {}", .{i});
        // check if we are the only thread
        thread.Thread.yield();
        arch.cpu.halt();
        i += 1;
    }
}

fn hasBootFlag(flag: []const u8) bool {
    var iterator = state.multiboot_info.getTagTypeIterator(.COMMAND_LINE);
    const header = iterator.next() orelse return false;
    const command_line: *const multiboot.CommandLineTag = @ptrCast(@alignCast(header));
    return command_line.hasFlag(flag);
}

pub fn isMacbook41BootProfile() bool {
    return config.macbook_early_fb and hasBootFlag("thad-macbook41");
}

fn getBootParam(name: []const u8, buffer: []u8) ?[]const u8 {
    var iterator = state.multiboot_info.getTagTypeIterator(.COMMAND_LINE);
    const header = iterator.next() orelse return null;
    const command_line: *const multiboot.CommandLineTag = @ptrCast(@alignCast(header));
    return command_line.getParam(name, buffer);
}

fn configureLogging() void {
    var level_buffer: [16]u8 = undefined;
    if (getBootParam("thad-log-level", &level_buffer)) |level| {
        if (std.mem.eql(u8, level, "error") or std.mem.eql(u8, level, "err")) {
            log_level = .err;
        } else if (std.mem.eql(u8, level, "warn")) {
            log_level = .warn;
        } else if (std.mem.eql(u8, level, "info")) {
            log_level = .info;
        } else if (std.mem.eql(u8, level, "debug")) {
            log_level = .debug;
        } else {
            hardwareBootStatus("logging: unknown level '{s}'; using {s}", .{ level, logLevelText(log_level) });
        }
    }

    var scopes_buffer: [configured_log_scopes.len]u8 = undefined;
    if (getBootParam("thad-log-scopes", &scopes_buffer)) |scopes| {
        @memcpy(configured_log_scopes[0..scopes.len], scopes);
        configured_log_scopes_len = scopes.len;
    }

    hardwareBootStatus("logging: level={s}, scopes={s}", .{
        logLevelText(log_level),
        if (configured_log_scopes_len == 0)
            "default"
        else
            configured_log_scopes[0..configured_log_scopes_len],
    });
}

fn logLevelText(level: std.log.Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}

fn initBootFramebuffer() !void {
    if (hasBootFlag("thad-macbook41")) {
        // Debian's efifb DMI quirk confirms these values on this MacBook4,1.
        // Its EFI UGA scanout uses a padded 8192-byte pitch rather than
        // width * bytes_per_pixel (5120 bytes).
        return mapBootFramebuffer(.{
            .address = 0xA000_0000,
            .width = 1280,
            .height = 800,
            .pitch = 8192,
            .bits_per_pixel = 32,
            .red_position = 16,
            .red_mask_size = 8,
            .green_position = 8,
            .green_mask_size = 8,
            .blue_position = 0,
            .blue_mask_size = 8,
        });
    }

    var iterator = state.multiboot_info.getTagTypeIterator(.FRAMEBUFFER_INFO);
    const header = iterator.next() orelse return error.FramebufferTagNotFound;
    const framebuffer: *const multiboot.FramebufferTag = @ptrCast(@alignCast(header));
    if (framebuffer.getType() != .RGB) return error.UnsupportedFramebufferType;
    const rgb = framebuffer.getRgbInfo() orelse return error.MissingRgbInformation;
    return mapBootFramebuffer(.{
        .address = framebuffer.framebuffer_addr,
        .width = framebuffer.framebuffer_width,
        .height = framebuffer.framebuffer_height,
        .pitch = framebuffer.framebuffer_pitch,
        .bits_per_pixel = framebuffer.framebuffer_bpp,
        .red_position = rgb.red_field_position,
        .red_mask_size = rgb.red_mask_size,
        .green_position = rgb.green_field_position,
        .green_mask_size = rgb.green_mask_size,
        .blue_position = rgb.blue_field_position,
        .blue_mask_size = rgb.blue_mask_size,
    });
}

const BootFramebuffer = struct {
    address: u64,
    width: u32,
    height: u32,
    pitch: u32,
    bits_per_pixel: u8,
    red_position: u8,
    red_mask_size: u8,
    green_position: u8,
    green_mask_size: u8,
    blue_position: u8,
    blue_mask_size: u8,
};

fn mapBootFramebuffer(framebuffer: BootFramebuffer) !void {
    const mapper = state.mem_manager.mapper orelse return error.MapperNotInitialized;
    const physical_start = framebuffer.address & ~mem.PAGE_MASK_4K;
    const first_page_offset = framebuffer.address & mem.PAGE_MASK_4K;
    const byte_length = first_page_offset +
        @as(u64, framebuffer.pitch) * framebuffer.height;
    var offset: u64 = 0;
    while (offset < byte_length) : (offset += mem.PAGE_SIZE_4K) {
        const physical = physical_start + offset;
        const virtual = state.mem_manager.memory_layout.kernel_offset | physical;
        if (mapper.translate(virtual) == null) {
            try mapper.map(virtual, physical, mem.PageFlags{
                .writable = true,
                .cache_disable = true,
                .execute_disable = true,
            });
        }
    }

    const virtual_address = (state.mem_manager.memory_layout.kernel_offset | physical_start) +
        first_page_offset;
    try drivers.vga.initFramebuffer(
        @intCast(virtual_address),
        framebuffer.width,
        framebuffer.height,
        framebuffer.pitch,
        framebuffer.bits_per_pixel,
        framebuffer.red_position,
        framebuffer.red_mask_size,
        framebuffer.green_position,
        framebuffer.green_mask_size,
        framebuffer.blue_position,
        framebuffer.blue_mask_size,
    );
    log.info("Framebuffer console initialized: {}x{}x{}", .{
        framebuffer.width,
        framebuffer.height,
        framebuffer.bits_per_pixel,
    });

    // TODO: Replace the MacBook4,1 boot-profile constant with a small hardware
    // quirk table once thad-os can read EFI/DMI system identifiers itself.
}

fn bootStatus(comptime format: []const u8, args: anytype) void {
    var writer = persistentBootLogWriter();
    writer.print("[boot] " ++ format ++ "\n", args) catch {};

    // Once AHCI is online, make each checkpoint survive a reset. This is
    // intentionally synchronous while diagnosing early physical-hardware boot.
    if (drivers.ahci.isReady()) {
        flushPersistentBootLog() catch {};
    }

    // Full-screen clients such as the arcade own the framebuffer contents.
    // Continue persisting checkpoints without scrolling through their UI.
    if (!state.options.vga_printing or !drivers.vga.hasFramebuffer()) return;
    drivers.vga.setColor(.LIGHT_GRAY, .BLACK);
    drivers.vga.print("[boot] " ++ format ++ "\n", args) catch {};

    // TODO: Batch routine boot-log checkpoints once physical bring-up is
    // stable instead of synchronously rewriting the diagnostic region.
}

/// Emits an early-boot checkpoint to every currently available diagnostic
/// sink. Hardware drivers use this before the normal logging stack is useful.
pub fn hardwareBootStatus(comptime format: []const u8, args: anytype) void {
    bootStatus(format, args);
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
        vga_logging: bool = false, // Enable VGA logging by default
    },

    vga_addr: usize,
    stdio_port: drivers.serial_log.Port,
    stdio_baudrate: usize,
    stdio_init: bool,
    keyboard_manager: ?*drivers.keyboard.KeyboardManager = null,
    ps2_ctrl: ?*drivers.ps2.Ps2Controller = null,
    mem_manager: *mem.Manager,
    multiboot_info: multiboot.Multiboot2Info,
    kernel_heap: ?mem.allocator.TrackedAllocator = null,
    kernel_allocator: ?mem.allocator.AllocatorWrapper = null,
    scheduler: ?scheduler.Scheduler = null,

    pub fn switchMap(self: *Kernel) !void {
        if (!self.initilized.mem_manager) {
            log.err("Memory manager not initialized, cannot switch map", .{});
            return error.MemoryManagerNotInitialized;
        }
        if (self.mem_manager.mapper) |mapper| {
            try mapper.switchMap();
        } else {
            log.err("Mapper not initialized, cannot switch map", .{});
            return error.MapperNotInitialized;
        }
    }

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
        recordPersistentBootLog("[memory] Multiboot tags located\n");
        try self.mem_manager.init(
            self.multiboot_info,
            self.testing.page_bitfield,
            hasBootFlag("thad-keep-bootstrap-map"),
        );
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

        self.kernel_heap = try mem.allocator.TrackedAllocator.init(heap_start, heap_size, mapper, mem.PageFlags{
            .present = true,
            .writable = true,
            .user_accessible = false,
            .demand_alloc = false,
        }, self.mem_manager.internal_allocator // For tracking contexts
        );

        // Allocator self-tests deliberately allocate, free, and coalesce a
        // series of heap blocks. Keep that mutation out of normal hardware
        // boot; it is useful only in the dedicated allocator test profile.
        if (self.testing.allocator) try self.kernel_heap.?.tester();

        // TODO: Add a non-mutating heap integrity check that can run during a
        // diagnostic hardware boot without changing allocator topology.

        self.kernel_allocator = try self.kernel_heap.?.createAllocator();

        log.info("Kernel heap initialized", .{});
    }

    pub fn getKernelAllocator(self: *Kernel) ?std.mem.Allocator {
        if (self.kernel_allocator) |*alloc| {
            return alloc.allocator();
        }
        return null;
    }
};

pub var state: Kernel = undefined;
const persistent_boot_log_capacity = 64 * 1024;
var persistent_boot_log: [persistent_boot_log_capacity]u8 = [_]u8{0} ** persistent_boot_log_capacity;
var persistent_boot_log_len: usize = 0;

fn persistentBootLogWrite(_: void, bytes: []const u8) error{}!usize {
    const available = persistent_boot_log.len - persistent_boot_log_len;
    const copy_length = @min(available, bytes.len);
    @memcpy(
        persistent_boot_log[persistent_boot_log_len..][0..copy_length],
        bytes[0..copy_length],
    );
    persistent_boot_log_len += copy_length;
    // TODO: Reserve space for and append a single truncation marker so a full
    // persistent buffer is distinguishable from a cleanly completed log.
    return bytes.len;
}

fn persistentBootLogWriter() std.io.Writer(void, error{}, persistentBootLogWrite) {
    return .{ .context = {} };
}

fn recordPersistentBootLog(message: []const u8) void {
    _ = persistentBootLogWrite({}, message) catch {};
}

fn flushPersistentBootLog() !void {
    if (!drivers.ahci.isReady()) return error.PersistentStorageUnavailable;
    @memset(persistent_boot_log[persistent_boot_log_len..], 0);

    const parameter_names = [_][]const u8{
        "thad-log0",
        "thad-log1",
        "thad-log2",
        "thad-log3",
    };
    var source_offset: usize = 0;
    for (parameter_names) |name| {
        var parameter_buffer: [48]u8 = undefined;
        const value = getBootParam(name, &parameter_buffer) orelse
            return error.PersistentLogExtentMissing;
        var fields = std.mem.splitScalar(u8, value, ':');
        const lba_text = fields.next() orelse return error.InvalidPersistentLogExtent;
        const sectors_text = fields.next() orelse return error.InvalidPersistentLogExtent;
        if (fields.next() != null) return error.InvalidPersistentLogExtent;
        const lba = try std.fmt.parseInt(u64, lba_text, 10);
        const sectors = try std.fmt.parseInt(usize, sectors_text, 10);
        const byte_count = std.math.mul(usize, sectors, 512) catch
            return error.InvalidPersistentLogExtent;
        if (source_offset + byte_count > persistent_boot_log.len) {
            return error.InvalidPersistentLogExtent;
        }
        try drivers.ahci.writeAbsoluteSectors(
            lba,
            persistent_boot_log[source_offset..][0..byte_count],
        );
        source_offset += byte_count;
    }
    if (source_offset != persistent_boot_log.len) return error.PersistentLogSizeMismatch;

    // TODO: Add synchronization around the RAM log before multiple kernel
    // threads are allowed to emit and persist messages concurrently.
}

var panic_buffer: [1024]u8 = undefined;
var panic_allocator: std.mem.Allocator = undefined;
/// helpers
/// NOTE: logging is going to have error levels basically
/// debug = everything
/// log = some stuff
/// warn = information / base level
/// error = errors
pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    _ = trace;
    var tmp_aloc = std.heap.FixedBufferAllocator.init(&panic_buffer);
    panic_allocator = tmp_aloc.allocator();
    print("\n================ PANIC ================\n", .{});
    print("Message: {s}\n", .{msg});
    if (return_address) |addr| {
        print("Return address: 0x{X}\n", .{addr});
    } else {
        print("No return address available.\n", .{});
    }
    // Halt forever
    // TODO @(dleiferives,1ad01822-7fbc-4e0d-b952-2ba435ba3b9f): Make panic
    // relaunch the kernel! ~#
    while (true) {}
}

pub fn print(comptime format: []const u8, args: anytype) void {
    persistentBootLogWriter().print(format, args) catch {};
    // Print logging protect via disabling interrupts
    // arch.cpu.cli();
    if (drivers.vga.initialized) {
        if (state.options.vga_printing) {
            // Print to VGA
            if (state.options.vga_logging) {
                drivers.vga.print(format, args) catch {};
            }
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
    arch_cpu,
    drivers_vga,
    drivers_serial_log,
    drivers_ahci,
    drivers_ps2,
    drivers_ps2_verbose,
    drivers_keyboard,
    drivers_keyboard_verbose,
    drivers_uart_verbose,
    drivers_uart,
    drivers_ata,
    drivers_ata_verbose,
    drivers_ata_hyper_verbose,
    arch_gdt,
    kernel,
    kernel_main,
    kernel_mbr,
    kernel_thread,
    mem,
    mem_verbose,
    mem_layout,
    mem_manager,
    mem_manager_verbose,
    mem_manager_mapper,
    mem_manager_mapper_verbose,
    mem_manager_mapper_translate,
    mapper_tests,
    mem_allocator,
    mem_allocator_verbose,
    mem_page_bitfield,
    mem_page_bitfield_verbose,
    thread_yield,
    irq_page_fault,
    irq,
    std_log_default_scope,
    multiboot_module,
    simple_fs,
    kernel_vfs,
    ext2,
    elf_loader,
    arcade,
};

pub var allowed_scopes: ?[]const LogScope = null;
pub const ALL_SCOPES = [_]LogScope{
    .arcade,
    .mapper_tests,
    .elf_loader,
    .simple_fs,
    .kernel_vfs,
    .ext2,
    // .mem_page_bitfield_verbose,
    // .mem_page_bitfield,
    .mem,
    // .mem_verbose,
    .mem_layout,
    .mem_manager,
    // .mem_manager_verbose,
    // .mem_manager_mapper,
    // .mem_manager_mapper_verbose,
    // .mem_manager_mapper_translate,
    // .mem_allocator,
    // .mem_allocator_verbose,
    .irq,
    // `.thread_yield` is deliberately opt-in: yielding can occur on every
    // scheduler tick and would otherwise consume the persistent log in seconds.
    .irq_page_fault,
    // .drivers_vga,
    // .drivers_serial_log,
    // .drivers_ps2,
    // .drivers_ps2_verbose,
    // .drivers_keyboard,
    .drivers_ata,
    .drivers_ahci,
    // .drivers_ata_verbose,
    // .drivers_ata_verbose,
    // .drivers_keyboard_verbose,
    // .drivers_uart_verbose,
    // .drivers_uart,
    .kernel,
    .kernel_mbr,
    // .kernel_thread,
    // .arch_gdt,
    .kernel_main,
    .std_log_default_scope,
};

fn logSectionForScope(comptime scope_name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, scope_name, "drivers_ahci") or
        std.mem.startsWith(u8, scope_name, "drivers_ata") or
        std.mem.eql(u8, scope_name, "kernel_mbr")) return "storage";
    if (std.mem.startsWith(u8, scope_name, "drivers_ps2") or
        std.mem.startsWith(u8, scope_name, "drivers_keyboard")) return "input";
    if (std.mem.eql(u8, scope_name, "drivers_vga") or
        std.mem.eql(u8, scope_name, "drivers_serial_log") or
        std.mem.startsWith(u8, scope_name, "drivers_uart")) return "console";
    if (std.mem.startsWith(u8, scope_name, "mem")) return "memory";
    if (std.mem.startsWith(u8, scope_name, "irq")) return "interrupts";
    if (std.mem.eql(u8, scope_name, "simple_fs") or
        std.mem.eql(u8, scope_name, "kernel_vfs") or
        std.mem.eql(u8, scope_name, "ext2")) return "filesystem";
    if (std.mem.eql(u8, scope_name, "kernel_thread") or
        std.mem.eql(u8, scope_name, "thread_yield")) return "scheduler";
    if (std.mem.eql(u8, scope_name, "elf_loader")) return "userspace";
    if (std.mem.eql(u8, scope_name, "arcade")) return "arcade";
    return "boot";
}

fn configuredScopeEnabled(comptime scope_name: []const u8) bool {
    if (configured_log_scopes_len == 0) return true;
    const configured = configured_log_scopes[0..configured_log_scopes_len];
    const section = comptime logSectionForScope(scope_name);
    var tokens = std.mem.tokenizeScalar(u8, configured, ',');
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "all") or
            std.mem.eql(u8, token, section) or
            std.mem.eql(u8, token, scope_name)) return true;
    }
    return false;
}

fn legacyScopeEnabled(comptime scope_name: []const u8) bool {
    // Zig's unscoped std.log calls historically bypassed this project's scope
    // allow-list. Keep that compatibility while the remaining call sites are
    // migrated to named subsystem scopes.
    if (std.mem.eql(u8, scope_name, "default")) return true;
    if (allowed_scopes) |allowed| {
        for (allowed) |allowed_scope| {
            if (std.mem.eql(u8, scope_name, @tagName(allowed_scope))) return true;
        }
        return false;
    }
    return true;
}

pub const MAP_TEST_SCOPES = [_]LogScope{
    .mapper_tests,
    .mem_page_bitfield_verbose,
    .mem_page_bitfield,
    .mem,
    .mem_verbose,
    .mem_layout,
    .mem_manager,
    .mem_manager_verbose,
    .mem_manager_mapper,
    .mem_manager_mapper_verbose,
    .irq,
    .irq_page_fault,
    .kernel,
    .kernel_mbr,
    .kernel_main,
    .std_log_default_scope,
};

pub fn logger(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_name = @tagName(scope);
    // Errors bypass scope filters so a narrowly configured diagnostic session
    // cannot hide the failure that actually stopped the boot.
    if (level != .err and
        (!configuredScopeEnabled(scope_name) or !legacyScopeEnabled(scope_name)))
    {
        return;
    }
    if (@intFromEnum(level) > @intFromEnum(log_level) and level != .err) return;

    const prefix_scope = "[" ++ scope_name ++ "]: ";
    const prefix_level = "[" ++ comptime level.asText() ++ "]: ";
    const prefix = if (scope == .default) prefix_level else prefix_scope;
    print("{s}", .{prefix});
    print(format ++ "\n", args);
    if (level == .err and drivers.ahci.isReady()) flushPersistentBootLog() catch {};

    // TODO: Add timestamps and CPU/thread identifiers once a monotonic clock
    // and stable scheduler identities are available.
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

fn testVfsOperations() !void {
    log.info("=== Testing VFS Operations ===", .{});

    // Test opening root directory
    const root_fd = vfs.vfs_open(
        "/",
        vfs.FileDescriptor.O_RDONLY | vfs.FileDescriptor.O_DIRECTORY,
    ) catch |err| {
        log.err("Failed to open root directory: {}", .{err});
        return;
    };
    defer vfs.vfs_close(root_fd) catch {};

    log.info("Opened root directory as fd {}", .{root_fd});

    // Test stat on root
    var root_stat: vfs.VfsStat = undefined;
    vfs.vfs_stat("/", &root_stat) catch |err| {
        log.err("Failed to stat root: {}", .{err});
        return;
    };

    log.info("Root stat: inode={}, mode=0o{o}, size={}", .{
        root_stat.st_ino, root_stat.st_mode, root_stat.st_size,
    });

    // Test readdir on root
    log.info("Reading root directory contents:", .{});

    const ReaddirState = struct {
        count: u32 = 0,

        fn callback(
            dirent: *const vfs.VfsDirent,
            user_data: ?*anyopaque,
        ) vfs.VfsError!void {
            const state_: *@This() = @ptrCast(@alignCast(user_data.?));
            log.info("  {s} (inode={}, type={})", .{
                dirent.d_name, dirent.d_ino, dirent.d_type,
            });
            state_.count += 1;
        }
    };

    var readdir_state = ReaddirState{};
    vfs.vfs_readdir(root_fd, ReaddirState.callback, &readdir_state) catch |err| {
        log.err("Failed to readdir root: {}", .{err});
        return;
    };

    log.info("Found {} entries in root directory", .{readdir_state.count});

    log.info("--- Testing file read: /boot/grub/grub.cfg ---", .{});
    const grub_cfg_path = "/boot/grub/grub.cfg";
    const file_fd = vfs.vfs_open(
        grub_cfg_path,
        vfs.FileDescriptor.O_RDONLY,
    ) catch |err| {
        log.err("Failed to open '{s}': {}", .{ grub_cfg_path, err });
        log.info("--- File read test skipped ---", .{});
        log.info("=== VFS Tests Complete ===", .{});
        return error.FileReadTestSkipped;
    };
    defer vfs.vfs_close(file_fd) catch {};

    log.info("Successfully opened '{s}' as fd {}", .{ grub_cfg_path, file_fd });

    var file_stat: vfs.VfsStat = undefined;
    vfs.vfs_stat(grub_cfg_path, &file_stat) catch |err| {
        log.err("Failed to stat '{s}': {}", .{ grub_cfg_path, err });
        return;
    };

    log.info("Stat for '{s}': size={}", .{ grub_cfg_path, file_stat.st_size });

    if (file_stat.st_size > 0) {
        var read_buffer = (state.getKernelAllocator() orelse return).alloc(
            u8,
            file_stat.st_size,
        ) catch |err| {
            log.err("Failed to allocate buffer for file read: {}", .{err});
            return;
        };
        defer (state.getKernelAllocator() orelse @panic("Could not")).free(read_buffer);

        const bytes_read = vfs.vfs_read(file_fd, read_buffer) catch |err| {
            log.err("Failed to read from '{s}': {}", .{ grub_cfg_path, err });
            return;
        };

        log.info("Read {} bytes from '{s}':", .{ bytes_read, grub_cfg_path });
        log.info("--- FILE CONTENT START ---", .{});
        print("{s}", .{read_buffer[0..bytes_read]});
        log.info("--- FILE CONTENT END ---", .{});
    } else {
        log.info("File '{s}' is empty.", .{grub_cfg_path});
    }

    log.info("--- Testing non-existent file ---", .{});
    const non_existent_path = "/this/file/does/not/exist.txt";
    if (vfs.vfs_open(non_existent_path, vfs.FileDescriptor.O_RDONLY)) |_| {
        log.err(
            "Opened a non-existent file '{s}', which should not happen.",
            .{non_existent_path},
        );
    } else |err| {
        if (err == error.NotFound) {
            log.info(
                "Correctly failed to open non-existent file with error: {}",
                .{err},
            );
        } else {
            log.err(
                "Incorrect error when opening non-existent file: {}",
                .{err},
            );
        }
    }

    log.info("=== VFS Tests Complete ===", .{});
}

fn testMd5Checksum() !void {
    log.info("=== Testing MD5 Checksum ===", .{});

    const kernel_path = "/boot/kernel";
    const block_size = 4096;

    // Open the kernel file
    const file_fd = vfs.vfs_open(
        kernel_path,
        vfs.FileDescriptor.O_RDONLY,
    ) catch |err| {
        log.err("Failed to open '{s}': {}", .{ kernel_path, err });
        log.info("--- MD5 test skipped ---", .{});
        return;
    };
    defer vfs.vfs_close(file_fd) catch {};

    log.info("Successfully opened '{s}' for MD5 calculation", .{kernel_path});

    // Get file size
    var file_stat: vfs.VfsStat = undefined;
    vfs.vfs_stat(kernel_path, &file_stat) catch |err| {
        log.err("Failed to stat '{s}': {}", .{ kernel_path, err });
        return;
    };

    log.info("File size: {} bytes", .{file_stat.st_size});

    // Allocate buffer for reading blocks
    var read_buffer = (state.getKernelAllocator() orelse return).alloc(
        u8,
        block_size,
    ) catch |err| {
        log.err("Failed to allocate buffer for MD5 calculation: {}", .{err});
        return;
    };
    defer (state.getKernelAllocator() orelse @panic("Could not")).free(read_buffer);

    // Initialize MD5 hasher
    var md5_hasher = std.crypto.hash.Md5.init(.{});
    var total_bytes_read: usize = 0;
    var block_count: usize = 0;

    log.info("Reading file in {}KB blocks...", .{block_size / 1024});

    // Read file in blocks and update MD5
    while (true) {
        const bytes_read = vfs.vfs_read(file_fd, read_buffer) catch |err| {
            log.err("Failed to read block from '{s}': {}", .{ kernel_path, err });
            return;
        };

        if (bytes_read == 0) {
            // End of file reached
            break;
        }

        // Update MD5 with this block
        md5_hasher.update(read_buffer[0..bytes_read]);
        total_bytes_read += bytes_read;
        block_count = total_bytes_read / 1024;

        if (block_count % 256 == 0) {
            const mb_processed = total_bytes_read / (1024 * 1024);
            log.info("Processed {} blocks ({} MB)...", .{ block_count, mb_processed });
        }
    }

    // Finalize MD5 hash
    var md5_digest: [16]u8 = undefined;
    md5_hasher.final(&md5_digest);

    // Convert MD5 hash to hex string
    var md5_hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(md5_hex[0..], "{}", .{std.fmt.fmtSliceHexLower(&md5_digest)}) catch |err| {
        log.err("Failed to format MD5 hash: {}", .{err});
        return;
    };

    log.info("--- MD5 Calculation Complete ---", .{});
    log.info("File: {s}", .{kernel_path});
    log.info("Total bytes processed: {}", .{total_bytes_read});
    log.info("Blocks read: {}", .{block_count});
    log.info("MD5 checksum: {s}", .{md5_hex});

    // Verify we read the expected amount
    if (total_bytes_read != file_stat.st_size) {
        log.err("Warning: Expected {} bytes but read {} bytes", .{ file_stat.st_size, total_bytes_read });
    } else {
        log.info("Successfully processed entire file", .{});
    }

    log.info("=== MD5 Test Complete ===", .{});
}

pub fn kputc(ch: u8) void {
    // possibly disable interrupts?
    if (drivers.vga.initialized and state.options.vga_printing) {
        drivers.vga.putChar(ch);
    }
    if (state.stdio_init and drivers.serial_log.isInitialised(state.stdio_port)) {
        drivers.serial_log.write(ch, state.stdio_port);
    }
}
