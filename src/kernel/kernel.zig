//
const std = @import("std");
const drivers = @import("drivers");
const mem = @import("mem.zig");
const log = std.log.scoped(.kernel);
const multiboot = @import("multiboot.zig");

comptime {
    _ = mem.memset;
    _ = mem.memcpy;

    // early setting the container allocator to be linked to the kernel
    _ = mem.Manager;
}

pub var log_level: std.log.Level = std.log.Level.info;

pub export fn kmain() callconv(.C) void {
    main() catch |err| {
        log.err("Kernel main failed: {}", .{err});
        panic("Kernel main failed", null, null);
    };
}

pub fn main() !void {
    allowed_scopes = ALL_SCOPES[0..];

    // Load the symbols from the linker!
    state.multiboot_info_init();

    // Initilize the VGA driver
    state.testing.vga = true;
    state.vga_init(0xb8000);

    // Initialize the serial driver
    state.serial_init(drivers.serial.DEFAULT_BAUDRATE, .COM1);
    state.mem_manager.memory_layout.log();

    // // log.info("Info header {x}",.{@as(u64,@intFromPtr(multiboot.loadInfoHeader(state.mem_manager.memory_layout.kernel_offset)))});
    // log.info("Info header {}",.{multiboot.loadInfoHeader(state.mem_manager.memory_layout.kernel_offset)});
    // var mbi = multiboot.Multiboot2Info.init(multiboot.loadInfoHeader(state.mem_manager.memory_layout.kernel_offset));
    // mbi.dumpInfo(drivers.serial.writer(state.stdio_port)) catch {};

    try state.mem_manager_init();
    log.info("Kernel loaded", .{});


}

pub const Kernel = struct {
    testing: struct {
        vga: bool,

    },
    initilized: struct {
        mem_layout: bool = false,
        multiboot_info: bool = false,
        vga: bool = false,
        serial: bool = false,
    },
    vga_addr: usize,
    stdio_port: drivers.serial.Port,
    stdio_baudrate: usize,
    stdio_init: bool,
    mem_manager: mem.Manager,
    multiboot_info: multiboot.Multiboot2Info,

    pub inline fn mem_manager_init(self: *Kernel) !void {
        self.mem_manager= mem.Manager.new();
        self.initilized.mem_layout = true;
        self.multiboot_info_init();
        try self.mem_manager.init(self.multiboot_info);
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

    pub inline fn serial_init(self: *Kernel, baudrate: usize, port: drivers.serial.Port) void {
        log.debug("Initialising serial driver {} with baudrate {d}", .{port, baudrate});
        self.stdio_init = true;
        self.stdio_port = port;
        self.stdio_baudrate = baudrate;
        drivers.serial.init(baudrate, port) catch {};
        log.info("Serial driver initialised", .{});
        self.initilized.serial = true;
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
    if (drivers.vga.initialized) {
        drivers.vga.print(format, args) catch {};
    }
    if (state.stdio_init) {
        if (drivers.serial.isInitialised(state.stdio_port)) {
                drivers.serial.print(state.stdio_port, format, args) catch {};
        }
   }
}

pub const LogScope = enum {
    drivers_vga,
    drivers_serial,
    arch_gdt,
    kernel,
    kernel_main,
    std_log_default_scope,
};

pub var allowed_scopes: ?[]const LogScope = null;
pub const ALL_SCOPES = [_]LogScope{
    .drivers_vga,
    .drivers_serial,
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
    const scope_prefix = if (scope == .default) ": " else " (" ++ @tagName(scope) ++ "): ";
    const prefix = "[" ++ comptime level.asText() ++ "]" ++ scope_prefix;
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
                print("{s}", .{prefix});
                print(format ++ "\n", args);
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
