// src/drivers/ata.zig
const std = @import("std");
const arch = @import("arch");
const kernel = @import("kernel");
const block_device = @import("block_device.zig");

const log = std.log.scoped(.drivers_ata);
const log_verbose = std.log.scoped(.drivers_ata_verbose);
const log_hyper_verbose = std.log.scoped(.drivers_ata_hyper_verbose);

pub const AtaError = error{
    NoDevice,
    DeviceError,
    Timeout,
    InvalidCommand,
    BadSector,
    ControllerNotFound,
    UnsupportedDevice,
    DeviceBusy,
    InvalidParameters,
    OperationInProgress,
};

pub const AtaCommand = enum(u8) {
    READ_PIO = 0x20,
    READ_PIO_EXT = 0x24,
    READ_DMA = 0xC8,
    READ_DMA_EXT = 0x25,
    WRITE_PIO = 0x30,
    WRITE_PIO_EXT = 0x34,
    WRITE_DMA = 0xCA,
    WRITE_DMA_EXT = 0x35,
    CACHE_FLUSH = 0xE7,
    CACHE_FLUSH_EXT = 0xEA,
    PACKET = 0xA0,
    IDENTIFY_PACKET = 0xA1,
    IDENTIFY = 0xEC,
    SET_FEATURES = 0xEF,

    // Multi-sector commands
    // TODO @(dleiferives,f05f56e1-b4f6-4e4f-9bfa-f00b1dd5e5a9): I don't think
    // that I got these working super good lol ~#
    READ_MULTIPLE = 0xC4,
    READ_MULTIPLE_EXT = 0x29,
    WRITE_MULTIPLE = 0xC5,
    WRITE_MULTIPLE_EXT = 0x39,
    SET_MULTIPLE = 0xC6,
};

// Status Register bits
pub const AtaStatus = packed struct {
    err: bool, // Error
    idx: bool, // Index (always 0)
    corr: bool, // Corrected data (always 0)
    drq: bool, // Data request ready
    srv: bool, // Service request
    df: bool, // Drive fault
    rdy: bool, // Drive ready
    bsy: bool, // Busy

    pub fn fromByte(byte: u8) AtaStatus {
        return @bitCast(byte);
    }

    pub fn toByte(self: AtaStatus) u8 {
        return @bitCast(self);
    }
};

// Error Register bits
pub const AtaErrorReg = packed struct {
    amnf: bool, // Address mark not found
    tk0nf: bool, // Track 0 not found
    abrt: bool, // Aborted command
    mcr: bool, // Media change request
    idnf: bool, // ID not found
    mc: bool, // Media changed
    unc: bool, // Uncorrectable data error
    bbk: bool, // Bad block detected

    pub fn fromByte(byte: u8) AtaErrorReg {
        return @bitCast(byte);
    }
};

// I/O Base Port registers
pub const DataPortReg = enum(u8) {
    DATA = 0, // RW
    ERROR = 1, // R
    SECTOR_COUNT = 2, // RW
    LBA_LOW = 3, // RW
    LBA_MID = 4, // RW
    LBA_HIGH = 5, // RW
    DRIVE_HEAD = 6, // RW
    STATUS = 7, // R
};

pub const DataPortWrite = enum(u8) {
    DATA = 0, // RW
    FEATURES = 1, // W
    SECTOR_COUNT = 2, // RW
    LBA_LOW = 3, // RW
    LBA_MID = 4, // RW
    LBA_HIGH = 5, // RW
    DRIVE_HEAD = 6, // RW
    COMMAND = 7, // W
};

pub const ControlPortReg = enum(u8) {
    ALT_STATUS = 0, // R
    DRIVE_ADDRESS = 1, // R
};

pub const ControlPortWrite = enum(u8) {
    DEVICE_CONTROL = 0, // W
};

pub const DeviceType = enum {
    NONE,
    PATA,
    SATA,
    PATAPI,
    SATAPI,
    UNKNOWN,
};

pub const DriveSelect = enum(u1) {
    LITCH = 0,
    THRALL = 1,
};

pub const Channel = enum(u1) {
    PRIMARY = 0,
    SECONDARY = 1,
};

pub const OperationType = enum {
    NONE,
    read_sector,
    write_sector,
    read_sectors,
    write_sectors,
    flush_cache,
    identify,
};

pub const OperationState = enum {
    IDLE,
    COMMAND_SENT,
    DATA_TRANSFER,
    COMPLETING,
    COMPLETED,
    ERROR,
};

pub const TransferMode = enum {
    SINGLE_SECTOR,
    MULTI_SECTOR,
};

// Operation context for tracking async operations
pub const OperationContext = struct {
    operation: OperationType = .NONE,
    state: OperationState = .IDLE,
    device_idx: u8 = 0,
    lba: u64 = 0,
    sector_count: u16 = 0,
    current_sector: u16 = 0,
    sectors_per_interrupt: u16 = 1, // How many sectors to transfer per interrupt
    buffer: ?[]u8 = null,
    const_buffer: ?[]const u8 = null,
    error_code: ?AtaError = null,
    waiting_thread: ?*kernel.thread.Thread = null,
    completed: bool = false,
    transfer_mode: TransferMode = .SINGLE_SECTOR,

    pub fn reset(self: *OperationContext) void {
        self.* = OperationContext{};
    }

    pub fn isActive(self: *const OperationContext) bool {
        return self.state != .IDLE and self.state != .COMPLETED and self.state != .ERROR;
    }

    pub fn getSectorsRemaining(self: *const OperationContext) u16 {
        return self.sector_count - self.current_sector;
    }

    pub fn getSectorsToTransfer(self: *const OperationContext) u16 {
        const remaining = self.getSectorsRemaining();
        return @min(remaining, self.sectors_per_interrupt);
    }
};


pub const ChannelRegs = struct {
    base: u16,
    ctrl: u16,
    bmide: u16,
    irq: u8,
    enabled: bool = false,

    // Operation tracking
    current_operation: OperationContext = .{},
    operation_mutex: kernel.mutex.Mutex = .{},

    // Timeout handling
    timeout_ms: u32 = 5000, // 5 second timeout
    operation_start_time: u64 = 0,
};

pub const DeviceInfo = struct {
    exists: bool = false,
    channel: Channel,
    drive: DriveSelect,
    device_type: DeviceType = .NONE,
    signature: u16 = 0,
    capabilities: u16 = 0,
    command_sets: u32 = 0,
    size: u64 = 0,
    model: [41]u8 = [_]u8{0} ** 41,
    block_device: ?*block_device.BlockDev = null,

    supports_lba48: bool = false,
    max_lba28: u32 = 0,
    max_lba48: u64 = 0,

    // Performance.. what a joke
    supports_dma: bool = false,
    supports_write_cache: bool = false,
    supports_read_ahead: bool = false,
    supports_multiple: bool = false,
    multiple_sector_count: u8 = 1,
    max_multiple_sectors: u8 = 1,
};

fn fastReadSectors(port: u16, buffer: []u8, sector_count: u16) void {
    const word_count = sector_count * 256;
    const buffer_ptr = @as([*]u16, @ptrCast(@alignCast(buffer.ptr)));

    asm volatile (
        \\cld
        \\rep insw
        :
        : [port] "{dx}" (port),
          [count] "{cx}" (word_count),
          [buffer_in] "{Di}" (buffer_ptr),
        : "memory", "dx", "cx", "di"
    );
}

fn fastWriteSectors(port: u16, buffer: []const u8, sector_count: u16) void {
    const word_count = sector_count * 256;
    const buffer_ptr = @as([*]const u16, @ptrCast(@alignCast(buffer.ptr)));

    asm volatile (
        \\cld
        \\rep outsw
        :
        : [port] "{dx}" (port),
          [count] "{cx}" (word_count),
          [buffer] "{Si}" (buffer_ptr),
        : "memory", "dx", "cx", "si"
    );
}

fn readSectorWords(port: u16, buffer: []u8) void {
    const buffer_u16: [*]u16 = @ptrCast(@alignCast(buffer.ptr));

    for (0..256) |i| {
        buffer_u16[i] = asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> u16),
            : [port] "N{dx}" (port),
        );
    }
}

fn writeSectorWords(port: u16, buffer: []const u8) void {
    const buffer_u16: [*]const u16 = @ptrCast(@alignCast(buffer.ptr));

    for (0..256) |i| {
        asm volatile ("outw %[data], %[port]"
            :
            : [data] "{ax}" (buffer_u16[i]),
              [port] "N{dx}" (port),
        );
    }
}

pub const AtaController = struct {
    channels: [2]ChannelRegs,
    devices: [4]DeviceInfo,
    allocator: std.mem.Allocator,

    // Global operation mutex to prevent conflicts
    global_mutex: kernel.mutex.Mutex = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        log.info("Creating ATA controller instance", .{});

        const controller = try allocator.create(Self);
        controller.* = Self{
            .channels = [_]ChannelRegs{
                .{ .base = 0x1F0, .ctrl = 0x3F6, .bmide = 0, .irq = 14 },
                .{ .base = 0x170, .ctrl = 0x376, .bmide = 0, .irq = 15 },
            },
            .devices = [_]DeviceInfo{.{
                .channel = .PRIMARY,
                .drive = .LITCH,
            }} ** 4,
            .allocator = allocator,
        };

        log_verbose.info("Controller initialized with channels: Primary(0x{X}, IRQ {}), Secondary(0x{X}, IRQ {})", .{
            controller.channels[0].base, controller.channels[0].irq,
            controller.channels[1].base, controller.channels[1].irq
        });

        return controller;
    }

    pub fn deinit(self: *Self) void {
        log.info("Shutting down ATA controller", .{});

        // Unregister IRQ handlers
        for (0..2) |ch_idx| {
            if (self.channels[ch_idx].enabled) {
                arch.irq.irq.unregisterIrq(self.channels[ch_idx].irq) catch {
                    log.err("Failed to unregister IRQ {} for channel {}", .{
                        self.channels[ch_idx].irq, ch_idx
                    });
                };
            }
        }

        self.allocator.destroy(self);
    }

    pub fn detectController(self: *Self) !void {
        log.info("Detecting ATA/IDE controller...", .{});

        log_verbose.info("Testing primary channel existence", .{});
        if (self.testChannelExists(.PRIMARY)) {
            self.channels[0].enabled = true;
            log.info("Primary ATA channel detected at base 0x{X}", .{self.channels[0].base});
        } else {
            log.info("Primary ATA channel not detected", .{});
        }

        log_verbose.info("Testing secondary channel existence", .{});
        if (self.testChannelExists(.SECONDARY)) {
            self.channels[1].enabled = true;
            log.info("Secondary ATA channel detected at base 0x{X}", .{self.channels[1].base});
        } else {
            log.info("Secondary ATA channel not detected", .{});
        }

        if (!self.channels[0].enabled and !self.channels[1].enabled) {
            log.err("No ATA controllers found - all channels failed detection", .{});
            return AtaError.ControllerNotFound;
        }

        log.info("Controller detection complete - {} channels enabled", .{
            (@as(u8, if (self.channels[0].enabled) 1 else 0) +
            @as(u8, if (self.channels[1].enabled) 1 else 0))
        });
    }

    fn testChannelExists(self: *Self, channel: Channel) bool {
        const ch_idx = @intFromEnum(channel);
        log_verbose.info("Reading status register from channel {}", .{ch_idx});

        const status = self.readDataPort(channel, .STATUS);
        log_verbose.info("Channel {} status register read: 0x{X:0>2}", .{ ch_idx, status });

        // Check for "floating" bus
        if (status == 0xFF) {
            log_verbose.info("Channel {} floating bus detected (status=0xFF)", .{ch_idx});
            return false;
        }

        log_verbose.info("Channel {} appears to exist (status=0x{X:0>2})", .{ ch_idx, status });
        return true;
    }

    pub fn initializeChannels(self: *Self) !void {
        log.info("Initializing ATA channels...", .{});

        var successfully_initialized: u8 = 0;
        ata_controller = self;

        for (0..2) |ch_idx| {
            const channel: Channel = @enumFromInt(ch_idx);
            if (!self.channels[ch_idx].enabled) {
                log_verbose.info("Skipping disabled channel {}", .{ch_idx});
                continue;
            }

            log.info("Initializing channel {} (base=0x{X}, ctrl=0x{X}, IRQ={})", .{
                ch_idx, self.channels[ch_idx].base, self.channels[ch_idx].ctrl, self.channels[ch_idx].irq
            });

            log_verbose.info("Disabling interrupts on channel {}", .{ch_idx});
            self.writeControlPort(channel, .DEVICE_CONTROL, 0x02);

            log_verbose.info("Performing soft reset on channel {}", .{ch_idx});
            if (self.softReset(channel)) {
                log_verbose.info("Soft reset completed on channel {}", .{ch_idx});
            } else |err| {
                log.err("Soft reset failed on channel {}: {} - disabling channel", .{ ch_idx, err });
                self.channels[ch_idx].enabled = false;
                continue;
            }

            log_verbose.info("Enabling interrupts on channel {}", .{ch_idx});
            self.writeControlPort(channel, .DEVICE_CONTROL, 0x00);

            log_verbose.info("Registering IRQ {} handler for channel {}", .{ self.channels[ch_idx].irq, ch_idx });
            if (arch.irq.irq.registerIrq(self.channels[ch_idx].irq, switch (channel) {
                .PRIMARY => primaryIrqHandler,
                .SECONDARY => secondaryIrqHandler,
            })) {
                log.info("Channel {} initialized successfully - IRQ {} registered", .{
                    ch_idx, self.channels[ch_idx].irq
                });
                successfully_initialized += 1;
            } else |err| {
                log.err("Failed to register IRQ {} for channel {}: {} - disabling channel", .{
                    self.channels[ch_idx].irq, ch_idx, err
                });
                self.channels[ch_idx].enabled = false;
                continue;
            }
        }

        if (successfully_initialized == 0) {
            log.err("No ATA channels could be initialized successfully", .{});
            return AtaError.ControllerNotFound;
        }

        log.info("{} ATA channels initialized successfully", .{successfully_initialized});
    }

    pub fn detectDevices(self: *Self) !void {
        log.info("Detecting ATA devices...", .{});

        var device_count: u32 = 0;

        for (0..2) |ch_idx| {
            const channel: Channel = @enumFromInt(ch_idx);
            if (!self.channels[ch_idx].enabled) {
                log_verbose.info("Skipping device detection on disabled channel {}", .{ch_idx});
                continue;
            }

            log_verbose.info("Scanning devices on channel {}", .{ch_idx});

            for (0..2) |drive_idx| {
                const drive: DriveSelect = @enumFromInt(drive_idx);
                const device_idx = ch_idx * 2 + drive_idx;

                log_verbose.info("Checking channel {}, drive {} (device index {})", .{
                    ch_idx, drive_idx, device_idx
                });

                if (self.identifyDevice(channel, drive)) |device_info| {
                    self.devices[device_idx] = device_info;
                    self.devices[device_idx].exists = true;
                    device_count += 1;

                    const model_len = std.mem.indexOfScalar(u8, &device_info.model, 0) orelse device_info.model.len;
                    log.info("Found {} device on channel {}, drive {}: {s} ({} MB)", .{
                        device_info.device_type, ch_idx, drive_idx,
                        device_info.model[0..model_len], device_info.size / (1024 * 1024)
                    });

                    log_verbose.info("Device details - LBA48: {}, DMA: {}, Write Cache: {}, Multiple: {} ({})", .{
                        device_info.supports_lba48, device_info.supports_dma, device_info.supports_write_cache,
                        device_info.supports_multiple, device_info.multiple_sector_count
                    });

                    // Set up multiple sector support if available
                    if (device_info.supports_multiple) {
                        try self.setMultipleSectors(device_idx, device_info.max_multiple_sectors);
                    }

                    // Register as block device
                    if (device_info.device_type == .PATA or device_info.device_type == .SATA) {
                        log_verbose.info("Registering device {} as block device", .{device_idx});
                        try self.registerBlockDevice(device_idx);
                        log_verbose.info("Device {} registered successfully", .{device_idx});
                    }
                } else |err| {
                    log_verbose.info("No device on channel {}, drive {}: {}", .{ ch_idx, drive_idx, err });
                }
            }
        }

        log.info("Device detection complete - found {} devices total", .{device_count});
        if (device_count == 0) {
            log.err("No ATA devices detected on any channel", .{});
        }
    }

    fn identifyDevice(self: *Self, channel: Channel, drive: DriveSelect) !DeviceInfo {
        const ch_idx = @intFromEnum(channel);
        const drive_idx = @intFromEnum(drive);

        log_verbose.info("Starting device identification for channel {}, drive {}", .{ ch_idx, drive_idx });

        // Going to do this synchronously for now
        // Step 1: Select the drive
        const drive_select: u8 = 0xA0 | (@as(u8, @intFromEnum(drive)) << 4);
        log_verbose.info("Selecting drive with value 0x{X:0>2}", .{drive_select});
        self.writeDataPort(channel, .DRIVE_HEAD, drive_select);

        // Step 2: Wait for drive selection
        self.delay400ns(channel);

        // Step 3: Clear the status register
        log_verbose.info("Clearing LBA and sector count registers", .{});
        self.writeDataPort(channel, .SECTOR_COUNT, 0);
        self.writeDataPort(channel, .LBA_LOW, 0);
        self.writeDataPort(channel, .LBA_MID, 0);
        self.writeDataPort(channel, .LBA_HIGH, 0);

        // Step 4: Identify
        log_verbose.info("Sending IDENTIFY command (0x{X:0>2})", .{@intFromEnum(AtaCommand.IDENTIFY)});
        self.writeDataPort(channel, .COMMAND, @intFromEnum(AtaCommand.IDENTIFY));

        // Step 5: Check if the device exists
        var status = self.readDataPort(channel, .STATUS);
        log_verbose.info("Initial status after IDENTIFY: 0x{X:0>2}", .{status});

        if (status == 0) {
            log_verbose.info("Status is 0 - no device present", .{});
            return AtaError.NoDevice;
        }

        log_verbose.info("Waiting for BSY bit to clear", .{});
        var timeout: u32 = 10000;
        while ((status & 0x80) != 0 and timeout > 0) : (timeout -= 1) {
            status = self.readDataPort(channel, .STATUS);
        }

        if (timeout == 0) {
            log_verbose.info("Timeout waiting for BSY to clear (final status: 0x{X:0>2})", .{status});
            return AtaError.Timeout;
        }

        log_verbose.info("BSY cleared, final status: 0x{X:0>2}", .{status});

        // Step 6: Check for ATAPI device
        const lba_mid = self.readDataPort(channel, .LBA_MID);
        const lba_high = self.readDataPort(channel, .LBA_HIGH);
        log_verbose.info("Device signature: LBA_MID=0x{X:0>2}, LBA_HIGH=0x{X:0>2}", .{ lba_mid, lba_high });

        var device_type: DeviceType = .UNKNOWN;

        if (lba_mid == 0x14 and lba_high == 0xEB) {
            device_type = .PATAPI;
            log_verbose.info("Detected PATAPI device", .{});
        } else if (lba_mid == 0x69 and lba_high == 0x96) {
            device_type = .SATAPI;
            log_verbose.info("Detected SATAPI device", .{});
        } else if (lba_mid == 0x3C and lba_high == 0xC3) {
            device_type = .SATA;
            log_verbose.info("Detected SATA device", .{});
        } else if (lba_mid == 0x00 and lba_high == 0x00) {
            device_type = .PATA;
            log_verbose.info("Detected PATA device", .{});
        } else {
            log_verbose.info("Unknown device type with signature 0x{X:0>2}:0x{X:0>2}", .{ lba_mid, lba_high });
            return AtaError.UnsupportedDevice;
        }

        if (device_type == .PATAPI or device_type == .SATAPI) {
            log_verbose.info("Sending IDENTIFY PACKET command for ATAPI device", .{});
            self.writeDataPort(channel, .COMMAND, @intFromEnum(AtaCommand.IDENTIFY_PACKET));
        }

        log_verbose.info("Waiting for DRQ or ERR bit", .{});
        timeout = 10000;
        while (timeout > 0) : (timeout -= 1) {
            status = self.readDataPort(channel, .STATUS);
            if ((status & 0x01) != 0) {
                log_verbose.info("ERR bit set in status: 0x{X:0>2}", .{status});
                return AtaError.DeviceError; // ERR bit
            }
            if ((status & 0x08) != 0) {
                log_verbose.info("DRQ bit set, ready to read data", .{});
                break; // DRQ bit
            }
        }

        if (timeout == 0) {
            log_verbose.info("Timeout waiting for DRQ/ERR (final status: 0x{X:0>2})", .{status});
            return AtaError.Timeout;
        }

        // Step 7: Read identification data using fast transfer
        log_verbose.info("Reading 512 bytes of identification data", .{});
        var identify_buffer: [512]u8 = undefined;
        readSectorWords(self.channels[ch_idx].base, &identify_buffer);

        const identify_data: *[256]u16 = @ptrCast(@alignCast(&identify_buffer));
        log_verbose.info("Identification data read complete", .{});

        var device_info = DeviceInfo{
            .exists = true,
            .channel = channel,
            .drive = drive,
            .device_type = device_type,
            .signature = identify_data[0],
            .capabilities = identify_data[49],
            .command_sets = @as(u32, identify_data[82]) | (@as(u32, identify_data[83]) << 16),
        };

        log_verbose.info("Device signature: 0x{X:0>4}, capabilities: 0x{X:0>4}, command_sets: 0x{X:0>8}", .{
            device_info.signature, device_info.capabilities, device_info.command_sets
        });

        // Step 8: Advanced features
        device_info.supports_dma = (device_info.capabilities & (1 << 8)) != 0;
        device_info.supports_write_cache = (identify_data[82] & (1 << 5)) != 0;
        device_info.supports_read_ahead = (identify_data[82] & (1 << 6)) != 0;

        // Check for multiple sector support
        device_info.supports_multiple = (identify_data[47] & 0xFF) > 1;
        device_info.max_multiple_sectors = @truncate(identify_data[47] & 0xFF);
        if (device_info.supports_multiple) {
            device_info.multiple_sector_count = @min(device_info.max_multiple_sectors, 16);
            log_verbose.info("Device supports multiple sector transfers: max={}, setting={}", .{
                device_info.max_multiple_sectors, device_info.multiple_sector_count
            });
        }

        // Step 9: Get the model string
        log_verbose.info("Extracting model string from identification data", .{});
        for (0..20) |i| {
            const word = identify_data[27 + i];
            device_info.model[i * 2] = @truncate(word >> 8);
            device_info.model[i * 2 + 1] = @truncate(word);
        }
        device_info.model[40] = 0; // Null terminate

        var model_end: usize = 39;
        while (model_end > 0 and device_info.model[model_end] == ' ') {
            device_info.model[model_end] = 0;
            model_end -= 1;
        }

        // Step 10: Check for LBA support
        if ((device_info.command_sets & (1 << 26)) != 0) {
            device_info.supports_lba48 = true;
            device_info.max_lba48 = @as(u64, identify_data[100]) |
                (@as(u64, identify_data[101]) << 16) |
                (@as(u64, identify_data[102]) << 32) |
                (@as(u64, identify_data[103]) << 48);
            device_info.size = device_info.max_lba48 * 512;
            log_verbose.info("Device supports LBA48 - max LBA: 0x{X}, size: {} bytes", .{
                device_info.max_lba48, device_info.size
            });
        } else {
            device_info.max_lba28 = @as(u32, identify_data[60]) | (@as(u32, identify_data[61]) << 16);
            device_info.size = @as(u64, device_info.max_lba28) * 512;
            log_verbose.info("Device uses LBA28 - max LBA: 0x{X}, size: {} bytes", .{
                device_info.max_lba28, device_info.size
            });
        }

        const model_len = std.mem.indexOfScalar(u8, &device_info.model, 0) orelse device_info.model.len;
        log_verbose.info("Device identification complete - model: {s}", .{device_info.model[0..model_len]});

        return device_info;
    }

    fn setMultipleSectors(self: *Self, device_idx: usize, sector_count: u8) !void {
        const device = &self.devices[device_idx];
        const channel = device.channel;
        const drive = device.drive;

        if (!device.supports_multiple) {
            return;
        }

        log_verbose.info("Setting multiple sector count to {} for device {}", .{ sector_count, device_idx });

        // Select drive
        const drive_select: u8 = 0xA0 | (@as(u8, @intFromEnum(drive)) << 4);
        self.writeDataPort(channel, .DRIVE_HEAD, drive_select);
        self.delay400ns(channel);

        // Set sector count
        self.writeDataPort(channel, .SECTOR_COUNT, sector_count);

        // Send SET MULTIPLE command
        self.writeDataPort(channel, .COMMAND, @intFromEnum(AtaCommand.SET_MULTIPLE));

        // Wait for completion
        var timeout: u32 = 1000;
        while (timeout > 0) : (timeout -= 1) {
            const status = self.readDataPort(channel, .STATUS);
            if ((status & 0x80) == 0) { // BSY cleared
                if ((status & 0x01) != 0) { // ERR set
                    log.err("Failed to set multiple sectors for device {}", .{device_idx});
                    return AtaError.DeviceError;
                }
                break;
            }
        }

        if (timeout == 0) {
            log.err("Timeout setting multiple sectors for device {}", .{device_idx});
            return AtaError.Timeout;
        }

        self.devices[device_idx].multiple_sector_count = sector_count;
        log.info("Successfully set multiple sector count to {} for device {}", .{ sector_count, device_idx });
    }

    fn registerBlockDevice(self: *Self, device_idx: usize) !void {
        const device = &self.devices[device_idx];
        if (!device.exists or device.device_type == .PATAPI or device.device_type == .SATAPI) {
            log_verbose.info("Skipping block device registration for device {} (ATAPI or non-existent)", .{device_idx});
            return;
        }

        log_verbose.info("Creating block device structure for device {}", .{device_idx});
        const block_dev = try self.allocator.create(block_device.BlockDev);

        // Make a name
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "ata{}:{}", .{
            @intFromEnum(device.channel), @intFromEnum(device.drive)
        }) catch "ata";
        log_verbose.info("Generated device name: {s}", .{name});

        const name_copy = try self.allocator.dupe(u8, name);

        block_dev.* = block_device.BlockDev{
            .tot_length = device.size,
            .read_block = ataReadBlock,
            .read_blocks = ataReadBlocks,
            .blk_size = 512,
            .dev_type = .MASS_STORAGE,
            .name = name_copy,
            .fs_type = 0,
            .next = null,
        };

        device.block_device = block_dev;

        log_verbose.info("Block device configured: name={s}, size={} bytes, block_size=512", .{
            name_copy, device.size
        });

        log_verbose.info("Registering block device {s} with block device subsystem", .{name_copy});
        block_device.registerBlockDevice(block_dev);
        log.info("Block device {s} registered successfully", .{name_copy});
    }

    pub fn readSector(self: *Self, device_idx: usize, lba: u64, buffer: []u8) !void {
        return self.readSectors(device_idx, lba, 1, buffer);
    }

    pub fn readSectors(self: *Self, device_idx: usize, lba: u64, sector_count: u16, buffer: []u8) !void {
        // std.log.debug("ReadSectors: device={}, LBA={}, sectors={}", .{
            // device_idx, lba, sector_count
        // });
        if (buffer.len < @as(u64, @intCast(sector_count)) * 512) {
            log.err("Buffer too small for sector read: {} bytes (need {})", .{
                buffer.len, sector_count * 512
            });
            return AtaError.InvalidParameters;
        }

        log_hyper_verbose.info("Async read: device={}, LBA={}, sectors={}", .{
            device_idx, lba, sector_count
        });

        const device = &self.devices[device_idx];
        if (!device.exists) {
            return AtaError.NoDevice;
        }

        const channel = device.channel;
        const ch_idx = @intFromEnum(channel);

        // Acquire channel mutex
        self.channels[ch_idx].operation_mutex.lock();
        defer self.channels[ch_idx].operation_mutex.unlock();

        // Check if channel is busy
        if (self.channels[ch_idx].current_operation.isActive()) {
            return AtaError.OperationInProgress;
        }

        // Choose transfer mode and sectors per interrupt
        const transfer_mode: TransferMode = if (device.supports_multiple and sector_count > 1)
            .MULTI_SECTOR else .SINGLE_SECTOR;

        const sectors_per_interrupt: u16 = if (transfer_mode == .MULTI_SECTOR)
            @min(device.multiple_sector_count, sector_count) else 1;

        // Set up operation context
        var operation = &self.channels[ch_idx].current_operation;
        operation.reset();
        operation.operation = .read_sectors;
        operation.device_idx = @intCast(device_idx);
        operation.lba = lba;
        operation.sector_count = sector_count;
        operation.current_sector = 0;
        operation.sectors_per_interrupt = sectors_per_interrupt;
        operation.transfer_mode = transfer_mode;
        operation.buffer = buffer;
        operation.waiting_thread = kernel.thread.getCurrentThread();
        operation.state = .COMMAND_SENT;

        log_verbose.info("Starting {} read: {} sectors, {} per interrupt", .{
            transfer_mode, sector_count, sectors_per_interrupt
        });

        try self.startReadOperation(device_idx, lba, sector_count, transfer_mode);

        // Block until operation completes
        try self.waitForOperation(channel);

        if (operation.error_code) |err| {
            return err;
        }

        log_verbose.info("Successfully read {} sectors from device {}", .{ sector_count, device_idx });
    }

    pub fn writeSector(self: *Self, device_idx: usize, lba: u64, buffer: []const u8) !void {
        return self.writeSectors(device_idx, lba, 1, buffer);
    }

    pub fn writeSectors(self: *Self, device_idx: usize, lba: u64, sector_count: u16, buffer: []const u8) !void {
        if (buffer.len < sector_count * 512) {
            log.err("Buffer too small for sector write: {} bytes (need {})", .{
                buffer.len, sector_count * 512
            });
            return AtaError.InvalidParameters;
        }

        log_hyper_verbose.info("Async write: device={}, LBA={}, sectors={}", .{
            device_idx, lba, sector_count
        });

        const device = &self.devices[device_idx];
        if (!device.exists) {
            return AtaError.NoDevice;
        }

        const channel = device.channel;
        const ch_idx = @intFromEnum(channel);

        // Acquire channel mutex
        self.channels[ch_idx].operation_mutex.lock();
        defer self.channels[ch_idx].operation_mutex.unlock();

        // Check if channel is busy
        if (self.channels[ch_idx].current_operation.isActive()) {
            return AtaError.OperationInProgress;
        }

        // Choose transfer mode and sectors per interrupt
        const transfer_mode: TransferMode = if (device.supports_multiple and sector_count > 1)
            .MULTI_SECTOR else .SINGLE_SECTOR;

        const sectors_per_interrupt: u16 = if (transfer_mode == .MULTI_SECTOR)
            @min(device.multiple_sector_count, sector_count) else 1;

        // Set up operation context
        var operation = &self.channels[ch_idx].current_operation;
        operation.reset();
        operation.operation = .write_sectors;
        operation.device_idx = @intCast(device_idx);
        operation.lba = lba;
        operation.sector_count = sector_count;
        operation.current_sector = 0;
        operation.sectors_per_interrupt = sectors_per_interrupt;
        operation.transfer_mode = transfer_mode;
        operation.const_buffer = buffer;
        operation.waiting_thread = kernel.thread.getCurrentThread();
        operation.state = .COMMAND_SENT;

        log_verbose.info("Starting {} write: {} sectors, {} per interrupt", .{
            transfer_mode, sector_count, sectors_per_interrupt
        });

        try self.startWriteOperation(device_idx, lba, sector_count, transfer_mode);

        try self.waitForOperation(channel);

        if (operation.error_code) |err| {
            return err;
        }

        log_verbose.info("Successfully wrote {} sectors to device {}", .{ sector_count, device_idx });
    }

    pub fn flushCache(self: *Self, device_idx: usize) !void {
        log_hyper_verbose.info("Async flush: device={}", .{device_idx});

        const device = &self.devices[device_idx];
        if (!device.exists) {
            return AtaError.NoDevice;
        }

        if (!device.supports_write_cache) {
            log_verbose.info("Device {} does not support write cache - flush not needed", .{device_idx});
            return;
        }

        const channel = device.channel;
        const ch_idx = @intFromEnum(channel);

        // Acquire channel mutex
        self.channels[ch_idx].operation_mutex.lock();
        defer self.channels[ch_idx].operation_mutex.unlock();

        // Check if channel is busy
        if (self.channels[ch_idx].current_operation.isActive()) {
            return AtaError.OperationInProgress;
        }

        // Set up operation context
        var operation = &self.channels[ch_idx].current_operation;
        operation.reset();
        operation.operation = .flush_cache;
        operation.device_idx = @intCast(device_idx);
        operation.waiting_thread = kernel.thread.getCurrentThread();
        operation.state = .COMMAND_SENT;

        try self.startFlushOperation(device_idx);

        try self.waitForOperation(channel);

        if (operation.error_code) |err| {
            return err;
        }

        log_verbose.info("Cache flush completed for device {}", .{device_idx});
    }


    fn startReadOperation(self: *Self, device_idx: usize, lba: u64, sector_count: u16, transfer_mode: TransferMode) !void {
        const device = &self.devices[device_idx];
        const channel = device.channel;
        const drive = device.drive;

        try self.setupLbaCommand(channel, drive, lba, sector_count, true);

        // Choose appropriate command based on transfer mode
        const command = if (transfer_mode == .MULTI_SECTOR and device.supports_multiple) blk: {
            if (device.supports_lba48 and lba >= 0x10000000) {
                break :blk AtaCommand.READ_MULTIPLE_EXT;
            } else {
                break :blk AtaCommand.READ_MULTIPLE;
            }
        } else blk: {
            if (device.supports_lba48 and lba >= 0x10000000) {
                break :blk AtaCommand.READ_PIO_EXT;
            } else {
                break :blk AtaCommand.READ_PIO;
            }
        };

        log_verbose.info("Sending read command: {} for {} sectors", .{ command, sector_count });
        self.writeDataPort(channel, .COMMAND, @intFromEnum(command));

        // Record operation start time for timeout
        // TODO @(dleiferives,cf01795b-fea3-4ea5-8f20-e248b29f7cb2): get the time
        // system up and running ~#
        const ch_idx = @intFromEnum(channel);
        self.channels[ch_idx].operation_start_time = getCurrentTimeMs();
    }

    fn startWriteOperation(self: *Self, device_idx: usize, lba: u64, sector_count: u16, transfer_mode: TransferMode) !void {
        const device = &self.devices[device_idx];
        const channel = device.channel;
        const drive = device.drive;

        // Set up LBA command
        try self.setupLbaCommand(channel, drive, lba, sector_count, false);

        // Choose appropriate command based on transfer mode
        const command = if (transfer_mode == .MULTI_SECTOR and device.supports_multiple) blk: {
            if (device.supports_lba48 and lba >= 0x10000000) {
                break :blk AtaCommand.WRITE_MULTIPLE_EXT;
            } else {
                break :blk AtaCommand.WRITE_MULTIPLE;
            }
        } else blk: {
            if (device.supports_lba48 and lba >= 0x10000000) {
                break :blk AtaCommand.WRITE_PIO_EXT;
            } else {
                break :blk AtaCommand.WRITE_PIO;
            }
        };

        log_verbose.info("Sending write command: {} for {} sectors", .{ command, sector_count });
        self.writeDataPort(channel, .COMMAND, @intFromEnum(command));

        // Record operation start time for timeout
        const ch_idx = @intFromEnum(channel);
        self.channels[ch_idx].operation_start_time = getCurrentTimeMs();
    }

    fn startFlushOperation(self: *Self, device_idx: usize) !void {
        const device = &self.devices[device_idx];
        const channel = device.channel;
        const drive = device.drive;

        // Select drive
        const drive_select: u8 = 0xA0 | (@as(u8, @intFromEnum(drive)) << 4);
        self.writeDataPort(channel, .DRIVE_HEAD, drive_select);
        self.delay400ns(channel);

        // Send flush command
        const command = if (device.supports_lba48)
            AtaCommand.CACHE_FLUSH_EXT
        else
            AtaCommand.CACHE_FLUSH;

        log_verbose.info("Sending cache flush command: {}", .{command});
        self.writeDataPort(channel, .COMMAND, @intFromEnum(command));

        // Record operation start time for timeout
        const ch_idx = @intFromEnum(channel);
        self.channels[ch_idx].operation_start_time = getCurrentTimeMs();
    }

    fn waitForOperation(self: *Self, channel: Channel) !void {
        const ch_idx = @intFromEnum(channel);
        const current_thread = kernel.thread.getCurrentThread() orelse return AtaError.DeviceError;

        log_verbose.info("Thread {} waiting for ATA operation on channel {}", .{ current_thread.tid, ch_idx });

        // Disable interrupts while we set up blocking
        arch.irq.irq.disable();
        defer arch.irq.irq.enable();

        // Block the current thread until operation completes
        while (self.channels[ch_idx].current_operation.isActive() and
               self.channels[ch_idx].current_operation.error_code == null)
        {
            // Check for timeout
            const elapsed = getCurrentTimeMs() - self.channels[ch_idx].operation_start_time;
            if (elapsed > self.channels[ch_idx].timeout_ms) {
                log.err("ATA operation timed out on channel {} after {}ms", .{ ch_idx, elapsed });
                self.channels[ch_idx].current_operation.error_code = AtaError.Timeout;
                self.channels[ch_idx].current_operation.state = .ERROR;
                break;
            }

            // Re-enable interrupts and yield to other threads
            arch.irq.irq.enable();
            kernel.thread.Thread.yield();
            arch.irq.irq.disable();
        }

        log_verbose.info("Thread {} unblocked from ATA operation", .{current_thread.tid});
    }

    pub fn handleInterrupt(self: *Self, channel: Channel) void {
        const ch_idx = @intFromEnum(channel);
        log_verbose.info("ATA interrupt received on channel {}", .{ch_idx});

        var operation = &self.channels[ch_idx].current_operation;
        if (!operation.isActive()) {
            log_verbose.info("Unexpected interrupt on channel {} - no active operation", .{ch_idx});
            return;
        }

        const status = AtaStatus.fromByte(self.readDataPort(channel, .STATUS));
        log_verbose.info("Interrupt status on channel {}: BSY={}, DRQ={}, ERR={}", .{
            ch_idx, status.bsy, status.drq, status.err
        });

        // Check for errors
        if (status.err) {
            const error_info = AtaErrorReg.fromByte(self.readDataPort(channel, .ERROR));
            log.err("ATA error on channel {}: AMNF={}, TK0NF={}, ABRT={}, UNC={}, BBK={}", .{
                ch_idx, error_info.amnf, error_info.tk0nf, error_info.abrt, error_info.unc, error_info.bbk
            });
            operation.error_code = AtaError.DeviceError;
            operation.state = .ERROR;
            return;
        }

        // Handle different operation types
        switch (operation.operation) {
            .read_sectors => self.handleReadInterrupt(channel, operation),
            .write_sectors => self.handleWriteInterrupt(channel, operation),
            .flush_cache => self.handleFlushInterrupt(channel, operation),
            else => {
                log.err("Unknown operation type in interrupt handler: {}", .{operation.operation});
                operation.error_code = AtaError.InvalidCommand;
                operation.state = .ERROR;
            },
        }
    }

    fn handleReadInterrupt(self: *Self, channel: Channel, operation: *OperationContext) void {
        const status = AtaStatus.fromByte(self.readDataPort(channel, .STATUS));
        const ch_idx = @intFromEnum(channel);

        if (status.drq and operation.buffer != null) {
            const sectors_to_read = operation.getSectorsToTransfer();
            log_verbose.info("Reading {} sectors starting from sector {}/{}", .{
                sectors_to_read, operation.current_sector + 1, operation.sector_count
            });

            const buffer_offset = operation.current_sector * 512;
            const transfer_size = sectors_to_read * 512;
            const sector_buffer = operation.buffer.?[buffer_offset..buffer_offset + transfer_size];

            // Use fast transfer for multiple sectors, single transfer for one sector
            if (sectors_to_read > 1) {
                // std.log.debug("Fast reading {} sectors from channel {}", .{sectors_to_read, ch_idx});
                fastReadSectors(self.channels[ch_idx].base, sector_buffer, sectors_to_read);
                // std.log.debug("Fast read completed for channel {}", .{ch_idx});
            } else {
                readSectorWords(self.channels[ch_idx].base, sector_buffer);
            }

            operation.current_sector += sectors_to_read;

            // Check if all sectors are read
            if (operation.current_sector >= operation.sector_count) {
                log_verbose.info("Read operation completed on channel {}", .{ch_idx});
                operation.state = .COMPLETED;
            } else {
                operation.state = .DATA_TRANSFER;
                log_verbose.info("Continuing read operation: {}/{} sectors complete", .{
                    operation.current_sector, operation.sector_count
                });
            }
        } else if (!status.bsy and !status.drq) {
            log_verbose.info("Read operation completed on channel {}", .{ch_idx});
            operation.state = .COMPLETED;
        }
    }

    fn handleWriteInterrupt(self: *Self, channel: Channel, operation: *OperationContext) void {
        const status = AtaStatus.fromByte(self.readDataPort(channel, .STATUS));
        const ch_idx = @intFromEnum(channel);

        if (status.drq and operation.const_buffer != null) {
            const sectors_to_write = operation.getSectorsToTransfer();
            log_verbose.info("Writing {} sectors starting from sector {}/{}", .{
                sectors_to_write, operation.current_sector + 1, operation.sector_count
            });

            const buffer_offset = operation.current_sector * 512;
            const transfer_size = sectors_to_write * 512;
            const sector_buffer = operation.const_buffer.?[buffer_offset..buffer_offset + transfer_size];

            if (sectors_to_write > 1) {
                fastWriteSectors(self.channels[ch_idx].base, sector_buffer, sectors_to_write);
            } else {
                writeSectorWords(self.channels[ch_idx].base, sector_buffer);
            }

            operation.current_sector += sectors_to_write;

            // Check if all sectors are written
            if (operation.current_sector >= operation.sector_count) {
                operation.state = .COMPLETING;
                log_verbose.info("All sectors written, waiting for completion on channel {}", .{ch_idx});
            } else {
                operation.state = .DATA_TRANSFER;
                log_verbose.info("Continuing write operation: {}/{} sectors complete", .{
                    operation.current_sector, operation.sector_count
                });
            }
        } else if (!status.bsy and !status.drq) {
            // Operation completed
            log_verbose.info("Write operation completed on channel {}", .{ch_idx});
            operation.state = .COMPLETED;
        }
    }

    fn handleFlushInterrupt(self: *Self, channel: Channel, operation: *OperationContext) void {
        const status = AtaStatus.fromByte(self.readDataPort(channel, .STATUS));

        if (!status.bsy and status.rdy and !status.drq) {
            log_verbose.info("Flush operation completed on channel {}", .{@intFromEnum(channel)});
            operation.state = .COMPLETED;
        }
    }

    fn setupLbaCommand(self: *Self, channel: Channel, drive: DriveSelect, lba: u64, sector_count: u16, is_read: bool) !void {
        _ = is_read;
        const device_idx: u4 = (@as(u4, @intFromEnum(channel)) * 2) + @intFromEnum(drive);
        const device = &self.devices[device_idx];

        // Select drive
        const drive_select = if (device.supports_lba48 and lba >= 0x10000000) blk: {
            // LBA48 mode
            log_verbose.info("Using LBA48 mode for LBA 0x{X}", .{lba});
            break :blk 0x40 | (@as(u8, @intFromEnum(drive)) << 4);
        } else blk: {
            // LBA28 mode
            const lba28: u32 = @truncate(lba);
            log_verbose.info("Using LBA28 mode for LBA 0x{X}", .{lba28});
            if (lba >= 0x10000000) {
                log.err("LBA 0x{X} too large for LBA28 mode", .{lba});
                return AtaError.InvalidParameters;
            }
            break :blk 0xE0 | (@as(u8, @intFromEnum(drive)) << 4) | @as(u8, @truncate((lba28 >> 24) & 0x0F));
        };

        log_verbose.info("Selecting drive with value 0x{X:0>2}", .{drive_select});
        self.writeDataPort(channel, .DRIVE_HEAD, drive_select);
        self.delay400ns(channel);

        // Set up registers
        if (device.supports_lba48 and lba >= 0x10000000) {
            log_verbose.info("Setting up LBA48 registers", .{});
            self.writeDataPort(channel, .SECTOR_COUNT, @truncate(sector_count >> 8)); // High byte
            self.writeDataPort(channel, .LBA_LOW, @truncate(lba >> 24));
            self.writeDataPort(channel, .LBA_MID, @truncate(lba >> 32));
            self.writeDataPort(channel, .LBA_HIGH, @truncate(lba >> 40));
            self.writeDataPort(channel, .SECTOR_COUNT, @truncate(sector_count)); // Low byte
            self.writeDataPort(channel, .LBA_LOW, @truncate(lba));
            self.writeDataPort(channel, .LBA_MID, @truncate(lba >> 8));
            self.writeDataPort(channel, .LBA_HIGH, @truncate(lba >> 16));
        } else {
            log_verbose.info("Setting up LBA28 registers", .{});
            self.writeDataPort(channel, .SECTOR_COUNT, @truncate(sector_count));
            self.writeDataPort(channel, .LBA_LOW, @truncate(lba));
            self.writeDataPort(channel, .LBA_MID, @truncate(lba >> 8));
            self.writeDataPort(channel, .LBA_HIGH, @truncate(lba >> 16));
        }
    }

    fn softReset(self: *Self, channel: Channel) !void {
        const ch_idx = @intFromEnum(channel);
        log_verbose.info("Performing soft reset on channel {}", .{ch_idx});

        log_verbose.info("Setting SRST bit in device control register", .{});
        self.writeControlPort(channel, .DEVICE_CONTROL, 0x04);

        log_verbose.info("Waiting ~5 microseconds", .{});
        var i: u32 = 0;
        while (i < 1000) : (i += 1) {
            asm volatile ("" ::: "memory");
        }

        log_verbose.info("Clearing SRST bit", .{});
        self.writeControlPort(channel, .DEVICE_CONTROL, 0x00);

        log_verbose.info("Waiting for drives to become ready after reset", .{});
        var timeout: u32 = 10000;
        while (timeout > 0) : (timeout -= 1) {
            const status = self.readDataPort(channel, .STATUS);
            if ((status & 0x80) == 0 and (status & 0x40) != 0) {
                log_verbose.info("Drive ready after reset (status: 0x{X:0>2})", .{status});
                break;
            }
        }

        if (timeout == 0) {
            log.err("Timeout waiting for drives to be ready after reset on channel {}", .{ch_idx});
            return AtaError.Timeout;
        }

        log_verbose.info("Soft reset completed successfully on channel {}", .{ch_idx});
    }

    fn delay400ns(self: *Self, channel: Channel) void {
        _ = self.readControlPort(channel, .ALT_STATUS);
        _ = self.readControlPort(channel, .ALT_STATUS);
        _ = self.readControlPort(channel, .ALT_STATUS);
        _ = self.readControlPort(channel, .ALT_STATUS);
    }

    fn readDataPort(self: *Self, channel: Channel, reg: DataPortReg) u8 {
        const ch_idx = @intFromEnum(channel);
        const port = self.channels[ch_idx].base + @intFromEnum(reg);
        const value = arch.cpu.inb(port);
        return value;
    }

    fn writeDataPort(self: *Self, channel: Channel, reg: DataPortWrite, value: u8) void {
        const ch_idx = @intFromEnum(channel);
        const port = self.channels[ch_idx].base + @intFromEnum(reg);
        arch.cpu.outb(port, value);
    }

    fn readControlPort(self: *Self, channel: Channel, reg: ControlPortReg) u8 {
        const ch_idx = @intFromEnum(channel);
        const port = self.channels[ch_idx].ctrl + @intFromEnum(reg);
        const value = arch.cpu.inb(port);
        return value;
    }

    fn writeControlPort(self: *Self, channel: Channel, reg: ControlPortWrite, value: u8) void {
        const ch_idx = @intFromEnum(channel);
        const port = self.channels[ch_idx].ctrl + @intFromEnum(reg);
        arch.cpu.outb(port, value);
    }

    fn readData(self: *Self, channel: Channel) u16 {
        const ch_idx = @intFromEnum(channel);
        const port = self.channels[ch_idx].base;

        const value = asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> u16),
            : [port] "N{dx}" (port),
        );

        return value;
    }

    fn writeData(self: *Self, channel: Channel, data: u16) void {
        const ch_idx = @intFromEnum(channel);
        const port = self.channels[ch_idx].base;
        asm volatile ("outw %[data], %[port]"
            :
            : [data] "{ax}" (data),
              [port] "N{dx}" (port),
        );
    }

    pub fn getDeviceInfo(self: *Self, device_idx: usize) ?*const DeviceInfo {
        if (device_idx >= 4) return null;
        if (!self.devices[device_idx].exists) return null;
        return &self.devices[device_idx];
    }

    pub fn listDevices(self: *Self) void {
        log.info("=== ATA Device List ===", .{});
        for (0..4) |i| {
            const device = &self.devices[i];
            if (device.exists) {
                const model_len = std.mem.indexOfScalar(u8, &device.model, 0) orelse device.model.len;
                log.info("Device {}: {s} - {} ({} MB)", .{
                    i, device.model[0..model_len], device.device_type, device.size / (1024 * 1024)
                });
                log.info("  Channel: {}, Drive: {}, LBA48: {}, DMA: {}", .{
                    device.channel, device.drive, device.supports_lba48, device.supports_dma
                });
                log.info("  Multiple sectors: {} (max: {}, current: {})", .{
                    device.supports_multiple, device.max_multiple_sectors, device.multiple_sector_count
                });
                if (device.block_device) |bd| {
                    log.info("  Block device: {s}", .{bd.name});
                }
            }
        }
        log.info("=======================", .{});
    }
};

// Global controller instance (for callbacks)
var ata_controller: ?*AtaController = null;

// Helper function to get current time
fn getCurrentTimeMs() u64 {
    // TODO: Implement proper timer/RTC reading
    return 0;
}

fn ataReadBlock(dev: *block_device.BlockDev, blk_num: u64, dst: *anyopaque, dst_len: u64) block_device.BlockDevError!void {
    log_hyper_verbose.info("Block device read request: device={s}, block={}, dst=0x{X}", .{
        dev.name, blk_num, @intFromPtr(dst)
    });

    if (ata_controller == null) {
        log.err("ATA controller not initialized for block read", .{});
        return block_device.BlockDevError.DeviceError;
    }

    // Find device index
    const device_idx: usize = blk: {
        for (0..4) |i| {
            if (ata_controller.?.devices[i].exists and ata_controller.?.devices[i].block_device == dev) {
                break :blk i;
            }
        }
        log.err("Block device not found in ATA controller", .{});
        return block_device.BlockDevError.DeviceError;
    };

    const buffer_ptr: [*]u8 = @ptrCast(dst);
    const buffer = buffer_ptr[0..dst_len];
    ata_controller.?.readSector(device_idx, blk_num, buffer) catch |err| {
        log.err("ATA sector read failed: {}", .{err});
        return block_device.BlockDevError.DeviceError;
    };

    log_hyper_verbose.info("Block device read completed successfully", .{});
}

fn ataReadBlocks(dev: *block_device.BlockDev, blk_num: u64, count: u64, dst: *anyopaque, dst_len: u64) block_device.BlockDevError!void {
    log_hyper_verbose.info("Block device read request: device={s}, block={}, count={}, dst=0x{X}", .{
        dev.name, blk_num, count, @intFromPtr(dst)
    });

    if (ata_controller == null) {
        log.err("ATA controller not initialized for block read", .{});
        return block_device.BlockDevError.DeviceError;
    }

    // Find device index
    const device_idx: usize = blk: {
        for (0..4) |i| {
            if (ata_controller.?.devices[i].exists and ata_controller.?.devices[i].block_device == dev) {
                break :blk i;
            }
        }
        log.err("Block device not found in ATA controller", .{});
        return block_device.BlockDevError.DeviceError;
    };

    const raw_size: u64 = count * dev.blk_size;
    if (dst_len < raw_size) {
        log.err("Destination buffer too small: {} bytes (need {})", .{ dst_len, raw_size });
        return block_device.BlockDevError.InvalidRequest;
    }
    const sectors: u16 = @intCast(raw_size / 512);

    const buffer_ptr: [*]u8 = @ptrCast(dst);
    const buffer = buffer_ptr[0..dst_len];
    ata_controller.?.readSectors(device_idx, blk_num, sectors, buffer) catch |err| {
        log.err("ATA sector read failed: {}", .{err});
        return block_device.BlockDevError.DeviceError;
    };

    log_hyper_verbose.info("Block device read completed successfully", .{});
}

// IRQ handlers
fn primaryIrqHandler(frame: *arch.irq.InterruptFrame) void {
    _ = frame;
    if (ata_controller) |controller| {
        controller.handleInterrupt(.PRIMARY);
    }
}

fn secondaryIrqHandler(frame: *arch.irq.InterruptFrame) void {
    _ = frame;
    if (ata_controller) |controller| {
        controller.handleInterrupt(.SECONDARY);
    }
}

pub fn init() !void {
    log.info("Initializing ATA driver...", .{});

    const allocator = kernel.state.getKernelAllocator() orelse return error.NoAllocator;
    const controller = try AtaController.init(allocator);

    try controller.detectController();
    try controller.initializeChannels();
    try controller.detectDevices();

    ata_controller = controller;

    log.info("ATA driver initialized successfully (interrupt-driven mode with fast transfers)", .{});
}

pub fn deinit() void {
    if (ata_controller) |controller| {
        controller.deinit();
        ata_controller = null;
    }
}

pub fn testRead() !void {
    log.info("Starting ATA test read operation", .{});

    if (ata_controller == null) {
        log.err("ATA controller not initialized - cannot perform test read", .{});
        return;
    }

    // Find first available device
    for (0..4) |i| {
        if (ata_controller.?.devices[i].exists and
            (ata_controller.?.devices[i].device_type == .PATA or ata_controller.?.devices[i].device_type == .SATA))
        {
            log.info("Testing multi-sector read from device {} ({})", .{ i, ata_controller.?.devices[i].device_type });

            // Test single sector read
            var buffer: [512]u8 = undefined;
            log_verbose.info("Reading single sector 0 from device {}", .{i});
            try ata_controller.?.readSector(i, 0, &buffer);
            log.info("Single sector read successful! First few bytes: 0x{X:0>2} 0x{X:0>2} 0x{X:0>2} 0x{X:0>2}", .{
                buffer[0], buffer[1], buffer[2], buffer[3]
            });

            // Test multi-sector read
            var multi_buffer: [4096]u8 = undefined; // 8 sectors
            log_verbose.info("Reading 8 sectors starting from sector 0 from device {}", .{i});
            try ata_controller.?.readSectors(i, 0, 8, &multi_buffer);
            log.info("Multi-sector read successful! First sector bytes: 0x{X:0>2} 0x{X:0>2} 0x{X:0>2} 0x{X:0>2}", .{
                multi_buffer[0], multi_buffer[1], multi_buffer[2], multi_buffer[3]
            });
            log.info("Last sector bytes: 0x{X:0>2} 0x{X:0>2} 0x{X:0>2} 0x{X:0>2}", .{
                multi_buffer[4092], multi_buffer[4093], multi_buffer[4094], multi_buffer[4095]
            });

            return;
        }
    }

    log.err("No ATA devices available for testing", .{});
}

pub fn testWrite() !void {
    log.info("Starting ATA test write operation", .{});

    if (ata_controller == null) {
        log.err("ATA controller not initialized - cannot perform test write", .{});
        return;
    }

    // Find first device
    for (0..4) |i| {
        if (ata_controller.?.devices[i].exists and
            (ata_controller.?.devices[i].device_type == .PATA or ata_controller.?.devices[i].device_type == .SATA))
        {
            log.info("Testing multi-sector write to device {} ({})", .{ i, ata_controller.?.devices[i].device_type });

            // Read original content (multiple sectors)
            var original_buffer: [2048]u8 = undefined; // 4 sectors
            try ata_controller.?.readSectors(i, 1, 4, &original_buffer);
            log.info("Original 4 sectors content: 0x{X:0>2} 0x{X:0>2} 0x{X:0>2} 0x{X:0>2}", .{
                original_buffer[0], original_buffer[1], original_buffer[2], original_buffer[3]
            });

            // Write test pattern (multiple sectors)
            var test_buffer: [2048]u8 = undefined; // 4 sectors
            for (0..2048) |j| {
                test_buffer[j] = @truncate(j & 0xFF);
            }

            log.info("Writing test pattern to 4 sectors starting at sector 1...", .{});
            try ata_controller.?.writeSectors(i, 1, 4, &test_buffer);

            // Read back and verify
            var verify_buffer: [2048]u8 = undefined;
            try ata_controller.?.readSectors(i, 1, 4, &verify_buffer);

            var matches: u32 = 0;
            for (0..2048) |j| {
                if (verify_buffer[j] == test_buffer[j]) {
                    matches += 1;
                }
            }

            log.info("Write verification: {}/2048 bytes match", .{matches});
            if (matches == 2048) {
                log.info("Multi-sector write test PASSED!", .{});
            } else {
                log.err("Multi-sector write test FAILED - data mismatch", .{});
            }

            log.info("Restoring original content...", .{});
            try ata_controller.?.writeSectors(i, 1, 4, &original_buffer);

            log.info("Flushing write cache...", .{});
            try ata_controller.?.flushCache(i);

            return;
        }
    }

    log.err("No ATA devices available for testing", .{});
}

pub fn listDevices() void {
    if (ata_controller) |controller| {
        controller.listDevices();
    } else {
        log.info("ATA controller not initialized", .{});
    }
}

pub fn getController() ?*AtaController {
    return ata_controller;
}

pub fn isInitialized() bool {
    return ata_controller != null;
}
