ENTRY(_entry)

KERNEL_OFFSET = 0xFFFFFF8000000000;
KERNEL_START = 0x100000; /* 1MB, typically where GRUB loads kernels */

SECTIONS
{
    . = KERNEL_START + KERNEL_OFFSET;

    .text ALIGN(4K) : AT(ADDR(.text) - KERNEL_OFFSET)
    {
        *(.multiboot)   /* Put multiboot header first */
        *(.text)
    }

    .rodata ALIGN(4K) : AT(ADDR(.rodata) - KERNEL_OFFSET)
    {
        *(.rodata)
    }

    .data ALIGN(4K) : AT(ADDR(.data) - KERNEL_OFFSET)
    {
        *(.data)
    }

    .bss ALIGN(4K) : AT(ADDR(.bss) - KERNEL_OFFSET)
    {
        *(COMMON)
        *(.bss)
    }

    /* Record the end of kernel for memory allocation */
    KERNEL_END = .;
}
