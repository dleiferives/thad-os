const std = @import("std");
const mem = @import("../mem.zig");
const log = std.log.scoped(.mem_allocator);
const log_verbose = std.log.scoped(.mem_allocator_verbose);

pub const Header = packed struct {
    next: ?*Header,
    size: u32, // Size of usable space (excluding header)
    free: bool,
    _padding1: u8 = 0,
    _padding2: u8 = 0,
    _padding3: u8 = 0,

    pub const Iterator = struct {
        current: ?*Header,
        visited_count: usize = 0,
        max_visits: usize,

        pub fn next(self: *@This()) ?*Header {
            // Prevent infinite loops
            if (self.visited_count >= self.max_visits) return null;

            if (self.current) |cur| {
                const tmp = self.current;
                self.current = cur.next;
                self.visited_count += 1;
                return tmp;
            }
            return null;
        }
    };

    pub fn iterator(self: *Header, max_blocks: usize) Iterator {
        return .{ .current = self, .max_visits = max_blocks };
    }

    pub fn getDataPtr(self: *Header) [*]u8 {
        return @as([*]u8, @ptrCast(self)) + @sizeOf(Header);
    }

    pub fn getEndPtr(self: *Header) [*]u8 {
        return @as([*]u8, @ptrCast(self)) + @sizeOf(Header) + self.size;
    }

    pub fn getTotalSize(self: *Header) usize {
        return @sizeOf(Header) + self.size;
    }

    pub fn isAdjacent(self: *Header, other: *Header) bool {
        return self.getEndPtr() == @as([*]u8, @ptrCast(other)) or
               other.getEndPtr() == @as([*]u8, @ptrCast(self));
    }

    pub fn canFit(self: *Header, size: usize, alignment: std.mem.Alignment) bool {
        if (!self.free) return false;

        const data_ptr = self.getDataPtr();
        const aligned_ptr: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(data_ptr), alignment.toByteUnits()));
        const offset = @intFromPtr(aligned_ptr) - @intFromPtr(data_ptr);

        return (offset + size) <= self.size;
    }

    // Returns true if a split occurred, false if using whole block
    pub fn split(self: *Header, size: usize, alignment: std.mem.Alignment) bool {
        if (!self.canFit(size, alignment)) return false;

        const data_ptr = self.getDataPtr();
        const aligned_ptr: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(data_ptr), alignment.toByteUnits()));
        const offset = @intFromPtr(aligned_ptr) - @intFromPtr(data_ptr);

        // Calculate how much space we actually need (including alignment offset)
        const space_needed = offset + size;

        // Align the position for the next header to @sizeOf(Header) boundary
        const unaligned_remainder_pos = @intFromPtr(self.getDataPtr()) + space_needed;
        const aligned_remainder_pos = std.mem.alignForward(usize, unaligned_remainder_pos, @sizeOf(Header));
        const actual_space_used = aligned_remainder_pos - @intFromPtr(self.getDataPtr());

        // Calculate remaining space after this allocation and header alignment
        const remaining_total_space = self.size - actual_space_used;

        // If there's not enough space left for a meaningful block, use the whole block
        if (remaining_total_space < @sizeOf(Header) + 8) {
            self.free = false;
            log_verbose.info("Using whole block: size={}, needed={}", .{self.size, space_needed});
            return false; // No split occurred
        }

        // Place the remainder header at the aligned position
        const new_header: *Header = @ptrFromInt(aligned_remainder_pos);

        // Initialize the remainder header
        new_header.* = Header{
            .next = self.next,
            .size = @intCast(remaining_total_space - @sizeOf(Header)),
            .free = true,
        };

        // Update current header to point to remainder and mark as allocated
        self.next = new_header;
        self.size = @intCast(actual_space_used);
        self.free = false;

        log_verbose.info("Split block: allocated_size={}, remainder_size={}, remainder_pos=0x{x}", .{
            actual_space_used,
            new_header.size,
            aligned_remainder_pos
        });

        return true; // Split occurred
    }
};

comptime {
    std.debug.assert(@sizeOf(Header) == 16);
}

pub const FreeListAllocator = struct {
    headers: ?*Header,
    start: usize,
    end: usize,
    mapper: *mem.Mapper,
    flags: mem.PageFlags,
    total_blocks: usize,

    pub const MIN_ALLOC_SIZE = 8;
    pub const MAX_BLOCKS = 10000; // Prevent infinite loops

    pub fn init(start: usize, initial_size: usize, mapper: *mem.Mapper, flags: mem.PageFlags) !FreeListAllocator {
        if (initial_size < @sizeOf(Header) + MIN_ALLOC_SIZE) {
            return error.InitialSizeTooSmall;
        }

        var allocator_er = FreeListAllocator{
            .headers = null,
            .start = start,
            .end = start + initial_size,
            .flags = flags,
            .mapper = mapper,
            .total_blocks = 1,
        };

        log.info("Initializing FreeListAllocator at 0x{x} with size {d}", .{ start, initial_size });

        const demand_state = try allocator_er.mapper.mapDemandRange(start, initial_size, flags);
        if (!demand_state) {
            return error.MappingFailed;
        }

        // Initialize first header
        allocator_er.headers = @ptrFromInt(start);
        allocator_er.headers.?.* = Header{
            .next = null,
            .size = @intCast(initial_size - @sizeOf(Header)),
            .free = true,
        };

        return allocator_er;
    }

    pub fn allocator(self: *FreeListAllocator) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &std.mem.Allocator.VTable{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    fn findHeader(self: *FreeListAllocator, ptr: [*]u8) ?*Header {
        if (self.headers == null) return null;

        var iter = self.headers.?.iterator(self.total_blocks);
        while (iter.next()) |header| {
            const data_start = @intFromPtr(header.getDataPtr());
            const data_end = data_start + header.size;
            const ptr_addr = @intFromPtr(ptr);

            if (ptr_addr >= data_start and ptr_addr < data_end) {
                return header;
            }
        }
        return null;
    }

    fn coalesceFreeBLocks(self: *FreeListAllocator) void {
        if (self.headers == null) return;

        var changed = true;
        while (changed) {
            changed = false;
            var iter = self.headers.?.iterator(self.total_blocks);
            while (iter.next()) |header| {
                if (!header.free) continue;

                // Try to coalesce with next block
                if (header.next) |next_header| {
                    if (next_header.free and header.isAdjacent(next_header)) {
                        header.size += @sizeOf(Header) + next_header.size;
                        header.next = next_header.next;
                        self.total_blocks -= 1;
                        changed = true;
                        log_verbose.info("Coalesced blocks, new size: {}", .{header.size});
                        break; // Restart iteration
                    }
                }
            }
        }
    }

    fn findFreeBlock(self: *FreeListAllocator, size: usize, alignment: std.mem.Alignment) ?*Header {
        if (self.headers == null) return null;

        var iter = self.headers.?.iterator(self.total_blocks);
        while (iter.next()) |header| {
            if (header.canFit(size, alignment)) {
                log_verbose.info("Found suitable block: size={}, needed={}, free={}", .{header.size, size, header.free});
                return header;
            }
        }
        return null;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        if (len == 0) return null;

        var self: *FreeListAllocator = @ptrCast(@alignCast(ctx));
        const size = std.mem.alignForward(usize, @max(len, MIN_ALLOC_SIZE), @sizeOf(usize));

        log_verbose.info("Allocating {} bytes (rounded to {})", .{len, size});

        // Try to coalesce free blocks first
        self.coalesceFreeBLocks();

        if (self.findFreeBlock(size, alignment)) |header| {
            const split_occurred = header.split(size, alignment);
            if (split_occurred) {
                self.total_blocks += 1; // We created a new remainder block
            }

            const data_ptr = header.getDataPtr();
            const aligned_ptr: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(data_ptr), alignment.toByteUnits()));

            // Zero out the memory
            @memset(aligned_ptr[0..len], 0);

            log_verbose.info("Allocated {} bytes at 0x{x}", .{ len, @intFromPtr(aligned_ptr) });
            return aligned_ptr;
        }

        log.info("Allocation failed: no suitable block found for {} bytes", .{size});
        self.debugPrint();
        return null;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        if (new_len == 0) return false;

        var self: *FreeListAllocator = @ptrCast(@alignCast(ctx));

        if (self.findHeader(buf.ptr)) |header| {
            if (!header.free) {
                const new_size = std.mem.alignForward(usize, @max(new_len, MIN_ALLOC_SIZE), @sizeOf(usize));
                const data_ptr = header.getDataPtr();
                const aligned_ptr: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(data_ptr), buf_align.toByteUnits()));
                const offset = @intFromPtr(aligned_ptr) - @intFromPtr(data_ptr);

                // Check if we can shrink
                if (new_size <= header.size - offset) {
                    log_verbose.info("Resized allocation from {} to {} bytes", .{ buf.len, new_len });
                    return true;
                }
            }
        }

        return false;
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        if (new_len == 0) return null;

        // Try resize first
        if (resize(ctx, buf, buf_align, new_len, ret_addr)) {
            return buf.ptr;
        }

        // If resize failed, allocate new memory, copy, and free old
        if (alloc(ctx, new_len, buf_align, ret_addr)) |new_ptr| {
            const copy_len = @min(buf.len, new_len);
            @memcpy(new_ptr[0..copy_len], buf[0..copy_len]);
            free(ctx, buf, buf_align, ret_addr);
            return new_ptr;
        }

        return null;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = buf_align;
        _ = ret_addr;

        var self: *FreeListAllocator = @ptrCast(@alignCast(ctx));

        if (self.findHeader(buf.ptr)) |header| {
            if (!header.free) {
                header.free = true;
                log_verbose.info("Freed {} bytes at 0x{x}", .{ buf.len, @intFromPtr(buf.ptr) });

                // Coalesce immediately after freeing
                self.coalesceFreeBLocks();
            }
        }
    }

    pub fn debugPrint(self: *FreeListAllocator) void {
        if (self.headers == null) {
            log.info("No headers", .{});
            return;
        }

        log.info("=== Allocator Debug Info ===", .{});
        log.info("Total blocks: {}", .{self.total_blocks});

        var iter = self.headers.?.iterator(self.total_blocks);
        var count: usize = 0;
        while (iter.next()) |header| {
            log.info("Block {}: ptr=0x{x}, data=0x{x}, size={}, free={}", .{
                count,
                @intFromPtr(header),
                @intFromPtr(header.getDataPtr()),
                header.size,
                header.free,
            });
            count += 1;
        }
    }

    pub fn tester(self: *FreeListAllocator) !void {
        const alloca = self.allocator();
        log.info("Starting allocator test!", .{});

        // Test basic allocation
        log.info("Allocating 10 bytes...", .{});
        const bytes = try alloca.alloc(u8, 10);
        defer alloca.free(bytes);

        // Test the memory
        for (bytes, 0..) |*byte, i| {
            byte.* = @truncate(i);
        }

        for (bytes, 0..) |byte, i| {
            if (i != byte) {
                log.err("Memory corruption detected at index {}", .{i});
                return error.MemoryCorruption;
            }
        }

        log.info("Basic allocation test passed!", .{});
        self.debugPrint();

        // Test multiple allocations with simpler sizes first
        log.info("Testing multiple small allocations...", .{});
        var allocs: [3][]u8 = undefined;
        for (&allocs, 0..) |*alloc_ptr, i| {
            const alloc_size = (i + 1) * 8; // Start with smaller sizes
            log.info("Allocating {} bytes...", .{alloc_size});
            alloc_ptr.* = try alloca.alloc(u8, alloc_size);
            log.info("Successfully allocated {} bytes", .{alloc_size});
            self.debugPrint();
        }

        log.info("Freeing allocations...", .{});
        for (allocs, 0..) |allocation, i| {
            log.info("Freeing allocation {}", .{i});
            alloca.free(allocation);
        }

        self.debugPrint();
        log.info("All tests passed!", .{});
    }
};
