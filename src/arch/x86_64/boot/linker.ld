ENTRY(_entry)

GRUB_GAP = 0x100000;
KERNEL_OFFSET = 0xFFFFFF8000000000;
KERNEL_VIRTUAL_ADDRESS_START = KERNEL_OFFSET | GRUB_GAP;

SECTIONS
{
    . = GRUB_GAP + KERNEL_OFFSET;

    KERNEL_PHYSICAL_ADDRESS_START = . - KERNEL_OFFSET;

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

    .bss.stack ALIGN(4K) : AT (ADDR(.bss.stack) - KERNEL_OFFSET) {
        KERNEL_VIRTUAL_STACK_START = .;
        KEEP(*(.bss.stack))
        KERNEL_VIRTUAL_STACK_END = .;
    }

    KERNEL_VIRTUAL_ADDRESS_END = .;
    KERNEL_PHYSICAL_ADDRESS_END = KERNEL_VIRTUAL_ADDRESS_END - KERNEL_OFFSET;
}
