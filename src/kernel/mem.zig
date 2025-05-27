pub const std = @import("std");
pub const types = @import("mem/types.zig");
pub const allocator = @import("mem/allocator.zig");
const multiboot = @import("multiboot.zig");
const PageBitField = @import("mem/page_bitfield.zig").PageBitField;
const elf = @import("elf.zig");

const log = std.log.scoped(.mem);
const verbose_log = std.log.scoped(.mem_verbose);
const manager_log = std.log.scoped(.mem_manager);
const manager_verbose_log = std.log.scoped(.mem_manager_verbose);
const mapper_log = std.log.scoped(.mem_manager_mapper);
const mapper_verbose_log = std.log.scoped(.mem_manager_mapper_verbose);
const mapper_translate_log = std.log.scoped(.mem_manager_mapper_translate);

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

    mapper: ?Mapper = null,

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
            .mapper = null,
            .page_bitfield = undefined,
        };

        return result;
    }

    pub fn init(self: *Manager, multiboot_info: multiboot.Multiboot2Info) !void {
        manager_log.info("Initializing memory manager", .{});
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
                            manager_verbose_log.debug("Error appending available physical range: {}\n", .{err});
                        };
                        manager_verbose_log.debug("Found available physical range: {x} - {x}", .{ range.start, range.end });
                    },
                    else => {
                        const range = entry.toRange();
                        r_physical.append(range) catch |err| {
                            manager_verbose_log.debug("Error appending reserved physical range: {}\n", .{err});
                        };
                        manager_verbose_log.debug("Found reserved physical range: {x} - {x}", .{ range.start, range.end });
                    },
                }
            }
        }

        const kv_range = self.memory_layout.rangeFomKernelVirtual();
        const kp_range = self.memory_layout.rangeFomKernelPhysical();

        // Add the kernel virtual range to the reserved virtual maps
        try r_virtual.append(types.MemoryMap{
            .virtual = kv_range,
            .physical = kp_range,
        });
        // should also do the stack

        // go through and add the multiboot elf headers and restrict their locations
        var elf_tag_iterator = multiboot_info.getTagTypeIterator(.ELF_SYMBOLS);

        // Iterate through the ELF tags
        while (elf_tag_iterator.next()) |tag_header| {
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

        manager_log.debug("Starting cleaning up physical ranges", .{});

        // add back the reserved virtual ranges to the reserved physical ranges
        for (r_virtual.items) |map| {
            if (map.physical) |physical| {
                try r_physical.append(physical);
            }
        }

        // Clean up physical available ranges!
        a_loop: while (a_physical.pop()) |available| {
            for (r_physical.items) |reserved| {
                if (!available.is_valid()) continue;
                if (!available.overlaps(reserved)) continue;
                // This means that the available range in fact overlaps with a reserved range
                manager_verbose_log.debug("Found overlapping range: {x} - {x}", .{ available.start, available.end });
                manager_verbose_log.debug("Reserved range: {x} - {x}", .{ reserved.start, reserved.end });
                if (available.contains_range(reserved)) {
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
            manager_log.debug("Reserved virtual map: {x} - {x}", .{ map.virtual.start, map.virtual.end });
            manager_log.debug("Reserved physical map: {x} - {x}", .{ map.physical.?.start, map.physical.?.end });
        }
        for (r_physical.items) |range| {
            manager_log.debug("Reserved physical range: {x} - {x}", .{ range.start, range.end });
        }
        for (a_physical_clean.items) |range| {
            manager_log.debug("Available physical range: {x} - {x}", .{ range.start, range.end });
        }

        manager_log.debug("Starting to create the page bitfield", .{});
        self.page_bitfield = try PageBitField.init(self.internal_allocator, a_physical_clean.items[0..]);
        try self.page_bitfield.reserveRanges(self.reserved_physical_ranges);

        manager_log.info("Page bitfield created with {} pages and {} reserved ", .{self.page_bitfield.pages, self.page_bitfield.getReserved()});

        manager_log.info("Starting to create the Mapper", .{});
        // #1 - Get the current page table, and figure out if its  physical or virtual address.
        const current_page_table_add: u64 = Mapper.currentPML4();
        std.log.debug("The current page table is 0x{X:0>16}", .{current_page_table_add});
        const cpt: *PageMapLevel4 = @ptrFromInt(current_page_table_add | self.memory_layout.kernel_virtual_address_start);
        cpt.log();

        const pmask_4k = PAGE_MASK_4K;

        // // Create a new address space (PML4)
        var new_mapper = try Mapper.create(&self.page_bitfield, self.memory_layout.kernel_offset);
        self.mapper = new_mapper; // Assign to manager's mapper field
        manager_log.info("New Mapper created.", .{});

        // --- Map essential kernel regions into the new_mapper ---
        manager_log.info("Mapping kernel regions into new address space...", .{});
        var current_phys: u64 = 0;
        var current_virt = self.memory_layout.kernel_offset;
        // Kernel code is executable, data is not. For simplicity, map all as R/W, X for code.
        // A more granular approach would map sections with different flags.
        const kernel_code_data_flags = PageFlags{ .present = true, .writable = true, .execute_disable = false }; // A general kernel flag

        while ( true ) {
            // TODO @(dleiferives,fd0a8391-a09e-413c-83f1-43d17b535c6f): Remove
            // the hacky solution to gettig the kernel to load properly by just
            // loading an additional meg ontop! ~#
            if (current_phys > self.memory_layout.kernel_physical_address_end + (12 * 1024 * 1024)) {
                if (self.page_bitfield.largestFreePage()) |largest_page| {
                    if (current_phys > largest_page) {
                        manager_log.err("Physical address 0x{x} is larger than largest free page 0x{x}", .{current_phys, largest_page});
                        break;
                    }
                } else {
                    break;
                }
            }
            // Align to page boundaries for mapping
            const aligned_virt = current_virt & ~pmask_4k;
            const aligned_phys = current_phys & ~pmask_4k;
            // Check if already mapped by a previous iteration if ranges overlap due to alignment
            if (new_mapper.translate(aligned_virt) == null) {
                manager_verbose_log.debug("Could not translate virtual address to physical address", .{});
                try new_mapper.map(aligned_virt, aligned_phys, kernel_code_data_flags);
            }
            current_phys += PAGE_SIZE_4K;
            current_virt += PAGE_SIZE_4K;
        }
        manager_log.info("Kernel regions mapped (approx range phys: 0x{x}-0x{x} to virt: 0x{x}-0x{x}).", .{
            self.memory_layout.kernel_physical_address_start, self.memory_layout.kernel_physical_address_end,
            self.memory_layout.kernel_virtual_address_start,  self.memory_layout.kernel_virtual_address_end,
        });

        // // Map VGA buffer
        // const vga_phys_addr: u64 = 0xB8000;
        // // The virtual address for VGA depends on how the kernel expects to access it.
        // // Often it's kernel_offset + physical_address.
        // const vga_virt_addr: u64 = vga_phys_addr + self.memory_layout.kernel_offset;
        // const vga_flags = PageFlags{ .present = true, .writable = true, .cache_disable = false, .execute_disable = false};
        // try new_mapper.map(vga_virt_addr, vga_phys_addr, vga_flags);
        // manager_log.info("VGA buffer mapped: phys 0x{x} to virt 0x{x}", .{ vga_phys_addr, vga_virt_addr });

        // Map the Multiboot Information Structure
        var mbi_ptr_raw: u64 = undefined;
        asm volatile ( // Get physical address of MBI stored by bootloader assembly
            \\ movabs $multiboot_info_ptr, %%rcx
            \\ mov (%%rcx), %%rcx
            : [_] "={rcx}" (mbi_ptr_raw),
        );
        const mbi_phys_start_aligned = mbi_ptr_raw & ~pmask_4k;
        // Note: multiboot_info.header_ptr from loadInfoHeader is already virtual (kernel_offset | raw_physical)
        // So, the virtual address is simply multiboot_info.header_ptr
        const mbi_actual_virt_start_aligned = @intFromPtr(multiboot_info.header_ptr) & ~pmask_4k;

        var current_mbi_map_offset: u64 = 0;
        const mbi_total_size = multiboot_info.header_ptr.total_size;
        const mbi_map_flags = PageFlags{ .writable = false, .execute_disable = true }; // Read-only
        manager_log.info("Mapping Multiboot info (phys_base: 0x{x}, virt_base: 0x{x}, size: {})", .{ mbi_phys_start_aligned, mbi_actual_virt_start_aligned, mbi_total_size });
        while (current_mbi_map_offset < mbi_total_size) {
            const map_virt = mbi_actual_virt_start_aligned + current_mbi_map_offset;
            const map_phys = mbi_phys_start_aligned + current_mbi_map_offset;
            if (new_mapper.translate(map_virt) == null) { // Avoid remapping if part of kernel image
                manager_verbose_log.err("Failed to allocate PT frame for new Mapper", .{});
                try new_mapper.map(map_virt, map_phys, mbi_map_flags);
            }
            current_mbi_map_offset += PAGE_SIZE_4K;
        }
        manager_log.info("Multiboot info mapped.", .{});

        // Map the memory_manager_allocation_buffer (where PMM's internal allocator state might be)
        // This buffer is likely in .bss, so its physical backing needs to be mapped to its virtual address.
        const mma_buffer_virt_start = @intFromPtr(&memory_manager_allocation_buffer);
        const mma_buffer_phys_start = mma_buffer_virt_start - self.memory_layout.kernel_offset; // Assuming it's in higher half
        var mma_offset: u64 = 0;
        manager_log.info("Mapping memory_manager_allocation_buffer (virt: 0x{x}, phys: 0x{x}, size: 0x{x})", .{ mma_buffer_virt_start, mma_buffer_phys_start, @sizeOf(@TypeOf(memory_manager_allocation_buffer)) });
        while (mma_offset < @sizeOf(@TypeOf(memory_manager_allocation_buffer))) {
            const map_virt = (mma_buffer_virt_start + mma_offset) & ~pmask_4k;
            const map_phys = (mma_buffer_phys_start + mma_offset) & ~pmask_4k;
            if (new_mapper.translate(map_virt) == null) {
                manager_verbose_log.err("Page already mapped", .{});
                try new_mapper.map(map_virt, map_phys, PageFlags{ .writable = true, .execute_disable = true });
            }
            mma_offset += PAGE_SIZE_4K;
        }
        manager_log.info("memory_manager_allocation_buffer mapped.", .{});
        const pml4_virt: *PageMapLevel4 = @ptrFromInt(new_mapper.pml4_phys_addr | self.memory_layout.kernel_offset);
        pml4_virt.log_all(self.memory_layout.kernel_offset);

        // After all essential mappings are done for the new_mapper:
        Mapper.loadPML4(new_mapper.pml4_phys_addr);
        manager_log.info("New PML4 (0x{x}) loaded into CR3.", .{new_mapper.pml4_phys_addr});

        // Test translation with the new mapper
        const test_virt_addr = self.memory_layout.kernel_virtual_address_start;
        if (new_mapper.translate(test_virt_addr)) |translated_phys_addr| {
            manager_log.info("Post-load test translation: virt 0x{x} -> phys 0x{x} (expected phys 0x{x})", .{ test_virt_addr, translated_phys_addr, self.memory_layout.kernel_physical_address_start + (test_virt_addr & pmask_4k) });
            if ((translated_phys_addr & ~pmask_4k) != (self.memory_layout.kernel_physical_address_start & ~pmask_4k)) {
                manager_log.err("Post-load translation mismatch!", .{});
            }
        } else {
            manager_log.err("Post-load test translation failed for virt 0x{x}", .{test_virt_addr});
        }
    }

    // Owned by the container!
    // TODO @(dleiferives,909b4610-e62d-430f-acf0-c4ae94028c17): Make sure that
    // this is seen globally so it gets linked nicely! ~#
    pub var memory_manager_allocation_buffer: [0x10_0000]u8 = undefined;
    var memory_manager_internal_allocator: std.heap.FixedBufferAllocator = std.heap.FixedBufferAllocator.init(memory_manager_allocation_buffer[0..]);
};

// In ./src/kernel/mem.zig

// Add these definitions at the top of the file or in a relevant section.
// (Make sure to place it before the existing `Manager` struct or adjust imports if moved to a new file)

const PageMapLevel4 = extern struct {
    entries: [PAGE_TABLE_ENTRY_COUNT]u64,

    pub fn deVoltaile(self: *volatile PageMapLevel4) *PageMapLevel4 {
        var ptr: usize = @intFromPtr(self);
        _ = &ptr;
        return @ptrFromInt(ptr);
    }
    pub fn log(self: *PageMapLevel4) void {
        const n_entries = tester: {
            var number_of_entries: usize = 0;
            for (0..PAGE_TABLE_ENTRY_COUNT) |i| {
                const entry = self.entries[i];
                const flags = PageFlags.from_bits(entry);
                if (flags.present) {
                    number_of_entries += 1;
                }
            }
            break :tester number_of_entries;
        };
        manager_log.info("The number of directory pointers in map is {}",.{n_entries});
        var iter = self.iterator();
        while (iter.next()) |entry| {
            const flags = PageFlags.from_bits(entry);
            if (flags.present) {
                manager_log.info("{d:0>3}: 0x{X:0>16}", .{iter.index - 1, entry});
            }
        }
    }

    pub fn log_all(self: *PageMapLevel4, kernel_offset: u64) void {
        var pm4_iter = self.iterator();
        while (pm4_iter.next()) |entry| {
            const flags = PageFlags.from_bits(entry);
            if (flags.present) {
                const phys_addr = entry & PTE_ADDR_MASK;
                const virt_addr = phys_addr + kernel_offset;
                const pm3_ptr: *PageDirectoryPointerTable = @ptrFromInt(virt_addr);
                var pm3_iter = pm3_ptr.iterator();
                while (pm3_iter.next()) |pm3_entry| {
                    const pm3_flags = PageFlags.from_bits(pm3_entry);
                    if (pm3_flags.present) {
                        const pm2_phys_addr = pm3_entry & PTE_ADDR_MASK;
                        const pm2_virt_addr = pm2_phys_addr + kernel_offset;
                        const pm2_ptr: *PageDirectory = @ptrFromInt(pm2_virt_addr);
                        var pm2_iter = pm2_ptr.iterator();
                        while (pm2_iter.next()) |pm2_entry| {
                            const pm2_flags = PageFlags.from_bits(pm2_entry);
                            if (pm2_flags.present) {
                                const pt_phys_addr = pm2_entry & PTE_ADDR_MASK;
                                const pt_virt_addr = pt_phys_addr + kernel_offset;
                                const pt_ptr: *PageTable = @ptrFromInt(pt_virt_addr);
                                var pt_iter = pt_ptr.iterator();
                                while (pt_iter.next()) |pt_entry| {
                                    const pt_flags = PageFlags.from_bits(pt_entry);
                                    if (pt_flags.present) {
                                        const _phys_addr = pt_entry & PTE_ADDR_MASK;
                                        const _virt_addr = virtFromIndexs(pm4_iter.index - 1, pm3_iter.index - 1, pm2_iter.index - 1, pt_iter.index - 1);
                                        manager_verbose_log.info("0x{X:0>16} -> 0x{X:0>16}", .{
                                            _virt_addr, _phys_addr});
                                        manager_verbose_log.info("PML4: {d}, PDPT: {d}, PD: {d}, PT: {d}", .{
                                            pm4_iter.index - 1, pm3_iter.index - 1, pm2_iter.index - 1, pt_iter.index - 1
                                        });
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

    }

    pub fn iterator(self: *PageMapLevel4) Iterator {
        return Iterator{ .pointer = self, .index = 0 };
    }

    pub const Iterator = struct {
        pointer: *PageMapLevel4,
        index: usize = 0,

        pub fn next(self: *Iterator) ?u64 {
            if (self.index >= PAGE_TABLE_ENTRY_COUNT) return null;
            const entry = self.pointer.entries[self.index];
            self.index += 1;
            return entry; // Return physical address part
        }

        pub fn nextPresent(self: *Iterator) ?u64 {
            while (self.index < PAGE_TABLE_ENTRY_COUNT) {
                const entry = self.pointer.entries[self.index];
                self.index += 1;
                if (entry & PT_PRESENT != 0) {
                    return entry;
                }
            }
            return null; // No more present entries
        }
    };
};
const PageDirectoryPointerTable = extern struct {
    entries: [PAGE_TABLE_ENTRY_COUNT]u64,

    pub fn deVoltaile(self: *volatile PageDirectoryPointerTable) *PageDirectoryPointerTable {
        var ptr: usize = @intFromPtr(self);
        _ = &ptr;
        return @ptrFromInt(ptr);
    }

    pub fn log(self: *PageDirectoryPointerTable) void {
        const n_entries = tester: {
            var number_of_entries: usize = 0;
            for (0..PAGE_TABLE_ENTRY_COUNT) |i| {
                const entry = self.entries[i];
                const flags = PageFlags.from_bits(entry);
                if (flags.present) {
                    number_of_entries += 1;
                }
            }
            break :tester number_of_entries;
        };
        manager_log.info("The number of directories in directory table is {}",.{n_entries});
        var iter = self.iterator();
        while (iter.next()) |entry| {
            const flags = PageFlags.from_bits(entry);
            if (flags.present) {
                manager_log.info("{d:0>3}: 0x{X:0>16}", .{iter.index - 1, entry});
            }
        }
    }

    pub fn iterator(self: *PageDirectoryPointerTable) Iterator {
        return Iterator{ .pointer = self, .index = 0 };
    }

    pub const Iterator = struct {
        pointer: *PageDirectoryPointerTable,
        index: usize = 0,

        pub fn next(self: *Iterator) ?u64 {
            if (self.index >= PAGE_TABLE_ENTRY_COUNT) return null;
            const entry = self.pointer.entries[self.index];
            self.index += 1;
            return entry; // Return physical address part
        }

        pub fn nextPresent(self: *Iterator) ?u64 {
            while (self.index < PAGE_TABLE_ENTRY_COUNT) {
                const entry = self.pointer.entries[self.index];
                self.index += 1;
                if (entry & PT_PRESENT != 0) {
                    return entry;
                }
            }
            return null; // No more present entries
        }
    };
};
const PageDirectory = extern struct {
    entries: [PAGE_TABLE_ENTRY_COUNT]u64,

    pub fn deVoltaile(self: *volatile PageDirectory) *PageDirectory {
        var ptr: usize = @intFromPtr(self);
        _ = &ptr;
        return @ptrFromInt(ptr);
    }
    pub fn log(self: *PageDirectory) void {
        const n_entries = tester: {
            var number_of_entries: usize = 0;
            for (0..PAGE_TABLE_ENTRY_COUNT) |i| {
                const entry = self.entries[i];
                const flags = PageFlags.from_bits(entry);
                if (flags.present) {
                    number_of_entries += 1;
                }
            }
            break :tester number_of_entries;
        };
        manager_log.info("The number of tables in directory is {}",.{n_entries});
        var iter = self.iterator();
        while (iter.next()) |entry| {
            const flags = PageFlags.from_bits(entry);
            if (flags.present) {
                manager_log.info("{d:0>3}: 0x{X:0>16}", .{iter.index - 1, entry});
            }
        }
    }

    pub fn iterator(self: *PageDirectory) Iterator {
        return Iterator{ .pointer = self, .index = 0 };
    }

    pub const Iterator = struct {
        pointer: *PageDirectory,
        index: usize = 0,

        pub fn next(self: *Iterator) ?u64 {
            if (self.index >= PAGE_TABLE_ENTRY_COUNT) return null;
            const entry = self.pointer.entries[self.index];
            self.index += 1;
            return entry; // Return physical address part
        }

        pub fn nextPresent(self: *Iterator) ?u64 {
            while (self.index < PAGE_TABLE_ENTRY_COUNT) {
                const entry = self.pointer.entries[self.index];
                self.index += 1;
                if (entry & PT_PRESENT != 0) {
                    return entry;
                }
            }
            return null; // No more present entries
        }
    };
};
const PageTable = extern struct {
    entries: [PAGE_TABLE_ENTRY_COUNT]u64,

    pub fn log(self: *PageTable) void {
        const n_entries = tester: {
            var number_of_entries: usize = 0;
            for (0..PAGE_TABLE_ENTRY_COUNT) |i| {
                const entry = self.entries[i];
                const flags = PageFlags.from_bits(entry);
                if (flags.present) {
                    number_of_entries += 1;
                }
            }
            break :tester number_of_entries;
        };
        manager_log.info("The number of entries in table is {}",.{n_entries});
        var iter = self.iterator();
        while (iter.next()) |entry| {
            const flags = PageFlags.from_bits(entry);
            if (flags.present) {
                manager_log.info("{d:0>3}: 0x{X:0>16}", .{iter.index - 1, entry});
            }
        }
    }

    pub fn deVoltaile(self: *volatile PageTable) *PageTable {
        var ptr: usize = @intFromPtr(self);
        _ = &ptr;
        return @ptrFromInt(ptr);
    }


    pub fn iterator(self: *PageTable) Iterator {
        return Iterator{ .pointer = self, .index = 0 };
    }

    pub const Iterator = struct {
        pointer: *PageTable,
        index: usize = 0,

        pub fn next(self: *Iterator) ?u64 {
            if (self.index >= PAGE_TABLE_ENTRY_COUNT) return null;
            const entry = self.pointer.entries[self.index];
            self.index += 1;
            return entry; // Return physical address part
        }

        pub fn nextPresent(self: *Iterator) ?u64 {
            while (self.index < PAGE_TABLE_ENTRY_COUNT) {
                const entry = self.pointer.entries[self.index];
                self.index += 1;
                if (entry & PT_PRESENT != 0) {
                    return entry;
                }
            }
            return null; // No more present entries
        }
    };

};

// Page Table Entry Flags (IA-32e, 64-bit mode)
// Common flags
const PT_PRESENT: u64 = 1 << 0;
const PT_WRITABLE: u64 = 1 << 1;
const PT_USER_ACCESSIBLE: u64 = 1 << 2;
const PT_WRITE_THROUGH: u64 = 1 << 3;
const PT_CACHE_DISABLE: u64 = 1 << 4;
const PT_ACCESSED: u64 = 1 << 5; // Set by hardware
const PT_DIRTY: u64 = 1 << 6; // Set by hardware (PTE, or PDE/PDPE with PS=1)
const PT_PAGE_SIZE: u64 = 1 << 7; // PS bit (for PDE, PDPE indicating 2MB/1GB page)
const PT_GLOBAL: u64 = 1 << 8; // For PTE, or PDE/PDPE with PS=1
// Bits 9-11 are available for OS use
const PT_CUSTOM_0: u64 = 1 << 9;
const PT_CUSTOM_1: u64 = 1 << 10;
const PT_CUSTOM_2: u64 = 1 << 11;
// PAT bits depend on context (PTE vs Large Page)
const PT_PAT_PTE: u64 = 1 << 7; // PAT bit for PTE (if PS=0, reuses PS bit position)
const PT_PAT_LARGE_PAGE: u64 = 1 << 12; // PAT bit for PDE (PS=1, 2MB) or PDPE (PS=1, 1GB)

const PT_EXECUTE_DISABLE: u64 = @as(u64, 1) << 63; // XD bit (if IA32_EFER.NXE=1)

const PAGE_TABLE_ENTRY_COUNT = 512;
pub const PAGE_SIZE_4K: u64 = 4096;
const PAGE_SIZE_2MB: u64 = PAGE_SIZE_4K * 512;
const PAGE_SIZE_1GB: u64 = PAGE_SIZE_2MB * 512;

pub const PAGE_MASK_4K: u64 = PAGE_SIZE_4K - 1;
const PAGE_MASK_2MB: u64 = PAGE_SIZE_2MB - 1;
const PAGE_MASK_1GB: u64 = PAGE_SIZE_1GB - 1;

// Mask to extract the physical address from a page table entry
const PTE_ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000; // Bits 12-51 for 4KB aligned address
const PDE_2MB_ADDR_MASK: u64 = 0x000F_FFFF_FFE0_0000; // Bits 21-51 for 2MB aligned
const PDPE_1GB_ADDR_MASK: u64 = 0x000F_FFFF_C000_0000; // Bits 30-51 for 1GB aligned

// Virtual address parsing helpers
fn pml4Index(virt_addr: u64) usize {
    return @truncate((virt_addr >> 39) & 0x1FF);
}
fn pdptIndex(virt_addr: u64) usize {
    return @truncate((virt_addr >> 30) & 0x1FF);
}
fn pdIndex(virt_addr: u64) usize {
    return @truncate((virt_addr >> 21) & 0x1FF);
}
fn ptIndex(virt_addr: u64) usize {
    return @truncate((virt_addr >> 12) & 0x1FF);
}

pub fn virtFromIndexs(p4: usize, p3: usize, p2: usize, p1: usize) usize {
    const i4_: usize = @truncate(p4 & 0x1FF);
    const i3_: usize = @truncate(p3 & 0x1FF);
    const i2_: usize = @truncate(p2 & 0x1FF);
    const i1_: usize = @truncate(p1 & 0x1FF);

    const header  = if (i4_ & 0x100 == 0) 0 else @as(u64,((@as(u64, 1) << (64 - 48)) - 1)) << 48; // Mask for 48-bit physical addresses
    return header | (i4_ << 39) | (i3_ << 30) | (i2_ << 21) | (i1_ << 12);
}

pub const MapperError = error{
    OutOfMemory,
    PageTableNotPresent, // Indicates an intermediate table was expected but not found
    AddressNotAligned,
    AlreadyMapped,
    NotMapped,
    UnsupportedPageSize, // If trying to operate on large pages with functions not designed for them
};

/// Flags for mapping a page.
const PT_DEMAND_ALLOC: u64 = 1 << 9; // Using PT_CUSTOM_0 for demand allocation bit

// Update PageFlags structure
pub const PageFlags = struct {
    present: bool = true,
    writable: bool = true,
    user_accessible: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    global: bool = false,
    execute_disable: bool = false,
    demand_alloc: bool = false, // NEW: For demand paging

    pub fn to_bits(self: PageFlags) u64 {
        var flags: u64 = if (self.present) PT_PRESENT else 0;
        if (self.writable) flags |= PT_WRITABLE;
        if (self.user_accessible) flags |= PT_USER_ACCESSIBLE;
        if (self.write_through) flags |= PT_WRITE_THROUGH;
        if (self.cache_disable) flags |= PT_CACHE_DISABLE;
        if (self.global) flags |= PT_GLOBAL;
        if (self.execute_disable) flags |= PT_EXECUTE_DISABLE;
        if (self.demand_alloc) flags |= PT_DEMAND_ALLOC; // NEW
        return flags;
    }

    pub fn from_bits(bits: u64) PageFlags {
        return PageFlags{
            .present = (bits & PT_PRESENT) != 0,
            .writable = (bits & PT_WRITABLE) != 0,
            .user_accessible = (bits & PT_USER_ACCESSIBLE) != 0,
            .write_through = (bits & PT_WRITE_THROUGH) != 0,
            .cache_disable = (bits & PT_CACHE_DISABLE) != 0,
            .global = (bits & PT_GLOBAL) != 0,
            .execute_disable = (bits & PT_EXECUTE_DISABLE) != 0,
            .demand_alloc = (bits & PT_DEMAND_ALLOC) != 0, // NEW
        };
    }

    pub fn log(self: PageFlags) void {
        manager_log.debug("PageFlags: present={}, writable={}, user_accessible={}, write_through={}, cache_disable={}, global={}, execute_disable={}, demand_alloc={}",
            .{self.present, self.writable, self.user_accessible, self.write_through, self.cache_disable, self.global, self.execute_disable, self.demand_alloc});
    }
};

// Now, the Mapper struct itself:
pub const Mapper = struct {
    pml4_phys_addr: u64,
    pmm: *PageBitField,
    kernel_offset: u64,

    const Self = @This();

    /// Gets a virtual pointer to a physical page table.
    fn getTableVirtPtr(phys_addr: u64, kernel_offset: u64, comptime T: type) *volatile T {
        // std.debug.assert(phys_addr & PAGE_MASK_4K == 0); // Must be page aligned
        const virt_ptr_val = phys_addr + kernel_offset;
        return @ptrFromInt(virt_ptr_val);
    }

    /// Allocates a new, zeroed page table frame.
    fn allocate_page_table_frame(self: *Self) MapperError!u64 {
        mapper_log.debug("Allocating frame", .{});
        const frame_phys_addr = self.pmm.allocatePage() orelse return MapperError.OutOfMemory;

        // Zero the frame using its virtual address
        const frame_virt_ptr = getTableVirtPtr(frame_phys_addr, self.kernel_offset, [PAGE_TABLE_ENTRY_COUNT]u64);
        for (0..PAGE_TABLE_ENTRY_COUNT) |i| {
            frame_virt_ptr[i] = 0;
        }
        // @memset(@ptrCast(frame_virt_ptr), 0x00, PAGE_SIZE_4K);
        return frame_phys_addr;
    }

    /// Frees a page table frame.
    fn free_page_table_frame(self: *Self, frame_phys_addr: u64) !void {
        try self.pmm.freePage(frame_phys_addr);
    }

    /// Invalidates a single page in the TLB.
    pub fn invlpg(virt_addr: u64) void {
        asm volatile ("invlpg (%[addr])"
            :
            : [addr] "r" (virt_addr),
            : "memory"
        );
    }

    /// Gets the current physical address of the PML4 table from CR3.
    pub fn currentPML4() u64 {
        var val: u64 = undefined;
        asm volatile ("mov %%cr3, %[val]"
            : [val] "=r" (val),
        );
        return val; //& PTE_ADDR_MASK; // CR3 also contains PCID bits if enabled
    }

    /// Loads the given physical address of a PML4 table into CR3.
    pub fn loadPML4(pml4_phys_addr: u64) void {
        // std.debug.assert(pml4_phys_addr & PAGE_MASK_4K == 0);
        mapper_verbose_log.debug("loadding physical address: 0x{x}", .{pml4_phys_addr});

        // TODO: Handle PCID if CR4.PCIDE is set. For now, assume PCID 0.
        asm volatile (
            \\ mov %[addr], %%cr3
            \\ jmp load_pml
            \\ load_pml:
            :
            : [addr] "r" (pml4_phys_addr),
            : "memory"
        );
    }

    /// Initializes a new Mapper with a new, empty PML4 table.
    /// The caller is responsible for populating this new PML4 and then calling `loadPML4`.
    pub fn create(pmm: *PageBitField, kernel_offset: u64) !Self {
        mapper_log.debug("Creating new Mapper instance...", .{});
        var mapper = Self{
            .pml4_phys_addr = 0, // Will be set after allocation
            .pmm = pmm,
            .kernel_offset = kernel_offset,
        };
        mapper.pml4_phys_addr = try mapper.allocate_page_table_frame();
        mapper_verbose_log.debug("New PML4 allocated at physical address: 0x{x}", .{mapper.pml4_phys_addr});
        return mapper;
    }

    /// Initializes a Mapper instance to operate on an existing PML4 table.
    pub fn init_existing(pml4_phys: u64, pmm: *PageBitField, kernel_offset: u64) Self {
        mapper_log.debug("Initializing Mapper with existing PML4 at 0x{x}", .{pml4_phys});
        return Self{
            .pml4_phys_addr = pml4_phys,
            .pmm = pmm,
            .kernel_offset = kernel_offset,
        };
    }

    /// Internal helper: Walks to the next level page table, creating it if necessary.
    /// `parent_entry_virt_ptr`: Virtual pointer to the entry in the parent table (e.g., PML4E).
    /// `entry_flags_for_new_table`: Flags for the parent entry if a new table is created (e.g., PRESENT, WRITABLE).
    /// Returns the physical address of the next level table.
    fn get_or_create_next_table(
        self: *Self,
        parent_entry_virt_ptr: *volatile u64,
        entry_flags_for_new_table: u64,
    ) MapperError!u64 {
        const parent_entry_val = parent_entry_virt_ptr.*;

        if (parent_entry_val & PT_PRESENT != 0) {
            // Table already exists. Ensure it's not a large page entry.
            if (parent_entry_val & PT_PAGE_SIZE != 0) {
                mapper_log.err("get_or_create_next_table: Parent entry 0x{x} points to a large page, not a table.", .{parent_entry_val});
                return MapperError.UnsupportedPageSize;
            }
            return parent_entry_val & PTE_ADDR_MASK;
        } else {
            // Table does not exist, create it.
            const new_table_phys_addr = try self.allocate_page_table_frame();
            std.debug.assert(entry_flags_for_new_table & PT_PRESENT != 0); // New table must be present
            parent_entry_virt_ptr.* = new_table_phys_addr | entry_flags_for_new_table;
            return new_table_phys_addr;
        }
    }

    /// Maps a 4KB virtual page to a 4KB physical frame.
    /// `virt_addr` and `phys_addr` must be 4KB aligned.
    pub fn map(
        self: *Self,
        virt_addr: u64,
        phys_addr: u64,
        page_flags: PageFlags,
    ) MapperError!void {
        if (virt_addr & PAGE_MASK_4K != 0 or phys_addr & PAGE_MASK_4K != 0) {
            mapper_log.err("map: virt_addr 0x{x} or phys_addr 0x{x} not 4K aligned.", .{ virt_addr, phys_addr });
            return MapperError.AddressNotAligned;
        }

        const pml4_idx = pml4Index(virt_addr);
        const pdpt_idx = pdptIndex(virt_addr);
        const pd_idx = pdIndex(virt_addr);
        const pt_idx = ptIndex(virt_addr);

        const pml4_virt = getTableVirtPtr(self.pml4_phys_addr, self.kernel_offset, PageMapLevel4);

        // Flags for intermediate directory entries pointing to other tables.
        // They should be writable if any underlying page is writable,
        // and user-accessible if any underlying page is user-accessible.
        // Always execute-disable for table pointers.
        var table_entry_flags = PT_PRESENT; // | PT_EXECUTE_DISABLE;
        if (page_flags.writable) table_entry_flags |= PT_WRITABLE;
        if (page_flags.user_accessible) table_entry_flags |= PT_USER_ACCESSIBLE;

        // 1. PML4 -> PDPT
        const pdpt_phys_addr = try self.get_or_create_next_table(
            &pml4_virt.entries[pml4_idx],
            table_entry_flags,
        );
        const pdpt_virt = getTableVirtPtr(pdpt_phys_addr, self.kernel_offset, PageDirectoryPointerTable);

        // 2. PDPT -> PD
        const pd_phys_addr = try self.get_or_create_next_table(
            &pdpt_virt.entries[pdpt_idx],
            table_entry_flags,
        );
        const pd_virt = getTableVirtPtr(pd_phys_addr, self.kernel_offset, PageDirectory);

        // 3. PD -> PT
        const pt_phys_addr = try self.get_or_create_next_table(
            &pd_virt.entries[pd_idx],
            table_entry_flags,
        );
        const pt_virt = getTableVirtPtr(pt_phys_addr, self.kernel_offset, PageTable);

        // 4. Set PTE in PT
        const pte_ptr = &pt_virt.entries[pt_idx];
        if (pte_ptr.* & PT_PRESENT != 0) {
            // Page is already mapped. For simplicity, we'll overwrite.
            // A more robust VMM might error or require unmap first.
            manager_log.warn("map: virt_addr 0x{x} already mapped to 0x{x}. Overwriting with 0x{x}.", .{
                virt_addr, pte_ptr.* & PTE_ADDR_MASK, phys_addr,
            });
        }
        mapper_verbose_log.info("mapped (allocated) virt 0x{X:0>16} -> 0x{X:0>16}",.{virt_addr,phys_addr});
        pte_ptr.* = phys_addr | page_flags.to_bits();
        invlpg(virt_addr);
    }

    pub fn mapDemandRange(
        self: *Self,
        start_virt_addr: u64,
        end_virt_addr: u64,
        page_flags: PageFlags,
    ) !bool {
        if (start_virt_addr & PAGE_MASK_4K != 0 or end_virt_addr & PAGE_MASK_4K != 0) {
            mapper_log.err("mapDemandRange: start_virt_addr 0x{x} or end_virt_addr 0x{x} not 4K aligned.", .{start_virt_addr, end_virt_addr});
            return MapperError.AddressNotAligned;
        }
        mapper_log.debug("mapDemandRange: start_virt_addr 0x{x}, end_virt_addr 0x{x}, page_flags: {any}", .{start_virt_addr, end_virt_addr, page_flags});

        if (start_virt_addr >= end_virt_addr) {
            mapper_log.err("mapDemandRange: start address 0x{x} is not less than end address 0x{x}.", .{start_virt_addr, end_virt_addr});
            return false; // No range to map
        }

        // check if the range is already mapped
        // using the translate function
        var current_virt = start_virt_addr;
        while(current_virt <= end_virt_addr) {
            if (self.translate(current_virt)) |phys_addr| {
                mapper_log.warn("mapDemandRange: virt_addr 0x{x} already mapped to 0x{x}.", .{current_virt, phys_addr});
                return MapperError.AlreadyMapped;
            }
            current_virt += PAGE_SIZE_4K;
        }


        current_virt = start_virt_addr;
        while (current_virt <= end_virt_addr) {
            try self.mapDemand(current_virt, page_flags);
            current_virt += PAGE_SIZE_4K;
        }
        return true; // Successfully mapped the range
    }

    /// Maps a virtual page with demand allocation - no physical frame allocated initially
    pub fn mapDemand(
        self: *Self,
        virt_addr: u64,
        page_flags: PageFlags,
    ) MapperError!void {
        if (virt_addr & PAGE_MASK_4K != 0) {
            mapper_log.err("mapDemand: virt_addr 0x{x} not 4K aligned.", .{virt_addr});
            return MapperError.AddressNotAligned;
        }

        const pml4_idx = pml4Index(virt_addr);
        const pdpt_idx = pdptIndex(virt_addr);
        const pd_idx = pdIndex(virt_addr);
        const pt_idx = ptIndex(virt_addr);

        const pml4_virt = getTableVirtPtr(self.pml4_phys_addr, self.kernel_offset, PageMapLevel4);

        // Flags for intermediate directory entries
        var table_entry_flags = PT_PRESENT;
        if (page_flags.writable) table_entry_flags |= PT_WRITABLE;
        if (page_flags.user_accessible) table_entry_flags |= PT_USER_ACCESSIBLE;

        // 1. PML4 -> PDPT
        const pdpt_phys_addr = try self.get_or_create_next_table(
            &pml4_virt.entries[pml4_idx],
            table_entry_flags,
        );
        const pdpt_virt = getTableVirtPtr(pdpt_phys_addr, self.kernel_offset, PageDirectoryPointerTable);
        mapper_verbose_log.debug("mapDemand: PDPT created at 0x{x} for virt_addr 0x{x}", .{pdpt_phys_addr, virt_addr});

        // 2. PDPT -> PD
        const pd_phys_addr = try self.get_or_create_next_table(
            &pdpt_virt.entries[pdpt_idx],
            table_entry_flags,
        );
        const pd_virt = getTableVirtPtr(pd_phys_addr, self.kernel_offset, PageDirectory);
        mapper_verbose_log.debug("mapDemand: PD created at 0x{x} for virt_addr 0x{x}", .{pd_phys_addr, virt_addr});

        // 3. PD -> PT
        const pt_phys_addr = try self.get_or_create_next_table(
            &pd_virt.entries[pd_idx],
            table_entry_flags,
        );
        const pt_virt = getTableVirtPtr(pt_phys_addr, self.kernel_offset, PageTable);
        mapper_verbose_log.debug("mapDemand: PT created at 0x{x} for virt_addr 0x{x}", .{pt_phys_addr, virt_addr});

        // 4. Set PTE for demand allocation
        const pte_ptr = &pt_virt.entries[pt_idx];
        if (pte_ptr.* & PT_PRESENT != 0) {
            mapper_log.warn("mapDemand: virt_addr 0x{x} already mapped.", .{virt_addr});
            return MapperError.AlreadyMapped;
        }
        mapper_verbose_log.debug("mapDemand: Setting PTE for virt_addr 0x{x}", .{virt_addr});

        // Create flags with demand bit set and present bit clear
        var demand_flags = page_flags;
        demand_flags.present = false;  // Not present initially
        demand_flags.demand_alloc = true;  // Mark for demand allocation

        // Set PTE with demand flags and zero physical address
        pte_ptr.* = demand_flags.to_bits();
        mapper_verbose_log.info("mapDemand: virt 0x{X:0>16} marked for demand allocation", .{virt_addr});

        invlpg(virt_addr);
        invlpg(@intFromPtr(pt_virt));
    }

    /// Allocate a page frame for a page fault (MMU_pf_alloc equivalent)
    pub fn allocatePageForFault(self: *Self, virt_addr: u64) MapperError!u64 {
        mapper_log.debug("allocatePageForFault: Allocating page for fault at virt_addr 0x{x}", .{virt_addr});
        const phys_addr = self.pmm.allocatePage() orelse return MapperError.OutOfMemory;

        // Zero the allocated page
        // const page_virt_ptr = getTableVirtPtr(phys_addr, self.kernel_offset, [PAGE_SIZE_4K]u8);
        // @memset(page_virt_ptr, 0);

        mapper_verbose_log.debug("Allocated page frame 0x{x} for fault at virt 0x{x}", .{ phys_addr, virt_addr });
        return phys_addr;
    }

    /// Handle demand page allocation in page fault
    pub fn handleDemandPageFault(self: *Self, virt_addr: u64) MapperError!bool {
        const page_aligned_virt = virt_addr & ~PAGE_MASK_4K;

        const pml4_idx = pml4Index(page_aligned_virt);
        const pdpt_idx = pdptIndex(page_aligned_virt);
        const pd_idx = pdIndex(page_aligned_virt);
        const pt_idx = ptIndex(page_aligned_virt);

        const pml4_virt = getTableVirtPtr(self.pml4_phys_addr, self.kernel_offset, PageMapLevel4);

        // Walk page tables to find the PTE
        const pml4e_val = pml4_virt.entries[pml4_idx];
        // pml4_virt.deVoltaile().log();
        if (pml4e_val & PT_PRESENT == 0) return false;

        const pdpt_phys_addr = pml4e_val & PTE_ADDR_MASK;
        const pdpt_virt = getTableVirtPtr(pdpt_phys_addr, self.kernel_offset, PageDirectoryPointerTable);
        // pdpt_virt.deVoltaile().log();

        const pdpte_val = pdpt_virt.entries[pdpt_idx];
        if (pdpte_val & PT_PRESENT == 0) return false;
        if (pdpte_val & PT_PAGE_SIZE != 0) return false; // Large page

        const pd_phys_addr = pdpte_val & PTE_ADDR_MASK;
        const pd_virt = getTableVirtPtr(pd_phys_addr, self.kernel_offset, PageDirectory);
        // pd_virt.deVoltaile().log();

        const pde_val = pd_virt.entries[pd_idx];
        if (pde_val & PT_PRESENT == 0) return false;
        if (pde_val & PT_PAGE_SIZE != 0) return false; // Large page

        const pt_phys_addr = pde_val & PTE_ADDR_MASK;
        const pt_virt = getTableVirtPtr(pt_phys_addr, self.kernel_offset, PageTable);
        // pt_virt.deVoltaile().log();

        const pte_ptr = &pt_virt.entries[pt_idx];
        const pte_val = pte_ptr.*;

        // PageFlags.from_bits(pte_val).log();



        // Check if this is a demand allocation page
        if ((pte_val & PT_DEMAND_ALLOC) == 0) {
            return false; // Not a demand page
        }

        if (pte_val & PT_PRESENT != 0) {
            return false; // Already allocated
        }

        // Allocate physical page
        std.log.info("Handling demand page fault for virt 0x{X:0>16}", .{page_aligned_virt});
        const phys_addr = try self.allocatePageForFault(page_aligned_virt);

        // Update PTE: clear demand bit, set present bit, set physical address
        var new_flags = PageFlags.from_bits(pte_val);
        new_flags.demand_alloc = false;
        new_flags.present = true;
        new_flags.writable = true; // Assume writable for simplicity, adjust as needed
        new_flags.demand_alloc = false;
        new_flags.execute_disable = false; // Set execute-disable for security

        mapper_verbose_log.debug("Allocating page for demand fault: virt 0x{X:0>16} -> phys 0x{X:0>16}",
            .{ page_aligned_virt, phys_addr });

        pte_ptr.* = phys_addr | new_flags.to_bits();

        invlpg(page_aligned_virt);

        mapper_verbose_log.info("Demand allocated: virt 0x{X:0>16} -> phys 0x{X:0>16}",
                       .{ page_aligned_virt, phys_addr });


        invlpg(page_aligned_virt);
        invlpg(@intFromPtr(pt_virt));
        return true;
    }

    /// Unmaps a 4KB virtual page.
    /// `virt_addr` must be 4KB aligned.
    /// Note: This version does not free underlying page table frames if they become empty.
    pub fn unmap(self: *Self, virt_addr: u64) MapperError!void {
        if (virt_addr & PAGE_MASK_4K != 0) {
            mapper_log.err("unmap: virt_addr 0x{x} not 4K aligned.", .{virt_addr});
            return MapperError.AddressNotAligned;
        }

        const pml4_idx = pml4Index(virt_addr);
        const pdpt_idx = pdptIndex(virt_addr);
        const pd_idx = pdIndex(virt_addr);
        const pt_idx = ptIndex(virt_addr);

        const pml4_virt = getTableVirtPtr(self.pml4_phys_addr, self.kernel_offset, PageMapLevel4);

        // 1. PML4 Entry
        const pml4e_val = pml4_virt.entries[pml4_idx];
        if (pml4e_val & PT_PRESENT == 0) return MapperError.NotMapped;
        if (pml4e_val & PT_PAGE_SIZE != 0) return MapperError.UnsupportedPageSize; // Should be table
        const pdpt_phys_addr = pml4e_val & PTE_ADDR_MASK;
        const pdpt_virt = getTableVirtPtr(pdpt_phys_addr, self.kernel_offset, PageDirectoryPointerTable);

        // 2. PDPT Entry
        const pdpte_val = pdpt_virt.entries[pdpt_idx];
        if (pdpte_val & PT_PRESENT == 0) return MapperError.NotMapped;
        if (pdpte_val & PT_PAGE_SIZE != 0) return MapperError.UnsupportedPageSize; // No 1GB pages here
        const pd_phys_addr = pdpte_val & PTE_ADDR_MASK;
        const pd_virt = getTableVirtPtr(pd_phys_addr, self.kernel_offset, PageDirectory);

        // 3. PD Entry
        const pde_val = pd_virt.entries[pd_idx];
        if (pde_val & PT_PRESENT == 0) return MapperError.NotMapped;
        if (pde_val & PT_PAGE_SIZE != 0) return MapperError.UnsupportedPageSize; // No 2MB pages here
        const pt_phys_addr = pde_val & PTE_ADDR_MASK;
        const pt_virt = getTableVirtPtr(pt_phys_addr, self.kernel_offset, PageTable);

        // 4. PT Entry (PTE)
        const pte_ptr = &pt_virt.entries[pt_idx];
        if (pte_ptr.* & PT_PRESENT == 0) return MapperError.NotMapped;

        pte_ptr.* = 0; // Clear the entry (mark as not present)
        invlpg(virt_addr);

        // TODO: Implement freeing of page table frames if they become empty.
        // This requires checking all entries in pt_virt, pd_virt, pdpt_virt.
    }

    /// Translates a virtual address to its corresponding physical address.
    /// Returns `null` if the address is not mapped or if it encounters an unsupported large page.
    pub fn translate(self: *Self, virt_addr: u64) ?u64 {
        mapper_translate_log.debug("Translating 0x{X}", .{virt_addr});
        const pml4_idx = pml4Index(virt_addr);
        const pdpt_idx = pdptIndex(virt_addr);
        const pd_idx = pdIndex(virt_addr);
        const pt_idx = ptIndex(virt_addr);
        const page_offset = virt_addr & PAGE_MASK_4K;

        const pml4_virt = getTableVirtPtr(self.pml4_phys_addr, self.kernel_offset, PageMapLevel4);
        mapper_translate_log.debug("Virtual address of pml4 is {*}", .{pml4_virt});

        // 1. PML4 Entry
        const pml4e_val = pml4_virt.entries[pml4_idx];
        mapper_translate_log.debug("desired enry is right now 0x{X:0>16}", .{pml4e_val});
        if (pml4e_val & PT_PRESENT == 0) return null;
        if (pml4e_val & PT_PAGE_SIZE != 0) { // Should not happen for PML4E pointing to PDPT
            mapper_translate_log.err("translate: PML4E 0x{x} has PS bit set.", .{pml4e_val});
            return null;
        }
        const pdpt_phys_addr = pml4e_val & PTE_ADDR_MASK;
        const pdpt_virt = getTableVirtPtr(pdpt_phys_addr, self.kernel_offset, PageDirectoryPointerTable);

        // 2. PDPT Entry
        const pdpte_val = pdpt_virt.entries[pdpt_idx];
        if (pdpte_val & PT_PRESENT == 0) return null;
        if (pdpte_val & PT_PAGE_SIZE != 0) { // 1GB Page
            const frame_1gb_addr = pdpte_val & PDPE_1GB_ADDR_MASK;
            return frame_1gb_addr + (virt_addr & PAGE_MASK_1GB);
        }
        const pd_phys_addr = pdpte_val & PTE_ADDR_MASK;
        const pd_virt = getTableVirtPtr(pd_phys_addr, self.kernel_offset, PageDirectory);

        // 3. PD Entry
        const pde_val = pd_virt.entries[pd_idx];
        if (pde_val & PT_PRESENT == 0) return null;
        if (pde_val & PT_PAGE_SIZE != 0) { // 2MB Page
            const frame_2mb_addr = pde_val & PDE_2MB_ADDR_MASK;
            return frame_2mb_addr + (virt_addr & PAGE_MASK_2MB);
        }
        const pt_phys_addr = pde_val & PTE_ADDR_MASK;
        const pt_virt = getTableVirtPtr(pt_phys_addr, self.kernel_offset, PageTable);

        // 4. PT Entry (PTE)
        const pte_val = pt_virt.entries[pt_idx];
        if (pte_val & PT_PRESENT == 0) return null;
        if (pte_val & PT_DEMAND_ALLOC != 0) {
            // Demand allocation page, not present yet
            mapper_translate_log.debug("translate: PTE 0x{x} is demand allocated, not present.", .{pte_val});
            return null;
        }

        // For a PTE pointing to a 4KB page, PS bit (bit 7) must be 0.
        if (pte_val & PT_PAGE_SIZE != 0) {
            mapper_translate_log.err("translate: PTE 0x{x} has PS bit set.", .{pte_val});
            return null;
        }

        const frame_4k_addr = pte_val & PTE_ADDR_MASK;
        return frame_4k_addr + page_offset;
    }
};

// Integration into Manager struct (in src/kernel/mem.zig):
// Add `mapper: Mapper,` to the Manager struct.

// In Manager.new():
// Initialize mapper after PMM and memory_layout are ready.
// This part is a bit tricky because `Manager.new()` might be too early if PMM isn't fully up.
// It's better to initialize `Mapper` within `Manager.init()`.

// Modify Manager.new() to initialize mapper as undefined or an option type.
// For example:
// pub var mapper: ?Mapper = null; // In Manager struct

// Then in Manager.init(self: *Manager, multiboot_info: multiboot.Multiboot2Info) !void:
// ... after self.page_bitfield is initialized ...
//
// // Create a new address space (PML4)
// var new_mapper = try Mapper.create(&self.page_bitfield, self.memory_layout.kernel_offset);
// self.mapper = new_mapper; // Assign to manager's mapper field
// manager_log.info("New Mapper created.", .{});

// // --- Map essential kernel regions into the new_mapper ---
// manager_log.info("Mapping kernel regions into new address space...", .{});
// var current_phys = self.memory_layout.kernel_physical_address_start;
// var current_virt = self.memory_layout.kernel_virtual_address_start;
// // Kernel code is executable, data is not. For simplicity, map all as R/W, X for code.
// // A more granular approach would map sections with different flags.
// const kernel_code_data_flags = PageFlags{ .writable = true, .execute_disable = false }; // A general kernel flag
//
// while (current_phys < self.memory_layout.kernel_physical_address_end) {
//     // Align to page boundaries for mapping
//     const aligned_virt = current_virt & ~PAGE_MASK_4K;
//     const aligned_phys = current_phys & ~PAGE_MASK_4K;
//     // Check if already mapped by a previous iteration if ranges overlap due to alignment
//     if (new_mapper.translate(aligned_virt) == null) {
//          try new_mapper.map(aligned_virt, aligned_phys, kernel_code_data_flags);
//     }
//     current_phys += PAGE_SIZE_4K;
//     current_virt += PAGE_SIZE_4K;
// }
// manager_log.info("Kernel regions mapped (approx range phys: 0x{x}-0x{x} to virt: 0x{x}-0x{x}).", .{
//     self.memory_layout.kernel_physical_address_start, self.memory_layout.kernel_physical_address_end,
//     self.memory_layout.kernel_virtual_address_start, self.memory_layout.kernel_virtual_address_end,
// });

// // Map VGA buffer
// const vga_phys_addr: u64 = 0xB8000;
// // The virtual address for VGA depends on how the kernel expects to access it.
// // Often it's kernel_offset + physical_address.
// const vga_virt_addr: u64 = vga_phys_addr + self.memory_layout.kernel_offset;
// const vga_flags = PageFlags{ .writable = true, .cache_disable = true, .execute_disable = true };
// try new_mapper.map(vga_virt_addr, vga_phys_addr, vga_flags);
// manager_log.info("VGA buffer mapped: phys 0x{x} to virt 0x{x}", .{vga_phys_addr, vga_virt_addr});

// // Map the Multiboot Information Structure
// var mbi_ptr_raw: u64 = undefined;
// asm volatile ( // Get physical address of MBI stored by bootloader assembly
//     "movabs $multiboot_info_ptr, %%rcx\n\t"
//     "mov (%%rcx), %%rcx"
//     : [_] "={rcx}" (mbi_ptr_raw)
// );
// const mbi_phys_start_aligned = mbi_ptr_raw & ~PAGE_MASK_4K;
// const mbi_virt_start_aligned = (multiboot_info.header_ptr + self.memory_layout.kernel_offset) & ~PAGE_MASK_4K;
// // Note: multiboot_info.header_ptr from loadInfoHeader is already virtual (kernel_offset | raw_physical)
// // So, the virtual address is simply multiboot_info.header_ptr
// const mbi_actual_virt_start_aligned = @ptrToInt(multiboot_info.header_ptr) & ~PAGE_MASK_4K;

// var current_mbi_map_offset: u64 = 0;
// const mbi_total_size = multiboot_info.header_ptr.total_size;
// const mbi_map_flags = PageFlags{ .writable = false, .execute_disable = true }; // Read-only
// manager_log.info("Mapping Multiboot info (phys_base: 0x{x}, virt_base: 0x{x}, size: {})", .{
//     mbi_phys_start_aligned, mbi_actual_virt_start_aligned, mbi_total_size});
// while (current_mbi_map_offset < mbi_total_size) {
//     const map_virt = mbi_actual_virt_start_aligned + current_mbi_map_offset;
//     const map_phys = mbi_phys_start_aligned + current_mbi_map_offset;
//     if (new_mapper.translate(map_virt) == null) { // Avoid remapping if part of kernel image
//         try new_mapper.map(map_virt, map_phys, mbi_map_flags);
//     }
//     current_mbi_map_offset += PAGE_SIZE_4K;
// }
// manager_log.info("Multiboot info mapped.", .{});

// // Map the memory_manager_allocation_buffer (where PMM's internal allocator state might be)
// // This buffer is likely in .bss, so its physical backing needs to be mapped to its virtual address.
// const mma_buffer_virt_start = @ptrToInt(&memory_manager_allocation_buffer);
// const mma_buffer_phys_start = mma_buffer_virt_start - self.memory_layout.kernel_offset; // Assuming it's in higher half
// var mma_offset: u64 = 0;
// manager_log.info("Mapping memory_manager_allocation_buffer (virt: 0x{x}, phys: 0x{x}, size: 0x{x})", .{
//     mma_buffer_virt_start, mma_buffer_phys_start, @sizeOf(@TypeOf(memory_manager_allocation_buffer))});
// while (mma_offset < @sizeOf(@TypeOf(memory_manager_allocation_buffer))) {
//     const map_virt = (mma_buffer_virt_start + mma_offset) & ~PAGE_MASK_4K;
//     const map_phys = (mma_buffer_phys_start + mma_offset) & ~PAGE_MASK_4K;
//     if (new_mapper.translate(map_virt) == null) {
//          try new_mapper.map(map_virt, map_phys, PageFlags{ .writable = true, .execute_disable = true });
//     }
//     mma_offset += PAGE_SIZE_4K;
// }
// manager_log.info("memory_manager_allocation_buffer mapped.", .{});

// // After all essential mappings are done for the new_mapper:
// Mapper.loadPML4(new_mapper.pml4_phys_addr);
// manager_log.info("New PML4 (0x{x}) loaded into CR3.", .{new_mapper.pml4_phys_addr});

// // Test translation with the new mapper
// const test_virt_addr = self.memory_layout.kernel_virtual_address_start;
// if (new_mapper.translate(test_virt_addr)) |translated_phys_addr| {
//     manager_log.info("Post-load test translation: virt 0x{x} -> phys 0x{x} (expected phys 0x{x})", .{
//         test_virt_addr, translated_phys_addr, self.memory_layout.kernel_physical_address_start + (test_virt_addr & PAGE_MASK_4K)
//     });
//     if ((translated_phys_addr & ~PAGE_MASK_4K) != (self.memory_layout.kernel_physical_address_start & ~PAGE_MASK_4K)) {
//         manager_log.err("Post-load translation mismatch!", .{});
//     }
// } else {
//     manager_log.err("Post-load test translation failed for virt 0x{x}", .{test_virt_addr});
// }
//
// // At this point, the new address space is active.
