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

var scratch_pdpt: PageTable align(4096) = undefined;
var scratch_pd: PageTable align(4096) = undefined;
var scratch_pt: PageTable align(4096) = undefined;

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

    mapper: ?*Mapper = null,

    /// The bitfield for the pages
    page_bitfield: PageBitField,

    internal_allocator: std.mem.Allocator,

    /// Sets up a new memory manager -> this is not alllocated
    pub fn new() !*Manager {
        verbose_log.info("Creating new memory manager", .{});
        const internal_allocator = Manager.memory_manager_internal_allocator.allocator();
        const result = try internal_allocator.create(Manager);
        result.* = Manager{
            .memory_layout = types.MEMORY_LAYOUT.init(),
            .reserved_virtual_maps = undefined,
            .reserved_physical_ranges = undefined,
            .available_physical_ranges = undefined,
            .internal_allocator = internal_allocator,
            .mapper = null,
            .page_bitfield = undefined,
        };

        return result;
    }

    pub fn init(self: *Manager, multiboot_info: multiboot.Multiboot2Info, test_bitfield_before_page_switch: bool) !void {
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
                const section_map = section.toMemoryMap(self.memory_layout.kernel_offset) orelse continue;
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

        if (test_bitfield_before_page_switch) {
            try self.page_bitfield.tester(self.memory_layout.kernel_offset);
        }

        manager_log.info("Page bitfield created with {} pages and {} reserved ", .{ self.page_bitfield.pages, self.page_bitfield.getReserved() });

        manager_log.info("Starting to create the Mapper", .{});
        // #1 - Get the current page table, and figure out if its  physical or virtual address.
        const current_page_table_add: u64 = Mapper.currentPML4();
        std.log.debug("The current page table is 0x{X:0>16}", .{current_page_table_add});
        const cpt: *PageMapLevel4 = @ptrFromInt(current_page_table_add | self.memory_layout.kernel_virtual_address_start);
        cpt.log();

        const pmask_4k = PAGE_MASK_4K;

        // // Create a new address space (PML4)
        try Mapper.initScratchMap(self.memory_layout.kernel_offset);
        var new_mapper = try Mapper.create(&self.page_bitfield, self.memory_layout.kernel_offset, self.internal_allocator);
        self.mapper = new_mapper; // Assign to manager's mapper field
        cpt.log();
        manager_log.info("New Mapper created.", .{});

        // --- Map essential kernel regions into the new_mapper ---
        manager_log.info("Mapping kernel regions into new address space...", .{});
        var current_phys: u64 = 0;
        var current_virt = self.memory_layout.kernel_offset;
        // Kernel code is executable, data is not. For simplicity, map all as R/W, X for code.
        // A more granular approach would map sections with different flags.
        const kernel_code_data_flags = PageFlags{ .present = true, .writable = true, .execute_disable = false }; // A general kernel flag

        while (true) {
            // TODO @(dleiferives,fd0a8391-a09e-413c-83f1-43d17b535c6f): Remove
            // the hacky solution to gettig the kernel to load properly by just
            // loading an additional meg ontop! ~#
            if (current_phys > self.memory_layout.kernel_physical_address_end + (10 * 1024 * 1024)) {
                if (self.page_bitfield.largestFreePage()) |largest_page| {
                    if (current_phys > largest_page) {
                        manager_log.err("Physical address 0x{x} is larger than largest free page 0x{x}", .{ current_phys, largest_page });
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
        // new_mapper.scratchmapVirt(new_mapper.pml4_phys_addr, PageMapLevel4);
        // const pml4_virt: *PageMapLevel4 = new_mapper.scratchMapVirt(new_mapper.pml4_phys_addr, PageMapLevel4);
        // defer new_mapper.scratchMapDemap(new_mapper.pml4_phys_addr);
        //@ptrFromInt(new_mapper.pml4_phys_addr | self.memory_layout.kernel_offset);
        // pml4_virt.log_all(self.memory_layout.kernel_offset);

        // After all essential mappings are done for the new_mapper:
        try Mapper.initScratchMap(self.memory_layout.kernel_offset);
        Mapper.loadPML4(new_mapper.pml4_phys_addr);
        manager_log.info("New PML4 (0x{x}) loaded into CR3.", .{new_mapper.pml4_phys_addr});
        try Mapper.initScratchMap(self.memory_layout.kernel_offset);

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

    pub fn test_mapper(self: *Manager, virt_addr_start: u64) !void {
        const free_pages: u64 = self.page_bitfield.getFreePages();
        manager_log.info("Free pages in the bitfield: {}", .{free_pages});
        var last_page: u64 = 0;
        var counter: u64 = 0;
        for (0..free_pages) |i| {
            const page_addr = self.page_bitfield.allocatePage() orelse {
                manager_log.warn("\nFailed to get page address stopping...", .{});
                break;
            };
            manager_log.warn("Page {}: 0x{X:0>16}\r", .{ i, page_addr });
            // Map the page to a virtual address
            const virt_addr = virt_addr_start + (i * PAGE_SIZE_4K);
            const flags = PageFlags{ .present = true, .writable = true, .execute_disable = false };
            self.mapper.?.map(virt_addr, page_addr, flags) catch {
                manager_log.err("Error appending reserved virtual map: ", .{});
                while (true) {}
            };
            @memset(@as(*[64]u64, @ptrFromInt(virt_addr)), last_page);
            last_page = virt_addr;
            counter += 1;
        }
        manager_log.warn("\n", .{});
        manager_log.info("Mapped {} pages starting from 0x{X:0>16}", .{ counter, virt_addr_start });

        while (true) {
            if (last_page == 0) {
                manager_log.warn("\nNo more pages to test, stopping at 0x{X:0>16}", .{last_page});
                break;
            }
            const data: [*]u64 = @ptrFromInt(last_page);
            const next: u64 = data[0];
            manager_log.warn("Unmapping 0x{X:0>16}", .{last_page});
            const frame = self.mapper.?.unmap(last_page) catch |err| {
                manager_log.warn("\nError unmapping page at 0x{X:0>16}: {}", .{ last_page, err });
                while (true) {} // Halt on error
            };
            self.page_bitfield.freePage(frame) catch |err| {
                manager_log.warn("\nError freeing page at 0x{X:0>16}: {}", .{ last_page, err });
                while (true) {} // Halt on error
            };
            manager_log.warn("-> 0x{X:0>16}\r", .{frame});
            last_page = next;
        }
        manager_log.info("Memory mapper tester completed.", .{});
    }

    // Owned by the container!
    // TODO @(dleiferives,909b4610-e62d-430f-acf0-c4ae94028c17): Make sure that
    // this is seen globally so it gets linked nicely! ~#
    pub var memory_manager_allocation_buffer: [0x10_0000]u8 = undefined;
    var memory_manager_internal_allocator: std.heap.FixedBufferAllocator = std.heap.FixedBufferAllocator.init(memory_manager_allocation_buffer[0..]);
};

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
        manager_log.info("The number of directory pointers in map is {}", .{n_entries});
        var iter = self.iterator();
        while (iter.next()) |entry| {
            const flags = PageFlags.from_bits(entry);
            if (flags.present) {
                manager_log.info("{d:0>3}: 0x{X:0>16}", .{ iter.index - 1, entry });
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
                                        manager_verbose_log.info("0x{X:0>16} -> 0x{X:0>16}", .{ _virt_addr, _phys_addr });
                                        manager_verbose_log.info("PML4: {d}, PDPT: {d}, PD: {d}, PT: {d}", .{ pm4_iter.index - 1, pm3_iter.index - 1, pm2_iter.index - 1, pt_iter.index - 1 });
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
        manager_log.info("The number of directories in directory table is {}", .{n_entries});
        var iter = self.iterator();
        while (iter.next()) |entry| {
            const flags = PageFlags.from_bits(entry);
            if (flags.present) {
                manager_log.info("{d:0>3}: 0x{X:0>16}", .{ iter.index - 1, entry });
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
        manager_log.info("The number of tables in directory is {}", .{n_entries});
        var iter = self.iterator();
        while (iter.next()) |entry| {
            const flags = PageFlags.from_bits(entry);
            if (flags.present) {
                manager_log.info("{d:0>3}: 0x{X:0>16}", .{ iter.index - 1, entry });
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
        manager_log.info("The number of entries in table is {}", .{n_entries});
        var iter = self.iterator();
        while (iter.next()) |entry| {
            const flags = PageFlags.from_bits(entry);
            if (flags.present) {
                manager_log.info("{d:0>3}: 0x{X:0>16}", .{ iter.index - 1, entry });
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

// Page Table Entry Flags IA-32e
const PT_PRESENT: u64 = 1 << 0;
const PT_WRITABLE: u64 = 1 << 1;
const PT_USER_ACCESSIBLE: u64 = 1 << 2;
const PT_WRITE_THROUGH: u64 = 1 << 3;
const PT_CACHE_DISABLE: u64 = 1 << 4;
const PT_ACCESSED: u64 = 1 << 5; // Set by hardware
const PT_DIRTY: u64 = 1 << 6; // Set by hardware (PTE, or PDE/PDPE with PS=1)
const PT_PAGE_SIZE: u64 = 1 << 7; // PS bit (for PDE, PDPE indicating 2MB/1GB page)
const PT_GLOBAL: u64 = 1 << 8; // For PTE, or PDE/PDPE with PS=1

// Bits 9-11 are available for my use
const PT_DEMAND_ALLOC: u64 = 1 << 9;
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

    const header = if (i4_ & 0x100 == 0) 0 else @as(u64, ((@as(u64, 1) << (64 - 48)) - 1)) << 48; // Mask for 48-bit physical addresses
    return header | (i4_ << 39) | (i3_ << 30) | (i2_ << 21) | (i1_ << 12);
}

pub const MapperError = error{
    OutOfMemory,
    PageTableNotPresent, // Indicates an intermediate table was expected but not found
    AddressNotAligned,
    AlreadyMapped,
    NotMapped,
    UnsupportedPageSize, // If trying to operate on large pages with functions not designed for them
    NotInScratchMap,
};

/// Flags for mapping a page.
pub const PageFlags = struct {
    present: bool = true,
    writable: bool = true,
    user_accessible: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    global: bool = false,
    execute_disable: bool = false,
    demand_alloc: bool = false,

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
        manager_log.debug("PageFlags: present={}, writable={}, user_accessible={}, write_through={}, cache_disable={}, global={}, execute_disable={}, demand_alloc={}", .{ self.present, self.writable, self.user_accessible, self.write_through, self.cache_disable, self.global, self.execute_disable, self.demand_alloc });
    }
};

/// The mapper -> this will be given to each of the programs,
/// they will have their own mapper
/// from this mapper an allocator will be made. which will do the allocation for each program
pub const Mapper = struct {
    pml4_phys_addr: u64,
    pmm: *PageBitField,
    kernel_offset: u64,

    const Self = @This();

    /// Gets a virtual pointer to a physical page table.
    inline fn getTableVirtPtr(phys_addr: u64, kernel_offset: u64, comptime T: type) *volatile T {
        // std.debug.assert(phys_addr & PAGE_MASK_4K == 0); // Must be page aligned
        const virt_ptr_val = phys_addr + kernel_offset;
        return @ptrFromInt(virt_ptr_val);
    }

    /// Allocates a new, zeroed page table frame.
    inline fn allocate_page_table_frame(self: *Self) MapperError!u64 {
        mapper_verbose_log.debug("Allocating frame", .{});
        const frame_phys_addr = self.pmm.allocatePage() orelse return MapperError.OutOfMemory;

        // Zero the frame using its virtual address
        const frame_virt_ptr = self.scratchMapVirt(frame_phys_addr, u8); //getTableVirtPtr(frame_phys_addr, self.kernel_offset, [PAGE_TABLE_ENTRY_COUNT]u64);
        const framthing: [*]u8 = @ptrCast(frame_virt_ptr);
        defer self.scratchMapDemap(frame_phys_addr);
        for (0..4096) |i| {
            framthing[i] = 0;
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

    pub fn currentPML4() u64 {
        var val: u64 = undefined;
        asm volatile ("mov %%cr3, %[val]"
            : [val] "=r" (val),
        );
        return val;
    }

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
    pub fn create(pmm: *PageBitField, kernel_offset: u64, allocator_local: std.mem.Allocator) !*Self {
        mapper_log.debug("Creating new Mapper instance...", .{});
        var mapper = try allocator_local.create(Self);

        mapper.* = Self{
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
            parent_entry_virt_ptr.* = new_table_phys_addr | entry_flags_for_new_table | PT_PRESENT;
            return new_table_phys_addr;
        }
    }

    /// Maps a 4KB virtual page to a 4KB physical frame.
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

        const pml4_virt = self.scratchMapVirt(self.pml4_phys_addr, PageMapLevel4); //getTableVirtPtr(self.pml4_phys_addr, self.kernel_offset, PageMapLevel4);
        defer self.scratchMapDemap(self.pml4_phys_addr);

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
        const pdpt_virt = self.scratchMapVirt(pdpt_phys_addr, PageDirectoryPointerTable); //getTableVirtPtr(pdpt_phys_addr, self.kernel_offset, PageDirectoryPointerTable);
        defer self.scratchMapDemap(pdpt_phys_addr);

        // 2. PDPT -> PD
        const pd_phys_addr = try self.get_or_create_next_table(
            &pdpt_virt.entries[pdpt_idx],
            table_entry_flags,
        );
        const pd_virt = self.scratchMapVirt(pd_phys_addr, PageDirectory); //getTableVirtPtr(pd_phys_addr, self.kernel_offset, PageDirectory);
        defer self.scratchMapDemap(pd_phys_addr);

        // 3. PD -> PT
        const pt_phys_addr = try self.get_or_create_next_table(
            &pd_virt.entries[pd_idx],
            table_entry_flags,
        );
        const pt_virt = self.scratchMapVirt(pt_phys_addr, PageTable); // getTableVirtPtr(pt_phys_addr, self.kernel_offset, PageTable);
        defer self.scratchMapDemap(pt_phys_addr);

        // 4. Set PTE in PT
        const pte_ptr = &pt_virt.entries[pt_idx];
        if (pte_ptr.* & PT_PRESENT != 0) {
            // Page is already mapped. For simplicity, we'll overwrite.
            // A more robust VMM might error or require unmap first.
            manager_log.warn("map: virt_addr 0x{x} already mapped to 0x{x}. Overwriting with 0x{x}.\n", .{
                virt_addr, pte_ptr.* & PTE_ADDR_MASK, phys_addr,
            });
        }

        mapper_verbose_log.info("mapped (allocated) virt 0x{X:0>16} -> 0x{X:0>16}", .{ virt_addr, phys_addr });
        pte_ptr.* = phys_addr | page_flags.to_bits();
        invlpg(virt_addr);
    }

    pub fn clone(self: *Self, allocator_l: std.mem.Allocator) !*Mapper {
        // 1. Create a new, empty mapper for the new process
        const new_mapper = try Mapper.create(self.pmm, self.kernel_offset, allocator_l);

        // 2. Get virtual pointers to the source (kernel) and destination (new) PML4 tables.
        //    We use the scratch map to safely access these physical pages.
        const src_pml4_virt = self.scratchMapVirt(self.pml4_phys_addr, PageMapLevel4);
        defer self.scratchMapDemap(self.pml4_phys_addr);

        const dest_pml4_virt = self.scratchMapVirt(new_mapper.pml4_phys_addr, PageMapLevel4);
        defer self.scratchMapDemap(new_mapper.pml4_phys_addr);

        // 3. Copy the kernel-space mappings (typically the upper half of the table).
        //    This is a shallow copy; we're just copying the pointers to the PDPTs.
        //    This makes all processes share the same kernel space.
        const kernel_space_start_index = PAGE_TABLE_ENTRY_COUNT / 2;
        for (kernel_space_start_index..PAGE_TABLE_ENTRY_COUNT) |i| {
            dest_pml4_virt.entries[i] = src_pml4_virt.entries[i];
        }

        mapper_log.info(
            "Cloned address space. New PML4 at 0x{X} now shares kernel mappings.",
            .{new_mapper.pml4_phys_addr},
        );

        return new_mapper;
    }

    pub fn mapRange(
        self: *Self,
        start_virt_addr: u64,
        end_virt_addr: u64,
        page_flags: PageFlags,
    ) !void {
        if (start_virt_addr & PAGE_MASK_4K != 0 or end_virt_addr & PAGE_MASK_4K != 0) {
            mapper_log.err("mapRange: start_virt_addr 0x{x} or end_virt_addr 0x{x} not 4K aligned.", .{ start_virt_addr, end_virt_addr });
            return MapperError.AddressNotAligned;
        }
        mapper_log.debug("mapRange: start_virt_addr 0x{x}, end_virt_addr 0x{x}, page_flags: {any}", .{ start_virt_addr, end_virt_addr, page_flags });

        if (start_virt_addr >= end_virt_addr) {
            mapper_log.err("mapdRange: start address 0x{x} is not less than end address 0x{x}.", .{ start_virt_addr, end_virt_addr });
            return; // No range to map
        }

        // check if the range is already mapped
        // using the translate function
        var current_virt = start_virt_addr;
        var new_start = start_virt_addr;
        while (current_virt <= end_virt_addr) {
            if (self.translate(current_virt)) |phys_addr| {
                mapper_log.warn("mapDemandRange: virt_addr 0x{x} already mapped to 0x{x}.\n", .{ current_virt, phys_addr });
                new_start = current_virt;
                // return MapperError.AlreadyMapped;
            }
            current_virt += PAGE_SIZE_4K;
        }

        current_virt = new_start;
        while (current_virt <= end_virt_addr) {
            // allocate a page
            const phys_addr = self.pmm.allocatePage() orelse return MapperError.OutOfMemory;
            try self.map(current_virt, phys_addr, page_flags);
            mapper_log.info("Mapped 0x{X:0>16} 0x{X:0>16}",.{current_virt,phys_addr});
            current_virt += PAGE_SIZE_4K;
        }
        return; // Successfully mapped the range

    }

    pub fn mapDemandRange(
        self: *Self,
        virt_addr: u64,
        size: u64,
        page_flags: PageFlags,
    ) !bool {
        const page_count = (size + PAGE_SIZE_4K - 1) / PAGE_SIZE_4K;
        var current_addr:u64 = virt_addr & ~@as(u64,0x1FF);

        var i: u64 = 0;
        while (i < page_count) : (i += 1) {
            std.log.debug("current_addr: 0x{X:0>16}, page_count: {d}", .{current_addr, page_count});
            try self.mapDemand(current_addr, page_flags);
            current_addr += PAGE_SIZE_4K;
        }

        log.info("Allocated {} pages with demand paging at 0x{X:0>16}", .{ page_count, virt_addr });
        return true;
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
        std.log.debug("virtual address is 0x{X:0>16}",.{virt_addr});

        const pml4_idx = pml4Index(virt_addr);
        const pdpt_idx = pdptIndex(virt_addr);
        const pd_idx = pdIndex(virt_addr);
        const pt_idx = ptIndex(virt_addr);

        const pml4_virt = self.scratchMapVirt(self.pml4_phys_addr, PageMapLevel4); //getTableVirtPtr(self.pml4_phys_addr, self.kernel_offset, PageMapLevel4);
        defer self.scratchMapDemap(self.pml4_phys_addr);

        // Flags for intermediate directory entries
        var table_entry_flags = PT_PRESENT;
        if (page_flags.writable) table_entry_flags |= PT_WRITABLE;
        if (page_flags.user_accessible) table_entry_flags |= PT_USER_ACCESSIBLE;

        // 1. PML4 -> PDPT
        const pdpt_phys_addr = try self.get_or_create_next_table(
            &pml4_virt.entries[pml4_idx],
            table_entry_flags,
        );
        const pdpt_virt = self.scratchMapVirt(pdpt_phys_addr, PageDirectoryPointerTable); //getTableVirtPtr(pdpt_phys_addr, self.kernel_offset, PageDirectoryPointerTable);
        defer self.scratchMapDemap(pdpt_phys_addr);
        mapper_verbose_log.debug("mapDemand: PDPT created at 0x{x} for virt_addr 0x{x}", .{ pdpt_phys_addr, virt_addr });

        // 2. PDPT -> PD
        const pd_phys_addr = try self.get_or_create_next_table(
            &pdpt_virt.entries[pdpt_idx],
            table_entry_flags,
        );
        const pd_virt = self.scratchMapVirt(pd_phys_addr, PageDirectory); //getTableVirtPtr(pd_phys_addr, self.kernel_offset, PageDirectory);
        defer self.scratchMapDemap(pd_phys_addr);
        mapper_verbose_log.debug("mapDemand: PD created at 0x{x} for virt_addr 0x{x}", .{ pd_phys_addr, virt_addr });

        // 3. PD -> PT
        const pt_phys_addr = try self.get_or_create_next_table(
            &pd_virt.entries[pd_idx],
            table_entry_flags,
        );
        const pt_virt = self.scratchMapVirt(pt_phys_addr, PageTable); // getTableVirtPtr(pt_phys_addr, self.kernel_offset, PageTable);
        defer self.scratchMapDemap(pt_phys_addr);
        mapper_verbose_log.debug("mapDemand: PT created at 0x{x} for virt_addr 0x{x}", .{ pt_phys_addr, virt_addr });

        // 4. Set PTE for demand allocation
        const pte_ptr = &pt_virt.entries[pt_idx];
        if (pte_ptr.* & PT_PRESENT != 0) {
            mapper_log.warn("mapDemand: virt_addr 0x{x} already mapped.\n", .{virt_addr});
            return MapperError.AlreadyMapped;
        }
        mapper_verbose_log.debug("mapDemand: Setting PTE for virt_addr 0x{x}", .{virt_addr});

        // Create flags with demand bit set and present bit clear
        var demand_flags = page_flags;
        demand_flags.present = false; // Not present initially
        demand_flags.demand_alloc = true; // Mark for demand allocation

        // Set PTE with demand flags and zero physical address
        pte_ptr.* = demand_flags.to_bits();
        mapper_verbose_log.info("mapDemand: virt 0x{X:0>16} marked for demand allocation", .{virt_addr});

        invlpg(virt_addr);
        invlpg(@intFromPtr(pt_virt));
    }

    /// Allocate a page frame for a page fault (MMU_pf_alloc equivalent)
    pub fn allocatePageForFault(self: *Self, virt_addr: u64) MapperError!u64 {
        mapper_verbose_log.debug("allocatePageForFault: Allocating page for fault at virt_addr 0x{x}", .{virt_addr});
        const phys_addr = self.pmm.allocatePage() orelse return MapperError.OutOfMemory;

        // Zero the allocated page
        const page_virt_ptr = self.scratchMapVirt(phys_addr, PageTable); //getTableVirtPtr(phys_addr, self.kernel_offset, [PAGE_SIZE_4K]u8);
        defer self.scratchMapDemap(phys_addr);
        @memset(&page_virt_ptr.entries, 0);

        mapper_verbose_log.debug("Allocated page frame 0x{x} for fault at virt 0x{x}", .{ phys_addr, virt_addr });
        return phys_addr;
    }

    /// Handle demand page allocation in page fault
    pub inline fn handleDemandPageFault(self: *Self, virt_addr: u64) MapperError!bool {
        const page_aligned_virt = virt_addr & ~PAGE_MASK_4K;

        const pml4_idx = pml4Index(page_aligned_virt);
        const pdpt_idx = pdptIndex(page_aligned_virt);
        const pd_idx = pdIndex(page_aligned_virt);
        const pt_idx = ptIndex(page_aligned_virt);

        const pml4_virt = self.scratchMapVirt(self.pml4_phys_addr, PageMapLevel4); //getTableVirtPtr(self.pml4_phys_addr, self.kernel_offset, PageMapLevel4);
        defer self.scratchMapDemap(self.pml4_phys_addr);

        // Walk page tables to find the PTE
        const pml4e_val = pml4_virt.entries[pml4_idx];
        // pml4_virt.deVoltaile().log();
        if (pml4e_val & PT_PRESENT == 0) {
            std.log.debug("PML4 entry not present for virt 0x{X:0>16}", .{page_aligned_virt});
            return false;
        }

        const pdpt_phys_addr = pml4e_val & PTE_ADDR_MASK;
        const pdpt_virt = self.scratchMapVirt(pdpt_phys_addr, PageDirectoryPointerTable); //getTableVirtPtr(pdpt_phys_addr, self.kernel_offset, PageDirectoryPointerTable);
        defer self.scratchMapDemap(pdpt_phys_addr);
        // pdpt_virt.deVoltaile().log();

        const pdpte_val = pdpt_virt.entries[pdpt_idx];
        if (pdpte_val & PT_PRESENT == 0) {
            std.log.debug("PDPT entry not present for virt 0x{X:0>16}", .{page_aligned_virt});
            return false;
        }
        if (pdpte_val & PT_PAGE_SIZE != 0){
            std.log.debug("PDPT entry not present for virt 0x{X:0>16}", .{page_aligned_virt});
            return false; // Large page
        }

        const pd_phys_addr = pdpte_val & PTE_ADDR_MASK;
        const pd_virt = self.scratchMapVirt(pd_phys_addr, PageDirectory); //getTableVirtPtr(pd_phys_addr, self.kernel_offset, PageDirectory);
        defer self.scratchMapDemap(pd_phys_addr);
        // pd_virt.deVoltaile().log();

        const pde_val = pd_virt.entries[pd_idx];
        if (pde_val & PT_PRESENT == 0) {
            std.log.debug("PD entry not present for virt 0x{X:0>16}", .{page_aligned_virt});
            return false;
        }
        if (pde_val & PT_PAGE_SIZE != 0){
            std.log.debug("PD entry not present for virt 0x{X:0>16}", .{page_aligned_virt});
            return false;
        }

        const pt_phys_addr = pde_val & PTE_ADDR_MASK;
        const pt_virt = self.scratchMapVirt(pt_phys_addr, PageTable); // getTableVirtPtr(pt_phys_addr, self.kernel_offset, PageTable);
        defer self.scratchMapDemap(pt_phys_addr);
        // pt_virt.deVoltaile().log();

        const pte_ptr = &pt_virt.entries[pt_idx];
        const pte_val = pte_ptr.*;

        // PageFlags.from_bits(pte_val).log();

        // Check if this is a demand allocation page
        if ((pte_val & PT_DEMAND_ALLOC) == 0) {
            std.log.debug("Handling demand page fault for virt not a demand page 0x{X:0>16}", .{page_aligned_virt});
            return false; // Not a demand page
        }

        if (pte_val & PT_PRESENT != 0) {
            std.log.debug("Handling demand page fault for virt already allocated 0x{X:0>16}", .{page_aligned_virt});
            return false; // Already allocated
        }

        // Allocate physical page
        // std.log.info("Handling demand page fault for virt 0x{X:0>16}", .{page_aligned_virt});
        const phys_addr = try self.allocatePageForFault(page_aligned_virt);

        // Update PTE: clear demand bit, set present bit, set physical address
        var new_flags = PageFlags.from_bits(pte_val);
        new_flags.demand_alloc = false;
        new_flags.present = true;
        new_flags.writable = true; // Assume writable for simplicity, adjust as needed
        new_flags.demand_alloc = false;
        new_flags.execute_disable = false; // Set execute-disable for security

        mapper_log.debug("Allocating page for demand fault: virt 0x{X:0>16} -> phys 0x{X:0>16}", .{ page_aligned_virt, phys_addr });

        pte_ptr.* = phys_addr | new_flags.to_bits();

        invlpg(page_aligned_virt);

        mapper_verbose_log.info("Demand allocated: virt 0x{X:0>16} -> phys 0x{X:0>16}", .{ page_aligned_virt, phys_addr });

        invlpg(page_aligned_virt);
        invlpg(@intFromPtr(pt_virt));
        return true;
    }

    pub fn isTablePhysicallyEmpty(
        table_phys_addr: u64,
        comptime TableStruct: type,
        mapper: *Mapper,
    ) bool {
        const table_virt = mapper.scratchMapVirt(table_phys_addr, TableStruct);
        defer mapper.scratchMapDemap(table_phys_addr);
        for (0..PAGE_TABLE_ENTRY_COUNT) |i| {
            if ((table_virt.entries[i] & PT_PRESENT) != 0) {
                return false;
            }
        }
        return true;
    }

    pub fn unmapAndFreeRangeFull(
        self: *Self,
        range_start_virt: u64,
        range_end_virt: u64, // exclusive end
    ) !void {
        if (range_start_virt & PAGE_MASK_4K != 0 or
            range_end_virt & PAGE_MASK_4K != 0)
        {
            mapper_log.err(
                "unmapAndFreeRangeFull: start_virt 0x{x} or end_virt 0x{x} not 4K aligned.",
                .{ range_start_virt, range_end_virt },
            );
            return MapperError.AddressNotAligned;
        }
        if (range_start_virt >= range_end_virt) {
            mapper_log.debug(
                "unmapAndFreeRangeFull: start_virt 0x{x} >= end_virt 0x{x}, nothing to do.",
                .{ range_start_virt, range_end_virt },
            );
            return;
        }

        // Step 1: Unmap individual pages and free their physical frames
        try self.unmapAndFreeRange(range_start_virt, range_end_virt);
        mapper_verbose_log.debug(
            "unmapAndFreeRangeFull: Pages unmapped for range 0x{x}-0x{x}. Starting table cleanup.",
            .{ range_start_virt, range_end_virt },
        );

        // --- Pass 1: Clean Page Tables (PTs) ---
        // Iterate through Page Directory regions (2MB chunks) that overlap with the range
        var current_pd_region_addr = range_start_virt & ~PAGE_MASK_2MB;
        while (current_pd_region_addr < range_end_virt) {
            const pml4_idx_for_pd = pml4Index(current_pd_region_addr);
            const pdpt_idx_for_pd = pdptIndex(current_pd_region_addr);

            const pml4_virt = self.scratchMapVirt(
                self.pml4_phys_addr,
                PageMapLevel4,
            );
            defer self.scratchMapDemap(self.pml4_phys_addr);
            const pml4e = pml4_virt.entries[pml4_idx_for_pd];

            if (pml4e & PT_PRESENT == 0) {
                current_pd_region_addr = (current_pd_region_addr + PAGE_SIZE_1GB) &
                    ~PAGE_MASK_1GB;
                if (current_pd_region_addr < (range_start_virt & ~PAGE_MASK_2MB)) { // Ensure forward progress
                    current_pd_region_addr = range_start_virt & ~PAGE_MASK_2MB;
                }
                continue;
            }
            const pdpt_phys = pml4e & PTE_ADDR_MASK;

            const pdpt_virt = self.scratchMapVirt(
                pdpt_phys,
                PageDirectoryPointerTable,
            );
            const pdpte = pdpt_virt.entries[pdpt_idx_for_pd];
            // Demap pdpt_virt later, after potential modification if its child PD is freed

            if (pdpte & PT_PRESENT == 0) {
                self.scratchMapDemap(pdpt_phys);
                current_pd_region_addr += PAGE_SIZE_2MB;
                continue;
            }
            if (pdpte & PT_PAGE_SIZE != 0) { // 1GB page
                self.scratchMapDemap(pdpt_phys);
                current_pd_region_addr = (current_pd_region_addr + PAGE_SIZE_1GB) &
                    ~PAGE_MASK_1GB;
                if (current_pd_region_addr < (range_start_virt & ~PAGE_MASK_2MB)) {
                    current_pd_region_addr = range_start_virt & ~PAGE_MASK_2MB;
                }
                continue;
            }
            const pd_phys = pdpte & PTE_ADDR_MASK;
            var pd_virt = self.scratchMapVirt(pd_phys, PageDirectory);

            // Iterate over PDEs in the current PD
            for (0..PAGE_TABLE_ENTRY_COUNT) |pt_idx_in_pd| {
                const pde_ptr = &pd_virt.entries[pt_idx_in_pd];
                if (pde_ptr.* & PT_PRESENT == 0) continue;
                if (pde_ptr.* & PT_PAGE_SIZE != 0) continue; // 2MB page

                const pt_phys_addr = pde_ptr.* & PTE_ADDR_MASK;
                if (isTablePhysicallyEmpty(pt_phys_addr, PageTable, self)) {
                    mapper_verbose_log.debug(
                        "unmapAndFreeRangeFull: PT @0x{x} (PDE @{*} entry {}) is empty. Freeing.",
                        .{ pt_phys_addr, pde_ptr, pt_idx_in_pd },
                    );
                    try self.free_page_table_frame(pt_phys_addr);
                    pde_ptr.* = 0; // Clear the PDE
                }
            }
            self.scratchMapDemap(pd_phys); // Demap PD after iterating its PDEs
            self.scratchMapDemap(pdpt_phys); // Demap PDPT (was mapped before PD)
            current_pd_region_addr += PAGE_SIZE_2MB;
        }

        // --- Pass 2: Clean Page Directories (PDs) ---
        // Iterate through Page Directory Pointer Table regions (1GB chunks)
        var current_pdpt_region_addr = range_start_virt & ~PAGE_MASK_1GB;
        while (current_pdpt_region_addr < range_end_virt) {
            const pml4_idx_for_pdpt = pml4Index(current_pdpt_region_addr);

            var pml4_virt_pd = self.scratchMapVirt(
                self.pml4_phys_addr,
                PageMapLevel4,
            );
            const pml4e_ptr_pd = &pml4_virt_pd.entries[pml4_idx_for_pdpt];

            if (pml4e_ptr_pd.* & PT_PRESENT == 0) {
                self.scratchMapDemap(self.pml4_phys_addr);
                current_pdpt_region_addr = (current_pdpt_region_addr +
                    PAGE_SIZE_1GB * PAGE_TABLE_ENTRY_COUNT) &
                    ~(PAGE_SIZE_1GB * PAGE_TABLE_ENTRY_COUNT - 1); // Align to next PML4E coverage
                if (current_pdpt_region_addr < (range_start_virt & ~PAGE_MASK_1GB)) {
                    current_pdpt_region_addr = range_start_virt & ~PAGE_MASK_1GB;
                }
                continue;
            }
            const pdpt_phys_addr_pd = pml4e_ptr_pd.* & PTE_ADDR_MASK;
            var pdpt_virt_pd = self.scratchMapVirt(
                pdpt_phys_addr_pd,
                PageDirectoryPointerTable,
            );

            // Iterate over PDPTEs in the current PDPT
            for (0..PAGE_TABLE_ENTRY_COUNT) |pd_idx_in_pdpt| {
                const pdpte_ptr = &pdpt_virt_pd.entries[pd_idx_in_pdpt];
                if (pdpte_ptr.* & PT_PRESENT == 0) continue;
                if (pdpte_ptr.* & PT_PAGE_SIZE != 0) continue; // 1GB page

                const pd_phys_addr = pdpte_ptr.* & PTE_ADDR_MASK;
                if (isTablePhysicallyEmpty(pd_phys_addr, PageDirectory, self)) {
                    mapper_verbose_log.debug(
                        "unmapAndFreeRangeFull: PD @0x{x} (PDPTE @{*} entry {}) is empty. Freeing.",
                        .{ pd_phys_addr, pdpte_ptr, pd_idx_in_pdpt },
                    );
                    try self.free_page_table_frame(pd_phys_addr);
                    pdpte_ptr.* = 0; // Clear the PDPTE
                }
            }
            self.scratchMapDemap(pdpt_phys_addr_pd);
            self.scratchMapDemap(self.pml4_phys_addr);
            current_pdpt_region_addr += PAGE_SIZE_1GB;
        }

        // --- Pass 3: Clean Page Directory Pointer Tables (PDPTs) ---
        // Iterate through PML4E regions that cover the range.
        // A single PML4E covers 512GB. The range is usually smaller.
        // We find unique PML4 indices covering the start and end of the range.
        const start_pml4_idx = pml4Index(range_start_virt);
        const end_pml4_idx = pml4Index(range_end_virt - 1); // -1 for inclusive end for index calc

        for (start_pml4_idx..(end_pml4_idx + 1)) |pml4_idx_for_cleanup| {
            var pml4_virt_cleanup = self.scratchMapVirt(
                self.pml4_phys_addr,
                PageMapLevel4,
            );
            const pml4e_ptr_cleanup = &pml4_virt_cleanup.entries[pml4_idx_for_cleanup];

            if (pml4e_ptr_cleanup.* & PT_PRESENT == 0) {
                self.scratchMapDemap(self.pml4_phys_addr);
                continue;
            }
            // PML4Es should not have PS bit set when pointing to PDPT
            // std.debug.assert((pml4e_ptr_cleanup.* & PT_PAGE_SIZE) == 0);

            const pdpt_phys_addr_cleanup = pml4e_ptr_cleanup.* & PTE_ADDR_MASK;
            if (isTablePhysicallyEmpty(
                pdpt_phys_addr_cleanup,
                PageDirectoryPointerTable,
                self,
            )) {
                mapper_verbose_log.debug(
                    "unmapAndFreeRangeFull: PDPT @0x{x} (PML4E @{*} entry {}) is empty. Freeing.",
                    .{
                        pdpt_phys_addr_cleanup,
                        pml4e_ptr_cleanup,
                        pml4_idx_for_cleanup,
                    },
                );
                try self.free_page_table_frame(pdpt_phys_addr_cleanup);
                pml4e_ptr_cleanup.* = 0; // Clear the PML4E
            }
            self.scratchMapDemap(self.pml4_phys_addr);
        }

        mapper_verbose_log.debug(
            "unmapAndFreeRangeFull: Table cleanup finished for range 0x{x}-0x{x}.",
            .{ range_start_virt, range_end_virt },
        );
    }

    pub fn getpageDirectoryPointerPhys(self: *Self, virt_addr: u64) MapperError!u64 {
        if (virt_addr & PAGE_MASK_4K != 0) {
            mapper_log.err("getPageDirectoryPointer: virt_addr 0x{x} not 4K aligned.", .{virt_addr});
            return MapperError.AddressNotAligned;
        }

        const pml4_idx = pml4Index(virt_addr);

        const pml4_virt = self.scratchMapVirt(self.pml4_phys_addr, PageMapLevel4); //getTableVirtPtr(self.pml4_phys_addr, self.kernel_offset, PageMapLevel4);
        defer self.scratchMapDemap(self.pml4_phys_addr);

        // 1. PML4 Entry
        const pml4e_val = pml4_virt.entries[pml4_idx];
        if (pml4e_val & PT_PRESENT == 0) return MapperError.NotMapped;
        if (pml4e_val & PT_PAGE_SIZE != 0) return MapperError.UnsupportedPageSize; // Should be table
        const pdpt_phys_addr = pml4e_val & PTE_ADDR_MASK;
        return pdpt_phys_addr;
    }

    pub fn getPageDirectoryPhys(self: *Self, virt_addr: u64) MapperError!u64 {
        if (virt_addr & PAGE_MASK_4K != 0) {
            mapper_log.err("getPageDirectory: virt_addr 0x{x} not 4K aligned.", .{virt_addr});
            return MapperError.AddressNotAligned;
        }

        const pml4_idx = pml4Index(virt_addr);
        const pdpt_idx = pdptIndex(virt_addr);

        const pml4_virt = self.scratchMapVirt(self.pml4_phys_addr, PageMapLevel4); //getTableVirtPtr(self.pml4_phys_addr, self.kernel_offset, PageMapLevel4);
        defer self.scratchMapDemap(self.pml4_phys_addr);

        // 1. PML4 Entry
        const pml4e_val = pml4_virt.entries[pml4_idx];
        if (pml4e_val & PT_PRESENT == 0) return MapperError.NotMapped;
        if (pml4e_val & PT_PAGE_SIZE != 0) return MapperError.UnsupportedPageSize; // Should be table
        const pdpt_phys_addr = pml4e_val & PTE_ADDR_MASK;
        const pdpt_virt = self.scratchMapVirt(pdpt_phys_addr, PageDirectoryPointerTable); //getTableVirtPtr(pdpt_phys_addr, self.kernel_offset, PageDirectoryPointerTable);
        defer self.scratchMapDemap(pdpt_phys_addr);

        // 2. PDPT Entry
        const pdpte_val = pdpt_virt.entries[pdpt_idx];
        if (pdpte_val & PT_PRESENT == 0) return MapperError.NotMapped;
        if (pdpte_val & PT_PAGE_SIZE != 0) return MapperError.UnsupportedPageSize; // No 1GB pages here
        const pd_phys_addr = pdpte_val & PTE_ADDR_MASK;
        return pd_phys_addr;
    }

    pub fn getPageTablePhys(self: *Self, virt_addr: u64) MapperError!u64 {
        if (virt_addr & PAGE_MASK_4K != 0) {
            mapper_log.err("getPageTable: virt_addr 0x{x} not 4K aligned.", .{virt_addr});
            return MapperError.AddressNotAligned;
        }

        const pml4_idx = pml4Index(virt_addr);
        const pdpt_idx = pdptIndex(virt_addr);
        const pd_idx = pdIndex(virt_addr);

        const pml4_virt = self.scratchMapVirt(self.pml4_phys_addr, PageMapLevel4); //getTableVirtPtr(self.pml4_phys_addr, self.kernel_offset, PageMapLevel4);
        defer self.scratchMapDemap(self.pml4_phys_addr);

        // 1. PML4 Entry
        const pml4e_val = pml4_virt.entries[pml4_idx];
        if (pml4e_val & PT_PRESENT == 0) return MapperError.NotMapped;
        if (pml4e_val & PT_PAGE_SIZE != 0) return MapperError.UnsupportedPageSize; // Should be table
        const pdpt_phys_addr = pml4e_val & PTE_ADDR_MASK;
        const pdpt_virt = self.scratchMapVirt(pdpt_phys_addr, PageDirectoryPointerTable); //getTableVirtPtr(pdpt_phys_addr, self.kernel_offset, PageDirectoryPointerTable);
        defer self.scratchMapDemap(pdpt_phys_addr);

        // 2. PDPT Entry
        const pdpte_val = pdpt_virt.entries[pdpt_idx];
        if (pdpte_val & PT_PRESENT == 0) return MapperError.NotMapped;
        if (pdpte_val & PT_PAGE_SIZE != 0) return MapperError.UnsupportedPageSize; // No 1GB pages here
        const pd_phys_addr = pdpte_val & PTE_ADDR_MASK;
        const pd_virt = self.scratchMapVirt(pd_phys_addr, PageDirectory); //getTableVirtPtr(pd_phys_addr, self.kernel_offset, PageDirectory);
        defer self.scratchMapDemap(pd_phys_addr);

        // 3. PD Entry
        const pde_val = pd_virt.entries[pd_idx];
        if (pde_val & PT_PRESENT == 0) return MapperError.NotMapped;
        if (pde_val & PT_PAGE_SIZE != 0) return MapperError.UnsupportedPageSize; // No 2MB pages here
        const pt_phys_addr = pde_val & PTE_ADDR_MASK;
        return pt_phys_addr;
    }

    pub fn unmapAndFreeRange(
        self: *Self,
        start_virt_addr: u64,
        end_virt_addr: u64,
    ) !void {
        if (start_virt_addr & PAGE_MASK_4K != 0 or end_virt_addr & PAGE_MASK_4K != 0) {
            mapper_log.err("unmapAndFreeRange: start_virt_addr 0x{x} or end_virt_addr 0x{x} not 4K aligned.", .{ start_virt_addr, end_virt_addr });
            return MapperError.AddressNotAligned;
        }
        mapper_log.debug("unmapAndFreeRange: start_virt_addr 0x{x}, end_virt_addr 0x{x}", .{ start_virt_addr, end_virt_addr });

        var current_virt = start_virt_addr;
        var i: u64 = 0;
        while (current_virt < end_virt_addr) : (i += 1) {
            const result = self.unmap(current_virt) catch |err| {
                switch (err) {
                    MapperError.NotMapped => {
                        if (i & 0x3ff == 0) mapper_log.warn("unmapAndFreeRange: ~virt_addr 0x{x} not mapped. continuing...\r", .{current_virt});
                        current_virt += PAGE_SIZE_4K;
                        continue; // Not mapped, continue to next address
                        // return MapperError.NotMapped;
                    },
                    MapperError.AddressNotAligned => {
                        mapper_log.err("unmapAndFreeRange: virt_addr 0x{x} not 4K aligned.", .{current_virt});
                        return err; // Address not aligned error
                    },
                    MapperError.UnsupportedPageSize => {
                        mapper_log.err("unmapAndFreeRange: virt_addr 0x{x} has unsupported page size.", .{current_virt});
                        return err; // Unsupported page size error
                    },
                    else => {},
                }
                mapper_log.err("unmapAndFreeRange: Failed to unmap virt_addr 0x{x}: {}", .{ current_virt, err });
                return err; // Propagate the error
            };
            self.free_page_table_frame(result) catch |err| {
                mapper_log.err("unmapAndFreeRange: Failed to free page frame 0x{x}: {}", .{ result, err });
                return err; // Propagate the error
            };
            mapper_verbose_log.info("Unmapped and freed virt 0x{X:0>16}", .{current_virt});
            current_virt += PAGE_SIZE_4K;
        }

        mapper_log.warn("\n", .{});
    }

    /// Unmaps a 4KB virtual page.
    /// `virt_addr` must be 4KB aligned.
    /// Note: This version does not free underlying page table frames if they become empty.
    pub fn unmap(self: *Self, virt_addr: u64) MapperError!u64 {
        if (virt_addr & PAGE_MASK_4K != 0) {
            mapper_log.err("unmap: virt_addr 0x{x} not 4K aligned.", .{virt_addr});
            return MapperError.AddressNotAligned;
        }
        // mapper_log.debug("unmap: Unmapping virt_addr 0x{x}", .{virt_addr});

        const pml4_idx = pml4Index(virt_addr);
        const pdpt_idx = pdptIndex(virt_addr);
        const pd_idx = pdIndex(virt_addr);
        const pt_idx = ptIndex(virt_addr);

        const pml4_virt = self.scratchMapVirt(self.pml4_phys_addr, PageMapLevel4); //getTableVirtPtr(self.pml4_phys_addr, self.kernel_offset, PageMapLevel4);
        defer self.scratchMapDemap(self.pml4_phys_addr);

        // 1. PML4 Entry
        const pml4e_val = pml4_virt.entries[pml4_idx];
        if (pml4e_val & PT_PRESENT == 0) return MapperError.NotMapped;
        if (pml4e_val & PT_PAGE_SIZE != 0) return MapperError.UnsupportedPageSize; // Should be table
        const pdpt_phys_addr = pml4e_val & PTE_ADDR_MASK;
        const pdpt_virt = self.scratchMapVirt(pdpt_phys_addr, PageDirectoryPointerTable); //getTableVirtPtr(pdpt_phys_addr, self.kernel_offset, PageDirectoryPointerTable);
        defer self.scratchMapDemap(pdpt_phys_addr);

        // 2. PDPT Entry
        const pdpte_val = pdpt_virt.entries[pdpt_idx];
        if (pdpte_val & PT_PRESENT == 0) return MapperError.NotMapped;
        if (pdpte_val & PT_PAGE_SIZE != 0) return MapperError.UnsupportedPageSize; // No 1GB pages here
        const pd_phys_addr = pdpte_val & PTE_ADDR_MASK;
        const pd_virt = self.scratchMapVirt(pd_phys_addr, PageDirectory); //getTableVirtPtr(pd_phys_addr, self.kernel_offset, PageDirectory);
        defer self.scratchMapDemap(pd_phys_addr);

        // 3. PD Entry
        const pde_val = pd_virt.entries[pd_idx];
        if (pde_val & PT_PRESENT == 0) return MapperError.NotMapped;
        if (pde_val & PT_PAGE_SIZE != 0) return MapperError.UnsupportedPageSize; // No 2MB pages here
        const pt_phys_addr = pde_val & PTE_ADDR_MASK;
        const pt_virt = self.scratchMapVirt(pt_phys_addr, PageTable); // getTableVirtPtr(pt_phys_addr, self.kernel_offset, PageTable);
        defer self.scratchMapDemap(pt_phys_addr);

        // 4. PT Entry (PTE)
        const pte_ptr = &pt_virt.entries[pt_idx];

        if (pte_ptr.* & PT_PRESENT == 0) return MapperError.NotMapped;

        const result: usize = pte_ptr.* & PTE_ADDR_MASK;
        pte_ptr.* = 0; // Clear the entry (mark as not present)
        invlpg(virt_addr);
        return result;

        // TODO: Implement freeing of page table frames if they become empty.
        // This requires checking all entries in pt_virt, pd_virt, pdpt_virt.
    }

    pub fn initScratchMap(kernel_offset: u64) !void {
        const virt_addr = types.MEMORY_LAYOUT.KERNEL_VIRTUAL_SCRATCH_START;
        const pml4_idx = pml4Index(virt_addr);
        const pdpt_idx = pdptIndex(virt_addr);
        const pd_idx = pdIndex(virt_addr);

        const pml4_virt = getTableVirtPtr(currentPML4(), kernel_offset, PageMapLevel4);
        const pml4e_val = pml4_virt.entries[pml4_idx];
        std.log.debug("PML4E at index {}: 0x{X:0>16}", .{ pml4_idx, pml4e_val });

        if (pml4e_val & PT_PRESENT == 0) {
            pml4_virt.entries[pml4_idx] = @as(u64, @intFromPtr(&scratch_pdpt) - kernel_offset) | PT_PRESENT;
        }
        std.log.debug("-> PML4E at index {}: 0x{X:0>16}", .{ pml4_idx, pml4_virt.entries[pml4_idx] });

        const pdpt_phys_addr = pml4_virt.entries[pml4_idx] & PTE_ADDR_MASK;
        const pdpt_virt = getTableVirtPtr(pdpt_phys_addr, kernel_offset, PageDirectoryPointerTable);
        const pdpte_val = pdpt_virt.entries[pdpt_idx];
        std.log.debug("PDPTE at index {}: 0x{X:0>16}", .{ pdpt_idx, pdpte_val });

        if (pdpte_val & PT_PRESENT == 0) {
            pdpt_virt.entries[pdpt_idx] = @as(u64, @intFromPtr(&scratch_pd) - kernel_offset) | PT_PRESENT;
        }
        std.log.debug("-> PDPTE at index {}: 0x{X:0>16}", .{ pdpt_idx, pdpt_virt.entries[pdpt_idx] });

        const pd_phys_addr = pdpt_virt.entries[pdpt_idx] & PTE_ADDR_MASK;
        const pd_virt = getTableVirtPtr(pd_phys_addr, kernel_offset, PageDirectory);
        pd_virt.entries[pd_idx] = @as(u64, @intFromPtr(&scratch_pt) - kernel_offset) | PT_PRESENT;
        std.log.debug("PDE at index {}: 0x{X:0>16}", .{ pd_idx, pd_virt.entries[pd_idx] });
    }

    // TODO @(dleiferives,ef3d975c-0197-429e-a412-1d843561e43a): Update scratch
    // map to be setup on mapper initilization! ~#
    pub fn scratchMapVirt(self: *Self, phys_addr: u64, comptime return_type: type) *return_type {
        _ = self;
        for (0..PAGE_TABLE_ENTRY_COUNT) |i| {
            if (scratch_pt.entries[i] & PT_PRESENT == 0) {
                // we've found the entry that we're going to write to / we will use
                scratch_pt.entries[i] = phys_addr & PTE_ADDR_MASK | PT_PRESENT | PT_WRITABLE;
                // std.log.debug("scratchMapVirt: Mapping physical address 0x{X:0>16} to virtual index {} in scratch map", .{phys_addr, i});
                invlpg(types.MEMORY_LAYOUT.KERNEL_VIRTUAL_SCRATCH_START + (i * PAGE_SIZE_4K));
                return @ptrFromInt(types.MEMORY_LAYOUT.KERNEL_VIRTUAL_SCRATCH_START + (i * PAGE_SIZE_4K));
            }
        }
        @panic("scratchMapVirt: No free entry in scratch map");
    }

    pub fn scratchMapDemap(self: *Self, phys_addr: u64) void {
        _ = self;
        for (0..PAGE_TABLE_ENTRY_COUNT) |i| {
            if (scratch_pt.entries[i] & PTE_ADDR_MASK == phys_addr & PTE_ADDR_MASK) {
                scratch_pt.entries[i] = 0;
                invlpg(types.MEMORY_LAYOUT.KERNEL_VIRTUAL_SCRATCH_START + (i * PAGE_SIZE_4K));
                return;
            }
        }
        @panic("scratchMapDemap: Address not found in scratch map");
    }

    /// Translates a virtual address to its corresponding physical address.
    pub fn translate(self: *Self, virt_addr: u64) ?u64 {
        mapper_translate_log.debug("Translating 0x{X}", .{virt_addr});
        const pml4_idx = pml4Index(virt_addr);
        const pdpt_idx = pdptIndex(virt_addr);
        const pd_idx = pdIndex(virt_addr);
        const pt_idx = ptIndex(virt_addr);
        const page_offset = virt_addr & PAGE_MASK_4K;

        const pml4_virt = self.scratchMapVirt(self.pml4_phys_addr, PageMapLevel4); //getTableVirtPtr(self.pml4_phys_addr, self.kernel_offset, PageMapLevel4);
        defer self.scratchMapDemap(self.pml4_phys_addr);
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
        const pdpt_virt = self.scratchMapVirt(pdpt_phys_addr, PageDirectoryPointerTable); //getTableVirtPtr(pdpt_phys_addr, self.kernel_offset, PageDirectoryPointerTable);
        defer self.scratchMapDemap(pdpt_phys_addr);

        // 2. PDPT Entry
        const pdpte_val = pdpt_virt.entries[pdpt_idx];
        if (pdpte_val & PT_PRESENT == 0) return null;
        if (pdpte_val & PT_PAGE_SIZE != 0) { // 1GB Page
            const frame_1gb_addr = pdpte_val & PDPE_1GB_ADDR_MASK;
            return frame_1gb_addr + (virt_addr & PAGE_MASK_1GB);
        }
        const pd_phys_addr = pdpte_val & PTE_ADDR_MASK;
        const pd_virt = self.scratchMapVirt(pd_phys_addr, PageDirectory); //getTableVirtPtr(pd_phys_addr, self.kernel_offset, PageDirectory);
        defer self.scratchMapDemap(pd_phys_addr);

        // 3. PD Entry
        const pde_val = pd_virt.entries[pd_idx];
        if (pde_val & PT_PRESENT == 0) return null;
        if (pde_val & PT_PAGE_SIZE != 0) { // 2MB Page
            const frame_2mb_addr = pde_val & PDE_2MB_ADDR_MASK;
            return frame_2mb_addr + (virt_addr & PAGE_MASK_2MB);
        }
        const pt_phys_addr = pde_val & PTE_ADDR_MASK;
        const pt_virt = self.scratchMapVirt(pt_phys_addr, PageTable); // getTableVirtPtr(pt_phys_addr, self.kernel_offset, PageTable);
        defer self.scratchMapDemap(pt_phys_addr);

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
