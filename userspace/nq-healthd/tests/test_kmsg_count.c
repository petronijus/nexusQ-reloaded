/* userspace/nq-healthd/tests/test_kmsg_count.c
 *
 * dmesg_err is "matching records currently in the kernel ring", published to
 * MQTT/Home Assistant. Up to device r109 it was a literal whole-ring re-read
 * every 30 s (157 ms of CPU at 350 MHz, most of this daemon's idle cost); from
 * r110 it is incremental: new records are matched once, their seqs remembered,
 * and matches older than the ring's oldest record forgotten. These tests pin the
 * pure half of that — record parsing and the seq bookkeeping — so the number
 * cannot drift from what a recount would say. The /dev/kmsg half (one record per
 * read, EPIPE, SEEK_SET to the oldest record) cannot be faked with a file and is
 * checked on the device instead.
 *
 * The source is #included so these statics are reachable, with main() renamed
 * out of the way. */
#define main healthd_main_unused
#include "nq-healthd.c"
#undef main

#include <stdio.h>

static int fails;
#define CHECK(cond) do { if (!(cond)) { fails++; \
    printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static int parse(const char *rec, unsigned long long *seq, const char **msg)
{
    static char b[512];
    snprintf(b, sizeof b, "%s", rec);
    char *m = NULL;
    int ok = kmsg_parse(b, seq, &m);
    *msg = m;
    return ok;
}

static void test_parse_reads_seq_and_message(void)
{
    unsigned long long seq = 0;
    const char *msg;
    CHECK(parse("6,1234,5678901,-;brcmfmac: something\n", &seq, &msg));
    CHECK(seq == 1234);
    CHECK(strncmp(msg, "brcmfmac:", 9) == 0);
}

/* Continuation (dictionary) lines follow the message and are matched with it,
 * as the whole-ring version did — the count must not change under HA. */
static void test_parse_keeps_continuation_lines(void)
{
    unsigned long long seq;
    const char *msg;
    CHECK(parse("3,7,100,-;first line\n SUBSYSTEM=i2c\n DEVICE=+i2c:1\n", &seq, &msg));
    CHECK(strstr(msg, "SUBSYSTEM=i2c") != NULL);
}

/* A digit or keyword in the header is never part of the match. */
static void test_header_is_not_the_message(void)
{
    unsigned long long seq;
    const char *msg;
    CHECK(parse("4,99,1,-;clean message\n", &seq, &msg));
    CHECK(!line_is_error(msg));
}

/* The five lines that made dmesg_err read 5 on every clean boot (the cottage Q,
 * 2026-09-26): "ramoops" contains "oops", and the command line names ramoops
 * and panic=30. None is an error; a real oops and a real panic still are. */
static void test_ramoops_and_the_cmdline_are_not_errors(void)
{
    CHECK(!line_is_error("Kernel command line: console=ttyS2 ramoops.mem_address=0xbf000000 panic=30"));
    CHECK(!line_is_error("ramoops: using module parameters"));
    CHECK(!line_is_error("printk: legacy console [ramoops-1] enabled"));
    CHECK(!line_is_error("pstore: Registered ramoops as persistent store backend"));
    CHECK(!line_is_error("ramoops: using 0x100000@0xbf000000, ecc: 0"));
    CHECK(line_is_error("Internal error: Oops: 5 [#1] SMP ARM"));
    CHECK(line_is_error("Kernel panic - not syncing: sysrq triggered crash"));
    CHECK(line_is_error("oops: 0000"));
    CHECK(line_is_error("BUG: scheduling while atomic"));
}

static void test_malformed_records_are_rejected(void)
{
    unsigned long long seq;
    const char *msg;
    CHECK(!parse("no header at all\n", &seq, &msg));
    CHECK(!parse("6;message before any comma\n", &seq, &msg));
    CHECK(!parse("6,notanumber,1,-;x\n", &seq, &msg));
    CHECK(!parse("6,,1,-;x\n", &seq, &msg));
}

static void test_trim_drops_only_what_left_the_ring(void)
{
    kerr_reset();
    kerr_push(10); kerr_push(20); kerr_push(30);
    kerr_trim(5);                 /* the oldest record is older than every match */
    CHECK(kerr_n == 3);
    kerr_trim(20);                /* seq 20 is the oldest record: still in the ring */
    CHECK(kerr_n == 2 && kerr_seq[0] == 20 && kerr_seq[1] == 30);
    kerr_trim(31);                /* everything overwritten */
    CHECK(kerr_n == 0);
    kerr_trim(100);               /* trimming an empty list is a no-op */
    CHECK(kerr_n == 0);
}

/* The list grows past its initial capacity without losing order or entries. */
static void test_push_grows(void)
{
    kerr_reset();
    for (unsigned long long s = 1; s <= 1000; s++)
        kerr_push(s);
    CHECK(kerr_n == 1000);
    CHECK(kerr_seq[0] == 1 && kerr_seq[999] == 1000);
    kerr_trim(501);
    CHECK(kerr_n == 500 && kerr_seq[0] == 501);
}

/* The equivalence the change rests on: feeding records one by one and trimming
 * to the ring's oldest seq gives the same count as recounting the ring. */
static void test_incremental_equals_recount(void)
{
    const char *msgs[] = {
        "boot ok", "Kernel panic - not syncing", "i2c timeout on bus 1",
        "wlan0: associated", "thermal crit trip", "all quiet", "oops: 0000",
        "nothing", "rcu_sched stall detected", "done",
    };
    const int N = sizeof msgs / sizeof *msgs;
    kerr_reset();
    for (int ring_start = 0; ring_start < N; ring_start++) {
        /* incremental: every record seen once, then trimmed to ring_start */
        kerr_reset();
        for (int i = 0; i < N; i++)
            if (line_is_error(msgs[i]))
                kerr_push((unsigned long long)i);
        kerr_trim((unsigned long long)ring_start);
        /* recount: only the records still in the ring */
        long long recount = 0;
        for (int i = ring_start; i < N; i++)
            recount += line_is_error(msgs[i]);
        CHECK((long long)kerr_n == recount);
    }
}

int main(void)
{
    test_parse_reads_seq_and_message();
    test_parse_keeps_continuation_lines();
    test_header_is_not_the_message();
    test_malformed_records_are_rejected();
    test_ramoops_and_the_cmdline_are_not_errors();
    test_trim_drops_only_what_left_the_ring();
    test_push_grows();
    test_incremental_equals_recount();
    printf("test_kmsg_count: %s (%d failure%s)\n", fails ? "FAIL" : "ok",
           fails, fails == 1 ? "" : "s");
    return fails != 0;
}
