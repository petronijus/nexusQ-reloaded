/*
 * nq-glibc-compat: the glibc ABI the TI SGX DDK blobs need, on musl.
 *
 * The PowerVR SGX540 userspace (TI DDK 1.17.4948957, ti443x) is a set of
 * glibc armhf shared objects that must stay byte-for-byte unmodified (TI
 * TSPA). Loaded into a musl process they mostly work: musl maps libc.so.6 and
 * libm.so.6 to itself, ignores symbol versions and remaps the LFS64 names
 * (docs/gpu-sgx540/reverse-engineering.md §3.3). Three gaps remain, and this
 * library closes them without touching a blob:
 *
 * 1. Every blob has DT_NEEDED ld-linux-armhf.so.3, a name musl does not
 *    reserve. This library carries that SONAME, so the blobs find it on the
 *    private library path instead of a loader or gcompat.
 *
 * 2. Nine glibc fortify entry points (__memcpy_chk, __snprintf_chk, ...) are
 *    imported and missing from musl. They are implemented here with glibc's
 *    semantics: an overflow aborts.
 *
 * 3. Two imports have the same name but a different ABI in musl:
 *    - mmap@GLIBC_2.4 takes a 32-bit off_t. musl's mmap takes a 64-bit off_t,
 *      which the ARM EABI passes 8-byte aligned on the stack, so musl reads
 *      the offset from the wrong slot. libsrv_um's PVRSRVMapDmaBuf takes this
 *      path (first light, 2026-10-11).
 *    - strerror_r is GNU in glibc (returns char *) and XSI in musl (int).
 *    musl ignores symbol versions, so a blob's reference binds to whatever
 *    "mmap" comes first in the global scope. With this library preloaded
 *    (LD_PRELOAD), that is the definition below; it decides the ABI per call
 *    from the caller: an object that has DT_NEEDED libc.so.6 is glibc code,
 *    anything else is musl code and gets musl's own function unchanged.
 *
 * Only for 32-bit ARM hard-float EABI: the mmap argument layout below is that
 * ABI's.
 *
 * Copyright (c) 2026 Petr Parkan Janda <petronijus@bastla.com>
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <elf.h>
#include <link.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nq-glibc-compat.h"

#define EXPORT __attribute__((visibility("default")))

/* musl's reserved name for itself; the host tests run on glibc. */
#ifndef NQ_LIBC_SONAME
#define NQ_LIBC_SONAME "libc.so"
#endif

/* ---------------------------------------------------------------------------
 * Caller classification
 * ------------------------------------------------------------------------- */

static const char *glibc_marker = "libc.so.6";

void nq_glibc_compat_set_marker(const char *soname)
{
	glibc_marker = soname;
}

struct classify {
	uintptr_t addr;
	int found;
	int glibc;
};

static int needs_marker(struct dl_phdr_info *info, const ElfW(Dyn) *dyn)
{
	uintptr_t strtab = 0;

	for (const ElfW(Dyn) *d = dyn; d->d_tag != DT_NULL; d++)
		if (d->d_tag == DT_STRTAB)
			strtab = d->d_un.d_ptr;
	if (!strtab)
		return 0;
	/* glibc relocates d_ptr in place, musl leaves the link-time value. */
	if (strtab < info->dlpi_addr)
		strtab += info->dlpi_addr;

	for (const ElfW(Dyn) *d = dyn; d->d_tag != DT_NULL; d++)
		if (d->d_tag == DT_NEEDED &&
		    !strcmp((const char *)strtab + d->d_un.d_val, glibc_marker))
			return 1;
	return 0;
}

static int classify_cb(struct dl_phdr_info *info, size_t size, void *data)
{
	struct classify *c = data;
	const ElfW(Dyn) *dyn = NULL;
	int inside = 0;

	(void)size;
	for (int i = 0; i < info->dlpi_phnum; i++) {
		const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
		uintptr_t start = info->dlpi_addr + ph->p_vaddr;

		if (ph->p_type == PT_LOAD && c->addr >= start && c->addr - start < ph->p_memsz)
			inside = 1;
		else if (ph->p_type == PT_DYNAMIC)
			dyn = (const ElfW(Dyn) *)(info->dlpi_addr + ph->p_vaddr);
	}
	if (!inside)
		return 0;
	c->found = 1;
	c->glibc = dyn && needs_marker(info, dyn);
	return 1;
}

int nq_glibc_compat_is_glibc_code(const void *addr)
{
	struct classify c = { .addr = (uintptr_t)addr };

	dl_iterate_phdr(classify_cb, &c);
	return c.found && c.glibc;
}

/* ---------------------------------------------------------------------------
 * musl's own definitions, for nq-glibc-compat-abi.c. Reached through musl
 * itself, so never ourselves, wherever this library sits in the global scope.
 * ------------------------------------------------------------------------- */

nq_mmap_fn nq_libc_mmap;
nq_strerror_r_fn nq_libc_strerror_r;

static void *libc_sym(const char *name)
{
	/* "libc.so" is a reserved name in musl: it is musl itself, nothing loads. */
	void *h = dlopen(NQ_LIBC_SONAME, RTLD_LAZY | RTLD_NOLOAD);
	void *s = h ? dlsym(h, name) : NULL;

	if (!s) {
		fprintf(stderr, "nq-glibc-compat: cannot find libc's %s\n", name);
		abort();
	}
	return s;
}

/* ---------------------------------------------------------------------------
 * The GPU environment is for one process. sgx-env sets LD_PRELOAD (this
 * library) and LD_LIBRARY_PATH (mesa-sgx, the DDK) for the compositor it
 * starts, with NQ_SGX_SCOPE=process and the values they had before. musl reads
 * both variables once, when the process starts, so putting the old values
 * back here changes nothing for this process -- its later dlopen()s still
 * search the GPU path -- and keeps them from every child: the session, the
 * apps, and whatever those push into the systemd user manager.
 * ------------------------------------------------------------------------- */

static void restore(const char *var, const char *saved)
{
	const char *v = getenv(saved);

	if (v)
		setenv(var, v, 1);
	else
		unsetenv(var);
	unsetenv(saved);
}

void nq_glibc_compat_scope_env(void)
{
	const char *scope = getenv("NQ_SGX_SCOPE");

	if (!scope || strcmp(scope, "process"))
		return;
	restore("LD_PRELOAD", "NQ_SGX_ORIG_LD_PRELOAD");
	restore("LD_LIBRARY_PATH", "NQ_SGX_ORIG_LD_LIBRARY_PATH");
	unsetenv("NQ_SGX_SCOPE");
}

__attribute__((constructor)) static void init(void)
{
	nq_libc_mmap = (nq_mmap_fn)libc_sym("mmap");
	nq_libc_strerror_r = (nq_strerror_r_fn)libc_sym("strerror_r");
	nq_glibc_compat_scope_env();
}

/* ---------------------------------------------------------------------------
 * glibc fortify entry points, with glibc's semantics.
 * ------------------------------------------------------------------------- */

static void __attribute__((noreturn)) chk_fail(void)
{
	static const char msg[] = "*** buffer overflow detected ***: terminated\n";

	(void)!write(2, msg, sizeof(msg) - 1);
	abort();
}

EXPORT void *__memcpy_chk(void *dst, const void *src, size_t len, size_t dstlen)
{
	if (len > dstlen)
		chk_fail();
	return memcpy(dst, src, len);
}

EXPORT char *__strcpy_chk(char *dst, const char *src, size_t dstlen)
{
	if (strlen(src) >= dstlen)
		chk_fail();
	return strcpy(dst, src);
}

EXPORT char *__stpcpy_chk(char *dst, const char *src, size_t dstlen)
{
	if (strlen(src) >= dstlen)
		chk_fail();
	return stpcpy(dst, src);
}

EXPORT char *__strcat_chk(char *dst, const char *src, size_t dstlen)
{
	size_t used = strnlen(dst, dstlen);

	if (used == dstlen || strlen(src) >= dstlen - used)
		chk_fail();
	return strcat(dst, src);
}

EXPORT int __vsnprintf_chk(char *s, size_t maxlen, int flag, size_t slen,
			   const char *fmt, va_list ap)
{
	(void)flag;
	if (maxlen > slen)
		chk_fail();
	return vsnprintf(s, maxlen, fmt, ap);
}

EXPORT int __snprintf_chk(char *s, size_t maxlen, int flag, size_t slen,
			  const char *fmt, ...)
{
	va_list ap;
	int rc;

	va_start(ap, fmt);
	rc = __vsnprintf_chk(s, maxlen, flag, slen, fmt, ap);
	va_end(ap);
	return rc;
}

EXPORT int __printf_chk(int flag, const char *fmt, ...)
{
	va_list ap;
	int rc;

	(void)flag;
	va_start(ap, fmt);
	rc = vprintf(fmt, ap);
	va_end(ap);
	return rc;
}

/*
 * The blobs call musl's _setjmp on their (larger, glibc-sized) jmp_buf, so
 * the matching longjmp is musl's too.
 */
EXPORT void __attribute__((noreturn)) __longjmp_chk(jmp_buf env, int val)
{
	longjmp(env, val);
}
