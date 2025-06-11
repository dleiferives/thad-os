const CPU = @import("arch").cpu;
const std = @import("std");
const log = std.log.scoped(.drivers_ps2);
const log_verbose = std.log.scoped(.drivers_ps2_verbose);

/// for busy waiting... which I should remove
pub const DEFAULT_TIMEOUT_ITERATIONS: u32 = 100_000_00;


pub const Ps2Error = error{
    Timeout,
    ControllerTestFailed,
    PortTestFailed,
    DeviceResetFailed,
    DeviceIdentifyFailed,
    DeviceNotPresent,
    CommandFailed, // Generic command failure
    NoDualChannelSupport,
    UnexpectedResponse,
};

const IoPort = struct {
    port_address: u16,

    pub fn init(port_address: u16) IoPort {
        return .{ .port_address = port_address };
    }

    pub fn readByte(self: IoPort) u8 {
        return CPU.inb(self.port_address);
    }

    pub fn writeByte(self: IoPort, value: u8) void {
        CPU.outb(self.port_address, value);
    }
};

pub const ps2 = struct {
    pub const PORT_DATA: u16 = 0x60;
    pub const PORT_COMMAND_STATUS: u16 = 0x64;

    // Status Register Bits (Port 0x64 - Read)
    pub const STATUS_OUTPUT_BUFFER_FULL: u8 = 1 << 0; // 0: Empty, 1: Full
    pub const STATUS_INPUT_BUFFER_FULL: u8 = 1 << 1; // 0: Empty, 1: Full
    pub const STATUS_SYSTEM_FLAG: u8 = 1 << 2; // POST status
    pub const STATUS_COMMAND_DATA: u8 = 1 << 3; // 0: Data for device, 1: Data for controller
    // Bit 4: Unknown (chipset specific) / Keyboard Lock
    // Bit 5: Unknown (chipset specific) / Second PS/2 port output buffer full / Receive timeout
    pub const STATUS_TIMEOUT_ERROR: u8 = 1 << 6; // 0: No error, 1: Time-out error
    pub const STATUS_PARITY_ERROR: u8 = 1 << 7; // 0: No error, 1: Parity error

    // PS/2 Controller Commands (Port 0x64 - Write)
    pub const CMD_READ_CONFIG_BYTE: u8 = 0x20;
    pub const CMD_WRITE_CONFIG_BYTE: u8 = 0x60;
    pub const CMD_DISABLE_SECOND_PORT: u8 = 0xA7;
    pub const CMD_ENABLE_SECOND_PORT: u8 = 0xA8;
    pub const CMD_TEST_SECOND_PORT: u8 = 0xA9;
    pub const CMD_TEST_CONTROLLER: u8 = 0xAA;
    pub const CMD_TEST_FIRST_PORT: u8 = 0xAB;
    // pub const CMD_DIAGNOSTIC_DUMP: u8 = 0xAC; // Not typically used by OS
    pub const CMD_DISABLE_FIRST_PORT: u8 = 0xAD;
    pub const CMD_ENABLE_FIRST_PORT: u8 = 0xAE;
    pub const CMD_READ_CONTROLLER_OUTPUT_PORT: u8 = 0xD0;
    pub const CMD_WRITE_CONTROLLER_OUTPUT_PORT: u8 = 0xD1;
    pub const CMD_WRITE_BYTE_TO_FIRST_PORT_OUTPUT_BUFFER: u8 = 0xD2; // Simulates data from port 1
    pub const CMD_WRITE_BYTE_TO_SECOND_PORT_OUTPUT_BUFFER: u8 = 0xD3; // Simulates data from port 2
    pub const CMD_WRITE_BYTE_TO_SECOND_PORT_INPUT_BUFFER: u8 = 0xD4; // Send to second device

    pub const CMD_PULSE_OUTPUT_LINE_LOW_RESET: u8 = 0xFE; // Pulses bit 0 (reset line)

    // Controller Self-Test Responses
    pub const CONTROLLER_TEST_PASSED: u8 = 0x55;
    pub const CONTROLLER_TEST_FAILED: u8 = 0xFC;

    // Port Test Responses
    pub const PORT_TEST_PASSED: u8 = 0x00;
    pub const PORT_TEST_CLOCK_LOW: u8 = 0x01;
    pub const PORT_TEST_CLOCK_HIGH: u8 = 0x02;
    pub const PORT_TEST_DATA_LOW: u8 = 0x03;
    pub const PORT_TEST_DATA_HIGH: u8 = 0x04;

    // Controller Configuration Byte (CCB) Bits
    pub const CCB_FIRST_PORT_INTERRUPT_ENABLE: u8 = 1 << 0;
    pub const CCB_SECOND_PORT_INTERRUPT_ENABLE: u8 = 1 << 1;
    pub const CCB_SYSTEM_FLAG_POST_PASSED: u8 = 1 << 2;
    // Bit 3: Should be zero
    pub const CCB_FIRST_PORT_CLOCK_DISABLE: u8 = 1 << 4; // 1: Disabled, 0: Enabled
    pub const CCB_SECOND_PORT_CLOCK_DISABLE: u8 = 1 << 5; // 1: Disabled, 0: Enabled
    pub const CCB_FIRST_PORT_TRANSLATION_ENABLE: u8 = 1 << 6;
    // Bit 7: Must be zero

    // Controller Output Port Bits
    pub const COP_SYSTEM_RESET: u8 = 1 << 0; // WARNING: Always set to 1. Pulse via 0xFE.
    pub const COP_A20_GATE: u8 = 1 << 1;
    pub const COP_SECOND_PORT_CLOCK: u8 = 1 << 2;
    pub const COP_SECOND_PORT_DATA: u8 = 1 << 3;
    pub const COP_OUTPUT_BUFFER_FULL_PORT1: u8 = 1 << 4; // IRQ1
    pub const COP_OUTPUT_BUFFER_FULL_PORT2: u8 = 1 << 5; // IRQ12
    pub const COP_FIRST_PORT_CLOCK: u8 = 1 << 6;
    pub const COP_FIRST_PORT_DATA: u8 = 1 << 7;

    // PS/2 Device Commands
    pub const DEV_CMD_RESET: u8 = 0xFF;
    pub const DEV_CMD_IDENTIFY: u8 = 0xF2;
    pub const DEV_CMD_DISABLE_SCANNING: u8 = 0xF5;
    pub const DEV_CMD_ENABLE_SCANNING: u8 = 0xF4;
    pub const DEV_CMD_ECHO: u8 = 0xEE;

    // PS/2 Device Responses
    pub const DEV_RES_ACK: u8 = 0xFA; // Acknowledge
    pub const DEV_RES_BAT_OK: u8 = 0xAA; // Basic Assurance Test OK
    pub const DEV_RES_SELF_TEST_FAILED: u8 = 0xFC; // Self-test failed
    pub const DEV_RES_ECHO: u8 = 0xEE; // Echo response
    pub const DEV_RES_RESEND: u8 = 0xFE;
};

const DataPort = struct {
    io: IoPort,

    pub fn init() DataPort {
        return .{ .io = IoPort.init(ps2.PORT_DATA) };
    }
    pub fn read(self: DataPort) u8 {
        return self.io.readByte();
    }
    pub fn write(self: DataPort, value: u8) void {
        self.io.writeByte(value);
    }
};

const StatusPort = struct {
    io: IoPort,

    pub fn init() StatusPort {
        return .{ .io = IoPort.init(ps2.PORT_COMMAND_STATUS) };
    }
    pub fn read(self: StatusPort) u8 {
        return self.io.readByte();
    }
};

const CommandPort = struct {
    io: IoPort,

    pub fn init() CommandPort {
        return .{ .io = IoPort.init(ps2.PORT_COMMAND_STATUS) };
    }
    pub fn write(self: CommandPort, value: u8) void {
        self.io.writeByte(value);
    }
};

pub const DeviceType = enum {
    Unknown,
    AncientAtKeyboard,
    StandardPs2Mouse,
    MouseWithScrollWheel,
    FiveButtonMouse,
    Mf2Keyboard, // general case for 0xAB, 0x83 or 0xAB, 0x41
    Mf2KeyboardType2, // e.g. 0xAB, 0xC1
    ShortKeyboard, // e.g. ThinkPads... like mine, 0xAB, 0x84
    NcdN97Keyboard, // 0xAB, 0x85
    Keyboard122Key, // 0xAB, 0x86
    // I dont think I need this many. but I can add more if needed :shrug:

    pub fn from_id(id_byte1: u8, id_byte2: ?u8, translated: bool) DeviceType {
        // try to translate
        // TODO @(dleiferives,cb53b28b-5aea-4aeb-b499-e69999df1511): add a more
        // robust translation system ~#
        if (translated) {
            if (id_byte1 == 0xAB) {
                if (id_byte2) |b2| {
                    if (b2 == 0x41) return .Mf2Keyboard;
                }
            }
        } else {
            // Non-translated IDs
            if (id_byte1 == 0x00 and id_byte2 == null) return .StandardPs2Mouse;
            if (id_byte1 == 0x03 and id_byte2 == null) return .MouseWithScrollWheel;
            if (id_byte1 == 0x04 and id_byte2 == null) return .FiveButtonMouse;
            if (id_byte1 == 0xAB) {
                if (id_byte2) |b2| {
                    switch (b2) {
                        0x83 => return .Mf2Keyboard,
                        0xC1 => return .Mf2KeyboardType2,
                        0x84 => return .ShortKeyboard,
                        0x85 => return .NcdN97Keyboard,
                        0x86 => return .Keyboard122Key,
                        else => {},
                    }
                }
            }
        }
        log.err("Unknown device ID: {x} {?x} (translated: {})\n", .{ id_byte1, id_byte2, translated });
        return .Unknown;
    }
};

pub const DeviceIdentification = struct {
    byte1: u8,
    byte2: ?u8,
    device_type: DeviceType,
};

pub const Ps2Controller = struct {
    data_port: DataPort,
    status_port: StatusPort,
    command_port: CommandPort,

    // State
    is_dual_channel_supported: bool,
    port1_operational: bool,
    port2_operational: bool,
    port1_device_id: ?DeviceIdentification,
    port2_device_id: ?DeviceIdentification,

    const Self = @This();

    pub fn init() Ps2Error!Self {
        var controller = Self{
            .data_port = DataPort.init(),
            .status_port = StatusPort.init(),
            .command_port = CommandPort.init(),
            .is_dual_channel_supported = false,
            .port1_operational = false,
            .port2_operational = false,
            .port1_device_id = null,
            .port2_device_id = null,
        };

        log_verbose.info("PS/2 Controller Initialisation Started...\n", .{});

        // Disable Devices
        log_verbose.info("  Step 1: Disabling devices...\n", .{});
        try controller.sendCommand(ps2.CMD_DISABLE_FIRST_PORT);

        // try to disable the second port
        _ = controller.sendCommand(ps2.CMD_DISABLE_SECOND_PORT) catch |err| {
            if (err == error.Timeout) { // Expected on single channel controllers
                log_verbose.info("    (Note: Timeout disabling second port, likely single channel)\n", .{});
            } else return err;
        };

        // flush our output buffer
        log_verbose.info("  Step 2: Flushing output buffer...\n", .{});
        controller.flushOutputBuffer();

        log_verbose.info("  Step 3: Setting Controller Configuration Byte...\n", .{});
        var ccb = try controller.readConfigByte();

        // Configure out controller byte
        // namely lets disable our irg and translation
        // and ensure the clock is enabled for port 1
        ccb &= ~ps2.CCB_FIRST_PORT_INTERRUPT_ENABLE;
        ccb &= ~ps2.CCB_SECOND_PORT_INTERRUPT_ENABLE; // Clear for now??
        ccb &= ~ps2.CCB_FIRST_PORT_TRANSLATION_ENABLE;
        ccb &= ~ps2.CCB_FIRST_PORT_CLOCK_DISABLE; // Ensure clock is enabled
        // Bit 3 should be zero, Bit 7 must be zero
        ccb &= ~@as(u8, 1 << 3);
        ccb &= ~@as(u8, 1 << 7);
        try controller.writeConfigByte(ccb);
        log_verbose.info("    Initial CCB set to: {b}\n", .{ccb});

        // Do some testing!
        log_verbose.info("  Step 4: Performing controller self-test...\n", .{});
        try controller.sendCommand(ps2.CMD_TEST_CONTROLLER);
        const test_result = try controller.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS);
        if (test_result != ps2.CONTROLLER_TEST_PASSED) {
            log_verbose.info("    Controller self-test FAILED! Response: {x}\n", .{test_result});
            return Ps2Error.ControllerTestFailed;
        }
        log_verbose.info("    Controller self-test PASSED.\n", .{});

        // The OSDev wiki says "At the very least, the Controller Configuration Byte should be restored"
        log_verbose.info("    Restoring CCB after self-test...\n", .{});
        try controller.writeConfigByte(ccb); // ccb still holds our desired initial state

        // two channel determinatino
        log_verbose.info("  Step 5: Determining if dual channel...\n", .{});

        // lets like save our CCB before we do anything...
        const ccb_before_dual_test = try controller.readConfigByte();
        try controller.sendCommand(ps2.CMD_ENABLE_SECOND_PORT);
        var ccb_after_enable_second = try controller.readConfigByte();

        if ((ccb_after_enable_second & ps2.CCB_SECOND_PORT_CLOCK_DISABLE) == 0) {
            controller.is_dual_channel_supported = true;
            log_verbose.info("    Dual channel supported.\n", .{});
            try controller.sendCommand(ps2.CMD_DISABLE_SECOND_PORT);
            ccb_after_enable_second &= ~ps2.CCB_SECOND_PORT_CLOCK_DISABLE;
            ccb_after_enable_second &= ~ps2.CCB_SECOND_PORT_INTERRUPT_ENABLE;
            try controller.writeConfigByte(ccb_after_enable_second);
        } else {
            controller.is_dual_channel_supported = false;
            log_verbose.info("    Single channel controller (or second port enable failed).\n", .{});
            try controller.writeConfigByte(ccb_before_dual_test);
        }
        ccb = try controller.readConfigByte();

        log_verbose.info("  Step 6: Performing interface tests...\n", .{});
        try controller.sendCommand(ps2.CMD_TEST_FIRST_PORT);
        const port1_test_res = try controller.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS);
        if (port1_test_res == ps2.PORT_TEST_PASSED) {
            controller.port1_operational = true;
            log_verbose.info("    Port 1 test PASSED.\n", .{});
        } else {
            log_verbose.info("    Port 1 test FAILED. Code: {x}\n", .{port1_test_res});
        }

        if (controller.is_dual_channel_supported) {
            try controller.sendCommand(ps2.CMD_TEST_SECOND_PORT);
            const port2_test_res = try controller.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS);
            if (port2_test_res == ps2.PORT_TEST_PASSED) {
                controller.port2_operational = true;
                log_verbose.info("    Port 2 test PASSED.\n", .{});
            } else {
                log_verbose.info("    Port 2 test FAILED. Code: {x}\n", .{port2_test_res});
            }
        }

        if (!controller.port1_operational and !controller.port2_operational) {
            log_verbose.info("    No PS/2 ports are operational.\n", .{});
            return Ps2Error.PortTestFailed;
        }

        log_verbose.info("  Step 7: Enabling operational devices and interrupts...\n", .{});
        var final_ccb = try controller.readConfigByte();
        if (controller.port1_operational) {
            try controller.sendCommand(ps2.CMD_ENABLE_FIRST_PORT);
            final_ccb |= ps2.CCB_FIRST_PORT_INTERRUPT_ENABLE;
            log_verbose.info("    Port 1 enabled, interrupt requested.\n", .{});
        }
        if (controller.port2_operational) {
            try controller.sendCommand(ps2.CMD_ENABLE_SECOND_PORT);
            final_ccb |= ps2.CCB_SECOND_PORT_INTERRUPT_ENABLE;
            log_verbose.info("    Port 2 enabled, interrupt requested.\n", .{});
        }

        // Ensure translation is off for port 1, clocks are enabled
        final_ccb &= ~ps2.CCB_FIRST_PORT_TRANSLATION_ENABLE;
        final_ccb &= ~ps2.CCB_FIRST_PORT_CLOCK_DISABLE;
        if (controller.is_dual_channel_supported) {
            final_ccb &= ~ps2.CCB_SECOND_PORT_CLOCK_DISABLE;
        }
        try controller.writeConfigByte(final_ccb);
        log_verbose.info("    Final CCB set to: {b}\n", .{final_ccb});

        log_verbose.info("  Step 8: Resetting devices...\n", .{});
        if (controller.port1_operational) {
            log_verbose.info("    Resetting device on Port 1...\n", .{});
            if (controller.resetAndIdentifyDevice(0)) |id| {
                controller.port1_device_id = id;
                log_verbose.info("    Port 1 Device ID: {x} {?x}, Type: {s}\n", .{ id.byte1, id.byte2, @tagName(id.device_type) });
            } else |err| {
                log_verbose.info("    Port 1 device reset/identify failed: {s}\n", .{@errorName(err)});
            }
        }
        if (controller.port2_operational) {
            log_verbose.info("    Resetting device on Port 2...\n", .{});
            if (controller.resetAndIdentifyDevice(1)) |id| {
                controller.port2_device_id = id;
                log_verbose.info("    Port 2 Device ID: {x} {?x}, Type: {s}\n", .{ id.byte1, id.byte2, @tagName(id.device_type) });
            } else |err| {
                log_verbose.info("    Port 2 device reset/identify failed: {s}\n", .{@errorName(err)});
            }
        }

        log_verbose.info("PS/2 Controller Initialisation FINISHED.\n", .{});
        return controller;
    }

    fn waitForInputBufferEmpty(self: Self, timeout_iter: u32) Ps2Error!void {
        var timeout = timeout_iter;
        while (timeout > 0) : (timeout -= 1) {
            if ((self.status_port.read() & ps2.STATUS_INPUT_BUFFER_FULL) == 0) {
                return;
            }
        }
        return Ps2Error.Timeout;
    }

    fn waitForOutputBufferFull(self: Self, timeout_iter: u32) Ps2Error!void {
        var timeout = timeout_iter;
        while (timeout > 0) : (timeout -= 1) {
            if ((self.status_port.read() & ps2.STATUS_OUTPUT_BUFFER_FULL) != 0) {
                return;
            }
            asm volatile ( "" :::);
        }
        return Ps2Error.Timeout;
    }

    pub fn readDataPortWithTimeout(self: Self, timeout_iter: u32) Ps2Error!u8 {
        try self.waitForOutputBufferFull(timeout_iter);
        return self.data_port.read();
    }

    pub fn writeDataPortWithTimeout(self: Self, value: u8, timeout_iter: u32) Ps2Error!void {
        try self.waitForInputBufferEmpty(timeout_iter);
        self.data_port.write(value);
    }

    pub fn sendCommand(self: Self, command: u8) Ps2Error!void {
        try self.waitForInputBufferEmpty(DEFAULT_TIMEOUT_ITERATIONS);
        self.command_port.write(command);
    }

    fn sendCommandWithArg(self: Self, command: u8, arg: u8) Ps2Error!void {
        try self.waitForInputBufferEmpty(DEFAULT_TIMEOUT_ITERATIONS);
        self.command_port.write(command);
        try self.waitForInputBufferEmpty(DEFAULT_TIMEOUT_ITERATIONS);
        self.data_port.write(arg);
    }

    pub fn readConfigByte(self: Self) Ps2Error!u8 {
        try self.sendCommand(ps2.CMD_READ_CONFIG_BYTE);
        return self.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS);
    }

    pub fn writeConfigByte(self: Self, ccb: u8) Ps2Error!void {
        try self.sendCommandWithArg(ps2.CMD_WRITE_CONFIG_BYTE, ccb);
    }

    pub fn readControllerOutputPort(self: Self) Ps2Error!u8 {
        try self.sendCommand(ps2.CMD_READ_CONTROLLER_OUTPUT_PORT);
        return self.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS);
    }

    pub fn writeControllerOutputPort(self: Self, value: u8) Ps2Error!void {
        //org: +I should be checking if the output buffer is empty before sending the command.+
        if ((self.status_port.read() & ps2.STATUS_OUTPUT_BUFFER_FULL) != 0) {
            log_verbose.info("Output buffer full, flushing before writing controller output port.\n", .{});
            self.flushOutputBuffer();
        }
        try self.sendCommandWithArg(ps2.CMD_WRITE_CONTROLLER_OUTPUT_PORT, value);
    }

    fn flushOutputBuffer(self: Self) void {
        var i: u32 = 0;
        while (i < 16) : (i += 1) {
            if ((self.status_port.read() & ps2.STATUS_OUTPUT_BUFFER_FULL) != 0) {
                _ = self.data_port.read(); // Discard data
            } else {
                break; // Buffer is empty
            }
        }
    }

    pub fn sendByteToDevice(self: Self, port_index: u1, byte: u8) Ps2Error!void {
        if (port_index == 0) { // First PS/2 Port
            try self.writeDataPortWithTimeout(byte, DEFAULT_TIMEOUT_ITERATIONS);
        } else if (port_index == 1) { // Second PS/2 Port
            if (!self.is_dual_channel_supported) return Ps2Error.NoDualChannelSupport;
            try self.sendCommand(ps2.CMD_WRITE_BYTE_TO_SECOND_PORT_INPUT_BUFFER);
            try self.writeDataPortWithTimeout(byte, DEFAULT_TIMEOUT_ITERATIONS);
        } else {
            // Should not happen with u1
            unreachable;
        }
    }

    pub fn receiveBytePolling(self: Self) Ps2Error!u8 {
        return self.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS);
    }

    fn expectDeviceResponse(self: Self, expected_byte: u8) Ps2Error!void {
        const response = try self.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS);
        if (response == ps2.DEV_RES_RESEND) {
            log_verbose.info("  Device requested resend, not implemented.\n", .{});
            return Ps2Error.UnexpectedResponse;
        }
        if (response != expected_byte) {
            log_verbose.info("  Expected device response {x}, got {x}\n", .{ expected_byte, response });
            return Ps2Error.UnexpectedResponse;
        }
    }

    pub fn resetAndIdentifyDevice(self: *Self, port_index: u1) Ps2Error!DeviceIdentification {
        // Send Reset
        try self.sendByteToDevice(port_index, ps2.DEV_CMD_RESET);

        var response = try self.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS * 2); // Longer timeout for reset
        if (response == ps2.DEV_RES_ACK) {
            log_verbose.info("    Device ACKed reset.\n", .{});
            // Now expect completion code (0xAA)
            response = try self.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS);
        }

        if (response == ps2.DEV_RES_SELF_TEST_FAILED) {
            log_verbose.info("    Device self-test FAILED (0xFC).\n", .{});
            return Ps2Error.DeviceResetFailed;
        }
        if (response != ps2.DEV_RES_BAT_OK) {
            log_verbose.info("    Device reset failed, unexpected BAT code: {x}\n", .{response});
            return Ps2Error.DeviceResetFailed;
        }
        log_verbose.info("    Device BAT OK (0xAA).\n", .{});

        // Identify Sequence
        // 1. Disable Scanning
        try self.sendByteToDevice(port_index, ps2.DEV_CMD_DISABLE_SCANNING);
        try self.expectDeviceResponse(ps2.DEV_RES_ACK);
        log_verbose.info("    Device scanning disabled.\n", .{});

        // 2. Send Identify Command
        try self.sendByteToDevice(port_index, ps2.DEV_CMD_IDENTIFY);
        try self.expectDeviceResponse(ps2.DEV_RES_ACK);
        log_verbose.info("    Identify command sent.\n", .{});

        // 3. Wait for ID bytes (0, 1, or 2 bytes)
        const id_byte1 = try self.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS);
        log_verbose.info("    ID Byte 1: {x}\n", .{id_byte1});

        var id_byte2: ?u8 = null;
        // Try to read a second byte with a shorter timeout, as it's optional
        if (self.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS / 4)) |b2| {
            id_byte2 = b2;
            log_verbose.info("    ID Byte 2: {x}\n", .{b2});
        } else |err| {
            if (err != error.Timeout) return err; // Real error
        }

        // 4. Enable Scanning
        try self.sendByteToDevice(port_index, ps2.DEV_CMD_ENABLE_SCANNING);
        try self.expectDeviceResponse(ps2.DEV_RES_ACK);
        log_verbose.info("    Device scanning enabled.\n", .{});

        const dev_type = DeviceType.from_id(id_byte1, id_byte2, false);
        return DeviceIdentification{
            .byte1 = id_byte1,
            .byte2 = id_byte2,
            .device_type = dev_type,
        };
    }

    /// called from IRQ1 handler
    pub fn onIrq1Interrupt(self: *Self) ?u8 {
        if ((self.status_port.read() & ps2.STATUS_OUTPUT_BUFFER_FULL) != 0) {
            // could like maybe check Controller Output Port bit 4.. but like...
            return self.data_port.read();
        }
        return null;
    }

    /// called from IRQ12 handler
    pub fn onIrq12Interrupt(self: *Self) ?u8 {
        if ((self.status_port.read() & ps2.STATUS_OUTPUT_BUFFER_FULL) != 0) {
            return self.data_port.read();
        }
        return null;
    }

    pub fn triggerSystemReset(self: Self) Ps2Error!void {
        log_verbose.info("Attempting CPU Reset via PS/2 Controller...\n", .{});
        try self.waitForInputBufferEmpty(DEFAULT_TIMEOUT_ITERATIONS);
        self.command_port.write(ps2.CMD_PULSE_OUTPUT_LINE_LOW_RESET);
        var i: u32 = 0;
        while (i < 1000000) : (i += 1) { // Arbitrary delay
            asm volatile ("" ::: "memory");
        }
        log_verbose.info("CPU Reset command sent. If system did not reset, there might be an issue.\n", .{});
    }

    /// Controls the A20 gate.
    pub fn setA20Gate(self: Self, enable: bool) Ps2Error!void {
        log_verbose.info("Setting A20 gate: {s}\n", .{if (enable) "enable" else "disable"});
        var cop = try self.readControllerOutputPort();
        if (enable) {
            cop |= ps2.COP_A20_GATE;
        } else {
            cop &= ~ps2.COP_A20_GATE;
        }

        cop |= ps2.COP_SYSTEM_RESET;
        try self.writeControllerOutputPort(cop);
        log_verbose.info("A20 gate set. COP: {b}\n", .{cop});
    }
};
