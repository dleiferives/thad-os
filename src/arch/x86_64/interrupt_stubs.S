section .text

; Macro to create interrupt stub with error code
; num is the first argument
%macro ISR_ERROR_CODE 1
    global isr_ %+ %1
    ; type isr_%1, @function ; NASM usually infers this
isr_ %+ %1:
    ; Error code already pushed by CPU
    push %1                     ; Push interrupt number
    jmp interrupt_common
%endmacro

; Macro to create interrupt stub without error code
; num is the first argument
%macro ISR_NO_ERROR_CODE 1
    global isr_ %+ %1
    ; type isr_%1, @function ; NASM usually infers this
isr_ %+ %1:
    push 0                      ; Push dummy error code
    push %1                     ; Push interrupt number
    jmp interrupt_common
%endmacro

; Declare dispatch as an external function
extern dispatch

; Generate all 256 interrupt stubs
ISR_NO_ERROR_CODE 0     ; Divide Error
ISR_NO_ERROR_CODE 1     ; Debug
ISR_NO_ERROR_CODE 2     ; NMI
ISR_NO_ERROR_CODE 3     ; Breakpoint
ISR_NO_ERROR_CODE 4     ; Overflow
ISR_NO_ERROR_CODE 5     ; Bound Range
ISR_NO_ERROR_CODE 6     ; Invalid Opcode
ISR_NO_ERROR_CODE 7     ; Device Not Available
ISR_ERROR_CODE    8     ; Double Fault
ISR_NO_ERROR_CODE 9     ; Reserved
ISR_ERROR_CODE    10    ; Invalid TSS
ISR_ERROR_CODE    11    ; Segment Not Present
ISR_ERROR_CODE    12    ; Stack Segment Fault
ISR_ERROR_CODE    13    ; General Protection
ISR_ERROR_CODE    14    ; Page Fault
ISR_NO_ERROR_CODE 15    ; Reserved
ISR_NO_ERROR_CODE 16    ; x87 FPU Error
ISR_ERROR_CODE    17    ; Alignment Check
ISR_NO_ERROR_CODE 18    ; Machine Check
ISR_NO_ERROR_CODE 19    ; SIMD FPU Error
ISR_NO_ERROR_CODE 20    ; Virtualization
ISR_ERROR_CODE    21    ; Control Protection

; Generate remaining stubs (22-255)
%assign i 22
%rep 234
    ISR_NO_ERROR_CODE i
    %assign i i + 1
%endrep

; Common interrupt handler
interrupt_common:
    ; Save all registers
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push rsp ; Saves the stack pointer value before pushing r8-r15
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    ; Call Zig dispatcher
    mov rdi, rsp      ; Pass interrupt frame (pointer to saved registers) as first argument
    call dispatch

    ; Restore all registers
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsp ; Restores rsp to its value before r8-r15 were pushed
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax

    ; Remove error code and interrupt number from the stack (2 * 8 bytes)
    add rsp, 16

    ; Return from interrupt
    iretq

; Create stub address table
section .rodata
global interrupt_stubs
; type interrupt_stubs, @object ; NASM infers this
interrupt_stubs:
%assign i 0
%rep 256
    dq isr_ %+ i ; Define a 64-bit pointer to the ISR handler
    %assign i i + 1
%endrep
