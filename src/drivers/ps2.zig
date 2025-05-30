const CPU = @import("arch").cpu;
const std = @import("std");
const log = std.log.scoped(.drivers_ps2);
const log_verbose = std.log.scoped(.drivers_ps2_verbose);

// For bare-metal, we might not have std.debug.print
// Define a placeholder if not available or configure for your environment

// Default timeout iterations for busy-waiting loops
pub const DEFAULT_TIMEOUT_ITERATIONS: u32 = 100_000_00;

//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
// I/O Port Abstraction
//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

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

//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
// PS/2 Constants
//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

pub const ps2 = struct {
    // I/O Ports
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

//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
// Specialized Port Structs (Wrappers around IoPort)
//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

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

//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
// Error Types
//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

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

//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
// Device Types and Identification
//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

pub const DeviceType = enum {
    Unknown,
    AncientAtKeyboard,
    StandardPs2Mouse,
    MouseWithScrollWheel,
    FiveButtonMouse,
    Mf2Keyboard, // Common case for 0xAB, 0x83 or 0xAB, 0x41
    Mf2KeyboardType2, // e.g. 0xAB, 0xC1
    ShortKeyboard, // e.g. ThinkPads, 0xAB, 0x84
    NcdN97Keyboard, // 0xAB, 0x85
    Keyboard122Key, // 0xAB, 0x86
    // Add more as needed from the OSDev Wiki table

    pub fn from_id(id_byte1: u8, id_byte2: ?u8, translated: bool) DeviceType {
        // Simplified mapping; a more robust one would handle all listed cases
        if (translated) {
            // Handle translated IDs if necessary, though we disable translation
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

//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
// PS/2 Controller Struct and Methods
//++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

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
    // We aim to disable translation, so this might not be needed long-term
    // port1_translation_was_enabled: bool,

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

        // Step 1: Initialise USB Controllers (Assumed done by caller/OS)
        log_verbose.info("  Step 1: USB Legacy Support assumed handled by OS.\n", .{});

        // Step 2: Determine if the PS/2 Controller Exists (Assumed exists for this driver)
        log_verbose.info("  Step 2: PS/2 Controller assumed to exist.\n", .{});

        // Step 3: Disable Devices
        log_verbose.info("  Step 3: Disabling devices...\n", .{});
        try controller.sendCommand(ps2.CMD_DISABLE_FIRST_PORT);
        // Try to disable second port; ignore error if single channel
        _ = controller.sendCommand(ps2.CMD_DISABLE_SECOND_PORT) catch |err| {
            if (err == error.Timeout) { // Expected on single channel controllers
                log_verbose.info("    (Note: Timeout disabling second port, likely single channel)\n", .{});
            } else return err;
        };

        // Step 4: Flush The Output Buffer
        log_verbose.info("  Step 4: Flushing output buffer...\n", .{});
        controller.flushOutputBuffer();

        // Step 5: Set the Controller Configuration Byte (CCB)
        log_verbose.info("  Step 5: Setting Controller Configuration Byte...\n", .{});
        var ccb = try controller.readConfigByte();
        // controller.port1_translation_was_enabled = (ccb & ps2.CCB_FIRST_PORT_TRANSLATION_ENABLE) != 0;

        // Disable IRQs (bit 0, 1), disable translation (bit 6), enable clock for port 1 (clear bit 4)
        ccb &= ~ps2.CCB_FIRST_PORT_INTERRUPT_ENABLE;
        ccb &= ~ps2.CCB_SECOND_PORT_INTERRUPT_ENABLE; // Clear for now, enable later if dual
        ccb &= ~ps2.CCB_FIRST_PORT_TRANSLATION_ENABLE;
        ccb &= ~ps2.CCB_FIRST_PORT_CLOCK_DISABLE; // Ensure clock is enabled
        // Bit 3 should be zero, Bit 7 must be zero
        ccb &= ~@as(u8, 1 << 3);
        ccb &= ~@as(u8, 1 << 7);
        try controller.writeConfigByte(ccb);
        log_verbose.info("    Initial CCB set to: {b}\n", .{ccb});

        // Step 6: Perform Controller Self Test
        log_verbose.info("  Step 6: Performing controller self-test...\n", .{});
        try controller.sendCommand(ps2.CMD_TEST_CONTROLLER);
        const test_result = try controller.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS);
        if (test_result != ps2.CONTROLLER_TEST_PASSED) {
            log_verbose.info("    Controller self-test FAILED! Response: {x}\n", .{test_result});
            return Ps2Error.ControllerTestFailed;
        }
        log_verbose.info("    Controller self-test PASSED.\n", .{});

        // Restore CCB after self-test (as it might reset the controller)
        // The OSDev wiki says "At the very least, the Controller Configuration Byte should be restored"
        // We've already set it to a known good state, let's re-apply it.
        // Or, re-read and modify if the test changed it in an unknown way.
        // For simplicity, we re-apply our desired initial state.
        log_verbose.info("    Restoring CCB after self-test...\n", .{});
        try controller.writeConfigByte(ccb); // ccb still holds our desired initial state

        // Step 7: Determine If There Are 2 Channels
        log_verbose.info("  Step 7: Determining if dual channel...\n", .{});
        // Save current CCB before potentially modifying it for the test
        const ccb_before_dual_test = try controller.readConfigByte();
        try controller.sendCommand(ps2.CMD_ENABLE_SECOND_PORT);
        var ccb_after_enable_second = try controller.readConfigByte();

        // Bit 5 of CCB: Second PS/2 port clock (1 = disabled, 0 = enabled)
        // If bit 5 is clear (0), it means the second port clock is enabled, so dual channel exists.
        if ((ccb_after_enable_second & ps2.CCB_SECOND_PORT_CLOCK_DISABLE) == 0) {
            controller.is_dual_channel_supported = true;
            log_verbose.info("    Dual channel supported.\n", .{});
            // Disable the second port again for now
            try controller.sendCommand(ps2.CMD_DISABLE_SECOND_PORT);
            // Update CCB: ensure second port clock is enabled (clear bit 5)
            // and second port interrupt is disabled (clear bit 1) for now.
            ccb_after_enable_second &= ~ps2.CCB_SECOND_PORT_CLOCK_DISABLE;
            ccb_after_enable_second &= ~ps2.CCB_SECOND_PORT_INTERRUPT_ENABLE;
            try controller.writeConfigByte(ccb_after_enable_second);
        } else {
            controller.is_dual_channel_supported = false;
            log_verbose.info("    Single channel controller (or second port enable failed).\n", .{});
            // Restore CCB to state before this test if it was single channel
            try controller.writeConfigByte(ccb_before_dual_test);
        }
        // Update our main 'ccb' variable to the current state
        ccb = try controller.readConfigByte();

        // Step 8: Perform Interface Tests
        log_verbose.info("  Step 8: Performing interface tests...\n", .{});
        // Test first port
        try controller.sendCommand(ps2.CMD_TEST_FIRST_PORT);
        const port1_test_res = try controller.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS);
        if (port1_test_res == ps2.PORT_TEST_PASSED) {
            controller.port1_operational = true;
            log_verbose.info("    Port 1 test PASSED.\n", .{});
        } else {
            log_verbose.info("    Port 1 test FAILED. Code: {x}\n", .{port1_test_res});
        }

        // Test second port if dual channel and port 1 is OK (or if we want to test it regardless)
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
            return Ps2Error.PortTestFailed; // Or a more specific error
        }

        // Step 9: Enable Devices and Interrupts
        log_verbose.info("  Step 9: Enabling operational devices and interrupts...\n", .{});
        var final_ccb = try controller.readConfigByte();
        if (controller.port1_operational) {
            try controller.sendCommand(ps2.CMD_ENABLE_FIRST_PORT);
            final_ccb |= ps2.CCB_FIRST_PORT_INTERRUPT_ENABLE; // Enable interrupt for port 1
            log_verbose.info("    Port 1 enabled, interrupt requested.\n", .{});
        }
        if (controller.port2_operational) {
            try controller.sendCommand(ps2.CMD_ENABLE_SECOND_PORT);
            final_ccb |= ps2.CCB_SECOND_PORT_INTERRUPT_ENABLE; // Enable interrupt for port 2
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

        // Step 10: Reset Devices
        log_verbose.info("  Step 10: Resetting devices...\n", .{});
        if (controller.port1_operational) {
            log_verbose.info("    Resetting device on Port 1...\n", .{});
            if (controller.resetAndIdentifyDevice(0)) |id| {
                controller.port1_device_id = id;
                log_verbose.info("    Port 1 Device ID: {x} {?x}, Type: {s}\n", .{ id.byte1, id.byte2, @tagName(id.device_type) });
            } else |err| {
                log_verbose.info("    Port 1 device reset/identify failed: {s}\n", .{@errorName(err)});
                // Optionally mark port1 as non-operational for devices
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

    // --- Helper Methods ---

    fn waitForInputBufferEmpty(self: Self, timeout_iter: u32) Ps2Error!void {
        var timeout = timeout_iter;
        while (timeout > 0) : (timeout -= 1) {
            if ((self.status_port.read() & ps2.STATUS_INPUT_BUFFER_FULL) == 0) {
                return;
            }
            // Small delay could be added here if running on very fast hardware
            // For bare-metal, this busy wait might be fine.
            // std.time.sleep(10_000); // 10us, if std.time is available and works
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
        // The OSDev wiki note "Check if output buffer is empty first" for 0xD1 is unusual.
        // Standard practice is to ensure input buffer is empty before sending command and data.
        try self.sendCommandWithArg(ps2.CMD_WRITE_CONTROLLER_OUTPUT_PORT, value);
    }

    fn flushOutputBuffer(self: Self) void {
        var i: u32 = 0;
        // Try to read a few times in case multiple bytes are stuck
        while (i < 16) : (i += 1) {
            if ((self.status_port.read() & ps2.STATUS_OUTPUT_BUFFER_FULL) != 0) {
                _ = self.data_port.read(); // Discard data
            } else {
                break; // Buffer is empty
            }
        }
    }

    // --- Device Communication ---

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

    /// Receives a byte from a device using polling.
    /// Note: On dual-channel systems, this doesn't distinguish which port sent the data
    /// without checking Controller Output Port bits, which is prone to race conditions.
    /// Interrupt-driven reception is preferred for dual-channel.
    pub fn receiveBytePolling(self: Self) Ps2Error!u8 {
        return self.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS);
    }

    fn expectDeviceResponse(self: Self, expected_byte: u8) Ps2Error!void {
        const response = try self.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS);
        if (response == ps2.DEV_RES_RESEND) {
            // TODO: Implement resend try vga.driver.printic if necessary. For now, treat as error.
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

        // Wait for ACK (0xFA) (optional, some devices go straight to BAT)
        // For robustness, try to read ACK, but proceed if BAT code (0xAA) comes first.
        var response = try self.readDataPortWithTimeout(DEFAULT_TIMEOUT_ITERATIONS * 2); // Longer timeout for reset
        if (response == ps2.DEV_RES_ACK) {
            log_verbose.info("    Device ACKed reset.\n", .{});
            // Now expect BAT completion code (0xAA)
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

        // Device might send an ID byte after 0xAA (e.g., older mice might send 0x00)
        // Or we need to explicitly ask for ID. The OSDev wiki implies we should do full identify sequence.

        // Full Identify Sequence
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
            // Timeout is fine, means only one ID byte
        }

        // 4. Enable Scanning
        try self.sendByteToDevice(port_index, ps2.DEV_CMD_ENABLE_SCANNING);
        try self.expectDeviceResponse(ps2.DEV_RES_ACK);
        log_verbose.info("    Device scanning enabled.\n", .{});

        // Determine type (assuming translation is off, which we configured)
        const dev_type = DeviceType.from_id(id_byte1, id_byte2, false);
        return DeviceIdentification{
            .byte1 = id_byte1,
            .byte2 = id_byte2,
            .device_type = dev_type,
        };
    }

    // --- Interrupt Handling (stubs for OS to call) ---

    /// Call this from IRQ1 handler. Returns data byte if available.
    pub fn onIrq1Interrupt(self: *Self) ?u8 {
        // Check if output buffer is actually full (it should be if IRQ1 fired from device)
        // And also check if the data is from port 1 (Controller Output Port bit 4)
        // However, a simple read is often done.
        // The problem: controller responses (e.g. from 0x20) might also trigger IRQ1.
        // During init, IRQs should be disabled when expecting controller responses.
        if ((self.status_port.read() & ps2.STATUS_OUTPUT_BUFFER_FULL) != 0) {
            // Ideally, also check Controller Output Port bit 4 if reliable
            return self.data_port.read();
        }
        return null;
    }

    /// Call this from IRQ12 handler. Returns data byte if available.
    pub fn onIrq12Interrupt(self: *Self) ?u8 {
        if ((self.status_port.read() & ps2.STATUS_OUTPUT_BUFFER_FULL) != 0) {
            // Ideally, also check Controller Output Port bit 5 if reliable
            return self.data_port.read();
        }
        return null;
    }

    // --- System Control ---

    /// Pulses the system reset line via the PS/2 controller.
    pub fn triggerSystemReset(self: Self) Ps2Error!void {
        log_verbose.info("Attempting CPU Reset via PS/2 Controller...\n", .{});
        try self.waitForInputBufferEmpty(DEFAULT_TIMEOUT_ITERATIONS);
        self.command_port.write(ps2.CMD_PULSE_OUTPUT_LINE_LOW_RESET);
        // System should reset; no response expected.
        // A small delay might be needed for the reset to take effect before any further code runs (if any).
        var i: u32 = 0;
        while (i < 1000000) : (i += 1) { // Arbitrary delay
            asm volatile ("" ::: "memory");
        }
        // If we're still here, it might not have worked or this code path is unexpected.
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
        // Crucially, ensure system reset bit remains 1
        cop |= ps2.COP_SYSTEM_RESET;
        try self.writeControllerOutputPort(cop);
        log_verbose.info("A20 gate set. COP: {b}\n", .{cop});

        // Verify A20 gate status (optional, but good for confirmation)
        // This can be tricky as enabling A20 might not be instantly readable or
        // might require other system interactions to confirm.
        // For now, we assume the write was successful.
    }
};

// Example of how you might use it (in a bare-metal context)
// This `main` function is for demonstration and won't run in a typical OS kernel directly.
// pub fn main() !void {
//     try vga.driver.print("Attempting to initialize PS/2 Controller...\n", .{});
//     var ps2_controller = try Ps2Controller.init();
//     try vga.driver.print("PS/2 Controller initialized successfully.\n", .{});
//
//     if (ps2_controller.port1_device_id) |id| {
//         try vga.driver.print("Port 1 Device: {s}\n", .{@tagName(id.device_type)});
//     } else {
//         try vga.driver.print("Port 1: No device or failed to identify.\n", .{});
//     }
//
//     if (ps2_controller.is_dual_channel_supported) {
//         if (ps2_controller.port2_device_id) |id| {
//             try vga.driver.print("Port 2 Device: {s}\n", .{@tagName(id.device_type)});
//         } else {
//             try vga.driver.print("Port 2: No device or failed to identify.\n", .{});
//         }
//     } else {
//         try vga.driver.print("Single channel controller, Port 2 not applicable.\n", .{});
//     }
//
//     // Example: try to enable A20 gate
//     // try ps2_controller.setA20Gate(true);
//     // try vga.driver.print("A20 gate enabled (attempted).\n", .{});
//
//     // Example: try to reset CPU (this would halt execution here)
//     // try ps2_controller.triggerSystemReset();
//     // try vga.driver.print("If you see this, CPU reset failed.\n", .{});
// }
