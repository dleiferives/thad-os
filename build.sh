#!/usr/bin/env sh

as --64 src/arch/x86_64/boot/boot_all.asm -o boot.o

ld -m elf_x86_64 -T src/arch/x86_64/boot/Link.ld boot.o src/arch/x86_64/boot/kmain.o -o zig-out/bin/kernel.bin --omagic
