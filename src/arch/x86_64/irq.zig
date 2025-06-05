const std = @import("std");
const kernel= @import("kernel");
const cpu = @import("cpu.zig");
const pf_log = std.log.scoped(.irq_page_fault);
const irq_log = std.log.scoped(.irq);
const thread = kernel.thread;
const syscall = kernel.syscall;


/// Interrupt vector enum, just a helper lol
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

    // TODO @(dleiferives,05739ef9-0365-4d71-b6d7-168f52fe27fb): need to add yeild
    // as a syscall for threading ~#
    // TODO @(dleiferives,84617f56-0ea9-4ae4-9a45-828cbaa35998): need to add
    // thread_exit as a syscall that calls a trap, which then does the thread
    // deallocation ~#
    syscall = 128,
    thread_cleanup = 129,

    pub fn toValue(self: Vector) u8 {
        return @intFromEnum(self);
    }

    pub fn fromValue(value: u8) ?Vector {
        switch(value) {
            0,1,2,3,4,5,6,7,8,10,11,12,13,14,
            16,17,18,19,20,21,32,33,34,35,36,
            37,38,39,40,41,42,43,44,45,46,47,
            128,129 => return @enumFromInt(value),
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
    // Segment registers
    gs: u64, fs: u64, es: u64, ds: u64,

    // General registers
    r15: u64, r14: u64, r13: u64, r12: u64,
    r11: u64, r10: u64, r9: u64, r8: u64,
    rbp: u64, rdi: u64, rsi: u64, rdx: u64,
    rcx: u64, rbx: u64, rax: u64,

    // Interrupt data
    vector: u64,
    error_code: u64,

    // From the cpu during interrupt!
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,

    pub fn toThreadContext(self: @This()) thread.ThreadContext{
        return .{
            .rax = self.rax,
            .rbx = self.rbx,
            .rcx = self.rcx,
            .rdx = self.rdx,
            .rsi = self.rsi,
            .rdi = self.rdi,
            .rbp = self.rbp,
            .rsp = self.rsp,
            .r8 = self.r8,
            .r9 = self.r9,
            .r10 = self.r10,
            .r11 = self.r11,
            .r12 = self.r12,
            .r13 = self.r13,
            .r14 = self.r14,
            .r15 = self.r15,
            .cs = self.cs,
            .ds = self.ds,
            .es = self.es,
            .fs = self.fs,
            .gs = self.gs,
            .ss = self.ss,
            .rip = self.rip,
            .rflags = self.rflags,
            .fpu_state = undefined,
        };
    }
};

// The interrupt handler function!
pub const HandlerFn = *const fn (frame: *InterruptFrame) void;


pub const idt = struct {
    const Gate = packed struct {
        offset_low: u16,
        selector: u16,
        ist: u3,
        reserved0: u5 = 0,
        gate_type: u4 = 0xE,
        zero: u1 = 0,
        dpl: u2,
        present: u1,
        offset_mid: u16,
        offset_high: u32,
        reserved1: u32 = 0,

        fn init(handler: u64, dpl: u2) Gate {
            return .{
                .offset_low = @truncate(handler),
                // TODO @(dleiferives,d379d31b-db97-4356-b8ee-b87ca606d56d): Make
                // it be imported from gdt ~#
                .selector = 0x08, // Kernel code segment
                .ist = 0,
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
        std.log.info("Initializing IDT...", .{});
        @memset(std.mem.asBytes(&table), 0);

        idtr = .{
            .limit = @sizeOf(@TypeOf(table)) - 1,
            .base = @intFromPtr(&table),
        };
    }

    pub fn setGate(vector: Vector, handler: u64, dpl: u2) void {
        std.log.info("Setting IDT gate for vector {d} at handler 0x{X:0>16} with DPL {d}", .{
            vector.toValue(), handler, dpl,
        });
        table[vector.toValue()] = Gate.init(handler, dpl);
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
            setGate(vector.?, interrupt_stubs[i], dpl);
        }
        std.log.info("Interrupt stubs set up for all vectors", .{});
    }
};

// Hardware controllers //
const ControllerError = error{ InvalidIrq, Timeout, HardwareError };

const Controller = struct {
    mask: *const fn (irq: u8) ControllerError!void,
    unmask: *const fn (irq: u8) ControllerError!void,
    eoi: *const fn (irq: u8) ControllerError!void,
    init: *const fn () ControllerError!void,
    name: []const u8,
};

const pic = struct {
    const CONTROLLER_CMD = 0x20;
    const CONTROLLER_DATA = 0x21;
    const FOLLOWER_CMD = 0xA0;
    const FOLLOWER_DATA = 0xA1;

    fn init() ControllerError!void {
        // Remap PIC to vectors 32-47
        cpu.outb(CONTROLLER_CMD, 0x11);
        cpu.outb(FOLLOWER_CMD, 0x11);
        cpu.outb(CONTROLLER_DATA, 32);
        cpu.outb(FOLLOWER_DATA, 40);
        cpu.outb(CONTROLLER_DATA, 4);
        cpu.outb(FOLLOWER_DATA, 2);
        cpu.outb(CONTROLLER_DATA, 1);
        cpu.outb(FOLLOWER_DATA, 1);
        cpu.outb(CONTROLLER_DATA, 0xFF); // Mask all
        cpu.outb(FOLLOWER_DATA, 0xFF);
    }

    fn mask(irq_num: u8) ControllerError!void {
        if (irq_num >= 16) return ControllerError.InvalidIrq;

        var port: u16 = undefined;
        if (irq_num < 8) {
            port = CONTROLLER_DATA;
        } else {
            port = FOLLOWER_DATA;
        }
        const bit = if (irq_num < 8) irq_num else irq_num - 8;
        const current = cpu.inb(port);
        cpu.outb(port, current | (@as(u8, 1) << @intCast(bit)));
    }

    fn unmask(irq_num: u8) ControllerError!void {
        if (irq_num >= 16) return ControllerError.InvalidIrq;

        var port: u16 = undefined;
        if (irq_num < 8) {
            port = CONTROLLER_DATA;
        } else {
            port = FOLLOWER_DATA;
        }
        const bit = if (irq_num < 8) irq_num else irq_num - 8;
        const current = cpu.inb(port);
        cpu.outb(port, current & ~(@as(u8, 1) << @intCast(bit)));
    }

    fn eoi(irq_num: u8) ControllerError!void {
        if (irq_num >= 16) return ControllerError.InvalidIrq;

        if (irq_num >= 8) cpu.outb(FOLLOWER_CMD, 0x20);
        cpu.outb(CONTROLLER_CMD, 0x20);
    }

    const controller: Controller = .{
        .init = init,
        .mask = mask,
        .unmask = unmask,
        .eoi = eoi,
        .name = "8259 PIC",
    };
};




// Interrupt Dispatcher //
pub const dispatcher = struct {
    var handlers: [256]?HandlerFn = [_]?HandlerFn{null} ** 256;

    pub fn register(vector: Vector, handler: HandlerFn) void {
        handlers[vector.toValue()] = handler;
    }

    pub fn unregister(vector: Vector) void {
        handlers[vector.toValue()] = null;
    }

    // Called from assembly stub
    export fn interrupt_dispatcher(frame: *InterruptFrame) callconv(.C) void {
        const vector_n = Vector.fromValue(@intCast(frame.vector));
        if (vector_n == null) {
            std.log.err("Invalid interrupt vector: {d}", .{frame.vector});
            defaultHandler(frame);
            return;
        }
        const vector = vector_n.?;

        if (handlers[frame.vector]) |handler| {
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
        const vector = Vector.fromValue(@intCast(frame.vector));
        std.log.err("Unhandled interrupt: {any} ({any})", .{ vector, frame.vector });

        if (frame.vector < 32) {
            // CPU exception - halt system
            std.log.err("CPU Exception at RIP: 0x{X}", .{frame.rip});
            asm volatile ("cli; hlt");
        }
    }
};

pub const exceptions = struct {
    fn formatException(comptime name: []const u8, frame: *InterruptFrame) void {
        std.log.err("EXCEPTION: {s}", .{name});
        std.log.err("  RIP: 0x{X:0>16}", .{frame.rip});
        std.log.err("  Error Code: 0x{X:0>16}", .{frame.error_code});
        std.log.err("  RAX: 0x{X:0>16} RBX: 0x{X:0>16}", .{ frame.rax, frame.rbx });
        std.log.err("  RCX: 0x{X:0>16} RDX: 0x{X:0>16}", .{ frame.rcx, frame.rdx });
    }

    fn pageFault(frame: *InterruptFrame) void {
        const fault_addr = asm volatile ("mov %%cr2, %[result]"
            : [result] "=r" (-> u64)
        );

        const present = (frame.error_code & 1) != 0;
        const write = (frame.error_code & 2) != 0;
        const user = (frame.error_code & 4) != 0;

        pf_log.err("Page Fault at address: 0x{X:0>16}", .{fault_addr});
        pf_log.err("  RIP: 0x{X:0>16}", .{frame.rip});
        pf_log.err("  Error Code: 0x{X:0>16}", .{frame.error_code});
        pf_log.err("  Type: {s} {s} {s}", .{
            if (present) "protection violation" else "page not present",
            if (write) "write" else "read",
            if (user) "user" else "kernel",
        });

        if (!present) {
            // TODO @(dleiferives,d84fdf12-0708-41a7-98e1-f3d3c83ec957): update in
            // threading rewrite to get mapper from the current thread! ~#
            const kernel_state = kernel.state;
            if (kernel_state.initilized.mem_manager) {
                if (kernel_state.mem_manager.mapper) |mapper_ptr| {
                    pf_log.err("Handling demand page fault at 0x{X:0>16}", .{fault_addr});
                    var mapper = @constCast(mapper_ptr);
                    if (mapper.handleDemandPageFault(fault_addr)) |success| {
                        if (success) {
                            pf_log.info("Successfully handled demand page fault at 0x{X:0>16}", .{fault_addr});
                            pf_log.info("Continuing execution after handling page fault", .{});
                            return; // Successfully handled, continue execution
                        } else {
                            pf_log.err("Failed to handle demand page fault at 0x{X:0>16}", .{fault_addr});
                            asm volatile("cli; hlt");
                            return;
                        }
                    } else |err| {
                        // TODO
                        // @(dleiferives,b45808dd-3874-4253-aed1-a34a791684b6):
                        // upgrade this to fault out the program that is calling.
                        // if its in the kernel... well the kernel really should
                        // not be running out of space. could use swap or
                        // something. at the end of the day I think that I will
                        // just make it such that the heap will not overallocate
                        // (ie. limit the heap to the nmber of free pages.) ~#
                        irq_log.err("Error handling demand page fault: {}", .{err});
                    }
                }
            }
        }

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

    fn genericException(comptime name: []const u8) HandlerFn {
        return struct {
            fn handler(frame: *InterruptFrame) void {
                formatException(name, frame);
                asm volatile ("cli; hlt");
            }
        }.handler;
    }

    fn syscallHandler(frame: *InterruptFrame) void {
        std.log.debug("syscall handler",.{});
        syscall.handleSyscall(frame);
    }

    // fn cleanupHandler(frame: *InterruptFrame) void {
    //     std.log.debug("cleanup handler",.{});

    //     if (thread.cleanup_thread) |cleanup| {
    //         if (thread.getCurrentThread()) |current| {
    //             if (current != cleanup) {
    //                 thread.switchContext(current, cleanup,frame);
    //             }
    //         }
    //     }
    // }



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

    pub fn initThreading() void{
        dispatcher.register(.syscall, syscallHandler);
        // dispatcher.register(@enumFromInt(thread.THREAD_CLEANUP_VECTOR), cleanupHandler);
    }

};

pub const irq = struct {
    var current_controller: Controller = pic.controller;

    pub fn init() !void {
        std.log.info("Initializing IRQ system...",.{});
        idt.init();
        disable();
        idt.setupStubs();

        try current_controller.init();
        exceptions.init();

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
