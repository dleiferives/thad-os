#include "syscalls.h"

void _start() {
    putc('>');
    putc(' ');

    while (1) {
        char c = getc();
        if (c == '\n') {
            putc('\n');
            putc('>');
            putc(' ');
        } else {
            putc(c);
        }
    }
}
