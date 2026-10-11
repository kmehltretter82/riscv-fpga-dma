.section .text.start
.global _start
.align 4
_start:
    la sp, __stack_top
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la t0, trap_handler
    csrw mtvec, t0
    call main

write_result:
    li t0, 0x4000fff8
    li t1, 0x524e444d00000000
    slli a0, a0, 32
    srli a0, a0, 32
    or t1, t1, a0
    sd t1, 0(t0)
1:  wfi
    j 1b

.align 4
trap_handler:
    csrr a0, mcause
    andi a0, a0, 0xff
    addi a0, a0, 0x100
    j write_result

