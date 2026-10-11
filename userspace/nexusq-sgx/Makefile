# nexusq-sgx: the open glue the TI SGX DDK blobs need on musl.
#   ld-linux-armhf.so.3   nq-glibc-compat (SONAME ld-linux-armhf.so.3), armhf only
#   pvrsrvinit            starts the SGX services once per module load
CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
PREFIX  ?= /usr
SGXDIR  ?= $(PREFIX)/lib/sgx-ddk

# No fortify: this library implements glibc's fortify entry points itself.
COMPAT_CFLAGS = $(CFLAGS) -std=gnu11 -fPIC -fvisibility=hidden -fno-builtin -U_FORTIFY_SOURCE

all: ld-linux-armhf.so.3 pvrsrvinit

ld-linux-armhf.so.3: nq-glibc-compat.c nq-glibc-compat-abi.c nq-glibc-compat-mmap.S nq-glibc-compat.h
	$(CC) $(COMPAT_CFLAGS) -shared -Wl,-soname,ld-linux-armhf.so.3 -Wl,-z,defs \
		-o $@ nq-glibc-compat.c nq-glibc-compat-abi.c nq-glibc-compat-mmap.S $(LDFLAGS)

pvrsrvinit: pvrsrvinit.c
	$(CC) $(CFLAGS) -std=c11 -o $@ $< $(LDFLAGS)

install: all
	install -Dm755 ld-linux-armhf.so.3 $(DESTDIR)$(SGXDIR)/ld-linux-armhf.so.3
	install -Dm755 pvrsrvinit $(DESTDIR)$(PREFIX)/libexec/sgx-ddk/pvrsrvinit

# Host tests: the portable half (caller classification, fortify functions).
# The ARM-EABI mmap/strerror_r half is tested on the unit (tests/README).
T = /tmp/nq-glibc-compat-test
test: tests/test_compat.c tests/marked.c tests/plain.c nq-glibc-compat.c nq-glibc-compat.h
	@mkdir -p $(T)
	$(CC) -shared -fPIC -Wl,-soname,libnqmarker.so -o $(T)/libnqmarker.so tests/plain.c
	$(CC) -shared -fPIC -o $(T)/libmarked.so tests/marked.c -L$(T) -Wl,--no-as-needed -lnqmarker -Wl,-rpath,$(T)
	$(CC) -shared -fPIC -o $(T)/libplain.so tests/plain.c
	$(CC) $(COMPAT_CFLAGS) -DNQ_LIBC_SONAME='"libc.so.6"' -I. -o $(T)/test_compat \
		tests/test_compat.c nq-glibc-compat.c -L$(T) -Wl,--no-as-needed -lmarked -lplain -ldl \
		-Wl,-rpath,$(T)
	@$(T)/test_compat

clean:
	rm -f ld-linux-armhf.so.3 pvrsrvinit

.PHONY: all install test clean
