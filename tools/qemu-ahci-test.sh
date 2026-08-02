#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir="$repo_dir/.qemu-test"
root_tree="$test_dir/root-tree"
iso_tree="$test_dir/iso-tree"
serial_log="$test_dir/ahci-serial.log"

rm -rf "$test_dir"
mkdir -p "$root_tree/boot/grub" "$root_tree/bin" "$iso_tree/boot/grub"
cp "$repo_dir/zig-out/bin/kernel" "$root_tree/boot/kernel"
cp "$repo_dir/zig-out/bin/echo_program" "$root_tree/bin/program"
cp "$repo_dir/tools/grub-ahci-test.cfg" "$root_tree/boot/grub/grub.cfg"

# Mirror the intended Mac layout: GPT, then a labeled ext2 filesystem inside a
# partition. The kernel must discover this through AHCI; it is not a boot module.
truncate -s 128M "$test_dir/root-gpt.img"
parted -s "$test_dir/root-gpt.img" mklabel gpt
parted -s "$test_dir/root-gpt.img" mkpart thad-os ext2 2048s 260095s
mke2fs -q -t ext2 -b 1024 -L thad-os -E offset=1048576 \
    -d "$root_tree" "$test_dir/root-gpt.img" 129024

cp "$repo_dir/zig-out/bin/kernel" "$iso_tree/boot/kernel"
cp "$repo_dir/tools/grub-ahci-test.cfg" "$iso_tree/boot/grub/grub.cfg"
grub-mkrescue -o "$test_dir/thad-ahci-test.iso" "$iso_tree" >/dev/null 2>&1

if [ -n "${OVMF_CODE:-}" ]; then
    ovmf_code=$OVMF_CODE
elif [ -f /usr/share/ovmf/OVMF.fd ]; then
    ovmf_code=/usr/share/ovmf/OVMF.fd
else
    ovmf_code=/usr/share/OVMF/OVMF_CODE.fd
fi

status=0
timeout 45s qemu-system-x86_64 \
    -machine q35,accel=tcg \
    -m 512M \
    -bios "$ovmf_code" \
    -cdrom "$test_dir/thad-ahci-test.iso" \
    -drive id=thaddisk,file="$test_dir/root-gpt.img",format=raw,if=none \
    -device ide-hd,drive=thaddisk \
    -display none \
    -serial stdio \
    -monitor none \
    -no-reboot >"$serial_log" 2>&1 || status=$?

cat "$serial_log"
if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
    exit "$status"
fi
grep -q "AHCI disk registered" "$serial_log"
grep -q "partition: at 2048" "$serial_log"
grep -q "found ext2 filesystem: thad-os" "$serial_log"
grep -q "Mounting ext2 filesystem as VFS root" "$serial_log"
grep -q "Successfully processed entire file" "$serial_log"
grep -q "ELF program loaded successfully" "$serial_log"
grep -q "Putc syscall invoked with char: 62" "$serial_log"
dd if="$test_dir/root-gpt.img" bs=512 skip=260096 count=2 2>/dev/null |
    grep -q "Zig kernel entered"
