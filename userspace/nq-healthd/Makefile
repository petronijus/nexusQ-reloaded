# nq-healthd — C rewrite of the shell health monitor. Same JSONL schema.
CC      ?= cc
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra
PREFIX  ?= /usr

nq-healthd: nq-healthd.c
	$(CC) $(CFLAGS) -o $@ $<

# The source is #included by the test, with the pstore paths pointed at fixtures
# under /tmp, so the counting logic can be exercised without root or a crash.
TESTDIRS = -DTEST_ARCHIVE='"/tmp/nqh-test-archive"' -DTEST_PSTOREFS='"/tmp/nqh-test-pstorefs"'
# cstate_sample()/qos_limit_us() likewise read a fixture cpuidle tree and QoS file.
CSTDIRS  = -DTEST_CPUROOT='"/tmp/nqh-test-cpu"' -DTEST_QOS='"/tmp/nqh-test-qos"'
test: tests/test_pstore_count.c tests/test_cstate.c nq-healthd.c
	$(CC) $(CFLAGS) -I. $(TESTDIRS) -o /tmp/nqh-test-pstore tests/test_pstore_count.c
	@/tmp/nqh-test-pstore
	$(CC) $(CFLAGS) -I. $(CSTDIRS) -o /tmp/nqh-test-cstate tests/test_cstate.c
	@/tmp/nqh-test-cstate

install: nq-healthd
	install -Dm755 nq-healthd $(DESTDIR)$(PREFIX)/bin/nq-healthd

clean:
	rm -f nq-healthd

.PHONY: install clean test
