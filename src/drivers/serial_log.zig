// TODO @(dleiferives,6f0e1aa5-c4a0-4f9c-a4f8-2fcd09badd0c): update this to be
// more of my code and less of where I nicked it from pluto zig os ~#
const std = @import("std");
const Writer = std.io.Writer;
const arch = @import("arch");
const log = std.log.scoped(.drivers_serial_log);

/// The I/O port numbers associated with each serial port
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

/// Errors thrown by serial functions
pub const SerialError = error{
    /// The given baudrate is outside of the allowed range
    InvalidBaudRate,

    /// The given char len is outside the allowed range.
    InvalidCharacterLength,
};

/// The LCR is the line control register
const LCR: u16 = 3;

/// Maximum baudrate
const BAUD_MAX: u32 = 115200;

/// 8 bits per serial character
const CHAR_LEN: u8 = 8;

/// One stop bit per transmission
const SINGLE_STOP_BIT: bool = true;

/// No parity bit
const PARITY_BIT: bool = false;

/// Default baudrate
pub const DEFAULT_BAUDRATE = 38400;

///
/// Compute a value that encodes the serial properties
/// Used by the line control register
///
/// Arguments:
///     IN char_len: u8 - The number of bits in each individual byte. Must be 0 or between 5 and 8 (inclusive).
///     IN stop_bit: bool - If a stop bit should included in each transmission.
///     IN parity_bit: bool - If a parity bit should be included in each transmission.
///     IN msb: u1 - The most significant bit to use.
///
/// Return: u8
///     The computed lcr value.
///
/// Error: SerialError
///     InvalidCharacterLength - If the char_len is less than 5 or greater than 8.
///
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

///
/// The serial controller accepts a divisor rather than a raw baudrate, as that is more space efficient.
/// This function computes the divisor for a desired baudrate. Note that multiple baudrates can have the same divisor.
///
/// Arguments:
///     baud: u32 - The desired baudrate. Must be greater than 0 and less than BAUD_MAX.
///
/// Return: u16
///     The computed divisor.
///
/// Error: SerialError
///     InvalidBaudRate - If baudrate is 0 or greater than BAUD_MAX.
///
fn baudDivisor(baud: u32) SerialError!u16 {
    if (baud > BAUD_MAX or baud == 0)
        return SerialError.InvalidBaudRate;
    return @truncate(BAUD_MAX / baud);
}

///
/// Checks if the transmission buffer is empty, which means data can be sent.
///
/// Arguments:
///     port: Port - The port to check.
///
/// Return: bool
///     If the transmission buffer is empty.
///
fn transmitIsEmpty(port: Port) bool {
    return arch.inb(@intFromEnum(port) + 5) & 0x20 > 0;
}


///
/// Write a byte to a serial port. Waits until the transmission queue is empty.
///
/// Arguments:
///     char: u8 - The byte to send.
///     port: Port - The port to send the byte to.
///
pub inline fn write(char: u8, port: Port) void {
    while (!transmitIsEmpty(port)) {
        arch.halt();
    }
    arch.outb(@intFromEnum(port), char);
}




///
/// Initialise a serial port to a certain baudrate
///
/// Arguments
///  IN baud: u32 - The baudrate to use. Cannot be more than MAX_BAUDRATE
///  IN port: Port - The port to initialise
///
/// Error: SerialError
///     InvalidBaudRate - The baudrate is 0 or greater than BAUD_MAX.
///
pub fn init(baud: u32, port: Port) SerialError!void {
    log.info("Serial port initialisation started",.{});
    // The baudrate is sent as a divisor of the max baud rate
    const divisor: u16 = try baudDivisor(baud);
    const port_int = @intFromEnum(port);
    // Send a byte to start setting the baudrate
    arch.outb(port_int + LCR, lcrValue(0, false, false, 1) catch {
        @panic("Failed to set serial properties");
    });
    // Send the divisor's lsb
    arch.outb(port_int, @truncate(divisor));
    // Send the divisor's msb
    arch.outb(port_int + 1, @truncate(divisor >> 8));
    // Send the properties to use
    arch.outb(port_int + LCR, lcrValue(CHAR_LEN, SINGLE_STOP_BIT, PARITY_BIT, 0) catch {
        @panic("Failed to set serial properties");
    });
    // Stop initialisation
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


/// Writer function for std.io.Writer interface
fn writerFn(port: Port, bytes: []const u8) error{}!usize {
    for (bytes) |ch| {
        write(ch, port);
    }
    return bytes.len;
}

/// Get a writer for printing formatted strings
pub fn writer(port: Port) Writer(Port, error{}, writerFn) {
    return .{ .context = port };
}

/// Print a formatted string to the VGA buffer
pub fn print(port: Port, comptime format: []const u8, args: anytype) !void {
    try writer(port).print(format, args);
}
