/*
 * nq-glibc-compat internals shared by its two translation units and its tests.
 *
 * Copyright (c) 2026 Petr Parkan Janda <petronijus@bastla.com>
 * SPDX-License-Identifier: MIT
 */
#ifndef NQ_GLIBC_COMPAT_H
#define NQ_GLIBC_COMPAT_H

#include <stddef.h>
#include <stdint.h>

typedef void *(*nq_mmap_fn)(void *, size_t, int, int, int, int64_t);
typedef int (*nq_strerror_r_fn)(int, char *, size_t);

/* musl's own mmap and strerror_r. */
extern nq_mmap_fn nq_libc_mmap;
extern nq_strerror_r_fn nq_libc_strerror_r;

/* Non-zero when addr lies in an object linked against glibc (DT_NEEDED marker). */
int nq_glibc_compat_is_glibc_code(const void *addr);

/* Put back the environment sgx-env replaced for this process (NQ_SGX_SCOPE). */
void nq_glibc_compat_scope_env(void);

/* Tests only: the DT_NEEDED name that marks glibc code (default "libc.so.6"). */
void nq_glibc_compat_set_marker(const char *soname);

#endif
