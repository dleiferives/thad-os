/* kmain.c */
#include "memory.h"
#include <stdint.h>

/* Simple VGA text mode buffer for display output */
#define VGA_MEMORY 0xB8000
#define VGA_WIDTH 80
#define VGA_HEIGHT 25

/* Colors */
#define VGA_COLOR_BLACK 0
#define VGA_COLOR_LIGHT_GREY 7
#define VGA_COLOR_WHITE 15

uint16_t* vga_buffer;

void clear_screen() {
    vga_buffer = (uint16_t*)P2V(VGA_MEMORY);

    for (int y = 0; y < VGA_HEIGHT; y++) {
        for (int x = 0; x < VGA_WIDTH; x++) {
            const int index = y * VGA_WIDTH + x;
            vga_buffer[index] = (VGA_COLOR_BLACK << 8) | ' ';
        }
    }
}

void print_string(const char* str) {
    static int x = 0, y = 0;

    while (*str) {
        if (*str == '\n') {
            x = 0;
            y++;
            if (y >= VGA_HEIGHT) y = 0;
            str++;
            continue;
        }

        const int index = y * VGA_WIDTH + x;
        vga_buffer[index] = (VGA_COLOR_LIGHT_GREY << 8) | *str;

        x++;
        if (x >= VGA_WIDTH) {
            x = 0;
            y++;
            if (y >= VGA_HEIGHT) y = 0;
        }

        str++;
    }
}

void kmain() {
    clear_screen();
    print_string("Hello from higher half kernel!\n");
    print_string("We are now running at 0xFFFFFF8000000000\n");

    /* Infinite loop - don't return */
    while (1) {
        /* Halt the CPU until next interrupt */
        __asm__ volatile("hlt");
    }
}
