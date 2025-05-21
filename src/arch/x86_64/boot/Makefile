# compiler/assembler settings with memory model for higher half
CC = gcc
AS = gcc
LD = ld

CFLAGS = -ffreestanding -mcmodel=large -mno-red-zone -mno-mmx -mno-sse \
         -mno-sse2 -nostdlib -Wall -Wextra -Werror -I./include
ASFLAGS = -c -mcmodel=large -m64
LDFLAGS = -T Link.ld -m elf_x86_64

# Source files
C_SOURCES = $(wildcard *.c)
ASM_SOURCES = boot_all.S # boot.S boot_PT.S multiboot_header.S
OBJ = $(C_SOURCES:.c=.o) $(ASM_SOURCES:.S=.o)

# Default target
all: kernel.bin

# Compile C sources
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

# Assemble assembly sources
%.o: %.S
	$(AS) $(ASFLAGS) $< -o $@

# Link the kernel
kernel.bin: $(OBJ)
	$(LD) $(LDFLAGS) -o $@ $^

# Clean up
clean:
	rm -f *.o kernel.bin
