// this file is a struct, this file is the thread struct
// threads are going to become "processes" in the future
const std = @import("std");
const mem = @import("mem.zig");
const arch = @import("arch");
const Self = @This();
pub const NUM_THREADS = 512; // The maximum number of threads that can be created

pub inline fn get_kernel_stack_size() usize {
    return (mem.types.MEMORY_LAYOUT.KERNEL_VIRTUAL_STACKS_END - mem.types.MEMORY_LAYOUT.KERNEL_VIRTUAL_STACKS_START) / NUM_THREADS;
}

pub inline fn get_tid() u64 {
    tid_counter += 1;
    return tid_counter;
}

pub fn find_free_entry() ?usize {
    for (0..NUM_THREADS) |i| {
        if (thread_table[i] == null) {
            return i;
        }
    }
    return null;
}


tid: u64, // the id for the thread, this is used to identify the thread
kernel_stack: []usize, // the kernel stack for the thread
user_stack: ?[]usize, // the user stack for the thread
is_kernel: bool, // is this thread a kernel thread?
mapper: *mem.Mapper, // the memory mapper for the thread
owning_allocator: std.mem.Allocator, // the allocator that created this thread
frame: arch.irq.InterruptFrame, // the interrupt frame for the thread

pub const ThreadError = error{
    ThreadingNotInitialized,
    OutOfMemory,
    InvalidThreadId,
    MainThreadAlreadyExists,
    MainThreadNotKernel,
    ThreadTableFull,
};

pub fn init() !void {
    if(initilized) return error.ThreadingNotInitialized;
    for (0..NUM_THREADS) |i| {
        // Initialize the thread table with null values
        thread_table[i] = null;
    }
    initilized = true;
}

const EntryFn = *const fn(arg: ?*anyopaque) callconv(.noreturn) void;

pub fn create(entry_fn: EntryFn, is_kernel: bool, mapper: *mem.Mapper, allocator: std.mem.Allocator, is_main: bool) !*Self {
    var result = try allocator.create(Self);
    errdefer allocator.destroy(result);

    // find free tid(!)
    // find free entry in the thread table. otherwise add to list to be added later

    // if we are the main thread, we need to set the tid to 0
    // also we will not allocate a kernel stack for the main thread as it has one.
    // else find the kernel stack that associated with this thread (from the thread table)

    if(is_main) {
        if (!is_kernel) {
            return error.MainThreadNotKernel; // Main thread must be a kernel thread
        }
        result.tid = 0; // Main thread always has tid 0
        const kernel_stack_start = mem.types.MEMORY_LAYOUT.KERNEL_VIRTUAL_STACK_START;
        const kernel_stack_end = mem.types.MEMORY_LAYOUT.KERNEL_VIRTUAL_STACK_END;
        const kernel_stack_size = kernel_stack_end - kernel_stack_start;
        const ptr:[*]usize = @ptrFromInt(kernel_stack_start);
        const kernel_stack: []usize = ptr[0..kernel_stack_size / @sizeOf(usize)];
        result.kernel_stack = kernel_stack;
    } else {
        result.tid = get_tid(); // Get a new thread ID
        const free_entry = find_free_entry();
        if (free_entry == null) {
            // TODO add to the list to be added later
            return .ThreadTableFull; // No free entry in the thread table
        }
        const slot = free_entry.?; // Unwrap the optional
        const kernel_stack_start = mem.types.MEMORY_LAYOUT.KERNEL_VIRTUAL_STACKS_START + (get_kernel_stack_size() * (slot));
        const ptr:[*]usize = @ptrFromInt(kernel_stack_start);
        const kernel_stack: []usize = ptr[0..get_kernel_stack_size() / @sizeOf(usize)];
        result.kernel_stack = kernel_stack;
        thread_table[free_entry.?] = result.tid; // Mark this entry as used
    }

    // if a user thread, we need to allocate a user stack for the thread
    // TODO @(dleiferives,93db9a3f-de9f-4e07-aba8-61c2862f00f9): Make this
    // dynamically increased in size! ~#
    // this will be dynamically increased as needed.
    // for now we will use a fixed size stack (same size as the kernel stack)
    // map the region to the user stack
    if(!is_kernel){
        const user_stack_start = mem.types.MEMORY_LAYOUT.USER_VIRTUAL_STACK_END - get_kernel_stack_size();
        _ = try mapper.mapDemandRange(
            user_stack_start,
            get_kernel_stack_size(),
            mem.PageFlags{
                .execute_disable = true,
                .write = true,
                .read = true,
                .user = true,
                .present = true,
            },
        );

        const user_stack_pre_ptr:[*]usize = @ptrFromInt(user_stack_start);
        const user_stack: []usize = user_stack_pre_ptr[0..get_kernel_stack_size() / @sizeOf(usize)];
        result.user_stack = user_stack;
    } else {
        result.user_stack = null; // Kernel threads do not have a user stack
    }

    // now we have to setup the frame and such

    return result;
}


pub var thread_table: [NUM_THREADS]?usize = undefined; // The table of threads
pub var initilized: bool = false;
pub var waiting_for_thread_table_slot: Queue(Self) = undefined;
pub var tid_counter: u64 = 1; // Global thread ID counter

pub fn Queue(comptime T: type) type {
    return struct {
        head: ?*Node = null,
        tail: ?*Node = null,

        const Node = struct {
            data: T,
            next: ?*Node = null,
        };

        const Iterator = struct {
            cursor: ?*Node = null,

            pub fn next(self: *@This()) ?T{
                if (self.cursor) |cur| {
                    self.cursor = cur.next;
                    return cur.data;
                }
                return null;
            }
        };

        pub fn enqueue(self: *Self, value: T, allocator: *std.mem.Allocator) !void {
            const node = try allocator.create(Node);
            node.* = Node{ .data = value, .next = null };
            if (self.tail) |tail| {
                tail.next = node;
            } else {
                self.head = node;
            }
            self.tail = node;
        }

        pub fn dequeue(self: *Self, allocator: *std.mem.Allocator) ?T {
            const node = self.head orelse return null;
            defer allocator.destroy(node);
            self.head = node.next;
            if (self.head == null) self.tail = null;
            return node.data;
        }

        pub fn peek(self: *Self) ?T{
            return self.head;
        }

        pub fn remove(self: *Self, item: T, allocator: *std.mem.Allocator) !bool{
            var prev: ?*Node = null;
            var curr = self.head;

            while (curr) |node| {
                if (node.data == item) {
                    if (prev) |p| {
                        p.next = node.next;
                    } else {
                        self.head = node.next;
                    }

                    if (self.tail == node) {
                        self.tail = prev;
                    }

                    try allocator.destroy(node);
                    return true;
                }
                prev = curr;
                curr = node.next;
            }
            return false;
        }

        pub fn toIterator(self: *Self) Iterator {
            return Iterator{.cursor = self.head};
        }
    };
}
