const std = @import("std");
const kernel = @import("kernel");
const block_device = @import("block_device.zig");

const log = std.log.scoped(.multiboot_module);

pub const ROOT_MODULE_NAME = "thad-root";

var module_start: usize = 0;
var module_size: usize = 0;

pub fn init() !void {
    const module = kernel.state.multiboot_info.findModule(ROOT_MODULE_NAME) orelse
        return error.RootModuleNotFound;
    if (module.getSize() < 512 or module.getSize() % 512 != 0) {
        return error.InvalidRootModule;
    }

    const allocator = kernel.state.getKernelAllocator() orelse return error.NoAllocator;
    const dev = try allocator.create(block_device.BlockDev);
    module_start = kernel.state.mem_manager.memory_layout.kernel_offset |
        @as(usize, module.mod_start);
    module_size = module.getSize();

    dev.* = .{
        .tot_length = module_size,
        .read_block = readBlock,
        .read_blocks = readBlocks,
        .blk_size = 512,
        .dev_type = .MASS_STORAGE,
        .name = "multiboot:thad-root",
        .fs_type = block_device.BlockDevType.MASS_STORAGE.toValue(),
        .next = null,
    };
    block_device.registerBlockDevice(dev);
    log.info("Registered {s} as a {} byte memory-backed disk", .{
        ROOT_MODULE_NAME,
        module_size,
    });
}

fn readBlock(
    dev: *block_device.BlockDev,
    blk_num: u64,
    dst: *anyopaque,
    dst_len: u64,
) block_device.BlockDevError!void {
    return readBlocks(dev, blk_num, 1, dst, dst_len);
}

fn readBlocks(
    dev: *block_device.BlockDev,
    blk_num: u64,
    count: u64,
    dst: *anyopaque,
    dst_len: u64,
) block_device.BlockDevError!void {
    const byte_count = std.math.mul(u64, count, dev.blk_size) catch
        return block_device.BlockDevError.InvalidRequest;
    const byte_offset = std.math.mul(u64, blk_num, dev.blk_size) catch
        return block_device.BlockDevError.InvalidRequest;
    if (dst_len < byte_count or byte_offset + byte_count > module_size) {
        return block_device.BlockDevError.InvalidBlock;
    }

    const source: [*]const u8 = @ptrFromInt(module_start + byte_offset);
    const destination: [*]u8 = @ptrCast(dst);
    @memcpy(destination[0..byte_count], source[0..byte_count]);
}
