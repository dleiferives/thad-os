pub const std = @import("std");
pub const types = @import("mem/types.zig");
const multiboot = @import("multiboot.zig");
const PageBitField = @import("mem/page_bitfield.zig").PageBitField;
const elf = @import("elf.zig");
const paging = @import("mem/paging.zig");

const log = std.log.scoped(.mem);
const verbose_log = std.log.scoped(.mem_verbose);
const manager_log = std.log.scoped(.mem_manager);
const manager_verbose_log = std.log.scoped(.mem_manager_verbose);

pub export fn memset(dest: [*]u8, value: u8, count: usize) [*]u8 {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        dest[i] = value;
    }
    return dest;
}

pub export fn memcpy(dest: [*]u8, src: [*]const u8, count: usize) [*]u8 {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        dest[i] = src[i];
    }
    return dest;
}

/// The memory manager
/// This handles both the physical and virtual memory
/// their reservations and mappings.
pub const Manager = struct {
    memory_layout: types.MEMORY_LAYOUT,

    /// The list of reserved virtual memory maps
    /// Note: that maps do not have to have a physical range defined,
    /// They can be virtual only.
    reserved_virtual_maps: []types.MemoryMap,

    /// The list of reserved physical ranges
    reserved_physical_ranges: []types.MemoryRange,
    available_physical_ranges: []types.MemoryRange,

    /// The bitfield for the pages
    page_bitfield: PageBitField,

    internal_allocator: std.mem.Allocator,

    pub fn new() Manager {
        verbose_log.info("Creating new memory manager", .{});
        const result = Manager{
            .memory_layout = types.MEMORY_LAYOUT.init(),
            .reserved_virtual_maps = undefined,
            .reserved_physical_ranges = undefined,
            .available_physical_ranges = undefined,
            .internal_allocator = Manager.memory_manager_internal_allocator.allocator(),
            .page_bitfield = undefined,
        };

        return result;
    }

    pub fn init(self: *Manager, multiboot_info: multiboot.Multiboot2Info) !void {
        // TODO @(dleiferives,50b1d32d-0557-4ce9-875c-a5da623b95e7): Add the physical
        // mappings from the multiboot header into the manager and then the ones from the
        // layout ~#
        var r_physical = std.ArrayList(types.MemoryRange).init(self.internal_allocator);
        var a_physical = std.ArrayList(types.MemoryRange).init(self.internal_allocator);
        var a_physical_clean = std.ArrayList(types.MemoryRange).init(self.internal_allocator);
        var r_virtual = std.ArrayList(types.MemoryMap).init(self.internal_allocator);

        var mmap_iter = multiboot_info.getTagTypeIterator(multiboot.TagType.MEMORY_MAP);
        while (mmap_iter.next()) |tag_header| {
            var entry_iterator = multiboot.MemoryMapTag.fromTagHeader(tag_header).getEntryIterator();
            while (entry_iterator.next()) |entry| {
                switch (entry.getType()) {
                    .AVAILABLE => {
                        const range = entry.toRange();
                        a_physical.append(range) catch |err| {
                            std.log.debug("Error appending available physical range: {}\n", .{err});
                        };
                        std.log.debug("Found available physical range: {x} - {x}", .{ range.start, range.end });
                    },
                    else => {
                        const range = entry.toRange();
                        r_physical.append(range) catch |err| {
                            std.log.debug("Error appending reserved physical range: {}\n", .{err});
                        };
                        std.log.debug("Found reserved physical range: {x} - {x}", .{ range.start, range.end });
                    },
                }
            }
        }

        const kv_range = self.memory_layout.rangeFomKernelVirtual();
        const kp_range = self.memory_layout.rangeFomKernelPhysical();

        // Add the kernel virtual range to the reserved virtual maps
        r_virtual.append(types.MemoryMap{
            .virtual = kv_range,
            .physical = kp_range,
        }) catch |err| {
            std.log.debug("Error appending reserved virtual range: {}\n", .{err});
        };
        // should also do the stack



        // go through and add the multiboot elf headers and restrict their locations
        var elf_tag_iterator = multiboot_info.getTagTypeIterator(.ELF_SYMBOLS);

        // Iterate through the ELF tags
        while(elf_tag_iterator.next()) |tag_header|{
            const elf_tag = multiboot.ElfSymbolsTag.fromTagHeader(tag_header);

            // Iterate through the ELF sections
            var elf_section_iterator = elf.ElfSectionIterator.init(elf_tag, true);
            while (elf_section_iterator.next()) |section| {
                const section_map = section.toMemoryMap();
                if (section_map.virtual.get_size() == 0) continue;
                if (section_map.virtual.start != 0) {
                    try r_virtual.append(section_map);
                } else {
                    try r_physical.append(section_map.physical.?);
                }
            }
        }

        std.log.debug("starting cleaning up physical ranges", .{});

        // add back the reserved virtual ranges to the reserved physical ranges
        for (r_virtual.items) |map| {
            if (map.physical) |physical| {
                try r_physical.append(physical);
            }
        }

        // Clean up physical available ranges!
        a_loop: while (a_physical.pop()) |available|  {
            for (r_physical.items) |reserved| {
                if (!available.is_valid()) continue;
                if (!available.overlaps(reserved)) continue;
                // This means that the available range in fact overlaps with a reserved range
                std.log.debug("Found overlapping range: {x} - {x}", .{available.start, available.end});
                std.log.debug("Reserved range: {x} - {x}", .{reserved.start, reserved.end});
                if(available.contains_range(reserved)) {
                    // This means that we completely contain the reserved range
                    // so we need to split the available range into two
                    // and add them back to the available list
                    const start = types.MemoryRange{ .start = available.start, .end = reserved.start };
                    const end = types.MemoryRange{ .start = reserved.end, .end = available.end };
                    try a_physical.append(start);
                    try a_physical.append(end);
                    continue :a_loop;
                }
                const disjoint = available.disjoint(reserved);
                try a_physical.append(disjoint);
                continue :a_loop;
            }
            // If we get here, it means that the available range does not overlap with any reserved range
            // so we can add it to the clean list
            if (available.is_valid()) try a_physical_clean.append(available);
        }
        defer a_physical.deinit();


        self.reserved_virtual_maps = r_virtual.items;
        self.reserved_physical_ranges = r_physical.items;
        self.available_physical_ranges = a_physical_clean.items;

        for (r_virtual.items) |map| {
            std.log.debug("Reserved virtual map: {x} - {x}", .{map.virtual.start, map.virtual.end});
            std.log.debug("Reserved physical map: {x} - {x}", .{map.physical.?.start, map.physical.?.end});
        }
        for (r_physical.items) |range| {
            std.log.debug("Reserved physical range: {x} - {x}", .{range.start, range.end});
        }
        for (a_physical_clean.items) |range| {
            std.log.debug("Available physical range: {x} - {x}", .{range.start, range.end});
        }

        std.log.debug("Starting to create the page bitfield", .{});
        self.page_bitfield = try PageBitField.init(self.internal_allocator, a_physical_clean.items[0..]);
        try self.page_bitfield.reserveRanges(self.reserved_physical_ranges);
        std.log.debug("PageBitField: {} pages", .{self.page_bitfield.pages});
        std.log.debug("PageBitField: {} reserved", .{self.page_bitfield.getReserved()});

    }

    // Owned by the container!
    // TODO @(dleiferives,909b4610-e62d-430f-acf0-c4ae94028c17): Make sure that
    // this is seen globally so it gets linked nicely! ~#
    pub var memory_manager_allocation_buffer: [0x10_0000]u8 = undefined;
    var memory_manager_internal_allocator: std.heap.FixedBufferAllocator = std.heap.FixedBufferAllocator.init(memory_manager_allocation_buffer[0..]);
};


/// The Mapper handles virtual memory operations.
pub const Mapper = struct {
    pml4_phys_addr: u64,
    kernel_offset: u64,
    frame_allocator: *PageBitField, // Physical frame allocator

    const Self = @This();
    const PageTable = paging.PageTable;
    const PageTableEntry = paging.PageTableEntry;
    const EntryFlags = paging.EntryFlags;
    const PagingError = paging.PagingError;

    /// Creates a new Mapper, allocating a new PML4 table.
    /// The frame_allocator must be initialized.
    /// kernel_offset is the higher-half offset for kernel virtual addresses.
    pub fn new(
        allocator: *PageBitField,
        current_kernel_offset: u64,
    ) !Self {
        manager_log.debug("Creating new Mapper", .{});
        const pml4_frame = allocator.allocatePage() orelse {
            manager_log.err("Failed to allocate PML4 frame for new Mapper", .{});
            return PagingError.OutOfMemory;
        };
        manager_log.debug("Allocated PML4 frame at physical 0x{x}", .{pml4_frame});

        // Access the new PML4 via its kernel virtual address to zero it
        const pml4_virt = PageTable.at(pml4_frame, current_kernel_offset);
        pml4_virt.zero();

        return Self{
            .pml4_phys_addr = pml4_frame,
            .kernel_offset = current_kernel_offset,
            .frame_allocator = allocator,
        };
    }

    /// Activates this mapper's page tables by loading its PML4 address into CR3.
    pub fn activate(self: *const Self) void {
        manager_log.debug("Activating page tables with PML4 at 0x{x}", .{self.pml4_phys_addr});
        paging.set_cr3(self.pml4_phys_addr);
    }

    /// Gets the physical address of the currently active PML4 from CR3.
    pub fn currentPml4Address() u64 {
        return paging.get_cr3() & EntryFlags.ADDRESS_MASK;
    }

    /// Creates a Mapper instance from the currently active PML4 (read from CR3).
    /// Useful for taking over paging from the bootloader.
    pub fn from_current_cr3(
        allocator: *PageBitField,
        current_kernel_offset: u64,
    ) Self {
        manager_log.debug("Creating Mapper from current CR3", .{});
        const current_pml4 = Self.currentPml4Address();
        return Self{
            .pml4_phys_addr = current_pml4,
            .kernel_offset = current_kernel_offset,
            .frame_allocator = allocator,
        };
    }

    /// Internal helper to walk page tables to find the Page Table Entry (PTE) for a 4KB page.
    /// If `create` is true, intermediate page tables (PDPT, PDT, PT) will be allocated if not present.
    /// Returns a pointer to the PTE.
    fn walk_to_pte(
        self: *Self,
        vaddr: u64,
        create: bool,
    ) PagingError!*volatile PageTableEntry {
        std.debug.assert(vaddr % types.PAGE_SIZE == 0, "Virtual address 0x{x} not page aligned for walk_to_pte", .{vaddr});

        const pml4 = PageTable.at(self.pml4_phys_addr, self.kernel_offset);
        const pml4e_idx = paging.pml4_index(vaddr);
        const pml4e = &pml4.entries[pml4e_idx];

        if (!EntryFlags.is_present(pml4e.*)) {
            if (!create) return PagingError.PageNotPresent;
            const pdpt_frame = self.frame_allocator.allocatePage() orelse return PagingError.OutOfMemory;
            PageTable.at(pdpt_frame, self.kernel_offset).zero();
            EntryFlags.set_address(&pml4e.*, pdpt_frame);
            EntryFlags.add_flags(&pml4e.*, EntryFlags.PRESENT | EntryFlags.WRITABLE | EntryFlags.USER_ACCESSIBLE); // Permissive for intermediate
        }
        // This walk is for 4KB pages, so higher-level huge pages are an issue here.
        if (EntryFlags.is_huge(pml4e.*)) return PagingError.UnexpectedHugePage;

        const pdpt_phys = EntryFlags.get_address(pml4e.*);
        const pdpt = PageTable.at(pdpt_phys, self.kernel_offset);
        const pdpte_idx = paging.pdpt_index(vaddr);
        const pdpte = &pdpt.entries[pdpte_idx];

        if (!EntryFlags.is_present(pdpte.*)) {
            if (!create) return PagingError.PageNotPresent;
            const pdt_frame = self.frame_allocator.allocatePage() orelse return PagingError.OutOfMemory;
            PageTable.at(pdt_frame, self.kernel_offset).zero();
            EntryFlags.set_address(&pdpte.*, pdt_frame);
            EntryFlags.add_flags(&pdpte.*, EntryFlags.PRESENT | EntryFlags.WRITABLE | EntryFlags.USER_ACCESSIBLE);
        }
        if (EntryFlags.is_huge(pdpte.*)) return PagingError.UnexpectedHugePage;

        const pdt_phys = EntryFlags.get_address(pdpte.*);
        const pdt = PageTable.at(pdt_phys, self.kernel_offset);
        const pdte_idx = paging.pdt_index(vaddr);
        const pdte = &pdt.entries[pdte_idx];

        if (!EntryFlags.is_present(pdte.*)) {
            if (!create) return PagingError.PageNotPresent;
            const pt_frame = self.frame_allocator.allocatePage() orelse return PagingError.OutOfMemory;
            PageTable.at(pt_frame, self.kernel_offset).zero();
            EntryFlags.set_address(&pdte.*, pt_frame);
            EntryFlags.add_flags(&pdte.*, EntryFlags.PRESENT | EntryFlags.WRITABLE | EntryFlags.USER_ACCESSIBLE);
        }
        if (EntryFlags.is_huge(pdte.*)) return PagingError.UnexpectedHugePage;

        const pt_phys = EntryFlags.get_address(pdte.*);
        const pt = PageTable.at(pt_phys, self.kernel_offset);
        const pte_idx = paging.pt_index(vaddr);
        return &pt.entries[pte_idx];
    }

    /// Maps a 4KB virtual page to a 4KB physical frame.
    /// vaddr: The virtual address of the page to map (must be 4KB aligned).
    /// paddr: The physical address of the frame to map to (must be 4KB aligned).
    /// page_flags: PageTableEntry flags (e.g., WRITABLE, USER_ACCESSIBLE, NO_EXECUTE). PRESENT is added automatically.
    pub fn map_page(
        self: *Self,
        vaddr: u64,
        paddr: u64,
        page_flags: u64, // Flags like WRITABLE, USER_ACCESSIBLE, NO_EXECUTE
    ) PagingError!void {
        manager_verbose_log.debug("map_page: vaddr=0x{x:0>16}, paddr=0x{x:0>16}, flags=0x{x}", .{ vaddr, paddr, page_flags });
        std.debug.assert(vaddr % types.PAGE_SIZE == 0, "Virtual address 0x{x} not page aligned", .{vaddr});
        std.debug.assert(paddr % types.PAGE_SIZE == 0, "Physical address 0x{x} not page aligned", .{paddr});

        const pte = try self.walk_to_pte(vaddr, true);

        if (EntryFlags.is_present(pte.*) and EntryFlags.get_address(pte.*) != paddr) {
            manager_log.warn("map_page: vaddr 0x{x:0>16} already mapped to 0x{x:0>16}, requested new map to 0x{x:0>16}", .{ vaddr, EntryFlags.get_address(pte.*), paddr });
            // Decide on policy: error out or overwrite. For now, we overwrite.
            // return PagingError.MappingExists;
        }

        EntryFlags.set_address(&pte.*, paddr);
        // Combine flags: ensure PRESENT is set, add user-provided flags (excluding address part).
        const final_flags = EntryFlags.PRESENT | (page_flags & ~EntryFlags.ADDRESS_MASK);
        EntryFlags.set_flags(&pte.*, final_flags);

        paging.invlpg(vaddr); // Invalidate TLB for this page
        manager_verbose_log.debug("Mapped 0x{x:0>16} -> 0x{x:0>16} with PTE 0x{x:0>16}", .{ vaddr, paddr, pte.* });
    }

    /// Unmaps a 4KB virtual page.
    /// vaddr: The virtual address of the page to unmap (must be 4KB aligned).
    pub fn unmap_page(self: *Self, vaddr: u64) PagingError!void {
        manager_verbose_log.debug("unmap_page: vaddr=0x{x:0>16}", .{vaddr});
        std.debug.assert(vaddr % types.PAGE_SIZE == 0, "Virtual address 0x{x} not page aligned for unmap", .{vaddr});

        const pte = self.walk_to_pte(vaddr, false) catch |err| {
            if (err == PagingError.PageNotPresent) {
                // Page or one of its parent tables isn't present, so it's effectively unmapped.
                manager_verbose_log.debug("Page 0x{x:0>16} or parent table not present, already considered unmapped.", .{vaddr});
                return; // Not an error to unmap something not present/already unmapped.
            }
            return err;
        };

        if (!EntryFlags.is_present(pte.*)) {
            manager_verbose_log.debug("Page 0x{x:0>16} PTE already marked not present.", .{vaddr});
            return; // Already unmapped at the PTE level.
        }

        pte.* = 0; // Clear the entry (marks as not present and clears other flags/address).
        paging.invlpg(vaddr); // Invalidate TLB.

        // TODO: Advanced: Consider freeing parent page tables if they become empty.
        // This requires reference counting or iterating through all 512 entries
        // of the parent table to see if it's now empty. For simplicity, this is skipped.
        manager_verbose_log.debug("Unmapped 0x{x:0>16}", .{vaddr});
    }

    /// Translates a virtual address to its corresponding physical address.
    /// Returns `null` if the address is not mapped or if an unexpected huge page
    /// configuration is encountered that this simple translation doesn't handle for 4KB pages.
    pub fn translate(self: *const Self, vaddr: u64) ?u64 {
        // manager_verbose_log.debug("translate: vaddr=0x{x:0>16}", .{vaddr});
        const pml4 = PageTable.at(self.pml4_phys_addr, self.kernel_offset);
        const pml4e = pml4.entries[paging.pml4_index(vaddr)];
        if (!EntryFlags.is_present(pml4e)) return null;

        if (EntryFlags.is_huge(pml4e)) { // 1GB page
            // manager_verbose_log.debug("Translate: 1GB page at PML4 for vaddr 0x{x:0>16}", .{vaddr});
            return (EntryFlags.get_address(pml4e) & ~(@as(u64, 0x3FFF_FFFF))) | (vaddr & 0x3FFF_FFFF);
        }

        const pdpt_phys = EntryFlags.get_address(pml4e);
        const pdpt = PageTable.at(pdpt_phys, self.kernel_offset);
        const pdpte = pdpt.entries[paging.pdpt_index(vaddr)];
        if (!EntryFlags.is_present(pdpte)) return null;

        if (EntryFlags.is_huge(pdpte)) { // 2MB page
            // manager_verbose_log.debug("Translate: 2MB page at PDPT for vaddr 0x{x:0>16}", .{vaddr});
            return (EntryFlags.get_address(pdpte) & ~(@as(u64, 0x1F_FFFF))) | (vaddr & 0x1F_FFFF);
        }

        const pdt_phys = EntryFlags.get_address(pdpte);
        const pdt = PageTable.at(pdt_phys, self.kernel_offset);
        const pdte = pdt.entries[paging.pdt_index(vaddr)];
        if (!EntryFlags.is_present(pdte)) return null;

        // Note: The PS (Page Size) bit in a PDE (Page Directory Entry) indicates a 2MB page.
        // If it's set, this PDE maps a 2MB page, and there's no PT.
        // The bootloader uses this for the initial 1GB mapping.
        if (EntryFlags.is_huge(pdte)) { // This is a 2MB page mapped by the PDT entry
            // manager_verbose_log.debug("Translate: 2MB page at PDT for vaddr 0x{x:0>16}", .{vaddr});
            return (EntryFlags.get_address(pdte) & ~(@as(u64, 0x1F_FFFF))) | (vaddr & 0x1F_FFFF);
        }

        const pt_phys = EntryFlags.get_address(pdte);
        const pt = PageTable.at(pt_phys, self.kernel_offset);
        const pte = pt.entries[paging.pt_index(vaddr)];
        if (!EntryFlags.is_present(pte)) return null;

        // PTEs (Page Table Entries) themselves don't have a HUGE_PAGE bit that means "this is a page".
        // The HUGE_PAGE bit (PS) is in PDE or PDPTE.
        if (EntryFlags.is_huge(pte)) {
            // This case should ideally not happen if the above checks are correct for 4-level to 4KB pages.
            manager_log.warn("Translate: PTE for vaddr 0x{x:0>16} has HUGE_PAGE set. This is unexpected.", .{vaddr});
            return null;
        }

        const paddr_final = EntryFlags.get_address(pte) | (vaddr & 0xFFF); // Add page offset for 4KB page
        // manager_verbose_log.debug("Translate: 0x{x:0>16} -> 0x{x:0>16} (4KB page)", .{vaddr, paddr_final});
        return paddr_final;
    }

    /// Sets up initial kernel mappings. This is crucial after taking over CR3.
    /// It ensures the kernel can access physical memory (especially for new page tables)
    /// and other essential regions like VGA.
    pub fn initial_kernel_map(
        self: *Self,
        layout: *const types.MEMORY_LAYOUT,
    ) !void {
        _ = layout;
        manager_log.info("Running initial_kernel_map for Mapper.", .{});

        // Map VGA buffer (0xB8000 physical) to KERNEL_OFFSET + 0xB8000 virtual
        // This is often identity-mapped by bootloader in higher-half for first 1GB.
        const vga_phys: u64 = 0xB8000;
        const vga_virt = vga_phys + self.kernel_offset;
        if (self.translate(vga_virt) == null) {
            manager_log.debug("Initial map: VGA phys 0x{x} to virt 0x{x}", .{ vga_phys, vga_virt });
            try self.map_page(
                vga_virt,
                vga_phys,
                EntryFlags.WRITABLE, // Kernel Read-Write
            );
        } else {
            manager_verbose_log.debug("VGA virt 0x{x} already mapped.", .{vga_virt});
        }

        // Map all physical memory ranges known to the frame allocator.
        // This ensures the kernel can write to allocated page table frames when they are
        // accessed via kernel_offset + physical_address.
        // The bootloader already maps the kernel's code/data (within the first 1GB phys)
        // to the higher half. This loop ensures other PMM-managed regions are also accessible.
        for (self.frame_allocator.ranges) |phys_range| {
            var current_phys_addr = std.mem.alignForward(u64, phys_range.start, types.PAGE_SIZE);
            const range_end_aligned = std.mem.alignBackward(u64, phys_range.end, types.PAGE_SIZE);

            while (current_phys_addr < range_end_aligned) : (current_phys_addr += types.PAGE_SIZE) {
                const target_virt_addr = current_phys_addr + self.kernel_offset;

                // Check if already mapped. The bootloader maps the first 1GB of physical memory
                // to KERNEL_OFFSET + phys_addr using 2MB pages.
                // Our translate function should correctly identify these.
                if (self.translate(target_virt_addr) == null) {
                    // manager_verbose_log.debug("Initial map: phys 0x{x:0>16} to virt 0x{x:0>16}", .{ current_phys_addr, target_virt_addr });
                    try self.map_page(
                        target_virt_addr,
                        current_phys_addr,
                        EntryFlags.WRITABLE | EntryFlags.NO_EXECUTE, // Kernel RW, NX for general RAM
                    );
                } else {
                    // It's already mapped. Could verify it maps to current_phys_addr if needed.
                    // manager_verbose_log.debug("Skipping map, virt 0x{x:0>16} already mapped.", .{target_virt_addr});
                }
            }
        }
        manager_log.info("Initial kernel mappings check/setup complete.", .{});
    }
};
