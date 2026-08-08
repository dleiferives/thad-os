# src/arch/x86_64/context_switch.S
.global saveContext
.global loadContext
.global saveFpuState

.section .text

# void saveContext(ThreadContext* ctx)
# ctx is in %rdi
saveContext:
    # Save general purpose registers
    # movq source_reg, destination_memory
    movq %rax, 0(%rdi)
    movq %rbx, 8(%rdi)
    movq %rcx, 16(%rdi)
    movq %rdx, 24(%rdi)
    movq %rsi, 32(%rdi)
    movq %rdi, 40(%rdi)    # Save original rdi (current argument) into the context
    movq %rbp, 48(%rdi)
    movq %rsp, 56(%rdi)
    movq %r8, 64(%rdi)
    movq %r9, 72(%rdi)
    movq %r10, 80(%rdi)
    movq %r11, 88(%rdi)
    movq %r12, 96(%rdi)
    movq %r13, 104(%rdi)
    movq %r14, 112(%rdi)
    movq %r15, 120(%rdi)

    # Save segment registers (16-bit selectors)
    # movw source_seg_reg, dest_ax_reg
    # movw source_ax_reg, dest_memory
    movw %cs, %ax
    movw %ax, 128(%rdi)
    movw %ds, %ax
    movw %ax, 136(%rdi)
    movw %es, %ax
    movw %ax, 144(%rdi)
    movw %fs, %ax
    movw %ax, 152(%rdi)
    movw %gs, %ax
    movw %ax, 160(%rdi)
    movw %ss, %ax
    movw %ax, 168(%rdi)

    # Save RIP (return address from stack)
    # movq source_memory_at_rsp, dest_rax_reg
    # movq source_rax_reg, dest_memory_in_context
    movq (%rsp), %rax       # Get return RIP from top of current stack
    movq %rax, 176(%rdi)

    # Save RFLAGS
    pushfq
    popq %rax
    movq %rax, 184(%rdi)

    # Save FPU state if present
    # movq source_memory_ptr, dest_rax_reg
    #movq 192(%rdi), %rax    # fpu_state pointer from context
    #testq %rax, %rax        # Check if pointer is null
    #jz 1f                   # Skip if null
    fxsave 192(%rdi)           # Save FPU state to address in %rax

1:
    retq

# void loadContext(ThreadContext* ctx) - never returns
# ctx is in %rdi
loadContext:
    # Load FPU state if present
    # movq source_memory_ptr, dest_rax_reg
    #movq 192(%rdi), %rax    # fpu_state pointer from context
    #testq %rax, %rax        # Check if pointer is null
    #jz 1f                   # Skip if null
    fxrstor 192(%rdi)          # Restore FPU state from address in %rax

1:
    # Load segment registers (except CS, SS which are handled by iretq)
    # movw source_memory, dest_ax_reg
    # movw source_ax_reg, dest_seg_reg
    movw 136(%rdi), %ax
    movw %ax, %ds
    movw 144(%rdi), %ax
    movw %ax, %es
    movw 152(%rdi), %ax
    movw %ax, %fs
    movw 160(%rdi), %ax
    movw %ax, %gs

    # Load general purpose registers (except rsp, rip, rflags)
    # movq source_memory, dest_reg
    movq 0(%rdi), %rax
    movq 8(%rdi), %rbx
    movq 16(%rdi), %rcx
    movq 24(%rdi), %rdx
    movq 32(%rdi), %rsi
    # RDI is loaded last, after it's used as base pointer
    movq 48(%rdi), %rbp
    # RSP is loaded separately
    movq 64(%rdi), %r8
    movq 72(%rdi), %r9
    movq 80(%rdi), %r10
    movq 88(%rdi), %r11
    movq 96(%rdi), %r12
    movq 104(%rdi), %r13
    movq 112(%rdi), %r14
    movq 120(%rdi), %r15

    # Set up new stack pointer
    movq 56(%rdi), %rsp     # Load new stack pointer

    # Push values for iretq frame (SS, RSP, RFLAGS, CS, RIP)
    # Values are pushed in reverse order of how iretq pops them.
    # iretq pops: RIP, CS, RFLAGS, RSP, SS (for 64-bit mode, CPL change or inter-privilege)
    # So, push SS, then RSP, then RFLAGS, then CS, then RIP.
    # pushq source_memory_value_from_context
    pushq 168(%rdi)         # SS from context
    pushq 56(%rdi)          # RSP from context (new stack pointer)
    pushq 184(%rdi)         # RFLAGS from context
    pushq 128(%rdi)         # CS from context
    pushq 176(%rdi)         # RIP from context

    # Load rdi last, as it was used as the base pointer for all context accesses
    movq 40(%rdi), %rdi

    # Jump to new thread context
    iretq

# void saveFpuState([512]u8* state)
# The Zig type and its containing Thread are asserted to be 16-byte aligned.
saveFpuState:
    fxsave (%rdi)
    retq

# TODO: Detect and use XSAVE/XRSTOR with a CPUID-derived state size once the
# scheduler supports CPUs and extensions beyond the legacy FXSAVE image.
