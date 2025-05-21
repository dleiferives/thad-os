const std = @import("std");
const drivers = @import("drivers");
const mem = @import("mem.zig");

comptime {
    _ = mem.memset;
_ = mem.memcpy;
}


pub export fn kmain() callconv(.C) void {
    main();
}

pub fn main() void {
    // Initilize the VGA driver
    drivers.vga.init(
        mem.types.PhysAddr.new(0xb8000).toVirtual().value,
    );
    // Run vga tests
    drivers.vga.test_vga() catch {};
}
