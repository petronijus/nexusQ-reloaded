/*
 * nq-glibc-compat: the mmap entry point, in assembly on purpose.
 *
 * A glibc mmap@GLIBC_2.4 caller passes fd at [sp] and a 32-bit offset at
 * [sp+4], and owns everything above: [sp+8] onwards are ITS locals. A musl
 * caller passes fd at [sp] and a 64-bit offset at [sp+8]. A C function
 * declared to read both layouts is free to write its stack parameters, and
 * GCC does: with a sibling call it stored the computed offset into [sp+8..15]
 * and jumped to musl's mmap, overwriting a glibc caller's locals
 * (PVRSRVMapDmaBuf then crashed on a corrupted pointer, 2026-10-12). No C
 * flag makes that a guarantee, so this entry only READS the caller's stack:
 * it hands nq_glibc_compat_mmap() the address of the incoming stack words
 * and the return address, in a frame of its own.
 *
 * Copyright (c) 2026 Petr Parkan Janda <petronijus@bastla.com>
 * SPDX-License-Identifier: MIT
 */
	.syntax unified
	.thumb
	.text

	.global	mmap
	.type	mmap, %function
	.thumb_func
mmap:
	push	{r4, lr}		@ incoming stack words now at sp+8
	sub	sp, sp, #8		@ two outgoing stack args; sp stays 8-aligned
	add	r4, sp, #16		@ r4 = &incoming[0] (fd, then the offset words)
	str	r4, [sp]		@ arg 5: const uint32_t *in
	str	lr, [sp, #4]		@ arg 6: the caller's return address
	bl	nq_glibc_compat_mmap	@ (addr, len, prot, flags, in, ra) in r0-r3
	add	sp, sp, #8
	pop	{r4, pc}
	.size	mmap, . - mmap

	.section .note.GNU-stack, "", %progbits
