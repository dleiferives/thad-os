//! Global Descriptor Table (GDT) implementation for x86_64
//! Provides kernel/user privilege separation and Task State Segment (TSS) management

const std = @import("std");
const arch = @import("../arch.zig");

const log = std.log.scoped(.arch_gdt);

// ============================================================================
// GDT Constants and Structures
// ============================================================================

/// GDT Access byte flags
const ACCESS = struct {
    const PRESENT: u8 = 1 << 7;       // Present bit
    const RING0: u8 = 0 << 5;         // Ring 0 (kernel)
    const RING3: u8 = 3 << 5;         // Ring 3 (user)
    const SYSTEM: u8 = 1 << 4;        // System segment (code/data)
    const EXECUTABLE: u8 = 1 << 3;    // Executable (code segment)
    const DIRECTION: u8 = 1 << 2;     // Direction/conforming
    const READABLE: u8 = 1 << 1;      // Readable (code) / Writable (data)
    const ACCESSED: u8 = 1 << 0;      // Accessed bit

    // TSS type (for system descriptors)
    const TSS_AVAILABLE: u8 = 0x9;    // Available 64-bit TSS
};

/// GDT Flags (upper 4 bits of limit/flags field)
const FLAGS = struct {
    const GRANULARITY: u8 = 1 << 3;   // 4KB granularity
    const SIZE: u8 = 1 << 2;          // 32-bit segment (ignored in 64-bit)
    const LONG_MODE: u8 = 1 << 1;     // 64-bit code segment
};

/// Segment selectors (indexes into GDT)
pub const SELECTOR = struct {
    pub const NULL: u16 = 0x00;
    pub const KERNEL_CODE: u16 = 0x08;
    pub const KERNEL_DATA: u16 = 0x10;
    pub const USER_DATA: u16 = 0x18;    // Note: data comes before code for sysret
    pub const USER_CODE: u16 = 0x20;
    pub const TSS: u16 = 0x28;

    // RPL (Requested Privilege Level) masks
    pub const RPL_MASK: u16 = 0x03;
    pub const KERNEL_RPL: u16 = 0x00;
    pub const USER_RPL: u16 = 0x03;

    // Helper functions
    pub fn withRPL(selector: u16, rpl: u16) u16 {
        return (selector & ~RPL_MASK) | (rpl & RPL_MASK);
    }
};

/// Standard GDT entry (8 bytes)
const GdtEntry = packed struct {
    limit_low: u16,     // Lower 16 bits of limit
    base_low: u16,      // Lower 16 bits of base
    base_mid: u8,       // Middle 8 bits of base
    access: u8,         // Access byte
    limit_flags: u8,    // Upper 4 bits of limit + flags
    base_high: u8,      // Upper 8 bits of base

    fn init(base: u32, limit: u32, access: u8, flags: u8) GdtEntry {
        return GdtEntry{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .base_mid = @truncate(base >> 16),
            .access = access,
            .limit_flags = @as(u8,@truncate(limit >> 16)) | (flags << 4),
            .base_high = @truncate(base >> 24),
        };
    }

    fn initNull() GdtEntry {
        return std.mem.zeroes(GdtEntry);
    }

    fn initCode(ring: u8, long_mode: bool) GdtEntry {
        var access_byte = ACCESS.PRESENT | ACCESS.SYSTEM | ACCESS.EXECUTABLE | ACCESS.READABLE;
        if (ring == 0) {
            access_byte |= ACCESS.RING0;
        } else {
            access_byte |= ACCESS.RING3;
        }

        var flags_byte: u8 = FLAGS.GRANULARITY;
        if (long_mode) {
            flags_byte |= FLAGS.LONG_MODE;
        } else {
            flags_byte |= FLAGS.SIZE;
        }

        return GdtEntry.init(0, 0xFFFFF, access_byte, flags_byte);
    }

    fn initData(ring: u8) GdtEntry {
        var access_byte = ACCESS.PRESENT | ACCESS.SYSTEM | ACCESS.READABLE;
        if (ring == 0) {
            access_byte |= ACCESS.RING0;
        } else {
            access_byte |= ACCESS.RING3;
        }

        return GdtEntry.init(0, 0xFFFFF, access_byte, FLAGS.GRANULARITY | FLAGS.SIZE);
    }
};

/// TSS entry (16 bytes in x86_64) - spans two GDT entries
const TssEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    limit_flags: u8,
    base_high: u8,
    base_upper: u32,    // Upper 32 bits of base (x86_64 only)
    reserved: u32,      // Must be zero

    fn init(tss_base: u64) TssEntry {
        const limit = @sizeOf(TaskStateSegment) - 1;
        return TssEntry{
            .limit_low = @truncate(limit),
            .base_low = @truncate(tss_base),
            .base_mid = @truncate(tss_base >> 16),
            .access = ACCESS.PRESENT | ACCESS.TSS_AVAILABLE,
            .limit_flags = @truncate(limit >> 16),
            .base_high = @truncate(tss_base >> 24),
            .base_upper = @truncate(tss_base >> 32),
            .reserved = 0,
        };
    }
};

/// Task State Segment structure
const TaskStateSegment = packed struct {
    reserved1: u32,
    rsp0: u64,          // Stack pointer for ring 0
    rsp1: u64,          // Stack pointer for ring 1 (unused)
    rsp2: u64,          // Stack pointer for ring 2 (unused)
    reserved2: u64,
    ist1: u64,          // Interrupt Stack Table 1
    ist2: u64,          // Interrupt Stack Table 2
    ist3: u64,          // Interrupt Stack Table 3
    ist4: u64,          // Interrupt Stack Table 4
    ist5: u64,          // Interrupt Stack Table 5
    ist6: u64,          // Interrupt Stack Table 6
    ist7: u64,          // Interrupt Stack Table 7
    reserved3: u64,
    reserved4: u16,
    iomap_base: u16,    // I/O Map Base Address

    fn init() TaskStateSegment {
        return TaskStateSegment{
            .reserved1 = 0,
            .rsp0 = 0,
            .rsp1 = 0,
            .rsp2 = 0,
            .reserved2 = 0,
            .ist1 = 0,
            .ist2 = 0,
            .ist3 = 0,
            .ist4 = 0,
            .ist5 = 0,
            .ist6 = 0,
            .ist7 = 0,
            .reserved3 = 0,
            .reserved4 = 0,
            .iomap_base = @sizeOf(TaskStateSegment),
        };
    }
};

/// GDT Pointer structure for lgdt instruction
const GdtPointer = packed struct {
    limit: u16,
    base: u64,
};

// ============================================================================
// Global GDT State
// ============================================================================

/// The actual GDT table (7 entries: null, kcode, kdata, udata, ucode, tss_low, tss_high)
var gdt_table: [7]u64 align(8) = undefined;

/// TSS instance
var tss: TaskStateSegment align(16) = undefined;

/// GDT pointer for lgdt
var gdt_ptr: GdtPointer = undefined;

/// Kernel stack for ring 0 operations
var kernel_stack: [0x4000]u8 align(16) = undefined; // 16KB kernel stack
var double_fault_stack: [0x1000]u8 align(16) = undefined; // 4KB DF stack
var page_fault_stack: [0x10000]u8 align(16) = undefined;   // 4KB PF stack

/// Flag to track initialization
var initialized: bool = false;

// ============================================================================
// Core GDT Functions
// ============================================================================

/// Initialize the GDT with proper kernel/user segments and TSS
pub fn init() void {
    if (initialized) {
        log.warn("GDT already initialized", .{});
        return;
    }

    log.info("Initializing GDT...", .{});

    // Clear the GDT table
    @memset(std.mem.asBytes(&gdt_table), 0);

    // Set up GDT entries as u64 values
    const entries = @as([*]GdtEntry, @ptrCast(&gdt_table));

    // Entry 0: Null descriptor
    entries[0] = GdtEntry.initNull();

    // Entry 1: Kernel code segment (ring 0, 64-bit)
    entries[1] = GdtEntry.initCode(0, true);

    // Entry 2: Kernel data segment (ring 0)
    entries[2] = GdtEntry.initData(0);

    // Entry 3: User data segment (ring 3) - must come before user code for sysret
    entries[3] = GdtEntry.initData(3);

    // Entry 4: User code segment (ring 3, 64-bit)
    entries[4] = GdtEntry.initCode(3, true);

    // Entries 5-6: TSS (takes 16 bytes = 2 entries in x86_64)
    tss = TaskStateSegment.init();
    const tss_addr = @intFromPtr(&tss);
    const tss_entry = TssEntry.init(tss_addr);

    // Copy TSS entry bytes into GDT
    const tss_bytes = std.mem.asBytes(&tss_entry);
    var entries_ptr: [*]u8 = @ptrCast(&entries[5]);
    for (0..16) |i| {
        entries_ptr[i] = tss_bytes[i];
    }
    // @memcpy(std.mem.asBytes(&entries[5])[0..16], tss_bytes);

    // Set up kernel stack in TSS
    const kernel_stack_top = @intFromPtr(&kernel_stack) + kernel_stack.len;
    tss.rsp0 = kernel_stack_top;


    const df_stack_top = @intFromPtr(&double_fault_stack) + double_fault_stack.len;
    const pf_stack_top = @intFromPtr(&page_fault_stack) + page_fault_stack.len;
    setInterruptStack(1, df_stack_top); // Assuming IST1 for Double Fault
    setInterruptStack(2, pf_stack_top); // Assuming IST2 for Page Fault

    // Set up GDT pointer
    gdt_ptr = GdtPointer{
        .limit = @sizeOf(@TypeOf(gdt_table)) - 1,
        .base = @intFromPtr(&gdt_table),
    };

    // Load the GDT
    loadGdt();

    // Load TSS
    loadTss();

    initialized = true;
    log.info("GDT initialized successfully", .{});
}

/// Load the GDT using lgdt instruction
fn loadGdt() void {
    asm volatile (
        \\lgdt (%[gdt_ptr])
        :
        : [gdt_ptr] "r" (&gdt_ptr),
        : "memory"
    );

    // Reload segment registers
    asm volatile (
        \\mov %[data_sel], %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
        \\pushq %[code_sel]
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        :
        : [data_sel] "i" (SELECTOR.KERNEL_DATA),
          [code_sel] "i" (SELECTOR.KERNEL_CODE),
        : "rax", "memory"
    );
}

/// Load the TSS using ltr instruction
fn loadTss() void {
    asm volatile (
        \\ltr %[tss_sel]
        :
        : [tss_sel] "r" (@as(u16, SELECTOR.TSS)),
        : "memory"
    );
}

// ============================================================================
// Stack Management
// ============================================================================

/// Set the kernel stack pointer in the TSS
/// This stack will be used when transitioning from user mode to kernel mode
pub fn setKernelStack(stack_top: u64) void {
    if (!initialized) {
        log.err("GDT not initialized", .{});
        return;
    }

    tss.rsp0 = stack_top;
    log.debug("Kernel stack set to 0x{X:0>16}", .{stack_top});
}

/// Set an interrupt stack table entry
pub fn setInterruptStack(ist_index: u3, stack_top: u64) void {
    if (!initialized) {
        log.err("GDT not initialized", .{});
        return;
    }

    if (ist_index == 0 or ist_index > 7) {
        log.err("Invalid IST index: {}", .{ist_index});
        return;
    }

    switch (ist_index) {
        1 => tss.ist1 = stack_top,
        2 => tss.ist2 = stack_top,
        3 => tss.ist3 = stack_top,
        4 => tss.ist4 = stack_top,
        5 => tss.ist5 = stack_top,
        6 => tss.ist6 = stack_top,
        7 => tss.ist7 = stack_top,
        else => unreachable,
    }

    log.debug("IST{} set to 0x{X:0>16}", .{ ist_index, stack_top });
}

/// Get the current kernel stack pointer from TSS
pub fn getKernelStack() u64 {
    return if (initialized) tss.rsp0 else 0;
}

// ============================================================================
// User Mode Transition
// ============================================================================

/// Switch to user mode and jump to the specified address
/// This function does not return - it transfers control to user space
pub fn switchToUserMode(user_rip: u64, user_rsp: u64) noreturn {
    if (!initialized) {
        @panic("GDT not initialized - cannot switch to user mode");
    }

    log.info("Switching to user mode: RIP=0x{X:0>16}, RSP=0x{X:0>16}", .{ user_rip, user_rsp });

    // Set up the stack frame for iretq
    // The stack should contain (from top to bottom):
    // - SS (user data selector with RPL=3)
    // - RSP (user stack pointer)
    // - RFLAGS (with interrupts enabled)
    // - CS (user code selector with RPL=3)
    // - RIP (user instruction pointer)

    const user_cs = SELECTOR.USER_CODE | SELECTOR.USER_RPL;
    const user_ss = SELECTOR.USER_DATA | SELECTOR.USER_RPL;
    const user_flags: u64 = 0x202; // IF=1, Reserved bit=1

    asm volatile (
        \\cli
        \\mov %[user_ds], %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\
        \\pushq %[user_ss]
        \\pushq %[user_rsp]
        \\pushq %[user_flags]
        \\pushq %[user_cs]
        \\pushq %[user_rip]
        \\iretq
        :
        : [user_ss] "i" (user_ss),
          [user_rsp] "r" (user_rsp),
          [user_flags] "i" (user_flags),
          [user_cs] "i" (user_cs),
          [user_rip] "r" (user_rip),
          [user_ds] "i" (SELECTOR.USER_DATA | SELECTOR.USER_RPL),
        : "rax", "memory"
    );

    unreachable;
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Get the current code segment selector
pub fn getCurrentCS() u16 {
    return asm volatile (
        \\mov %%cs, %[result]
        : [result] "=r" (-> u16),
    );
}

/// Get the current data segment selector
pub fn getCurrentDS() u16 {
    return asm volatile (
        \\mov %%ds, %[result]
        : [result] "=r" (-> u16),
    );
}

/// Check if currently running in kernel mode
pub fn isKernelMode() bool {
    return (getCurrentCS() & SELECTOR.RPL_MASK) == SELECTOR.KERNEL_RPL;
}

/// Check if currently running in user mode
pub fn isUserMode() bool {
    return (getCurrentCS() & SELECTOR.RPL_MASK) == SELECTOR.USER_RPL;
}

/// Print GDT information for debugging
pub fn debugPrint() void {
    if (!initialized) {
        log.info("GDT not initialized", .{});
        return;
    }

    log.info("=== GDT Debug Information ===", .{});
    log.info("GDT Base: 0x{X:0>16}", .{gdt_ptr.base});
    log.info("GDT Limit: 0x{X:0>4}", .{gdt_ptr.limit});
    log.info("TSS Base: 0x{X:0>16}", .{@intFromPtr(&tss)});
    log.info("Current CS: 0x{X:0>4} ({})", .{ getCurrentCS(), if (isKernelMode()) "kernel" else "user" });
    log.info("Current DS: 0x{X:0>4}", .{getCurrentDS()});
    log.info("Kernel Stack (RSP0): 0x{X:0>16}", .{tss.rsp0});

    // Print GDT entries
    for (gdt_table, 0..) |entry, i| {
        if (entry != 0) {
            log.info("GDT[{}]: 0x{X:0>16}", .{ i, entry });
        }
    }
}

/// Test function to verify GDT setup
pub fn tester() !void {
    log.info("Running GDT tests...", .{});

    // Basic sanity checks
    if (!initialized) {
        return error.NotInitialized;
    }

    if (!isKernelMode()) {
        return error.NotInKernelMode;
    }

    if (getKernelStack() == 0) {
        return error.NoKernelStack;
    }

    // Verify TSS is loaded
    const tss_selector = asm volatile (
        \\str %[result]
        : [result] "=r" (-> u16),
    );

    if (tss_selector != SELECTOR.TSS) {
        log.err("TSS not properly loaded: expected 0x{X:0>4}, got 0x{X:0>4}", .{ SELECTOR.TSS, tss_selector });
        return error.TssNotLoaded;
    }

    log.info("GDT tests passed", .{});
}
