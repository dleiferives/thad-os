const std = @import("std");
pub const gdt = @import("gdt.zig");

const log = std.log.scoped(.arch_cpu);

/// Read a byte from the specified port
pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

/// Writes a byte to the specified port
pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={al}" (-> u16),
        : [port] "N{dx}" (port),
    );
}


pub inline fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "r" (value),
          [port] "N{dx}" (port),
    );
}


/// Halt the CPU until the next interrupt
pub inline fn halt() void {
    asm volatile ("hlt");
}

/// disable interrupts
pub inline fn cli() void {
    asm volatile ("cli");
}

/// enable interrupts
pub inline fn sti() void {
    asm volatile ("sti");
}

/// Check if the CPU is currently in an interrupt context
// TODO @(dleiferives,6f0ab042-c201-4f07-83d1-a7ead4c6afb3): remove duplication ~#
pub inline fn in_interrupt() bool {
    var flags: u64 = 0;
    asm volatile (
        \\pushfq
        \\popq %[flags]
        : [flags] "=r" (flags));
    return (flags & 0x200) != 0; // Check the IF flag
}
