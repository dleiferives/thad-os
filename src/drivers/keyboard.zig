// keyboard.zig
const std = @import("std");
const Ps2ControllerModule = @import("ps2.zig");
const Ps2Controller = Ps2ControllerModule.Ps2Controller;
const ps2 = Ps2ControllerModule.ps2;
const Ps2Error = Ps2ControllerModule.Ps2Error;
const DeviceType = Ps2ControllerModule.DeviceType;
const log = std.log.scoped(.drivers_keyboard);
const log_verbose = std.log.scoped(.drivers_keyboard_verbose);

const kernel = @import("kernel");
const Mutex = kernel.mutex.Mutex;
const ThreadQueue = kernel.thread_queue.ThreadQueue;
const thread = kernel.thread;


const arch = @import("arch");
var ps2_ctrl : *Ps2Controller  = undefined;
var kbd_mgr  : *KeyboardManager = undefined;


// Based on common Scan Code Set 2 values.
// TODO @(dleiferives,794619e9-698f-40b4-8108-2bad486f7e48): add all of the
// scancodes and their parsing ~#
const Key = enum {
    Unknown,
    Escape,
    N1, N2, N3, N4, N5, N6, N7, N8, N9, N0,
    Minus,
    Equals,
    Backspace,
    Tab,
    Q, W, E, R, T, Y, U, I, O, P,
    LeftBracket,
    RightBracket,
    Enter,
    LeftCtrl,
    A, S, D, F, G, H, J, K, L,
    Semicolon,
    Apostrophe,
    Grave, // Backtick `
    LeftShift,
    Backslash,
    Z, X, C, V, B, N, M,
    Comma,
    Period,
    Slash,
    RightShift,
    KeypadAsterisk,
    LeftAlt,
    Space,
    CapsLock,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10,
    NumLock,
    ScrollLock,

    Keypad7,
    Keypad8,
    Keypad9,
    KeypadMinus,
    Keypad4,
    Keypad5,
    Keypad6,
    KeypadPlus,
    Keypad1,
    Keypad2,
    Keypad3,
    Keypad0,
    KeypadPeriod,
    KeypadSlash,
    KeypadEnter,
    F11, F12,

    E0_KeypadEnter,
    E0_RightCtrl,
    E0_KeypadSlash,
    E0_PrintScreen,
    E0_RightAlt,
    E0_Home,
    E0_ArrowUp,
    E0_PageUp,
    E0_ArrowLeft,
    E0_ArrowRight,
    E0_End,
    E0_ArrowDown,
    E0_PageDown,
    E0_Insert,
    E0_Delete,
    E0_LeftSuper,
    E0_RightSuper,
    E0_Apps, // Menu key
    E0_Power,
    E0_Sleep,
    E0_Wake,

    // Pause/Break is: E1, 1D, 45, E1, 9D, C5
    PauseBreak,

    KeyRelease, // I really don't know how to handle this yet... i'm just going to ignore it

    pub fn toChar(key: Key, shift: bool, caps_lock: bool) ?u8 {
        const is_alpha = switch (key) {
            .A, .B, .C, .D, .E, .F, .G, .H, .I, .J, .K, .L, .M,
            .N, .O, .P, .Q, .R, .S, .T, .U, .V, .W, .X, .Y, .Z,
            => true,
            else => false,
        };

        const effective_shift = if (is_alpha) (shift != caps_lock) else shift;

        if (!effective_shift) {
            return switch (key) {
                .A => 'a', .B => 'b', .C => 'c', .D => 'd', .E => 'e',
                .F => 'f', .G => 'g', .H => 'h', .I => 'i', .J => 'j',
                .K => 'k', .L => 'l', .M => 'm', .N => 'n', .O => 'o',
                .P => 'p', .Q => 'q', .R => 'r', .S => 's', .T => 't',
                .U => 'u', .V => 'v', .W => 'w', .X => 'x', .Y => 'y',
                .Z => 'z',
                .N0 => '0', .N1 => '1', .N2 => '2', .N3 => '3', .N4 => '4',
                .N5 => '5', .N6 => '6', .N7 => '7', .N8 => '8', .N9 => '9',
                .Space => ' ', .Comma => ',', .Period => '.', .Slash => '/',
                .Semicolon => ';', .Apostrophe => '\'', .LeftBracket => '[',
                .RightBracket => ']', .Backslash => '\\', .Minus => '-',
                .Equals => '=', .Grave => '`',
                .Keypad0 => '0', .Keypad1 => '1', .Keypad2 => '2', .Keypad3 => '3',
                .Keypad4 => '4', .Keypad5 => '5', .Keypad6 => '6', .Keypad7 => '7',
                .Keypad8 => '8', .Keypad9 => '9',
                .KeypadSlash => '/', .KeypadAsterisk => '*', .KeypadMinus => '-',
                .KeypadPlus => '+', .KeypadPeriod => '.',
                .Enter => '\n', .E0_KeypadEnter => '\n', .Tab => '\t',
                else => null,
            };
        } else { // Shift is pressed or CapsLock is on for alpha
            return switch (key) {
                .A => 'A', .B => 'B', .C => 'C', .D => 'D', .E => 'E',
                .F => 'F', .G => 'G', .H => 'H', .I => 'I', .J => 'J',
                .K => 'K', .L => 'L', .M => 'M', .N => 'N', .O => 'O',
                .P => 'P', .Q => 'Q', .R => 'R', .S => 'S', .T => 'T',
                .U => 'U', .V => 'V', .W => 'W', .X => 'X', .Y => 'Y',
                .Z => 'Z',
                .N0 => ')', .N1 => '!', .N2 => '@', .N3 => '#', .N4 => '$',
                .N5 => '%', .N6 => '^', .N7 => '&', .N8 => '*', .N9 => '(',
                .Space => ' ', .Comma => '<', .Period => '>', .Slash => '?',
                .Semicolon => ':', .Apostrophe => '"', .LeftBracket => '{',
                .RightBracket => '}', .Backslash => '|', .Minus => '_',
                .Equals => '+', .Grave => '~',
                .Keypad0 => '0', .Keypad1 => '1', .Keypad2 => '2', .Keypad3 => '3',
                .Keypad4 => '4', .Keypad5 => '5', .Keypad6 => '6', .Keypad7 => '7',
                .Keypad8 => '8', .Keypad9 => '9',
                .KeypadSlash => '/', .KeypadAsterisk => '*', .KeypadMinus => '-',
                .KeypadPlus => '+', .KeypadPeriod => '.',
                .Enter => '\n', .E0_KeypadEnter => '\n', .Tab => '\t',
                else => null,
            };
        }
    }
};

fn scancodeSet2ToKey(sc: u8, e0_prefix: bool) Key {
    if (e0_prefix) {
        return switch (sc) {
            0x1C => .E0_KeypadEnter,
            0x1D => .E0_RightCtrl,
            0x35 => .E0_KeypadSlash,
            // 0x37 => .E0_PrintScreen, // Often E0, 2A, E0, 37 for make
            0x38 => .E0_RightAlt,
            0x47 => .E0_Home,
            0x48 => .E0_ArrowUp,
            0x49 => .E0_PageUp,
            0x4B => .E0_ArrowLeft,
            0x4D => .E0_ArrowRight,
            0x4F => .E0_End,
            0x50 => .E0_ArrowDown,
            0x51 => .E0_PageDown,
            0x52 => .E0_Insert,
            0x53 => .E0_Delete,
            0x5B => .E0_LeftGui,
            0x5C => .E0_RightGui,
            0x5D => .E0_Apps,
            0x5E => .E0_Power,
            0x5F => .E0_Sleep,
            0x63 => .E0_Wake,
            else => .Unknown,
        };
    } else {
        return switch (sc) {
            0x01 => .F9, // Note: F-keys can vary
            0x03 => .F5,
            0x04 => .F3,
            0x05 => .F1,
            0x06 => .F2,
            0x07 => .F12,
            0x09 => .F10,
            0x0A => .F8,
            0x0B => .F6,
            0x0C => .F4,
            0x0D => .Tab,
            0x0E => .Grave,
            0x11 => .LeftAlt,
            0x12 => .LeftShift,
            0x14 => .LeftCtrl,
            0x15 => .Q,
            0x16 => .N1,
            0x1A => .Z,
            0x1B => .S,
            0x1C => .A,
            0x1D => .W,
            0x1E => .N2,
            0x21 => .C,
            0x22 => .X,
            0x23 => .D,
            0x24 => .E,
            0x25 => .N4,
            0x26 => .N3,
            0x29 => .Space,
            0x2A => .V,
            0x2B => .F,
            0x2C => .T,
            0x2D => .R,
            0x2E => .N5,
            0x31 => .N,
            0x32 => .B,
            0x33 => .H,
            0x34 => .G,
            0x35 => .Y,
            0x36 => .N6,
            0x3A => .M,
            0x3B => .J,
            0x3C => .U,
            0x3D => .N7,
            0x3E => .N8,
            0x41 => .Comma,
            0x42 => .K,
            0x43 => .I,
            0x44 => .O,
            0x45 => .N0,
            0x46 => .N9,
            0x49 => .Period,
            0x4A => .Slash,
            0x4B => .L,
            0x4C => .Semicolon,
            0x4D => .P,
            0x4E => .Minus,
            0x52 => .Apostrophe,
            0x54 => .LeftBracket,
            0x55 => .Equals,
            0x58 => .CapsLock,
            0x59 => .RightShift,
            0x5A => .Enter,
            0x5B => .RightBracket,
            0x5D => .Backslash,
            0x66 => .Backspace,
            0x69 => .Keypad1, // End !NumLock
            0x6A => .Keypad4, // Left !NumLock
            0x6B => .Keypad7, // Home !NumLock
            0x6C => .Keypad0, // Ins !NumLock
            0x6D => .KeypadPeriod, // Del !NumLock
            0x6E => .Keypad2, // Down !NumLock
            0x6F => .Keypad5,
            0x70 => .Keypad6, // Right !NumLock
            0x71 => .Keypad8, // Up !NumLock
            0x72 => .Escape,
            0x73 => .NumLock,
            0x74 => .F11,
            0x75 => .KeypadPlus,
            0x76 => .F7,
            0x77 => .Keypad3, // PageDown !NumLock
            0x78 => .KeypadMinus,
            0x79 => .KeypadAsterisk,
            0x7A => .Keypad9, // PageUp !NumLock
            0x7B => .ScrollLock,
            0x7E => .KeypadEnter,
            0xDF => .KeyRelease,
            else => .Unknown,
        };
    }
}

pub const KeyEvent = struct {
    key: Key,
    char: ?u8,
    pressed: bool, // True for make, false for break
};

pub const Ps2KeyboardDevice = struct {
    port_index: u1,
    controller: *Ps2Controller,
    device_type: DeviceType,

    // State for scan code processing
    e0_prefix: bool = false,
    f0_prefix: bool = false, // For break codes (0xF0, <make_code>)

    // Modifier and lock states
    left_shift_pressed: bool = false,
    right_shift_pressed: bool = false,
    left_ctrl_pressed: bool = false,
    right_ctrl_pressed: bool = false,
    left_alt_pressed: bool = false,
    right_alt_pressed: bool = false,
    left_super_pressed: bool = false,
    right_super_pressed: bool = false,

    caps_lock_on: bool = false,
    num_lock_on: bool = false,
    scroll_lock_on: bool = false,

    const Self = @This();

    pub fn init(
        port_index: u1,
        controller: *Ps2Controller,
        device_type: DeviceType,
    ) Self {
        return Self{
            .port_index = port_index,
            .controller = controller,
            .device_type = device_type,
        };
    }

    /// Proccesses a raw scancode from the keyboard.
    pub fn processScancode(self: *Self, scancode: u8) ?KeyEvent {
        var event: ?KeyEvent = null;

        // Handle pause break...
        if (scancode == 0xE1) {
            // I'm not going to do that!
            log_verbose.info(" (Pause/Break E1 prefix) ", .{});
            return null;
        }

        if (scancode == 0xE0) {
            self.e0_prefix = true;
            return null; // Wait for next byte
        }

        if (scancode == 0xF0) {
            self.f0_prefix = true;
            return null;
        }

        const key_pressed = !self.f0_prefix;
        const current_key = scancodeSet2ToKey(scancode, self.e0_prefix);

        if (current_key != .Unknown) {
            var char_val: ?u8 = null;

            // Update modifier states
            switch (current_key) {
                .LeftShift => self.left_shift_pressed = key_pressed,
                .RightShift => self.right_shift_pressed = key_pressed,
                .LeftCtrl => self.left_ctrl_pressed = key_pressed,
                .E0_RightCtrl => self.right_ctrl_pressed = key_pressed,
                .LeftAlt => self.left_alt_pressed = key_pressed,
                .E0_RightAlt => self.right_alt_pressed = key_pressed,
                .E0_LeftGui => self.left_super_pressed = key_pressed,
                .E0_RightGui => self.right_super_pressed = key_pressed,
                .CapsLock => if (key_pressed) {
                    self.caps_lock_on = !self.caps_lock_on;
                    self.updateLeds() catch |err| {
                        log_verbose.err("Error updating LEDs for CapsLock: {s}\n", .{@errorName(err)});
                    };
                },
                .NumLock => if (key_pressed) {
                    self.num_lock_on = !self.num_lock_on;
                    self.updateLeds() catch |err| {
                        log_verbose.err("Error updating LEDs for NumLock: {s}\n", .{@errorName(err)});
                    };
                },
                .ScrollLock => if (key_pressed) {
                    self.scroll_lock_on = !self.scroll_lock_on;
                    self.updateLeds() catch |err| {
                        log_verbose.err("Error updating LEDs for ScrollLock: {s}\n", .{@errorName(err)});
                    };
                },
                else => {},
            }

            if (key_pressed) {
                const shift_active = self.left_shift_pressed or self.right_shift_pressed;
                // TODO @(dleiferives,8a3af962-9101-4225-96bd-8cb725d0ea3c): add
                // numlock stuff.... ~#
                char_val = Key.toChar(current_key, shift_active, self.caps_lock_on);
            }

            event = KeyEvent{
                .key = current_key,
                .char = char_val,
                .pressed = key_pressed,
            };
        } else {
            log_verbose.info("Unknown scancode sequence: e0={any}, f0={any}, sc={x}\n", .{ self.e0_prefix, self.f0_prefix, scancode });
        }

        // Reset for next scancode
        self.e0_prefix = false;
        self.f0_prefix = false;
        return event;
    }

    fn sendKeyboardCommand(self: *Self, command: u8) Ps2Error!void {
        try self.controller.sendByteToDevice(self.port_index, command);
        // Wait for ACK
        const ack_timeout_iter = Ps2ControllerModule.DEFAULT_TIMEOUT_ITERATIONS;
        const response = try self.controller.readDataPortWithTimeout(ack_timeout_iter);
        if (response == ps2.DEV_RES_RESEND) {
            log_verbose.info("Keyboard requested resend for command {x}\n", .{command});
            return Ps2Error.CommandFailed;
        }
        if (response != ps2.DEV_RES_ACK) {
            log_verbose.info("Keyboard NACKed command {x}, response: {x}\n", .{ command, response });
            return Ps2Error.CommandFailed;
        }
    }

    pub fn updateLeds(self: *Self) Ps2Error!void {
        log_verbose.info("Updating LEDs: Caps={}, Num={}, Scroll={}\n", .{
            self.caps_lock_on, self.num_lock_on, self.scroll_lock_on,
        });
        try self.sendKeyboardCommand(0xED);

        var led_byte: u8 = 0;
        if (self.scroll_lock_on) led_byte |= (1 << 0);
        if (self.num_lock_on) led_byte |= (1 << 1);
        if (self.caps_lock_on) led_byte |= (1 << 2);

        try self.sendKeyboardCommand(led_byte);
        log_verbose.info("LEDs updated.\n", .{});
    }
};

pub const KeyboardManager = struct {
    controller: *Ps2Controller,
    keyboard1: ?Ps2KeyboardDevice = null,
    keyboard2: ?Ps2KeyboardDevice = null,

    const Self = @This();

    pub fn init(ps2_controller: *Ps2Controller) !Self {
        var manager = Self{ .controller = ps2_controller };

        log_verbose.info("KeyboardManager: Initializing...\n", .{});

        // Check Port 1 for a keyboard
        if (ps2_controller.port1_operational) {
            if (ps2_controller.port1_device_id) |id| {
                switch (id.device_type) {
                    .Mf2Keyboard, .Mf2KeyboardType2, .ShortKeyboard, .NcdN97Keyboard, .Keyboard122Key => {
                        log_verbose.info("KeyboardManager: Found '{s}' on Port 1.\n", .{@tagName(id.device_type)});
                        manager.keyboard1 = Ps2KeyboardDevice.init(0, ps2_controller, id.device_type);
                        manager.keyboard1.?.updateLeds() catch |e| {
                           log_verbose.info("Initial LED update for KBD1 failed: {s}\n", .{@errorName(e)});
                        };
                    },
                    else => {
                        log_verbose.info("KeyboardManager: Device on Port 1 ('{s}') is not a recognized keyboard type for this driver.\n", .{@tagName(id.device_type)});
                    },
                }
            } else {
                log_verbose.info("KeyboardManager: Port 1 operational but no device ID.\n", .{});
            }
        }

        // Check Port 2 for a keyboard
        if (ps2_controller.port2_operational) {
            if (ps2_controller.port2_device_id) |id| {
                switch (id.device_type) {
                    .Mf2Keyboard, .Mf2KeyboardType2, .ShortKeyboard, .NcdN97Keyboard, .Keyboard122Key => {
                        log_verbose.info("KeyboardManager: Found '{s}' on Port 2.\n", .{@tagName(id.device_type)});
                        manager.keyboard2 = Ps2KeyboardDevice.init(1, ps2_controller, id.device_type);
                        manager.keyboard2.?.updateLeds() catch |e| {
                           log_verbose.info("Initial LED update for KBD2 failed: {s}\n", .{@errorName(e)});
                        };
                    },
                    else => {
                        log_verbose.info("KeyboardManager: Device on Port 2 ('{s}') is not a recognized keyboard type for this driver.\n", .{@tagName(id.device_type)});
                    },
                }
            } else {
                log_verbose.info("KeyboardManager: Port 2 operational but no device ID.\n", .{});
            }
        }

        if (manager.keyboard1 == null and manager.keyboard2 == null) {
            log_verbose.info("KeyboardManager: No keyboard devices found or initialized.\n", .{});
        }

        return manager;
    }

    pub fn pollAndProcessInput(self: *Self) void {
        const status = self.controller.status_port.read();

        if ((status & ps2.STATUS_OUTPUT_BUFFER_FULL) != 0) {
            log_verbose.info("PS/2 Controller: Data available in output buffer.\n", .{});
            // Data is available. Let's find out which port it came from
            var scancode: u8 = 0;
            var port_source: ?u1 = null;

            // Read the data first
            scancode = self.controller.data_port.read();
            log_verbose.info("PS/2 Controller: Read scancode {x} from output buffer.\n", .{scancode});

            // There are almost certainly race conditions here, but...
            // I'm just going to be using the irq so I'm not pressed
            if (self.controller.is_dual_channel_supported) {
                const cop = self.controller.readControllerOutputPort() catch 0;
                if ((cop & ps2.COP_OUTPUT_BUFFER_FULL_PORT2) != 0) {
                    port_source = 1;
                } else if ((cop & ps2.COP_OUTPUT_BUFFER_FULL_PORT1) != 0) {
                    port_source = 0;
                } else {
                    if (self.keyboard1 != null) port_source = 0;
                }
            } else {
                // single channel controller
                if (self.keyboard1 != null) port_source = 0;
            }


            if (port_source) |idx| {
                var kbd: ?*Ps2KeyboardDevice = null;
                if (idx == 0 and self.keyboard1 != null) {
                    kbd = &self.keyboard1.?;
                } else if (idx == 1 and self.keyboard2 != null) {
                    kbd = &self.keyboard2.?;
                }

                if (kbd) |active_kbd| {
                    // We have a keyboard device for this port
                    log_verbose.info("PS/2 Controller: Processing scancode {x} from keyboard on port {d}.\n", .{scancode, idx});
                    if (active_kbd.processScancode(scancode)) |key_event| {
                        // try vga.driver.print("KBD Port {d}: Key={s}, Pressed={d}, Char='{c}'\n", .{
                        //     idx, @tagName(key_event.key), key_event.pressed, key_event.char orelse ' '
                        // });
                        if (key_event.pressed) {
                            if (key_event.char) |char_to_print| {
                                // "Type to screen"
                                log.warn("{c}", .{char_to_print});
                            }
                            if (key_event.key == .Backspace) {
                                log.warn("\x08 \x08", .{}); // Classic send backspace then space then backspace
                            }
                        }
                    }
                }
            } else {
                // could be the mouse?? if there is a mouse
                log_verbose.info("PS/2 data {x} received, but no keyboard handler or unknown source.\n", .{scancode});
            }
        }
    }
};

/// IRQ-1 (keyboard) handler.
fn irq1Handler(frame: *arch.irq.InterruptFrame) void {
    _ = frame; // CPU context not needed here
    if (ps2_ctrl.onIrq1Interrupt()) |scancode| {
        if (kbd_mgr.keyboard1) |*kbd| { // assume port1
            if (kbd.processScancode(scancode)) |evt| {
                // decode
                if (evt.pressed) {
                    if (evt.char) |ch| {
                        std.log.debug("Got char {c} from keyboard\n", .{ch});
                    }
                }
            }
        }
    }
}

pub fn setup_irq(ctrl: *Ps2Controller, mgr: *KeyboardManager) !void {
    ps2_ctrl = ctrl;
    kbd_mgr  = mgr;
    try arch.irq.irq.registerIrq(1, irq1Handler);
}


// Lovely buffering keyboard
// for when we have threading!!!!!!
pub const KeyboardBuffer = struct {
    buffer: [256]u8 = [_]u8{0} ** 256,
    read_pos: u8 = 0,
    write_pos: u8 = 0,
    blocked_readers: ThreadQueue = .{},
    buffer_mutex: Mutex = .{},

    pub fn init() KeyboardBuffer {
        return .{};
    }

    pub fn hasData(self: *KeyboardBuffer) bool {
        return self.read_pos != self.write_pos;
    }

    pub fn putChar(self: *KeyboardBuffer, ch: u8) void {
        arch.irq.irq.disable();
        defer arch.irq.irq.enable();

        const next_write = (self.write_pos +% 1);
        if (next_write != self.read_pos) {
            self.buffer[self.write_pos] = ch;
            self.write_pos = next_write;

            // Unblock one waiting reader
            self.blocked_readers.unblockOne();
        }
    }

    pub fn getChar(self: *KeyboardBuffer) u8 {
        arch.irq.irq.disable();

        while (self.read_pos == self.write_pos) {
            if (thread.getCurrentThread()) |current| {
                current.state = .BLOCKED_KEYBOARD;
                self.blocked_readers.enqueue(current);

                // Remove from scheduler
                if (kernel.state.scheduler) |sched| {
                    sched.removeThread(current) catch {};
                }

                arch.irq.irq.enable();
                thread.Thread.yield();
                arch.irq.irq.disable();
            } else {
                arch.irq.irq.enable();
                return 0;
            }
        }

        const ch = self.buffer[self.read_pos];
        self.read_pos = (self.read_pos +% 1);

        arch.irq.irq.enable();
        return ch;
    }

    pub fn getCharNonBlocking(self: *KeyboardBuffer) ?u8 {
        arch.irq.irq.disable();
        defer arch.irq.irq.enable();

        if (self.read_pos == self.write_pos) {
            return null;
        }

        const ch = self.buffer[self.read_pos];
        self.read_pos = (self.read_pos +% 1);
        return ch;
    }

    // Interrupt handler to put characters in buffer
    fn bufferedKeyboardInterruptHandler(frame: *arch.irq.InterruptFrame) void {
        _ = frame;
        if (ps2_ctrl.onIrq1Interrupt()) |scancode| {
            if (kbd_mgr.keyboard1) |*kbd| {
                if (kbd.processScancode(scancode)) |evt| {
                    if (evt.pressed and evt.char != null) {
                        keyboard_buffer.putChar(evt.char.?);
                    }
                }
            }
        }
    }

    pub fn getc() u8 {
        return keyboard_buffer.getChar();
    }

    pub fn tryGetc() ?u8 {
        return keyboard_buffer.getCharNonBlocking();
    }

    pub fn setup_irq(ctrl: *Ps2Controller, mgr: *KeyboardManager) !void {
        arch.irq.irq.disable();
        ps2_ctrl = ctrl;
        kbd_mgr = mgr;
        try arch.irq.irq.unregisterIrq(1); // Unregister any previous handler
        try arch.irq.irq.registerIrq(1, bufferedKeyboardInterruptHandler);
        arch.irq.irq.enable();
    }

};

var keyboard_buffer: KeyboardBuffer = .{};
