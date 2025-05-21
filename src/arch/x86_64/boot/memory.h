/* memory.h */
#ifndef MEMORY_H
#define MEMORY_H

#define KERNEL_OFFSET 0xFFFFFF8000000000

/* Paging constants */
#define PAGE_PRESENT (1 << 0)
#define PAGE_WRITE   (1 << 1)
#define ENTRIES_PER_PT 512

#ifdef __ASSEMBLER__
/* For assembly code */
#define V2P(a) ((a) - KERNEL_OFFSET)
#define P2V(a) ((a) + KERNEL_OFFSET)
#else
/* For C code */
#include <stdint.h>
#define V2P(a) ((uintptr_t)(a) & ~KERNEL_OFFSET)
#define P2V(a) ((uintptr_t)(a) | KERNEL_OFFSET)
#endif

#endif /* MEMORY_H */
