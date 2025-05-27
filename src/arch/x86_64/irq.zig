const std = @import("std");
const kernel= @import("kernel");
const pf_log = std.log.scoped(.irq_page_fault);

// ============================================================================
// Core Types and Enums
// ============================================================================

pub const Vector = enum(u8) {
    // CPU Exceptions
    divide_error = 0,
    debug = 1,
    nmi = 2,
    breakpoint = 3,
    overflow = 4,
    bound_range = 5,
    invalid_opcode = 6,
    device_not_available = 7,
    double_fault = 8,
    invalid_tss = 10,
    segment_not_present = 11,
    stack_segment_fault = 12,
    general_protection = 13,
    page_fault = 14,
    x87_floating_point = 16,
    alignment_check = 17,
    machine_check = 18,
    simd_floating_point = 19,
    virtualization = 20,
    control_protection = 21,

    // Hardware IRQs (32-47)
    irq0 = 32, irq1 = 33, irq2 = 34, irq3 = 35,
    irq4 = 36, irq5 = 37, irq6 = 38, irq7 = 39,
    irq8 = 40, irq9 = 41, irq10 = 42, irq11 = 43,
    irq12 = 44, irq13 = 45, irq14 = 46, irq15 = 47,

    // System calls
    syscall = 128,

    pub fn toValue(self: Vector) u8 {
        return @intFromEnum(self);
    }

    pub fn fromValue(value: u8) ?Vector {
        switch(value) {
            0,1,2,3,4,5,6,7,8,10,11,12,13,14,
            16,17,18,19,20,21,32,33,34,35,36,
            37,38,39,40,41,42,43,44,45,46,47,
            128 => return @enumFromInt(value),
            else => return null,
        }
    }

    pub fn isIrq(self: Vector) bool {
        const v = self.toValue();
        return v >= 32 and v <= 47;
    }

    pub fn irqNumber(self: Vector) ?u8 {
        const v = self.toValue();
        return if (v >= 32 and v <= 47) v - 32 else null;
    }
};

pub const InterruptFrame = extern struct {
    // GPRs pushed by stub (last to first)
    r15: u64, r14: u64, r13: u64, r12: u64,
    r11: u64, r10: u64, r9: u64,  r8: u64,
    rsp_saved: u64, // The RSP value that was pushed
    rbp: u64, rdi: u64, rsi: u64, rdx: u64,
    rcx: u64, rbx: u64, rax: u64,

    // Pushed by stub before GPRs
    vector_num: u64, // Renamed to avoid confusion with Vector enum type
    error_code_val: u64, // Renamed

    // CPU-pushed interrupt frame
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp_at_interrupt: u64,
    ss_at_interrupt: u64,
};

pub const HandlerFn = *const fn (frame: *InterruptFrame) void;

// ============================================================================
// IDT Management
// ============================================================================

pub const idt = struct {
    const Gate = packed struct {
        offset_low: u16,
        selector: u16,
        ist: u3,
        reserved0: u5 = 0,
        gate_type: u4 = 0xE, // Interrupt gate
        zero: u1 = 0,
        dpl: u2,
        present: u1,
        offset_mid: u16,
        offset_high: u32,
        reserved1: u32 = 0,

        fn init(handler: u64, dpl: u2, ist_index: u3) Gate {
            return .{
                .offset_low = @truncate(handler),
                .selector = 0x08, // Kernel code segment
                .ist = ist_index,
                .dpl = dpl,
                .present = 1,
                .offset_mid = @truncate(handler >> 16),
                .offset_high = @truncate(handler >> 32),
            };
        }
    };

    const Idtr = packed struct {
        limit: u16,
        base: u64,
    };

    var table: [256]Gate = undefined;
    var idtr: Idtr = undefined;

    pub fn init() void {
        // Clear table
        std.log.info("Initializing IDT...", .{});
        @memset(std.mem.asBytes(&table), 0);

        // Set up IDTR
        idtr = .{
            .limit = @sizeOf(@TypeOf(table)) - 1,
            .base = @intFromPtr(&table),
        };
    }

    pub fn setGate(vector: Vector, handler: u64, dpl: u2, ist_index: u3) void {
        std.log.info("Setting IDT gate for vector {d} at handler 0x{X:0>16} with DPL {d}", .{
            vector.toValue(), handler, dpl,
        });
        table[vector.toValue()] = Gate.init(handler, dpl,ist_index);
        std.log.info("Gate set for vector {d}", .{vector.toValue()});
    }

    pub fn load() void {
        asm volatile ("lidt (%[idtr])" : : [idtr] "r" (&idtr) : "memory");
    }

    // Import stub addresses from assembly
    extern const interrupt_stubs: [256]u64;

    pub fn setupStubs() void {
        std.log.info("Setting up interrupt stubs...", .{});
        for (0..256) |i| {
            const vector = Vector.fromValue(@intCast(i));
            if (vector == null) continue;
            const dpl: u2 = if (vector.? == .syscall or vector.? == .breakpoint) 3 else 0;
            if (vector.? == .double_fault) {
                setGate(vector.?, interrupt_stubs[i], 0, 1); // IST 1 for DF
            } else if (vector.? == .page_fault) {
                setGate(vector.?, interrupt_stubs[i], 0, 2); // IST 2 for PF (example)
            } else {
                setGate(vector.?, interrupt_stubs[i], dpl, 0); // No IST
            }
        }
        std.log.info("Interrupt stubs set up for all vectors", .{});
    }
};

// ============================================================================
// Hardware Controllers
// ============================================================================

const ControllerError = error{ InvalidIrq, Timeout, HardwareError };

const Controller = struct {
    mask: *const fn (irq: u8) ControllerError!void,
    unmask: *const fn (irq: u8) ControllerError!void,
    eoi: *const fn (irq: u8) ControllerError!void,
    init: *const fn () ControllerError!void,
    name: []const u8,
};

const pic = struct {
    const MASTER_CMD = 0x20;
    const MASTER_DATA = 0x21;
    const SLAVE_CMD = 0xA0;
    const SLAVE_DATA = 0xA1;

    fn out8(port: u16, value: u8) void {
        asm volatile ("outb %[value], %[port]"
            :
            : [value] "{al}" (value), [port] "N{dx}" (port)
        );
    }

    fn in8(port: u16) u8 {
        return asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> u8)
            : [port] "N{dx}" (port)
        );
    }

    fn init() ControllerError!void {
        // Remap PIC to vectors 32-47
        out8(MASTER_CMD, 0x11);
        out8(SLAVE_CMD, 0x11);
        out8(MASTER_DATA, 32);
        out8(SLAVE_DATA, 40);
        out8(MASTER_DATA, 4);
        out8(SLAVE_DATA, 2);
        out8(MASTER_DATA, 1);
        out8(SLAVE_DATA, 1);
        out8(MASTER_DATA, 0xFF); // Mask all
        out8(SLAVE_DATA, 0xFF);
    }

    fn mask(irq_num: u8) ControllerError!void {
        if (irq_num >= 16) return ControllerError.InvalidIrq;

        var port: u16 = undefined;
        if (irq_num < 8) {
            port = MASTER_DATA;
        } else {
            port = SLAVE_DATA;
        }
        const bit = if (irq_num < 8) irq_num else irq_num - 8;
        const current = in8(port);
        out8(port, current | (@as(u8, 1) << @intCast(bit)));
    }

    fn unmask(irq_num: u8) ControllerError!void {
        if (irq_num >= 16) return ControllerError.InvalidIrq;

        var port: u16 = undefined;
        if (irq_num < 8) {
            port = MASTER_DATA;
        } else {
            port = SLAVE_DATA;
        }
        const bit = if (irq_num < 8) irq_num else irq_num - 8;
        const current = in8(port);
        out8(port, current & ~(@as(u8, 1) << @intCast(bit)));
    }

    fn eoi(irq_num: u8) ControllerError!void {
        if (irq_num >= 16) return ControllerError.InvalidIrq;

        if (irq_num >= 8) out8(SLAVE_CMD, 0x20);
        out8(MASTER_CMD, 0x20);
    }

    const controller: Controller = .{
        .init = init,
        .mask = mask,
        .unmask = unmask,
        .eoi = eoi,
        .name = "8259 PIC",
    };
};

// ============================================================================
// Interrupt Dispatcher
// ============================================================================

pub const dispatcher = struct {
    var handlers: [256]?HandlerFn = [_]?HandlerFn{null} ** 256;

    pub fn register(vector: Vector, handler: HandlerFn) void {
        handlers[vector.toValue()] = handler;
    }

    pub fn unregister(vector: Vector) void {
        handlers[vector.toValue()] = null;
    }

    // Called from assembly stub
    export fn dispatch(frame: *InterruptFrame) void {
        const frame_l = frame.*; // Dereference once
        const vector_n = Vector.fromValue(@intCast(frame_l.vector_num));
        if (vector_n == null) {
            std.log.err("Invalid interrupt vector: {d}", .{frame_l.vector_num});
            defaultHandler(frame); // Pass pointer
            return;
        }
        const vector = vector_n.?;

        if (handlers[vector.toValue()]) |handler| {
            handler(frame);
        } else {
            defaultHandler(frame);
        }

        // Send EOI for hardware IRQs
        if (vector.irqNumber()) |irq_num| {
            pic.controller.eoi(irq_num) catch {};
        }
    }

    fn defaultHandler(frame: *InterruptFrame) void {
        const vector = Vector.fromValue(@intCast(frame.vector_num));
        std.log.err("Unhandled interrupt: {any} ({any})", .{ vector, frame.vector_num });

        if (frame.vector_num < 32) {
            // CPU exception - halt system
            std.log.err("CPU Exception at RIP: 0x{X}", .{frame.rip});
            asm volatile ("cli; hlt");
        }
    }
};

// ============================================================================
// Exception Handlers
// ============================================================================

pub const exceptions = struct {
    fn formatException(comptime name: []const u8, frame: *InterruptFrame) void {
        std.log.err("EXCEPTION: {s}", .{name});
        std.log.err("  RIP: 0x{X:0>16}", .{frame.rip});
        std.log.err("  Error Code: 0x{X:0>16}", .{frame.error_code_val});
        std.log.err("  RAX: 0x{X:0>16} RBX: 0x{X:0>16}", .{ frame.rax, frame.rbx });
        std.log.err("  RCX: 0x{X:0>16} RDX: 0x{X:0>16}", .{ frame.rcx, frame.rdx });
    }

    fn pageFault(frame: *InterruptFrame) void {
        const fault_addr = asm volatile ("mov %%cr2, %[result]"
            : [result] "=r" (-> u64)
        );

        const present = (frame.error_code_val & 1) != 0;
        const write = (frame.error_code_val & 2) != 0;
        const user = (frame.error_code_val & 4) != 0;

        pf_log.err("Page Fault at address: 0x{X:0>16}", .{fault_addr});
        pf_log.err("  RIP: 0x{X:0>16}", .{frame.rip});
        pf_log.err("  Error Code: 0x{X:0>16}", .{frame.error_code_val});
        pf_log.err("  Type: {s} {s} {s}", .{
            if (present) "protection violation" else "page not present",
            if (write) "write" else "read",
            if (user) "user" else "kernel",
        });

        // Try to handle demand paging first
        if (!present) {
            // Get the current mapper from the memory manager
            // You'll need to expose this from your kernel state
            const kernel_state = kernel.state;
            if (kernel_state.initilized.mem_manager) {
                if (kernel_state.mem_manager.mapper) |*mapper_ptr| {
                    pf_log.err("Handling demand page fault at 0x{X:0>16}", .{fault_addr});
                    var mapper = @constCast(mapper_ptr);
                    if (mapper.handleDemandPageFault(fault_addr)) |success| {
                        if (success) {
                            pf_log.info("Successfully handled demand page fault at 0x{X:0>16}", .{fault_addr});
                            // var t: [*]u64 = @ptrFromInt(fault_addr);
                            // t[0] = 0; // Example operation to ensure the page is mapped
                            pf_log.info("Continuing execution after handling page fault", .{});
                            return; // Successfully handled, continue execution
                        } else {
                            pf_log.err("Failed to handle demand page fault at 0x{X:0>16}", .{fault_addr});
                            return;
                        }
                    } else |err| {
                        pf_log.err("Error handling demand page fault: {}", .{err});
                    }
                }
            }
        }


        // If we get here, it's an unhandled page fault
        // formatException("Page Fault", frame);
        pf_log.err("  Fault Address: 0x{X:0>16}", .{fault_addr});
        pf_log.err("UNHANDLED PAGE FAULT - System halted",.{});
        asm volatile ("cli; hlt");
    }

    fn generalProtection(frame: *InterruptFrame) void {
        formatException("General Protection Fault", frame);
        asm volatile ("cli; hlt");
    }

    fn doubleFault(frame: *InterruptFrame) void {
        formatException("Double Fault", frame);
        std.log.err("SYSTEM HALTED",.{});
        asm volatile ("cli; hlt");
    }

    // Generic handler for non-critical exceptions
    fn genericException(comptime name: []const u8) HandlerFn {
        return struct {
            fn handler(frame: *InterruptFrame) void {
                formatException(name, frame);
                // For non-critical exceptions, we could potentially continue
                // but for safety, we'll halt for now
                asm volatile ("cli; hlt");
            }
        }.handler;
    }

    pub fn init() void {
        dispatcher.register(.divide_error, genericException("Divide Error"));
        dispatcher.register(.debug, genericException("Debug"));
        dispatcher.register(.nmi, genericException("NMI"));
        dispatcher.register(.breakpoint, genericException("Breakpoint"));
        dispatcher.register(.overflow, genericException("Overflow"));
        dispatcher.register(.bound_range, genericException("Bound Range"));
        dispatcher.register(.invalid_opcode, genericException("Invalid Opcode"));
        dispatcher.register(.device_not_available, genericException("Device Not Available"));
        dispatcher.register(.double_fault, doubleFault);
        dispatcher.register(.invalid_tss, genericException("Invalid TSS"));
        dispatcher.register(.segment_not_present, genericException("Segment Not Present"));
        dispatcher.register(.stack_segment_fault, genericException("Stack Segment Fault"));
        dispatcher.register(.general_protection, generalProtection);
        dispatcher.register(.page_fault, pageFault);
        dispatcher.register(.x87_floating_point, genericException("x87 FPU Error"));
        dispatcher.register(.alignment_check, genericException("Alignment Check"));
        dispatcher.register(.machine_check, genericException("Machine Check"));
        dispatcher.register(.simd_floating_point, genericException("SIMD FPU Error"));
        dispatcher.register(.virtualization, genericException("Virtualization"));
        dispatcher.register(.control_protection, genericException("Control Protection"));
    }
};

// ============================================================================
// Main IRQ Interface
// ============================================================================

pub const irq = struct {
    var current_controller: Controller = pic.controller;

    pub fn init() !void {
        // Initialize IDT
        std.log.info("Initializing IRQ system...",.{});
        idt.init();
        disable();
        idt.setupStubs();

        // Initialize controller
        try current_controller.init();

        // Register exception handlers
        exceptions.init();

        // Load IDT
        idt.load();
        enable();

        std.log.info("IRQ system initialized with {s}", .{current_controller.name});
    }

    pub fn enable() void {
        asm volatile ("sti");
    }

    pub fn disable() void {
        asm volatile ("cli");
    }

    pub fn isEnabled() bool {
        const flags = asm volatile ("pushfq; popq %[flags]"
            : [flags] "=r" (-> u64)
        );
        return (flags & (1 << 9)) != 0;
    }

    pub fn register(vector: Vector, handler: HandlerFn) void {
        dispatcher.register(vector, handler);
    }

    pub fn registerIrq(irq_num: u8, handler: HandlerFn) !void {
        if (irq_num >= 16) return error.InvalidIrq;

        const vector_n = Vector.fromValue(32 + irq_num);
        if (vector_n == null) return error.InvalidIrq;
        const vector = vector_n.?;
        dispatcher.register(vector, handler);
        try current_controller.unmask(irq_num);
    }

    pub fn unregisterIrq(irq_num: u8) !void {
        if (irq_num >= 16) return error.InvalidIrq;

        try current_controller.mask(irq_num);
        const vector = Vector.fromValue(32 + irq_num);
        if (vector == null) return error.InvalidIrq;
        dispatcher.unregister(vector.?);
    }

    pub fn maskIrq(irq_num: u8) !void {
        try current_controller.mask(irq_num);
    }

    pub fn unmaskIrq(irq_num: u8) !void {
        try current_controller.unmask(irq_num);
    }
};
