// src/kernel/elf_loader.zig
const std = @import("std");
const elf = @import("elf.zig");
const mem = @import("mem.zig");
const thread = @import("thread.zig");
const vfs = @import("vfs.zig");
const kernel = @import("kernel.zig");

const log = std.log.scoped(.elf_loader);

pub const ElfLoaderError = error{
    InvalidElf,
    UnsupportedArchitecture,
    LoadError,
    OutOfMemory,
    FileNotFound,
    PermissionDenied,
    AddressSpaceExhausted,
    InvalidSegment,
};

pub const LoadedProgram = struct {
    entry_point: u64,
    thread: *thread.Thread,
    allocator: mem.allocator.AllocatorWrapper,
    mapper: *mem.Mapper,

    pub fn deinit(self: *LoadedProgram) void {
        _ = self.allocator.freeAll();
        self.mapper.deinit();
    }
};

pub fn loadElfProgram(
    path: []const u8,
    args: ?[]const []const u8,
    is_kernel: bool,
    parent_allocator: std.mem.Allocator,
) !*LoadedProgram {
    log.info("Loading ELF program: {s}", .{path});
    const cur_thread = thread.getCurrentThread() orelse {
        log.err("No current thread available", .{});
        return ElfLoaderError.LoadError;
    };

    // REad in the elf file from VFS
    const elf_data = try readElfFile(path, parent_allocator);
    defer parent_allocator.free(elf_data);

    // Parse her
    const elf_file = elf.ElfFile.parse(elf_data) catch |err| {
        log.err("Failed to parse ELF file: {}", .{err});
        return ElfLoaderError.InvalidElf;
    };

    log.info("Parsed elf file",.{});


    // New mapper
    const base_mapper = kernel.state.mem_manager.mapper.?;
    const program_mapper = try base_mapper.createUserAddressSpace(parent_allocator);
    cur_thread.creating_thread = true;
    defer cur_thread.creating_thread = false;
    cur_thread.creating_thread_mapper = program_mapper;
    defer mem.Mapper.loadPML4(cur_thread.mapper.pml4_phys_addr);


    // New memory space
    const program_heap_start = mem.types.MEMORY_LAYOUT.USER_VIRTUAL_HEAP_START;
    const program_heap_size = mem.types.MEMORY_LAYOUT.USER_VIRTUAL_HEAP_INITIAL_END - program_heap_start;
    std.log.err("Program heap size is {} bytes", .{program_heap_size});


    // swith to the new memory space
    std.log.err("Switching to new memory space", .{});
    mem.Mapper.loadPML4(program_mapper.pml4_phys_addr);
    try mem.Mapper.initScratchMap(kernel.state.mem_manager.memory_layout.kernel_offset);
    // try mem.Mapper.initScratchMap(mem.types.MEMORY_LAYOUT.KERNEL_VIRTUAL_START);
    std.log.err("New memory space loaded", .{});

    var program_allocator = try mem.allocator.TrackedAllocator.init(
        program_heap_start,
        10 * 1024 * 1024, // 10 MiB initial heap size
        program_mapper,
        mem.PageFlags{
            .present = true,
            .writable = true,
            .user_accessible = !is_kernel,
            .demand_alloc = true,
        },
        parent_allocator
    );


    const program_alloc_wrapper = try program_allocator.createAllocator();

    try loadProgramSegments(elf_file, program_mapper, elf_data);

    // Create thread
    log.info("Creating program thread...", .{});
    const program_thread = try thread.Thread.create(
        null, // Set later
        // TODO @(dleiferives,e0444f1b-8c3c-453a-b5b4-ee079cccd9d8): setup arg
        // handling later... ~#
        null,
        is_kernel,
        program_mapper,
        parent_allocator,
        false, // Not main thread
        if (is_kernel) .KERNEL else .NORMAL,
        false, // not creating a stack -> should already be mapped
    );

    log.info("Program thread created: TID={}", .{program_thread.tid});
    program_thread.context.rip = elf_file.getEntryPoint();
    log.info("Program entry point set: 0x{X:0>16}", .{program_thread.context.rip});

    // Is user!
    // if (!is_kernel) {
    //     const stack_top = mem.types.MEMORY_LAYOUT.USER_VIRTUAL_STACK_INITIAL_START;
    //     program_thread.context.rsp = stack_top - 16;

    //     program_thread.context.cs = @import("arch").cpu.gdt.SELECTOR.USER_CODE;
    //     program_thread.context.ds = @import("arch").cpu.gdt.SELECTOR.USER_DATA;
    //     program_thread.context.ss = @import("arch").cpu.gdt.SELECTOR.USER_DATA;
    // }

    if (args) |arg_list| {
        try setupProgramArguments(program_thread, arg_list, program_mapper);
    }

    const loaded_program = try parent_allocator.create(LoadedProgram);
    log.info("Loaded program structure created", .{});
    loaded_program.* = LoadedProgram{
        .entry_point = elf_file.getEntryPoint(),
        .thread = program_thread,
        .allocator = program_alloc_wrapper,
        .mapper = program_mapper,
    };
    log.info("Loaded program structure initialized", .{});

    log.info("ELF program loaded successfully: entry=0x{X:0>16}", .{elf_file.getEntryPoint()});
    return loaded_program;
}

fn readElfFile(path: []const u8, allocator: std.mem.Allocator) ElfLoaderError![]u8 {
    const fd = vfs.vfs_open(path, vfs.FileDescriptor.O_RDONLY) catch |err| {
        switch (err) {
            error.NotFound => return ElfLoaderError.FileNotFound,
            error.PermissionDenied => return ElfLoaderError.PermissionDenied,
            else => return ElfLoaderError.LoadError,
        }
    };
    defer vfs.vfs_close(fd) catch {};

    var stat: vfs.VfsStat = undefined;
    vfs.vfs_stat(path, &stat) catch {
        return ElfLoaderError.LoadError;
    };

    const file_data = allocator.alloc(u8, stat.st_size) catch {
        return ElfLoaderError.OutOfMemory;
    };

    // Read file
    const bytes_read = vfs.vfs_read(fd, file_data) catch {
        allocator.free(file_data);
        return ElfLoaderError.LoadError;
    };

    if (bytes_read != stat.st_size) {
        allocator.free(file_data);
        return ElfLoaderError.LoadError;
    }

    return file_data;
}

fn loadProgramSegments(
    elf_file: elf.ElfFile,
    mapper: *mem.Mapper,
    elf_data: []const u8,
) !void {
    log.info("Loading program segments...", .{});

    var phdr_iter = elf_file.getProgramHeaders();
    while (phdr_iter.next()) |phdr| {
        if (!phdr.isLoadable()) continue;

        try loadSegment(phdr, mapper, elf_data);
    }

    log.info("All program segments loaded", .{});
}

/// Load a single ELF segment
fn loadSegment(
    phdr: *const elf.elf.Elf64_Phdr,
    mapper: *mem.Mapper,
    elf_data: []const u8,
) !void {
    const vaddr = phdr.p_vaddr;
    const memsz = phdr.p_memsz;
    const filesz = phdr.p_filesz;
    const offset = phdr.p_offset;

    log.info("Loading segment: vaddr=0x{X:0>16}, memsz={}, filesz={}, offset={}", .{
        vaddr, memsz, filesz, offset
    });

    if (vaddr < mem.types.MEMORY_LAYOUT.VIRTUAL_PROG_START or
        vaddr + memsz > mem.types.MEMORY_LAYOUT.VIRTUAL_PROG_END) {
        log.err("Segment address out of program space: 0x{X:0>16}", .{vaddr});
        return ElfLoaderError.InvalidSegment;
    }

    const flags = mem.PageFlags{
        .present = true,
        .writable = true,
        .user_accessible = true,
        .execute_disable = false,
        .demand_alloc = false,
    };

    const page_aligned_vaddr = vaddr & ~mem.PAGE_MASK_4K;
    const page_aligned_size = ((vaddr + memsz + mem.PAGE_MASK_4K) & ~mem.PAGE_MASK_4K) - page_aligned_vaddr;

    try mapper.mapRange(page_aligned_vaddr, page_aligned_vaddr + page_aligned_size, flags);

    if (filesz > 0) {
        try copySegmentData(vaddr, elf_data[offset..offset + filesz]);
    }

    if (memsz > filesz) {
        try zeroMemory(vaddr + filesz, memsz - filesz);
    }

    log.info("Segment loaded successfully", .{});
}

fn copySegmentData(
    target_vaddr: u64,
    data: []const u8,
) !void {
    log.debug("Copying {} bytes to 0x{X:0>16}", .{ data.len, target_vaddr });

    // try mem.Mapper.initScratchMap(mem.types.MEMORY_LAYOUT.KERNEL_OFFSET);

    const target_ptr: [*]u8 = @ptrFromInt(target_vaddr);
    @memcpy(target_ptr[0..data.len], data);
}

/// Zero memory in target address space
fn zeroMemory(target_vaddr: u64, size: u64) ElfLoaderError!void {
    if (size == 0) return;
    const target_ptr: [*]u8 = @ptrFromInt(target_vaddr);
    @memset(target_ptr[0..size], 0);
}

// TODO @(dleiferives,e9269fc9-5699-409e-91bf-316681d9c922): I need to do this...
// ~#
fn setupProgramArguments(
    program_thread: *thread.Thread,
    args: []const []const u8,
    mapper: *mem.Mapper,
) ElfLoaderError!void {
    // TODO: Implement proper argument setup
    // on the stak
    _ = program_thread;
    _ = args;
    _ = mapper;
    @panic("Program argument setup not yet implemented");
}

pub fn loadAndRunProgram(
    path: []const u8,
    args: ?[]const []const u8,
    is_kernel: bool,
) !void {
    const allocator = kernel.state.getKernelAllocator() orelse return ElfLoaderError.OutOfMemory;

    const loaded_program = try loadElfProgram(path, args, is_kernel, allocator);

    // Add thread to scheduler
    if (kernel.state.scheduler) |sched| {
        try sched.addThread(loaded_program.thread);
        log.info("Program thread added to scheduler: TID={}", .{loaded_program.thread.tid});
    } else {
        log.err("No scheduler available to run program", .{});
        return ElfLoaderError.LoadError;
    }
}
