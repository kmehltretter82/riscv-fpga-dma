/* SPDX-License-Identifier: GPL-2.0-only */
	.section .text.start, "ax", @progbits
	.globl _start
	.type _start, @function
_start:
	.option push
	.option norelax
	la	gp, __global_pointer$
	.option pop
	andi	sp, sp, -16
	li	s0, 0
	call	mininit_main
	mv	a0, a0
	li	a7, 93
	ecall
1:
	j	1b
	.size _start, .-_start

	.section .note.GNU-stack, "", @progbits
