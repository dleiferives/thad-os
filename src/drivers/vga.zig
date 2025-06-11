const std = @import("std");
const arch = @import("arch");

const Writer = std.io.Writer;
const log = std.log.scoped(.drivers_vga);

/// Screen dimensions
// TODO @(dleiferives,63b19c29-b7ac-4f1d-aaa8-fa9a8121754b): should grab this
// stuff from the multiboot header... and like... but I'm not going to. that's a
// pain! ~#
pub const WIDTH = 80;
pub const HEIGHT = 25;
pub const TAB_WIDTH = 4;

/// VGA Colors
pub const Color = enum(u4) {
    BLACK = 0,
    BLUE = 1,
    GREEN = 2,
    CYAN = 3,
    RED = 4,
    MAGENTA = 5,
    BROWN = 6,
    LIGHT_GRAY = 7,
    DARK_GRAY = 8,
    LIGHT_BLUE = 9,
    LIGHT_GREEN = 10,
    LIGHT_CYAN = 11,
    LIGHT_RED = 12,
    LIGHT_MAGENTA = 13,
    YELLOW = 14,
    WHITE = 15,
};

/// Global state
pub var buffer: [*]volatile u16 = undefined;
pub var row: usize = 0;
pub var column: usize = 0;
var fg_color: u4 = @intFromEnum(Color.LIGHT_GRAY);
var bg_color: u4 = @intFromEnum(Color.BLACK);
pub var initialized: bool = false;

pub fn init(buffer_addr: usize) void {
    if (initialized) return;

    buffer = @ptrFromInt(buffer_addr);
    row = 0;
    column = 0;
    fg_color = @intFromEnum(Color.LIGHT_GRAY);
    bg_color = @intFromEnum(Color.BLACK);

    
    clear();
    initialized = true;
}

pub fn clear() void {
    const entry = makeEntry(' ', fg_color, bg_color);
    for (0..WIDTH * HEIGHT) |i| {
        buffer[i] = entry;
    }
    row = 0;
    column = 0;
}

pub fn setColor(foreground: Color, background: Color) void {
    fg_color = @intFromEnum(foreground);
    bg_color = @intFromEnum(background);
}

pub fn makeEntry(ch: u8, fg: u4, bg: u4) u16 {
    return @as(u16, ch) | (@as(u16, fg) << 8) | (@as(u16, bg) << 12);
}

pub fn putChar(ch: u8) void {
    // TODO @(dleiferives,862ce5ad-e65c-45a7-969d-aa49222a8014): add cli and sti
    // here ~#
    arch.irq.irq.disable();
    switch (ch) {
        '\n' => {
            column = 0;
            row += 1;
        },
        '\r' => {
            column = 0;
        },
        '\t' => {
            column = (column + TAB_WIDTH) & ~@as(usize, TAB_WIDTH - 1);
        },
        '\x08' => { // Backspace
            if (column > 0) column -= 1;
            buffer[row * WIDTH + column] = makeEntry(' ', fg_color, bg_color);
        },
        else => {
            buffer[row * WIDTH + column] = makeEntry(ch, fg_color, bg_color);
            column += 1;
        },
    }

    // Handle wrapping
    if (column >= WIDTH) {
        column = 0;
        row += 1;
    }

    // Handle scrolling
    if (row >= HEIGHT) {
        // Move everything up one line
        for (1..HEIGHT) |y| {
            for (0..WIDTH) |x| {
                buffer[(y-1) * WIDTH + x] = buffer[y * WIDTH + x];
            }
        }

        // Clear the last line
        const empty = makeEntry(' ', fg_color, bg_color);
        for (0..WIDTH) |x| {
            buffer[(HEIGHT-1) * WIDTH + x] = empty;
        }

        row = HEIGHT - 1;
    }
    arch.irq.irq.enable();
}

pub fn putStr(str: []const u8) void {
    for (str) |ch| {
        putChar(ch);
    }
}

fn writerFn(_: void, bytes: []const u8) error{}!usize {
    putStr(bytes);
    return bytes.len;
}

pub fn writer() Writer(void, error{}, writerFn) {
    return .{ .context = {} };
}

pub fn print(comptime format: []const u8, args: anytype) !void {
    try writer().print(format, args);
}

pub fn deinit() void {
    if (!initialized) return;

    clear();
    initialized = false;
}

pub inline fn test_vga() !void {
    log.info("VGA test started\n", .{});
    try print("{c}\n", .{'a'}); // should be "a"
    try print("{c}\n", .{'Q'}); // should be "Q"
    try print("{c}\n", .{@as(u8,@truncate(256 + '9'))}); // Should be "9"
    try print("{s}\n", .{"test string"}); // "test string"
    try print("foo{s}bar\n", .{"blah"}); // "foo%sbar"
    try print("foo%sbar\n", .{}); // "foo%sbar"
    try print("{d}\n", .{std.math.minInt(i32)}); // "-2147483648"
    try print("{d}\n", .{std.math.maxInt(i32)}); // "2147483647"
    try print("{}\n", .{0}); // "0"
    try print("{d}\n", .{std.math.maxInt(u32)}); // "4294967295"
    try print("{x}\n", .{0xDEADbeef}); // "deadbeef"
    try print("{x}\n", .{std.math.maxInt(usize)}); // "0xFFFFFFFFFFFFFFFF"
    try print("{d}\n", .{@as(i16,@truncate(0x8000))}); // "-32768"
    try print("{d}\n", .{0x7FFF}); // "65535"
    try print("{d}\n", .{0xFFFF}); // "65535"
    try print("{d}\n", .{std.math.minInt(i64)});
    try print("{d}\n", .{std.math.maxInt(i64)});
    try print("{d}\n", .{std.math.maxInt(u64)});
    log.info("VGA test completed\n", .{});
}
