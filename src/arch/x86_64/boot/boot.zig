// src/arch/x86_64/boot/boot.zig
const std = @import("std");
const arch = @import("arch");
const kernel = @import("kernel");
const config = @import("boot_config");
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
    // MacBook4,1 GM965 prefetchable framebuffer aperture. Fill the full
    // 1280x800 scanout, including its 8192-byte padded stride, magenta.
    const macbook_early_marker = if (config.macbook_early_fb)
        "\ncld\nmovl $0x00FF00FF, %eax\nmovl $0xA0000000, %edi\nmovl $1638400, %ecx\nrep stosl\n"
    else
        "\n";
    const macbook_long_mode_marker = if (config.macbook_early_fb)
        "\nmovl $0x0000FF00, %eax\nmovl $0xA0000000, %edi\nmovl $163840, %ecx\nrep stosl\n"
    else
        "\n";
    const macbook_higher_half_marker = if (config.macbook_early_fb)
        "\nmovl $0x000000FF, %eax\nmovabs $0xFFFFFF80A00A0000, %rdi\nmovl $163840, %ecx\nrep stosl\n"
    else
        "\n";
    const macbook_tlb_marker = if (config.macbook_early_fb)
        "\nmovl $0x0000FFFF, %eax\nmovabs $0xFFFFFF80A0140000, %rdi\nmovl $163840, %ecx\nrep stosl\n"
    else
        "\n";

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

        // This marker runs before thad-os constructs page tables, so it can
        // distinguish entry failures from later VM/driver failures.
    ++ macbook_early_marker ++

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
        // Green: the CPU successfully entered 64-bit long mode.
    ++ macbook_long_mode_marker ++
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

        // Blue: the higher-half jump and stack relocation succeeded.
    ++ macbook_higher_half_marker ++

        // Unmap the lower memory..
        \\ movq $0, %rax                  # Value to write (0)
        \\ movabs $BootP4, %rbx           # Load the 64-bit address of BootP4 into RBX
        \\ movq %rax, (%rbx)              # Write the value from RAX to the address in RBX
        \\
        // Manually reload our page tables!
        // this is so that the tlb gets flushed
        \\ movq %cr3, %rax
        \\ movq %rax, %cr3

        // Cyan: the low mapping was removed and the TLB was reloaded.
    ++ macbook_tlb_marker ++

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
        \\ .quad 0
        \\ .quad BootFramebufferP2 - 0xFFFFFF8000000000 + ((1 << 0) | (1 << 1))
        \\ .rept 512 - 3
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

        // Map the 8 MiB GM965 scanout window needed by the early marker.
        \\ .align 4096
        \\ BootFramebufferP2:
        \\ .rept 256
        \\ .quad 0
        \\ .endr
        \\ .set i, 256
        \\ .rept 4
        \\ .quad 0x80000000 + (i << 21) + ((1 << 0) | (1 << 1) | (1 << 4) | (1 << 7))
        \\ .set i, i+1
        \\ .endr
        // MacBook4,1 ICH8M AHCI ABAR 0xB0704000 lies in this 2 MiB page.
        // Keeping the entry in this Mac-specific bootstrap profile lets the
        // hardware driver avoid modifying retained firmware page tables.
        \\ .rept 127
        \\ .quad 0
        \\ .endr
        \\ .quad 0x80000000 + (387 << 21) + ((1 << 0) | (1 << 1) | (1 << 4) | (1 << 7))
        \\ .rept 124
        \\ .quad 0
        \\ .endr
    );

    // TODO: Replace the compile-time Mac framebuffer marker with a generic
    // early-console abstraction once Multiboot tags can be parsed before VM
    // initialization.
    // TODO: Replace the fixed Mac AHCI bootstrap mapping with a generic early
    // MMIO mapper after retained page-table mutation works on this firmware.
}
