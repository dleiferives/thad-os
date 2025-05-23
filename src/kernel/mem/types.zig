//! Types and constants related to memory addressing and organization
const std = @import("std");
// const frame_allocator = @import("frame_allocator.zig");

const layout_log = std.log.scoped(.mem_layout);

// const PAGE_SIZE = frame_allocator.PAGE_SIZE;
pub const PAGE_SIZE: u64 = 4096; // 4 KiB

/// Address space layout constants
pub const MEMORY_LAYOUT = struct {
    // Canonical address limitation (48-bit addressing)
    kernel_offset: u64,
    kernel_virtual_address_start: u64,
    kernel_virtual_address_end: u64,
    kernel_physical_address_start: u64,
    kernel_physical_address_end: u64,
    kernel_virtual_stack_start: u64,
    kernel_virtual_stack_end: u64,

    pub const CANONICAL_MASK: u64 = 0xFFFF_0000_0000_0000;
    pub extern const KERNEL_VIRTUAL_ADDRESS_START: u64;
    pub extern const KERNEL_VIRTUAL_ADDRESS_END: u64;
    pub extern const KERNEL_PHYSICAL_ADDRESS_START: u64;
    pub extern const KERNEL_PHYSICAL_ADDRESS_END: u64;
    pub extern const KERNEL_VIRTUAL_STACK_START: u64;
    pub extern const KERNEL_VIRTUAL_STACK_END: u64;
    pub extern const KERNEL_OFFSET: u64;

    pub fn log(self: *const MEMORY_LAYOUT) void{
        layout_log.info("Kernel virtual address start: {x}", .{self.kernel_virtual_address_start});
        layout_log.info("Kernel virtual address end: {x}", .{self.kernel_virtual_address_end});
        layout_log.info("Kernel physical address start: {x}", .{self.kernel_physical_address_start});
        layout_log.info("Kernel physical address end: {x}", .{self.kernel_physical_address_end});
        layout_log.info("Kernel virtual stack start: {x}", .{self.kernel_virtual_stack_start});
        layout_log.info("Kernel virtual stack end: {x}", .{self.kernel_virtual_stack_end});
        layout_log.info("Kernel offset: {x}", .{self.kernel_offset});
    }

    pub fn init() MEMORY_LAYOUT {
        layout_log.info("Initializing memory layout", .{});
        const result = MEMORY_LAYOUT{
            .kernel_offset = @intFromPtr(&MEMORY_LAYOUT.KERNEL_OFFSET),
            .kernel_virtual_address_start = @intFromPtr(&MEMORY_LAYOUT.KERNEL_VIRTUAL_ADDRESS_START),
            .kernel_virtual_address_end = @intFromPtr(&MEMORY_LAYOUT.KERNEL_VIRTUAL_ADDRESS_END),
            .kernel_physical_address_start = @intFromPtr(&MEMORY_LAYOUT.KERNEL_PHYSICAL_ADDRESS_START),
            .kernel_physical_address_end = @intFromPtr(&MEMORY_LAYOUT.KERNEL_PHYSICAL_ADDRESS_END),
            .kernel_virtual_stack_start = @intFromPtr(&MEMORY_LAYOUT.KERNEL_VIRTUAL_STACK_START),
            .kernel_virtual_stack_end = @intFromPtr(&MEMORY_LAYOUT.KERNEL_VIRTUAL_STACK_END),
        };
        result.log();
        return result;
    }

    pub inline fn rangeFomKernelPhysical(self: *MEMORY_LAYOUT) MemoryRange {
        return MemoryRange{
            .start = self.kernel_physical_address_start,
            .end = self.kernel_physical_address_end,
        };
    }

    pub inline fn rangeFomKernelVirtual(self: *MEMORY_LAYOUT) MemoryRange {
        return MemoryRange{
            .start = self.kernel_virtual_address_start,
            .end = self.kernel_virtual_address_end,
        };
    }

    pub inline fn rangeFomKernelStack(self: *MEMORY_LAYOUT) MemoryRange {
        return MemoryRange{
            .start = self.kernel_virtual_stack_start,
            .end = self.kernel_virtual_stack_end,
        };
    }
};


/// This structure represents a range of memory.
/// It is the basis of the memory allocator.
/// Range -> Map -> Manager -> Allocator
pub const MemoryRange = struct {
    start: u64,
    end: u64,


    // self explanitory helper functions
    pub inline fn get_size(self: MemoryRange) u64 {
        return self.end - self.start;
    }
    pub inline fn is_empty(self: MemoryRange) bool {
        return self.start == self.end;
    }
    pub inline fn is_valid(self: MemoryRange) bool {
        return self.start < self.end;
    }
    pub inline fn contains(self: MemoryRange, addr: u64) bool {
        return addr >= self.start and addr < self.end;
    }
    pub inline fn contains_range(self: MemoryRange, other: MemoryRange) bool {
        return self.start <= other.start and self.end > other.end;
    }
    pub inline fn overlaps(self: MemoryRange, other: MemoryRange) bool {
        return (self.start <= other.start and self.end > other.start)
            or (self.start >= other.start and self.start < other.end);
    }
    pub inline fn disjoint(self: MemoryRange, other: MemoryRange) MemoryRange {
        if (self.overlaps(other)) {
            if (self.start <= other.start) {
                return MemoryRange{
                    .start = self.start,
                    .end = other.start,
                };
            } else if (self.end >= other.end) {
                return MemoryRange{
                    .start = other.end,
                    .end = self.end,
                };
            }
        }
        return self;
    }

    // Subtracts 'other' from 'self'. Returns up to two disjoint ranges.
    // Result is stored in a small array to avoid allocation.
    pub fn subtract(self: MemoryRange, other: MemoryRange) [2]MemoryRange {
        var result: [2]MemoryRange = .{ .{.start=0,.end=0}, .{.start=0,.end=0} };
        var count: usize = 0;

        if (!self.overlaps(other)) {
            result[count] = self;
            count += 1;
            return result;
        }

        // Part of self before other
        if (self.start < other.start) {
            result[count] = .{ .start = self.start, .end = @min(self.end, other.start) };
            if (result[count].is_valid()) count += 1;
        }

        // Part of self after other
        if (self.end > other.end) {
            result[count] = .{ .start = @max(self.start, other.end), .end = self.end };
            if (result[count].is_valid()) count += 1;
        }
        return result;
    }


};


pub const MemoryMap = struct {
    virtual: MemoryRange,
    physical: ?MemoryRange,

    pub inline fn new(virtual: MemoryRange, physical: MemoryRange) MemoryMap {
        return MemoryMap{
            .virtual = virtual,
            .physical = physical,
        };
    }

    pub inline fn toPhysical(self: *MemoryMap, addr: u64) ?u64 {
        if (self.virtual.contains(addr)) {
            return self.physical.start + (addr - self.virtual.start);
        }
        return null;
    }

    pub inline fn toVirtual(self: *MemoryMap, addr: u64) ?u64 {
        if (self.physical.contains(addr)) {
            return self.virtual.start + (addr - self.physical.start);
        }
        return null;
    }
};
