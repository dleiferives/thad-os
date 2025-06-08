// src/kernel/vfs.zig - Virtual File System implementation
const std = @import("std");
const kernel = @import("kernel.zig");
const thread = @import("thread.zig");
const ext2 = @import("ext2.zig");

const log = std.log.scoped(.kernel_vfs);

// POSIX file types and permissions
pub const FileType = enum(u16) {
    UNKNOWN = 0,
    FIFO = 0x1000,
    CHR = 0x2000,
    DIR = 0x4000,
    BLK = 0x6000,
    REG = 0x8000,
    LNK = 0xA000,
    SOCK = 0xC000,

    pub fn toMode(self: FileType) u16 {
        return @intFromEnum(self);
    }
};

pub const FileMode = packed struct {
    // Owner permissions
    owner_execute: bool = false,
    owner_write: bool = false,
    owner_read: bool = false,

    // Group permissions
    group_execute: bool = false,
    group_write: bool = false,
    group_read: bool = false,

    // Other permissions
    other_execute: bool = false,
    other_write: bool = false,
    other_read: bool = false,

    // Special bits
    sticky: bool = false,
    setgid: bool = false,
    setuid: bool = false,

    // File type (upper 4 bits)
    file_type: u4 = 0,

    pub fn toMode(self: FileMode) u16 {
        var mode: u16 = 0;

        // Permissions
        if (self.other_execute) mode |= 0o001;
        if (self.other_write) mode |= 0o002;
        if (self.other_read) mode |= 0o004;
        if (self.group_execute) mode |= 0o010;
        if (self.group_write) mode |= 0o020;
        if (self.group_read) mode |= 0o040;
        if (self.owner_execute) mode |= 0o100;
        if (self.owner_write) mode |= 0o200;
        if (self.owner_read) mode |= 0o400;

        // Special bits
        if (self.sticky) mode |= 0o1000;
        if (self.setgid) mode |= 0o2000;
        if (self.setuid) mode |= 0o4000;

        // File type
        mode |= (@as(u16, self.file_type) << 12);

        return mode;
    }

    pub fn fromMode(mode: u16) FileMode {
        return FileMode{
            .other_execute = (mode & 0o001) != 0,
            .other_write = (mode & 0o002) != 0,
            .other_read = (mode & 0o004) != 0,
            .group_execute = (mode & 0o010) != 0,
            .group_write = (mode & 0o020) != 0,
            .group_read = (mode & 0o040) != 0,
            .owner_execute = (mode & 0o100) != 0,
            .owner_write = (mode & 0o200) != 0,
            .owner_read = (mode & 0o400) != 0,
            .sticky = (mode & 0o1000) != 0,
            .setgid = (mode & 0o2000) != 0,
            .setuid = (mode & 0o4000) != 0,
            .file_type = @truncate((mode & 0xF000) >> 12),
        };
    }
};

// VFS node statistics
pub const VfsStat = struct {
    st_dev: u64 = 0,        // Device ID
    st_ino: u64 = 0,        // Inode number
    st_mode: u16 = 0,       // File type and mode
    st_nlink: u32 = 1,      // Number of hard links
    st_uid: u32 = 0,        // User ID
    st_gid: u32 = 0,        // Group ID
    st_rdev: u64 = 0,       // Device ID (if special file)
    st_size: u64 = 0,       // Total size in bytes
    st_atime: u64 = 0,      // Time of last access
    st_mtime: u64 = 0,      // Time of last modification
    st_ctime: u64 = 0,      // Time of last status change
    st_blksize: u32 = 512,  // Block size for filesystem I/O
    st_blocks: u64 = 0,     // Number of 512B blocks allocated
};

// Directory entry for readdir
pub const VfsDirent = struct {
    d_ino: u64,             // Inode number
    d_type: u8,             // File type
    d_name: []const u8,     // File name

    pub const DT_UNKNOWN = 0;
    pub const DT_FIFO = 1;
    pub const DT_CHR = 2;
    pub const DT_DIR = 4;
    pub const DT_BLK = 6;
    pub const DT_REG = 8;
    pub const DT_LNK = 10;
    pub const DT_SOCK = 12;
};

// VFS errors
pub const VfsError = error{
    NotFound,
    PermissionDenied,
    IsDirectory,
    NotDirectory,
    InvalidArgument,
    TooManyLinks,
    FileExists,
    NoSpace,
    ReadOnlyFilesystem,
    NameTooLong,
    NotSupported,
    IoError,
    BadFileDescriptor,
    OutOfMemory,
};

// Forward declarations
pub const VfsNode = struct {
    // Node metadata
    name: []const u8,
    parent: ?*VfsNode,
    mount: *VfsMount,

    // Reference counting
    ref_count: u32 = 1,

    // File operations (callbacks)
    vtable: *const VfsNodeVTable,

    // Private data for filesystem implementation
    private_data: ?*anyopaque = null,

    const Self = @This();

    pub fn ref(self: *Self) void {
        self.ref_count += 1;
    }

    pub fn unref(self: *Self) void {
        if (self.ref_count > 0) {
            self.ref_count -= 1;
            if (self.ref_count == 0) {
                if (self.vtable.release) |release_fn| {
                    release_fn(self);
                }
            }
        }
    }
};

pub const VfsNodeVTable = struct {
    // Required operations
    stat: *const fn(node: *VfsNode, stat: *VfsStat) VfsError!void,

    // Optional operations (can be null)
    open: ?*const fn(node: *VfsNode, flags: u32) VfsError!void = null,
    read: ?*const fn(node: *VfsNode, offset: u64, buffer: []u8) VfsError!usize = null,
    write: ?*const fn(node: *VfsNode, offset: u64, buffer: []const u8) VfsError!usize = null,
    readdir: ?*const fn(node: *VfsNode, ctx: *ReaddirContext) VfsError!void = null,
    lookup: ?*const fn(node: *VfsNode, name: []const u8) VfsError!*VfsNode = null,
    release: ?*const fn(node: *VfsNode) void = null,
};

// Context for readdir operations
pub const ReaddirContext = struct {
    callback: *const fn(ctx: *ReaddirContext, dirent: *const VfsDirent) VfsError!void,
    user_data: ?*anyopaque = null,
    offset: u64 = 0,

    pub fn emit(self: *ReaddirContext, dirent: *const VfsDirent) VfsError!void {
        return self.callback(self, dirent);
    }
};

// File descriptor structure
pub const FileDescriptor = struct {
    fd: u32,
    node: *VfsNode,
    offset: u64 = 0,
    flags: u32 = 0,
    next: ?*FileDescriptor = null,

    // File descriptor flags
    pub const O_RDONLY = 0x0000;
    pub const O_WRONLY = 0x0001;
    pub const O_RDWR = 0x0002;
    pub const O_CREAT = 0x0040;
    pub const O_EXCL = 0x0080;
    pub const O_TRUNC = 0x0200;
    pub const O_APPEND = 0x0400;
    pub const O_DIRECTORY = 0x10000;

    const Self = @This();

    pub fn canRead(self: *const Self) bool {
        return (self.flags & O_WRONLY) == 0;
    }

    pub fn canWrite(self: *const Self) bool {
        return (self.flags & (O_WRONLY | O_RDWR)) != 0;
    }
};

// Mount point structure
pub const VfsMount = struct {
    mountpoint: []const u8,
    root_node: *VfsNode,
    filesystem_type: []const u8,
    next: ?*VfsMount = null,

    // Mount flags
    read_only: bool = false,
    no_exec: bool = false,
    no_suid: bool = false,
};

// Per-thread file descriptor table
pub const FdTable = struct {
    fds: [256]?*FileDescriptor = [_]?*FileDescriptor{null} ** 256,
    next_fd: u32 = 0,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.fds) |maybe_fd| {
            if (maybe_fd) |fd| {
                fd.node.unref();
                self.allocator.destroy(fd);
            }
        }
    }

    pub fn allocateFd(self: *Self, node: *VfsNode, flags: u32) VfsError!u32 {
        // Find free file descriptor
        var fd_num: u32 = self.next_fd;
        var attempts: u32 = 0;

        while (attempts < 256) : (attempts += 1) {
            if (self.fds[fd_num] == null) {
                // Create new file descriptor
                const fd = self.allocator.create(FileDescriptor) catch {
                    return VfsError.OutOfMemory;
                };

                fd.* = FileDescriptor{
                    .fd = fd_num,
                    .node = node,
                    .flags = flags,
                };

                node.ref();
                self.fds[fd_num] = fd;
                self.next_fd = (fd_num + 1) % 256;

                return fd_num;
            }

            fd_num = (fd_num + 1) % 256;
        }

        return VfsError.OutOfMemory;
    }

    pub fn getFd(self: *Self, fd_num: u32) ?*FileDescriptor {
        if (fd_num >= 256) return null;
        return self.fds[fd_num];
    }

    pub fn closeFd(self: *Self, fd_num: u32) VfsError!void {
        if (fd_num >= 256) return VfsError.BadFileDescriptor;

        if (self.fds[fd_num]) |fd| {
            fd.node.unref();
            self.allocator.destroy(fd);
            self.fds[fd_num] = null;
        } else {
            return VfsError.BadFileDescriptor;
        }
    }
};

// Global VFS context
pub const VfsContext = struct {
    root_node: ?*VfsNode = null,
    mounts: ?*VfsMount = null,
    allocator: std.mem.Allocator,
    mutex: kernel.mutex.Mutex = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn mount(self: *Self, mountpoint: []const u8, root_node: *VfsNode, fs_type: []const u8) VfsError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        log.info("Mounting {s} filesystem at {s}", .{ fs_type, mountpoint });

        const mount_l = self.allocator.create(VfsMount) catch {
            return VfsError.OutOfMemory;
        };

        const mountpoint_copy = self.allocator.dupe(u8, mountpoint) catch {
            self.allocator.destroy(mount_l);
            return VfsError.OutOfMemory;
        };

        const fs_type_copy = self.allocator.dupe(u8, fs_type) catch {
            self.allocator.free(mountpoint_copy);
            self.allocator.destroy(mount_l);
            return VfsError.OutOfMemory;
        };

        mount_l.* = VfsMount{
            .mountpoint = mountpoint_copy,
            .root_node = root_node,
            .filesystem_type = fs_type_copy,
            .next = self.mounts,
        };

        root_node.mount = mount_l;
        self.mounts = mount_l;

        // If this is the root mount, set it as root
        if (std.mem.eql(u8, mountpoint, "/")) {
            self.root_node = root_node;
            log.info("Set root filesystem", .{});
        }

        log.info("Mount successful", .{});
    }

    pub fn resolvePath(self: *Self, path: []const u8) VfsError!*VfsNode {
        if (self.root_node == null) {
            log.err("VFS root node not initialized", .{});
            return VfsError.NotFound;
        }

        if (path.len == 0 or path[0] != '/') {
            return VfsError.InvalidArgument;
        }

        var current = self.root_node.?;
        current.ref();

        if (path.len == 1) {
            return current; // Root directory
        }

        var path_iter = std.mem.splitAny(u8, path[1..], "/");
        while (path_iter.next()) |component| {
            if (component.len == 0) continue; // Skip empty components

            // Check if current node supports lookup
            if (current.vtable.lookup == null) {
                current.unref();
                return VfsError.NotDirectory;
            }

            const next_node = current.vtable.lookup.?(current, component) catch |err| {
                current.unref();
                return err;
            };

            current.unref();
            current = next_node;
        }

        return current;
    }
};

// Global VFS instance
var vfs_context: ?VfsContext = null;

// Initialize VFS
pub fn init(allocator: std.mem.Allocator) void {
    vfs_context = VfsContext.init(allocator);
    log.info("VFS initialized", .{});
}

// Mount a filesystem
pub fn mount(mountpoint: []const u8, root_node: *VfsNode, fs_type: []const u8) VfsError!void {
    if (vfs_context == null) {
        return VfsError.NotSupported;
    }

    return vfs_context.?.mount(mountpoint, root_node, fs_type);
}

// VFS system calls

pub fn vfs_open(path: []const u8, flags: u32) VfsError!u32 {
    const current_thread = thread.getCurrentThread() orelse {
        return VfsError.NotSupported;
    };

    if (vfs_context == null) {
        return VfsError.NotSupported;
    }

    log.debug("Opening path: {s}, flags: 0x{X}", .{ path, flags });

    const node = vfs_context.?.resolvePath(path) catch |err| {
        log.debug("Path resolution failed: {}", .{err});
        return err;
    };
    defer node.unref();

    // Check if we're trying to open a directory without O_DIRECTORY
    var stat: VfsStat = undefined;
    node.vtable.stat(node, &stat) catch |err| {
        return err;
    };

    const is_directory = (stat.st_mode & FileType.DIR.toMode()) != 0;
    if (is_directory and (flags & FileDescriptor.O_DIRECTORY) == 0) {
        return VfsError.IsDirectory;
    }

    if (!is_directory and (flags & FileDescriptor.O_DIRECTORY) != 0) {
        return VfsError.NotDirectory;
    }

    // Call node's open function if available
    if (node.vtable.open) |open_fn| {
        open_fn(node, flags) catch |err| {
            return err;
        };
    }

    // Allocate file descriptor
    const fd = current_thread.fd_table.allocateFd(node, flags) catch |err| {
        return err;
    };

    log.debug("Opened {s} as fd {}", .{ path, fd });
    return fd;
}

pub fn vfs_read(fd: u32, buffer: []u8) VfsError!usize {
    const current_thread = thread.getCurrentThread() orelse {
        return VfsError.NotSupported;
    };

    const file_desc = current_thread.fd_table.getFd(fd) orelse {
        return VfsError.BadFileDescriptor;
    };

    if (!file_desc.canRead()) {
        return VfsError.PermissionDenied;
    }

    if (file_desc.node.vtable.read == null) {
        return VfsError.NotSupported;
    }

    const bytes_read = file_desc.node.vtable.read.?(
        file_desc.node,
        file_desc.offset,
        buffer
    ) catch |err| {
        return err;
    };

    file_desc.offset += bytes_read;
    return bytes_read;
}

pub fn vfs_lseek(fd: u32, offset: i64, whence: u32) VfsError!u64 {
    const current_thread = thread.getCurrentThread() orelse {
        return VfsError.NotSupported;
    };

    const file_desc = current_thread.fd_table.getFd(fd) orelse {
        return VfsError.BadFileDescriptor;
    };

    // Get file size for SEEK_END
    var stat: VfsStat = undefined;
    file_desc.node.vtable.stat(file_desc.node, &stat) catch |err| {
        return err;
    };

    const SEEK_SET = 0;
    const SEEK_CUR = 1;
    const SEEK_END = 2;

    const new_offset: u64 = switch (whence) {
        SEEK_SET => @intCast(@max(0, offset)),
        SEEK_CUR => @intCast(@max(0, @as(i64, @intCast(file_desc.offset)) + offset)),
        SEEK_END => @intCast(@max(0, @as(i64, @intCast(stat.st_size)) + offset)),
        else => return VfsError.InvalidArgument,
    };

    file_desc.offset = new_offset;
    return new_offset;
}

pub fn vfs_close(fd: u32) VfsError!void {
    const current_thread = thread.getCurrentThread() orelse {
        return VfsError.NotSupported;
    };

    return current_thread.fd_table.closeFd(fd);
}

pub fn vfs_stat(path: []const u8, stat: *VfsStat) VfsError!void {
    if (vfs_context == null) {
        return VfsError.NotSupported;
    }

    const node = vfs_context.?.resolvePath(path) catch |err| {
        return err;
    };
    defer node.unref();

    return node.vtable.stat(node, stat);
}

pub fn vfs_readdir(fd: u32, callback: *const fn(dirent: *const VfsDirent, user_data: ?*anyopaque) VfsError!void, user_data: ?*anyopaque) VfsError!void {
    const current_thread = thread.getCurrentThread() orelse {
        return VfsError.NotSupported;
    };

    const file_desc = current_thread.fd_table.getFd(fd) orelse {
        return VfsError.BadFileDescriptor;
    };

    if (file_desc.node.vtable.readdir == null) {
        return VfsError.NotDirectory;
    }

    // Helper function for callback conversion
    const CallbackWrapper = struct {
        original_callback: *const fn(dirent: *const VfsDirent, user_data: ?*anyopaque) VfsError!void,
        original_user_data: ?*anyopaque,

        fn readdirCallback(ctx: *ReaddirContext, dirent: *const VfsDirent) VfsError!void {
            const wrapper: *@This() = @ptrCast(@alignCast(ctx.user_data.?));
            return wrapper.original_callback(dirent, wrapper.original_user_data);
        }
    };

    var wrapper = CallbackWrapper{
        .original_callback = callback,
        .original_user_data = user_data,
    };

    var readdir_ctx = ReaddirContext{
        .callback = CallbackWrapper.readdirCallback,
        .user_data = &wrapper,
        .offset = file_desc.offset,
    };

    return file_desc.node.vtable.readdir.?(file_desc.node, &readdir_ctx);
}

// Helper functions for filesystem implementations

pub fn createNode(allocator: std.mem.Allocator, name: []const u8, vtable: *const VfsNodeVTable) VfsError!*VfsNode {
    const node = allocator.create(VfsNode) catch {
        return VfsError.OutOfMemory;
    };

    const name_copy = allocator.dupe(u8, name) catch {
        allocator.destroy(node);
        return VfsError.OutOfMemory;
    };

    node.* = VfsNode{
        .name = name_copy,
        .parent = null,
        .mount = undefined, // Will be set when mounted
        .vtable = vtable,
    };

    return node;
}

pub fn destroyNode(allocator: std.mem.Allocator, node: *VfsNode) void {
    allocator.free(node.name);
    allocator.destroy(node);
}

// Test function
pub fn test_vfs() !void {
    log.info("Starting VFS tests", .{});

    // TODO: Add basic VFS tests here
    log.info("VFS tests completed", .{});
}
