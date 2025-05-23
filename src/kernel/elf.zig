const std = @import("std");
const multiboot = @import("multiboot.zig");
const types = @import("mem/types.zig");
const mem = std.mem;
const ElfSymbolsTag = multiboot.ElfSymbolsTag;

pub const elf = struct {
    /// ELF identification indices
    pub const EI = struct {
        pub const MAG0 = 0;
        pub const MAG1 = 1;
        pub const MAG2 = 2;
        pub const MAG3 = 3;
        pub const CLASS = 4;
        pub const DATA = 5;
        pub const VERSION = 6;
        pub const OSABI = 7;
        pub const ABIVERSION = 8;
        pub const PAD = 9;
        pub const NIDENT = 16;
    };

    /// ELF classes
    pub const ELFCLASS = struct {
        pub const NONE = 0;
        pub const BITS32 = 1;
        pub const BITS64 = 2;
    };

    /// Data encoding
    pub const ELFDATA = struct {
        pub const NONE = 0;
        pub const LSB = 1; // Little endian
        pub const MSB = 2; // Big endian
    };

    /// Object file types
    pub const ET = struct {
        pub const NONE = 0;
        pub const REL = 1;
        pub const EXEC = 2;
        pub const DYN = 3;
        pub const CORE = 4;
        pub const LOOS = 0xFE00;
        pub const HIOS = 0xFEFF;
        pub const LOPROC = 0xFF00;
        pub const HIPROC = 0xFFFF;
    };

    /// Section types
    pub const SHT = struct {
        pub const NULL = 0;
        pub const PROGBITS = 1;
        pub const SYMTAB = 2;
        pub const STRTAB = 3;
        pub const RELA = 4;
        pub const HASH = 5;
        pub const DYNAMIC = 6;
        pub const NOTE = 7;
        pub const NOBITS = 8;
        pub const REL = 9;
        pub const SHLIB = 10;
        pub const DYNSYM = 11;
        pub const INIT_ARRAY = 14;
        pub const FINI_ARRAY = 15;
        pub const PREINIT_ARRAY = 16;
        pub const GROUP = 17;
        pub const SYMTAB_SHNDX = 18;
    };

    /// Program header types
    pub const PT = struct {
        pub const NULL = 0;
        pub const LOAD = 1;
        pub const DYNAMIC = 2;
        pub const INTERP = 3;
        pub const NOTE = 4;
        pub const SHLIB = 5;
        pub const PHDR = 6;
        pub const TLS = 7;
        pub const LOOS = 0x60000000;
        pub const HIOS = 0x6FFFFFFF;
        pub const LOPROC = 0x70000000;
        pub const HIPROC = 0x7FFFFFFF;
    };

    /// Section flags
    pub const SHF = struct {
        pub const WRITE = 0x1;
        pub const ALLOC = 0x2;
        pub const EXECINSTR = 0x4;
        pub const MERGE = 0x10;
        pub const STRINGS = 0x20;
        pub const INFO_LINK = 0x40;
        pub const LINK_ORDER = 0x80;
        pub const OS_NONCONFORMING = 0x100;
        pub const GROUP = 0x200;
        pub const TLS = 0x400;
        pub const MASKOS = 0x0FF00000;
        pub const MASKPROC = 0xF0000000;
    };

    /// 32-bit ELF header
    pub const Elf32_Ehdr = extern struct {
        e_ident: [EI.NIDENT]u8,
        e_type: u16,
        e_machine: u16,
        e_version: u32,
        e_entry: u32,
        e_phoff: u32,
        e_shoff: u32,
        e_flags: u32,
        e_ehsize: u16,
        e_phentsize: u16,
        e_phnum: u16,
        e_shentsize: u16,
        e_shnum: u16,
        e_shstrndx: u16,
    };

    /// 64-bit ELF header
    pub const Elf64_Ehdr = extern struct {
        e_ident: [EI.NIDENT]u8,
        e_type: u16,
        e_machine: u16,
        e_version: u32,
        e_entry: u64,
        e_phoff: u64,
        e_shoff: u64,
        e_flags: u32,
        e_ehsize: u16,
        e_phentsize: u16,
        e_phnum: u16,
        e_shentsize: u16,
        e_shnum: u16,
        e_shstrndx: u16,
    };

    /// 32-bit Section header
    pub const Elf32_Shdr = extern struct {
        sh_name: u32,
        sh_type: u32,
        sh_flags: u32,
        sh_addr: u32,
        sh_offset: u32,
        sh_size: u32,
        sh_link: u32,
        sh_info: u32,
        sh_addralign: u32,
        sh_entsize: u32,
    };

    /// 64-bit Section header
    pub const Elf64_Shdr = extern struct {
        sh_name: u32,
        sh_type: u32,
        sh_flags: u64,
        sh_addr: u64,
        sh_offset: u64,
        sh_size: u64,
        sh_link: u32,
        sh_info: u32,
        sh_addralign: u64,
        sh_entsize: u64,
    };

    /// 32-bit Program header
    pub const Elf32_Phdr = extern struct {
        p_type: u32,
        p_offset: u32,
        p_vaddr: u32,
        p_paddr: u32,
        p_filesz: u32,
        p_memsz: u32,
        p_flags: u32,
        p_align: u32,
    };

    /// 64-bit Program header
    pub const Elf64_Phdr = extern struct {
        p_type: u32,
        p_flags: u32,
        p_offset: u64,
        p_vaddr: u64,
        p_paddr: u64,
        p_filesz: u64,
        p_memsz: u64,
        p_align: u64,
    };

/// Symbol Binding Attributes (for st_info)
    pub const STB = struct {
        pub const LOCAL = 0; // Local symbol
        pub const GLOBAL = 1; // Global symbol
        pub const WEAK = 2; // Weak symbol
        // Other values exist for OS/processor specifics
    };

    /// Symbol Types (for st_info)
    pub const STT = struct {
        pub const NOTYPE = 0; // Symbol type is unspecified
        pub const OBJECT = 1; // Symbol is a data object
        pub const FUNC = 2; // Symbol is a code object (function)
        pub const SECTION = 3; // Symbol associated with a section
        pub const FILE = 4; // Symbol's name is file name
        pub const COMMON = 5; // Symbol is a common block
        pub const TLS = 6; // Symbol is thread-local storage
        // Other values exist for OS/processor specifics
    };

    /// Special Section Indices (for st_shndx)
    pub const SHN = struct {
        pub const UNDEF = 0; // Undefined section
        pub const LOPROC = 0xFF00; // Start of processor-specific
        pub const HIPROC = 0xFF1F; // End of processor-specific
        pub const LOOS = 0xFF20; // Start of OS-specific
        pub const HIOS = 0xFF3F; // End of OS-specific
        pub const ABS = 0xFFF1; // Associated symbol is absolute
        pub const COMMON = 0xFFF2; // Associated symbol is common (Fortran)
        pub const XINDEX = 0xFFFF; // Index is in extra table (SHT_SYMTAB_SHNDX)
    };

    /// 32-bit Symbol Table Entry
    pub const Elf32_Sym = extern struct {
        st_name: u32, // Symbol name (index into string table)
        st_value: u32, // Value of the symbol
        st_size: u32, // Associated size, if any
        st_info: u8, // Type and binding attributes
        st_other: u8, // Reserved (visibility for ELF64)
        st_shndx: u16, // Section header index
    };

    /// 64-bit Symbol Table Entry
    pub const Elf64_Sym = extern struct {
        st_name: u32, // Symbol name (index into string table)
        st_info: u8, // Type and binding attributes
        st_other: u8, // Symbol visibility (usually st_other & 0x3)
        st_shndx: u16, // Section header index
        st_value: u64, // Value of the symbol
        st_size: u64, // Associated size, if any
    };

    // Helper functions for st_info
    pub fn ELF_ST_BIND(info: u8) u8 {
        return info >> 4;
    }
    pub fn ELF_ST_TYPE(info: u8) u8 {
        return info & 0x0F;
    }
    pub fn ELF_ST_INFO(bind: u8, type_: u8) u8 {
        return (bind << 4) + (type_ & 0x0F);
    }

    // Helper for st_other (visibility)
    pub const STV = struct {
        pub const DEFAULT = 0;
        pub const INTERNAL = 1;
        pub const HIDDEN = 2;
        pub const PROTECTED = 3;
    };
    pub fn ELF_ST_VISIBILITY(other: u8) u8 {
        return other & 0x3;
    }

};



/// ELF section header iterator - no allocations required
pub const ElfSectionIterator = struct {
    tag: *const ElfSymbolsTag,
    current_index: usize = 0,
    is_64bit: bool,
    string_table_data: ?[]const u8 = null,

    /// Create a new section iterator from an ELF symbols tag
    pub fn init(tag: *const ElfSymbolsTag, is_64bit: bool) ElfSectionIterator {
        return .{
            .tag = tag,
            .is_64bit = is_64bit,
        };
    }

    /// Set the string table data for section name resolution
    pub fn setStringTable(self: *ElfSectionIterator, string_table: []const u8) void {
        self.string_table_data = string_table;
    }

    /// Get the next section header
    pub fn next(self: *ElfSectionIterator) ?ElfSection {
        if (self.current_index >= self.tag.num) {
            return null;
        }

        const section_offset = @sizeOf(ElfSymbolsTag) + (self.current_index * self.tag.entsize);
        if (self.tag.entsize != @sizeOf(elf.Elf64_Shdr) and
            self.tag.entsize != @sizeOf(elf.Elf32_Shdr)) {
            std.log.debug("Invalid section header size: {}", .{self.tag.entsize});
            return null;
        }
        const section_ptr = @intFromPtr(self.tag) + section_offset;

        var section = ElfSection{
            .header32 = undefined,
            .header64 = undefined,
            .is_64bit = self.is_64bit,
            .name = null,
            .string_table = self.string_table_data,
        };



        const buffer:[*]u8 = @ptrFromInt(@intFromPtr(self.tag) + @sizeOf(ElfSymbolsTag) - @sizeOf(u32));
        const offset_in_buffer = self.current_index * self.tag.entsize;
        const single_header_size = @sizeOf(elf.Elf64_Shdr);
        const section_header_bytes_from_buffer = buffer[offset_in_buffer .. offset_in_buffer + single_header_size];
        // for (section_header_bytes_from_buffer) |byte| {
        //     std.log.warn("{X:0>2}", .{byte});

        // }
        // std.log.warn("eeek\n",.{});
        // const u32_slice = std.mem.bytesAsSlice(u32, section_header_bytes_from_buffer);
        // for (u32_slice) |s| {
        //     const little = std.mem.littleToNative(u32,s);
        //     std.log.warn("{X:0>8} {X:0>8}\n",.{little, s});
        // }

        if (self.is_64bit) {
            section.header64 = std.mem.bytesAsValue(elf.Elf64_Shdr, section_header_bytes_from_buffer).*;
            // std.log.debug("Section Name 64-bit: 0x{X:0>8}", .{section.header64.sh_name});
            // std.log.debug("Section Type 64-bit: 0x{X:0>8}", .{section.header64.sh_type});
            // std.log.debug("Section Flags 64-bit: 0x{X:0>16}", .{section.header64.sh_flags});
            // std.log.debug("Section Address 64-bit: 0x{X:0>16}", .{section.header64.sh_addr});
            // std.log.debug("Section Offset 64-bit: 0x{X:0>16}", .{section.header64.sh_offset});
            // std.log.debug("Section Size 64-bit: 0x{X:0>16}", .{section.header64.sh_size});
            // std.log.debug("Section Link 64-bit: 0x{X:0>8}", .{section.header64.sh_link});
            // std.log.debug("Section Info 64-bit: 0x{X:0>8}", .{section.header64.sh_info});
            // std.log.debug("Section Addralign 64-bit: 0x{X:0>16}", .{section.header64.sh_addralign});
            // std.log.debug("Section Entsize 64-bit: 0x{X:0>16}", .{section.header64.sh_entsize});
            if (self.string_table_data != null) {
                section.name = section.getName();
            }
        } else {
            section.header32 = @as(*const elf.Elf32_Shdr, @ptrFromInt(section_ptr)).*;
            if (self.string_table_data != null) {
                section.name = section.getName();
            }
        }

        self.current_index += 1;
        return section;
    }

    /// Get the string table section - useful to get section names
    pub fn findStringTableSection(self: *ElfSectionIterator) ?ElfSection {
        // Save current state
        const original_index = self.current_index;
        self.current_index = 0;

        // Find the string table section at index tag.shndx
        var section: ?ElfSection = null;
        while (self.next()) |sect| {
            if (self.current_index - 1 == self.tag.shndx) {
                std.log.debug("Found string table section at index {}\n", .{self.current_index - 1});
                section = sect;
                break;
            }
        }

        // Restore iterator state
        self.current_index = original_index;
        return section;
    }
};

/// Represents a single ELF section
pub const ElfSection = struct {
    header32: elf.Elf32_Shdr,
    header64: elf.Elf64_Shdr,
    is_64bit: bool,
    name: ?[]const u8,
    string_table: ?[]const u8,

    /// Get section name if string table is available
    pub fn getName(self: ElfSection) ?[]const u8 {
        const string_table = self.string_table orelse return null;
        const name_offset = if (self.is_64bit) self.header64.sh_name else self.header32.sh_name;

        if (name_offset >= string_table.len) return null;

        // Find the null terminator
        var i: usize = name_offset;
        while (i < string_table.len and string_table[i] != 0) : (i += 1) {}

        return string_table[name_offset..i];
    }

    /// Get section type as a string
    pub fn getTypeString(self: ElfSection) []const u8 {
        const sh_type = if (self.is_64bit) self.header64.sh_type else self.header32.sh_type;

        return switch (sh_type) {
            elf.SHT.NULL => "NULL",
            elf.SHT.PROGBITS => "PROGBITS",
            elf.SHT.SYMTAB => "SYMTAB",
            elf.SHT.STRTAB => "STRTAB",
            elf.SHT.RELA => "RELA",
            elf.SHT.HASH => "HASH",
            elf.SHT.DYNAMIC => "DYNAMIC",
            elf.SHT.NOTE => "NOTE",
            elf.SHT.NOBITS => "NOBITS",
            elf.SHT.REL => "REL",
            elf.SHT.DYNSYM => "DYNSYM",
            else => "UNKNOWN",
        };
    }

    /// Get section data pointer
    pub fn getDataPtr(self: ElfSection) [*]const u8 {
        const offset = if (self.is_64bit) self.header64.sh_offset else self.header32.sh_offset;
        return @ptrFromInt(offset);
    }

    /// Get section data slice if available
    pub fn getData(self: ElfSection) ?[]const u8 {
        const offset = if (self.is_64bit) self.header64.sh_offset else self.header32.sh_offset;
        const size = if (self.is_64bit) self.header64.sh_size else self.header32.sh_size;

        if (offset == 0 or size == 0) return null;

        return @as([*]const u8, @ptrFromInt(offset))[0..@intCast(size)];
    }

    /// Get section flags as a string
    pub fn getFlagsString(self: ElfSection, buffer: []u8) []const u8 {
        const flags = if (self.is_64bit) self.header64.sh_flags else self.header32.sh_flags;
        var pos: usize = 0;

        if (flags & elf.SHF.WRITE != 0) buffer[pos] = 'W';
        pos += 1;
        if (flags & elf.SHF.ALLOC != 0) buffer[pos] = 'A';
        pos += 1;
        if (flags & elf.SHF.EXECINSTR != 0) buffer[pos] = 'X';
        pos += 1;
        if (flags & elf.SHF.MERGE != 0) buffer[pos] = 'M';
        pos += 1;
        if (flags & elf.SHF.STRINGS != 0) buffer[pos] = 'S';
        pos += 1;

        return buffer[0..pos];
    }

    pub fn toMemoryMap(self: ElfSection) types.MemoryMap {
        const addr = if (self.is_64bit) self.header64.sh_addr else self.header32.sh_addr;
        const size = if (self.is_64bit) self.header64.sh_size else self.header32.sh_size;
        const offset = if (self.is_64bit) self.header64.sh_offset else self.header32.sh_offset;

        return types.MemoryMap{
            .virtual = types.MemoryRange{
                .start = addr,
                .end = addr + size,
            },
            .physical =  types.MemoryRange{
                .start = offset,
                .end = offset + size,
            },
        };

    }
};

/// Usage example
pub fn parseElfSections(tag: *const ElfSymbolsTag, is_64bit: bool) void {
    // Create the iterator
    var section_iterator = ElfSectionIterator.init(tag, is_64bit);
    var string_data: []const u8 = undefined;

    // First, find the string table to resolve section names
    if (section_iterator.findStringTableSection()) |string_section| {
        if (string_section.getData()) |string_table| {
            section_iterator.setStringTable(string_table);
            string_data = string_table;
        }
    }

    // Reset and iterate through all sections
    section_iterator.current_index = 0;

    std.log.debug("Section Headers (total: {}):\n", .{tag.num});
    std.log.debug("  [Nr] Name                Type           Address          Offset    Size     Flags\n", .{});

    // var flags_buffer: [8]u8 = [_]u8{' '} ** 8;

    section_iterator = ElfSectionIterator.init(tag, is_64bit);
    var i: usize = 0;
    _ = section_iterator.next();
    while (section_iterator.next()) |section| : (i += 1) {
        const name = section.name orelse "[unknown]";
        const type_str = section.getTypeString();
        // const flags_str = section.getFlagsString(&flags_buffer);
        const flags_str = "aa";

        if (is_64bit) {
            std.log.debug("  [{:2}] {s:<20} {s:<15} {X:0>16} {X:0>8} {X:0>8} {s}\n",
                .{i, name, type_str, section.header64.sh_addr, section.header64.sh_offset,
                 section.header64.sh_size, flags_str});
        } else {
            std.log.debug("  [{:2}] {s:<20} {s:<15} {X:0>8} {X:0>8} {X:0>8} {s}\n",
                .{i, name, type_str, section.header32.sh_addr, section.header32.sh_offset,
                 section.header32.sh_size, flags_str});
        }
    }
}

pub fn littleToNativeInPlace(bytes: []u8) void {
    std.debug.assert(bytes.len % 4 == 0);

    // Ensure alignment for u32
    const aligned_ptr = bytes.ptr;

    // Cast to many-item pointer to u32 (type inferred)
    const u32_ptr: [*]u32 = @alignCast(@ptrCast(aligned_ptr));

    const u32_slice = u32_ptr[0 .. bytes.len / 4];

    for (u32_slice) |*val| {
        val.* = std.mem.littleToNative(u32, val.*);
    }
}
