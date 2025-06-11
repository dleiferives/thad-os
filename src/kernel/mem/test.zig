const std = @import("std");
const mem = @import("../mem.zig");
const Mapper = mem.Mapper;
const PageFlags = mem.PageFlags;
const PAGE_SIZE_4K = mem.PAGE_SIZE_4K;
const PAGE_MASK_4K = mem.PAGE_MASK_4K;

const test_log = std.log.scoped(.mapper_tests);

pub fn runMapperTests(allocator: std.mem.Allocator, base_mapper: *Mapper) !void {
    test_log.info("Running mapper deep copy tests...", .{});

    try testCreateUserAddressSpace(allocator, base_mapper);
    try testCopyMemoryRange(allocator, base_mapper);
    try testDeepClone(allocator, base_mapper);
    try testUpdatePageFlags(allocator, base_mapper);

    test_log.info("All mapper tests passed!", .{});
}

fn testCreateUserAddressSpace(allocator: std.mem.Allocator, base_mapper: *Mapper) !void {
    test_log.info("Testing createUserAddressSpace...", .{});

    const user_mapper = try base_mapper.createUserAddressSpace(allocator);
    defer user_mapper.deinit();

    const kernel_test_addr: u64 = 0xFFFFFF8000000000;
    const kernel_phys = base_mapper.translate(kernel_test_addr);
    const user_kernel_phys = user_mapper.translate(kernel_test_addr);

    if (kernel_phys != user_kernel_phys) {
        test_log.err("Kernel space not properly shared", .{});
        return error.TestFailed;
    }

    const user_test_addr: u64 = 0x400000;
    const user_phys = user_mapper.translate(user_test_addr);

    if (user_phys != null) {
        test_log.err("User space should be empty in new address space", .{});
        return error.TestFailed;
    }

    test_log.info("createUserAddressSpace test passed", .{});
}

fn testCopyMemoryRange(allocator: std.mem.Allocator, base_mapper: *Mapper) !void {
    test_log.info("Testing copyMemoryRange...", .{});

    const dest_mapper = try base_mapper.createUserAddressSpace(allocator);
    defer dest_mapper.deinit();

    const src_start: u64 = 0x10000000;
    const size: u64 = 4 * PAGE_SIZE_4K;
    const test_data = [_]u64{ 0xDEADBEEF, 0xCAFEBABE, 0x12345678, 0x87654321 };

    const flags = PageFlags{
        .present = true,
        .writable = true,
        .user_accessible = true,
        .demand_alloc = false,
    };

    try base_mapper.mapRange(src_start, src_start + size, flags);

    for (test_data, 0..) |data, i| {
        const addr = src_start + (i * PAGE_SIZE_4K);
        const ptr: *u64 = @ptrFromInt(addr);
        ptr.* = data;
    }

    const dest_start: u64 = 0x20000000;
    try base_mapper.copyMemoryRange(dest_mapper, src_start, dest_start, size, flags);

    const original_pml4 = Mapper.currentPML4();

    Mapper.loadPML4(dest_mapper.pml4_phys_addr);

    for (test_data, 0..) |expected_data, i| {
        const addr = dest_start + (i * PAGE_SIZE_4K);

        if (dest_mapper.translate(addr) == null) {
            Mapper.loadPML4(original_pml4);
            test_log.err("Page {} not mapped in destination", .{i});
            return error.TestFailed;
        }

        const ptr: *u64 = @ptrFromInt(addr);
        if (ptr.* != expected_data) {
            Mapper.loadPML4(original_pml4);
            test_log.err("Data mismatch at page {}: expected 0x{X}, got 0x{X}", .{ i, expected_data, ptr.* });
            return error.TestFailed;
        }
    }

    Mapper.loadPML4(original_pml4);

    try base_mapper.unmapAndFreeRangeFull(src_start, src_start + size);
    try dest_mapper.unmapAndFreeRangeFull(dest_start, dest_start + size);

    test_log.info("copyMemoryRange test passed", .{});
}

fn testDeepClone(allocator: std.mem.Allocator, base_mapper: *Mapper) !void {
    test_log.info("Testing deepClone...", .{});

    const test_start: u64 = 0x30000000;
    const test_size: u64 = 2 * PAGE_SIZE_4K;
    const test_values = [_]u32{ 0xABCDEF00, 0x11223344 };

    const flags = PageFlags{
        .present = true,
        .writable = true,
        .user_accessible = true,
        .demand_alloc = false,
    };

    try base_mapper.mapRange(test_start, test_start + test_size, flags);

    for (test_values, 0..) |value, i| {
        const addr = test_start + (i * PAGE_SIZE_4K);
        const ptr: *u32 = @ptrFromInt(addr);
        ptr.* = value;
    }

    const cloned_mapper = try base_mapper.deepClone(allocator);
    defer cloned_mapper.deinit();

    for (test_values, 0..) |expected_value, i| {
        const addr = test_start + (i * PAGE_SIZE_4K);

        if (cloned_mapper.translate(addr) == null) {
            test_log.err("Page {} not mapped in clone", .{i});
            return error.TestFailed;
        }

        const ptr: *u32 = @ptrFromInt(addr);
        if (ptr.* != expected_value) {
            test_log.err("Data mismatch in clone at page {}: expected 0x{X}, got 0x{X}", .{ i, expected_value, ptr.* });
            return error.TestFailed;
        }
    }

    const first_page_ptr: *u32 = @ptrFromInt(test_start);
    const original_value = first_page_ptr.*;
    first_page_ptr.* = 0xDEADBEEF;

    const original_pml4 = base_mapper.pml4_phys_addr;
    Mapper.loadPML4(cloned_mapper.pml4_phys_addr);

    const clone_ptr: *u32 = @ptrFromInt(test_start);
    const clone_value = clone_ptr.*;

    Mapper.loadPML4(original_pml4);

    if (clone_value != original_value) {
        test_log.err("Clone was affected by changes to original: clone=0x{X}, expected=0x{X}", .{ clone_value, original_value });
        return error.TestFailed;
    }

    try base_mapper.unmapAndFreeRangeFull(test_start, test_start + test_size);
    try cloned_mapper.unmapAndFreeRangeFull(test_start, test_start + test_size);

    test_log.info("deepClone test passed", .{});
}

fn testUpdatePageFlags(allocator: std.mem.Allocator, base_mapper: *Mapper) !void {
    _ = allocator;
    test_log.info("Testing updatePageFlags...", .{});

    const test_addr: u64 = 0x40000000;

    const writable_flags = PageFlags{
        .present = true,
        .writable = true,
        .user_accessible = true,
        .demand_alloc = false,
    };

    try base_mapper.mapRange(test_addr, test_addr + PAGE_SIZE_4K, writable_flags);

    const ptr: *u32 = @ptrFromInt(test_addr);
    ptr.* = 0x12345678;

    const readonly_flags = PageFlags{
        .present = true,
        .writable = false,
        .user_accessible = true,
        .demand_alloc = false,
    };

    try base_mapper.updatePageFlags(test_addr, readonly_flags);

    const read_value = ptr.*;
    if (read_value != 0x12345678) {
        test_log.err("Read failed after making page read-only", .{});
        return error.TestFailed;
    }

    try base_mapper.unmapAndFreeRangeFull(test_addr, test_addr + PAGE_SIZE_4K);

    test_log.info("updatePageFlags test passed", .{});
}
