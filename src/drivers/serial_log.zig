const std = @import("std");
const Writer = std.io.Writer;
const arch = @import("arch");
const log = std.log.scoped(.drivers_serial_log);

const LCR: u16 = 3;
const BAUD_MAX: u32 = 115200;
const CHAR_LEN: u8 = 8;
const SINGLE_STOP_BIT: bool = true;
const PARITY_BIT: bool = false;
pub const DEFAULT_BAUDRATE = 38400;

pub const Port = enum(u16) {
    COM1 = 0x3F8,
    COM2 = 0x2F8,
    COM3 = 0x3E8,
    COM4 = 0x2E8,
};

const PortStates = struct {
    COM1: bool,
    COM2: bool,
    COM3: bool,
    COM4: bool,
};

var portStates: PortStates = PortStates{
    .COM1 = false,
    .COM2 = false,
    .COM3 = false,
    .COM4 = false,
};

pub const SerialError = error{
    InvalidBaudRate,
    InvalidCharacterLength,
};


fn lcrValue(char_len: u8, stop_bit: bool, parity_bit: bool, msb: u1) SerialError!u8 {
    if (char_len != 0 and (char_len < 5 or char_len > 8))
        return SerialError.InvalidCharacterLength;
    // Set the msb and OR in all arguments passed
    const val = char_len & 0x3 |
        @as(u8, @intCast(@intFromBool(stop_bit))) << 2 |
        @as(u8, @intCast(@intFromBool(parity_bit))) << 3 |
        @as(u8,@intCast(msb)) << 7;
    return val;
}

fn baudDivisor(baud: u32) SerialError!u16 {
    if (baud > BAUD_MAX or baud == 0)
        return SerialError.InvalidBaudRate;
    return @truncate(BAUD_MAX / baud);
}

fn transmitIsEmpty(port: Port) bool {
    return arch.inb(@intFromEnum(port) + 5) & 0x20 > 0;
}


pub inline fn write(char: u8, port: Port) void {
    while (!transmitIsEmpty(port)) {
        arch.halt();
    }
    arch.outb(@intFromEnum(port), char);
}


pub fn init(baud: u32, port: Port) SerialError!void {
    log.info("Serial port initialisation started",.{});
    const divisor: u16 = try baudDivisor(baud);
    const port_int = @intFromEnum(port);
    arch.outb(port_int + LCR, lcrValue(0, false, false, 1) catch {
        @panic("Failed to set serial properties");
    });
    arch.outb(port_int, @truncate(divisor));
    arch.outb(port_int + 1, @truncate(divisor >> 8));
    arch.outb(port_int + LCR, lcrValue(CHAR_LEN, SINGLE_STOP_BIT, PARITY_BIT, 0) catch {
        @panic("Failed to set serial properties");
    });
    arch.outb(port_int + 1, @as(u8, 0));

    switch (port) {
        Port.COM1 => portStates.COM1 = true,
        Port.COM2 => portStates.COM2 = true,
        Port.COM3 => portStates.COM3 = true,
        Port.COM4 => portStates.COM4 = true,
    }
}


pub fn isInitialised(port: Port) bool {
    switch (port) {
        Port.COM1 => return portStates.COM1,
        Port.COM2 => return portStates.COM2,
        Port.COM3 => return portStates.COM3,
        Port.COM4 => return portStates.COM4,
    }
}

fn writerFn(port: Port, bytes: []const u8) error{}!usize {
    for (bytes) |ch| {
        write(ch, port);
    }
    return bytes.len;
}

pub fn writer(port: Port) Writer(Port, error{}, writerFn) {
    return .{ .context = port };
}

pub fn print(port: Port, comptime format: []const u8, args: anytype) !void {
    try writer(port).print(format, args);
}
