const std = @import("std");
const drivers = @import("drivers");
const block_device = drivers.block_device;
const DataSlice = block_device.DataSlice;
const log = std.log.scoped(.ext2);
const kernel = @import("kernel.zig");
const mbr = @import("mbr.zig");

// NOTE @(dleiferives,10ea4a48-2dbc-408a-b30a-d09b0a423f7f): first good inode for
// files is first_ino ~#

pub const EXT2_MAGIC: u16 = 0xEF53;
pub const EXT2_BAD_INODE: u32 = 0x0001;
pub const EXT2_ROOT_INODE: u32 = 0x0002;
pub const EXT2_ACL_IDX_INODE: u32 = 0x0003;
pub const EXT2_ACL_DATA_INODE: u32 = 0x0004;
pub const EXT2_BOOT_LOADER_INODE: u32 = 0x0005;
pub const EXT2_UNDEL_DIR_INODE: u32 = 0x0006;
pub const EXT2_BLOCK_GROUP_DESC_SIZE: u64 = 32;

pub const superblock = struct {
    inodes_count: u32,
    blocks_count: u32,
    reserved_blocks_count: u32,
    free_blocks_count: u32,
    free_inodes_count: u32,
    first_data_block: u32,
    log_block_size: u32,
    log_frag_size: i32,
    blocks_per_group: u32,
    frags_per_group: u32,
    inodes_per_group: u32,
    last_mount_time: u32, // last mount time
    last_write_time: u32, // last write time
    mnt_count: u16, // mount count
    max_mnt_count: u16, // max mount count
    magic: u16, // magic signature
    state: u16, // state of the filesystem
    errors: u16, // behaviour when detecting errors
    minor_rev_level: u16, // minor revision level
    lastcheck: u32, // time of last check
    checkinterval: u32, // max time between checks
    creator_os: u32, // OS that created the filesystem
    rev_level: u32, // revision level
    def_resuid: u16, // default uid for reserved blocks
    def_resgid: u16, // default gid for reserved blocks
    // ext2_dynamic rev specific fields
    first_ino: u32, // first non-reserved inode
    inode_size: u16, // size of inode structure
    block_group_nr: u16, // block group number
    feature_compat: u32, // compatible features
    feature_incompat: u32, // incompatible features
    feature_ro_compat: u32, // read-only compatible features
    uuid: [16]u8, // 128-bit UUID
    volume_name: [16]u8, // volume name
    last_mounted: [64]u8, // last mounted directory
    algo_bitmap: u32, // compression algorithms
    // performance hints
    prealloc_blocks: u8, // number of blocks to preallocate
    prealloc_dir_blocks: u8, // number of blocks to preallocate for directories
    align_1: u16, // alignment spacing
    // journaling support
    journal_uuid: [16]u8, // UUID of the journal
    journal_inum: u32, // inode number of the journal file
    journal_dev: u32, // device number of the journal
    last_orphan: u32, // head of the orphan inode list
    // directory indexing support
    hash_seed: [4]u32, // hash seed for directory indexing
    def_hash_version: u8, // default hash version
    reserved_direcotry: [3]u8, // reserved for future use
    // other options
    default_mount_opts: u32, // default mount options
    first_meta_bg: u32, // first meta block group
    // reserved for future use
    reserved: [760]u8, // reserved for future use

    // computed fields
    block_size: u64,
    frag_size: u64,
    num_block_groups: u64,

    pub inline fn isValid(self: @This()) bool {
        if (self.magic != EXT2_MAGIC) {
            return false; // Magic number must be 0xEF53 for ext2/3/4
        }
        return true;
    }

    pub fn hasVolumeName(self: @This(), expected: []const u8) bool {
        const end = std.mem.indexOfScalar(u8, &self.volume_name, 0) orelse
            self.volume_name.len;
        return std.mem.eql(u8, self.volume_name[0..end], expected);
    }

    pub fn fromBytes(bytes: []const u8) superblock {
        if (bytes.len < 1024) {
            @panic("Superblock bytes must be at least 1024 bytes long");
        }

        // do manual coputations
        const log_block_size = @as(u32, std.mem.bytesToValue(u32, bytes[24..28]));
        const block_size = @as(u64, @as(u64, 1024) << @truncate(log_block_size));
        const log_frag_size = @as(i32, std.mem.bytesToValue(i32, bytes[28..32]));
        var log_frag_size_fixed: u32 = 0;
        var frag_size: u64 = 0;
        if (log_frag_size < 0) {
            log_frag_size_fixed = @as(u32, @intCast(-log_frag_size));
            frag_size = @as(u64, 1024) >> @truncate(log_frag_size_fixed);
        } else {
            log_frag_size_fixed = @as(u32, @intCast(log_frag_size));
            frag_size = @as(u64, 1024) << @truncate(log_frag_size_fixed);
        }
        const inodes_count = @as(u32, std.mem.bytesToValue(u32, bytes[0..4]));
        const blocks_count = @as(u32, std.mem.bytesToValue(u32, bytes[4..8]));
        const inodes_per_group = @as(u32, std.mem.bytesToValue(u32, bytes[40..44]));
        const blocks_per_group = @as(u32, std.mem.bytesToValue(u32, bytes[32..36]));
        const block_groups = if (blocks_per_group == 0) 1 else 1 + ((@as(u64, blocks_count) - 1) / @as(u64, blocks_per_group));
        const inode_groups = if (inodes_per_group == 0) 1 else 1 + ((@as(u64, inodes_count) - 1) / @as(u64, inodes_per_group));
        const num_block_groups = @max(block_groups, inode_groups);

        return superblock{
            // computed fields
            .block_size = block_size,
            .frag_size = frag_size,
            .num_block_groups = num_block_groups,

            // regular
            .inodes_count = @as(u32, std.mem.bytesToValue(u32, bytes[0..4])),
            .blocks_count = @as(u32, std.mem.bytesToValue(u32, bytes[4..8])),
            .reserved_blocks_count = @as(u32, std.mem.bytesToValue(u32, bytes[8..12])),
            .free_blocks_count = @as(u32, std.mem.bytesToValue(u32, bytes[12..16])),
            .free_inodes_count = @as(u32, std.mem.bytesToValue(u32, bytes[16..20])),
            .first_data_block = @as(u32, std.mem.bytesToValue(u32, bytes[20..24])),
            .log_block_size = log_block_size,
            .log_frag_size = log_frag_size,
            .blocks_per_group = @as(u32, std.mem.bytesToValue(u32, bytes[32..36])),
            .frags_per_group = @as(u32, std.mem.bytesToValue(u32, bytes[36..40])),
            .inodes_per_group = @as(u32, std.mem.bytesToValue(u32, bytes[40..44])),
            .last_mount_time = @as(u32, std.mem.bytesToValue(u32, bytes[44..48])),
            .last_write_time = @as(u32, std.mem.bytesToValue(u32, bytes[48..52])),
            .mnt_count = @as(u16, std.mem.bytesToValue(u16, bytes[52..54])),
            .max_mnt_count = @as(u16, std.mem.bytesToValue(u16, bytes[54..56])),
            .magic = @as(u16, std.mem.bytesToValue(u16, bytes[56..58])),
            .state = @as(u16, std.mem.bytesToValue(u16, bytes[58..60])),
            .errors = @as(u16, std.mem.bytesToValue(u16, bytes[60..62])),
            .minor_rev_level = @as(u16, std.mem.bytesToValue(u16, bytes[62..64])),
            .lastcheck = @as(u32, std.mem.bytesToValue(u32, bytes[64..68])),
            .checkinterval = @as(u32, std.mem.bytesToValue(u32, bytes[68..72])),
            .creator_os = @as(u32, std.mem.bytesToValue(u32, bytes[72..76])),
            .rev_level = @as(u32, std.mem.bytesToValue(u32, bytes[76..80])),
            .def_resuid = @as(u16, std.mem.bytesToValue(u16, bytes[80..82])),
            .def_resgid = @as(u16, std.mem.bytesToValue(u16, bytes[82..84])),
            .first_ino = @as(u32, std.mem.bytesToValue(u32, bytes[84..88])),
            .inode_size = @as(u16, std.mem.bytesToValue(u16, bytes[88..90])),
            .block_group_nr = @as(u16, std.mem.bytesToValue(u16, bytes[90..92])),
            .feature_compat = @as(u32, std.mem.bytesToValue(u32, bytes[92..96])),
            .feature_incompat = @as(u32, std.mem.bytesToValue(u32, bytes[96..100])),
            .feature_ro_compat = @as(u32, std.mem.bytesToValue(u32, bytes[100..104])),
            .uuid = bytes[104..120].*,
            .volume_name = bytes[120..136].*,
            .last_mounted = bytes[136..200].*,
            .algo_bitmap = @as(u32, std.mem.bytesToValue(u32, bytes[200..204])),
            .prealloc_blocks = bytes[204],
            .prealloc_dir_blocks = bytes[205],
            .align_1 = @as(u16, std.mem.bytesToValue(u16, bytes[206..208])),
            .journal_uuid = bytes[208..224].*,
            .journal_inum = @as(u32, std.mem.bytesToValue(u32, bytes[224..228])),
            .journal_dev = @as(u32, std.mem.bytesToValue(u32, bytes[228..232])),
            .last_orphan = @as(u32, std.mem.bytesToValue(u32, bytes[232..236])),
            .hash_seed = [_]u32{
                @as(u32, std.mem.bytesToValue(u32, bytes[236..240])),
                @as(u32, std.mem.bytesToValue(u32, bytes[240..244])),
                @as(u32, std.mem.bytesToValue(u32, bytes[244..248])),
                @as(u32, std.mem.bytesToValue(u32, bytes[248..252])),
            },
            .def_hash_version = bytes[252],
            .reserved_direcotry = bytes[253..256].*,
            .default_mount_opts = @as(u32, std.mem.bytesToValue(u32, bytes[256..260])),
            .first_meta_bg = @as(u32, std.mem.bytesToValue(u32, bytes[260..264])),
            .reserved = bytes[264..1024].*,
        };
    }
};

pub const block_group_desc = struct {
    block_bitmap: u32, // block bitmap block number
    inode_bitmap: u32, // inode bitmap block number
    inode_table: u32, // inode table block number
    free_blocks_count: u16, // free blocks count in this group
    free_inodes_count: u16, // free inodes count in this group
    used_dirs_count: u16, // used directories count in this group
    padding: u16, // block group padding
    reserved: [12]u8, // reserved for future use

    pub fn fromBytes(bytes: []const u8) block_group_desc {
        if (bytes.len < 32) {
            @panic("Block group descriptor bytes must be at least 32 bytes long");
        }
        return block_group_desc{
            .block_bitmap = @as(u32, std.mem.bytesToValue(u32, bytes[0..4])),
            .inode_bitmap = @as(u32, std.mem.bytesToValue(u32, bytes[4..8])),
            .inode_table = @as(u32, std.mem.bytesToValue(u32, bytes[8..12])),
            .free_blocks_count = @as(u16, std.mem.bytesToValue(u16, bytes[12..14])),
            .free_inodes_count = @as(u16, std.mem.bytesToValue(u16, bytes[14..16])),
            .used_dirs_count = @as(u16, std.mem.bytesToValue(u16, bytes[16..18])),
            .padding = @as(u16, std.mem.bytesToValue(u16, bytes[18..20])),
            .reserved = bytes[20..32].*,
        };
    }
};

pub const inode_table_entry = struct {
    mode: inode_mode, // file mode (type and permissions)
    uid: u16, // owner user ID
    size: u32, // size in bytes
    atime: u32, // last access time
    ctime: u32, // last inode change time
    mtime: u32, // last data modification time
    dtime: u32, // deletion time
    gid: u16, // owner group ID
    links_count: u16, // number of hard links
    blocks_count: u32, // number of blocks allocated to the file (in 512 byte units...)
    flags: inode_flags, // file flags
    osd1: [4]u8, // OS-specific data
    blocks: [12]u32, // block pointers (direct and indirect)
    indirect_blocks: u32, // single indirect block pointer
    double_indirect_blocks: u32, // double indirect block pointer
    triple_indirect_blocks: u32, // triple indirect block pointer
    generation: u32, // file version (generation number)
    file_acl: u32, // file ACL (access control list)
    dir_acl: u32, // directory ACL
    faddr: u32, // fragment address
    osd2: [12]u8, // more OS-specific data

    pub fn fromBytes(bytes: []const u8) inode_table_entry {
        if (bytes.len < 128) {
            @panic("Inode table entry bytes must be at least 128 bytes long");
        }
        return inode_table_entry{
            .mode = inode_mode.fromValue(@as(u16, std.mem.bytesToValue(u16, bytes[0..2]))),
            .uid = @as(u16, std.mem.bytesToValue(u16, bytes[2..4])),
            .size = @as(u32, std.mem.bytesToValue(u32, bytes[4..8])),
            .atime = @as(u32, std.mem.bytesToValue(u32, bytes[8..12])),
            .ctime = @as(u32, std.mem.bytesToValue(u32, bytes[12..16])),
            .mtime = @as(u32, std.mem.bytesToValue(u32, bytes[16..20])),
            .dtime = @as(u32, std.mem.bytesToValue(u32, bytes[20..24])),
            .gid = @as(u16, std.mem.bytesToValue(u16, bytes[24..26])),
            .links_count = @as(u16, std.mem.bytesToValue(u16, bytes[26..28])),
            .blocks_count = @as(u32, std.mem.bytesToValue(u32, bytes[28..32])),
            .flags = inode_flags.fromValue(@as(u32, std.mem.bytesToValue(u32, bytes[32..36]))),
            .osd1 = bytes[36..40].*,
            .blocks = [_]u32{
                @as(u32, std.mem.bytesToValue(u32, bytes[40..44])),
                @as(u32, std.mem.bytesToValue(u32, bytes[44..48])),
                @as(u32, std.mem.bytesToValue(u32, bytes[48..52])),
                @as(u32, std.mem.bytesToValue(u32, bytes[52..56])),
                @as(u32, std.mem.bytesToValue(u32, bytes[56..60])),
                @as(u32, std.mem.bytesToValue(u32, bytes[60..64])),
                @as(u32, std.mem.bytesToValue(u32, bytes[64..68])),
                @as(u32, std.mem.bytesToValue(u32, bytes[68..72])),
                @as(u32, std.mem.bytesToValue(u32, bytes[72..76])),
                @as(u32, std.mem.bytesToValue(u32, bytes[76..80])),
                @as(u32, std.mem.bytesToValue(u32, bytes[80..84])),
                @as(u32, std.mem.bytesToValue(u32, bytes[84..88])),
            },
            .indirect_blocks = @as(u32, std.mem.bytesToValue(u32, bytes[88..92])),
            .double_indirect_blocks = @as(u32, std.mem.bytesToValue(u32, bytes[92..96])),
            .triple_indirect_blocks = @as(u32, std.mem.bytesToValue(u32, bytes[96..100])),
            .generation = @as(u32, std.mem.bytesToValue(u32, bytes[100..104])),
            .file_acl = @as(u32, std.mem.bytesToValue(u32, bytes[104..108])),
            .dir_acl = @as(u32, std.mem.bytesToValue(u32, bytes[108..112])),
            .faddr = @as(u32, std.mem.bytesToValue(u32, bytes[112..116])),
            .osd2 = bytes[116..128].*,
        };
    }
};

pub const inode_mode = struct {
    socket: bool = false,
    symlink: bool = false,
    regular: bool = false,
    block_device: bool = false,
    directory: bool = false,
    char_device: bool = false,
    fifo: bool = false,
    set_uid: bool = false,
    set_gid: bool = false,
    sticky_bit: bool = false,
    user_read: bool = false,
    user_write: bool = false,
    user_execute: bool = false,
    group_read: bool = false,
    group_write: bool = false,
    group_execute: bool = false,
    others_read: bool = false,
    others_write: bool = false,
    others_execute: bool = false,

    pub fn fromValue(value: u16) inode_mode {
        return inode_mode{
            .socket = (value & 0xC000) == 0xC000,
            .symlink = (value & 0xA000) == 0xA000,
            .regular = (value & 0x8000) == 0x8000,
            .block_device = (value & 0x6000) == 0x6000,
            .directory = (value & 0x4000) == 0x4000,
            .char_device = (value & 0x2000) == 0x2000,
            .fifo = (value & 0x1000) == 0x1000,
            .set_uid = (value & 0x0800) != 0,
            .set_gid = (value & 0x0400) != 0,
            .sticky_bit = (value & 0x0200) != 0,
            .user_read = (value & 0x0100) != 0,
            .user_write = (value & 0x0080) != 0,
            .user_execute = (value & 0x0040) != 0,
            .group_read = (value & 0x0020) != 0,
            .group_write = (value & 0x0010) != 0,
            .group_execute = (value & 0x0008) != 0,
            .others_read = (value & 0x0004) != 0,
            .others_write = (value & 0x0002) != 0,
            .others_execute = (value & 0x0001) != 0,
        };
    }

    pub fn toValue(self: inode_mode) u16 {
        var value: u16 = 0;
        if (self.socket) value |= 0xC000;
        if (self.symlink) value |= 0xA000;
        if (self.regular) value |= 0x8000;
        if (self.block_device) value |= 0x6000;
        if (self.directory) value |= 0x4000;
        if (self.char_device) value |= 0x2000;
        if (self.fifo) value |= 0x1000;
        if (self.set_uid) value |= 0x0800;
        if (self.set_gid) value |= 0x0400;
        if (self.sticky_bit) value |= 0x0200;
        if (self.user_read) value |= 0x0100;
        if (self.user_write) value |= 0x0080;
        if (self.user_execute) value |= 0x0040;
        if (self.group_read) value |= 0x0020;
        if (self.group_write) value |= 0x0010;
        if (self.group_execute) value |= 0x0008;
        if (self.others_read) value |= 0x0004;
        if (self.others_write) value |= 0x0002;
        if (self.others_execute) value |= 0x0001;

        return value;
    }
};

pub const inode_flags = struct {
    secure_deletion: bool = false,
    undelete: bool = false,
    compressed: bool = false,
    synchronous_updates: bool = false,
    immutable: bool = false,
    append_only: bool = false,
    no_dump: bool = false,
    no_atime_update: bool = false,
    dirty: bool = false,
    compressed_blocks: bool = false,
    no_compression: bool = false,
    compression_error: bool = false,
    btree_format_directory: bool = false,
    index_format_directory: bool = false,
    afs_directory: bool = false,
    journal_file_data: bool = false,
    reserved_for_ext2_library: bool = false,

    pub fn fromValue(value: u32) inode_flags {
        return inode_flags{
            .secure_deletion = (value & 0x00000001) != 0,
            .undelete = (value & 0x00000002) != 0,
            .compressed = (value & 0x00000004) != 0,
            .synchronous_updates = (value & 0x00000008) != 0,
            .immutable = (value & 0x00000010) != 0,
            .append_only = (value & 0x00000020) != 0,
            .no_dump = (value & 0x00000040) != 0,
            .no_atime_update = (value & 0x00000080) != 0,
            .dirty = (value & 0x00000100) != 0,
            .compressed_blocks = (value & 0x00000200) != 0,
            .no_compression = (value & 0x00000400) != 0,
            .compression_error = (value & 0x00000800) != 0,
            .btree_format_directory = (value & 0x00001000) == 0,
            .index_format_directory = (value & 0x00001000) != 0, // index is used when bit is set
            .afs_directory = (value & 0x00002000) != 0,
            .journal_file_data = (value & 0x00004000) != 0,
            .reserved_for_ext2_library = (value & 0x80000000) != 0,
        };
    }

    pub fn toValue(self: inode_flags) u32 {
        var value: u32 = 0;
        if (self.secure_deletion) value |= 0x00000001;
        if (self.undelete) value |= 0x00000002;
        if (self.compressed) value |= 0x00000004;
        if (self.synchronous_updates) value |= 0x00000008;
        if (self.immutable) value |= 0x00000010;
        if (self.append_only) value |= 0x00000020;
        if (self.no_dump) value |= 0x00000040;
        if (self.no_atime_update) value |= 0x00000080;
        if (self.dirty) value |= 0x00000100;
        if (self.compressed_blocks) value |= 0x00000200;
        if (self.no_compression) value |= 0x00000400;
        if (self.compression_error) value |= 0x00000800;
        if (self.index_format_directory) value |= 0x00001000;
        if (self.index_format_directory == self.btree_format_directory) @panic("index_format_directory and btree_format_directory cannot be the same");
        if (self.afs_directory) value |= 0x00002000;
        if (self.journal_file_data) value |= 0x00004000;
        if (self.reserved_for_ext2_library) value |= 0x80000000;

        return value;
    }
};

pub const directory_entry = struct {
    inode: u32, // inode number
    rec_len: u16, // length of this record
    name_len: u8, // length of the name
    file_type: FileType, // type of the file
    name_data: [256]u8, // name of the file

    // TODO @(dleiferives,14e48c4e-c43f-46a7-93b7-0ab669d93437): The directory
    // entries must be aligned on 4 bytes boundaries and there cannot be any
    // directory entry spanning multiple data blocks. If an entry cannot
    // completely fit in one block, it must be pushed to the next data block and
    // the rec_len of the previous entry properly adjusted. ~#
    pub fn fromBytes(bytes: []const u8) directory_entry {
        if (bytes.len < 8) {
            @panic("Directory entry bytes must be at least 8 bytes long");
        }
        var directory_entry_l = directory_entry{
            .inode = 0,
            .rec_len = 0,
            .name_len = 0,
            .file_type = undefined,
            .name_data = undefined, // initialize with zeros
        };
        directory_entry_l.inode = @as(u32, std.mem.bytesToValue(u32, bytes[0..4]));
        directory_entry_l.rec_len = @as(u16, std.mem.bytesToValue(u16, bytes[4..6]));
        if (directory_entry_l.rec_len < 8) {
            @panic("Directory entry record length must be at least 8 bytes");
        }
        directory_entry_l.name_len = bytes[6];
        directory_entry_l.file_type = FileType.fromValue(bytes[7]);

        @memcpy(directory_entry_l.name_data[0..directory_entry_l.name_len], bytes[8 .. 8 + directory_entry_l.name_len]);
        return directory_entry_l;
    }
    pub inline fn getName(self: *const directory_entry) []const u8 {
        // return the name data as a slice
        return self.name_data[0..self.name_len];
    }
};

pub const FileType = enum(u8) {
    unknown = 0, // unknown file type
    regular = 1, // regular file
    directory = 2, // directory
    character_device = 3, // character device
    block_device = 4, // block device
    fifo = 5, // FIFO (named pipe)
    socket = 6, // socket
    symlink = 7, // symbolic link

    pub inline fn fromValue(value: u8) FileType {
        return switch (value) {
            0 => .unknown,
            1 => .regular,
            2 => .directory,
            3 => .character_device,
            4 => .block_device,
            5 => .fifo,
            6 => .socket,
            7 => .symlink,
            else => @panic("Invalid file type value"),
        };
    }

    pub inline fn toValue(self: FileType) u8 {
        return switch (self) {
            .unknown => 0,
            .regular => 1,
            .directory => 2,
            .character_device => 3,
            .block_device => 4,
            .fifo => 5,
            .socket => 6,
            .symlink => 7,
        };
    }
};

pub const Ex2Error = error{
    InvalidArgument,
    InvalidFilesystem,
    InodeNotFound,
    InodeNotInAnyGroup,
    NotFound,
    OutOfMemory,
    IoError,
};

pub const Ex2Filesystem = struct {
    dev: *block_device.BlockDev,
    /// The partition entry for this filesystem
    /// Note that this is the mbr partition entry.
    /// note that this is allocated as a copy of the mbr partition entry,
    /// not a reference to the original entry.
    partition_entry: mbr.partition_table_entry,

    /// The allocator used for this filesystem.
    allocator: std.mem.Allocator,

    /// Block group descriptors for this filesystem.
    /// This is allocated with the allocator for the filesystem as a copy of the read bytes.
    superblock: superblock,
    first_data_block_addr: usize,
    first_block_addr: usize,

    /// Slice of the block groups.
    /// this is computed from the superblock
    block_groups: []block_group_desc,

    // Block Cache!
    cache: kernel.cache.Cache(u64, DataSlice, &DataSlice.destroy),

    pub const Self = @This();

    /// Will return null if the filesystem is not a valid ext2 filesystem.
    pub fn init(
        dev: *block_device.BlockDev,
        partition_entry: mbr.partition_table_entry,
        allocator: std.mem.Allocator,
    ) !?*Ex2Filesystem {
        kernel.hardwareBootStatus("ext2: allocating filesystem state at LBA {}", .{partition_entry.lba_first_absolute});
        var self = try allocator.create(Ex2Filesystem);
        kernel.hardwareBootStatus("ext2: filesystem state allocated at LBA {}", .{partition_entry.lba_first_absolute});
        self.* = Ex2Filesystem{
            .dev = dev,
            .superblock = undefined,
            .partition_entry = partition_entry,
            .allocator = allocator,
            // Invalid/non-ext2 partitions return before block-group metadata is
            // allocated. Keep teardown safe while probing mixed GPT disks.
            .block_groups = &.{},
            .first_data_block_addr = undefined,
            .first_block_addr = undefined,
            .cache = kernel.cache.Cache(u64, DataSlice, &DataSlice.destroy).init(allocator, 64),
        };
        kernel.hardwareBootStatus("ext2: filesystem state initialized at LBA {}", .{partition_entry.lba_first_absolute});
        errdefer self.deinit();

        // Read the superblock
        if (!try self.readSuperblock()) {
            self.deinit();
            return null;
        }

        try self.readBlockGroups();

        return self;
    }

    fn readSuperblock(self: *Self) !bool {
        const addr_start = self.partition_entry.lba_first_absolute * self.dev.blk_size;
        const offset = 1024; // superblock offset is 1024 bytes
        const size = 1024; // Superblock size is 1024 bytes
        kernel.hardwareBootStatus("ext2: reading superblock at LBA {}", .{self.partition_entry.lba_first_absolute});
        var superblock_slice = try self.dev.createDataSlice(self.allocator, addr_start + offset, size); //addr_start + offset + size);

        defer superblock_slice.free();
        const sb = superblock.fromBytes(superblock_slice.data);
        // printStruct(drivers.block_device.DataSlice, superblock_slice);
        // printStruct(superblock, sb);
        if (!sb.isValid()) {
            kernel.hardwareBootStatus("ext2: no superblock at LBA {}", .{self.partition_entry.lba_first_absolute});
            return false;
        }

        self.superblock = sb;
        self.first_data_block_addr = (self.partition_entry.lba_first_absolute * self.dev.blk_size) + (self.superblock.block_size * self.superblock.first_data_block);
        self.first_block_addr = self.partition_entry.lba_first_absolute * self.dev.blk_size;
        return true;
    }

    /// Must be run after reading the superblock.
    /// must be deallocated after use
    fn readBlockGroups(self: *Self) !void {
        log.info("reading block groups for device: {*}", .{self.dev});
        kernel.hardwareBootStatus("ext2: reading {} block groups at LBA {}", .{
            self.superblock.num_block_groups,
            self.partition_entry.lba_first_absolute,
        });
        var block_groups_slice = try self.dev.createDataSlice(self.allocator, self.first_data_block_addr + self.superblock.block_size, @intCast(self.superblock.num_block_groups * EXT2_BLOCK_GROUP_DESC_SIZE));
        defer block_groups_slice.free();
        self.block_groups = try self.allocator.alloc(block_group_desc, self.superblock.num_block_groups);
        for (0..self.superblock.num_block_groups) |i| {
            self.block_groups[i] = block_group_desc.fromBytes(block_groups_slice.data[i * 32 .. (i + 1) * 32]);
            // printStruct(block_group_desc, self.block_groups[i]);
        }
        kernel.hardwareBootStatus("ext2: block groups ready at LBA {}", .{self.partition_entry.lba_first_absolute});
    }

    /// Gets a block from the filesystem. fills the buffer with the block data.
    /// Returns an error if the block is out of bounds or the buffer is too small.
    /// or if there was trouble with memory
    pub fn getBlock(self: *Self, block: u64) !DataSlice {
        if (self.cache.get(block)) |slice| {
            // std.log.info("cache hit for block {d}", .{block});
            return slice;
        }
        const block_addr = self.first_block_addr + (block * self.superblock.block_size);
        // std.log.info("getting block {d} at address {d}", .{block, block_addr});
        var block_slice = try self.dev.createDataSlice(self.allocator, block_addr, self.superblock.block_size);
        block_slice.cached = true;
        self.cache.put(block, block_slice) catch {
            block_slice.cached = false;
        };
        return block_slice;
    }

    pub fn getBlockRaw(self: *Self, block: u64, data: []u8) !void {
        const block_addr = self.first_block_addr + (block * self.superblock.block_size);
        const block_num = @as(u64, block_addr / self.dev.blk_size);
        try self.dev.readBlock(block_num, data);
    }

    pub fn getBlocksRaw(self: *Self, block: u64, count: u64, data: []u8) !void {
        const block_addr = self.first_block_addr + (block * self.superblock.block_size);
        const block_num = @as(u64, block_addr / self.dev.blk_size);
        const byte_count = std.math.mul(u64, count, self.superblock.block_size) catch
            return error.InvalidArgument;
        if (byte_count % self.dev.blk_size != 0 or data.len < byte_count) {
            return error.InvalidArgument;
        }
        try self.dev.readBlocks(block_num, byte_count / self.dev.blk_size, data);
    }

    pub fn getInode(self: *Self, inode_num: u64) !inode_table_entry {
        if (inode_num == 0) return std.mem.zeroes(inode_table_entry);
        if (inode_num > self.superblock.inodes_count) return Ex2Error.InodeNotFound;

        // get the block group for the inode!
        const block_group_num = (inode_num - 1) / self.superblock.inodes_per_group;
        if (block_group_num > self.block_groups.len) return Ex2Error.InodeNotInAnyGroup;

        const block_group = self.block_groups[block_group_num];
        const inode_table = block_group.inode_table;
        // std.log.info("inode table: {d}, block group: {d}, inode num: {d}", .{inode_table, block_group_num, inode_num});
        const inode_table_idx = (inode_num - 1) % self.superblock.inodes_per_group;
        const inodes_per_block = self.superblock.block_size / self.superblock.inode_size;
        // std.log.info("inode table idx: {d}, inodes per block: {d}", .{inode_table_idx, inodes_per_block});
        const inode_block = inode_table_idx / inodes_per_block;
        const inode_block_offset = (inode_table_idx % inodes_per_block) * self.superblock.inode_size;
        // std.log.info("inode block: {d}, inode block offset: {d}", .{inode_block, inode_block_offset});

        var block_slice = try self.getBlock(inode_table + inode_block);
        defer block_slice.free();

        const inode_mem: []u8 = block_slice.data[inode_block_offset .. inode_block_offset + self.superblock.inode_size];
        var result: inode_table_entry = undefined;
        result = inode_table_entry.fromBytes(inode_mem);
        return result;
    }

    pub fn deinit(self: *Self) void {
        self.cache.deinit();
        if (self.block_groups.len != 0) self.allocator.free(self.block_groups);
        self.allocator.destroy(self);
    }

    pub inline fn getInodeBlockID(self: *Self, inode: inode_table_entry, block_index: u32) !u32 {
        const indirect_block_size = self.superblock.block_size / @sizeOf(u32);
        const double_indirect_block_size = indirect_block_size * indirect_block_size;
        if (block_index < 12) {
            return inode.blocks[block_index]; // Direct block
        } else if (block_index < 12 + indirect_block_size) {
            // Single indirect block
            const indirect_block = inode.indirect_blocks;
            if (indirect_block == 0) return error.NotFound; // No indirect block
            var indirect_slice = try self.getBlock(indirect_block);
            defer indirect_slice.free();
            const block_id = @as(u32, std.mem.bytesToValue(u32, indirect_slice.data[(block_index - 12) * 4 .. (block_index - 12 + 1) * 4]));
            return block_id;
        } else if (block_index < 12 + indirect_block_size + double_indirect_block_size) {
            // Double indirect block
            const double_indirect_block = inode.double_indirect_blocks;
            if (double_indirect_block == 0) return error.NotFound; // No double indirect block
            var double_indirect_slice = try self.getBlock(double_indirect_block);
            defer double_indirect_slice.free();
            const indirect_index = (block_index - 12 - indirect_block_size) / indirect_block_size;
            const indirect_block_id = @as(u32, std.mem.bytesToValue(u32, double_indirect_slice.data[indirect_index * 4 .. (indirect_index + 1) * 4]));
            if (indirect_block_id == 0) return error.NotFound; // No indirect block
            var indirect_slice = try self.getBlock(indirect_block_id);
            defer indirect_slice.free();
            const block_id = @as(u32, std.mem.bytesToValue(u32, indirect_slice.data[((block_index - 12 - indirect_block_size) % indirect_block_size) * 4 .. ((block_index - 12 - indirect_block_size) % indirect_block_size + 1) * 4]));
            return block_id;
        }

        // Triple indirect block
        const triple_indirect_block = inode.triple_indirect_blocks;
        if (triple_indirect_block == 0) return error.NotFound; // No triple indirect block
        var triple_indirect_slice = try self.getBlock(triple_indirect_block);
        defer triple_indirect_slice.free();
        const double_index = (block_index - 12 - indirect_block_size - double_indirect_block_size) / double_indirect_block_size;
        const double_indirect_block_id = @as(u32, std.mem.bytesToValue(u32, triple_indirect_slice.data[double_index * 4 .. (double_index + 1) * 4]));
        if (double_indirect_block_id == 0) return error.NotFound; // No double indirect block
        var double_indirect_slice = try self.getBlock(double_indirect_block_id);
        defer double_indirect_slice.free();
        const indirect_index = (block_index - 12 - indirect_block_size - double_indirect_block_size) % double_indirect_block_size / indirect_block_size;
        const indirect_block_id = @as(u32, std.mem.bytesToValue(u32, double_indirect_slice.data[indirect_index * 4 .. (indirect_index + 1) * 4]));
        if (indirect_block_id == 0) return error.NotFound; // No indirect block
        // Read the block from the indirect block
        var indirect_slice = try self.getBlock(indirect_block_id);
        defer indirect_slice.free();
        const block_id = @as(u32, std.mem.bytesToValue(u32, indirect_slice.data[((block_index - 12 - indirect_block_size - double_indirect_block_size) % double_indirect_block_size) * 4 .. ((block_index - 12 - indirect_block_size - double_indirect_block_size) % double_indirect_block_size + 1) * 4]));
        return block_id;
    }

    pub inline fn readInodeBlock(self: *Self, inode: inode_table_entry, block: u32) !DataSlice {
        const block_id = try self.getInodeBlockID(inode, block);
        if (block_id == 0) return error.NotFound; // No such block
        // std.log.info("Reading inode block {d} from inode {any}", .{block_id, inode});
        return try self.getBlock(block_id);
    }

    pub fn printDirectoryEntries(self: *Self, inode: inode_table_entry, depth: u64) !void {
        if (!inode.mode.directory) {
            return error.InvalidFilesystem; // Not a directory
        }
        if (inode.size == 0) {
            log.info("Directory is empty.", .{});
            return;
        }
        const num_blocks = (inode.blocks_count * 512) / self.superblock.block_size;
        var block_index: u32 = 0;
        const depth_buff: []const u8 = "  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||";
        while (block_index < num_blocks) : (block_index += 1) {
            var block_slice = try self.readInodeBlock(inode, block_index);
            defer block_slice.free();
            var offset: usize = 0;
            while (offset < block_slice.data.len) {
                const entry = directory_entry.fromBytes(block_slice.data[offset..]);
                if (entry.rec_len == 0) break; // No more entries in this block
                log.info("{s}{s}{s}", .{ if (depth == 0) "" else depth_buff[0 .. depth * 3], if (depth == 0) "" else "- ", entry.getName() });
                if (entry.file_type == FileType.directory) cont_b: {
                    if (std.mem.eql(u8, "..", entry.getName())) break :cont_b;
                    if (std.mem.eql(u8, ".", entry.getName())) break :cont_b;
                    const next_inode = try self.getInode(entry.inode);
                    // if(next_inode.flags.index_format_directory) {
                    //     std.log.info(" index directory... not supported yet", .{});
                    // } else {
                    try self.printDirectoryEntries(next_inode, depth + 1);
                    // }
                }
                offset += @intCast(entry.rec_len);
            }
        }
    }

    pub fn printFullTree(self: *Self) !void {
        const root_inode = try self.getInode(2); // Inode 2 is the root directory in ext2 filesystems
        if (!root_inode.mode.directory) {
            return error.InvalidFilesystem; // Not a directory
        }
        log.info("Root inode: {any}", .{root_inode});
        try self.printDirectoryEntries(root_inode, 0);
    }
};

// TODO @(dleiferives,a27615e7-fd19-4a4e-aa0a-986e4838c4c3): add a iterator (with
// seeking and such) for reading inode blocks! ~#

pub fn printStruct(comptime T: type, value: T) void {
    const typeInfo = @typeInfo(T);
    switch (typeInfo) {
        .@"struct" => |structInfo| {
            inline for (structInfo.fields) |field| {
                const field_name = field.name;
                const field_value = @field(value, field_name);
                log.info("{s}: {any}", .{ field_name, field_value });
            }
        },
        else => @compileError("Only structs are supported!"),
    }
}

// goes through all the devices, and finds the partitions that are ext2 filesystems
pub const Ext2FilesystemIterator = struct {
    block_device_iter: block_device.BlockDeviceIterator,
    dev: ?*block_device.BlockDev,
    partition_entry_iter: ?mbr.PartitionEntryIterator,
    partition_entry: ?mbr.partition_table_entry,
    allocator: std.mem.Allocator,

    const RootLabelProbe = enum {
        root,
        other_ext2,
        not_ext2,
        unreadable,
        unsupported_block_size,
    };

    fn probeRootLabel(dev: *block_device.BlockDev, ent: mbr.partition_table_entry) RootLabelProbe {
        // Read the ext2 superblock without allocating a filesystem object. A
        // physical disk commonly has EFI, Linux boot, and LVM partitions ahead
        // of thad-os; probing those must not churn the early kernel heap.
        if (dev.blk_size == 0 or dev.blk_size > 4096 or
            !std.math.isPowerOfTwo(dev.blk_size))
        {
            return .unsupported_block_size;
        }

        var scratch: [4096]u8 = undefined;
        const superblock_offset: usize = 1024;
        const block_offset = superblock_offset % dev.blk_size;
        const bytes_needed = block_offset + 1024;
        const block_count = (bytes_needed + dev.blk_size - 1) / dev.blk_size;
        const read_length = block_count * dev.blk_size;
        if (read_length > scratch.len) return .unsupported_block_size;

        const block_start = @as(u64, ent.lba_first_absolute) +
            superblock_offset / dev.blk_size;
        dev.readBlocks(block_start, block_count, scratch[0..read_length]) catch
            return .unreadable;
        const bytes = scratch[block_offset..][0..1024];

        // Check magic before parsing computed fields: arbitrary non-ext2 bytes
        // could otherwise produce invalid shifts or counts in fromBytes().
        if (std.mem.bytesToValue(u16, bytes[56..58]) != EXT2_MAGIC) return .not_ext2;
        const sb = superblock.fromBytes(bytes);
        if (sb.hasVolumeName("thad-os") or sb.hasVolumeName("boot")) return .root;
        return .other_ext2;

        // TODO: Validate ext2 incompatibility flags here before constructing a
        // writable/mountable filesystem object.
    }

    pub fn init(allocator: std.mem.Allocator) !Ext2FilesystemIterator {
        var block_device_iter = block_device.getBlockDeviceIterator();
        const self = Ext2FilesystemIterator{
            .block_device_iter = block_device_iter,
            .dev = block_device_iter.next(),
            .partition_entry_iter = null,
            .partition_entry = null,
            .allocator = allocator,
        };
        return self;
    }

    pub fn next(self: *Ext2FilesystemIterator) ?*Ex2Filesystem {
        if (self.dev == null) {
            log.info("No more block devices to check for ext2 filesystems.", .{});
            return null; // No more devices
        }
        if (self.partition_entry_iter == null) {
            // Initialize partition entry iterator for the current device
            log.info("Initializing partition entry iterator for device: {any}", .{self.dev.?});
            kernel.hardwareBootStatus("ext2: opening partition table on {s}", .{self.dev.?.name});
            self.partition_entry_iter = mbr.PartitionEntryIterator.init(self.dev.?) orelse return null;
            kernel.hardwareBootStatus("ext2: partition table ready", .{});
        }
        if (self.partition_entry_iter.?.next()) |ent| {
            kernel.hardwareBootStatus("ext2: probing partition LBA {}", .{ent.lba_first_absolute});
            switch (probeRootLabel(self.dev.?, ent)) {
                .not_ext2 => {
                    kernel.hardwareBootStatus("ext2: no superblock at LBA {}", .{ent.lba_first_absolute});
                    return self.next();
                },
                .other_ext2 => {
                    kernel.hardwareBootStatus("ext2: skipping non-root label at LBA {}", .{ent.lba_first_absolute});
                    return self.next();
                },
                .unreadable => {
                    kernel.hardwareBootStatus("ext2: could not read LBA {}", .{ent.lba_first_absolute});
                    return self.next();
                },
                .unsupported_block_size => {
                    kernel.hardwareBootStatus("ext2: unsupported block size {}", .{self.dev.?.blk_size});
                    return self.next();
                },
                .root => kernel.hardwareBootStatus("ext2: root label found at LBA {}", .{ent.lba_first_absolute}),
            }
            const fs_n = Ex2Filesystem.init(self.dev.?, ent, self.allocator) catch |err| {
                log.err("Failed to initialize ext2 filesystem: {}", .{err});
                kernel.hardwareBootStatus("ext2: partition LBA {} failed: {}", .{ ent.lba_first_absolute, err });
                return self.next(); // Try the next partition
            };
            if (fs_n) |fs| {
                kernel.hardwareBootStatus("ext2: valid filesystem at LBA {}", .{ent.lba_first_absolute});
                // Do not accidentally mount an unrelated ext2 filesystem (for
                // example an old Linux /boot partition) as thad-os's root.
                // "boot" keeps existing project disk images compatible.
                if (!fs.superblock.hasVolumeName("thad-os") and
                    !fs.superblock.hasVolumeName("boot"))
                {
                    log.info("Skipping ext2 filesystem without a thad-os root label", .{});
                    kernel.hardwareBootStatus("ext2: skipping non-root label at LBA {}", .{ent.lba_first_absolute});
                    fs.deinit();
                    return self.next();
                }
                // Successfully created an ext2 filesystem
                log.info("Found ext2 filesystem on device: {*}, partition: at {}", .{ self.dev.?, ent.lba_first_absolute });
                self.partition_entry = ent;
                return fs; // Return the filesystem
            } else {
                // Not a valid ext2 filesystem, continue to the next partition
                log.info("Partition {any} on device {any} is not a valid ext2 filesystem.", .{ ent, self.dev.? });
                return self.next();
            }
        } else {
            // No more partition entries, move to the next device
            log.info("No more partition entries for device: {*}, moving to the next device.", .{self.dev.?});
            self.dev = self.block_device_iter.next();
            self.partition_entry_iter = null;
            self.partition_entry = null;
            return self.next();
        }
    }
};
