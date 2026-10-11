/*
 * nq-glibc-compat, the two imports whose ABI differs between glibc and musl:
 * mmap (32-bit off_t in glibc's mmap@GLIBC_2.4) and strerror_r (GNU vs XSI).
 * See nq-glibc-compat.c for the whole picture.
 *
 * This file must not include <sys/mman.h> or <string.h>: it defines mmap64 and
 * strerror_r with prototypes that differ from musl's declarations on purpose.
 * mmap itself is nq-glibc-compat-mmap.S (why: see there).
 *
 * Copyright (c) 2026 Petr Parkan Janda <petronijus@bastla.com>
 * SPDX-License-Identifier: MIT
 */
#include <stdint.h>
#include <stdio.h>

#include "nq-glibc-compat.h"

#if !defined(__arm__) || defined(__aarch64__) || !defined(__ARM_EABI__)
#error "nq-glibc-compat's mmap reads the 32-bit ARM EABI stack layout"
#endif

#define EXPORT __attribute__((visibility("default")))

/* ---------------------------------------------------------------------------
 * mmap / mmap64
 *
 * ARM EABI: both callers pass addr, len, prot, flags in r0-r3 and fd at
 * [sp]. A glibc mmap@GLIBC_2.4 caller passes a 32-bit offset at [sp+4] and
 * nothing more; a musl caller passes a 64-bit offset 8-byte aligned at
 * [sp+8] (lo) and [sp+12] (hi), with [sp+4] as padding. The exported entry
 * point is nq-glibc-compat-mmap.S, which hands over `in` = the caller's sp:
 * in[0] fd, in[1..3] the offset words of either layout. They are only read
 * here; for a glibc caller in[2..3] are its locals.
 * ------------------------------------------------------------------------- */

__attribute__((visibility("hidden")))
void *nq_glibc_compat_mmap(void *addr, size_t len, int prot, int flags,
			   const uint32_t *in, const void *ra)
{
	int64_t off;

	if (nq_glibc_compat_is_glibc_code(ra))
		off = (int64_t)in[1];	/* glibc: 32-bit off_t, taken unsigned as glibc's mmap2 does */
	else
		off = (int64_t)((uint64_t)in[3] << 32 | in[2]);
	return nq_libc_mmap(addr, len, prot, flags, (int)in[0], off);
}

/*
 * mmap64 is the same in glibc and musl (64-bit offset). It must still be
 * defined here: musl resolves an unknown *64 name by retrying without the
 * suffix, which would land a glibc caller's mmap64 on the mmap above.
 */
EXPORT void *mmap64(void *addr, size_t len, int prot, int flags, int fd, int64_t off)
{
	return nq_libc_mmap(addr, len, prot, flags, fd, off);
}

/* ---------------------------------------------------------------------------
 * strerror_r: GNU for glibc callers, XSI (musl's, unchanged) for everyone
 * else. The return register carries a pointer or an int accordingly.
 * ------------------------------------------------------------------------- */

EXPORT intptr_t strerror_r(int errnum, char *buf, size_t buflen)
{
	int rc = nq_libc_strerror_r(errnum, buf, buflen);

	if (!nq_glibc_compat_is_glibc_code(__builtin_return_address(0)))
		return rc;
	/* GNU: always a usable string; buf holds it (truncated if it had to be). */
	if (rc && buflen) {
		snprintf(buf, buflen, "Unknown error %d", errnum);
	}
	return (intptr_t)(buflen ? buf : "");
}

