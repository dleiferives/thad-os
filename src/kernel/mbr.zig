const std = @import("std");
const kernel = @import("kernel");
const drivers = @import("drivers");

const log = std.log.scoped(.kernel_mbr);

const mbr = struct {
    bootstrap: []u8,
    partition_table: [4]partition_table_entry,
    signature: [2]u8,

    pub fn fromBytes(bytes: []u8) mbr {
        if (bytes.len < 512) {
            @panic("MBR bytes must be at least 512 bytes long");
        }
        return mbr{
            .bootstrap = bytes[0..446],
            .partition_table = [_]partition_table_entry{
                partition_table_entry.fromBytes(bytes[446..462]),
                partition_table_entry.fromBytes(bytes[462..478]),
                partition_table_entry.fromBytes(bytes[478..494]),
                partition_table_entry.fromBytes(bytes[494..510]),
            },
            .signature = bytes[510..512].*,
        };
    }

    pub fn validSignature(self: mbr) bool {
        return self.signature[0] == 0x55 and self.signature[1] == 0xAA;
    }
};

const chs = struct {
    head: u8,
    sector: u6,
    cylinder: u10,

    pub fn toLBA(self: chs) u32 {
        return (self.cylinder * 256 + self.head) * 63 + (self.sector - 1);
    }

    pub fn fromBytes(bytes: []u8) chs {
        return chs{
            .head = bytes[0],
            .sector = @truncate(bytes[1]),
            .cylinder = @as(u10, (bytes[1] & 0xC0) >> 6) | @as(u10, bytes[2]) << 2,
        };
    }

    pub fn rawLog(self: @This()) void {
        log.warn("Head {} Sector {} Cylinder {} ", .{ self.head, self.sector, self.cylinder });
    }
};

pub const partition_table_entry = struct {
    boot_flag: u8,
    first_chs: chs,
    partition_type: u8,
    last_chs: chs,
    lba_first_absolute: u32,
    num_sectors: u32,

    pub fn fromBytes(bytes: []u8) partition_table_entry {
        return partition_table_entry{
            .boot_flag = bytes[0],
            .first_chs = chs.fromBytes(bytes[1..4]),
            .partition_type = bytes[4],
            .last_chs = chs.fromBytes(bytes[5..8]),
            .lba_first_absolute = @as(u32, std.mem.bytesToValue(u32, bytes[8..12])),
            .num_sectors = @as(u32, std.mem.bytesToValue(u32, bytes[12..16])),
        };
    }

    pub fn rawLog(self: @This()) void {
        log.warn("Boot Flag: {}\nLBA Start: {}\nNum Sectors: {}\n", .{ self.boot_flag, self.lba_first_absolute, self.num_sectors });
        if (PartitionType.validType(self.partition_type)) {
            log.warn("Partition Type: {s}\n", .{PartitionType.fromValue(self.partition_type).toString()});
        } else {
            log.warn("Partition Type: Unknown (0x{X:0>2})\n", .{self.partition_type});
        }
        log.warn("First CHS: ", .{});
        self.first_chs.rawLog();
        log.warn("\nLast CHS: ", .{});
        self.last_chs.rawLog();
        log.warn("\n", .{});
    }
};

pub const PartitionType = enum(u8) {
    FAT32_LBA = 0x0C,
    LINIX = 0x83,

    pub fn validType(value: u8) bool {
        const fields = @typeInfo(@This()).@"enum".fields;
        inline for (fields) |field| {
            if (field.value == value) return true;
        }
        return false;
    }

    pub fn toString(self: @This()) []const u8 {
        return switch (self) {
            .FAT32_LBA => "FAT32 with LBA",
            .LINIX => "Linux",
        };
    }

    pub fn toValue(self: @This()) u8 {
        return @intFromEnum(self);
    }

    pub fn fromValue(value: u8) PartitionType {
        return switch (value) {
            0x0C => PartitionType.FAT32_LBA,
            0x83 => PartitionType.LINIX,
            else => @panic("Invalid partition type value"),
        };
    }
};

pub const PartitionEntryIterator = struct {
    const TableFormat = enum {
        mbr,
        gpt,
    };

    dev: *drivers.block_device.BlockDev,
    entries: [4]partition_table_entry,
    index: usize = 0,
    format: TableFormat = .mbr,
    gpt_entries_lba: u64 = 0,
    gpt_entry_count: u32 = 0,
    gpt_entry_size: u32 = 0,

    pub fn init(dev: *drivers.block_device.BlockDev) ?PartitionEntryIterator {
        var mbr_bytes: [512]u8 = undefined;
        dev.readBlock(0, &mbr_bytes) catch {
            return null;
        };
        const mbr_data = mbr.fromBytes(mbr_bytes[0..]);
        if (!mbr_data.validSignature()) {
            return null;
        }
        var iterator = PartitionEntryIterator{
            .dev = dev,
            .entries = mbr_data.partition_table,
            .index = 0,
        };

        // A GPT disk has a protective MBR entry with type 0xEE. Prefer the GPT
        // table when it is present, including on hybrid GPT/MBR disks.
        for (mbr_data.partition_table) |entry| {
            if (entry.partition_type != 0xEE) continue;

            if (dev.blk_size > 4096) return iterator;
            var header_block: [4096]u8 = undefined;
            const header = header_block[0..dev.blk_size];
            dev.readBlock(1, header) catch return iterator;

            if (header.len < 92 or !std.mem.eql(u8, header[0..8], "EFI PART")) {
                return iterator;
            }

            const entry_size = std.mem.bytesToValue(u32, header[84..88]);
            const entry_count = std.mem.bytesToValue(u32, header[80..84]);
            const entries_lba = std.mem.bytesToValue(u64, header[72..80]);

            // GPT entries are at least 128 bytes. We only need the fixed first
            // 56 bytes and require those bytes not to cross a logical block.
            if (entry_size < 128 or entry_size > dev.blk_size or
                entry_count == 0 or entries_lba < 2)
            {
                return iterator;
            }

            iterator.format = .gpt;
            iterator.gpt_entries_lba = entries_lba;
            iterator.gpt_entry_count = entry_count;
            iterator.gpt_entry_size = entry_size;
            return iterator;
        }

        return iterator;
    }

    pub fn next(self: *PartitionEntryIterator) ?partition_table_entry {
        return switch (self.format) {
            .mbr => self.nextMbr(),
            .gpt => self.nextGpt(),
        };
    }

    fn nextMbr(self: *PartitionEntryIterator) ?partition_table_entry {
        while (self.index < self.entries.len) {
            const entry = self.entries[self.index];
            self.index += 1;

            // The active flag says whether legacy BIOS should boot a partition;
            // it does not say whether an entry exists. Empty entries have no
            // type or sectors. Skip GPT's protective entry on hybrid disks.
            if (entry.partition_type == 0 or entry.num_sectors == 0 or
                entry.partition_type == 0xEE)
            {
                continue;
            }
            return entry;
        }
        return null;
    }

    fn nextGpt(self: *PartitionEntryIterator) ?partition_table_entry {
        while (self.index < self.gpt_entry_count) {
            const entry_index: u64 = self.index;
            self.index += 1;

            const byte_offset = entry_index * self.gpt_entry_size;
            const block_offset: usize = @intCast(byte_offset % self.dev.blk_size);
            if (block_offset + 56 > self.dev.blk_size) continue;

            const block_lba = self.gpt_entries_lba +
                (byte_offset / self.dev.blk_size);
            var entry_block: [4096]u8 = undefined;
            const block = entry_block[0..self.dev.blk_size];
            self.dev.readBlock(block_lba, block) catch return null;
            const bytes = block[block_offset..][0..56];

            var type_guid_is_zero = true;
            for (bytes[0..16]) |byte| {
                if (byte != 0) {
                    type_guid_is_zero = false;
                    break;
                }
            }
            if (type_guid_is_zero) continue;

            const first_lba = std.mem.bytesToValue(u64, bytes[32..40]);
            const last_lba = std.mem.bytesToValue(u64, bytes[40..48]);
            if (last_lba < first_lba or first_lba > std.math.maxInt(u32)) continue;

            const sector_count = last_lba - first_lba + 1;
            if (sector_count > std.math.maxInt(u32)) continue;

            // Keep the existing filesystem interface while presenting a GPT
            // partition. CHS and the legacy type/active fields are synthetic;
            // ext2 only consumes the LBA fields.
            return partition_table_entry{
                .boot_flag = 0x80,
                .first_chs = chs{ .head = 0, .sector = 1, .cylinder = 0 },
                .partition_type = PartitionType.LINIX.toValue(),
                .last_chs = chs{ .head = 0, .sector = 1, .cylinder = 0 },
                .lba_first_absolute = @intCast(first_lba),
                .num_sectors = @intCast(sector_count),
            };
        }
        return null;
    }
};

pub fn logAllMBR() !void {
    var block_dev_iter = drivers.block_device.getBlockDeviceIterator();
    while (block_dev_iter.next()) |dev| {
        if (dev.fs_type == drivers.block_device.BlockDevType.MASS_STORAGE.toValue()) {
            log.info("Reading MBR from block device: {s}", .{dev.name});
            var partition_iter = PartitionEntryIterator.init(dev) orelse {
                log.warn("Invalid MBR signature on device: {s}", .{dev.name});
                continue;
            };
            log.info("Partition table data: ", .{});
            while (partition_iter.next()) |entry| {
                entry.rawLog();
            }
        } else {
            log.debug("Skipping non-partition block device: {s}", .{dev.name});
        }
    }
}
