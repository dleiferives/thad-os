// src/kernel/simple_fs.zig - Simple filesystem implementation for VFS
const std = @import("std");
const vfs = @import("vfs.zig");
const ext2 = @import("ext2.zig");
const kernel = @import("kernel.zig");

const log = std.log.scoped(.simple_fs);

// VFS that wraps ext2
pub const SimpleNode = struct {
    // VFS requires this to be first
    vfs_node: vfs.VfsNode,

    // Simplefs data
    is_directory: bool,
    inode_number: u64,
    file_size: u64,

    // For root directory, we might not have an ext2 filesystem
    ext2_fs: ?*ext2.Ex2Filesystem = null,
    ext2_inode: ?ext2.inode_table_entry = null,

    // For simple in-memory directories
    children: ?std.ArrayList(*SimpleNode) = null,
    allocator: std.mem.Allocator,

    const Self = @This();

    // VFS callbacks
    const vtable = vfs.VfsNodeVTable{
        .stat = stat,
        .readdir = readdir,
        .lookup = lookup,
        .read = read,
        .release = release,
    };

    pub fn createRoot(allocator: std.mem.Allocator) !*Self {
        const node = try allocator.create(Self);

        node.* = Self{
            .vfs_node = vfs.VfsNode{
                .name = "/",
                .parent = null,
                .mount = undefined,
                .vtable = &vtable,
                .private_data = node,
            },
            .is_directory = true,
            .inode_number = 2,
            .file_size = 0,
            .children = std.ArrayList(*SimpleNode).init(allocator),
            .allocator = allocator,
        };

        return node;
    }

    pub fn createExt2Node(
        allocator: std.mem.Allocator,
        name: []const u8,
        ext2_fs: *ext2.Ex2Filesystem,
        inode: ext2.inode_table_entry,
        inode_num: u64,
    ) !*Self {
        const node = try allocator.create(Self);

        const name_copy = try allocator.dupe(u8, name);

        node.* = Self{
            .vfs_node = vfs.VfsNode{
                .name = name_copy,
                .parent = null,
                .mount = undefined,
                .vtable = &vtable,
                .private_data = node,
            },
            .is_directory = inode.mode.directory,
            .inode_number = inode_num,
            .file_size = inode.size,
            .ext2_fs = ext2_fs,
            .ext2_inode = inode,
            .allocator = allocator,
        };

        if (node.is_directory) {
            node.children = std.ArrayList(*SimpleNode).init(allocator);
        }

        return node;
    }

    pub fn addChild(self: *Self, child: *Self) !void {
        if (!self.is_directory or self.children == null) {
            return vfs.VfsError.NotDirectory;
        }

        child.vfs_node.parent = &self.vfs_node;
        try self.children.?.append(child);
    }

    fn stat(node: *vfs.VfsNode, stat_l: *vfs.VfsStat) vfs.VfsError!void {
        const self: *Self = @ptrCast(@alignCast(node.private_data.?));

        stat_l.* = vfs.VfsStat{
            .st_ino = self.inode_number,
            .st_mode = if (self.is_directory)
                vfs.FileType.DIR.toMode() | 0o755
            else
                vfs.FileType.REG.toMode() | 0o644,
            .st_size = self.file_size,
            .st_blksize = 512,
            .st_blocks = (self.file_size + 511) / 512,
        };
    }

    fn readdir(
        node: *vfs.VfsNode,
        ctx: *vfs.ReaddirContext,
    ) vfs.VfsError!void {
        const self: *Self = @ptrCast(@alignCast(node.private_data.?));

        if (!self.is_directory) {
            return vfs.VfsError.NotDirectory;
        }

        // Emit "." and ".." entries
        var dirent = vfs.VfsDirent{
            .d_ino = self.inode_number,
            .d_type = vfs.VfsDirent.DT_DIR,
            .d_name = ".",
        };
        try ctx.emit(&dirent);

        if (node.parent) |parent| {
            const parent_node: *Self = @ptrCast(@alignCast(parent.private_data.?));
            dirent = vfs.VfsDirent{
                .d_ino = parent_node.inode_number,
                .d_type = vfs.VfsDirent.DT_DIR,
                .d_name = "..",
            };
            try ctx.emit(&dirent);
        } else {
            // Root directory - .. points to itself
            dirent = vfs.VfsDirent{
                .d_ino = self.inode_number,
                .d_type = vfs.VfsDirent.DT_DIR,
                .d_name = "..",
            };
            try ctx.emit(&dirent);
        }

        // If we have an ext2 filesystem, read from it
        if (self.ext2_fs != null and self.ext2_inode != null) {
            try self.readdirExt2(ctx);
        } else if (self.children != null) {
            // Otherwise read from memory
            for (self.children.?.items) |child| {
                dirent = vfs.VfsDirent{
                    .d_ino = child.inode_number,
                    .d_type = if (child.is_directory)
                        vfs.VfsDirent.DT_DIR
                    else
                        vfs.VfsDirent.DT_REG,
                    .d_name = child.vfs_node.name,
                };
                try ctx.emit(&dirent);
            }
        }
    }

    fn readdirExt2(
        self: *Self,
        ctx: *vfs.ReaddirContext,
    ) vfs.VfsError!void {
        if (self.ext2_fs == null or self.ext2_inode == null) {
            return;
        }

        const ext2_fs = self.ext2_fs.?;
        const inode = self.ext2_inode.?;

        if (!inode.mode.directory) {
            return vfs.VfsError.NotDirectory;
        }

        const num_blocks = (inode.blocks_count * 512) /
            ext2_fs.superblock.block_size;
        var block_index: u32 = 0;

        while (block_index < num_blocks) : (block_index += 1) {
            var block_slice = ext2_fs.readInodeBlock(inode, block_index) catch |err| {
                log.err("Failed to read inode block: {}", .{err});
                continue;
            };
            defer block_slice.free();

            var offset: usize = 0;
            while (offset < block_slice.data.len) {
                const entry = ext2.directory_entry.fromBytes(block_slice.data[offset..]);
                if (entry.rec_len == 0) break;

                if (entry.inode != 0) { // Valid entry
                    const dirent = vfs.VfsDirent{
                        .d_ino = entry.inode,
                        .d_type = switch (entry.file_type) {
                            .directory => vfs.VfsDirent.DT_DIR,
                            .regular => vfs.VfsDirent.DT_REG,
                            .symlink => vfs.VfsDirent.DT_LNK,
                            .character_device => vfs.VfsDirent.DT_CHR,
                            .block_device => vfs.VfsDirent.DT_BLK,
                            .fifo => vfs.VfsDirent.DT_FIFO,
                            .socket => vfs.VfsDirent.DT_SOCK,
                            else => vfs.VfsDirent.DT_UNKNOWN,
                        },
                        .d_name = entry.getName(),
                    };

                    ctx.emit(&dirent) catch |err| {
                        return err;
                    };
                }

                offset += entry.rec_len;
            }
        }
    }

    fn lookup(
        node: *vfs.VfsNode,
        name: []const u8,
    ) vfs.VfsError!*vfs.VfsNode {
        const self: *Self = @ptrCast(@alignCast(node.private_data.?));

        if (!self.is_directory) {
            return vfs.VfsError.NotDirectory;
        }

        // Handle special cases
        if (std.mem.eql(u8, name, ".")) {
            node.ref();
            return node;
        }

        if (std.mem.eql(u8, name, "..")) {
            if (node.parent) |parent| {
                parent.ref();
                return parent;
            } else {
                node.ref();
                return node; // Root directory
            }
        }

        // Look in ext2 filesystem first
        if (self.ext2_fs != null and self.ext2_inode != null) {
            if (self.lookupExt2(name)) |child_node| {
                return child_node;
            } else |_| {
                // Fall through to memory-based lookup
            }
        }

        // Look in memory children
        if (self.children) |children| {
            for (children.items) |child| {
                if (std.mem.eql(u8, child.vfs_node.name, name)) {
                    child.vfs_node.ref();
                    return &child.vfs_node;
                }
            }
        }

        return vfs.VfsError.NotFound;
    }

    fn lookupExt2(
        self: *Self,
        name: []const u8,
    ) vfs.VfsError!*vfs.VfsNode {
        if (self.ext2_fs == null or self.ext2_inode == null) {
            return vfs.VfsError.NotFound;
        }

        const ext2_fs = self.ext2_fs.?;
        const inode = self.ext2_inode.?;

        const num_blocks = (inode.blocks_count * 512) /
            ext2_fs.superblock.block_size;
        var block_index: u32 = 0;

        while (block_index < num_blocks) : (block_index += 1) {
            var block_slice = ext2_fs.readInodeBlock(inode, block_index) catch continue;
            defer block_slice.free();

            var offset: usize = 0;
            while (offset < block_slice.data.len) {
                const entry = ext2.directory_entry.fromBytes(block_slice.data[offset..]);
                if (entry.rec_len == 0) break;

                if (entry.inode != 0 and std.mem.eql(u8, entry.getName(), name)) {
                    // Found the entry, create a VFS node for it
                    const child_inode = ext2_fs.getInode(entry.inode) catch {
                        return vfs.VfsError.IoError;
                    };

                    const child_node = createExt2Node(
                        self.allocator,
                        name,
                        ext2_fs,
                        child_inode,
                        entry.inode,
                    ) catch {
                        return vfs.VfsError.OutOfMemory;
                    };

                    child_node.vfs_node.parent = &self.vfs_node;
                    child_node.vfs_node.mount = self.vfs_node.mount;
                    return &child_node.vfs_node;
                }

                offset += entry.rec_len;
            }
        }

        return vfs.VfsError.NotFound;
    }

    fn read(
        node: *vfs.VfsNode,
        offset: u64,
        buffer: []u8,
    ) vfs.VfsError!usize {
        const self: *Self = @ptrCast(@alignCast(node.private_data.?));

        if (self.is_directory) {
            return vfs.VfsError.IsDirectory;
        }

        const ext2_fs = self.ext2_fs orelse return vfs.VfsError.NotSupported;
        const inode = self.ext2_inode orelse return vfs.VfsError.NotSupported;

        // Check for read beyond EOF
        if (offset >= self.file_size) {
            return 0;
        }

        const bytes_to_read = @min(buffer.len, self.file_size - offset);
        if (bytes_to_read == 0) {
            return 0;
        }

        const block_size = ext2_fs.superblock.block_size;
        var bytes_read_so_far: usize = 0;
        var current_offset_in_file = offset;

        // Read in larger chunks to reduce overhead
        while (bytes_read_so_far < bytes_to_read) {
            const current_block_index: u32 = @intCast(current_offset_in_file / block_size);
            const offset_in_block: usize = @intCast(current_offset_in_file % block_size);

            // Calculate how many consecutive blocks we can read
            const remaining_bytes = bytes_to_read - bytes_read_so_far;

            // If we're reading from the start of a block and have multiple blocks to read
            if (offset_in_block == 0 and remaining_bytes >= block_size) {
                // Calculate consecutive blocks. i_blocks is measured in 512-byte
                // sectors and includes metadata blocks, so derive the number of
                // file blocks from i_size instead.
                var consecutive_blocks: u32 = 1;
                const file_block_count = (self.file_size + block_size - 1) / block_size;
                const max_blocks = @min(
                    remaining_bytes / block_size,
                    file_block_count - current_block_index,
                );

                if (max_blocks > 1) {
                    const first_block_id = ext2_fs.getInodeBlockID(inode, current_block_index) catch |err| {
                        log.err("Failed to get block ID for inode {}: {}", .{ inode, err });
                        return vfs.VfsError.IoError;
                    };

                    // A zero ext2 block pointer represents a sparse hole. Reads
                    // from a hole return zero bytes; it is not an I/O failure.
                    if (first_block_id == 0) {
                        const bytes_to_zero = @min(block_size, remaining_bytes);
                        @memset(buffer[bytes_read_so_far..][0..bytes_to_zero], 0);
                        bytes_read_so_far += bytes_to_zero;
                        current_offset_in_file += bytes_to_zero;
                        continue;
                    }

                    // Check for consecutive blocks
                    for (1..@min(max_blocks, 64)) |i| { // Limit to 64 blocks (32KB) at once
                        const next_block_id = ext2_fs.getInodeBlockID(inode, current_block_index + @as(u32, @intCast(i))) catch break;
                        if (next_block_id != first_block_id + i) break;
                        consecutive_blocks += 1;
                    }

                    // Read multiple blocks at once
                    const bytes_to_read_now = consecutive_blocks * block_size;
                    const dest_slice = buffer[bytes_read_so_far .. bytes_read_so_far + @as(usize, bytes_to_read_now)];

                    ext2_fs.getBlocksRaw(first_block_id, consecutive_blocks, dest_slice) catch {
                        return vfs.VfsError.IoError;
                    };

                    bytes_read_so_far += bytes_to_read_now;
                    current_offset_in_file += bytes_to_read_now;
                    continue;
                }
            }

            // Fall back to single block read for partial blocks or non-consecutive blocks
            const block_id = ext2_fs.getInodeBlockID(inode, current_block_index) catch |err| {
                log.err("Failed to get inode block ID {}: {}", .{ current_block_index, err });
                return vfs.VfsError.IoError;
            };
            if (block_id == 0) {
                const bytes_to_zero = @min(
                    block_size - offset_in_block,
                    bytes_to_read - bytes_read_so_far,
                );
                @memset(buffer[bytes_read_so_far..][0..bytes_to_zero], 0);
                bytes_read_so_far += bytes_to_zero;
                current_offset_in_file += bytes_to_zero;
                continue;
            }

            var block_slice = ext2_fs.readInodeBlock(inode, current_block_index) catch |err| {
                log.err("Failed to read inode block {}: {}", .{ current_block_index, err });
                return vfs.VfsError.IoError;
            };
            defer block_slice.free();

            const bytes_to_copy_from_this_block = @min(
                block_size - offset_in_block,
                bytes_to_read - bytes_read_so_far,
            );

            const src_slice = block_slice.data[offset_in_block .. offset_in_block + bytes_to_copy_from_this_block];
            const dest_slice = buffer[bytes_read_so_far .. bytes_read_so_far + bytes_to_copy_from_this_block];
            @memcpy(dest_slice, src_slice);

            bytes_read_so_far += bytes_to_copy_from_this_block;
            current_offset_in_file += bytes_to_copy_from_this_block;
        }

        // TODO: Coalesce adjacent sparse blocks so large holes can be zero-filled
        // in one operation instead of advancing one filesystem block at a time.

        return bytes_read_so_far;
    }

    fn release(node: *vfs.VfsNode) void {
        const self: *Self = @ptrCast(@alignCast(node.private_data.?));

        if (self.children) |children| {
            for (children.items) |child| {
                child.vfs_node.unref();
            }
            children.deinit();
        }

        self.allocator.free(node.name);
        self.allocator.destroy(self);
    }
};

// Mount an ext2 filesystem as root
pub fn mountExt2Root(
    allocator: std.mem.Allocator,
    ext2_fs: *ext2.Ex2Filesystem,
) !void {
    log.info("Mounting ext2 filesystem as root", .{});

    const root_inode = try ext2_fs.getInode(2); // Root inode
    const root_node = try SimpleNode.createExt2Node(
        allocator,
        "/",
        ext2_fs,
        root_inode,
        2,
    );

    try vfs.mount("/", &root_node.vfs_node, "ext2");
    log.info("Ext2 root filesystem mounted successfully", .{});
}

// Create a simple in-memory root filesystem
pub fn createSimpleRoot(allocator: std.mem.Allocator) !void {
    log.info("Creating simple in-memory root filesystem", .{});

    const root_node = try SimpleNode.createRoot(allocator);

    try vfs.mount("/", &root_node.vfs_node, "simple");
    log.info("Simple root filesystem created and mounted", .{});
}
