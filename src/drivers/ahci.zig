const std = @import("std");
const arch = @import("arch");
const kernel = @import("kernel");
const block_device = @import("block_device.zig");

const log = std.log.scoped(.drivers_ahci);

const PCI_CONFIG_ADDRESS: u16 = 0xCF8;
const PCI_CONFIG_DATA: u16 = 0xCFC;
const PCI_CLASS_MASS_STORAGE: u8 = 0x01;
const PCI_SUBCLASS_SATA: u8 = 0x06;
const PCI_PROGIF_AHCI: u8 = 0x01;

const HBA_CAP: usize = 0x00;
const HBA_GHC: usize = 0x04;
const HBA_PI: usize = 0x0C;
const HBA_VS: usize = 0x10;
const HBA_CAP2: usize = 0x24;
const HBA_BOHC: usize = 0x28;
const HBA_PORTS: usize = 0x100;
const HBA_PORT_SIZE: usize = 0x80;

const PORT_CLB: usize = 0x00;
const PORT_CLBU: usize = 0x04;
const PORT_FB: usize = 0x08;
const PORT_FBU: usize = 0x0C;
const PORT_IS: usize = 0x10;
const PORT_IE: usize = 0x14;
const PORT_CMD: usize = 0x18;
const PORT_TFD: usize = 0x20;
const PORT_SIG: usize = 0x24;
const PORT_SSTS: usize = 0x28;
const PORT_SERR: usize = 0x30;
const PORT_SACT: usize = 0x34;
const PORT_CI: usize = 0x38;

const GHC_AE: u32 = 1 << 31;
const CAP2_BOH: u32 = 1 << 0;
const BOHC_BOS: u32 = 1 << 0;
const BOHC_OOS: u32 = 1 << 1;
const BOHC_BB: u32 = 1 << 4;
const PORT_CMD_ST: u32 = 1 << 0;
const PORT_CMD_FRE: u32 = 1 << 4;
const PORT_CMD_FR: u32 = 1 << 14;
const PORT_CMD_CR: u32 = 1 << 15;
const PORT_IS_TFES: u32 = 1 << 30;
const TFD_ERR: u32 = 1 << 0;
const TFD_DRQ: u32 = 1 << 3;
const TFD_BSY: u32 = 1 << 7;
const SATA_SIG_ATA: u32 = 0x0000_0101;
const AHCI_VERSION_1_2: u32 = 0x0001_0200;

const FIS_TYPE_REG_H2D: u8 = 0x27;
const ATA_CMD_IDENTIFY: u8 = 0xEC;
const ATA_CMD_READ_DMA_EXT: u8 = 0x25;
const ATA_CMD_WRITE_DMA_EXT: u8 = 0x35;
const ATA_CMD_FLUSH_CACHE_EXT: u8 = 0xEA;

const COMMAND_LIST_SIZE = 1024;
const RECEIVED_FIS_SIZE = 256;
const COMMAND_TABLE_SIZE = 256;
const DMA_BUFFER_SIZE = 64 * 1024;
const MAX_SECTORS_PER_COMMAND = DMA_BUFFER_SIZE / 512;
const POLL_LIMIT: usize = 20_000_000;
// Keep controller MMIO outside both the retained bootstrap direct map and the
// kernel heap. The AHCI register file fits in one 4 KiB page for 32 ports.
const AHCI_MMIO_VIRTUAL_BASE: u64 = 0xFFFF_FF98_0000_0000;

pub const AhciError = error{
    ControllerNotFound,
    Unsupported64BitBar,
    InvalidAbar,
    MmioVirtualRangeBusy,
    BiosHandoffTimeout,
    PortNotFound,
    CommandEngineTimeout,
    DeviceBusyTimeout,
    CommandTimeout,
    TaskFileError,
    IdentifyFailed,
    Lba48NotSupported,
    DeviceTooSmall,
    NoAllocator,
};

const PciAddress = struct {
    bus: u8,
    device: u8,
    function: u8,
};

const Controller = struct {
    abar_phys: u64,
    abar_virt: usize,
    port: u8,
    sector_count: u64,
};

var controller: ?Controller = null;
var io_mutex = kernel.mutex.Mutex.init();

// AHCI 1.3.1 section 4.2 requires a 1 KiB-aligned command list, a
// 256-byte-aligned received-FIS area, and 128-byte-aligned command tables.
var command_list: [COMMAND_LIST_SIZE]u8 align(1024) = undefined;
var received_fis: [RECEIVED_FIS_SIZE]u8 align(256) = undefined;
var command_table: [COMMAND_TABLE_SIZE]u8 align(128) = undefined;
var dma_buffer: [DMA_BUFFER_SIZE]u8 align(4096) = undefined;

// TODO: Allocate one command-list/FIS/table set per active port instead of
// intentionally supporting only the first SATA disk.
// TODO: Allocate DMA memory through a physical/contiguous DMA allocator rather
// than relying on statically linked, low physical memory.
// TODO: Support scatter/gather directly from caller buffers and eliminate the
// bounce-buffer copy once the VM subsystem can pin and translate ranges.

pub fn init() !void {
    if (controller != null) return;

    kernel.hardwareBootStatus("AHCI: scanning PCI", .{});
    const pci_address = findController() orelse return AhciError.ControllerNotFound;
    kernel.hardwareBootStatus("AHCI: controller {x:0>2}:{x:0>2}.{}", .{
        pci_address.bus,
        pci_address.device,
        pci_address.function,
    });
    enablePciMemoryAndBusMastering(pci_address);

    const abar_low = pciRead32(pci_address, 0x24);
    if (abar_low & 0x1 != 0) return AhciError.InvalidAbar;
    const bar_type = (abar_low >> 1) & 0x3;
    if (bar_type == 0x2) return AhciError.Unsupported64BitBar;
    const abar_phys: u64 = abar_low & 0xFFFF_FFF0;
    if (abar_phys == 0) return AhciError.InvalidAbar;
    kernel.hardwareBootStatus("AHCI: ABAR physical 0x{x}", .{abar_phys});

    const abar_virt = try mapAbar(abar_phys);
    kernel.hardwareBootStatus("AHCI: ABAR mapped", .{});
    var candidate = Controller{
        .abar_phys = abar_phys,
        .abar_virt = abar_virt,
        .port = 0,
        .sector_count = 0,
    };

    const version = readHba(&candidate, HBA_VS);
    kernel.hardwareBootStatus("AHCI: specification version 0x{x}", .{version});
    kernel.hardwareBootStatus("AHCI: requesting firmware handoff", .{});
    try biosHandoff(&candidate, version);
    kernel.hardwareBootStatus("AHCI: firmware handoff complete", .{});
    writeHba(&candidate, HBA_GHC, readHba(&candidate, HBA_GHC) | GHC_AE);

    const implemented = readHba(&candidate, HBA_PI);
    kernel.hardwareBootStatus("AHCI: implemented ports 0x{x}", .{implemented});
    candidate.port = findSataPort(&candidate, implemented) orelse
        return AhciError.PortNotFound;
    kernel.hardwareBootStatus("AHCI: SATA disk on port {}", .{candidate.port});
    kernel.hardwareBootStatus("AHCI: configuring command engine", .{});
    try configurePort(&candidate);
    kernel.hardwareBootStatus("AHCI: command engine ready", .{});
    kernel.hardwareBootStatus("AHCI: issuing IDENTIFY", .{});
    candidate.sector_count = try identifyDevice(&candidate);
    if (candidate.sector_count == 0) return AhciError.DeviceTooSmall;
    kernel.hardwareBootStatus("AHCI: IDENTIFY returned {} sectors", .{candidate.sector_count});

    controller = candidate;
    const allocator = kernel.state.getKernelAllocator() orelse return AhciError.NoAllocator;
    const dev = try allocator.create(block_device.BlockDev);
    dev.* = .{
        .tot_length = candidate.sector_count * 512,
        .read_block = blockRead,
        .read_blocks = blockReadMultiple,
        .blk_size = 512,
        .dev_type = .MASS_STORAGE,
        .name = "ahci0",
        .fs_type = block_device.BlockDevType.MASS_STORAGE.toValue(),
        .next = null,
    };
    block_device.registerBlockDevice(dev);
    kernel.hardwareBootStatus("AHCI: block device registered", .{});
    std.log.info("AHCI disk registered: port {}, {} sectors", .{
        candidate.port,
        candidate.sector_count,
    });

    // TODO: Add write and flush-cache operations when BlockDev grows a write
    // interface. Until then this driver is intentionally read-only.
    // TODO: Reserve an append-only raw diagnostic region outside filesystem
    // metadata and add a tiny crash-log writer that Debian can decode after a
    // failed hardware boot. Do not use ext2 for crash-time logging.
    // TODO: Add hot-plug detection, port reset/recovery, and device removal.
    // TODO: Enumerate multiple HBAs and all implemented SATA ports.
}

fn findController() ?PciAddress {
    var bus: u16 = 0;
    while (bus < 256) : (bus += 1) {
        var device: u8 = 0;
        while (device < 32) : (device += 1) {
            var function: u8 = 0;
            while (function < 8) : (function += 1) {
                const address = PciAddress{
                    .bus = @intCast(bus),
                    .device = device,
                    .function = function,
                };
                const id = pciRead32(address, 0x00);
                if ((id & 0xFFFF) == 0xFFFF) continue;
                const class = pciRead32(address, 0x08);
                if (@as(u8, @truncate(class >> 24)) == PCI_CLASS_MASS_STORAGE and
                    @as(u8, @truncate(class >> 16)) == PCI_SUBCLASS_SATA and
                    @as(u8, @truncate(class >> 8)) == PCI_PROGIF_AHCI)
                {
                    log.info("Found AHCI controller at {x:0>2}:{x:0>2}.{}", .{
                        address.bus,
                        address.device,
                        address.function,
                    });
                    return address;
                }
            }
        }
    }
    return null;

    // TODO: Use a shared PCI subsystem with multifunction/header-aware
    // enumeration instead of scanning all buses and functions here.
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

fn pciWrite32(address: PciAddress, offset: u8, value: u32) void {
    arch.outl(PCI_CONFIG_ADDRESS, pciConfigAddress(address, offset));
    arch.outl(PCI_CONFIG_DATA, value);
}

fn enablePciMemoryAndBusMastering(address: PciAddress) void {
    const command_status = pciRead32(address, 0x04);
    pciWrite32(address, 0x04, command_status | (1 << 1) | (1 << 2));
}

fn mapAbar(abar_phys: u64) !usize {
    const mapper = kernel.state.mem_manager.mapper orelse return error.MapperNotInitialized;
    const page_mask = kernel.mem.PAGE_MASK_4K;
    const physical_start = abar_phys & ~page_mask;
    if (mapper.translate(AHCI_MMIO_VIRTUAL_BASE) != null) {
        return AhciError.MmioVirtualRangeBusy;
    }
    try mapper.map(AHCI_MMIO_VIRTUAL_BASE, physical_start, kernel.mem.PageFlags{
        .writable = true,
        .cache_disable = true,
        .execute_disable = true,
    });
    return @intCast(AHCI_MMIO_VIRTUAL_BASE + (abar_phys & page_mask));

    // TODO: Replace this single fixed window with a shared MMIO virtual-range
    // allocator before supporting multiple HBAs and other MMIO drivers.
    // TODO: Configure PAT/MTRR policy for stronger uncacheable MMIO semantics.
}

fn reg(controller_: *const Controller, offset: usize) *volatile u32 {
    return @ptrFromInt(controller_.abar_virt + offset);
}

fn readHba(controller_: *const Controller, offset: usize) u32 {
    return reg(controller_, offset).*;
}

fn writeHba(controller_: *const Controller, offset: usize, value: u32) void {
    reg(controller_, offset).* = value;
}

fn portOffset(controller_: *const Controller, offset: usize) usize {
    return HBA_PORTS + @as(usize, controller_.port) * HBA_PORT_SIZE + offset;
}

fn readPort(controller_: *const Controller, offset: usize) u32 {
    return readHba(controller_, portOffset(controller_, offset));
}

fn writePort(controller_: *const Controller, offset: usize, value: u32) void {
    writeHba(controller_, portOffset(controller_, offset), value);
}

fn biosHandoff(controller_: *const Controller, version: u32) !void {
    // CAP2 and BOHC were introduced in AHCI 1.2. In AHCI 1.1 these offsets
    // are reserved and must not be interpreted as capability registers.
    if (version < AHCI_VERSION_1_2) return;
    if (readHba(controller_, HBA_CAP2) & CAP2_BOH == 0) return;
    writeHba(controller_, HBA_BOHC, readHba(controller_, HBA_BOHC) | BOHC_OOS);
    var remaining = POLL_LIMIT;
    while (remaining > 0) : (remaining -= 1) {
        const bohc = readHba(controller_, HBA_BOHC);
        if (bohc & (BOHC_BOS | BOHC_BB) == 0) return;
        asm volatile ("pause");
    }
    return AhciError.BiosHandoffTimeout;

    // TODO: Replace iteration-count timeouts with monotonic clock deadlines.
    // TODO: Record the final BOHC value on timeout so firmware ownership bugs
    // can be diagnosed without attaching a hardware debugger.
}

fn findSataPort(controller_: *Controller, implemented: u32) ?u8 {
    var port: u8 = 0;
    while (port < 32) : (port += 1) {
        if (implemented & (@as(u32, 1) << @intCast(port)) == 0) continue;
        controller_.port = port;
        const ssts = readPort(controller_, PORT_SSTS);
        const det = ssts & 0xF;
        const ipm = (ssts >> 8) & 0xF;
        if (det == 3 and ipm == 1 and readPort(controller_, PORT_SIG) == SATA_SIG_ATA) {
            return port;
        }
    }
    return null;

    // TODO: Support ATAPI signatures and port multipliers.
}

fn configurePort(controller_: *const Controller) !void {
    try stopCommandEngine(controller_);
    @memset(&command_list, 0);
    @memset(&received_fis, 0);
    @memset(&command_table, 0);

    const clb_phys = physicalAddress(&command_list);
    const fb_phys = physicalAddress(&received_fis);
    writePort(controller_, PORT_CLB, @truncate(clb_phys));
    writePort(controller_, PORT_CLBU, @truncate(clb_phys >> 32));
    writePort(controller_, PORT_FB, @truncate(fb_phys));
    writePort(controller_, PORT_FBU, @truncate(fb_phys >> 32));
    writePort(controller_, PORT_IE, 0);
    writePort(controller_, PORT_IS, 0xFFFF_FFFF);
    writePort(controller_, PORT_SERR, 0xFFFF_FFFF);

    writePort(controller_, PORT_CMD, readPort(controller_, PORT_CMD) | PORT_CMD_FRE);
    writePort(controller_, PORT_CMD, readPort(controller_, PORT_CMD) | PORT_CMD_ST);

    // TODO: Enable MSI/MSI-X or legacy interrupts and stop polling PxCI.
    // TODO: Implement staggered spin-up and COMRESET recovery for inactive
    // but physically present ports.
}

fn stopCommandEngine(controller_: *const Controller) !void {
    writePort(controller_, PORT_CMD, readPort(controller_, PORT_CMD) & ~PORT_CMD_ST);
    var remaining = POLL_LIMIT;
    while (remaining > 0 and readPort(controller_, PORT_CMD) & PORT_CMD_CR != 0) : (remaining -= 1) {
        asm volatile ("pause");
    }
    if (remaining == 0) return AhciError.CommandEngineTimeout;

    writePort(controller_, PORT_CMD, readPort(controller_, PORT_CMD) & ~PORT_CMD_FRE);
    remaining = POLL_LIMIT;
    while (remaining > 0 and readPort(controller_, PORT_CMD) & PORT_CMD_FR != 0) : (remaining -= 1) {
        asm volatile ("pause");
    }
    if (remaining == 0) return AhciError.CommandEngineTimeout;
}

fn identifyDevice(controller_: *const Controller) !u64 {
    try issueCommand(controller_, ATA_CMD_IDENTIFY, 0, 1, 512, false);
    const words: *const [256]u16 = @ptrCast(@alignCast(&dma_buffer));
    if (words[83] & (1 << 10) == 0) return AhciError.Lba48NotSupported;
    return @as(u64, words[100]) |
        (@as(u64, words[101]) << 16) |
        (@as(u64, words[102]) << 32) |
        (@as(u64, words[103]) << 48);

    // TODO: Parse and retain the full IDENTIFY data, including logical sector
    // size, model, queue depth, NCQ, TRIM, and flush capabilities.
    // TODO: Support 28-bit LBA disks where appropriate.
}

fn issueCommand(
    controller_: *const Controller,
    command: u8,
    lba: u64,
    sector_count: u16,
    byte_count: usize,
    write_to_device: bool,
) !void {
    if (byte_count > DMA_BUFFER_SIZE) return AhciError.DeviceTooSmall;

    var remaining = POLL_LIMIT;
    while (remaining > 0 and readPort(controller_, PORT_TFD) & (TFD_BSY | TFD_DRQ) != 0) : (remaining -= 1) {
        asm volatile ("pause");
    }
    if (remaining == 0) return AhciError.DeviceBusyTimeout;
    remaining = POLL_LIMIT;
    while (remaining > 0 and
        (readPort(controller_, PORT_SACT) & 1 != 0 or readPort(controller_, PORT_CI) & 1 != 0)) : (remaining -= 1)
    {
        // Only command slot zero is used by this initial polling driver.
        asm volatile ("pause");
    }
    if (remaining == 0) return AhciError.CommandTimeout;

    @memset(&command_list, 0);
    @memset(&command_table, 0);
    const table_phys = physicalAddress(&command_table);
    const write_flag: u32 = if (write_to_device) 1 << 6 else 0;
    const prdt_length: u32 = if (byte_count == 0) 0 else 1;
    putU32(command_list[0..], 0, 5 | write_flag | (prdt_length << 16));
    putU32(command_list[0..], 8, @truncate(table_phys));
    putU32(command_list[0..], 12, @truncate(table_phys >> 32));

    command_table[0] = FIS_TYPE_REG_H2D;
    command_table[1] = 1 << 7;
    command_table[2] = command;
    command_table[4] = @truncate(lba);
    command_table[5] = @truncate(lba >> 8);
    command_table[6] = @truncate(lba >> 16);
    command_table[7] = 1 << 6;
    command_table[8] = @truncate(lba >> 24);
    command_table[9] = @truncate(lba >> 32);
    command_table[10] = @truncate(lba >> 40);
    command_table[12] = @truncate(sector_count);
    command_table[13] = @truncate(sector_count >> 8);

    if (byte_count != 0) {
        const data_phys = physicalAddress(&dma_buffer);
        putU32(command_table[0..], 128, @truncate(data_phys));
        putU32(command_table[0..], 132, @truncate(data_phys >> 32));
        putU32(command_table[0..], 140, @as(u32, @intCast(byte_count - 1)) | (1 << 31));
    }

    writePort(controller_, PORT_IS, 0xFFFF_FFFF);
    asm volatile ("" ::: "memory");
    writePort(controller_, PORT_CI, 1);

    remaining = POLL_LIMIT;
    while (remaining > 0 and readPort(controller_, PORT_CI) & 1 != 0) : (remaining -= 1) {
        if (readPort(controller_, PORT_IS) & PORT_IS_TFES != 0) {
            return AhciError.TaskFileError;
        }
        asm volatile ("pause");
    }
    if (remaining == 0) return AhciError.CommandTimeout;
    if (readPort(controller_, PORT_IS) & PORT_IS_TFES != 0 or
        readPort(controller_, PORT_TFD) & TFD_ERR != 0)
    {
        return AhciError.TaskFileError;
    }

    // TODO: Use multiple command slots and NCQ instead of serializing slot 0.
    // TODO: Decode PxIS/PxSERR/PxTFD into actionable error diagnostics and
    // perform the AHCI-defined error recovery sequence.
}

fn physicalAddress(pointer: anytype) u64 {
    return @intFromPtr(pointer) - kernel.state.mem_manager.memory_layout.kernel_offset;
}

fn putU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset + 0] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

fn blockRead(
    dev: *block_device.BlockDev,
    block_number: u64,
    destination: *anyopaque,
    destination_len: u64,
) block_device.BlockDevError!void {
    return blockReadMultiple(dev, block_number, 1, destination, destination_len);
}

fn blockReadMultiple(
    dev: *block_device.BlockDev,
    block_number: u64,
    count: u64,
    destination: *anyopaque,
    destination_len: u64,
) block_device.BlockDevError!void {
    const controller_ = &(controller orelse return block_device.BlockDevError.NotReady);
    const total_bytes = std.math.mul(u64, count, 512) catch
        return block_device.BlockDevError.InvalidRequest;
    if (destination_len < total_bytes or block_number + count > controller_.sector_count) {
        return block_device.BlockDevError.InvalidRequest;
    }

    io_mutex.lock();
    defer io_mutex.unlock();

    const output: [*]u8 = @ptrCast(destination);
    var sectors_remaining = count;
    var current_lba = block_number;
    var output_offset: usize = 0;
    while (sectors_remaining > 0) {
        const chunk: u16 = @intCast(@min(sectors_remaining, MAX_SECTORS_PER_COMMAND));
        const chunk_bytes = @as(usize, chunk) * 512;
        issueCommand(controller_, ATA_CMD_READ_DMA_EXT, current_lba, chunk, chunk_bytes, false) catch |err| {
            log.err("AHCI read failed at LBA {}: {}", .{ current_lba, err });
            return block_device.BlockDevError.DeviceError;
        };
        @memcpy(output[output_offset..][0..chunk_bytes], dma_buffer[0..chunk_bytes]);
        current_lba += chunk;
        sectors_remaining -= chunk;
        output_offset += chunk_bytes;
    }
    _ = dev;

    // TODO: Make BlockDev requests asynchronous so callers can overlap I/O
    // with computation instead of blocking a kernel thread.
}

pub fn isReady() bool {
    return controller != null;
}

/// Overwrites already-reserved sectors without changing filesystem metadata.
/// Callers must ensure the range belongs exclusively to a fixed diagnostic
/// file or another reserved on-disk area.
pub fn writeAbsoluteSectors(start_lba: u64, data: []const u8) !void {
    const controller_ = &(controller orelse return AhciError.ControllerNotFound);
    if (data.len == 0 or data.len % 512 != 0) return AhciError.DeviceTooSmall;
    const sector_total = data.len / 512;
    if (start_lba + sector_total > controller_.sector_count) return AhciError.DeviceTooSmall;

    io_mutex.lock();
    defer io_mutex.unlock();

    var sectors_remaining = sector_total;
    var current_lba = start_lba;
    var input_offset: usize = 0;
    while (sectors_remaining > 0) {
        const chunk: u16 = @intCast(@min(sectors_remaining, MAX_SECTORS_PER_COMMAND));
        const chunk_bytes = @as(usize, chunk) * 512;
        @memcpy(dma_buffer[0..chunk_bytes], data[input_offset..][0..chunk_bytes]);
        try issueCommand(controller_, ATA_CMD_WRITE_DMA_EXT, current_lba, chunk, chunk_bytes, true);
        current_lba += chunk;
        sectors_remaining -= chunk;
        input_offset += chunk_bytes;
    }
    try issueCommand(controller_, ATA_CMD_FLUSH_CACHE_EXT, 0, 0, 0, false);

    // TODO: Add read-after-write verification and retain two generation-tagged
    // log slots so a torn write cannot destroy the previous boot record.
}
