//
const std = @import("std");
const drivers = @import("drivers");
const mem = @import("mem.zig");

comptime {
    _ = mem.memset;
    _ = mem.memcpy;
}

pub var log_level: std.log.Level = std.log.Level.info;

pub export fn kmain() callconv(.C) void {
    main();
}

pub fn main() void {
    // Set up the scopes for logging
    allowed_scopes = ALL_SCOPES[0..];

    // TODO @(dleiferives,847f8ee2-2c93-44f4-a27d-d7d865c23d1d): Support
    // dynamically finding the vga address from the multiboot header ~#
    // Initilize the VGA driver
    // Run vga tests
    // state.testing.vga = true;
    state.init_vga(0xb8000);

    // state.init_serial(.COM1) catch |err| {
    //     print("Error initializing serial port: {}\n", .{err});
    // };

    std.log.info("VGA and serial port initialized\n", .{});

}

pub const Kernel = struct {
    testing: struct{
        vga: bool,
        serial: bool,
    },
    vga_addr: usize,
    stdio_port: drivers.serial.Port,
    /// must set before calling init_serial
    stdio_baud: u32 = drivers.serial.DEFAULT_BAUDRATE,

    pub inline fn init_vga(self: *Kernel, addr: usize) void {
        self.vga_addr = mem.types.PhysAddr.new(addr).toVirtual().value;
        drivers.vga.init(self.vga_addr);
        if(self.testing.vga) {
                drivers.vga.test_vga() catch {};
        }
    }

    pub inline fn init_serial(self: *Kernel, port: drivers.serial.Port) !void {
        self.stdio_port = port;
        try drivers.serial.init(self.stdio_baud, port);
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
    if (drivers.serial.isInitialised(state.stdio_port)) {
        drivers.serial.print(state.stdio_port, format, args) catch {};

    }
}

pub const LogScope = enum {
    drivers_vga,
    drivers_serial,
    arch_gdt,
    kernel_main,
    std_log_default_scope,
};

pub var allowed_scopes: ?[]const LogScope = null;
pub const ALL_SCOPES = [_]LogScope{
    .drivers_vga,
    .drivers_serial,
    .arch_gdt,
    .kernel_main,
    .std_log_default_scope,
};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Ignore all non-error logging from sources other than
    // .my_project, .nice_library and the default

    // if (!std.mem.eql(u8, @tagName(scope), @tagName(.default))) {
    //     if (allowed_scopes) |allowed| {
    //         var found = false;
    //         for (allowed) |allowed_scope| {
    //             if (std.mem.eql(u8, @tagName(scope), @tagName(allowed_scope))) {
    //                 found = true;
    //                 break;
    //             }
    //         }
    //         if (!found) {
    //             return;
    //         }
    //     }
    // }
    const scope_prefix = if (scope == .default) ": " else " (" ++ @tagName(scope) ++ "): ";
    const prefix = "[" ++ comptime level.asText() ++ "]" ++ scope_prefix;
    switch (level) {
        .debug => {
            if (@intFromEnum(log_level) <= @intFromEnum(std.log.Level.debug)) {
                print("{s}", .{prefix});
                print(format, args);
            }
        },
        .info => {
            if (@intFromEnum(log_level) <= @intFromEnum(std.log.Level.info)) {
                print("{s}", .{prefix});
                print(format, args);
            }
        },
        .warn => {
            if (@intFromEnum(log_level) <= @intFromEnum(std.log.Level.warn)) {
                print("{s}", .{prefix});
                print(format, args);
            }
        },
        .err => {
            if (@intFromEnum(log_level) <= @intFromEnum(std.log.Level.err)) {
                print("{s}", .{prefix});
                print(format, args);
            }
        },
    }
}
