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
ACCTDIRS = -DTEST_PROCSTAT='"/tmp/nqh-test-procstat"' -DTEST_CGROOT='"/tmp/nqh-test-cg"' \
           -DTEST_CTLSTATS='"/tmp/nqh-test-ctlstats"' -DTEST_NQSOCK='"/tmp/nqh-test-nq.sock"'
MEMDIRS  = -DTEST_CGROOT='"/tmp/nqh-test-memcg"' -DTEST_MEMINFO='"/tmp/nqh-test-meminfo"'
GPUDIRS  = -DTEST_GPUROOT='"/tmp/nqh-test-gpu"' -DGPU_PM='"/tmp/nqh-test-gpu/power"' \
           -DGPU_MOD='"/tmp/nqh-test-gpu/module"' -DHDMI_CONN='"/tmp/nqh-test-gpu/hdmi"' \
           -DGPU_DEVFREQ='"/tmp/nqh-test-gpu/devfreq"'
LEDDIRS  = -DTEST_LEDSROOT='"/tmp/nqh-test-leds"' -DTEST_I2CDEVS='"/tmp/nqh-test-i2c"'
test: tests/test_pstore_count.c tests/test_cstate.c tests/test_kmsg_count.c tests/test_accounting.c tests/test_memory.c tests/test_led_frame.c tests/test_judgements.c tests/test_gpu.c tests/test_logopen.c nq-healthd.c
	$(CC) $(CFLAGS) -I. $(TESTDIRS) -o /tmp/nqh-test-pstore tests/test_pstore_count.c
	@/tmp/nqh-test-pstore
	$(CC) $(CFLAGS) -I. $(CSTDIRS) -o /tmp/nqh-test-cstate tests/test_cstate.c
	@/tmp/nqh-test-cstate
	# kmsg_parse()/kerr_*(): the incremental dmesg_err count (no fixtures needed).
	$(CC) $(CFLAGS) -I. -o /tmp/nqh-test-kmsg tests/test_kmsg_count.c
	@/tmp/nqh-test-kmsg
	# cpu_sample()/unit_sample()/nexusqd_counters()/control_stats(): the r119
	# CPU accounting, against a fixture /proc/stat, cgroup tree and fake nexusqd.
	$(CC) $(CFLAGS) -I. $(ACCTDIRS) -o /tmp/nqh-test-acct tests/test_accounting.c
	@/tmp/nqh-test-acct
	# meminfo_sample()/cg_anon_kB()/mem_units()/mem_line(): mem.jsonl, who holds
	# the memory, against a fixture meminfo and cgroup tree (device r125).
	$(CC) $(CFLAGS) -I. $(MEMDIRS) -o /tmp/nqh-test-mem tests/test_memory.c
	@/tmp/nqh-test-mem
	# find_frame_attr()/led_frame(): the LED ring fingerprint, against a fixture
	# sysfs shaped like the unit's (the frame on the AVR's i2c device).
	$(CC) $(CFLAGS) -I. $(LEDDIRS) -o /tmp/nqh-test-led tests/test_led_frame.c
	@/tmp/nqh-test-led
	# vdd_raw_mismatch()/vdd_confirmed()/led_judge(): what healthd reports, once
	# per stretch rather than every sample (no fixtures needed).
	$(CC) $(CFLAGS) -I. -o /tmp/nqh-test-judge tests/test_judgements.c
	@/tmp/nqh-test-judge
	# gpu_sample(): the SGX540's runtime-PM state and awake time per interval,
	# and whether HDMI shows anything (device r129), against a fixture sysfs.
	$(CC) $(CFLAGS) -I. $(GPUDIRS) -o /tmp/nqh-test-gpu-bin tests/test_gpu.c
	@/tmp/nqh-test-gpu-bin
	# open_jsonl(): a log tail torn by a power cut is sealed before appending.
	$(CC) $(CFLAGS) -I. -o /tmp/nqh-test-logopen tests/test_logopen.c
	@/tmp/nqh-test-logopen

install: nq-healthd
	install -Dm755 nq-healthd $(DESTDIR)$(PREFIX)/bin/nq-healthd

clean:
	rm -f nq-healthd

.PHONY: install clean test
