/* boot_PT.S */
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
