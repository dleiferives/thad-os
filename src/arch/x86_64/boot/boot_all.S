#define MBOOT2_MAGIC 0xE85250D6
#define MBOOT2_ARCH 0
#define MBOOT2_LENGTH (Multiboot2HeaderEnd - Multiboot2Header)
#define MBOOT2_CHECKSUM -(MBOOT2_MAGIC + MBOOT2_ARCH + MBOOT2_LENGTH)
.section .multiboot

.align 0x8
Multiboot2Header:
.long MBOOT2_MAGIC
.long MBOOT2_ARCH
.long MBOOT2_LENGTH
.long MBOOT2_CHECKSUM

.short 0
.short 0
.long 8
Multiboot2HeaderEnd:

.intel_syntax noprefix
.section .data
.align 4096
.global BootP4
BootP4:
    /* Identity map first 1GB for boot (first entry) */
    .quad offset BootP3 - 0xFFFFFF8000000000 + (( 1 << 0) | (1 << 1))
    /* Middle entries empty */
    .rept 512 - 2
        .quad 0
    .endr
    /* Last entry (for higher half kernel) */
    .quad offset BootP3 - 0xFFFFFF8000000000 + (( 1 << 0) | (1 << 1))

.align 4096
BootP3:
    /* Map first 1GB using huge pages */
    .quad offset BootP2 - 0xFFFFFF8000000000 + (( 1 << 0) | (1 << 1))
    .rept 512 - 1
        .quad 0
    .endr

.align 4096
BootP2:
    /* Map 2MB pages for first 1GB */
    .set i, 0
    .rept 512
        .quad (i << 21) + (( 1 << 0) | (1 << 1) | (1 << 7))  /* Set huge page bit */
        .set i, i+1
    .endr

/* boot.S */
.intel_syntax noprefix
.code32

.section .text
.global _start
_start:
    /* Disable interrupts */
    cli

    /* Set up initial stack */
    mov esp, offset boot_stack_top - 0xFFFFFF8000000000

    /* Check for multiboot */
    cmp eax, 0x36d76289
    jne .no_multiboot

    /* Save multiboot info pointer */
    mov [multiboot_info_ptr - 0xFFFFFF8000000000], ebx

    /* Load our page tables */
    mov eax, offset BootP4 - 0xFFFFFF8000000000
    mov cr3, eax

    /* Enable PAE */
    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    /* Set long mode bit */
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr

    /* Enable paging */
    mov eax, cr0
    or eax, 1 << 31
    mov cr0, eax

    /* Load GDT */
    lgdt [BootGDTPtr - 0xFFFFFF8000000000]

    /* Jump to 64-bit code segment */
    jmp 0x8:long_mode_start - 0xFFFFFF8000000000

.no_multiboot:
    /* Handle error - just halt */
    hlt
    jmp .no_multiboot

.align 8
.code64
long_mode_start:
    /* Update segment registers */
    mov ax, 0x10
    mov ss, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax

    /* Jump to higher half kernel */
    movabs rax, offset higher_half_start
    jmp rax

.code64
higher_half_start:
    /* Now we're running in the higher half */

    /* Update stack pointer to higher half */
    mov rax, 0xFFFFFF8000000000
    add rsp, rax

    /* Unmap identity mapping of lower memory */
    mov rax, 0                 // Value to write (0)
    movabs rbx, offset BootP4  // Load the 64-bit address of BootP4 into RBX
    mov [rbx], rax             // Write the value from RAX to the address in RBX

    /* Reload cr3 to flush TLB */
    mov rax, cr3
    mov cr3, rax

    /* Reload GDT with higher half address */
    movabs rax, offset BootGDTPtr
    lgdt [rax]

    /* Reload CS register */
    movabs rax, offset reload_cs
    push 0x8
    push rax
    retfq

reload_cs:
    /* Call into C code */
    movabs rax, offset kmain
    call rax

    /* If C code returns, halt the CPU */
    cli
    hlt
    jmp $

/* Data section */
.section .data
.align 8
multiboot_info_ptr:
    .quad 0

/* Stack space */
.section .bss
.align 16
boot_stack_bottom:
    .skip 16384  /* 16 KiB */
boot_stack_top:

/* Global Descriptor Table */
.section .rodata
.align 16
BootGDT:
    /* Null descriptor */
    .quad 0
    /* Code segment descriptor */
    .quad 0x00AF9A000000FFFF
    /* Data segment descriptor */
    .quad 0x00AF92000000FFFF

BootGDTPtr:
    .word BootGDTPtr - BootGDT - 1
    .quad BootGDT
