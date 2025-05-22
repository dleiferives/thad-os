const std = @import("std");
const arch = @import("arch");
const kernel = @import("kernel");
comptime {
    _ = kernel.kmain;
    _ = kernel.panic;
}

pub const std_options: std.Options = .{
    // By default, in safe build modes, the standard library will attach a segfault handler to the program to
    // print a helpful stack trace if a segmentation fault occurs. Here, we can disable this, or even enable
    // it in unsafe build modes.
    .enable_segfault_handler = true,

    // This is the logging function used by `std.log`.
    .logFn = kernel.logger,
    .log_level = .debug,
    // .page_size_min = 4096, // 4 KiB
    // .page_size_max = 2 * 1024 * 1024, // 2 MiB
};

// Using the linker to sneakily move some asm into language code
// Namely, we're using .bss.stacck to be at the end of the .bss section
// this will become the stack that the kernel uses
export var kernel_stack: [1024 << 4]u8 align(16) linksection(".bss.stack") = undefined;

// Basic Multiboot2 header
comptime {
    asm (
        \\ /* Convert from Intel syntax to AT&T syntax for LLVM */
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
        \\ .short 0
        \\ .short 0
        \\ .long 8
        \\ Multiboot2HeaderEnd:
        \\
        \\
        \\ /* boot.S */
        \\ .att_syntax prefix
        \\ .code32
        \\
        \\ .section .text
        \\ .global _entry
        \\ _entry:
        \\ /* Disable interrupts */
        \\ cli
        \\
        \\ /* Set up initial stack */
        \\ movl $(KERNEL_VIRTUAL_STACK_END - 0xFFFFFF8000000000), %esp
        \\
        \\ /* Check for multiboot */
        \\ cmpl $0x36d76289, %eax
        \\ jne .no_multiboot
        \\
        \\ /* Save multiboot info pointer */
        \\ movl %ebx, (multiboot_info_ptr - 0xFFFFFF8000000000)
        \\
        \\ /* Load our page tables */
        \\ movl $(BootP4 - 0xFFFFFF8000000000), %eax
        \\ movl %eax, %cr3
        \\
        \\ /* Enable PAE */
        \\ movl %cr4, %eax
        \\ orl $(1 << 5), %eax
        \\ movl %eax, %cr4
        \\
        \\ /* Set long mode bit */
        \\ movl $0xC0000080, %ecx
        \\ rdmsr
        \\ orl $(1 << 8), %eax
        \\ wrmsr
        \\
        \\ /* Enable paging */
        \\ movl %cr0, %eax
        \\ orl $(1 << 31), %eax
        \\ movl %eax, %cr0
        \\
        \\ /* Load GDT */
        \\ lgdt (BootGDTPtr - 0xFFFFFF8000000000)
        \\
        \\ /* Jump to 64-bit code segment */
        \\ ljmp $0x8, $(long_mode_start - 0xFFFFFF8000000000)
        \\
        \\ .no_multiboot:
        \\ /* Handle error - just halt */
        \\ hlt
        \\ jmp .no_multiboot
        \\
        \\ .align 8
        \\ .code64
        \\ long_mode_start:
        \\ /* Update segment registers */
        \\ movw $0x10, %ax
        \\ movw %ax, %ss
        \\ movw %ax, %ds
        \\ movw %ax, %es
        \\ movw %ax, %fs
        \\ movw %ax, %gs
        \\
        \\ /* Jump to higher half kernel */
        \\ movabs $higher_half_start, %rax
        \\ jmpq *%rax
        \\
        \\ .code64
        \\ higher_half_start:
        \\ /* Now we're running in the higher half */
        \\
        \\ /* Update stack pointer to higher half */
        \\ movq $0xFFFFFF8000000000, %rax
        \\ addq %rax, %rsp
        \\
        \\ /* Unmap identity mapping of lower memory */
        \\ movq $0, %rax                  #// Value to write (0)
        \\ movabs $BootP4, %rbx           #// Load the 64-bit address of BootP4 into RBX
        \\ movq %rax, (%rbx)              #// Write the value from RAX to the address in RBX
        \\
        \\ /* Reload cr3 to flush TLB */
        \\ movq %cr3, %rax
        \\ movq %rax, %cr3
        \\
        \\ /* Reload GDT with higher half address */
        \\ movabs $BootGDTPtr, %rax
        \\ lgdt (%rax)
        \\
        \\ /* Reload CS register */
        \\ movabs $reload_cs, %rax
        \\ pushq $0x8
        \\ pushq %rax
        \\ lretq
        \\
        \\ reload_cs:
        \\ /* Call into C code */
        \\ movabs $kmain, %rax
        \\ call *%rax
        \\
        \\ /* If C code returns, halt the CPU */
        \\ cli
        \\ hlt
        \\ jmp .
        \\
        \\ /* Data section */
        \\ .section .data
        \\ .align 8
        \\ multiboot_info_ptr:
        \\ .quad 0
        \\
        \\
        \\ /* Global Descriptor Table */
        \\ .section .rodata
        \\ .align 16
        \\ BootGDT:
        \\ /* Null descriptor */
        \\ .quad 0
        \\ /* Code segment descriptor */
        \\ .quad 0x00AF9A000000FFFF
        \\ /* Data segment descriptor */
        \\ .quad 0x00AF92000000FFFF
        \\
        \\ BootGDTPtr:
        \\ .word BootGDTPtr - BootGDT - 1
        \\ .quad BootGDT
        \\ .section .data
        \\ .align 4096
        \\ .global BootP4
        \\ BootP4:
        \\ /* Identity map first 1GB for boot (first entry) */
        \\ .quad BootP3 - 0xFFFFFF8000000000 + ((1 << 0) | (1 << 1))
        \\ /* Middle entries empty */
        \\ .rept 512 - 2
        \\ .quad 0
        \\ .endr
        \\ /* Last entry (for higher half kernel) */
        \\ .quad BootP3 - 0xFFFFFF8000000000 + ((1 << 0) | (1 << 1))
        \\
        \\ .align 4096
        \\ BootP3:
        \\ /* Map first 1GB using huge pages */
        \\ .quad BootP2 - 0xFFFFFF8000000000 + ((1 << 0) | (1 << 1))
        \\ .rept 512 - 1
        \\ .quad 0
        \\ .endr
        \\
        \\ .align 4096
        \\ BootP2:
        \\ /* Map 2MB pages for first 1GB */
        \\ .set i, 0
        \\ .rept 512
        \\ .quad (i << 21) + ((1 << 0) | (1 << 1) | (1 << 7))  /* Set huge page bit */
        \\ .set i, i+1
        \\ .endr
    );
}
