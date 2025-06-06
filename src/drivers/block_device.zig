const std = @import("std");
const kernel = @import("kernel");

pub const BlockDevType = enum(u8) {
    MASS_STORAGE,
    PARTITION,

    pub fn toString(self: BlockDevType) []const u8 {
        return switch (self) {
            .MASS_STORAGE => "Mass Storage",
            .PARTITION => "Partition",
        };
    }

    pub fn toValue(self: BlockDevType) u8 {
        return @intFromEnum(self);
    }
};

pub const BlockDevError = error{
    DeviceError,
    InvalidBlock,
    NotReady,
    Timeout,
    OutOfMemory,
};

pub const BlockDev = struct {
    tot_length: u64,
    read_block: *const fn (dev: *BlockDev, blk_num: u64, dst: *anyopaque) BlockDevError!void,
    blk_size: u32,
    dev_type: BlockDevType,
    name: []const u8,
    fs_type: u8,
    next: ?*BlockDev,

    pub fn readBlock(self: *BlockDev, blk_num: u64, dst: *anyopaque) BlockDevError!void {
        if (blk_num >= self.tot_length / self.blk_size) {
            return BlockDevError.InvalidBlock;
        }
        return self.read_block(self, blk_num, dst);
    }
};

// Global block device registry
var block_devices: ?*BlockDev = null;
var registry_mutex = kernel.mutex.Mutex.init();

pub fn registerBlockDevice(dev: *BlockDev) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();

    dev.next = block_devices;
    block_devices = dev;

    std.log.info("Registered block device: {s} ({} blocks of {} bytes)", .{
        dev.name, dev.tot_length / dev.blk_size, dev.blk_size
    });
}

pub fn getBlockDeviceIterator() BlockDeviceIterator {
    return BlockDeviceIterator{ .current = block_devices };
}

pub const BlockDeviceIterator = struct {
    current: ?*BlockDev,

    pub fn next(self: *BlockDeviceIterator) ?*BlockDev {
        if (self.current) |dev| {
            self.current = dev.next;
            return dev;
        }
        return null;
    }
};
