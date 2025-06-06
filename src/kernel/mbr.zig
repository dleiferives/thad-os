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

const partition_table_entry = struct {
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
        };
    }

    pub fn toValue(self: @This()) u8 {
        return @intFromEnum(self);
    }

    pub fn fromValue(value: u8) PartitionType {
        return switch (value) {
            0x0C => PartitionType.FAT32_LBA,
            else => @panic("Invalid partition type value"),
        };
    }
};

pub fn logAllMBR() !void {
    var block_dev_iter = drivers.block_device.getBlockDeviceIterator();
    while (block_dev_iter.next()) |dev| {
        if (dev.fs_type == drivers.block_device.BlockDevType.MASS_STORAGE.toValue()) {
            log.info("Reading MBR from block device: {s}", .{dev.name});
            var mbr_bytes: [512]u8 = undefined;
            try dev.readBlock(0, &mbr_bytes);
            const mbr_data = mbr.fromBytes(mbr_bytes[0..]);
            if (!mbr_data.validSignature()) {
                log.warn("Invalid MBR signature on device: {s}", .{dev.name});
                continue;
            }
            log.info("MBR Data: ", .{});
            for (mbr_data.partition_table) |entry| {
                if (entry.boot_flag == 0) continue; // Skip empty entries
                entry.rawLog();
            }
        } else {
            log.debug("Skipping non-partition block device: {s}", .{dev.name});
        }
    }
}
