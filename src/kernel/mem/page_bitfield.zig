// TODO @(dleiferives,98039049-8979-4469-b377-878aa2317aff): Add test that he
// wants where we allocate and write to all frames and then free them ~#
const std = @import("std");

const types = @import("types.zig");
const log = std.log.scoped(.mem_page_bitfield);
const verbose_log = std.log.scoped(.mem_page_bitfield_verbose);

pub const PageBitFieldError = error {
    OutOfMemory,
    InvalidRange,
    AddressNotAligned,
    AddressNotInField,
    PageNotInField,
};
// a bitfeild that stores pages.
// to initilize it, we pass in an allocator,
// the ranges of available memory
// uses u64 for the bitfield.
// this will be used for page allocation!
pub const PageBitField = struct {
    allocator: std.mem.Allocator,
    ranges: []types.MemoryRange,
    bit_ranges: []BitRange,
    bitfield: []u64,
    pages: u64,

    pub fn init(allocator: std.mem.Allocator, ranges: []types.MemoryRange) !PageBitField {
        log.info("Initializing", .{});
        var self = PageBitField{
            .allocator = allocator,
            .ranges = ranges,
            .bitfield = undefined,
            .bit_ranges = undefined,
            .pages = 0,
        };

        var pages: u64 = 0;
        var bit_ranges = std.ArrayList(BitRange).init(self.allocator);
        var new_ranges = std.ArrayList(types.MemoryRange).init(self.allocator);

        for (ranges) |range| {
            const start = std.mem.alignForward(u64, range.start, 4096) / 4096;
            const end = std.mem.alignBackward(u64, range.end - 1, 4096) / 4096;
            verbose_log.info("Proccessing range: 0x{X:0>16} - 0x{X:0>16}", .{start * 4096, end * 4096});
            if(start > end){
                verbose_log.info("Range is not large enough, skipping", .{});
                continue;
            }
            // as we align forward and backward, this means if end == start we have 1 page!
            pages += end - start;
            verbose_log.info("Yeilding {} pages", .{pages});
            const bit_range = BitRange{
                .start = self.pages,
                .end = pages,
            };
            try bit_ranges.append(bit_range);
            try new_ranges.append(types.MemoryRange{.start = start * 4096, .end = end * 4096});
            self.pages = pages;
        }
        self.bit_ranges = bit_ranges.items[0..];
        self.ranges = new_ranges.items[0..];

        self.bitfield = try allocator.alloc(u64, (pages + 63) / 64);
        // This is going to round up the number of entries that we need in our bitfield.
        // Therefore we need to set the ending bits as allocated at the end of the bitfield.
        // If they do not fit nicely into an entry
        const final_entry_mask = ~((@as(u64, 1) << (@as(u6,@truncate(pages)) & 0x3F)) - 1);

        for(0..self.bitfield.len) |i| {
            self.bitfield[i] = 0;
        }
        if (self.bitfield.len > 0){
            self.bitfield[self.bitfield.len - 1] = final_entry_mask;
        }

        log.info("Initialized with Pages: {}", .{self.pages});
        return self;
    }

    // COPY and Paste from the reserveRanges function
    pub fn reserveRange(self: *PageBitField, range: types.MemoryRange) !void {
        // Figure out our starting addresses
        const start = std.mem.alignForward(u64, range.start, 4096);
        const end = std.mem.alignBackward(u64, range.end - 1, 4096);
        if (end < start) {
            return PageBitFieldError.InvalidRange;
        }
        var iter = start;
        // we're going to skip a page at at ime
        while (iter <= end) : (iter += 4096) {
            // get the data we need
            const bit_id = try self.getBitId(iter);
            if (bit_id.index >= self.bitfield.len) {
                return PageBitFieldError.OutOfMemory;
            }
            // set the bit in the bitfield
            self.bitfield[bit_id.index] |= 1 << bit_id.bit;
        }
    }

    /// Reserves a range of pages in the bitfield.
    pub fn reserveRanges(self: *PageBitField, range: []types.MemoryRange) !void {
        // For each range, we need to reserve the pages
        for (range) |r| {
            // This starts with us figuring out the start and end pages are

            const start = std.mem.alignForward(u64, r.start, 4096);
            const end = std.mem.alignBackward(u64, r.end - 1, 4096);
            if (end < start) {
                continue;
                // return PageBitFieldError.InvalidRange;
            }
            // we're then going to iterate through each page
            // as they may lie across multiple ranges
            var iter = start;
            while (iter <= end) : (iter += 4096) {
                // then we're going to get the bit id
                const bit_id = self.getBitId(iter) catch {
                    // Range may not be in the space
                    // therefore we may have an error
                    // as such we're just going to continue
                    continue;

                } orelse continue;

                if (bit_id.index >= self.bitfield.len) {
                    return PageBitFieldError.OutOfMemory;
                }
                // and set the bit in the bitfield
                const mask: u64 = @as(u64,1) << @as(u6,@truncate(bit_id.bit));
                self.bitfield[bit_id.index] |= mask;
            }
        }
    }

    /// Returns the bit id of the page at the given address.
    pub fn getBitId(self: PageBitField, address: u64) !?BitRef {
        if (address % 4096 != 0) {
            return PageBitFieldError.AddressNotAligned;
        }
        for (self.bit_ranges,0..) |bit_range,range_idx| {
            if (self.ranges[range_idx].contains(address)) {
                const addr_start = address;
                const align_index =std.mem.alignForward(u64, self.ranges[range_idx].start, 4096);
                const range_bit_offset: u64 = (addr_start - align_index) / 4096;
                const bit_offset = range_bit_offset + bit_range.start;
                const bit_id = BitRef{
                    .index = (bit_offset) >> 6,
                    .bit = bit_offset & 0x3F,
                };
                return bit_id;
            }
        }
        return null;
    }

    /// Returns the number of pages in the bitfield.
    pub fn getFreePages(self: *PageBitField) u64 {
        var free_pages: u64 = 0;
        for (self.bitfield) |bit| {
            free_pages += @popCount(bit);
        }
        return self.pages - free_pages;
    }

    /// Returns the number of reserved pages in the bitfield.
    pub fn getReserved(self: *PageBitField) u64 {
        var reserved_pages: u64 = 0;
        for (self.bitfield) |bit| {
            reserved_pages += @popCount(bit);
        }
        return reserved_pages;
    }

    // Gets the page address from the page id.
    pub fn pageFromId(self: *PageBitField, id: u64) ?u64 {
        // verbose_log.info("Getting page from id: {}", .{id});
        if (id >= self.pages) {
            // verbose_log.info("Page id is out of range", .{});
            return null;
        }
        for (self.bit_ranges,0..) |bit_range,range_idx| {
            if (!bit_range.contains(id)) continue;
            // verbose_log.info("{} in {}",.{id,range_idx});
            const aligned_start = std.mem.alignForward(u64, self.ranges[range_idx].start, 4096);
            const address = aligned_start + (4096 * (id - bit_range.start));
            // if(id > 31900){
            //     verbose_log.info("Found page address: 0x{X:0>16}", .{address});
            //     verbose_log.info("start 0x{X:0>16}",.{aligned_start});
            //     verbose_log.info("addr 0x{X:0>16}",.{address});
            //     while(true){}

            // }
            return address;
        }
        return null;
    }


    /// Allocates a page from the bitfield.
    /// Returns the address of the page.
    /// If no pages are available, returns null.
    pub fn allocatePage(self: *PageBitField) ?u64 {
        // verbose_log.info("Allocating page", .{});
        for (self.bitfield,0..) |entry, index| {
            if (entry != 0xFFFFFFFFFFFFFFFF) {
                // find the first bit that is not set
                // we are goig to flip the entry
                // then count the number of traling zeros
                // This means that we're always going to allocate from the end forward.
                const bit_offset = @ctz(~entry);
                const page_id = (index << 6) + bit_offset;

                // verbose_log.info("Found page id: {}", .{page_id});
                const page = self.pageFromId(page_id);
                if (page) |address| {
                    // set the bit in the bitfield
                    const mask: u64 = @as(u64,1) << @as(u6,@truncate(bit_offset));
                    self.bitfield[index] |= mask;
                    // verbose_log.info("Allocated page: 0x{X:0>16}", .{address});
                    return address;
                } else {
                    return null;
                }
            }
        }
        return null;
    }

    pub fn largestFreePage(self: *PageBitField) ?u64 {
        verbose_log.info("Finding largest free page", .{});
        for (self.bitfield,0..) |entry, index| {
            if (entry != 0xFFFFFFFFFFFFFFFF) {
                // find the first bit that is not set
                const bit_offset = @ctz(~entry);
                const page_id = (index << 6) + bit_offset;
                const page = self.pageFromId(page_id);
                if (page) |address| {
                    verbose_log.info("Largest free page found: 0x{X:0>16}", .{address});
                    return address;
                }
            }
        }
        return null;
    }

    /// Frees a page from the bitfield.
    pub fn freePage(self: *PageBitField, address: u64) !void {
        if (try self.getBitId(address)) |bit_id| {
            if (bit_id.index >= self.bitfield.len) {
                return PageBitFieldError.PageNotInField;
            }
            // std.log.err("found bit id {any}",.{bit_id});
            // clear the bit in the bitfield
            const mask: u64 = @as(u64,1) << @as(u6,@truncate(bit_id.bit));
            self.bitfield[bit_id.index] &= ~mask;
            return;
        }
        return PageBitFieldError.AddressNotInField;
    }

    pub const Tester = packed struct {
        next: ?*Tester,
        data: u64,

        pub var kernel_offset: u64 = undefined;

        fn virt(addr: u64) u64{
            return addr + Tester.kernel_offset;
        }
    };
    pub fn tester(self: *PageBitField, kernel_offset: u64) !void{
        Tester.kernel_offset = kernel_offset;
        std.log.info("starting the tester",.{});

        for (self.ranges,0..) |range,idx|{
            std.log.info("Found range 0x{X:0>16} 0x{X:0>16}",.{range.start,range.end});
            std.log.info("Found bange 0x{X:0>16} 0x{X:0>16}",.{self.bit_ranges[idx].start,self.bit_ranges[idx].end});
        }

        const head_page = self.allocatePage() orelse {
            std.log.info("Could not create head for tester",.{});
            return;
        };

        // for(self.bit_ranges[0].end-800..self.bit_ranges[0].end + 20) |i|{
        //     const temp_page = self.pageFromId(i);
        //     std.log.info("{} 0x{X:0>16}",.{i,temp_page.?});
        // }
        // for(self.bit_ranges[1].end-100..self.bit_ranges[1].end) |i|{
        //     const temp_page = self.pageFromId(i);
        //     std.log.info("{} 0x{X:0>16}",.{i,temp_page.?});
        // }
        // for(31900..32000) |i|{
        //     const temp_page = self.pageFromId(i);
        //     std.log.info("{} 0x{X:0>16}",.{i,temp_page.?});
        // }
        //     while(true){}

        const head: *Tester = @ptrFromInt(Tester.virt(head_page));
        head.next = null;
        var cursor: *Tester = head;
        var i: usize = 0;
        std.log.warn("PageBitFeildTest: Allocating:\n",.{});
        while (self.allocatePage()) |page| : (i += 1){
            std.log.warn("{} @ 0x{X:0>8}\r",.{i, page});
            const cast: *Tester = @ptrFromInt(Tester.virt(page));
            // std.log.info("cursor is 0x{X:0>16}",.{@intFromPtr(cursor)});
            // std.log.info("cast is 0x{X:0>16}",.{@intFromPtr(cast)});
            cast.next = cursor;
            const data: [*]u64 = @ptrCast(cast);
            for(1..64) |j|{
                data[j] = page;
            }
            cursor = cast;
        }
        std.log.warn("\nPageBitFeildTest: Allocated all pages\n",.{});

        i = 0;
        while(true) : (i += 1){
            const current: *Tester = cursor;
            // std.log.info("current is 0x{X:0>16}",.{@intFromPtr(current)});
            if(current.next == null) {
                std.log.info("No more pages to free, breaking", .{});
                try self.freePage(@intFromPtr(current) & ~Tester.kernel_offset);
                break;
            }

            const data: [*]u64 = @ptrCast(current);
            // std.log.info("current next is 0x{X:0>16}",.{@intFromPtr(current.next.?)});
            for(1..64) |j|{
                if (data[j] != @as(u64,@intFromPtr(current)) - Tester.kernel_offset) {
                    std.log.err("Entry {} in {} does not match",.{j,i});
                    std.log.err("Expected: 0x{X:0>16}, got: 0x{X:0>16}",.{data[j], @intFromPtr(current) - Tester.kernel_offset});
                    while(true){}
                }
            }
            cursor = current.next.?;
            try self.freePage(@intFromPtr(current) - Tester.kernel_offset);
            std.log.warn("PageBitFeildTest: free {}\r",.{i});
        }
        std.log.warn("\nPageBitFeildTest: Freed all pages\n",.{});

        const page1 = self.allocatePage() orelse {
            std.log.err("Could not allocate page for tester",.{});
            return;
        };
        const page2 = self.allocatePage() orelse {
            std.log.err("Could not allocate page for tester",.{});
            return;
        };
        std.log.err("Allocated two pages for tester: 0x{X:0>16} and 0x{X:0>16}", .{page1, page2});
        try self.freePage(page1);
        std.log.err("Freed page 1: 0x{X:0>16}", .{page1});
        const page3 = self.allocatePage() orelse {
            std.log.err("Could not allocate page for tester",.{});
            return;
        };
        std.log.err("Allocated page 3: 0x{X:0>16}", .{page3});
        try self.freePage(page2);
        std.log.err("Freed page 2: 0x{X:0>16}", .{page2});
        try self.freePage(page3);
        std.log.err("Freed page 3: 0x{X:0>16}", .{page3});


        std.log.warn("\nPageBitFeildTest: Free all pages\n",.{});
    }


};

pub const BitRef = struct {
    index: u64,
    bit: u64,
};

pub const BitRange = struct {
    start: u64,
    end: u64,

    pub inline fn contains(self: BitRange, address: u64) bool {
        return (address >= self.start) and (address < self.end);
    }
};
