set tcp auto-retry on
set tcp connect-timeout unlimited
target extended-remote :1234
add-symbol-file zig-out/bin/kernel
