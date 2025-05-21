//! Global Descriptor Table (GDT) implementation for x86_64
//! Defines memory segments and provides the foundation for privilege levels.
//! In 64-bit mode, segmentation is largely vestigial but still required for:
//! - Code/Data segment selectors (base/limit ignored)
//! - Task State Segment loading
//! - Privilege level transitions (syscalls, interrupts)
const std = @import("std");
const log = std.log.scoped(.arch_gdt);

/// GDT Access byte flags
pub const Access = struct {
    pub const PRESENT = 1 << 7;
    pub const RING0 = 0 << 5;
    pub const RING1 = 1 << 5;
    pub const RING2 = 2 << 5;
    pub const RING3 = 3 << 5;
    pub const SYSTEM = 0 << 4;
    pub const CODE_DATA = 1 << 4; // S bit
    pub const EXECUTABLE = 1 << 3;
    pub const CONFORMING = 1 << 2;
    pub const READABLE = 1 << 1;
    pub const WRITABLE = 1 << 1;
    pub const ACCESSED = 1 << 0;

    // Common combinations
    pub const KERNEL_CODE = PRESENT | RING0 | CODE_DATA | EXECUTABLE | READABLE;
    pub const KERNEL_DATA = PRESENT | RING0 | CODE_DATA | WRITABLE;
    pub const USER_CODE = PRESENT | RING3 | CODE_DATA | EXECUTABLE | READABLE;
    pub const USER_DATA = PRESENT | RING3 | CODE_DATA | WRITABLE;
};

pub const DPL = enum(u2) {
    KERNEL = 0,
    USER = 3,
    pub fn fromU2(dpl: u2) DPL {
        return dpl;
    }
    pub fn toU2(self: DPL) u2 {
        return self;
    }
};

/// GDT Flags byte (high 4 bits)
pub const Flags = struct {
    pub const PAGE_GRANULARITY = 1 << 3; // G bit
    pub const SIZE_32 = 1 << 2; // DB bit
    pub const LONG_MODE = 1 << 1; // L bit

    // Common combinations
    pub const PROTECTED_MODE = PAGE_GRANULARITY | SIZE_32;
    pub const LONG_MODE_CODE = PAGE_GRANULARITY | LONG_MODE;
};

/// 64-bit segment descriptor
pub const Descriptor = packed struct {
    limit_low: u16 = 0,
    base_low: u16 = 0,
    base_middle: u8 = 0,
    access_byte: u8 = 0,
    limit_high_flags: u8 = 0, // Upper 4 bits are flags
    base_high: u8 = 0,

    /// Initialize a segment descriptor with the given parameters
    pub fn init(base: u32, limit: u20, access: u8, flags: u4) Descriptor {
        return .{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .base_middle = @truncate(base >> 16),
            .access_byte = access,
            .limit_high_flags = @truncate((limit >> 16) | (@as(u8, flags) << 4)),
            .base_high = @truncate(base >> 24),
        };
    }
};

// comptime assert that the size of Descriptor is 8 bytes
comptime {
    const descriptor_size = @sizeOf(Descriptor);
    const expected_size = 8;
    if (descriptor_size != expected_size) {
        @compileError("Descriptor size mismatch: expected 8 bytes");
    }
}

/// 16-byte system descriptor for TSS (split over two u64s)
/// Required because 64-bit TSS needs a 64-bit base address
pub const TssDescriptor = packed struct {
    // First 8 bytes similar to Descriptor
    limit_low: u16 = 0,
    base_low: u16 = 0,
    base_middle: u8 = 0,
    access_byte: u8 = 0, // Type 0b1001 for 64-bit TSS
    limit_high_flags: u8 = 0,
    base_high: u8 = 0,

    // Second 8 bytes specific to 64-bit TSS
    base_upper: u32 = 0,
    reserved: u32 = 0,

    /// Initialize a TSS descriptor with the given base and limit
    pub fn init(base: u64, limit: u20) TssDescriptor {
        return .{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .base_middle = @truncate(base >> 16),
            // Present, ring0, system, TSS available (0b1001)
            .access_byte = 0b10001001,
            .limit_high_flags = @truncate((limit >> 16) & 0x0F),
            .base_high = @truncate(base >> 24),
            .base_upper = @truncate(base >> 32),
            .reserved = 0,
        };
    }
};

// comptime assert that the size of TssDescriptor is 16 bytes
comptime {
    const tss_descriptor_size = @sizeOf(TssDescriptor);
    const expected_tss_descriptor_size = 16;
    if (tss_descriptor_size != expected_tss_descriptor_size) {
        @compileError("TSS Descriptor size mismatch: expected 16 bytes");
    }
}

/// GDTR structure for loading with lgdt
pub const Gdtr = packed struct {
    size: u16,
    offset: u64,
};

/// Segment selector indices for our GDT
// Long jump to a selector
// This is a 16-bit value with the following structure:
// - 13 bits for the selector index
// - 1 bit for the table indicator (0 for GDT, 1 for LDT)
// - 2 bits for the requestor privilege level (RPL)
//
// You cannot use a selector with RPL 0 in user mode, so we set the RPL to 3
// This will allow us to use the selector in user mode, but it will not be
// able to access kernel memory.
//
// The selector index is the index of the descriptor in the GDT.
//
// Fundementally the selector is how we request to go to user mode.
pub const Selector = packed struct {
    selector_index: u13,
    table_indicator: u1,
    requestor_priv_level: u2, // RPL needs to be 3 to be in user mode.

    pub const NULL = 0x00;
    pub const KERNEL_CODE = 0x08; // 1st entry after null
    pub const KERNEL_DATA = 0x10; // 2nd entry after null
    pub const USER_DATA = 0x18;   // 3rd entry (for future)
    pub const USER_CODE = 0x20;   // 4th entry (for future)
    pub const TSS = 0x28;         // 5th entry for tss lmao
    pub fn fromU16(selector: u16) Selector {
        return .{
            .selector_index = @truncate(selector & 0xFFF8),
            .table_indicator = @truncate((selector >> 3) & 0x1),
            .requestor_priv_level = @truncate((selector >> 5) & 0x3),
        };
    }

    pub fn toU16(self: Selector) u16 {
        return @truncate(self.selector_index | (self.table_indicator << 3) | (self.requestor_priv_level << 5));
    }
};

comptime {
    const selector_size = @sizeOf(Selector);
    const expected_size = 2;
    if (selector_size != expected_size) {
        @compileError("Selector size mismatch: expected 2 bytes");
    }
}

/// Our GDT structure with 6 entries (null, kernel code/data, user code/data, TSS)
/// The TSS is a 16-byte descriptor, so we use a union for proper alignment.
/// Note that entry "slots" are not necessarily 8 bytes each due to this.
pub const Gdt = packed struct {
    null_descriptor: Descriptor = .{}, // size 8 bytes
    kernel_code: Descriptor = .{}, // size 8 bytes
    kernel_data: Descriptor = .{}, // size 8 bytes
    user_data: Descriptor = .{}, // size 8 bytes
    user_code: Descriptor = .{}, // size 8 bytes
    tss_descriptor: TssDescriptor = .{}, // size 16 bytes
};

// comptime assert for the offsets within the Gdt structure
comptime {
    const null_offset = @offsetOf(Gdt, "null_descriptor");
    const kernel_code_offset = @offsetOf(Gdt, "kernel_code");
    const kernel_data_offset = @offsetOf(Gdt, "kernel_data");
    const user_data_offset = @offsetOf(Gdt, "user_data");
    const user_code_offset = @offsetOf(Gdt, "user_code");
    const tss_descriptor_offset = @offsetOf(Gdt, "tss_descriptor");


    if (null_offset != 0x0) {
        @compileLog("Null descriptor offset: {}",.{null_offset});
        @compileLog("Kernel code descriptor offset: {}",.{kernel_code_offset});
        @compileLog("Kernel data descriptor offset: {}",.{kernel_data_offset});
        @compileLog("User data descriptor offset: {}",.{user_data_offset});
        @compileLog("User code descriptor offset: {}",.{user_code_offset});
        @compileLog("TSS descriptor offset: {}",.{tss_descriptor_offset});
        @compileError("Null descriptor offset mismatch");
    }
    if (kernel_code_offset != 0x8) {
        @compileLog("Null descriptor offset: {}",.{null_offset});
        @compileLog("Kernel code descriptor offset: {}",.{kernel_code_offset});
        @compileLog("Kernel data descriptor offset: {}",.{kernel_data_offset});
        @compileLog("User data descriptor offset: {}",.{user_data_offset});
        @compileLog("User code descriptor offset: {}",.{user_code_offset});
        @compileLog("TSS descriptor offset: {}",.{tss_descriptor_offset});
        @compileError("Kernel code descriptor offset mismatch");
    }
    if (kernel_data_offset != 0x10) {
        @compileLog("Null descriptor offset: {}",.{null_offset});
        @compileLog("Kernel code descriptor offset: {}",.{kernel_code_offset});
        @compileLog("Kernel data descriptor offset: {}",.{kernel_data_offset});
        @compileLog("User data descriptor offset: {}",.{user_data_offset});
        @compileLog("User code descriptor offset: {}",.{user_code_offset});
        @compileLog("TSS descriptor offset: {}",.{tss_descriptor_offset});
        @compileError("Kernel data descriptor offset mismatch");
    }
    if (user_data_offset != 0x18) {
        @compileLog("Null descriptor offset: {}",.{null_offset});
        @compileLog("Kernel code descriptor offset: {}",.{kernel_code_offset});
        @compileLog("Kernel data descriptor offset: {}",.{kernel_data_offset});
        @compileLog("User data descriptor offset: {}",.{user_data_offset});
        @compileLog("User code descriptor offset: {}",.{user_code_offset});
        @compileLog("TSS descriptor offset: {}",.{tss_descriptor_offset});
        @compileError("User data descriptor offset mismatch");
    }
    if (user_code_offset != 0x20) {
        @compileLog("Null descriptor offset: {}",.{null_offset});
        @compileLog("Kernel code descriptor offset: {}",.{kernel_code_offset});
        @compileLog("Kernel data descriptor offset: {}",.{kernel_data_offset});
        @compileLog("User data descriptor offset: {}",.{user_data_offset});
        @compileLog("User code descriptor offset: {}",.{user_code_offset});
        @compileLog("TSS descriptor offset: {}",.{tss_descriptor_offset});
        @compileError("User code descriptor offset mismatch");
    }
    if (tss_descriptor_offset != 0x28) {
        @compileLog("Null descriptor offset: {}",.{null_offset});
        @compileLog("Kernel code descriptor offset: {}",.{kernel_code_offset});
        @compileLog("Kernel data descriptor offset: {}",.{kernel_data_offset});
        @compileLog("User data descriptor offset: {}",.{user_data_offset});
        @compileLog("User code descriptor offset: {}",.{user_code_offset});
        @compileLog("TSS descriptor offset: {}",.{tss_descriptor_offset});
        @compileError("TSS descriptor offset mismatch");
    }
}

/// Global GDT instance
var gdt align(16) = Gdt{};

/// Global GDTR instance
var gdtr: Gdtr = undefined;

/// Initialize and load the GDT
pub fn init() void {
    // Null descriptor (required)
    gdt.null_descriptor = .{};

    // Kernel code segment (executable, readable)
    gdt.kernel_code = Descriptor.init(
        0, 0xFFFFF,
        Access.KERNEL_CODE,
        @truncate(Flags.LONG_MODE_CODE >> 4)
    );

    // Kernel data segment (writable)
    gdt.kernel_data = Descriptor.init(
        0, 0xFFFFF,
        Access.KERNEL_DATA,
        @truncate(Flags.PROTECTED_MODE >> 4)
    );

    // User data segment (ring 3, writable)
    gdt.user_data = Descriptor.init(
        0, 0xFFFFF,
        Access.USER_DATA,
        @truncate(Flags.PROTECTED_MODE >> 4)
    );

    // User code segment (ring 3, executable, readable)
    gdt.user_code = Descriptor.init(
        0, 0xFFFFF,
        Access.USER_CODE,
        @truncate(Flags.LONG_MODE_CODE >> 4)
    );

    // TSS descriptor gets initialized when loadTss is called

    // Set up GDTR and load GDT
    gdtr = .{
        .size = @sizeOf(Gdt) - 1,
        .offset = @intFromPtr(&gdt),
    };

    loadGdt();

    log.debug("Reloading segment registers\n", .{});
    // Now reload segment registers (except CS, which requires far jump)
    asm volatile (
        \\mov $0x10, %%ax  // Kernel data segment
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%ss
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        ::: "ax", "memory"
    );

    // Reload CS register via far return
    // This is a bit tricky - we push the new CS and instruction pointer,
    // then use retfq to "return" to the next instruction with the new CS
    asm volatile (
        \\pushq $0x08      // Kernel code segment
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\retfq
        \\1:
        ::: "rax", "memory"
    );
    log.debug("Segment registers reloaded\n", .{});
}

/// Helper to load the TSS into the GDT
/// Called by tss.zig
pub fn loadTss(tss_addr: *const anyopaque, tss_size: u16) void {
    log.debug("Loading TSS at address {x} with size {d}\n", .{tss_addr, tss_size});
    // Update the TSS descriptor in our GDT
    gdt.tss_descriptor = TssDescriptor.init(
        @intFromPtr(tss_addr),
        @intCast(tss_size - 1)  // Convert to u20 and subtract 1 as required by TSS descriptor
    );

    // Load the task register with our TSS selector
    asm volatile (
        \\mov $0x28, %%ax  // TSS selector
        \\ltr %%ax
        ::: "ax", "memory"
    );
    log.debug("TSS loaded with selector {x}\n", .{0x28});
}

/// Load the GDT using the lgdt instruction
fn loadGdt() void {
    log.debug("Loading GDT: {*}\n{any}\n\n", .{&gdtr, gdtr});
    asm volatile ("lgdt (%[gdtr])"
        :
        : [gdtr] "r" (&gdtr)
        : "memory"
    );
    log.debug("GDT loaded\n",.{});
}

/// Export our segment selectors for usage by other modules
pub const KERNEL_CODE_SELECTOR = Selector.KERNEL_CODE;
pub const KERNEL_DATA_SELECTOR = Selector.KERNEL_DATA;
pub const USER_CODE_SELECTOR = Selector.USER_CODE;
pub const USER_DATA_SELECTOR = Selector.USER_DATA;
pub const TSS_SELECTOR = Selector.TSS;

test "gdt descriptor sizes" {
    try std.testing.expectEqual(8, @sizeOf(Descriptor));
    try std.testing.expectEqual(16, @sizeOf(TssDescriptor));
    try std.testing.expectEqual(10, @sizeOf(Gdtr));
}

test "segment selector values" {
    try std.testing.expectEqual(0x08, KERNEL_CODE_SELECTOR);
    try std.testing.expectEqual(0x10, KERNEL_DATA_SELECTOR);
    try std.testing.expectEqual(0x28, TSS_SELECTOR);
}
