const std = @import("std");
const Builder = std.Build;
const fs = std.fs;
const fmt = std.fmt;
const ArrayList = std.ArrayList;
//const std = @import("/home/dleiferives/.local/share/zigup/0.14.0/files/lib/std/std.zig");

pub fn build(b: *std.Build) void {
    // Target options
    var target_query: std.Target.Query = .{
        .cpu_arch = std.Target.Cpu.Arch.x86_64,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64 },
        .os_tag = std.Target.Os.Tag.freestanding,
        .abi = std.Target.Abi.none,
        .ofmt = std.Target.ObjectFormat.elf,
    };
    // Add default and nice
    // target_query.cpu_features_add.addFeature(@intFromEnum(std.Target.x86.Feature.@"16bit_mode"));
    // target_query.cpu_features_add.addFeature(@intFromEnum(std.Target.x86.Feature.@"32bit_mode"));
    // target_query.cpu_features_add.addFeature(@intFromEnum(std.Target.x86.Feature.@"64bit"));
    // target_query.cpu_features_add.addFeature(@intFromEnum(std.Target.x86.Feature.soft_float));

    // Remove speedy and weird
    target_query.cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.mmx));
    target_query.cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.sse));
    target_query.cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.sse2));
    target_query.cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.avx));
    target_query.cpu_features_sub.addFeature(@intFromEnum(std.Target.x86.Feature.avx2));

    const target = b.resolveTargetQuery(target_query);

    // Standard optimization options
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    // =========================================================================
    // Echo Program (the one we will load)
    // =========================================================================
    const echo_program = b.addExecutable(.{
        .name = "echo_program",
        .target = target,
        .optimize = optimize,
    });

    // Add the C source file
    echo_program.addCSourceFile(.{ .file = b.path("c-src/echo.c") });
    echo_program.addIncludePath(b.path("c-src"));

    // Use our custom linker script
    echo_program.setLinkerScript(b.path("program.ld"));

    // Critical options for a freestanding program
    echo_program.setLibCFile(null); // No standard C library
    // echo_program.strip = true;
    echo_program.pie = false; // Not position-independent
    echo_program.bundle_compiler_rt = false;
    echo_program.bundle_ubsan_rt = false;
    echo_program.no_builtin = true;

    b.installArtifact(echo_program);

    // Boot
    const boot = b.addModule("boot", .{
        // TODO @(dleiferives,79feea73-404f-4e2d-b8db-2bba55db6ab3): make this
        // dynamic ~#
        .root_source_file = b.path("src/arch/x86_64/boot/boot.zig"),
        //.imports = .{}, // TODO
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .link_libcpp = false,
        .single_threaded = true,
        .strip = false,
        //.unwind_tables = false, // enable true for smaller package using in development
        //.dwarf_format = .@"64", causes it to crash!
        .code_model = .large,
        .stack_protector = false, // panic point on manual management
        .stack_check = false, // ditto
        .sanitize_c = false,
        .sanitize_thread = false,
        .fuzz = false,
        .valgrind = false,
        .pic = false,
        .red_zone = false,
        .omit_frame_pointer = false,
    });

    // Arch

    const arch = b.addModule("arch", .{
        // TODO @(dleiferives,79feea73-404f-4e2d-b8db-2bba55db6ab3): make this
        // dynamic ~#
        .root_source_file = b.path("src/arch/arch.zig"),
        //.imports = .{}, // TODO
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .link_libcpp = false,
        .single_threaded = true,
        .strip = false,
        //.unwind_tables = false, // enable true for smaller package using in development
        //.dwarf_format = .@"64", causes it to crash!
        .code_model = .kernel,
        .stack_protector = false, // panic point on manual management
        .stack_check = false, // ditto
        .sanitize_c = false,
        .sanitize_thread = false,
        .fuzz = false,
        .valgrind = false,
        .pic = false,
        .red_zone = false,
        .omit_frame_pointer = false,
    });

    // Kernel
    const kernel = b.addModule("kernel", .{
        .root_source_file = b.path("src/kernel/kernel.zig"),
        //.imports = .{}, // TODO
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .link_libcpp = false,
        .single_threaded = true,
        .strip = false,
        //.unwind_tables = false, // enable true for smaller package using in development
        //.dwarf_format = .@"64", causes it to crash!
        .code_model = .kernel,
        .stack_protector = false, // panic point on manual management
        .stack_check = false, // ditto
        .sanitize_c = false,
        .sanitize_thread = false,
        .fuzz = false,
        .valgrind = false,
        .pic = false,
        .red_zone = false,
        .omit_frame_pointer = false,
    });

    const drivers = b.addModule("drivers", .{
        .root_source_file = b.path("src/drivers/drivers.zig"),
        //.imports = .{}, // TODO
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .link_libcpp = false,
        .single_threaded = true,
        .strip = false,
        //.unwind_tables = false, // enable true for smaller package using in development
        //.dwarf_format = .@"64", causes it to crash!
        .code_model = .kernel,
        .stack_protector = false, // panic point on manual management
        .stack_check = false, // ditto
        .sanitize_c = false,
        .sanitize_thread = false,
        .fuzz = false,
        .valgrind = false,
        .pic = false,
        .red_zone = false,
        .omit_frame_pointer = false,
    });

    // --------------- core

    // const core = b.addModule("core", .{
    //     .root_source_file = b.path("src/core/core.zig"),
    //     //.imports = .{}, // TODO
    //     .target = target,
    //     .optimize = optimize,
    //     .link_libc = false,
    //     .link_libcpp =  false,
    //     .single_threaded = true,
    //     .strip = false,
    //     //.unwind_tables = false, // enable true for smaller package using in development
    //     //.dwarf_format = .@"64", causes it to crash!
    //     .code_model = .kernel,
    //     .stack_protector = false, // panic point on manual management
    //     .stack_check = false, // ditto
    //     .sanitize_c = false,
    //     .sanitize_thread = false,
    //     .fuzz = false,
    //     .valgrind = false,
    //     .pic = false,
    //     .red_zone = false,
    //     .omit_frame_pointer = false,
    // });

    // Do imports

    // boot.addObjectFile(b.path("src/arch/x86_64/boot/kmain.o"));
    // _ = kernel;
    boot.addImport("kernel", kernel);
    // boot.addImport("arch", arch);
    // boot.addImport("drivers",drivers);

    kernel.addImport("drivers", drivers);
    // kernel.addImport("core",core);
    kernel.addImport("arch", arch);

    // drivers.addImport("core",core);
    drivers.addImport("arch", arch);
    drivers.addImport("kernel", kernel);

    // arch.addImport("core",core);
    arch.addImport("kernel", kernel);
    arch.addAssemblyFile(b.path("src/arch/x86_64/context_switch.S"));

    // TODO @(dleiferives,e310b4ad-095c-48ad-80fe-3b7d400194a6): move multiboot
    // header and stuff to core ~#
    // core.addImport("arch",arch);

    // Do assemble :bleh
    // arch.addAssemblyFile(b.path("src/arch/x86_64/cpu/entry_expanded.S"));
    arch.addAssemblyFile(b.path("src/arch/x86_64/interrupt_stubs.S"));

    const test_vga = b.option(bool, "test_vga", "Enable Vga Test for early kernel boot") orelse false;
    const test_pagebitfield = b.option(bool, "test_pagebitfield", "Enable page_bitfield for early kernel boot") orelse false;
    const test_mapper = b.option(bool, "test_mapper", "Enable test_mapper for early kernel boot") orelse false;
    const test_map_dispatch = b.option(bool, "test_map_dispatch", "Enable test_map_dispatch for early kernel boot") orelse false;
    const test_allocator = b.option(bool, "test_allocator", "Enable test_allocator for early kernel boot") orelse false;
    const test_threading_increment = b.option(bool, "test_threading_increment", "Enable test_threading_increment for early kernel boot") orelse false;
    const test_threading_snakes = b.option(bool, "test_threading_snakes", "Enable test_threading_snakes for early kernel boot") orelse false;
    const test_threading_snakes_hungry = b.option(bool, "test_threading_snakes_hungry", "Enable test_threading_snakes_hungry for early kernel boot") orelse false;
    const test_change_scheduler = b.option(bool, "test_change_scheduler", "Enable test_change_scheduler for early kernel boot") orelse false;
    const macbook_early_fb = b.option(bool, "macbook_early_fb", "Enable the MacBook4,1 pre-paging framebuffer marker") orelse false;

    // Add our options
    const options = b.addOptions();
    options.addOption(bool, "test_vga", test_vga);
    options.addOption(bool, "test_pagebitfield", test_pagebitfield);
    options.addOption(bool, "test_mapper", test_mapper);
    options.addOption(bool, "test_map_dispatch", test_map_dispatch);
    options.addOption(bool, "test_allocator", test_allocator);
    options.addOption(bool, "test_threading_increment", test_threading_increment);
    options.addOption(bool, "test_threading_snakes", test_threading_snakes);
    options.addOption(bool, "test_threading_snakes_hungry", test_threading_snakes_hungry);
    options.addOption(bool, "test_change_scheduler", test_change_scheduler);
    options.addOption(bool, "macbook_early_fb", macbook_early_fb);
    kernel.addOptions("config", options);

    const boot_options = b.addOptions();
    boot_options.addOption(bool, "macbook_early_fb", macbook_early_fb);
    boot.addOptions("boot_config", boot_options);

    // Create an executable
    const exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = boot,
    });

    // Set linker script
    exe.setLinkerScript(b.path("src/arch/x86_64/boot/linker.ld"));
    // exe.libc_file = null;

    exe.addIncludePath(b.path("c-src"));
    exe.addCSourceFile(.{ .file = b.path("c-src/snakes.c") });

    // TODO @(dleiferives,64b269c0-c96d-4583-b536-7930e0615c77): I want to not do
    // this... but I'm just going to do it for the moment I think ~#
    // TODO @(dleiferives,2b69fe44-d94f-4bd8-b4d4-7d72bdcfe46b): I've now removed
    // it! ~#
    exe.bundle_compiler_rt = false;
    // don't panic on undefined behaviour, we're probably going to be doing some
    exe.bundle_ubsan_rt = false;
    // we have to provide our own panic handler and such.
    exe.no_builtin = true;
    exe.subsystem = .Console;

    // TESTING
    // exe.link_data_sections = true;
    exe.link_eh_frame_hdr = true;
    // exe.link_function_sections = true;
    // exe.link_gc_sections = true;

    // Would ruin so much lmao
    exe.pie = false;

    // set our entry point to our entry point
    exe.entry = .{ .symbol_name = "_entry" };

    // grub expected image base
    // handled in the linker
    // exe.image_base = 0x100000;

    // Just setting so they don't allocate for me!
    // exe.stack_size = 0;
    exe.want_lto = false;

    // DEBUG
    exe.discard_local_symbols = false;

    // Allow panic handler to direcly dump to vga output!
    // depricated exe.formatted_panics = false;

    // kernel start -------------

    // Install the kernel executable in the install step
    b.installArtifact(exe);

    // Paths
    const image_path = "os_image.img";

    // Step 1: Create the empty disk image
    const create_img = b.addSystemCommand(&[_][]const u8{ "dd", "if=/dev/zero", std.fmt.comptimePrint("of={s}", .{image_path}), "bs=512", "count=65536" });

    // Step 2: Partition the image with parted
    const parted_label = b.addSystemCommand(&[_][]const u8{ "parted", image_path, "mklabel", "msdos" });
    parted_label.step.dependOn(&create_img.step);

    const parted_part = b.addSystemCommand(&[_][]const u8{ "parted", image_path, "mkpart", "primary", "ext2", "2048s", "63480s" });
    parted_part.step.dependOn(&parted_label.step);

    const parted_boot = b.addSystemCommand(&[_][]const u8{ "parted", image_path, "set", "1", "boot", "on" });
    parted_boot.step.dependOn(&parted_part.step);

    // Step 3: Install GRUB and format partition
    const install_grub = b.addSystemCommand(&[_][]const u8{
        "bash", "-c",
        \\set -eux
        \\LOOP1=""
        \\LOOP2=""
        \\
        \\# This function unmounts the partition and detaches the loopback devices.
        \\# It is designed to be safe to run even if some steps failed.
        \\cleanup() {
        \\    echo "--- Running cleanup ---"
        \\    # The '|| true' prevents the script from failing if umount/rmdir fails (e.g., not mounted).
        \\    if [ -d /mnt/osfiles ]; then
        \\        sudo umount /mnt/osfiles || true
        \\    fi
        \\    if [ -n "$LOOP2" ]; then
        \\        sudo losetup -d "$LOOP2" || true
        \\    fi
        \\    if [ -n "$LOOP1" ]; then
        \\        sudo losetup -d "$LOOP1" || true
        \\    fi
        \\    echo "--- Cleanup finished ---"
        \\}
        \\
        \\# Register the cleanup function to run on any script exit.
        \\trap cleanup EXIT
        \\LOOP1=$(sudo losetup -f --show os_image.img)
        \\LOOP2=$(sudo losetup -f --show -o 1048576 --sizelimit 31453184 os_image.img)
        \\sudo mke2fs -t ext2 -L "thad-os" $LOOP2
        // \\sudo mkdosfs -F32 -f 2 $LOOP2
        \\sudo mkdir -p /mnt/osfiles
        \\sudo mount $LOOP2 /mnt/osfiles
        \\sudo grub-install --root-directory=/mnt/osfiles --target=i386-pc --no-floppy --modules="normal part_msdos ext2 multiboot" $LOOP1
        \\sudo chown $(id -u) os_image.img
    });
    install_grub.step.dependOn(&parted_boot.step);

    // Step 4: Copy kernel and boot files into the image (as a bash script)
    const install_dev = b.addSystemCommand(&[_][]const u8{
        "bash", "-c",
        \\set -eux
        \\LOOP1=""
        \\LOOP2=""
        \\
        \\# This function unmounts the partition and detaches the loopback devices.
        \\# It is designed to be safe to run even if some steps failed.
        \\cleanup() {
        \\    echo "--- Running cleanup ---"
        \\    # The '|| true' prevents the script from failing if umount/rmdir fails (e.g., not mounted).
        \\    if [ -d /mnt/osfiles ]; then
        \\        sudo umount /mnt/osfiles || true
        \\    fi
        \\    if [ -n "$LOOP2" ]; then
        \\        sudo losetup -d "$LOOP2" || true
        \\    fi
        \\    if [ -n "$LOOP1" ]; then
        \\        sudo losetup -d "$LOOP1" || true
        \\    fi
        \\    echo "--- Cleanup finished ---"
        \\}
        \\
        \\# Register the cleanup function to run on any script exit.
        \\trap cleanup EXIT
        \\LOOP1=$(sudo losetup -f --show os_image.img)
        \\LOOP2=$(sudo losetup -f --show -o 1048576 --sizelimit 31453184 os_image.img)
        \\sudo mkdir -p /mnt/osfiles
        \\sudo mount $LOOP2 /mnt/osfiles
        \\sudo mkdir -p /mnt/osfiles/boot/grub
        \\sudo mkdir -p /mnt/osfiles/bin
        \\sudo cp zig-out/bin/kernel /mnt/osfiles/boot/
        \\sudo cp zig-out/bin/echo_program /mnt/osfiles/bin/program
        \\echo 'menuentry "My Kernel" { multiboot2 /boot/kernel }' | sudo tee /mnt/osfiles/boot/grub/grub.cfg
        \\sudo chown $(id -u) os_image.img
    });
    install_dev.step.dependOn(&install_grub.step);

    // Step 5: Add a run step to boot the image in QEMU
    const run_cmd = b.addSystemCommand(&[_][]const u8{
        "qemu-system-x86_64",           "-d",
        "cpu_reset,guest_errors,unimp",
        // "cpu_reset,guest_errors,unimp,int",
        "-s",
        //"-no-reboot","-no-shutdown",
        "-drive",                       "file=os_image.img,format=raw",
        "-serial",                      "stdio",
    });
    run_cmd.step.dependOn(&install_dev.step);

    // Top-level build steps
    const image_step = b.step("image", "Create bootable OS disk image");
    image_step.dependOn(&install_dev.step);

    const run_step = b.step("run", "Run the OS image in QEMU");
    run_step.dependOn(&run_cmd.step);
}
