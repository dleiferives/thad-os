const std = @import("std");
const drivers = @import("drivers");
const kernel = @import("kernel.zig");
const snakes = @import("snakes.zig");
const thread = @import("thread.zig");

const log = std.log.scoped(.arcade);
const Color = drivers.vga.Color;
const Input = drivers.keyboard.InputCode;

const menu_items = [_][]const u8{
    "SNAKES  - the original multi-snake demo",
    "PONG    - W/S or arrow keys",
    "TETRIS  - arrows/WASD, Space to drop",
};

pub fn run() noreturn {
    kernel.state.options.vga_printing = false;
    drivers.vga.setColor(.LIGHT_GRAY, .BLACK);
    var selected: usize = 0;
    kernel.hardwareBootStatus("arcade: entering menu loop", .{});

    while (true) {
        drawMenu(selected);
        kernel.hardwareBootStatus("arcade: menu ready", .{});
        const key = drivers.keyboard.KeyboardBuffer.getc();
        switch (key) {
            'w', 'W', Input.arrow_up => selected = if (selected == 0) menu_items.len - 1 else selected - 1,
            's', 'S', Input.arrow_down => selected = (selected + 1) % menu_items.len,
            '1' => selected = 0,
            '2' => selected = 1,
            '3' => selected = 2,
            '\n', '\r' => {
                log.info("Launching arcade entry: {s}", .{menu_items[selected]});
                switch (selected) {
                    0 => runSnakes(),
                    1 => runPong(),
                    2 => runTetris(),
                    else => unreachable,
                }
            },
            else => {},
        }
    }
}

fn drawMenu(selected: usize) void {
    drivers.vga.clear();
    fillRow(0, Color.LIGHT_BLUE);
    fillRow(drivers.vga.HEIGHT - 1, Color.BLUE);
    drawCentered(2, "THAD-OS", Color.LIGHT_CYAN, Color.BLACK);
    drawCentered(4, "hello, world. what should we play?", Color.WHITE, Color.BLACK);

    drawText(21, 7, "+--------------------------------------+");
    for (menu_items, 0..) |item, index| {
        const row = 9 + index * 3;
        const active = index == selected;
        drawTextColor(23, row, if (active) ">" else " ", if (active) Color.YELLOW else Color.DARK_GRAY, Color.BLACK);
        drawTextColor(26, row, item, if (active) Color.WHITE else Color.LIGHT_GRAY, if (active) Color.BLUE else Color.BLACK);
    }
    drawText(21, 17, "+--------------------------------------+");
    drawCentered(20, "Use arrows or W/S, then Enter", Color.LIGHT_GREEN, Color.BLACK);
    drawCentered(22, "Escape always returns to this menu", Color.DARK_GRAY, Color.BLACK);
    if (kernel.isMacbook41BootProfile() and kernel.state.keyboard_manager == null) {
        drawCentered(23, "USB keyboard support pending", Color.YELLOW, Color.BLACK);
    }
    log.info("Arcade menu ready (selection {})", .{selected});
}

fn runSnakes() void {
    drivers.vga.clear();
    snakes.csnakes.setup_snakes(0);
    drawTextColor(1, drivers.vga.HEIGHT - 1, "ESC: back to menu", Color.WHITE, Color.BLUE);
    log.info("Snakes started", .{});

    while (true) {
        if (drivers.keyboard.KeyboardBuffer.tryGetc() == Input.escape) {
            snakes.csnakes.kill_snake();
            while (snakes.csnakes.snakes_running() != 0) thread.Thread.yield();
            log.info("Snakes returned to menu", .{});
            return;
        }
        // Snakes animate in cooperative worker threads, so the arcade thread
        // must yield even while no key is pending.
        thread.Thread.yield();
    }
}

fn runPong() void {
    const left_x: i16 = 10;
    const right_x: i16 = 69;
    var left_y: i16 = 10;
    var right_y: i16 = 10;
    var ball_x: i16 = 40;
    var ball_y: i16 = 12;
    var ball_dx: i16 = 1;
    var ball_dy: i16 = 1;
    var player_score: u16 = 0;
    var computer_score: u16 = 0;

    log.info("Pong started", .{});
    drawPongArena();
    drawPongState(left_x, left_y, right_x, right_y, ball_x, ball_y, player_score, computer_score);
    while (true) {
        const previous_left_y = left_y;
        while (drivers.keyboard.KeyboardBuffer.tryGetc()) |key| {
            switch (key) {
                Input.escape => {
                    log.info("Pong returned to menu", .{});
                    return;
                },
                'w', 'W', Input.arrow_up => left_y = @max(3, left_y - 1),
                's', 'S', Input.arrow_down => left_y = @min(20, left_y + 1),
                else => {},
            }
        }

        erasePongState(left_x, previous_left_y, right_x, right_y, ball_x, ball_y);
        if (right_y + 1 < ball_y) right_y += 1 else if (right_y + 1 > ball_y) right_y -= 1;
        right_y = std.math.clamp(right_y, 3, 20);

        ball_x += ball_dx;
        ball_y += ball_dy;
        if (ball_y <= 2 or ball_y >= 23) {
            ball_dy = -ball_dy;
            ball_y = std.math.clamp(ball_y, 3, 22);
        }
        if (ball_dx < 0 and ball_x == left_x + 1 and ball_y >= left_y and ball_y < left_y + 3) ball_dx = 1;
        if (ball_dx > 0 and ball_x == right_x - 1 and ball_y >= right_y and ball_y < right_y + 3) ball_dx = -1;

        if (ball_x < left_x) {
            computer_score +%= 1;
            ball_x = 40;
            ball_y = 12;
            ball_dx = 1;
        } else if (ball_x > right_x) {
            player_score +%= 1;
            ball_x = 40;
            ball_y = 12;
            ball_dx = -1;
        }

        drawPongState(left_x, left_y, right_x, right_y, ball_x, ball_y, player_score, computer_score);
        frameDelay(650_000);
    }
}

fn drawPongArena() void {
    drivers.vga.clear();
    drawCentered(0, "THAD PONG", Color.LIGHT_CYAN, Color.BLACK);
    for (10..71) |x| {
        drawCell(x, 2, '-', Color.DARK_GRAY, Color.BLACK);
        drawCell(x, 23, '-', Color.DARK_GRAY, Color.BLACK);
    }
    drawTextColor(1, 24, "W/S or arrows: move   ESC: menu", Color.WHITE, Color.BLUE);
}

fn erasePongState(left_x: i16, left_y: i16, right_x: i16, right_y: i16, ball_x: i16, ball_y: i16) void {
    for (0..3) |dy| {
        drawCell(@intCast(left_x), @intCast(left_y + @as(i16, @intCast(dy))), ' ', Color.WHITE, Color.BLACK);
        drawCell(@intCast(right_x), @intCast(right_y + @as(i16, @intCast(dy))), ' ', Color.WHITE, Color.BLACK);
    }
    drawCell(@intCast(ball_x), @intCast(ball_y), ' ', Color.WHITE, Color.BLACK);
}

fn drawPongState(left_x: i16, left_y: i16, right_x: i16, right_y: i16, ball_x: i16, ball_y: i16, player: u16, computer: u16) void {
    drawTextColor(30, 1, "                    ", Color.YELLOW, Color.BLACK);
    var score_buffer: [32]u8 = undefined;
    const score = std.fmt.bufPrint(&score_buffer, "YOU {d}  :  {d} CPU", .{ player, computer }) catch "score";
    drawCentered(1, score, Color.YELLOW, Color.BLACK);
    for (0..3) |dy| {
        drawCell(@intCast(left_x), @intCast(left_y + @as(i16, @intCast(dy))), '|', Color.LIGHT_GREEN, Color.BLACK);
        drawCell(@intCast(right_x), @intCast(right_y + @as(i16, @intCast(dy))), '|', Color.LIGHT_RED, Color.BLACK);
    }
    drawCell(@intCast(ball_x), @intCast(ball_y), 'O', Color.WHITE, Color.BLACK);
}

const BoardWidth = 10;
const BoardHeight = 18;
const shapes = [7][4]u16{
    .{ 0x00F0, 0x2222, 0x00F0, 0x2222 },
    .{ 0x0660, 0x0660, 0x0660, 0x0660 },
    .{ 0x0270, 0x0262, 0x0720, 0x0232 },
    .{ 0x0360, 0x0462, 0x0360, 0x0462 },
    .{ 0x0630, 0x0264, 0x0630, 0x0264 },
    .{ 0x0710, 0x0226, 0x0470, 0x0322 },
    .{ 0x0740, 0x0622, 0x0170, 0x0223 },
};

fn runTetris() void {
    var board = [_][BoardWidth]u4{[_]u4{0} ** BoardWidth} ** BoardHeight;
    var random_state: u32 = 0x5448_4144;
    var score: u32 = 0;
    var lines: u32 = 0;
    var piece: usize = nextPiece(&random_state);
    var rotation: usize = 0;
    var piece_x: i8 = 3;
    var piece_y: i8 = -1;
    var frame: usize = 0;

    log.info("Tetris started", .{});
    drawTetrisArena();
    while (true) {
        var hard_drop = false;
        while (drivers.keyboard.KeyboardBuffer.tryGetc()) |key| {
            switch (key) {
                Input.escape => {
                    log.info("Tetris returned to menu", .{});
                    return;
                },
                'a', 'A', Input.arrow_left => if (!tetrisCollision(&board, piece, rotation, piece_x - 1, piece_y)) {
                    piece_x -= 1;
                },
                'd', 'D', Input.arrow_right => if (!tetrisCollision(&board, piece, rotation, piece_x + 1, piece_y)) {
                    piece_x += 1;
                },
                'w', 'W', Input.arrow_up => {
                    const next_rotation = (rotation + 1) % 4;
                    if (!tetrisCollision(&board, piece, next_rotation, piece_x, piece_y)) rotation = next_rotation;
                },
                's', 'S', Input.arrow_down => frame = 7,
                ' ' => hard_drop = true,
                else => {},
            }
        }

        if (hard_drop) {
            while (!tetrisCollision(&board, piece, rotation, piece_x, piece_y + 1)) {
                piece_y += 1;
                score += 2;
            }
            frame = 7;
        }

        frame += 1;
        if (frame >= 8) {
            frame = 0;
            if (!tetrisCollision(&board, piece, rotation, piece_x, piece_y + 1)) {
                piece_y += 1;
            } else {
                lockPiece(&board, piece, rotation, piece_x, piece_y);
                const cleared = clearLines(&board);
                lines += cleared;
                score += cleared * cleared * 100;
                piece = nextPiece(&random_state);
                rotation = 0;
                piece_x = 3;
                piece_y = -1;
                if (tetrisCollision(&board, piece, rotation, piece_x, piece_y)) {
                    drawTetris(&board, piece, rotation, piece_x, piece_y, score, lines);
                    drawCentered(12, "GAME OVER - R to restart, ESC for menu", Color.WHITE, Color.RED);
                    while (true) {
                        const key = drivers.keyboard.KeyboardBuffer.getc();
                        if (key == Input.escape) return;
                        if (key == 'r' or key == 'R') return runTetris();
                    }
                }
            }
        }

        drawTetris(&board, piece, rotation, piece_x, piece_y, score, lines);
        frameDelay(220_000);
    }
}

fn nextPiece(state: *u32) usize {
    state.* = state.* *% 1_664_525 +% 1_013_904_223;
    return @intCast(state.* % shapes.len);
}

fn tetrisCollision(board: *const [BoardHeight][BoardWidth]u4, piece: usize, rotation: usize, x: i8, y: i8) bool {
    const mask = shapes[piece][rotation];
    for (0..4) |row| for (0..4) |column| {
        const bit: u4 = @intCast(row * 4 + column);
        if (mask & (@as(u16, 1) << bit) == 0) continue;
        const board_x = x + @as(i8, @intCast(column));
        const board_y = y + @as(i8, @intCast(row));
        if (board_x < 0 or board_x >= BoardWidth or board_y >= BoardHeight) return true;
        if (board_y >= 0 and board[@intCast(board_y)][@intCast(board_x)] != 0) return true;
    };
    return false;
}

fn lockPiece(board: *[BoardHeight][BoardWidth]u4, piece: usize, rotation: usize, x: i8, y: i8) void {
    const mask = shapes[piece][rotation];
    for (0..4) |row| for (0..4) |column| {
        const bit: u4 = @intCast(row * 4 + column);
        if (mask & (@as(u16, 1) << bit) == 0) continue;
        const board_x = x + @as(i8, @intCast(column));
        const board_y = y + @as(i8, @intCast(row));
        if (board_y >= 0 and board_y < BoardHeight and board_x >= 0 and board_x < BoardWidth) {
            board[@intCast(board_y)][@intCast(board_x)] = @intCast(piece + 1);
        }
    };
}

fn clearLines(board: *[BoardHeight][BoardWidth]u4) u32 {
    var cleared: u32 = 0;
    var row: i32 = BoardHeight - 1;
    while (row >= 0) {
        var full = true;
        for (board[@intCast(row)]) |cell| if (cell == 0) {
            full = false;
            break;
        };
        if (!full) {
            row -= 1;
            continue;
        }
        var move_row = row;
        while (move_row > 0) : (move_row -= 1) board[@intCast(move_row)] = board[@intCast(move_row - 1)];
        board[0] = [_]u4{0} ** BoardWidth;
        cleared += 1;
    }
    return cleared;
}

fn drawTetrisArena() void {
    drivers.vga.clear();
    drawTextColor(3, 2, "THAD TETRIS", Color.LIGHT_CYAN, Color.BLACK);
    drawTextColor(3, 11, "W/Up  rotate", Color.LIGHT_GRAY, Color.BLACK);
    drawTextColor(3, 12, "A/D   move", Color.LIGHT_GRAY, Color.BLACK);
    drawTextColor(3, 13, "S     down", Color.LIGHT_GRAY, Color.BLACK);
    drawTextColor(3, 14, "Space drop", Color.LIGHT_GRAY, Color.BLACK);
    drawTextColor(3, 16, "ESC   menu", Color.WHITE, Color.BLUE);

    const origin_x = 35;
    const origin_y = 3;
    for (0..BoardHeight + 2) |row| {
        drawCell(origin_x - 1, origin_y + row -| 1, '|', Color.DARK_GRAY, Color.BLACK);
        drawCell(origin_x + BoardWidth * 2, origin_y + row -| 1, '|', Color.DARK_GRAY, Color.BLACK);
    }
    for (0..BoardWidth * 2 + 2) |column| {
        drawCell(origin_x - 1 + column, origin_y + BoardHeight, '-', Color.DARK_GRAY, Color.BLACK);
    }
}

fn drawTetris(board: *const [BoardHeight][BoardWidth]u4, piece: usize, rotation: usize, piece_x: i8, piece_y: i8, score: u32, lines: u32) void {
    var buffer: [32]u8 = undefined;
    drawTextColor(3, 5, "                  ", Color.YELLOW, Color.BLACK);
    drawTextColor(3, 5, std.fmt.bufPrint(&buffer, "Score: {d}", .{score}) catch "Score", Color.YELLOW, Color.BLACK);
    drawTextColor(3, 7, "                  ", Color.LIGHT_GREEN, Color.BLACK);
    drawTextColor(3, 7, std.fmt.bufPrint(&buffer, "Lines: {d}", .{lines}) catch "Lines", Color.LIGHT_GREEN, Color.BLACK);

    const origin_x = 35;
    const origin_y = 3;
    for (0..BoardHeight) |y| for (0..BoardWidth * 2) |x| {
        drawCell(origin_x + x, origin_y + y, ' ', Color.WHITE, Color.BLACK);
    };
    for (board, 0..) |board_row, y| for (board_row, 0..) |cell, x| {
        if (cell != 0) drawBlock(origin_x + x * 2, origin_y + y, cell);
    };

    const mask = shapes[piece][rotation];
    for (0..4) |row| for (0..4) |column| {
        const bit: u4 = @intCast(row * 4 + column);
        if (mask & (@as(u16, 1) << bit) == 0) continue;
        const x = piece_x + @as(i8, @intCast(column));
        const y = piece_y + @as(i8, @intCast(row));
        if (x >= 0 and x < BoardWidth and y >= 0 and y < BoardHeight) {
            drawBlock(origin_x + @as(usize, @intCast(x)) * 2, origin_y + @as(usize, @intCast(y)), @intCast(piece + 1));
        }
    };
}

fn drawBlock(x: usize, y: usize, color_index: u4) void {
    const palette = [_]Color{ Color.CYAN, Color.YELLOW, Color.MAGENTA, Color.LIGHT_GREEN, Color.RED, Color.BLUE, Color.LIGHT_RED };
    const color = palette[(color_index - 1) % palette.len];
    drawCell(x, y, ' ', Color.WHITE, color);
    drawCell(x + 1, y, ' ', Color.WHITE, color);
}

fn frameDelay(iterations: usize) void {
    var counter: usize = 0;
    while (counter < iterations) : (counter += 1) asm volatile ("pause");
    thread.Thread.yield();
    // TODO: Drive games from monotonic timer ticks and block between frames
    // instead of using CPU-speed-dependent busy waits.
}

fn fillRow(y: usize, background: Color) void {
    for (0..drivers.vga.WIDTH) |x| drawCell(x, y, ' ', Color.WHITE, background);
}

fn drawCentered(y: usize, text: []const u8, foreground: Color, background: Color) void {
    drawTextColor((drivers.vga.WIDTH -| text.len) / 2, y, text, foreground, background);
}

fn drawText(x: usize, y: usize, text: []const u8) void {
    drawTextColor(x, y, text, Color.LIGHT_GRAY, Color.BLACK);
}

fn drawTextColor(x: usize, y: usize, text: []const u8, foreground: Color, background: Color) void {
    for (text, 0..) |character, offset| {
        if (x + offset >= drivers.vga.WIDTH or y >= drivers.vga.HEIGHT) break;
        drawCell(x + offset, y, character, foreground, background);
    }
}

fn drawCell(x: usize, y: usize, character: u8, foreground: Color, background: Color) void {
    if (x >= drivers.vga.WIDTH or y >= drivers.vga.HEIGHT) return;
    drivers.vga.setCell(x, y, character, @intFromEnum(foreground), @intFromEnum(background));
}
