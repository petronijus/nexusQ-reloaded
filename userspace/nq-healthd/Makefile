# nq-healthd — C rewrite of the shell health monitor. Same JSONL schema.
CC      ?= cc
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra
PREFIX  ?= /usr

nq-healthd: nq-healthd.c
	$(CC) $(CFLAGS) -o $@ $<

# The source is #included by the test, with the pstore paths pointed at fixtures
# under /tmp, so the counting logic can be exercised without root or a crash.
TESTDIRS = -DTEST_ARCHIVE='"/tmp/nqh-test-archive"' -DTEST_PSTOREFS='"/tmp/nqh-test-pstorefs"'
test: tests/test_pstore_count.c nq-healthd.c
	$(CC) $(CFLAGS) -I. $(TESTDIRS) -o /tmp/nqh-test-pstore $<
	@/tmp/nqh-test-pstore

install: nq-healthd
	install -Dm755 nq-healthd $(DESTDIR)$(PREFIX)/bin/nq-healthd

clean:
	rm -f nq-healthd

.PHONY: install clean test
