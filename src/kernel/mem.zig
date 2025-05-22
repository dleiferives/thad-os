pub const std = @import("std");
pub const types = @import("mem/types.zig");
const multiboot = @import("multiboot.zig");
const PageBitField = @import("mem/page_bitfield.zig").PageBitField;

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

        // Don't think that I need this
        // // Add the kernel physical range to the reserved physical ranges
        // and I was wrong I did need it lmao
        r_physical.append(types.MemoryRange{
            .start = kp_range.start,
            .end = kp_range.end,
        }) catch |err| {
            std.log.debug("Error appending reserved physical range: {}\n", .{err});
        };

        std.log.debug("starting cleaning up physical ranges", .{});

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
                const disjoint = reserved.disjoint(reserved);
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
