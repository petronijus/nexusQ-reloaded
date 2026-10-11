/* LD_PRELOAD logger: report who calls mmap()/mmap64() with MAP_SHARED on a
 * non-bridge mapping (offset below 2 GiB), with the caller's object. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/types.h>

static void report(const char *fn, void *ra, size_t len, int prot, int flags, int fd, long long off, void *ret)
{
	Dl_info di;
	if (!(flags & MAP_SHARED) || fd < 0)
		return;
	if (dladdr(ra, &di) && di.dli_fname)
		fprintf(stderr, "mmaplog: %s(len=%zu prot=%d flags=0x%x fd=%d off=%lld) = %p from %s+0x%lx\n", fn, len,
			prot, flags, fd, off, ret, di.dli_fname, (unsigned long)((char *)ra - (char *)di.dli_fbase));
	else
		fprintf(stderr, "mmaplog: %s(len=%zu fd=%d off=%lld) = %p from %p\n", fn, len, fd, off, ret, ra);
}

void *mmap(void *a, size_t len, int prot, int flags, int fd, off_t off)
{
	static void *(*real)(void *, size_t, int, int, int, off_t);
	if (!real)
		real = (void *(*)(void *, size_t, int, int, int, off_t))dlsym(RTLD_NEXT, "mmap");
	void *r = real(a, len, prot, flags, fd, off);
	report("mmap", __builtin_return_address(0), len, prot, flags, fd, (long long)off, r);
	return r;
}

void *mmap64(void *a, size_t len, int prot, int flags, int fd, off64_t off)
{
	static void *(*real)(void *, size_t, int, int, int, off64_t);
	if (!real)
		real = (void *(*)(void *, size_t, int, int, int, off64_t))dlsym(RTLD_NEXT, "mmap64");
	void *r = real(a, len, prot, flags, fd, off);
	report("mmap64", __builtin_return_address(0), len, prot, flags, fd, (long long)off, r);
	return r;
}
