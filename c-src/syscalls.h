#ifndef SYSCALLS_H
#define SYSCALLS_H

static inline void putc(char c) {
    __asm__ volatile (
        "int $0x80"
        :
        : "a"(5), "D"(c) // rax=5 (PUTC), rdi=c
        : "memory"
    );
}

static inline char getc() {
    char result;
    __asm__ volatile (
        "int $0x80"
        : "=a"(result) // result in rax
        : "a"(6)       // rax=6 (GETC)
        : "memory"
    );
    return result;
}


#endif // SYSCALLS_H
