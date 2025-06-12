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
    InvalidRequest,
    NotReady,
    Timeout,
    OutOfMemory,
};

pub const DataSlice = struct {
    data: []u8,
    alloc: std.mem.Allocator,
    start: usize = 0,
    end: usize = 0,
    valid: bool = true,
    cached: bool = false,

    pub fn create(dev: *BlockDev, allocator: std.mem.Allocator, start: usize, size: usize) !DataSlice {
        const data = try allocator.alloc(u8, size);
        errdefer allocator.free(data);
        const block_start = start / dev.blk_size;
        const block_end = (start + size + dev.blk_size - 1) / dev.blk_size;
        if (block_start >= dev.tot_length / dev.blk_size or block_end > dev.tot_length / dev.blk_size) {
            return BlockDevError.InvalidBlock;
        }
        // offset into the first block
        const offset = start % dev.blk_size;
        // read out of the first block
        const buffer = try allocator.alloc(u8,dev.blk_size);
        defer allocator.free(buffer);
        try dev.readBlock(block_start, buffer);

        // first block data
        var index: usize = 0;
        for (buffer[offset..]) |byte| {
            if (index >= size) break;
            data[index] = byte;
            index += 1;
        }
        // read the rest of the blocks
        for (block_start + 1 .. block_end) |blk_num| blc_l: {
            if (index >= size) break;
            try dev.readBlock(blk_num, buffer);
            for (buffer) |byte| {
                if (index >= size) break :blc_l;
                data[index] = byte;
                index += 1;
            }
        }
        return DataSlice{
            .data = data,
            .alloc = allocator,
            .start = start,
            .end = start + size,
            .valid = true,
        };
    }

    pub fn free(self: *DataSlice) void {
        if (!self.valid) {
            @panic("DataSlice already freed");
        }
        if (self.cached) {
            return; // Do not free cached slices
        }
        self.alloc.free(self.data);
        self.valid = false;
    }

    pub fn destroy(self: *DataSlice) void {
        self.alloc.free(self.data);
        self.valid = false;
    }
};

pub const BlockDev = struct {
    tot_length: u64,
    read_block: *const fn (dev: *BlockDev, blk_num: u64, dst: *anyopaque, dst_len:u64) BlockDevError!void,
    read_blocks: *const fn (dev: *BlockDev, blk_num: u64, count: u64, dst: *anyopaque, dst_len:u64) BlockDevError!void,
    // TODO @(dleiferives,07f290fa-45bc-4c8b-a0b0-19d57e3a13f1): add writing... ~#
    blk_size: u32,
    dev_type: BlockDevType,
    name: []const u8,
    fs_type: u8,
    next: ?*BlockDev,
    // TODO @(dleiferives,2d198cc6-0032-4596-8460-a40427498e2d): I like having the
    // block dev not having an allocator or allocated memory. But this would be a
    // good addition I think that I'm going to put it in the ata and in the ext2
    // levels but this would be the prefered place for it however, that means rethinking (refactorig)
    // my architechture a bit more than I really want to.~#
    // cache: ?kernel.cache.Cache(u64,[512]u8) = null,


    pub fn readBlock(self: *BlockDev, blk_num: u64, dst: []u8) BlockDevError!void {
        if (blk_num >= self.tot_length / self.blk_size) {
            return BlockDevError.InvalidBlock;
        }
        return self.read_block(self, blk_num, @ptrCast(dst.ptr),dst.len);
    }


    pub fn readBlocks(self: *BlockDev, blk_num: u64, count: u64, dst: []u8) BlockDevError!void {
        if (blk_num >= self.tot_length / self.blk_size) {
            std.log.err("Invalid block number: {d} for device: {s}", .{blk_num, self.name});
            return BlockDevError.InvalidBlock;
        }
        return self.read_blocks(self, blk_num, count, @ptrCast(dst.ptr), dst.len);
    }

    pub fn createDataSlice(
        self: *BlockDev,
        allocator: std.mem.Allocator,
        start: usize,
        size: usize,
    ) BlockDevError!DataSlice {
        return DataSlice.create(self, allocator, start, size);
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
