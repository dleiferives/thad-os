//! Types and constants related to memory addressing and organization
const std = @import("std");
// const frame_allocator = @import("frame_allocator.zig");

// const PAGE_SIZE = frame_allocator.PAGE_SIZE;
pub const PAGE_SIZE: u64 = 4096; // 4 KiB

/// Address space layout constants
pub const MEMORY_LAYOUT = struct {
    // Canonical address limitation (48-bit addressing)
    pub const CANONICAL_MASK: u64 = 0xFFFF_0000_0000_0000;

    pub const USER_START: u64 = 0x0000_0000_0000_0000;
    pub const USER_END: u64 = 0x0000_003F_FFFF_FFFF;
    pub const KERNEL_START: u64 = 0xFFFF_FF80_0000_0000;
    pub const KERNEL_END: u64 = 0xFFFF_FFFF_FFFF_FFFF;

    pub const CANNONICAL_MASK: u64 = 0xFFFF_8000_0000_0000; // Canonical address mask for 48-bit addressing
};

/// Physical memory address
pub const PhysAddr = struct {
    value: u64,

    pub inline fn new(addr: u64) PhysAddr {
        return .{ .value = addr};
    }

    pub inline fn newAligned(addr: u64) PhysAddr {
        // Assert the address is page-aligned
        if (addr & (PAGE_SIZE - 1) != 0) {
            // @panic("PhysAddr must be page-aligned");
        }
        return .{ .value = addr };
    }

    pub inline fn add(self: *PhysAddr, offset: u64) void {
        self.value += offset;
    }

    pub inline fn toVirtual(self: PhysAddr) VirtAddr {
        // Map to the direct physical mapping region
        return VirtAddr.new(MEMORY_LAYOUT.KERNEL_START | self.value);
    }

    pub inline fn fromPointer(ptr: anytype) PhysAddr {
        return PhysAddr.new(@intFromPtr(ptr));
    }
};

/// Virtual memory address
pub const VirtAddr = struct {
    value: u64,

    pub inline fn new(addr: u64) VirtAddr {
        // TODO @(dleiferives,0e54c7e7-b126-4d08-afc4-0c8eaa7ac294): Add
        // cannonical support for virtural addressing, namely that the upper bits
        // from 47 up have to be the same... ~#
        if ((addr >> 47) & 0x1 == 1) {
            if((addr & MEMORY_LAYOUT.CANONICAL_MASK) != MEMORY_LAYOUT.CANONICAL_MASK) {
                // if(frame_allocator.global_allocator) |_|{
                    // @panic("VirtAddr must be canonical 0x{x} 0x{x}");
                    // fa.writer.print("VirtAddr must be canonical 0x{x} 0x{x}", .{addr, addr >> 47 & 0x1}) catch {};
                // }
            }
        } else {
            if ((addr & MEMORY_LAYOUT.CANONICAL_MASK) != 0) {
                // if(frame_allocator.global_allocator) |_|{

                    // @panic("VirtAddr must be canonical 0x{x} 0x{x}");
                    // fa.writer.print("VirtAddr must be canonical should start with 0 0x{x} 0x{x}", .{addr, addr >> 47 & 0x1}) catch {};
                // }
            }
        }
        return .{ .value = addr };
    }

    pub inline fn newAligned(addr: u64) VirtAddr {
        if (addr & (PAGE_SIZE - 1) != 0) {
            // @panic("VirtAddr must be page-aligned");
        }
        return .{ .value = addr };
    }

    pub inline fn add(self: *VirtAddr, offset: u64) void {
        self.value += offset;
    }

    pub inline fn isNull(self: VirtAddr) bool {
        return self.value == 0;
    }

    pub inline fn isCanonical(self: VirtAddr) bool {
        const bit47 = (self.value >> 47) & 1;
        const upper_bits = (self.value >> 48) & 0xFFFF;
        return (bit47 == 1 and upper_bits == 0xFFFF) or
               (bit47 == 0 and upper_bits == 0);
    }

    pub inline fn isKernelAddress(self: VirtAddr) bool {
        return self.value >= MEMORY_LAYOUT.KERNEL_START;
    }

    pub inline fn isUserAddress(self: VirtAddr) bool {
        return self.value <= MEMORY_LAYOUT.USER_END;
    }

    pub inline fn toPhysical(self: VirtAddr) PhysAddr {
        return PhysAddr.new(self.value - MEMORY_LAYOUT.KERNEL_START);
    }

    pub inline fn fromPointer(ptr: anytype) VirtAddr {
        return VirtAddr.new(@intFromPtr(ptr));
    }
};
