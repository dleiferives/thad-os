// src/arch/x86_64/boot/boot.zig
const std = @import("std");
const arch = @import("arch");
const kernel = @import("kernel");
comptime {
    _ = kernel.kmain;
    _ = kernel.panic;
}

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, return_address: ?usize) noreturn {
    kernel.panic(msg, trace, return_address);
}

pub const std_options: std.Options = .{
    // By default, in safe build modes, the standard library will attach a segfault handler to the program to
    // print a helpful stack trace if a segmentation fault occurs. Here, we can disable this, or even enable
    // it in unsafe build modes.
    .enable_segfault_handler = true,

    // This is the logging function used by `std.log`.
    .logFn = kernel.logger,
    .log_level = .debug,
    .page_size_min = 4096, // 4 KiB
    .page_size_max = 1024 * 1024 * 1024, // 1Gb
};

// Using the linker to sneakily move some asm into language code
// Namely, we're using .bss.stacck to be at the end of the .bss section
// this will become the stack that the kernel uses
export var kernel_stack: [1024 << 4]u8 align(16) linksection(".bss.stack") = undefined;

// TODO @(dleiferives,ab22758a-dd7e-42ad-916b-bff21ff6c8e2): Replace this with zig
// and not asm ~#
comptime {
    asm (
    // setup the multiboot header
        \\ .set MBOOT2_MAGIC, 0xE85250D6
        \\ .set MBOOT2_ARCH, 0
        \\ .set MBOOT2_LENGTH, (Multiboot2HeaderEnd - Multiboot2Header)
        \\ .set MBOOT2_CHECKSUM, -(MBOOT2_MAGIC + MBOOT2_ARCH + MBOOT2_LENGTH)
        \\
        \\ .section .multiboot
        \\ .align 8
        \\ Multiboot2Header:
        \\ .long MBOOT2_MAGIC
        \\ .long MBOOT2_ARCH
        \\ .long MBOOT2_LENGTH
        \\ .long MBOOT2_CHECKSUM
        \\
        // Request the MacBook's native 1280x800-style 32-bit framebuffer.
        // The tag is optional so machines without that exact mode still boot.
        \\ .short 5
        \\ .short 1
        \\ .long 20
        \\ .long 1280
        \\ .long 800
        \\ .long 32
        \\ .balign 8
        \\
        \\ .short 0
        \\ .short 0
        \\ .long 8
        \\ Multiboot2HeaderEnd:

        // === 32-bit code ===
        \\ .att_syntax prefix
        \\ .code32
        \\
        \\ .section .text
        \\ .global _entry
        \\ _entry:
        \\ cli

        // Setup the stack pointer
        \\ movl $(KERNEL_VIRTUAL_STACK_END - 0xFFFFFF8000000000), %esp

        // Check for multiboot!
        \\ cmpl $0x36d76289, %eax
        \\ jne .no_multiboot

        // Save the location of the multiboot info structure
        \\ movl %ebx, (multiboot_info_ptr - 0xFFFFFF8000000000)

        // Load our page tables!
        \\ movl $(BootP4 - 0xFFFFFF8000000000), %eax
        \\ movl %eax, %cr3

        // Enable paging and long mode
        \\ movl %cr4, %eax
        \\ orl $(1 << 5), %eax
        \\ movl %eax, %cr4

        // Setup for longmode
        \\ movl $0xC0000080, %ecx
        \\ rdmsr
        \\ orl $(1 << 8), %eax
        \\ wrmsr

        // Enable paging
        \\ movl %cr0, %eax
        \\ orl $(1 << 31), %eax
        \\ movl %eax, %cr0

        // Load gdt
        \\ lgdt (BootGDTPtr - 0xFFFFFF8000000000)

        // Jump to 64 bit mode
        \\ ljmp $0x8, $(long_mode_start - 0xFFFFFF8000000000)

        // Deep error if we don't have multiboot
        \\ .no_multiboot:
        \\ hlt
        \\ jmp .no_multiboot

        // === 64-bit code ===
        \\ .align 8
        \\ .code64
        \\ long_mode_start:
        \\ movw $0x10, %ax
        \\ movw %ax, %ss
        \\ movw %ax, %ds
        \\ movw %ax, %es
        \\ movw %ax, %fs
        \\ movw %ax, %gs
        \\

        // Jump to our higher half code!
        \\ movabs $higher_half_start, %rax
        \\ jmpq *%rax
        \\
        \\ .code64
        \\ higher_half_start:

        // update our stack pointer to the higher half
        \\ movq $0xFFFFFF8000000000, %rax
        \\ addq %rax, %rsp

        // Unmap the lower memory..
        \\ movq $0, %rax                  # Value to write (0)
        \\ movabs $BootP4, %rbx           # Load the 64-bit address of BootP4 into RBX
        \\ movq %rax, (%rbx)              # Write the value from RAX to the address in RBX
        \\
        // Manually reload our page tables!
        // this is so that the tlb gets flushed
        \\ movq %cr3, %rax
        \\ movq %rax, %cr3

        // Reload other things witht he higher half stuff too
        \\ movabs $BootGDTPtr, %rax
        \\ lgdt (%rax)
        \\ movabs $reload_cs, %rax
        \\ pushq $0x8
        \\ pushq %rax
        \\ lretq

        // Call the kmain!
        \\ reload_cs:
        \\ movabs $kmain, %rax
        \\ call *%rax

        // Return to assembly code
        // dunno what to do here tbh
        \\ cli
        \\ hlt
        \\ jmp .

        // Memory for the multiboot info pointer
        \\ .section .data
        \\ .align 8
        \\ multiboot_info_ptr:
        \\ .quad 0

        // Setting up the gdt
        \\ .section .rodata
        \\ .align 16
        \\ BootGDT:
        \\ .quad 0
        // Code segment
        \\ .quad 0x00AF9A000000FFFF
        // Data segment
        \\ .quad 0x00AF92000000FFFF

        // Manual allocation for the GDT pointer
        \\ BootGDTPtr:
        \\ .word BootGDTPtr - BootGDT - 1
        \\ .quad BootGDT
        \\ .section .data
        \\ .align 4096
        \\ .global BootP4
        \\ BootP4:
        \\ .quad BootP3 - 0xFFFFFF8000000000 + ((1 << 0) | (1 << 1))
        \\ .rept 512 - 2
        \\ .quad 0
        \\ .endr
        \\ .quad BootP3 - 0xFFFFFF8000000000 + ((1 << 0) | (1 << 1))
        \\
        \\ .align 4096
        \\ BootP3:
        \\ .quad BootP2 - 0xFFFFFF8000000000 + ((1 << 0) | (1 << 1))
        \\ .rept 512 - 1
        \\ .quad 0
        \\ .endr
        \\
        \\ .align 4096
        \\ BootP2:
        \\ .set i, 0
        \\ .rept 512
        \\ .quad (i << 21) + ((1 << 0) | (1 << 1) | (1 << 7))
        \\ .set i, i+1
        \\ .endr
    );
}
