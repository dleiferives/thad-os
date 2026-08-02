#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir="$repo_dir/.qemu-test"
root_tree="$test_dir/root-tree"
iso_tree="$test_dir/iso-tree"

rm -rf "$test_dir"
mkdir -p "$root_tree/boot/grub" "$root_tree/bin" "$iso_tree/boot/grub"
cp "$repo_dir/zig-out/bin/kernel" "$root_tree/boot/kernel"
cp "$repo_dir/zig-out/bin/echo_program" "$root_tree/bin/program"
cp "$repo_dir/tools/grub-test.cfg" "$root_tree/boot/grub/grub.cfg"

# A partitioned MBR image is used because thad-os's ext2 layer consumes block
# devices containing partition tables. GRUB loads this whole image as a module.
truncate -s 64M "$test_dir/root.img"
parted -s "$test_dir/root.img" mklabel msdos
parted -s "$test_dir/root.img" mkpart primary ext2 2048s 100%
parted -s "$test_dir/root.img" set 1 boot on
mke2fs -q -t ext2 -b 1024 -L thad-os -E offset=1048576 \
    -d "$root_tree" "$test_dir/root.img" 64512

cp "$repo_dir/zig-out/bin/kernel" "$iso_tree/boot/kernel"
cp "$test_dir/root.img" "$iso_tree/boot/root.img"
cp "$repo_dir/tools/grub-test.cfg" "$iso_tree/boot/grub/grub.cfg"

grub-mkrescue -o "$test_dir/thad-test.iso" "$iso_tree" >/dev/null 2>&1

if [ -n "${OVMF_CODE:-}" ]; then
    ovmf_code=$OVMF_CODE
elif [ -f /usr/share/ovmf/OVMF.fd ]; then
    ovmf_code=/usr/share/ovmf/OVMF.fd
else
    ovmf_code=/usr/share/OVMF/OVMF_CODE.fd
fi
timeout 45s qemu-system-x86_64 \
    -machine q35,accel=tcg \
    -m 512M \
    -bios "$ovmf_code" \
    -cdrom "$test_dir/thad-test.iso" \
    -display none \
    -serial stdio \
    -monitor none \
    -no-reboot
