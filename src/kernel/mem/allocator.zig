const std = @import("std");
const mem = @import("../mem.zig");
const log = std.log.scoped(.mem_allocator);
const log_verbose = std.log.scoped(.mem_allocator_verbose);

pub const Header = packed struct {
    next: ?*Header,
    size: u32, // Size of usable space (excluding header)
    allocator_id: u16, // ID of the allocator that allocated this block
    free: bool,
    _padding1: u8 = 0,

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
    pub fn split(self: *Header, size: usize, alignment: std.mem.Alignment, allocator_id: u16) bool {
        if (!self.canFit(size, alignment)) return false;

        const data_ptr = self.getDataPtr();
        const aligned_ptr: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(data_ptr), alignment.toByteUnits()));
        const offset = @intFromPtr(aligned_ptr) - @intFromPtr(data_ptr);

        // Calculate how much space we actually need (with alignment)
        const space_needed = offset + size;

        // Find next position
        const unaligned_remainder_pos = @intFromPtr(self.getDataPtr()) + space_needed;
        const aligned_remainder_pos = std.mem.alignForward(usize, unaligned_remainder_pos, @sizeOf(Header));
        const actual_space_used = aligned_remainder_pos - @intFromPtr(self.getDataPtr());

        const remaining_total_space = self.size - actual_space_used;

        // If there's not enough space... we use the whole thing
        if (remaining_total_space < @sizeOf(Header) + 8) {
            self.free = false;
            self.allocator_id = allocator_id;
            log_verbose.info("Using whole block: size={}, needed={}, allocator_id={}", .{self.size, space_needed, allocator_id});
            return false;
        }


        const new_header: *Header = @ptrFromInt(aligned_remainder_pos);


        new_header.* = Header{
            .next = self.next,
            .size = @intCast(remaining_total_space - @sizeOf(Header)),
            .allocator_id = 0, // Free block has no allocator...
            .free = true,
        };


        self.next = new_header;
        self.size = @intCast(actual_space_used);
        self.allocator_id = allocator_id;
        self.free = false;

        log_verbose.info("Split block: allocated_size={}, remainder_size={}, remainder_pos=0x{x}, allocator_id={}", .{
            actual_space_used,
            new_header.size,
            aligned_remainder_pos,
            allocator_id
        });

        return true; // Split occurred
    }
};

comptime {
    std.debug.assert(@sizeOf(Header) == 16);
}

const AllocatorContext = struct {
    tracker: *TrackedAllocator,
    id: u16,
};

pub const TrackedAllocator = struct {
    inner: FreeListAllocator,
    next_id: u16 = 1,
    contexts: std.ArrayList(AllocatorContext),
    allocator_for_contexts: std.mem.Allocator,

    pub const MIN_ALLOC_SIZE = 8;
    pub const MAX_BLOCKS = 10000;

    pub fn init(start: usize, initial_size: usize, mapper: *mem.Mapper, flags: mem.PageFlags, context_allocator: std.mem.Allocator) !TrackedAllocator {
        const inner = try FreeListAllocator.init(start, initial_size, mapper, flags);

        return TrackedAllocator{
            .inner = inner,
            .contexts = std.ArrayList(AllocatorContext).init(context_allocator),
            .allocator_for_contexts = context_allocator,
        };
    }

    pub fn createAllocator(self: *TrackedAllocator) !AllocatorWrapper {
        const id = self.next_id;
        self.next_id += 1;

        log.info("Created allocator with ID {}", .{id});

        return AllocatorWrapper{
            .tracker = self,
            .id = id,
        };
    }

    pub fn freeAllForId(self: *TrackedAllocator, id: u16) usize {
        var freed_count: usize = 0;
        var freed_bytes: usize = 0;

        if (self.inner.headers == null) return 0;

        log.info("Freeing all allocations for allocator ID {}", .{id});

        var iter = self.inner.headers.?.iterator(self.inner.total_blocks);
        while (iter.next()) |header| {
            if (!header.free and header.allocator_id == id) {
                log_verbose.info("Freeing block: ptr=0x{x}, size={}, allocator_id={}", .{
                    @intFromPtr(header.getDataPtr()),
                    header.size,
                    header.allocator_id
                });
                header.free = true;
                header.allocator_id = 0;
                freed_count += 1;
                freed_bytes += header.size;
            }
        }

        if (freed_count > 0) {
            self.inner.coalesceFreeBLocks();
        }

        log.info("Freed {} blocks ({} bytes) for allocator ID {}", .{freed_count, freed_bytes, id});
        return freed_count;
    }

    pub fn getAllocationStats(self: *TrackedAllocator, id: u16) struct { count: usize, bytes: usize } {
        var count: usize = 0;
        var bytes: usize = 0;

        if (self.inner.headers == null) return .{ .count = 0, .bytes = 0 };

        var iter = self.inner.headers.?.iterator(self.inner.total_blocks);
        while (iter.next()) |header| {
            if (!header.free and header.allocator_id == id) {
                count += 1;
                bytes += header.size;
            }
        }

        return .{ .count = count, .bytes = bytes };
    }

    pub fn debugPrint(self: *TrackedAllocator) void {
        self.inner.debugPrint();

        log.info("=== Allocations by ID ===", .{});
        var checked_ids = std.AutoHashMap(u16, bool).init(self.allocator_for_contexts);
        defer checked_ids.deinit();

        if (self.inner.headers) |headers| {
            var iter = headers.iterator(self.inner.total_blocks);
            while (iter.next()) |header| {
                if (!header.free and !checked_ids.contains(header.allocator_id)) {
                    const stats = self.getAllocationStats(header.allocator_id);
                    log.info("ID {}: {} blocks, {} bytes", .{header.allocator_id, stats.count, stats.bytes});
                    checked_ids.put(header.allocator_id, true) catch {};
                }
            }
        }
    }

    pub fn tester(self: *TrackedAllocator) !void {
        log.info("Starting tracked allocator test!", .{});

        var alloc1 = try self.createAllocator();
        var alloc2 = try self.createAllocator();

        const std_alloc1 = alloc1.allocator();
        const std_alloc2 = alloc2.allocator();

        log.info("Testing allocations with different IDs...", .{});

        const bytes1 = try std_alloc1.alloc(u8, 100);
        const bytes2 = try std_alloc2.alloc(u8, 200);
        const bytes3 = try std_alloc1.alloc(u8, 150);

        for (bytes1, 0..) |*byte, i| {
            byte.* = @truncate(i);
        }
        for (bytes2, 0..) |*byte, i| {
            byte.* = @truncate(i + 100);
        }
        for (bytes3, 0..) |*byte, i| {
            byte.* = @truncate(i + 200);
        }

        self.debugPrint();

        log.info("Freeing all allocations for ID {}...", .{alloc1.id});
        const freed_count = self.freeAllForId(alloc1.id);
        log.info("Freed {} allocations", .{freed_count});

        self.debugPrint();

        if (bytes2[0] != 100 or bytes2[199] != 43) {
            log.err("Allocator 2's memory was corrupted!", .{});
            return error.MemoryCorruption;
        }

        std_alloc2.free(bytes2);

        log.info("Tracked allocator test passed!", .{});
    }
};

pub const AllocatorWrapper = struct {
    tracker: *TrackedAllocator,
    id: u16,

    pub fn allocator(self: *AllocatorWrapper) std.mem.Allocator {
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

    pub fn freeAll(self: *AllocatorWrapper) usize {
        return self.tracker.freeAllForId(self.id);
    }

    pub fn getStats(self: *AllocatorWrapper) struct { count: usize, bytes: usize } {
        return self.tracker.getAllocationStats(self.id);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        if (len == 0) return null;

        var self: *AllocatorWrapper = @ptrCast(@alignCast(ctx));
        const size = std.mem.alignForward(usize, @max(len, TrackedAllocator.MIN_ALLOC_SIZE), @sizeOf(usize));

        log_verbose.info("Allocating {} bytes (rounded to {}) for ID {}", .{len, size, self.id});

        self.tracker.inner.coalesceFreeBLocks();

        if (self.tracker.inner.findFreeBlock(size, alignment)) |header| {
            const split_occurred = header.split(size, alignment, self.id);
            if (split_occurred) {
                self.tracker.inner.total_blocks += 1;
            }

            const data_ptr = header.getDataPtr();
            const aligned_ptr: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(data_ptr), alignment.toByteUnits()));

            // sero it out
            @memset(aligned_ptr[0..len], 0);

            log_verbose.info("Allocated {} bytes at 0x{x} for ID {}", .{ len, @intFromPtr(aligned_ptr), self.id });
            return aligned_ptr;
        }

        log.info("Allocation failed: no suitable block found for {} bytes (ID {})", .{size, self.id});
        return null;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ret_addr;
        if (new_len == 0) return false;

        var self: *AllocatorWrapper = @ptrCast(@alignCast(ctx));

        if (self.tracker.inner.findHeader(buf.ptr)) |header| {
            if (!header.free and header.allocator_id == self.id) {
                const new_size = std.mem.alignForward(usize, @max(new_len, TrackedAllocator.MIN_ALLOC_SIZE), @sizeOf(usize));
                const data_ptr = header.getDataPtr();
                const aligned_ptr: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(data_ptr), buf_align.toByteUnits()));
                const offset = @intFromPtr(aligned_ptr) - @intFromPtr(data_ptr);

                // Check if we can shrink
                if (new_size <= header.size - offset) {
                    log_verbose.info("Resized allocation from {} to {} bytes for ID {}", .{ buf.len, new_len, self.id });
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

        var self: *AllocatorWrapper = @ptrCast(@alignCast(ctx));

        if (self.tracker.inner.findHeader(buf.ptr)) |header| {
            if (!header.free and header.allocator_id == self.id) {
                header.free = true;
                header.allocator_id = 0;
                log_verbose.info("Freed {} bytes at 0x{x} for ID {}", .{ buf.len, @intFromPtr(buf.ptr), self.id });

                self.tracker.inner.coalesceFreeBLocks();
            }
        }
    }
};

const FreeListAllocator = struct {
    headers: ?*Header,
    start: usize,
    end: usize,
    mapper: *mem.Mapper,
    flags: mem.PageFlags,
    total_blocks: usize,

    pub fn init(start: usize, initial_size: usize, mapper: *mem.Mapper, flags: mem.PageFlags) !FreeListAllocator {
        if (initial_size < @sizeOf(Header) + TrackedAllocator.MIN_ALLOC_SIZE) {
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
            .allocator_id = 0, // Free block
            .free = true,
        };

        return allocator_er;
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

                if (header.next) |next_header| {
                    if (next_header.free and header.isAdjacent(next_header)) {
                        header.size += @sizeOf(Header) + next_header.size;
                        header.next = next_header.next;
                        self.total_blocks -= 1;
                        changed = true;
                        log_verbose.info("Coalesced blocks, new size: {}", .{header.size});
                        break;
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
            log.info("Block {}: ptr=0x{x}, data=0x{x}, size={}, free={}, allocator_id={}", .{
                count,
                @intFromPtr(header),
                @intFromPtr(header.getDataPtr()),
                header.size,
                header.free,
                header.allocator_id,
            });
            count += 1;
        }
    }
};
