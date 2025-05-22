const std = @import("std");
const types = @import("mem/types.zig");
const elf = @import("elf.zig");

pub fn loadInfoHeader(kernel_offset: u64) *InfoHeader {
    var ptr_raw: u64 = undefined;
    asm volatile (
        \\.code64
        \\  movabs $multiboot_info_ptr, %%rcx
        \\  mov (%%rcx), %%rcx
        : [_] "={rcx}" (ptr_raw),
    );
    return @ptrFromInt(kernel_offset | ptr_raw);
}

// INFO
/// Error type for Multiboot2 operations
pub const MultibootError = error{
    InvalidInfoStructure,
    TagNotFound,
    InvalidMagic, // If magic number in EAX is wrong
};

/// Multiboot2 tag types (for boot information structure)
pub const TagType = enum(u32) {
    END = 0,
    COMMAND_LINE = 1,
    BOOT_LOADER_NAME = 2,
    MODULE = 3,
    BASIC_MEMORY_INFO = 4,
    BIOS_BOOT_DEVICE = 5,
    MEMORY_MAP = 6,
    VBE_INFO = 7,
    FRAMEBUFFER_INFO = 8,
    ELF_SYMBOLS = 9,
    APM_TABLE = 10,
    EFI_32_SYSTEM_TABLE = 11,
    EFI_64_SYSTEM_TABLE = 12,
    SMBIOS_TABLES = 13,
    ACPI_OLD_RSDP = 14,
    ACPI_NEW_RSDP = 15,
    NETWORK_INFO = 16,
    EFI_MEMORY_MAP = 17,
    EFI_BOOT_SERVICES_NOT_TERMINATED = 18, // Renamed for clarity
    EFI_32_IMAGE_HANDLE = 19,
    EFI_64_IMAGE_HANDLE = 20,
    IMAGE_LOAD_BASE_ADDR = 21,
    _, // Catch-all for unknown tags

    pub fn toString(self: TagType) []const u8 {
        return switch (self) {
            .END => "End",
            .COMMAND_LINE => "Command Line",
            .BOOT_LOADER_NAME => "Boot Loader Name",
            .MODULE => "Module",
            .BASIC_MEMORY_INFO => "Basic Memory Info",
            .BIOS_BOOT_DEVICE => "BIOS Boot Device",
            .MEMORY_MAP => "Memory Map",
            .VBE_INFO => "VBE Info",
            .FRAMEBUFFER_INFO => "Framebuffer Info",
            .ELF_SYMBOLS => "ELF Symbols",
            .APM_TABLE => "APM Table",
            .EFI_32_SYSTEM_TABLE => "EFI 32 System Table",
            .EFI_64_SYSTEM_TABLE => "EFI 64 System Table",
            .SMBIOS_TABLES => "SMBIOS Tables",
            .ACPI_OLD_RSDP => "ACPI Old RSDP",
            .ACPI_NEW_RSDP => "ACPI New RSDP",
            .NETWORK_INFO => "Network Info",
            .EFI_MEMORY_MAP => "EFI Memory Map",
            .EFI_BOOT_SERVICES_NOT_TERMINATED => "EFI Boot Services Not Terminated",
            .EFI_32_IMAGE_HANDLE => "EFI 32 Image Handle",
            .EFI_64_IMAGE_HANDLE => "EFI 64 Image Handle",
            .IMAGE_LOAD_BASE_ADDR => "Image Load Base Address",
            _ => "Unknown Tag Type",
        };
    }
};

pub const TagCast = union(TagType) {
    END: *const TagHeader,
    COMMAND_LINE: *const CommandLineTag,
    BOOT_LOADER_NAME: *const BootLoaderNameTag,
    MODULE: *const ModuleTag,
    BASIC_MEMORY_INFO: *const BasicMemoryInfoTag,
    BIOS_BOOT_DEVICE: *const BiosBootDeviceTag,
    MEMORY_MAP: *const MemoryMapTag,
    VBE_INFO: *const VBEInfoTag,
    FRAMEBUFFER_INFO: *const FramebufferTag,
    ELF_SYMBOLS: *const ElfSymbolsTag,
    APM_TABLE: *const ApmTableTag,
    EFI_32_SYSTEM_TABLE: *const Efi32SystemTableTag,
    EFI_64_SYSTEM_TABLE: *const Efi64SystemTableTag,
    SMBIOS_TABLES: *const SmbiosTablesTag,
    ACPI_OLD_RSDP: *const AcpiOldRsdpTag,
    ACPI_NEW_RSDP: *const AcpiNewRsdpTag,
    NETWORK_INFO: *const NetworkInfoTag,
    EFI_MEMORY_MAP: *const EfiMemoryMapTag,
    EFI_BOOT_SERVICES_NOT_TERMINATED: *const EfiBootServicesNotTerminatedTag,
    EFI_32_IMAGE_HANDLE: *const Efi32ImageHandleTag,
    EFI_64_IMAGE_HANDLE: *const Efi64ImageHandleTag,
    IMAGE_LOAD_BASE_ADDR: *const ImageLoadBaseAddrTag,
};

/// Multiboot2 information header (fixed part of boot information)
pub const InfoHeader = extern struct {
    total_size: u32,
    reserved: u32,
};

/// Tag header present at the beginning of every tag in boot information
pub const TagHeader = extern struct {
    type: u32,
    size: u32,

    pub fn getType(self: TagHeader) TagType {
        return @enumFromInt(self.type);
    }

};

// --- Individual Tag Struct Definitions ---

/// Command line tag (type 1)
pub const CommandLineTag = extern struct {
    header: TagHeader,
    // String follows (null-terminated UTF-8)

    pub fn getString(self: *const CommandLineTag) [*:0]const u8 {
        return @ptrCast(@alignCast(&@as([*]const u8, @ptrCast(&self.header))[8]));
    }

    pub fn getParam(self: *const CommandLineTag, name: []const u8, buffer: []u8) ?[]const u8 {
        const cmdline = std.mem.span(self.getString());
        var it = std.mem.tokenizeAny(u8, cmdline, " \t");

        while (it.next()) |token| {
            if (std.mem.startsWith(u8, token, name)) {
                if (token.len > name.len and token[name.len] == '=') {
                    const value = token[name.len + 1 ..];
                    const len = std.math.min(value.len, buffer.len);
                    std.mem.copy(u8, buffer[0..len], value[0..len]);
                    return buffer[0..len];
                } else {
                    return ""; // Parameter exists but has no value
                }
            }
        }
        return null;
    }

    pub fn hasFlag(self: *const CommandLineTag, flag: []const u8) bool {
        const cmdline = std.mem.span(self.getString());
        var it = std.mem.tokenizeAny(u8, cmdline, " \t");

        while (it.next()) |token| {
            if (std.mem.eql(u8, token, flag)) {
                return true;
            }
        }
        return false;
    }

    pub fn print(self: *const CommandLineTag, writer: anytype) !void {
        try writer.print("Command Line: {s}\n", .{self.getString()});
        const cmdline = std.mem.span(self.getString());
        var it = std.mem.tokenizeAny(u8, cmdline, " \t");
        var arg_count: usize = 0;
        try writer.print("  Parsed Arguments:\n", .{});
        while (it.next()) |arg| : (arg_count += 1) {
            try writer.print("    Arg {}: {s}\n", .{ arg_count, arg });
        }
    }
};

/// Boot loader name tag (type 2)
pub const BootLoaderNameTag = extern struct {
    header: TagHeader,
    // String follows (null-terminated UTF-8)

    pub fn getString(self: *const BootLoaderNameTag) [*:0]const u8 {
        return @ptrCast(@alignCast(&@as([*]const u8, @ptrCast(&self.header))[8]));
    }

    pub fn getVersion(self: *const BootLoaderNameTag) ?[]const u8 {
        const name = std.mem.span(self.getString());
        var i: usize = 0;
        while (i < name.len) : (i += 1) {
            if (std.ascii.isDigit(name[i])) {
                return name[i..];
            }
        }
        return null;
    }

    pub fn print(self: *const BootLoaderNameTag, writer: anytype) !void {
        try writer.print("Boot Loader Name: {s}\n", .{self.getString()});
        if (self.getVersion()) |version| {
            try writer.print("  Version: {s}\n", .{version});
        }
    }
};

/// Module information tag (type 3)
pub const ModuleTag = extern struct {
    header: TagHeader,
    mod_start: u32,
    mod_end: u32,
    // String follows (null-terminated UTF-8)

    pub fn getString(self: *const ModuleTag) [*:0]const u8 {
        return @ptrCast(@alignCast(&@as([*]const u8, @ptrCast(&self.header))[16]));
    }

    pub fn getSize(self: *const ModuleTag) u32 {
        return self.mod_end - self.mod_start;
    }

    pub fn getContents(self: *const ModuleTag) []const u8 {
        return @as([*]const u8, @ptrFromInt(self.mod_start))[0..self.getSize()];
    }

    pub fn containsAddress(self: *const ModuleTag, addr: u32) bool {
        return addr >= self.mod_start and addr < self.mod_end;
    }

    pub fn print(self: *const ModuleTag, writer: anytype) !void {
        try writer.print("Module Info:\n", .{});
        try writer.print("  Start Address: 0x{x:0>8}\n", .{self.mod_start});
        try writer.print("  End Address:   0x{x:0>8}\n", .{self.mod_end});
        try writer.print("  Size:          {} bytes ({} KB)\n", .{ self.getSize(), self.getSize() / 1024 });
        try writer.print("  Command Line:  {s}\n", .{self.getString()});
        const content = self.getContents();
        if (content.len >= 4) {
            const magic = content[0..4];
            if (std.mem.eql(u8, magic, "\x7FELF")) {
                try writer.print("  Format:        ELF executable\n", .{});
            } else if (std.mem.eql(u8, magic[0..2], "MZ")) {
                try writer.print("  Format:        DOS/PE executable\n", .{});
            }
        }
    }
};

/// Basic memory information tag (type 4)
pub const BasicMemoryInfoTag = extern struct {
    header: TagHeader,
    mem_lower: u32, // in kilobytes
    mem_upper: u32, // in kilobytes

    pub fn getTotalBytes(self: *const BasicMemoryInfoTag) u64 {
        return @as(u64, self.mem_lower) * 1024 + @as(u64, self.mem_upper) * 1024;
    }

    pub fn getLowerBytes(self: *const BasicMemoryInfoTag) u64 {
        return @as(u64, self.mem_lower) * 1024;
    }

    pub fn getUpperBytes(self: *const BasicMemoryInfoTag) u64 {
        return @as(u64, self.mem_upper) * 1024;
    }

    pub fn getTotalMB(self: *const BasicMemoryInfoTag) u64 {
        return self.getTotalBytes() / (1024 * 1024);
    }

    pub fn print(self: *const BasicMemoryInfoTag, writer: anytype) !void {
        try writer.print("Basic Memory Info:\n", .{});
        try writer.print("  Lower Memory: {} KB ({} bytes)\n", .{ self.mem_lower, self.getLowerBytes() });
        try writer.print("  Upper Memory: {} KB ({} bytes)\n", .{ self.mem_upper, self.getUpperBytes() });
        try writer.print("  Total Memory: {} MB ({} bytes)\n", .{ self.getTotalMB(), self.getTotalBytes() });
    }
};

/// BIOS Boot device tag (type 5)
pub const BiosBootDeviceTag = extern struct {
    header: TagHeader,
    bios_dev: u32,
    partition: u32,
    sub_partition: u32,

    pub const BiosDev = enum(u32) {
        FLOPPY_0 = 0x00,
        FLOPPY_1 = 0x01,
        FLOPPY_2 = 0x02,
        FLOPPY_3 = 0x03,
        HARD_DISK_0 = 0x80,
        HARD_DISK_1 = 0x81,
        HARD_DISK_2 = 0x82,
        HARD_DISK_3 = 0x83,
        CDROM_0 = 0xE0,
        CDROM_1 = 0xE1,
        _,
        pub fn toString(self: BiosDev) []const u8 {
            return switch (self) {
                .FLOPPY_0 => "Floppy Drive 0",
                .FLOPPY_1 => "Floppy Drive 1)",
                .FLOPPY_2 => "Floppy Drive 2",
                .FLOPPY_3 => "Floppy Drive 3",
                .HARD_DISK_0 => "Hard Disk 0",
                .HARD_DISK_1 => "Hard Disk 1",
                .HARD_DISK_2 => "Hard Disk 2",
                .HARD_DISK_3 => "Hard Disk 3",
                .CDROM_0 => "CD-ROM 0",
                .CDROM_1 => "CD-ROM 1",
                _ => "Unknown Device",
            };
        }
    };

    pub fn getBiosDev(self: *const BiosBootDeviceTag) ?BiosDev {
        return @enumFromInt(self.bios_dev);
    }
    pub fn getPartition(self: *const BiosBootDeviceTag) ?u32 {
        if (self.partition == 0xFFFFFFFF) return null;
        return self.partition;
    }
    pub fn getSubPartition(self: *const BiosBootDeviceTag) ?u32 {
        if (self.sub_partition == 0xFFFFFFFF) return null;
        return self.sub_partition;
    }
    pub fn isDosExtendedPartition(self: *const BiosBootDeviceTag) bool {
        const p = self.getPartition() orelse return false;
        return p >= 4;
    }
    pub fn getDevicePathString(self: *const BiosBootDeviceTag, buffer: []u8) []const u8 {
        var stream = std.io.fixedBufferStream(buffer);
        const writer = stream.writer();
        const dev = self.getBiosDev() orelse {
            _ = writer.write("Unknown") catch {};
            return buffer[0..stream.pos];
        };
        _ = writer.print("{s}", .{dev.toString()}) catch {};
        if (self.getPartition()) |p| {
            if (self.isDosExtendedPartition()) {
                _ = writer.print(", ExtP {}", .{p - 3}) catch {};
            } else {
                _ = writer.print(", P {}", .{p + 1}) catch {};
            }
            if (self.getSubPartition()) |sp| {
                _ = writer.print(", SubP {}", .{sp + 1}) catch {};
            }
        }
        return buffer[0..stream.pos];
    }
    pub fn print(self: *const BiosBootDeviceTag, writer: anytype) !void {
        try writer.print("BIOS Boot Device:\n", .{});
        const dev = self.getBiosDev() orelse {
            try writer.print("  Unknown BIOS Device: 0x{x:0>2}\n", .{self.bios_dev});
            return;
        };
        try writer.print("  BIOS Device: {s} (0x{x:0>2})\n", .{ dev.toString(), self.bios_dev });
        if (self.getPartition()) |p| {
            if (self.isDosExtendedPartition()) {
                try writer.print("  Partition: Extended Partition {} (raw: {})\n", .{ p - 3, p });
            } else {
                try writer.print("  Partition: {} (raw: {})\n", .{ p + 1, p });
            }
        } else {
            try writer.print("  Partition: None\n", .{});
        }
        if (self.getSubPartition()) |sp| {
            try writer.print("  Sub-Partition: {} (raw: {})\n", .{ sp + 1, sp });
        } else {
            try writer.print("  Sub-Partition: None\n", .{});
        }
        var path_buf: [100]u8 = undefined;
        try writer.print("  Device Path: {s}\n", .{self.getDevicePathString(&path_buf)});
    }
};

/// Memory map entry types
pub const MemoryMapType = enum(u32) {
    AVAILABLE = 1,
    RESERVED = 2,
    ACPI_RECLAIMABLE = 3,
    NVS = 4,
    BADRAM = 5,
    _,
    pub fn toString(self: MemoryMapType) []const u8 {
        return switch (self) {
            .AVAILABLE => "Available RAM",
            .RESERVED => "Reserved",
            .ACPI_RECLAIMABLE => "ACPI Reclaimable",
            .NVS => "ACPI NVS",
            .BADRAM => "Bad RAM",
            _ => "Unknown Memory Type",
        };
    }
};

/// Memory map entry
pub const MemoryMapEntry = extern struct {
    base_addr: u64,
    length: u64,
    type: u32,
    reserved: u32,
    pub fn getType(self: MemoryMapEntry) MemoryMapType {
        return @enumFromInt(self.type);
    }
    pub fn isAvailable(self: MemoryMapEntry) bool {
        return self.getType() == .AVAILABLE;
    }
    pub fn containsAddress(self: MemoryMapEntry, addr: u64) bool {
        return addr >= self.base_addr and addr < (self.base_addr + self.length);
    }
    pub fn endAddress(self: MemoryMapEntry) u64 {
        return self.base_addr + self.length;
    }

    pub fn toRange(self: MemoryMapEntry) types.MemoryRange {
        return types.MemoryRange{
            .start = self.base_addr,
            .end = self.endAddress(),
        };
    }
};

/// Memory map tag (type 6)
pub const MemoryMapTag = extern struct {
    header: TagHeader,
    entry_size: u32,
    entry_version: u32, // Entries follow

    pub const MemoryMapEntryIterator = struct {
        tag: *const MemoryMapTag,
        index: usize,

        pub fn next(self: *MemoryMapEntryIterator) ?*const MemoryMapEntry {
            if (self.index >= self.tag.getEntryCount()) return null;
            const entry = self.tag.getEntry(self.index);
            self.index += 1;
            return entry;
        }
    };

    pub fn getEntryIterator(self: *const MemoryMapTag) MemoryMapEntryIterator {
        return MemoryMapEntryIterator{
            .tag = self,
            .index = 0,
        };
    }

    pub fn fromTagHeader(header: *const TagHeader) *const MemoryMapTag {
        return @ptrCast(header);
    }

    pub fn getEntryCount(self: *const MemoryMapTag) usize {
        return @divExact(self.header.size - @sizeOf(MemoryMapTag), self.entry_size);
    }
    pub fn getEntry(self: *const MemoryMapTag, index: usize) ?*const MemoryMapEntry {
        if (index >= self.getEntryCount()) return null;
        const entries_start = @intFromPtr(self) + @sizeOf(MemoryMapTag);
        return @ptrFromInt(entries_start + (index * self.entry_size));
    }
    pub fn getTotalAvailableMemory(self: *const MemoryMapTag) u64 {
        var total: u64 = 0;
        for (0..self.getEntryCount()) |i| {
            if (self.getEntry(i).?.isAvailable()) total += self.getEntry(i).?.length;
        }
        return total;
    }
    pub fn getLargestAvailableRegion(self: *const MemoryMapTag) ?*const MemoryMapEntry {
        var largest_entry: ?*const MemoryMapEntry = null;
        var largest_size: u64 = 0;
        for (0..self.getEntryCount()) |i| {
            const entry = self.getEntry(i).?;
            if (entry.isAvailable() and entry.length > largest_size) {
                largest_size = entry.length;
                largest_entry = entry;
            }
        }
        return largest_entry;
    }
    pub fn print(self: *const MemoryMapTag, writer: anytype) !void {
        try writer.print("Memory Map:\n", .{});
        try writer.print("  Entry Size: {} bytes, Version: {}, Count: {}\n", .{ self.entry_size, self.entry_version, self.getEntryCount() });
        try writer.print("  Total Available: {} bytes ({} MiB)\n", .{ self.getTotalAvailableMemory(), self.getTotalAvailableMemory() / (1024 * 1024) });
        if (self.getLargestAvailableRegion()) |r| try writer.print("  Largest Available: 0x{x:0>16}-0x{x:0>16} ({} MiB)\n", .{ r.base_addr, r.endAddress() - 1, r.length / (1024 * 1024) });
        const to_print = self.getEntryCount();
        if (to_print == 0) {
            try writer.print("  No memory entries available.\n", .{});
            return;
        }
        try writer.print("The {} entries:\n", .{to_print});
        for (0..to_print) |i| {
            const e = self.getEntry(i).?;
            try writer.print("    0x{x:0>16}-0x{x:0>16} ({} Bytes) {s}\n", .{ e.base_addr, e.endAddress() - 1, e.length / (1), e.getType().toString() });
        }
    }
};

/// VBE information tag (type 7)
pub const VBEInfoTag = extern struct {
    header: TagHeader,
    vbe_mode: u16,
    vbe_interface_seg: u16,
    vbe_interface_off: u16,
    vbe_interface_len: u16,
    vbe_control_info: [512]u8,
    vbe_mode_info: [256]u8,
    pub fn print(self: *const VBEInfoTag, writer: anytype) !void {
        try writer.print("VBE Info:\n", .{});
        try writer.print("  Mode: 0x{x:0>4}, Interface: {x:0>4}:{x:0>4} (len {})\n", .{ self.vbe_mode, self.vbe_interface_seg, self.vbe_interface_off, self.vbe_interface_len });
        // Further parsing of vbe_control_info and vbe_mode_info is complex and VBE-spec dependent
    }
};

/// Framebuffer types
pub const FramebufferType = enum(u8) {
    INDEXED = 0,
    RGB = 1,
    EGA_TEXT = 2,
    _,
    pub fn toString(self: FramebufferType) []const u8 {
        return switch (self) {
            .INDEXED => "Indexed Color",
            .RGB => "Direct RGB",
            .EGA_TEXT => "EGA Text",
            _ => "Unknown Framebuffer Type",
        };
    }
};
/// Color descriptor for indexed color modes
pub const Color = extern struct { red: u8, green: u8, blue: u8 };
/// RGB color information for direct RGB modes
pub const RgbColorInfo = extern struct {
    red_field_position: u8,
    red_mask_size: u8,
    green_field_position: u8,
    green_mask_size: u8,
    blue_field_position: u8,
    blue_mask_size: u8,
};

/// Framebuffer info tag (type 8)
pub const FramebufferTag = extern struct {
    header: TagHeader,
    framebuffer_addr: u64,
    framebuffer_pitch: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    framebuffer_bpp: u8,
    framebuffer_type: u8,
    reserved: u8, // Color info follows
    pub fn getType(self: *const FramebufferTag) FramebufferType {
        return @enumFromInt(self.framebuffer_type);
    }
    pub fn getPaletteNumColors(self: *const FramebufferTag) ?u32 { // Spec says u16 for num_colors in header example, but u32 in text. Using u32 from text.
        if (self.getType() != .INDEXED) return null;
        const data_start = @intFromPtr(self) + @sizeOf(FramebufferTag);
        return @as(*const u32, @ptrFromInt(data_start)).*;
    }
    pub fn getRgbInfo(self: *const FramebufferTag) ?*const RgbColorInfo {
        if (self.getType() != .RGB) return null;
        const data_start = @intFromPtr(self) + @sizeOf(FramebufferTag);
        return @as(*const RgbColorInfo, @ptrFromInt(data_start));
    }
    pub fn print(self: *const FramebufferTag, writer: anytype) !void {
        try writer.print("Framebuffer Info:\n", .{});
        try writer.print("  Address: 0x{x:0>16}, Pitch: {}\n", .{ self.framebuffer_addr, self.framebuffer_pitch });
        try writer.print("  Dimensions: {}x{}, BPP: {}, Type: {s}\n", .{ self.framebuffer_width, self.framebuffer_height, self.framebuffer_bpp, self.getType().toString() });
        switch (self.getType()) {
            .INDEXED => if (self.getPaletteNumColors()) |n| try writer.print("  Palette Colors: {}\n", .{n}),
            .RGB => if (self.getRgbInfo()) |rgb| try writer.print("  RGB Masks: R={}({}), G={}({}), B={}({})\n", .{ rgb.red_field_position, rgb.red_mask_size, rgb.green_field_position, rgb.green_mask_size, rgb.blue_field_position, rgb.blue_mask_size }),
            else => {},
        }
    }
};

/// ELF symbols tag (type 9)
pub const ElfSymbolsTag = extern struct {
    header: TagHeader,
    num: u32,
    entsize: u32,
    shndx: u32, // Contains index of the section header table entry that contains the section names
    reserved: u32, // Section headers follow

    pub fn print(self: *const ElfSymbolsTag, writer: anytype) !void {
        try writer.print("ELF Symbols:\n  Sections: {}, Entry Size: {}, String Table Index: {}\n", .{ self.num, self.entsize, self.shndx });
        elf.parseElfSections(self, true);

    }

    pub fn getSectionCount(self: *const ElfSymbolsTag) usize {
        return @divExact(self.header.size - @sizeOf(ElfSymbolsTag), self.entsize);
    }
};


/// APM table tag (type 10)
pub const ApmTableTag = extern struct {
    header: TagHeader,
    version: u16,
    cseg: u16,
    offset: u32,
    cseg_16: u16,
    dseg: u16,
    flags: u16,
    cseg_len: u16,
    cseg_16_len: u16,
    dseg_len: u16,
    pub fn print(self: *const ApmTableTag, writer: anytype) !void {
        try writer.print("APM Table:\n  Version: {}.{}, CS:0x{x:0>4}, Offset:0x{x:0>8}\n", .{ self.version >> 8, self.version & 0xFF, self.cseg, self.offset });
    }
};

/// EFI 32-bit system table tag (type 11)
pub const Efi32SystemTableTag = extern struct {
    header: TagHeader,
    pointer: u32,
    pub fn print(self: *const Efi32SystemTableTag, writer: anytype) !void {
        try writer.print("EFI 32 System Table Pointer: 0x{x:0>8}\n", .{self.pointer});
    }
};

/// EFI 64-bit system table tag (type 12)
pub const Efi64SystemTableTag = extern struct {
    header: TagHeader,
    pointer: u64,
    pub fn print(self: *const Efi64SystemTableTag, writer: anytype) !void {
        try writer.print("EFI 64 System Table Pointer: 0x{x:0>16}\n", .{self.pointer});
    }
};

/// SMBIOS tables tag (type 13)
pub const SmbiosTablesTag = extern struct {
    header: TagHeader,
    major: u8,
    minor: u8,
    reserved: [6]u8, // SMBIOS tables follow
    pub fn getTablesSize(self: *const SmbiosTablesTag) usize {
        return self.header.size - @sizeOf(SmbiosTablesTag);
    }
    pub fn print(self: *const SmbiosTablesTag, writer: anytype) !void {
        try writer.print("SMBIOS Tables:\n  Version: {}.{}, Size: {} bytes\n", .{ self.major, self.minor, self.getTablesSize() });
    }
};

/// ACPI old RSDP tag (type 14)
pub const AcpiOldRsdpTag = extern struct {
    header: TagHeader, // RSDPv1 structure follows
    pub fn getRsdpSize(self: *const AcpiOldRsdpTag) usize {
        return self.header.size - @sizeOf(TagHeader);
    }
    pub fn print(self: *const AcpiOldRsdpTag, writer: anytype) !void {
        try writer.print("ACPI Old RSDP (v1):\n  Size: {} bytes\n", .{self.getRsdpSize()});
    }
};

/// ACPI new RSDP tag (type 15)
pub const AcpiNewRsdpTag = extern struct {
    header: TagHeader, // RSDPv2+ structure follows
    pub fn getRsdpSize(self: *const AcpiNewRsdpTag) usize {
        return self.header.size - @sizeOf(TagHeader);
    }
    pub fn print(self: *const AcpiNewRsdpTag, writer: anytype) !void {
        try writer.print("ACPI New RSDP (v2+):\n  Size: {} bytes\n", .{self.getRsdpSize()});
    }
};

/// Network information tag (type 16)
pub const NetworkInfoTag = extern struct {
    header: TagHeader, // DHCP ACK follows
    pub fn getDhcpSize(self: *const NetworkInfoTag) usize {
        return self.header.size - @sizeOf(TagHeader);
    }
    pub fn print(self: *const NetworkInfoTag, writer: anytype) !void {
        try writer.print("Network Info (DHCP ACK):\n  Size: {} bytes\n", .{self.getDhcpSize()});
    }
};

/// EFI memory map tag (type 17)
pub const EfiMemoryMapTag = extern struct {
    header: TagHeader,
    descriptor_size: u32,
    descriptor_version: u32, // EFI memory map follows
    pub fn getMapSize(self: *const EfiMemoryMapTag) usize {
        return self.header.size - @sizeOf(EfiMemoryMapTag);
    }
    pub fn getEntryCount(self: *const EfiMemoryMapTag) usize {
        return if (self.descriptor_size == 0) 0 else self.getMapSize() / self.descriptor_size;
    }
    pub fn print(self: *const EfiMemoryMapTag, writer: anytype) !void {
        try writer.print("EFI Memory Map:\n  Desc Size: {}, Desc Ver: {}, Entries: {}\n", .{ self.descriptor_size, self.descriptor_version, self.getEntryCount() });
    }
};

/// EFI boot services not terminated tag (type 18)
pub const EfiBootServicesNotTerminatedTag = extern struct { // Renamed from EfiBootServicesTag
    header: TagHeader,
    pub fn print(self: *const EfiBootServicesNotTerminatedTag, writer: anytype) !void {
        _ = self;
        try writer.print("EFI Boot Services: Not Terminated (Still Active)\n", .{});
    }
};

/// EFI 32-bit image handle pointer tag (type 19)
pub const Efi32ImageHandleTag = extern struct {
    header: TagHeader,
    pointer: u32,
    pub fn print(self: *const Efi32ImageHandleTag, writer: anytype) !void {
        try writer.print("EFI 32 Image Handle Pointer: 0x{x:0>8}\n", .{self.pointer});
    }
};

/// EFI 64-bit image handle pointer tag (type 20)
pub const Efi64ImageHandleTag = extern struct {
    header: TagHeader,
    pointer: u64,
    pub fn print(self: *const Efi64ImageHandleTag, writer: anytype) !void {
        try writer.print("EFI 64 Image Handle Pointer: 0x{x:0>16}\n", .{self.pointer});
    }
};

/// Image load base physical address tag (type 21)
pub const ImageLoadBaseAddrTag = extern struct {
    header: TagHeader,
    load_base_addr: u32,
    pub fn print(self: *const ImageLoadBaseAddrTag, writer: anytype) !void {
        try writer.print("Image Load Base Address: 0x{x:0>8}\n", .{self.load_base_addr});
    }
};

/// Main Multiboot2 information structure
pub const Multiboot2Info = struct {
    header_ptr: *allowzero const InfoHeader,

    pub fn init(header: *InfoHeader) Multiboot2Info {
        // if (header.total_size < @sizeOf(InfoHeader) or header.reserved != 0) {
        //     return MultibootError.InvalidInfoStructure;
        // }
        return Multiboot2Info{ .header_ptr = header };
    }

    // --- Tag Iteration ---
    fn getFirstTag(self: Multiboot2Info) ?*const TagHeader {
        const first_tag_addr = @intFromPtr(self.header_ptr) + @sizeOf(InfoHeader);
        return @ptrFromInt(first_tag_addr);
    }
    fn getNextTag(self: Multiboot2Info, tag: *const TagHeader) ?*const TagHeader {
        if (tag.type == 0 and tag.size == 8) return null; // End tag
        const tag_end = @intFromPtr(tag) + tag.size;
        const next_tag_addr = (tag_end + 7) & ~@as(usize, 7); // Align to 8 bytes
        if (next_tag_addr >= @intFromPtr(self.header_ptr) + self.header_ptr.total_size) return null;
        return @ptrFromInt(next_tag_addr);
    }
    pub fn findTag(self: Multiboot2Info, tag_type: TagType) ?*const TagHeader {
        var current_tag = self.getFirstTag();
        while (current_tag) |tag| {
            if (tag.getType() == tag_type) return tag;
            current_tag = self.getNextTag(tag);
        }
        return null;
    }
    pub fn getTagByType(self: Multiboot2Info, comptime T: type, tag_type: TagType) ?*const T {
        const tag = self.findTag(tag_type) orelse return null;
        return @ptrCast(@alignCast(tag));
    }

    // --- Module Handling ---
    pub fn getModules(self: Multiboot2Info, allocator: std.mem.Allocator) ![]*const ModuleTag {
        var list = std.ArrayList(*const ModuleTag).init(allocator);
        errdefer list.deinit();
        var current_tag = self.getFirstTag();
        while (current_tag) |tag| {
            if (tag.getType() == .MODULE) {
                try list.append(@ptrCast(@alignCast(tag)));
            }
            current_tag = self.getNextTag(tag);
        }
        return list.toOwnedSlice();
    }

    pub const TagIterator = struct {
        info: *const Multiboot2Info,
        next_tag: ?*const TagHeader,
        tag_type: ?TagType,
        pub fn next(self: *TagIterator) ?*const TagHeader {
            while (self.next_tag) |tag| {
                if (self.tag_type) |ttype| {
                    self.next_tag = self.info.getNextTag(tag);
                    if (ttype != tag.getType()) continue;
                    return tag;
                }
                self.next_tag = self.info.getNextTag(tag);
                return tag;
            }
            return null;
        }
    };

    pub fn getTagIterator(self: *const Multiboot2Info) TagIterator {
        return TagIterator{ .info = self, .next_tag = self.getFirstTag(), .tag_type = null };
    }

    pub fn getTagTypeIterator(self: *const Multiboot2Info, tag_type: TagType) TagIterator {
        return TagIterator{ .info = self, .next_tag = self.getFirstTag(), .tag_type = tag_type };
    }

    pub fn printModules(self: Multiboot2Info, writer:anytype ) !void {
        var current_tag = self.getFirstTag();
        while (current_tag) |tag| {
            if (tag.type == 0 and tag.size == 8) break; // End tag
            if (tag.getType() == .MODULE) {
                const mod: *const ModuleTag = @ptrCast(@alignCast(tag));
                try mod.print(writer);
            }
            current_tag = self.getNextTag(tag);
        }
    }

    pub fn findModule(self: Multiboot2Info, name: []const u8) ?*const ModuleTag {
        var current_tag = self.getFirstTag();
        while (current_tag) |tag| {
            if (tag.getType() == .MODULE) {
                const mod_tag: *const ModuleTag = @ptrCast(@alignCast(tag));
                if (std.mem.eql(u8, std.mem.span(mod_tag.getString()), name)) return mod_tag;
            }
            current_tag = self.getNextTag(tag);
        }
        return null;
    }

    // --- Utility ---
    pub fn getTotalMemory(self: Multiboot2Info) u64 {
        if (self.getMemoryMapTag()) |mmap| return mmap.getTotalAvailableMemory();
        if (self.getBasicMemoryInfoTag()) |basic| return basic.getTotalBytes();
        return 0;
    }

    /// Print all Multiboot2 information for debugging
    pub fn dumpInfo(self: *Multiboot2Info, writer: anytype) !void {
        try writer.print("\n--- Multiboot2 Information (Total Size: {} bytes) ---\n", .{self.header_ptr.total_size});


        var current_tag:?*const TagHeader  = self.getFirstTag();
        var tag_idx: usize = 0;
        while (current_tag) |tag| : (tag_idx += 1) while_loop: {
            if (tag.type == 0 and tag.size == 8) break; // End tag
            switch(tag.getType()) {
                .END => {break :while_loop;},
                .COMMAND_LINE => {
                    const cmd_line:*CommandLineTag  = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try cmd_line.print(writer);
                },
                .BOOT_LOADER_NAME => {
                    const boot_loader_name:*BootLoaderNameTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try boot_loader_name.print(writer);
                },
                .MODULE => {
                    const module:*ModuleTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try module.print(writer);
                },
                .BASIC_MEMORY_INFO => {
                    const basic_memory_info:*BasicMemoryInfoTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try basic_memory_info.print(writer);
                },
                .MEMORY_MAP => {
                    const memory_map:*MemoryMapTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try memory_map.print(writer);
                },
                .BIOS_BOOT_DEVICE => {
                    const bios_boot_device:*BiosBootDeviceTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try bios_boot_device.print(writer);
                },
                .VBE_INFO => {
                    const vbe_info:*VBEInfoTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try vbe_info.print(writer);
                },
                .FRAMEBUFFER_INFO => {
                    const framebuffer_info:*FramebufferTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try framebuffer_info.print(writer);
                },
                .ELF_SYMBOLS => {
                    const elf_symbols:*ElfSymbolsTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try elf_symbols.print(writer);
                },
                .APM_TABLE => {
                    const apm_table:*ApmTableTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try apm_table.print(writer);
                },
                .EFI_32_SYSTEM_TABLE => {
                    const efi_32_system_table:*Efi32SystemTableTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try efi_32_system_table.print(writer);
                },
                .EFI_64_SYSTEM_TABLE => {
                    const efi_64_system_table:*Efi64SystemTableTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try efi_64_system_table.print(writer);
                },
                .SMBIOS_TABLES => {
                    const smbios_tables:*SmbiosTablesTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try smbios_tables.print(writer);
                },
                .ACPI_OLD_RSDP => {
                    const acpi_old_rsdp:*AcpiOldRsdpTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try acpi_old_rsdp.print(writer);
                },
                .ACPI_NEW_RSDP => {
                    const acpi_new_rsdp:*AcpiNewRsdpTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try acpi_new_rsdp.print(writer);
                },
                .NETWORK_INFO => {
                    const network_info:*NetworkInfoTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try network_info.print(writer);
                },
                .EFI_MEMORY_MAP => {
                    const efi_memory_map:*EfiMemoryMapTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try efi_memory_map.print(writer);
                },
                .EFI_BOOT_SERVICES_NOT_TERMINATED => {
                    const efi_boot_services_not_terminated:*EfiBootServicesNotTerminatedTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try efi_boot_services_not_terminated.print(writer);
                },
                .EFI_32_IMAGE_HANDLE => {
                    const efi_32_image_handle:*Efi32ImageHandleTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try efi_32_image_handle.print(writer);
                },
                .EFI_64_IMAGE_HANDLE => {
                    const efi_64_image_handle:*Efi64ImageHandleTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try efi_64_image_handle.print(writer);
                },
                .IMAGE_LOAD_BASE_ADDR => {
                    const image_load_base_addr:*ImageLoadBaseAddrTag = @ptrFromInt(@as(usize, @intFromPtr(tag)));
                    try image_load_base_addr.print(writer);
                },

                else => {}
            }
            current_tag = self.getNextTag(tag);
        }

        try writer.print("Modules ------------------------------------------------\n", .{});
        try self.printModules(writer);
        try writer.print("--------------------------------------------------------\n", .{});

        try writer.print("--- All Tags Raw Listing ---\n", .{});
        try writer.print("  {s: <5} | {s: <25} | {s: <8} | {s: <8}\n", .{ "Index", "Type Name", "TypeID", "Size" });
        try writer.print("  --------------------------------------------------------\n", .{});
        current_tag = self.getFirstTag();
        tag_idx= 0;
        while (current_tag) |tag| : (tag_idx += 1) {
            try writer.print("  {d: <5} | {s: <25} | {d: <8} | {d: <8}\n", .{ tag_idx, tag.getType().toString(), tag.type, tag.size });
            if (tag.type == 0 and tag.size == 8) break; // End tag
            current_tag = self.getNextTag(tag);
        }
        try writer.print("--- End Multiboot2 Information ---\n", .{});
    }
};
