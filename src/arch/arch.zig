const std = @import("std");
const builtin = @import("builtin");

// TODO @(dleiferives,880775e0-38f0-475e-8a82-8bfc6cfea0c8): Create cpu feature
// sets which are determined... will probably never add other cpus just going to
// switch ~#
comptime {
    switch (builtin.cpu.arch) {
        .x86_64 => {},
        else => @compileError("Unsupported architecture"),
    }
}

pub const cpu = switch (builtin.cpu.arch) {
    .x86_64 => @import("x86_64/cpu.zig"),
    else => @compileError("Unsupported architecture"),
};

// pub const irq = switch (builtin.cpu.arch) {
//     .x86_64 => @import("x86_64/irq.zig"),
//     else => @compileError("Unsupported architecture"),
// };

// pub const multiboot = switch (builtin.cpu.arch) {
//     .x86_64 => @import("x86_64/multiboot.zig"),
//     else => @compileError("Unsupported architecture"),
// };

pub const outb = cpu.outb;
pub const inb = cpu.inb;
pub const halt= cpu.halt;
