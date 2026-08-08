#!/bin/sh
set -eu

# This is a hardware profile, not merely a display option: it also installs
# the bootstrap page-table mapping needed for the MacBook4,1 AHCI ABAR.
zig_bin=${ZIG:-zig}
exec "$zig_bin" build -Dmacbook_early_fb=true "$@"
