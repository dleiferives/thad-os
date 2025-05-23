const std = @import("std");
const types = @import("types.zig"); // For PAGE_SIZE
const mem = std.mem; // For memset

// Page Table Entry structure and flags
pub const PageTableEntry = u64;

pub const EntryFlags = struct {
    pub const PRESENT = @as(u64, 1) << 0;
    pub const WRITABLE = @as(u64, 1) << 1;
    pub const USER_ACCESSIBLE = @as(u64, 1) << 2;
    pub const WRITE_THROUGH = @as(u64, 1) << 3;
    pub const CACHE_DISABLED = @as(u64, 1) << 4;
    pub const ACCESSED = @as(u64, 1) << 5; // Set by CPU
    pub const DIRTY = @as(u64, 1) << 6; // Set by CPU (page entries)
    pub const HUGE_PAGE = @as(u64, 1) << 7; // PS bit
    pub const GLOBAL = @as(u64, 1) << 8; // Page entries
    // Bits 9-11 available for software
    pub const NO_EXECUTE = @as(u64, 1) << 63; // If CR4.NXE=1

    pub const ADDRESS_MASK = 0x000F_FFFF_FFFF_F000; // Bits 12-51 for 4KB pages

    pub fn get_address(entry: PageTableEntry) u64 {
        return entry & ADDRESS_MASK;
    }

    pub fn set_address(entry: *PageTableEntry, address: u64) void {
        std.debug.assert((address & ~ADDRESS_MASK) == 0, "Address 0x{x} too large or misaligned for PTE", .{address});
        std.debug.assert((address % types.PAGE_SIZE) == 0, "Address 0x{x} not page aligned", .{address});
        entry.* = (entry.* & ~ADDRESS_MASK) | address;
    }

    pub fn is_present(entry: PageTableEntry) bool {
        return (entry & PRESENT) != 0;
    }

    pub fn is_writable(entry: PageTableEntry) bool {
        return (entry & WRITABLE) != 0;
    }

    pub fn is_user(entry: PageTableEntry) bool {
        return (entry & USER_ACCESSIBLE) != 0;
    }

    pub fn is_huge(entry: PageTableEntry) bool {
        return (entry & HUGE_PAGE) != 0;
    }

    pub fn add_flags(entry: *PageTableEntry, flags_to_add: u64) void {
        // Only apply non-address flags, preserve existing address
        entry.* |= (flags_to_add & ~ADDRESS_MASK);
    }

    pub fn remove_flags(entry: *PageTableEntry, flags_to_remove: u64) void {
        // Only remove non-address flags, preserve existing address
        entry.* &= ~(flags_to_remove & ~ADDRESS_MASK);
    }

    pub fn set_flags(entry: *PageTableEntry, new_flags: u64) void {
        // Preserves address, sets other flags according to new_flags
        const current_address = get_address(entry.*);
        entry.* = current_address | (new_flags & ~ADDRESS_MASK);
    }
};

// Page Table structure (common for PML4, PDPT, PDT, PT)
pub const PAGE_TABLE_ENTRIES = 512;
pub const PageTable = extern struct {
    entries: [PAGE_TABLE_ENTRIES]PageTableEntry,

    pub fn zero(self: *PageTable) void {
        mem.memset(@as([*]u8, @ptrCast(self)), 0, @sizeOf(PageTable));
    }

    // Get a virtual pointer to a page table given its physical address and kernel offset
    pub fn at(phys_addr: u64, kernel_offset: u64) *volatile PageTable {
        std.debug.assert(phys_addr % types.PAGE_SIZE == 0);
        return @ptrFromInt(phys_addr + kernel_offset);
    }
};

// Virtual address to page table indices
pub fn pml4_index(vaddr: u64) u16 { return @truncate((vaddr >> 39) & 0x1FF); }
pub fn pdpt_index(vaddr: u64) u16 { return @truncate((vaddr >> 30) & 0x1FF); }
pub fn pdt_index(vaddr: u64) u16  { return @truncate((vaddr >> 21) & 0x1FF); }
pub fn pt_index(vaddr: u64) u16   { return @truncate((vaddr >> 12) & 0x1FF); }

// CR3 and TLB operations
pub fn get_cr3() u64 {
    var val: u64 = undefined;
    asm volatile ("mov %%cr3, %[val]" : [val] "=r" (val) :: "memory");
    return val;
}

pub fn set_cr3(val: u64) void {
    std.debug.assert(val % types.PAGE_SIZE == 0);
    asm volatile ("mov %[val], %%cr3" :: [val] "r" (val) : "memory");
}

pub fn invlpg(vaddr: u64) void {
    asm volatile ("invlpg (%[addr])" :: [addr] "r" (vaddr) : "memory");
}

// Common errors for paging operations
pub const PagingError = error{
    OutOfMemory,
    PageNotPresent,
    UnexpectedHugePage, // Encountered a huge page where a smaller one was expected during walk
    MappingExists,      // Attempted to map an already mapped page with different properties
    InvalidAddress,
};
