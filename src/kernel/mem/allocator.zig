const std = @import("std");
const mem = @import("../mem.zig");
const log = std.log.scoped(.mem_allocator);
const log_verbose = std.log.scoped(.mem_allocator_verbose);

// free list allocator
// start by preallocating a region (1Mb)
// if more memory is requested try to expand said region.



pub const Header = packed struct {
    //  8
    next: ?*Header,

    // the size of the allocated space
    // not including the header!
    // 4
    size: u32,
    // the starting position of the allocation
    // this can be used to compute the lenght of the allocation
    // 4
    offset: u32,
    // the alignment of course
    // 1
    alignment: std.mem.Alignment,

    free: bool,

    // If the header is at the end of the block and not at the start!
    // used for large alignments!
    end_pos: bool = false,

    // if the offset is from the start,
    // or from the end.
    offset_start: bool = false,

    pub const Iterator = struct {
        current: ?*Header,

        pub fn next(self: *@This()) ?*Header {
            if (self.current) |cur| {
                const tmp = self.current;
                self.current = cur.next;
                return tmp;
            }
            return null;
        }
    };

    pub fn iterator(self: *Header) Iterator {
        return .{ .current = self };
    }

    pub fn freeSpace(self: *Header) ?mem.types.MemoryRange {
        if (self.free) {
            var start: usize = @intFromPtr(self);
            var end: usize = start + self.size + @sizeOf(Header);
            if (self.end_pos) {
                end = start + @sizeOf(Header);
                start -= self.size;
            }
            return mem.types.MemoryRange{ .start = start, .end = end };
        }

        // block is not marked as free!
        if (self.offset == 0) return null;

        if (self.end_pos and !self.offset_start) {
            // I don't want to handle this case for now.. so lets not
            // as this would require splitting the block
            return null;
        }

        if (!self.end_pos and self.offset_start) {
            // I also don't want to handle this so let's not
            return null;
        }

        if (self.end_pos and self.offset_start) {
            // Here we can look at the space that is given in the offset
            const alloc_start = @intFromPtr(self) - self.size;
            return mem.types.MemoryRange{ .start = alloc_start, .end = alloc_start + self.offset };
        }

        if (!self.end_pos and !self.offset_start) {
            const alloc_end = @intFromPtr(self) + @sizeOf(Header) + self.size;
            const alloc_start = alloc_end - self.offset;
            return mem.types.MemoryRange{ .start = alloc_start, .end = alloc_end };
        }

        return null;
    }

    pub fn getAllocRange(self: *Header) mem.types.MemoryRange {
        var result: mem.types.MemoryRange = undefined;
        result.start = if (self.end_pos) @intFromPtr(self) - self.size else @intFromPtr(self) + @sizeOf(Header);
        result.end = result.start + self.size;
        if (self.offset_start) {
            result.start += self.offset;
        } else {
            result.end -= self.offset;
        }
        return result;
    }
};

comptime {
    std.debug.assert(@sizeOf(Header) == 32);
}

pub const FreeListAllocator = struct {
    headers: ?*Header,
    start: usize,
    end: usize,
    mapper: mem.Mapper,
    flags: mem.PageFlags,
    // log: @TypeOf(log_verbose),

    // required for resize
    last_allocation_len: usize = 0,

    pub const MIN_ALLOC_SIZE = @sizeOf(Header);

    pub fn init(start: usize, initial_size: usize, mapper: mem.Mapper, flags: mem.PageFlags) !FreeListAllocator {
        var allocator_er = FreeListAllocator{
            .headers = null,
            .start = start,
            .end = start + initial_size,
            .flags = flags,
            .mapper = mapper,
        };

        // map the first page
        log.info("Initializing FreeListAllocator at {x} with size {d}", .{ start, initial_size });
        const demand_state = try allocator_er.mapper.mapDemandRange(allocator_er.start, initial_size, allocator_er.flags);
        if (!demand_state) {
            // we have a demand state, so we need to initialize the headers
            @panic("we have to hanlde cleanup of the demand state");
        }
        allocator_er.headers = @ptrFromInt(start);
        allocator_er.headers.?.* = Header{
            .next = null,
            .size = @intCast(initial_size - @sizeOf(Header)),
            .offset = 0,
            .free = true,
            .end_pos = false,
            .offset_start = false,
            .alignment = std.mem.Alignment.@"1",
        };
        return allocator_er;
    }

    pub fn allocator(self: *FreeListAllocator) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &std.mem.Allocator.VTable{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn findFreeSpace(self: *FreeListAllocator, len_: usize, alignment: std.mem.Alignment) ?*Header {
        var head_iter = if(self.headers) |h| h.iterator() else return null;
        const len: u64 = std.mem.alignForward(u64,len_,@sizeOf(Header));
        var prev: ?*Header = null;
        while (head_iter.next()) |head| : (prev = head) {
            log_verbose.info("We have found a head",.{});
            // we now have a header.. lets see if it has free space
            if (Header.freeSpace(@constCast(head))) |*free_space| {
                log.info("we have found free space of size {}",.{free_space.get_size()});
                var end: bool = false;
                var space: ?mem.types.MemoryRange = aligned_start: {
                    var aligned_start_space = free_space.alignStartTo(alignment.toByteUnits());
                    // for now we're only doing next to each other regions
                    aligned_start_space.end -= @sizeOf(Header);
                    if (!aligned_start_space.is_valid()) break :aligned_start null;
                    if (aligned_start_space.get_size() < len) break :aligned_start null;
                    end = true;
                    log_verbose.info("We have found an end",.{});
                    break :aligned_start aligned_start_space;
                };

                if (space == null) space = aligned_end: {
                    var aligned_end_space = mem.types.MemoryRange{.start = free_space.start, .end = free_space.end};
                    aligned_end_space.start += @sizeOf(Header);

                    aligned_end_space = aligned_end_space.alignStartTo(alignment.toByteUnits());
                    // for now we're only doing next to each other regions
                    if (!aligned_end_space.is_valid()) break :aligned_end null;
                    if (aligned_end_space.get_size() < len) break :aligned_end null;

                    // note we're only allowing it if the free space matches directly with the aligned space!
                    if (aligned_end_space.start != free_space.start + @sizeOf(Header)) break :aligned_end null;
                    end = false;
                    log_verbose.info("We have found an start",.{});
                    break :aligned_end aligned_end_space;
                };

                if (space == null) continue;

                const new_space = space.?;
                log_verbose.info("We have applicatble space, 0x{X:0>16} -> 0x{X:0>16}",.{new_space.start, new_space.end});


                // we've found some free space.
                // let's turn that into the header we want
                var result: *Header = undefined;
                if (end) {
                    // our header goes at the end!
                    result = @ptrFromInt(new_space.end);
                    result.size = @intCast(free_space.get_size());
                    result.size -= @sizeOf(Header);
                    result.offset = result.size;
                    result.offset -=  @intCast(len);
                    result.alignment = alignment;
                    result.free = true;
                    result.end_pos = true;
                    result.offset_start = true;
                    const r = result.getAllocRange();
                    log_verbose.info("allocated range is 0x{X:0>16} -> 0x{X:0>16}",.{r.start, r.end});
                    log.info("There is an offset of {}",.{result.offset});
                } else {
                    // our headder goes at the start
                    result = @ptrFromInt(new_space.start);
                    result.size = @intCast(free_space.get_size());
                    result.size -= @sizeOf(Header);
                    result.offset = result.size;
                    result.offset -=  @intCast(len);
                    // result.offset = result.size - @as(u32,@truncate(new_space.get_size()));
                    // result.offset-=  @intCast(len);
                    result.alignment = alignment;
                    result.free = true;
                    result.end_pos = false;
                    result.offset_start = false;
                    log.info("There is an offset of {}",.{result.offset});
                }

                if (head.free) {
                    // we can replace
                    log.info("From a free head",.{});
                    if (prev) |phead| {
                        // there is a previous entry. they should point to us.
                        phead.next = result;
                    } else {
                        // this is the header!
                        self.headers = result;
                    }
                } else {
                    // remove ourselves from the header we spliced off of
                    if (head.end_pos != head.offset_start){
                        log.info("we are not at the start of the splice",.{});
                        unreachable;
                    }
                    log.info("Setting the size off",.{});
                    head.size -= head.offset;
                    head.offset = 0;
                }

                result.next = head.next;
                head.next = result;
                log.info("returning",.{});

                const r = result.getAllocRange();
                log_verbose.info("allocated range is 0x{X:0>16} -> 0x{X:0>16}",.{r.start, r.end});
                return result;
            } else continue;
        }
        return null;
    }

    pub fn findHeader(self: *FreeListAllocator, addr: usize) ?*Header {
        var head_iter = if(self.headers) |h| h.iterator() else return null;
        while (head_iter.next()) |cursor| {
            if (cursor.getAllocRange().contains(addr)) {
                return cursor;
            }
        }
        return null;
    }

    /// Return a pointer to `len` bytes with specified `alignment`, or return
    /// `null` indicating the allocation failed.
    ///
    /// `ret_addr` is optionally provided as the first return address of the
    /// allocation call stack. If the value is `0` it means no return address
    /// has been provided.
    pub fn alloc(self_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        if (len == 0) return null;
        var self: *FreeListAllocator = @ptrCast(@alignCast(self_));

        // Figure out if we have enough space
        if (self.findFreeSpace(len, alignment)) |free_header| {
            // - If we do have enough space. Allocate within that
            free_header.free = false;
            const range = free_header.getAllocRange();

            log_verbose.info("allocated range is 0x{X:0>16} -> 0x{X:0>16}",.{range.start, range.end});
            self.last_allocation_len = len;
            const res: [*]u8 = @ptrFromInt(range.start);
            for(0..len) |i| {
                res[i] = 0;
            }
            return res;
        } else {
            log.info("We do not have enough space!",.{});
            // + Not enough space we ask for more
            // ++ If we don't get space, return null, allocation failed.
            // +- If we receive that space, repeat alloc
            unreachable;
        }
        return null;
    }

    /// Attempt to expand or shrink memory in place.
    ///
    /// `memory.len` must equal the length requested from the most recent
    /// successful call to `alloc`, `resize`, or `remap`. `alignment` must
    /// equal the same value that was passed as the `alignment` parameter to
    /// the original `alloc` call.
    ///
    /// A result of `true` indicates the resize was successful and the
    /// allocation now has the same address but a size of `new_len`. `false`
    /// indicates the resize could not be completed without moving the
    /// allocation to a different address.
    ///
    /// `new_len` must be greater than zero.
    ///
    /// `ret_addr` is optionally provided as the first return address of the
    /// allocation call stack. If the value is `0` it means no return address
    /// has been provided.
    pub fn resize(self_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        var self: *FreeListAllocator = @ptrCast(@alignCast(self_));
        _ = ret_addr;
        if (memory.len != self.last_allocation_len) return false;
        const addr = @intFromPtr(&memory[0]);
        if (self.findHeader(addr)) |header| {
            if (header.alignment != alignment) return false;
            if (new_len < header.size) {
                header.offset = header.size - @as(u32,@truncate(new_len));
                self.last_allocation_len = new_len;
                return true;
            }
            return false;
        }
        return false;
    }

    /// Attempt to expand or shrink memory, allowing relocation.
    ///
    /// `memory.len` must equal the length requested from the most recent
    /// successful call to `alloc`, `resize`, or `remap`. `alignment` must
    /// equal the same value that was passed as the `alignment` parameter to
    /// the original `alloc` call.
    ///
    /// A non-`null` return value indicates the resize was successful. The
    /// allocation may have same address, or may have been relocated. In either
    /// case, the allocation now has size of `new_len`. A `null` return value
    /// indicates that the resize would be equivalent to allocating new memory,
    /// copying the bytes from the old memory, and then freeing the old memory.
    /// In such case, it is more efficient for the caller to perform the copy.
    ///
    /// `new_len` must be greater than zero.
    ///
    /// `ret_addr` is optionally provided as the first return address of the
    /// allocation call stack. If the value is `0` it means no return address
    /// has been provided.
    pub fn remap(self_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        var self: *FreeListAllocator = @ptrCast(@alignCast(self_));
        if (memory.len != self.last_allocation_len) return null;
        if (!FreeListAllocator.resize(self_,memory, alignment, new_len, ret_addr)) {
            if (FreeListAllocator.alloc(self_,new_len, alignment, ret_addr)) |allocation| {
                if (new_len < memory.len) {
                    for (0..new_len) |i| allocation[i] = memory[i];
                } else {
                    for (memory, 0..) |entry, i| allocation[i] = entry;
                }
                self.last_allocation_len = new_len;
                return allocation;
            } else return null;
        } else {
            const addr: usize = @intFromPtr(&memory[0]);
            return @ptrFromInt(addr);
        }
    }

    /// Free and invalidate a region of memory.
    ///
    /// `memory.len` must equal the length requested from the most recent
    /// successful call to `alloc`, `resize`, or `remap`. `alignment` must
    /// equal the same value that was passed as the `alignment` parameter to
    /// the original `alloc` call.
    ///
    /// `ret_addr` is optionally provided as the first return address of the
    /// allocation call stack. If the value is `0` it means no return address
    /// has been provided.
    pub fn free(self_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        var self: *FreeListAllocator = @ptrCast(@alignCast(self_));
        if (memory.len != self.last_allocation_len) return;
        if (self.findHeader(@intFromPtr(&memory[0]))) |header| {
            if (header.alignment != alignment) return;
            header.free = true;
        }
        _ = ret_addr;
    }


    pub fn tester(self: *FreeListAllocator) !void {
        const alloca = self.allocator();
        log.info("Starting test!",.{});

        log.info("Trying to allocate 10 bytes",.{});
        const bytes = try alloca.alloc(u8, 10);
        for(bytes,0..) |*byte,i|{
            byte.* = @truncate(i);
        }
        for(bytes,0..) |byte,i|{
            if(i != byte){
                log.info("bytes did not align",.{});
            }

        }
    }
};
