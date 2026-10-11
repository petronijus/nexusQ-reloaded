/*
 * Host tests for nq-glibc-compat's portable half: which code is "glibc code"
 * (DT_NEEDED marker), and glibc's fortify semantics (an overflow aborts).
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "nq-glibc-compat.h"

int marked_fn(void);
int plain_fn(void);
void *__memcpy_chk(void *, const void *, size_t, size_t);
char *__strcpy_chk(char *, const char *, size_t);
char *__stpcpy_chk(char *, const char *, size_t);
char *__strcat_chk(char *, const char *, size_t);
int __snprintf_chk(char *, size_t, int, size_t, const char *, ...);
void __longjmp_chk(jmp_buf, int);

static int fails;

static void check(int ok, const char *what)
{
	printf("%-58s %s\n", what, ok ? "ok" : "FAIL");
	fails += !ok;
}

/* Run fn in a child; true when it died of SIGABRT (glibc's __chk_fail). */
static int aborts(void (*fn)(void))
{
	pid_t pid = fork();
	int st;

	if (pid == 0) {
		int devnull = open("/dev/null", O_WRONLY);
		dup2(devnull, 2);
		fn();
		_exit(0);
	}
	waitpid(pid, &st, 0);
	return WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT;
}

static char small[8];
static void cpy_over(void) { __strcpy_chk(small, "12345678", sizeof(small)); }
static void cpy_fit(void) { __strcpy_chk(small, "1234567", sizeof(small)); }
static void stp_over(void) { __stpcpy_chk(small, "123456789", sizeof(small)); }
static void cat_over(void) { strcpy(small, "1234"); __strcat_chk(small, "567", sizeof(small) - 1); }
static void cat_fit(void) { strcpy(small, "1234"); __strcat_chk(small, "567", sizeof(small)); }
static void mem_over(void) { __memcpy_chk(small, "123456789", 9, sizeof(small)); }
static void snp_over(void) { __snprintf_chk(small, 16, 1, sizeof(small), "%s", "x"); }
static void snp_fit(void) { __snprintf_chk(small, sizeof(small), 1, sizeof(small), "%d", 1234567); }

int main(void)
{
	nq_glibc_compat_set_marker("libnqmarker.so");
	check(nq_glibc_compat_is_glibc_code((void *)marked_fn), "code in an object with DT_NEEDED marker is glibc code");
	check(!nq_glibc_compat_is_glibc_code((void *)plain_fn), "code in an object without it is not");
	check(!nq_glibc_compat_is_glibc_code((void *)main), "the executable (no marker) is not");
	check(!nq_glibc_compat_is_glibc_code((void *)1), "an address in no object is not");
	nq_glibc_compat_set_marker("libc.so.6");
	check(nq_glibc_compat_is_glibc_code((void *)plain_fn), "with marker libc.so.6 a glibc-host object is glibc code");

	check(aborts(cpy_over), "__strcpy_chk aborts when the string does not fit");
	check(!aborts(cpy_fit), "__strcpy_chk copies when it fits exactly");
	check(aborts(stp_over), "__stpcpy_chk aborts on overflow");
	check(aborts(cat_over), "__strcat_chk aborts on overflow");
	check(!aborts(cat_fit), "__strcat_chk appends when it fits exactly");
	check(aborts(mem_over), "__memcpy_chk aborts when len > dstlen");
	check(aborts(snp_over), "__snprintf_chk aborts when maxlen > object size");
	check(!aborts(snp_fit), "__snprintf_chk formats within bounds");
	{
		char b[8];
		int n = __snprintf_chk(b, sizeof(b), 1, sizeof(b), "%d", 123456789);
		check(n == 9 && !strcmp(b, "1234567"), "__snprintf_chk truncates and returns the full length");
	}
	{
		jmp_buf env;
		volatile int round = 0;
		if (setjmp(env) == 0) {
			round = 1;
			__longjmp_chk(env, 7);
		}
		check(round == 1, "__longjmp_chk returns to setjmp");
	}

	/* NQ_SGX_SCOPE=process: put back what sgx-env replaced, for the children. */
	setenv("LD_PRELOAD", "/usr/lib/sgx-ddk/ld-linux-armhf.so.3", 1);
	setenv("LD_LIBRARY_PATH", "/usr/lib/sgx-mesa:/usr/lib/sgx-ddk", 1);
	setenv("NQ_SGX_ORIG_LD_LIBRARY_PATH", "/opt/x", 1);
	unsetenv("NQ_SGX_ORIG_LD_PRELOAD");
	setenv("NQ_SGX_SCOPE", "process", 1);
	nq_glibc_compat_scope_env();
	check(!getenv("LD_PRELOAD"), "scope: an LD_PRELOAD that was unset is unset again");
	check(getenv("LD_LIBRARY_PATH") && !strcmp(getenv("LD_LIBRARY_PATH"), "/opt/x"),
	      "scope: LD_LIBRARY_PATH gets its earlier value back");
	check(!getenv("NQ_SGX_SCOPE") && !getenv("NQ_SGX_ORIG_LD_LIBRARY_PATH"),
	      "scope: the marker and the saved values are gone");
	setenv("LD_PRELOAD", "/keep", 1);
	nq_glibc_compat_scope_env();
	check(getenv("LD_PRELOAD") && !strcmp(getenv("LD_PRELOAD"), "/keep"),
	      "scope: without the marker nothing is touched");
	unsetenv("LD_PRELOAD");

	printf("%s (%d failing)\n", fails ? "FAIL" : "PASS", fails);
	return fails != 0;
}
