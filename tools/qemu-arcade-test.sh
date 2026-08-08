#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir="$repo_dir/.qemu-test"
root_tree="$test_dir/root-tree"
iso_tree="$test_dir/iso-tree"
serial_log="$test_dir/arcade-serial.log"

rm -rf "$test_dir"
mkdir -p "$root_tree/boot/grub" "$root_tree/bin" "$iso_tree/boot/grub"
cp "$repo_dir/zig-out/bin/kernel" "$root_tree/boot/kernel"
cp "$repo_dir/zig-out/bin/echo_program" "$root_tree/bin/program"
cp "$repo_dir/tools/grub-arcade-test.cfg" "$root_tree/boot/grub/grub.cfg"

truncate -s 128M "$test_dir/root-gpt.img"
parted -s "$test_dir/root-gpt.img" mklabel gpt
parted -s "$test_dir/root-gpt.img" mkpart thad-os ext2 2048s 260095s
mke2fs -q -t ext2 -b 1024 -L thad-os -E offset=1048576 \
    -d "$root_tree" "$test_dir/root-gpt.img" 129024

cp "$repo_dir/zig-out/bin/kernel" "$iso_tree/boot/kernel"
cp "$repo_dir/tools/grub-arcade-test.cfg" "$iso_tree/boot/grub/grub.cfg"
grub-mkrescue -o "$test_dir/thad-arcade-test.iso" "$iso_tree" >/dev/null 2>&1

if [ -n "${OVMF_CODE:-}" ]; then
    ovmf_code=$OVMF_CODE
elif [ -f /usr/share/ovmf/OVMF.fd ]; then
    ovmf_code=/usr/share/ovmf/OVMF.fd
else
    ovmf_code=/usr/share/OVMF/OVMF_CODE.fd
fi

# Drive every entry through QEMU's UHCI USB keyboard. Each game must
# acknowledge Escape and redraw the menu before the next selection is sent.
(
    sleep 25
    printf 'screendump /work/.qemu-test/arcade-menu.ppm\n'
    sleep 1
    printf 'sendkey 2\n'
    sleep 1
    printf 'sendkey ret\n'
    sleep 1
    # Hold S long enough to cross the USB typematic delay and exercise repeats.
    printf 'sendkey s 800\n'
    sleep 1
    printf 'screendump /work/.qemu-test/arcade-pong.ppm\n'
    sleep 2
    printf 'sendkey esc\n'
    sleep 2
    printf 'sendkey 3\n'
    sleep 1
    printf 'sendkey ret\n'
    sleep 1
    printf 'screendump /work/.qemu-test/arcade-tetris.ppm\n'
    sleep 2
    printf 'sendkey esc\n'
    sleep 2
    printf 'sendkey 1\n'
    sleep 1
    printf 'sendkey ret\n'
    sleep 1
    printf 'screendump /work/.qemu-test/arcade-snakes.ppm\n'
    sleep 2
    printf 'sendkey esc\n'
    sleep 4
    printf 'quit\n'
) | timeout 50s qemu-system-x86_64 \
    -machine q35,accel=tcg \
    -m 512M \
    -bios "$ovmf_code" \
    -cdrom "$test_dir/thad-arcade-test.iso" \
    -drive id=thaddisk,file="$test_dir/root-gpt.img",format=raw,if=none \
    -device ide-hd,drive=thaddisk \
    -usb \
    -device usb-kbd \
    -device piix3-usb-uhci,id=extra-uhci \
    -device usb-kbd,bus=extra-uhci.0 \
    -display none \
    -serial "file:$serial_log" \
    -monitor stdio \
    -no-reboot >/dev/null 2>&1

cat "$serial_log"
grep -q "Framebuffer console initialized" "$serial_log"
grep -q "2 UHCI HID boot keyboard(s) ready" "$serial_log"
grep -q "Arcade menu ready" "$serial_log"
grep -q "Pong started" "$serial_log"
grep -q "Pong returned to menu" "$serial_log"
grep -q "Tetris started" "$serial_log"
grep -q "Tetris returned to menu" "$serial_log"
grep -q "Snakes started" "$serial_log"
grep -q "Snakes returned to menu" "$serial_log"
if grep -q "Failed to handle demand page fault" "$serial_log"; then
    exit 1
fi
test -s "$test_dir/arcade-menu.ppm"
test -s "$test_dir/arcade-pong.ppm"
test -s "$test_dir/arcade-tetris.ppm"
test -s "$test_dir/arcade-snakes.ppm"
