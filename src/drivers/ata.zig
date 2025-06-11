// src/drivers/ata.zig
// This took so damn long lmao
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
    QueueFull,
    InvalidParameters,
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

pub const IoRequestType = enum {
    read,
    write,
    flush,
};

pub const IoRequest = struct {
    request_type: IoRequestType,
    device_idx: usize,
    lba: u64,
    sector_count: u16,
    buffer: []u8,
    completed: bool = false,
    error_code: ?AtaError = null,
    waiting_thread: ?*kernel.thread.Thread = null,
    next: ?*IoRequest = null,
};

pub const IoQueue = struct {
    head: ?*IoRequest = null,
    tail: ?*IoRequest = null,
    count: u32 = 0,
    max_queue_size: u32 = 64,
    mutex: kernel.mutex.Mutex = .{},
    blocked_threads: kernel.thread_queue.ThreadQueue = .{},

    pub fn init(max_size: u32) IoQueue {
        return .{ .max_queue_size = max_size };
    }

    pub fn enqueue(self: *IoQueue, request: *IoRequest) AtaError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count >= self.max_queue_size) {
            return AtaError.QueueFull;
        }

        request.next = null;
        request.waiting_thread = kernel.thread.getCurrentThread();

        if (self.tail) |tail| {
            tail.next = request;
        } else {
            self.head = request;
        }
        self.tail = request;
        self.count += 1;

        log_verbose.info("Enqueued I/O request: type={}, device={}, LBA={}, count={}", .{
            request.request_type, request.device_idx, request.lba, request.sector_count
        });
    }

    pub fn dequeue(self: *IoQueue) ?*IoRequest {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.head) |head| {
            self.head = head.next;
            if (self.head == null) {
                self.tail = null;
            }
            head.next = null;
            self.count -= 1;

            log_verbose.info("Dequeued I/O request: type={}, device={}, LBA={}", .{
                head.request_type, head.device_idx, head.lba
            });

            return head;
        }
        return null;
    }

    pub fn completeRequest(self: *IoQueue, request: *IoRequest, error_code: ?AtaError) void {
        _ = self;
        request.completed = true;
        request.error_code = error_code;

        // Unblock waiting thread
        if (request.waiting_thread) |thread| {
            log_verbose.info("Completing I/O request and unblocking thread {}", .{thread.tid});
            thread.state = .READY;
            if (kernel.state.scheduler) |sched| {
                sched.addThread(thread) catch {
                    log.err("Failed to re-add thread {} to scheduler", .{thread.tid});
                };
            }
        }
    }

    pub fn isEmpty(self: *IoQueue) bool {
        return self.head == null;
    }
};

// Channel registers
pub const ChannelRegs = struct {
    base: u16, // I/O base port
    ctrl: u16, // Control base port
    bmide: u16, // Bus master IDE port
    irq: u8, // IRQ number
    enabled: bool = false,
    processing_request: bool = false,
    current_request: ?*IoRequest = null,
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

    // Performance features
    supports_dma: bool = false,
    supports_write_cache: bool = false,
    supports_read_ahead: bool = false,
};

pub const AtaController = struct {
    channels: [2]ChannelRegs,
    devices: [4]DeviceInfo,
    io_queue: IoQueue,
    allocator: std.mem.Allocator,
    worker_thread: ?*kernel.thread.Thread = null,
    shutdown_requested: bool = false,

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
            .io_queue = IoQueue.init(64),
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

        self.shutdown_requested = true;

        if (self.worker_thread) |worker| {
            // looping waiting for worker to finish
            _ = worker;
        }

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

                    log_verbose.info("Device details - LBA48: {}, DMA: {}, Write Cache: {}", .{
                        device_info.supports_lba48, device_info.supports_dma, device_info.supports_write_cache
                    });

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

    pub fn startWorkerThread(self: *Self) !void {
        log_verbose.info("Starting ATA I/O worker thread", .{});

        self.worker_thread = try kernel.thread.Thread.create(
            &ioWorkerThread,
            self,
            true, // kernel thread
            kernel.state.mem_manager.mapper.?,
            self.allocator,
            false,
            .NORMAL,
        );

        if (kernel.state.scheduler) |sched| {
            try sched.addThread(self.worker_thread.?);
            log.info("ATA I/O worker thread started successfully", .{});
        } else {
            return AtaError.DeviceError;
        }
    }

    fn ioWorkerThread(arg: *anyopaque) callconv(.C) i32 {
        const self: *AtaController = @ptrCast(@alignCast(arg));
        log_verbose.info("ATA I/O worker thread started", .{});

        while (!self.shutdown_requested) {
            if (self.io_queue.dequeue()) |request| {
                log_verbose.info("Processing I/O request: type={}, device={}, LBA={}", .{
                    request.request_type, request.device_idx, request.lba
                });

                const error_code = self.processIoRequest(request);
                self.io_queue.completeRequest(request, error_code);
            } else {
                // No requests! lets yeild
                kernel.thread.Thread.yield();
            }
        }

        log_verbose.info("ATA I/O worker thread shutting down", .{});
        return 0;
    }

    fn processIoRequest(self: *Self, request: *IoRequest) ?AtaError {
        switch (request.request_type) {
            .read => {
                return self.readSectorsInternal(
                    request.device_idx,
                    request.lba,
                    request.sector_count,
                    request.buffer
                );
            },
            .write => {
                return self.writeSectorsInternal(
                    request.device_idx,
                    request.lba,
                    request.sector_count,
                    request.buffer
                );
            },
            .flush => {
                return self.flushCacheInternal(request.device_idx);
            },
        }
    }

    fn identifyDevice(self: *Self, channel: Channel, drive: DriveSelect) !DeviceInfo {
        const ch_idx = @intFromEnum(channel);
        const drive_idx = @intFromEnum(drive);

        log_verbose.info("Starting device identification for channel {}, drive {}", .{ ch_idx, drive_idx });

        // Step 1: Select the drive
        const drive_select: u8 = 0xA0 | (@as(u8, @intFromEnum(drive)) << 4);
        log_verbose.info("Selecting drive with value 0x{X:0>2}", .{drive_select});
        self.writeDataPort(channel, .DRIVE_HEAD, drive_select);

        // Step 2: Wait... should check BSY i think but lets just wait a bit
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

        // Wait for BSY to clear
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

        // Step 7: Read identification data
        log_verbose.info("Reading 512 bytes of identification data", .{});
        var identify_data: [256]u16 = undefined;
        for (0..256) |i| {
            identify_data[i] = self.readData(channel);
        }
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

        // Step 9: Get the string
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


        // Step 11: Fucking celebrate
        return device_info;
    }

    fn registerBlockDevice(self: *Self, device_idx: usize) !void {
        const device = &self.devices[device_idx];
        if (!device.exists or device.device_type == .PATAPI or device.device_type == .SATAPI) {
            log_verbose.info("Skipping block device registration for device {} (ATAPI or non-existent)", .{device_idx});
            return;
        }

        log_verbose.info("Creating block device structure for device {}", .{device_idx});
        const block_dev = try self.allocator.create(block_device.BlockDev);

        // Mkea a name
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "ata{}:{}", .{
            @intFromEnum(device.channel), @intFromEnum(device.drive)
        }) catch "ata";
        log_verbose.info("Generated device name: {s}", .{name});

        const name_copy = try self.allocator.dupe(u8, name);

        block_dev.* = block_device.BlockDev{
            .tot_length = device.size,
            .read_block = ataReadBlock,
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
        if (buffer.len < sector_count * 512) {
            log.err("Buffer too small for sector read: {} bytes (need {})", .{
                buffer.len, sector_count * 512
            });
            return AtaError.InvalidParameters;
        }

        var request = IoRequest{
            .request_type = .read,
            .device_idx = device_idx,
            .lba = lba,
            .sector_count = sector_count,
            .buffer = buffer,
        };

        try self.io_queue.enqueue(&request);

        while (!request.completed) {
            kernel.thread.Thread.yield();
        }

        if (request.error_code) |err| {
            return err;
        }
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

        var request = IoRequest{
            .request_type = .write,
            .device_idx = device_idx,
            .lba = lba,
            .sector_count = sector_count,
            .buffer = @constCast(buffer),
        };

        try self.io_queue.enqueue(&request);

        while (!request.completed) {
            kernel.thread.Thread.yield();
        }

        if (request.error_code) |err| {
            return err;
        }
    }

    pub fn flushCache(self: *Self, device_idx: usize) !void {
        var request = IoRequest{
            .request_type = .flush,
            .device_idx = device_idx,
            .lba = 0,
            .sector_count = 0,
            .buffer = &[_]u8{},
        };

        try self.io_queue.enqueue(&request);

        while (!request.completed) {
            kernel.thread.Thread.yield();
        }

        if (request.error_code) |err| {
            return err;
        }
    }

    fn readSectorsInternal(self: *Self, device_idx: usize, lba: u64, sector_count: u16, buffer: []u8) ?AtaError {
        const device = &self.devices[device_idx];
        if (!device.exists) {
            log.err("Attempted to read from non-existent device {}", .{device_idx});
            return AtaError.NoDevice;
        }

        const channel = device.channel;
        const drive = device.drive;
        const ch_idx = @intFromEnum(channel);

        log_verbose.info("Reading {} sectors from LBA {} on device {} (channel {}, drive {})", .{
            sector_count, lba, device_idx, ch_idx, @intFromEnum(drive)
        });

        self.channels[ch_idx].processing_request = true;
        defer self.channels[ch_idx].processing_request = false;

        for (0..sector_count) |sector_offset| {
            const current_lba = lba + sector_offset;
            const buffer_offset = sector_offset * 512;
            const sector_buffer = buffer[buffer_offset..buffer_offset + 512];

            if (self.readSectorInternal(device_idx, current_lba, sector_buffer)) |err| {
                return err;
            }
        }

        log_verbose.info("Successfully read {} sectors from device {}", .{ sector_count, device_idx });
        return null;
    }

    fn readSectorInternal(self: *Self, device_idx: usize, lba: u64, buffer: []u8) ?AtaError {
        const device = &self.devices[device_idx];
        const channel = device.channel;
        const drive = device.drive;

        if (self.setupLbaCommand(channel, drive, lba, 1, true)) |err| {
            return err;
        }

        const command = if (device.supports_lba48 and lba >= 0x10000000)
            AtaCommand.READ_PIO_EXT
        else
            AtaCommand.READ_PIO;

        log_verbose.info("Sending read command: {}", .{command});
        self.writeDataPort(channel, .COMMAND, @intFromEnum(command));

        if (self.waitForDrq(channel)) |err| {
            return err;
        }

        log_verbose.info("Reading 512 bytes of sector data", .{});
        const buffer_u16: [*]u16 = @ptrCast(@alignCast(buffer.ptr));
        for (0..256) |i| {
            buffer_u16[i] = self.readData(channel);
        }

        return null;
    }

    fn writeSectorsInternal(self: *Self, device_idx: usize, lba: u64, sector_count: u16, buffer: []u8) ?AtaError {
        const device = &self.devices[device_idx];
        if (!device.exists) {
            log.err("Attempted to write to non-existent device {}", .{device_idx});
            return AtaError.NoDevice;
        }

        const channel = device.channel;
        const drive = device.drive;
        const ch_idx = @intFromEnum(channel);

        log_verbose.info("Writing {} sectors to LBA {} on device {} (channel {}, drive {})", .{
            sector_count, lba, device_idx, ch_idx, @intFromEnum(drive)
        });

        // amke busy
        self.channels[ch_idx].processing_request = true;
        defer self.channels[ch_idx].processing_request = false;

        for (0..sector_count) |sector_offset| {
            const current_lba = lba + sector_offset;
            const buffer_offset = sector_offset * 512;
            const sector_buffer = buffer[buffer_offset..buffer_offset + 512];

            if (self.writeSectorInternal(device_idx, current_lba, sector_buffer)) |err| {
                return err;
            }
        }

        log_verbose.info("Successfully wrote {} sectors to device {}", .{ sector_count, device_idx });
        return null;
    }

    fn writeSectorInternal(self: *Self, device_idx: usize, lba: u64, buffer: []const u8) ?AtaError {
        const device = &self.devices[device_idx];
        const channel = device.channel;
        const drive = device.drive;

        // Select dirv ena LBA
        if (self.setupLbaCommand(channel, drive, lba, 1, false)) |err| {
            return err;
        }

        const command = if (device.supports_lba48 and lba >= 0x10000000)
            AtaCommand.WRITE_PIO_EXT
        else
            AtaCommand.WRITE_PIO;

        log_verbose.info("Sending write command: {}", .{command});
        self.writeDataPort(channel, .COMMAND, @intFromEnum(command));

        if (self.waitForDrq(channel)) |err| {
            return err;
        }

        log_hyper_verbose.info("Writing 512 bytes of sector data", .{});
        const buffer_u16: [*]const u16 = @ptrCast(@alignCast(buffer.ptr));
        for (0..256) |i| {
            self.writeData(channel, buffer_u16[i]);
        }

        if (self.waitForCompletion(channel)) |err| {
            return err;
        }

        return null;
    }

    fn flushCacheInternal(self: *Self, device_idx: usize) ?AtaError {
        const device = &self.devices[device_idx];
        if (!device.exists) {
            return AtaError.NoDevice;
        }

        if (!device.supports_write_cache) {
            log_verbose.info("Device {} does not support write cache - flush not needed", .{device_idx});
            return null;
        }

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

        if (self.waitForCompletion(channel)) |err| {
            return err;
        }

        log_verbose.info("Cache flush completed for device {}", .{device_idx});
        return null;
    }

    fn setupLbaCommand(self: *Self, channel: Channel, drive: DriveSelect, lba: u64, sector_count: u16, is_read: bool) ?AtaError {
        _ = is_read;
        const device_idx: u4 = (@as(u4,@intFromEnum(channel)) * 2) + @intFromEnum(drive);
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

        return null;
    }

    fn waitForDrq(self: *Self, channel: Channel) ?AtaError {
        log_verbose.info("Waiting for DRQ on channel {}", .{@intFromEnum(channel)});

        var timeout: u32 = 100000;
        while (timeout > 0) : (timeout -= 1) {
            const status = AtaStatus.fromByte(self.readDataPort(channel, .STATUS));

            if (status.err) {
                const error_info = AtaErrorReg.fromByte(self.readDataPort(channel, .ERROR));
                log.err("ATA error during DRQ wait: AMNF={}, TK0NF={}, ABRT={}, UNC={}, BBK={}", .{
                    error_info.amnf, error_info.tk0nf, error_info.abrt, error_info.unc, error_info.bbk
                });
                return AtaError.DeviceError;
            }

            if (status.drq) {
                log_verbose.info("DRQ set - ready for data transfer", .{});
                return null;
            }

            if (!status.bsy and status.rdy) {
                // Device is ready but no DRQ - might be an error
                // I really do not know what to do here
                continue;
            }
        }

        log.err("Timeout waiting for DRQ on channel {}", .{@intFromEnum(channel)});
        return AtaError.Timeout;
    }

    fn waitForCompletion(self: *Self, channel: Channel) ?AtaError {
        log_verbose.info("Waiting for completion on channel {}", .{@intFromEnum(channel)});

        var timeout: u32 = 100000;
        while (timeout > 0) : (timeout -= 1) {
            const status = AtaStatus.fromByte(self.readDataPort(channel, .STATUS));

            if (status.err) {
                const error_info = AtaErrorReg.fromByte(self.readDataPort(channel, .ERROR));
                log.err("ATA error during completion wait: AMNF={}, TK0NF={}, ABRT={}, UNC={}, BBK={}", .{
                    error_info.amnf, error_info.tk0nf, error_info.abrt, error_info.unc, error_info.bbk
                });
                return AtaError.DeviceError;
            }

            if (!status.bsy and status.rdy and !status.drq) {
                log_verbose.info("Operation completed successfully", .{});
                return null;
            }
        }

        log.err("Timeout waiting for completion on channel {}", .{@intFromEnum(channel)});
        return AtaError.Timeout;
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
        // So like... this is what the internet said to do..
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
        // TODO @(dleiferives,733a845b-2fca-47cd-9b30-a7387777b43c): add to cpu ~#
        asm volatile ("outw %[data], %[port]"
            :
            : [data] "{ax}" (data),
              [port] "N{dx}" (port),
        );
    }

    pub fn handleInterrupt(self: *Self, channel: Channel) void {
        const ch_idx = @intFromEnum(channel);
        log_verbose.info("ATA interrupt received on channel {}", .{ch_idx});

        const status = self.readDataPort(channel, .STATUS);
        log_verbose.info("Interrupt status on channel {}: 0x{X:0>2}", .{ ch_idx, status });

        if (self.channels[ch_idx].processing_request) {
            log_verbose.info("Interrupt for active request on channel {}", .{ch_idx});
        } else {
            log_verbose.info("Unexpected interrupt on channel {} - no active request", .{ch_idx});
        }
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

fn ataReadBlock(dev: *block_device.BlockDev, blk_num: u64, dst: *anyopaque) block_device.BlockDevError!void {
    log_hyper_verbose.info("Block device read request: device={s}, block={}, dst=0x{X}", .{
        dev.name, blk_num, @intFromPtr(dst)
    });

    if (ata_controller == null) {
        log.err("ATA controller not initialized for block read", .{});
        return block_device.BlockDevError.DeviceError;
    }

    // find blk id
    const device_idx: usize = blk: {
        for (0..4) |i| {
            if (ata_controller.?.devices[i].exists and ata_controller.?.devices[i].block_device == dev) {
                break :blk i;
            }
        }
        log.err("Block device not found in ATA controller", .{});
        return block_device.BlockDevError.DeviceError;
    };

    const buffer: [*]u8 = @ptrCast(dst);
    ata_controller.?.readSector(device_idx, blk_num, buffer[0..512]) catch |err| {
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
    try controller.startWorkerThread();

    ata_controller = controller;

    log.info("ATA driver initialized successfully", .{});
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
            log.info("Testing read from device {} ({})", .{ i, ata_controller.?.devices[i].device_type });

            var buffer: [512]u8 = undefined;
            log_verbose.info("Reading sector 0 from device {}", .{i});

            try ata_controller.?.readSector(i, 0, &buffer);

            log.info("Test read successful! First few bytes: 0x{X:0>2} 0x{X:0>2} 0x{X:0>2} 0x{X:0>2}", .{
                buffer[0], buffer[1], buffer[2], buffer[3]
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
            log.info("Testing write to device {} ({})", .{ i, ata_controller.?.devices[i].device_type });

            // Read original content
            var original_buffer: [512]u8 = undefined;
            try ata_controller.?.readSector(i, 1, &original_buffer);
            log.info("Original sector 1 content: 0x{X:0>2} 0x{X:0>2} 0x{X:0>2} 0x{X:0>2}", .{
                original_buffer[0], original_buffer[1], original_buffer[2], original_buffer[3]
            });

            // Write test pattern
            var test_buffer: [512]u8 = undefined;
            for (0..512) |j| {
                test_buffer[j] = @truncate(j & 0xFF);
            }

            log.info("Writing test pattern to sector 1...", .{});
            try ata_controller.?.writeSector(i, 1, &test_buffer);

            // Read back and verify
            var verify_buffer: [512]u8 = undefined;
            try ata_controller.?.readSector(i, 1, &verify_buffer);

            var matches: u32 = 0;
            for (0..512) |j| {
                if (verify_buffer[j] == test_buffer[j]) {
                    matches += 1;
                }
            }

            log.info("Write verification: {}/512 bytes match", .{matches});
            if (matches == 512) {
                log.info("Write test PASSED!", .{});
            } else {
                log.err("Write test FAILED - data mismatch", .{});
            }

            log.info("Restoring original content...", .{});
            try ata_controller.?.writeSector(i, 1, &original_buffer);

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

// Helper functions for other modules
pub fn getController() ?*AtaController {
    return ata_controller;
}

pub fn isInitialized() bool {
    return ata_controller != null;
}
