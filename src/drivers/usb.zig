const std = @import("std");
const arch = @import("arch");
const kernel = @import("kernel");
const keyboard = @import("keyboard.zig");

const log = std.log.scoped(.drivers_usb);

const PCI_CONFIG_ADDRESS: u16 = 0xCF8;
const PCI_CONFIG_DATA: u16 = 0xCFC;
const PCI_CLASS_SERIAL_BUS: u8 = 0x0C;
const PCI_SUBCLASS_USB: u8 = 0x03;
const PCI_PROGIF_UHCI: u8 = 0x00;

const REG_USBCMD: u16 = 0x00;
const REG_USBSTS: u16 = 0x02;
const REG_USBINTR: u16 = 0x04;
const REG_FRNUM: u16 = 0x06;
const REG_FRBASEADD: u16 = 0x08;
const REG_SOFMOD: u16 = 0x0C;
const REG_PORTSC1: u16 = 0x10;

const CMD_RUN: u16 = 1 << 0;
const CMD_HCRESET: u16 = 1 << 1;
const CMD_CONFIGURE: u16 = 1 << 6;
const CMD_MAX_PACKET_64: u16 = 1 << 7;
const STS_FATAL_MASK: u16 = (1 << 4) | (1 << 3);
const PORT_CONNECTED: u16 = 1 << 0;
const PORT_CONNECT_CHANGE: u16 = 1 << 1;
const PORT_ENABLED: u16 = 1 << 2;
const PORT_ENABLE_CHANGE: u16 = 1 << 3;
const PORT_RESET: u16 = 1 << 9;
const PORT_LOW_SPEED: u16 = 1 << 8;

const LINK_TERMINATE: u32 = 1;
const LINK_QUEUE_HEAD: u32 = 1 << 1;
const LINK_DEPTH_FIRST: u32 = 1 << 2;
const TD_ACTIVE: u32 = 1 << 23;
const TD_LOW_SPEED: u32 = 1 << 26;
const TD_ERROR_COUNT_3: u32 = 3 << 27;
const TD_ERROR_MASK: u32 = 0x7E << 16;
const PID_IN: u8 = 0x69;
const PID_OUT: u8 = 0xE1;
const PID_SETUP: u8 = 0x2D;

const DESCRIPTOR_DEVICE: u8 = 1;
const DESCRIPTOR_CONFIGURATION: u8 = 2;
const DESCRIPTOR_INTERFACE: u8 = 4;
const DESCRIPTOR_ENDPOINT: u8 = 5;
const REQUEST_GET_DESCRIPTOR: u8 = 6;
const REQUEST_SET_ADDRESS: u8 = 5;
const REQUEST_SET_CONFIGURATION: u8 = 9;
const HID_REQUEST_SET_IDLE: u8 = 0x0A;
const HID_REQUEST_SET_PROTOCOL: u8 = 0x0B;

const POLL_LIMIT: usize = 20_000_000;
const MAX_CONFIGURATION_BYTES: usize = 256;
// A configuration descriptor may arrive through an 8-byte endpoint zero, so
// reserve one TD per packet plus the SETUP and STATUS stages. The MacBook4,1
// keyboard/trackpad advertises 84 bytes and already needs thirteen TDs.
const MIN_ENDPOINT_ZERO_PACKET: usize = 8;
const MAX_CONTROL_TDS: usize = 2 +
    (MAX_CONFIGURATION_BYTES + MIN_ENDPOINT_ZERO_PACKET - 1) / MIN_ENDPOINT_ZERO_PACKET;
const MAX_KEYBOARDS: usize = 8;

// TODO: Allocate control-transfer TD chains to match each request rather than
// retaining a worst-case static array once the USB core has an allocator-safe
// DMA API.

pub const UsbError = error{
    ControllerNotFound,
    KeyboardNotFound,
    InvalidIoBar,
    DmaAddressTooHigh,
    ControllerResetTimeout,
    ControllerFatalError,
    PortResetFailed,
    TransferTimeout,
    TransferFailed,
    InvalidDescriptor,
    ConfigurationTooLarge,
    TooManyKeyboards,
};

const PciAddress = struct {
    bus: u8,
    device: u8,
    function: u8,
};

const Controller = struct {
    pci: PciAddress,
    io_base: u16,
};

const SetupPacket = extern struct {
    request_type: u8,
    request: u8,
    value: u16,
    index: u16,
    length: u16,
};

const TransferDescriptor = extern struct {
    link: u32,
    status: u32,
    token: u32,
    buffer: u32,
    software: [4]u32,
};

const QueueHead = extern struct {
    horizontal: u32,
    element: u32,
};

const KeyboardDevice = struct {
    controller: Controller,
    address: u7,
    endpoint: u4,
    max_packet: u11,
    low_speed: bool,
    data_toggle: bool = false,
    previous_report: [8]u8 = [_]u8{0} ** 8,
    caps_lock: bool = false,
};

const KeyboardRuntime = struct {
    frame_list: [1024]u32 align(4096),
    queue_head: QueueHead align(16),
    interrupt_td: TransferDescriptor align(16),
    report: [8]u8 align(16),
    device: KeyboardDevice,
};

var frame_list: [1024]u32 align(4096) = undefined;
var queue_head: QueueHead align(16) = undefined;
var transfer_descriptors: [MAX_CONTROL_TDS]TransferDescriptor align(16) = undefined;
var setup_packet: SetupPacket align(16) = undefined;
var control_data: [MAX_CONFIGURATION_BYTES]u8 align(16) = undefined;
var keyboards: [MAX_KEYBOARDS]KeyboardRuntime align(4096) = undefined;
var keyboard_count: usize = 0;

pub fn init() !void {
    kernel.hardwareBootStatus("USB: scanning for UHCI controllers", .{});
    keyboard_count = 0;
    var bus: u16 = 0;
    var found_controller = false;
    while (bus < 256) : (bus += 1) {
        var device: u8 = 0;
        while (device < 32) : (device += 1) {
            var function: u8 = 0;
            while (function < 8) : (function += 1) {
                const pci = PciAddress{
                    .bus = @intCast(bus),
                    .device = device,
                    .function = function,
                };
                if (!isUhciController(pci)) continue;
                found_controller = true;
                kernel.hardwareBootStatus("USB: UHCI controller {x:0>2}:{x:0>2}.{}", .{
                    pci.bus,
                    pci.device,
                    pci.function,
                });
                const candidate = controllerFromPci(pci) catch |err| {
                    log.warn("Could not initialize UHCI PCI function: {}", .{err});
                    continue;
                };
                initializeController(candidate) catch |err| {
                    log.warn("UHCI controller initialization failed: {}", .{err});
                    continue;
                };
                if (enumerateController(candidate)) |keyboard_device| {
                    if (keyboard_device) |device_found| {
                        activateKeyboard(device_found) catch |err| {
                            log.warn("Could not activate UHCI keyboard: {}", .{err});
                            stopController(candidate);
                            continue;
                        };
                        continue;
                    }
                    stopController(candidate);
                } else |err| {
                    log.warn("UHCI enumeration failed: {}", .{err});
                    stopController(candidate);
                }
            }
        }
    }
    if (!found_controller) return UsbError.ControllerNotFound;
    if (keyboard_count == 0) return UsbError.KeyboardNotFound;
    keyboard.KeyboardBuffer.registerPollHook(poll);
    log.info("{} UHCI HID boot keyboard(s) ready", .{keyboard_count});
    kernel.hardwareBootStatus("USB: {} HID boot keyboard(s) ready", .{keyboard_count});

    // TODO: Move PCI discovery into a shared enumerator used by AHCI and USB.
    // TODO: Add OHCI, EHCI companion routing, and xHCI host controllers.
    // TODO: Add external hubs and support multiple boot keyboards attached to
    // separate root ports of the same UHCI controller.
    // TODO: Monitor root-port status changes, tear down disconnected devices,
    // and re-enumerate hot-plugged keyboards without rebooting the kernel.
}

fn isUhciController(pci: PciAddress) bool {
    const id = pciRead32(pci, 0x00);
    if (id & 0xFFFF == 0xFFFF) return false;
    const class = pciRead32(pci, 0x08);
    return @as(u8, @truncate(class >> 24)) == PCI_CLASS_SERIAL_BUS and
        @as(u8, @truncate(class >> 16)) == PCI_SUBCLASS_USB and
        @as(u8, @truncate(class >> 8)) == PCI_PROGIF_UHCI;
}

fn controllerFromPci(pci: PciAddress) !Controller {
    const bar = pciRead32(pci, 0x20);
    if (bar & 1 == 0) return UsbError.InvalidIoBar;
    const base: u32 = bar & 0xFFFF_FFE0;
    if (base == 0 or base > std.math.maxInt(u16) - 0x20) return UsbError.InvalidIoBar;

    const command = pciRead16(pci, 0x04);
    // Only write the command half of this register. The adjacent PCI status
    // bits are write-one-to-clear and must not be echoed by a 32-bit write.
    pciWrite16(pci, 0x04, command | (1 << 0) | (1 << 2));
    return .{ .pci = pci, .io_base = @intCast(base) };
}

fn initializeController(controller: Controller) !void {
    stopController(controller);
    out16(controller, REG_USBCMD, CMD_HCRESET);
    var remaining = POLL_LIMIT;
    while (remaining > 0 and in16(controller, REG_USBCMD) & CMD_HCRESET != 0) : (remaining -= 1) {
        asm volatile ("pause");
    }
    if (remaining == 0) return UsbError.ControllerResetTimeout;

    @memset(&frame_list, LINK_TERMINATE);
    queue_head = .{ .horizontal = LINK_TERMINATE, .element = LINK_TERMINATE };
    const qh_phys = try physicalAddress(&queue_head);
    for (&frame_list) |*entry| entry.* = qh_phys | LINK_QUEUE_HEAD;

    out16(controller, REG_USBINTR, 0);
    out16(controller, REG_USBSTS, 0xFFFF);
    out16(controller, REG_FRNUM, 0);
    out32(controller, REG_FRBASEADD, try physicalAddress(&frame_list));
    arch.outb(controller.io_base + REG_SOFMOD, 0x40);
    out16(controller, REG_USBCMD, CMD_MAX_PACKET_64 | CMD_CONFIGURE | CMD_RUN);
    try waitFrames(controller, 2);

    // TODO: Perform chipset-specific legacy/SMI ownership handoff through the
    // standardized PCI legacy-support capability where firmware enables it.
}

fn enumerateController(controller: Controller) !?KeyboardDevice {
    var port_index: u8 = 0;
    var next_address: u7 = 1;
    while (port_index < 2) : (port_index += 1) {
        const port_offset = REG_PORTSC1 + @as(u16, port_index) * 2;
        const initial = in16(controller, port_offset);
        if (initial & PORT_CONNECTED == 0) continue;
        const low_speed = initial & PORT_LOW_SPEED != 0;
        kernel.hardwareBootStatus("USB: device on root port {}, speed={s}", .{
            port_index + 1,
            if (low_speed) "low" else "full",
        });
        resetPort(controller, port_offset) catch |err| {
            log.warn("USB port {} reset failed: {}", .{ port_index + 1, err });
            continue;
        };
        if (enumerateDevice(controller, next_address, low_speed)) |keyboard_device| {
            return keyboard_device;
        } else |err| {
            log.warn("USB device on port {} was not a boot keyboard: {}", .{ port_index + 1, err });
        }
        next_address +%= 1;
        if (next_address == 0) next_address = 1;
    }
    return null;
}

fn enumerateDevice(controller: Controller, address: u7, low_speed: bool) !KeyboardDevice {
    @memset(&control_data, 0);
    try controlTransfer(controller, 0, 8, low_speed, .{
        .request_type = 0x80,
        .request = REQUEST_GET_DESCRIPTOR,
        .value = @as(u16, DESCRIPTOR_DEVICE) << 8,
        .index = 0,
        .length = 8,
    }, control_data[0..8]);
    if (control_data[0] < 8 or control_data[1] != DESCRIPTOR_DEVICE) return UsbError.InvalidDescriptor;
    const endpoint_zero_packet = control_data[7];
    if (endpoint_zero_packet != 8 and endpoint_zero_packet != 16 and
        endpoint_zero_packet != 32 and endpoint_zero_packet != 64)
    {
        return UsbError.InvalidDescriptor;
    }

    try controlTransfer(controller, 0, endpoint_zero_packet, low_speed, .{
        .request_type = 0,
        .request = REQUEST_SET_ADDRESS,
        .value = address,
        .index = 0,
        .length = 0,
    }, &.{});
    try waitFrames(controller, 3);

    @memset(&control_data, 0);
    try controlTransfer(controller, address, endpoint_zero_packet, low_speed, .{
        .request_type = 0x80,
        .request = REQUEST_GET_DESCRIPTOR,
        .value = @as(u16, DESCRIPTOR_DEVICE) << 8,
        .index = 0,
        .length = 18,
    }, control_data[0..18]);
    if (control_data[0] < 18 or control_data[1] != DESCRIPTOR_DEVICE or control_data[17] == 0) {
        return UsbError.InvalidDescriptor;
    }
    const configuration_count = control_data[17];

    var configuration_index: u8 = 0;
    while (configuration_index < configuration_count) : (configuration_index += 1) {
        @memset(&control_data, 0);
        controlTransfer(controller, address, endpoint_zero_packet, low_speed, .{
            .request_type = 0x80,
            .request = REQUEST_GET_DESCRIPTOR,
            .value = (@as(u16, DESCRIPTOR_CONFIGURATION) << 8) | configuration_index,
            .index = 0,
            .length = 9,
        }, control_data[0..9]) catch break;
        if (control_data[0] < 9 or control_data[1] != DESCRIPTOR_CONFIGURATION) return UsbError.InvalidDescriptor;
        const total_length = readLe16(control_data[2..4]);
        if (total_length < 9 or total_length > control_data.len) return UsbError.ConfigurationTooLarge;
        try controlTransfer(controller, address, endpoint_zero_packet, low_speed, .{
            .request_type = 0x80,
            .request = REQUEST_GET_DESCRIPTOR,
            .value = (@as(u16, DESCRIPTOR_CONFIGURATION) << 8) | configuration_index,
            .index = 0,
            .length = total_length,
        }, control_data[0..total_length]);

        const match = findBootKeyboard(control_data[0..total_length]) orelse continue;
        try controlTransfer(controller, address, endpoint_zero_packet, low_speed, .{
            .request_type = 0,
            .request = REQUEST_SET_CONFIGURATION,
            .value = control_data[5],
            .index = 0,
            .length = 0,
        }, &.{});
        try waitFrames(controller, 2);

        // HID boot protocol is descriptor-selected; no vendor/product IDs or
        // fixed interface/endpoint numbers are involved.
        try controlTransfer(controller, address, endpoint_zero_packet, low_speed, .{
            .request_type = 0x21,
            .request = HID_REQUEST_SET_PROTOCOL,
            .value = 0,
            .index = match.interface,
            .length = 0,
        }, &.{});
        controlTransfer(controller, address, endpoint_zero_packet, low_speed, .{
            .request_type = 0x21,
            .request = HID_REQUEST_SET_IDLE,
            .value = 0,
            .index = match.interface,
            .length = 0,
        }, &.{}) catch |err| log.warn("USB keyboard SET_IDLE failed: {}", .{err});

        kernel.hardwareBootStatus("USB: keyboard address {}, interface {}, endpoint 0x{x}", .{
            address,
            match.interface,
            @as(u8, match.endpoint) | 0x80,
        });
        return .{
            .controller = controller,
            .address = address,
            .endpoint = match.endpoint,
            .max_packet = match.max_packet,
            .low_speed = low_speed,
        };
    }
    return UsbError.KeyboardNotFound;
}

const KeyboardMatch = struct {
    interface: u8,
    endpoint: u4,
    max_packet: u11,
};

fn findBootKeyboard(bytes: []const u8) ?KeyboardMatch {
    var offset: usize = 0;
    var keyboard_interface: ?u8 = null;
    while (offset + 2 <= bytes.len) {
        const length = bytes[offset];
        const descriptor_type = bytes[offset + 1];
        if (length < 2 or offset + length > bytes.len) return null;
        if (descriptor_type == DESCRIPTOR_INTERFACE and length >= 9) {
            keyboard_interface = if (bytes[offset + 5] == 3 and
                bytes[offset + 6] == 1 and bytes[offset + 7] == 1)
                bytes[offset + 2]
            else
                null;
        } else if (descriptor_type == DESCRIPTOR_ENDPOINT and length >= 7 and
            keyboard_interface != null)
        {
            const endpoint_address = bytes[offset + 2];
            const attributes = bytes[offset + 3];
            const max_packet = readLe16(bytes[offset + 4 .. offset + 6]) & 0x7FF;
            if (endpoint_address & 0x80 != 0 and attributes & 0x3 == 0x3 and
                max_packet >= 8 and max_packet <= 64)
            {
                return .{
                    .interface = keyboard_interface.?,
                    .endpoint = @truncate(endpoint_address),
                    .max_packet = @intCast(max_packet),
                };
            }
        }
        offset += length;
    }
    return null;
}

fn controlTransfer(
    controller: Controller,
    address: u7,
    endpoint_zero_packet: u8,
    low_speed: bool,
    packet: SetupPacket,
    data: []u8,
) !void {
    if (data.len > control_data.len) return UsbError.ConfigurationTooLarge;
    if (packet.request_type & 0x80 == 0 and data.len != 0 and data.ptr != control_data[0..].ptr) {
        @memcpy(control_data[0..data.len], data);
    }
    setup_packet = packet;
    var td_count: usize = 0;
    setTd(td_count, PID_SETUP, address, 0, false, 8, try physicalAddress(&setup_packet), low_speed);
    td_count += 1;

    const data_pid: u8 = if (packet.request_type & 0x80 != 0) PID_IN else PID_OUT;
    var offset: usize = 0;
    var toggle = true;
    while (offset < data.len) {
        if (td_count + 1 >= transfer_descriptors.len) return UsbError.ConfigurationTooLarge;
        const length = @min(data.len - offset, endpoint_zero_packet);
        setTd(td_count, data_pid, address, 0, toggle, length, try physicalAddress(&control_data[offset]), low_speed);
        td_count += 1;
        offset += length;
        toggle = !toggle;
    }

    const status_pid: u8 = if (data_pid == PID_IN) PID_OUT else PID_IN;
    setTd(td_count, status_pid, address, 0, true, 0, 0, low_speed);
    td_count += 1;
    linkTds(td_count);
    try executeSchedule(controller, td_count);
    if (data_pid == PID_IN and data.len != 0 and data.ptr != control_data[0..].ptr) {
        @memcpy(data, control_data[0..data.len]);
    }
}

fn setTd(
    index: usize,
    pid: u8,
    address: u7,
    endpoint: u4,
    toggle: bool,
    length: usize,
    buffer_phys: u32,
    low_speed: bool,
) void {
    transfer_descriptors[index] = makeTd(
        pid,
        address,
        endpoint,
        toggle,
        length,
        buffer_phys,
        low_speed,
    );
}

fn makeTd(
    pid: u8,
    address: u7,
    endpoint: u4,
    toggle: bool,
    length: usize,
    buffer_phys: u32,
    low_speed: bool,
) TransferDescriptor {
    return .{
        .link = LINK_TERMINATE,
        .status = TD_ACTIVE | TD_ERROR_COUNT_3 | (if (low_speed) TD_LOW_SPEED else 0),
        .token = token(pid, address, endpoint, toggle, length),
        .buffer = buffer_phys,
        .software = [_]u32{0} ** 4,
    };
}

fn linkTds(count: usize) void {
    var index: usize = 0;
    while (index + 1 < count) : (index += 1) {
        transfer_descriptors[index].link = physicalAddress(&transfer_descriptors[index + 1]) catch unreachable |
            LINK_DEPTH_FIRST;
    }
    transfer_descriptors[count - 1].link = LINK_TERMINATE;
}

fn executeSchedule(controller: Controller, count: usize) !void {
    queue_head.element = try physicalAddress(&transfer_descriptors[0]);
    var remaining = POLL_LIMIT;
    while (remaining > 0) : (remaining -= 1) {
        const status = @as(*volatile u32, @ptrCast(&transfer_descriptors[count - 1].status)).*;
        if (status & TD_ACTIVE == 0) break;
        if (in16(controller, REG_USBSTS) & STS_FATAL_MASK != 0) return UsbError.ControllerFatalError;
        asm volatile ("pause");
    }
    if (remaining == 0) return UsbError.TransferTimeout;
    for (transfer_descriptors[0..count]) |*td| {
        const status = @as(*volatile u32, @ptrCast(&td.status)).*;
        if (status & TD_ERROR_MASK != 0) return UsbError.TransferFailed;
    }
}

fn activateKeyboard(device: KeyboardDevice) !void {
    if (keyboard_count >= keyboards.len) return UsbError.TooManyKeyboards;
    const runtime = &keyboards[keyboard_count];
    runtime.device = device;
    @memset(&runtime.frame_list, LINK_TERMINATE);
    @memset(&runtime.report, 0);
    runtime.queue_head = .{ .horizontal = LINK_TERMINATE, .element = LINK_TERMINATE };
    const queue_head_phys = try physicalAddress(&runtime.queue_head);
    for (&runtime.frame_list) |*entry| entry.* = queue_head_phys | LINK_QUEUE_HEAD;
    try armInterruptTransfer(runtime);

    // The enumeration schedule is shared because control requests are issued
    // serially. Give each discovered keyboard its own permanent schedule before
    // scanning the next UHCI controller.
    stopController(device.controller);
    out16(device.controller, REG_USBINTR, 0);
    out16(device.controller, REG_USBSTS, 0xFFFF);
    out16(device.controller, REG_FRNUM, 0);
    out32(device.controller, REG_FRBASEADD, try physicalAddress(&runtime.frame_list));
    out16(device.controller, REG_USBCMD, CMD_MAX_PACKET_64 | CMD_CONFIGURE | CMD_RUN);
    try waitFrames(device.controller, 2);

    keyboard_count += 1;
    kernel.hardwareBootStatus(
        "USB: keyboard active on {x:0>2}:{x:0>2}.{} endpoint 0x{x}",
        .{
            device.controller.pci.bus,
            device.controller.pci.device,
            device.controller.pci.function,
            @as(u8, device.endpoint) | 0x80,
        },
    );
}

fn armInterruptTransfer(runtime: *KeyboardRuntime) !void {
    const device = &runtime.device;
    @memset(&runtime.report, 0);
    runtime.interrupt_td = makeTd(
        PID_IN,
        device.address,
        device.endpoint,
        device.data_toggle,
        @min(@as(usize, device.max_packet), runtime.report.len),
        try physicalAddress(&runtime.report),
        device.low_speed,
    );
    runtime.queue_head.element = try physicalAddress(&runtime.interrupt_td);
}

pub fn poll() void {
    for (keyboards[0..keyboard_count]) |*runtime| {
        const device = &runtime.device;
        const status = @as(*volatile u32, @ptrCast(&runtime.interrupt_td.status)).*;
        if (status & TD_ACTIVE != 0) continue;
        if (status & TD_ERROR_MASK == 0) {
            processKeyboardReport(device, runtime.report);
            device.data_toggle = !device.data_toggle;
        } else {
            log.warn("USB keyboard interrupt transfer status 0x{x}", .{status});
        }
        armInterruptTransfer(runtime) catch |err| {
            log.err("Could not rearm USB keyboard transfer: {}", .{err});
        };
    }

    // TODO: Replace synchronous application-driven polling with UHCI IRQ
    // completion handling and schedule the endpoint at bInterval cadence.
    // TODO: Recover stalled endpoints with CLEAR_FEATURE(ENDPOINT_HALT).
}

fn processKeyboardReport(device: *KeyboardDevice, report: [8]u8) void {
    const shift = report[0] & ((1 << 1) | (1 << 5)) != 0;
    for (report[2..8]) |usage| {
        if (usage == 0 or containsUsage(device.previous_report, usage)) continue;
        if (usage == 0x39) {
            device.caps_lock = !device.caps_lock;
            continue;
        }
        if (usageToInput(usage, shift, device.caps_lock)) |input| {
            keyboard.KeyboardBuffer.inject(input);
        }
    }
    device.previous_report = report;

    // TODO: Add key-repeat timing and expose press/release plus modifier state
    // as structured events instead of reducing all input to bytes.
    // TODO: Parse general HID report descriptors for non-boot keyboards.
}

fn containsUsage(report: [8]u8, usage: u8) bool {
    for (report[2..8]) |existing| if (existing == usage) return true;
    return false;
}

fn usageToInput(usage: u8, shift: bool, caps_lock: bool) ?u8 {
    if (usage >= 0x04 and usage <= 0x1D) {
        const upper = shift != caps_lock;
        return (if (upper) @as(u8, 'A') else @as(u8, 'a')) + (usage - 0x04);
    }
    if (usage >= 0x1E and usage <= 0x27) {
        const plain = "1234567890";
        const shifted = "!@#$%^&*()";
        return (if (shift) shifted else plain)[usage - 0x1E];
    }
    return switch (usage) {
        0x28 => '\n',
        0x29 => keyboard.InputCode.escape,
        0x2A => 0x08,
        0x2B => '\t',
        0x2C => ' ',
        0x2D => if (shift) '_' else '-',
        0x2E => if (shift) '+' else '=',
        0x2F => if (shift) '{' else '[',
        0x30 => if (shift) '}' else ']',
        0x31 => if (shift) '|' else '\\',
        0x33 => if (shift) ':' else ';',
        0x34 => if (shift) '"' else '\'',
        0x35 => if (shift) '~' else '`',
        0x36 => if (shift) '<' else ',',
        0x37 => if (shift) '>' else '.',
        0x38 => if (shift) '?' else '/',
        0x4F => keyboard.InputCode.arrow_right,
        0x50 => keyboard.InputCode.arrow_left,
        0x51 => keyboard.InputCode.arrow_down,
        0x52 => keyboard.InputCode.arrow_up,
        else => null,
    };
}

fn resetPort(controller: Controller, offset: u16) !void {
    var value = in16(controller, offset);
    if (value & PORT_CONNECTED == 0) return UsbError.PortResetFailed;
    value &= ~(PORT_CONNECT_CHANGE | PORT_ENABLE_CHANGE);
    out16(controller, offset, value | PORT_RESET);
    try waitFrames(controller, 50);
    value = in16(controller, offset) & ~(PORT_CONNECT_CHANGE | PORT_ENABLE_CHANGE | PORT_RESET);
    out16(controller, offset, value);
    try waitFrames(controller, 10);
    value = in16(controller, offset) & ~(PORT_CONNECT_CHANGE | PORT_ENABLE_CHANGE | PORT_RESET);
    out16(controller, offset, value | PORT_ENABLED);
    try waitFrames(controller, 2);
    if (in16(controller, offset) & (PORT_CONNECTED | PORT_ENABLED) !=
        (PORT_CONNECTED | PORT_ENABLED)) return UsbError.PortResetFailed;
    out16(controller, offset, in16(controller, offset) | PORT_CONNECT_CHANGE | PORT_ENABLE_CHANGE);
}

fn waitFrames(controller: Controller, frames: u16) !void {
    const start = in16(controller, REG_FRNUM) & 0x7FF;
    var remaining = POLL_LIMIT;
    while (remaining > 0) : (remaining -= 1) {
        const current = in16(controller, REG_FRNUM) & 0x7FF;
        if ((current -% start) & 0x7FF >= frames) return;
        if (in16(controller, REG_USBSTS) & STS_FATAL_MASK != 0) {
            return UsbError.ControllerFatalError;
        }
        asm volatile ("pause");
    }
    return UsbError.TransferTimeout;
}

fn token(pid: u8, address: u7, endpoint: u4, toggle: bool, length: usize) u32 {
    const encoded_length: u32 = if (length == 0) 0x7FF else @intCast(length - 1);
    return (encoded_length << 21) |
        (@as(u32, @intFromBool(toggle)) << 19) |
        (@as(u32, endpoint) << 15) |
        (@as(u32, address) << 8) |
        pid;
}

fn physicalAddress(pointer: anytype) !u32 {
    const virtual = @intFromPtr(pointer);
    const offset = kernel.state.mem_manager.memory_layout.kernel_offset;
    if (virtual < offset) return UsbError.DmaAddressTooHigh;
    const physical = virtual - offset;
    if (physical > std.math.maxInt(u32)) return UsbError.DmaAddressTooHigh;
    return @intCast(physical);
}

fn stopController(controller: Controller) void {
    out16(controller, REG_USBCMD, in16(controller, REG_USBCMD) & ~CMD_RUN);
}

fn pciConfigAddress(address: PciAddress, offset: u8) u32 {
    return 0x8000_0000 |
        (@as(u32, address.bus) << 16) |
        (@as(u32, address.device) << 11) |
        (@as(u32, address.function) << 8) |
        (offset & 0xFC);
}

fn pciRead32(address: PciAddress, offset: u8) u32 {
    arch.outl(PCI_CONFIG_ADDRESS, pciConfigAddress(address, offset));
    return arch.inl(PCI_CONFIG_DATA);
}

fn pciRead16(address: PciAddress, offset: u8) u16 {
    arch.outl(PCI_CONFIG_ADDRESS, pciConfigAddress(address, offset));
    return arch.cpu.inw(PCI_CONFIG_DATA + (offset & 2));
}

fn pciWrite16(address: PciAddress, offset: u8, value: u16) void {
    arch.outl(PCI_CONFIG_ADDRESS, pciConfigAddress(address, offset));
    arch.cpu.outw(PCI_CONFIG_DATA + (offset & 2), value);
}

fn in16(controller: Controller, offset: u16) u16 {
    return arch.cpu.inw(controller.io_base + offset);
}

fn out16(controller: Controller, offset: u16, value: u16) void {
    arch.cpu.outw(controller.io_base + offset, value);
}

fn out32(controller: Controller, offset: u16, value: u32) void {
    arch.cpu.outl(controller.io_base + offset, value);
}

fn readLe16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

comptime {
    std.debug.assert(@sizeOf(SetupPacket) == 8);
    std.debug.assert(@sizeOf(TransferDescriptor) == 32);
    std.debug.assert(@sizeOf(QueueHead) == 8);
}
