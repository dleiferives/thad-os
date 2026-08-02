const std = @import("std");
const arch = @import("arch");
const font = @import("font5x7.zig");

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

const Framebuffer = struct {
    address: [*]volatile u8,
    width: usize,
    height: usize,
    pitch: usize,
    bits_per_pixel: u8,
    red_position: u8,
    green_position: u8,
    blue_position: u8,
};

var framebuffer: ?Framebuffer = null;

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
        setEntry(i, entry);
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

pub fn setCell(x: usize, y: usize, ch: u8, fg: u4, bg: u4) void {
    if (x >= WIDTH or y >= HEIGHT) return;
    setEntry(y * WIDTH + x, makeEntry(ch, fg, bg));
}

pub fn initFramebuffer(
    address: usize,
    width: usize,
    height: usize,
    pitch: usize,
    bits_per_pixel: u8,
    red_position: u8,
    green_position: u8,
    blue_position: u8,
) !void {
    if (width < WIDTH * 6 or height < HEIGHT * 8) return error.FramebufferTooSmall;
    if (bits_per_pixel != 24 and bits_per_pixel != 32) return error.UnsupportedFramebuffer;
    framebuffer = .{
        .address = @ptrFromInt(address),
        .width = width,
        .height = height,
        .pitch = pitch,
        .bits_per_pixel = bits_per_pixel,
        .red_position = red_position,
        .green_position = green_position,
        .blue_position = blue_position,
    };
    refresh();

    // TODO: Replace the built-in 5x7 ASCII font with PSF font loading and
    // Unicode glyph lookup once the VFS is available during console setup.
    // TODO: Add dirty-cell batching or a back buffer so large redraws can be
    // flushed without redundant MMIO writes or visible tearing.
}

pub fn refresh() void {
    if (framebuffer == null) return;
    for (0..WIDTH * HEIGHT) |index| renderEntry(index, buffer[index]);
}

fn setEntry(index: usize, entry: u16) void {
    buffer[index] = entry;
    renderEntry(index, entry);
}

fn renderEntry(index: usize, entry: u16) void {
    const fb = framebuffer orelse return;
    const cell_width = fb.width / WIDTH;
    const cell_height = fb.height / HEIGHT;
    const cell_x = (index % WIDTH) * cell_width;
    const cell_y = (index / WIDTH) * cell_height;
    const character: u8 = @truncate(entry);
    const foreground: u4 = @truncate(entry >> 8);
    const background: u4 = @truncate(entry >> 12);
    const foreground_rgb = colorRgb(foreground);
    const background_rgb = colorRgb(background);

    for (0..cell_height) |y| for (0..cell_width) |x| {
        putPixel(fb, cell_x + x, cell_y + y, background_rgb);
    };

    const scale_x = @max(1, cell_width / 6);
    const scale_y = @max(1, cell_height / 8);
    const glyph_width = 5 * scale_x;
    const glyph_height = 7 * scale_y;
    const offset_x = (cell_width -| glyph_width) / 2;
    const offset_y = (cell_height -| glyph_height) / 2;
    for (0..7) |glyph_y| {
        const bits = font.row(character, glyph_y);
        for (0..5) |glyph_x| {
            if (bits & (@as(u8, 1) << @intCast(4 - glyph_x)) == 0) continue;
            for (0..scale_y) |pixel_y| for (0..scale_x) |pixel_x| {
                putPixel(
                    fb,
                    cell_x + offset_x + glyph_x * scale_x + pixel_x,
                    cell_y + offset_y + glyph_y * scale_y + pixel_y,
                    foreground_rgb,
                );
            };
        }
    }
}

fn putPixel(fb: Framebuffer, x: usize, y: usize, rgb: u32) void {
    if (x >= fb.width or y >= fb.height) return;
    const red = (rgb >> 16) & 0xFF;
    const green = (rgb >> 8) & 0xFF;
    const blue = rgb & 0xFF;
    const pixel = (red << @intCast(fb.red_position)) |
        (green << @intCast(fb.green_position)) |
        (blue << @intCast(fb.blue_position));
    const bytes_per_pixel = fb.bits_per_pixel / 8;
    const offset = y * fb.pitch + x * bytes_per_pixel;
    for (0..bytes_per_pixel) |byte| fb.address[offset + byte] = @truncate(pixel >> @intCast(byte * 8));
}

fn colorRgb(color: u4) u32 {
    const palette = [_]u32{
        0x000000, 0x0000AA, 0x00AA00, 0x00AAAA,
        0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
        0x555555, 0x5555FF, 0x55FF55, 0x55FFFF,
        0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
    };
    return palette[color];
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
            setCell(column, row, ' ', fg_color, bg_color);
        },
        else => {
            setCell(column, row, ch, fg_color, bg_color);
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
                setEntry((y - 1) * WIDTH + x, buffer[y * WIDTH + x]);
            }
        }

        // Clear the last line
        const empty = makeEntry(' ', fg_color, bg_color);
        for (0..WIDTH) |x| {
            setEntry((HEIGHT - 1) * WIDTH + x, empty);
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
    try print("{c}\n", .{@as(u8, @truncate(256 + '9'))}); // Should be "9"
    try print("{s}\n", .{"test string"}); // "test string"
    try print("foo{s}bar\n", .{"blah"}); // "foo%sbar"
    try print("foo%sbar\n", .{}); // "foo%sbar"
    try print("{d}\n", .{std.math.minInt(i32)}); // "-2147483648"
    try print("{d}\n", .{std.math.maxInt(i32)}); // "2147483647"
    try print("{}\n", .{0}); // "0"
    try print("{d}\n", .{std.math.maxInt(u32)}); // "4294967295"
    try print("{x}\n", .{0xDEADbeef}); // "deadbeef"
    try print("{x}\n", .{std.math.maxInt(usize)}); // "0xFFFFFFFFFFFFFFFF"
    try print("{d}\n", .{@as(i16, @truncate(0x8000))}); // "-32768"
    try print("{d}\n", .{0x7FFF}); // "65535"
    try print("{d}\n", .{0xFFFF}); // "65535"
    try print("{d}\n", .{std.math.minInt(i64)});
    try print("{d}\n", .{std.math.maxInt(i64)});
    try print("{d}\n", .{std.math.maxInt(u64)});
    log.info("VGA test completed\n", .{});
}
