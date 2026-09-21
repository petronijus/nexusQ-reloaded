/* userspace/nq-healthd/tests/test_pstore_count.c
 *
 * pstore_count() decides whether the daemon can ever report a crash. It read
 * /sys/fs/pstore, which systemd-pstore.service drains and unlinks at boot, so
 * the field sat at 0 forever, the pstore_new crit event was unreachable, and the
 * 0 was republished to MQTT/Home Assistant as if it meant "no crash". Two
 * sessions read that empty directory as proof ramoops never captured anything.
 *
 * The source is #included so these statics are reachable, with main() renamed
 * out of the way and both paths pointed at fixtures. */
#define main healthd_main_unused
#define PSTORE    TEST_ARCHIVE
#define PSTORE_FS TEST_PSTOREFS
#include "nq-healthd.c"
#undef main

#include <stdio.h>
#include <sys/stat.h>

static int fails;
#define CHECK(cond) do { if (!(cond)) { fails++; \
    printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static void mk(const char *p) { mkdir(p, 0755); }
static void touch(const char *p) { FILE *f = fopen(p, "w"); if (f) { fputs("x", f); fclose(f); } }
static void rmrf(const char *p) { char c[512]; snprintf(c, sizeof c, "rm -rf '%s'", p); if (system(c)) {} }

/* A real archive as this device writes it: records flat in the directory. */
static void test_flat_archive_is_counted(void) {
    rmrf(TEST_ARCHIVE); mk(TEST_ARCHIVE);
    touch(TEST_ARCHIVE "/console-ramoops-0");
    touch(TEST_ARCHIVE "/dmesg-ramoops-0");
    CHECK(pstore_count() == 2);
}

/* systemd nests records under a per-boot directory in other versions; the same
 * daemon binary must count those too, or it silently reports 0 on such a box. */
static void test_nested_archive_is_counted(void) {
    rmrf(TEST_ARCHIVE); mk(TEST_ARCHIVE);
    mk(TEST_ARCHIVE "/8f1c2d");
    touch(TEST_ARCHIVE "/8f1c2d/dmesg-ramoops-0");
    touch(TEST_ARCHIVE "/8f1c2d/console-ramoops-0");
    mk(TEST_ARCHIVE "/9a2b3c");
    touch(TEST_ARCHIVE "/9a2b3c/dmesg-ramoops-0");
    CHECK(pstore_count() == 3);
}

static void test_an_empty_archive_is_zero_not_a_fallback(void) {
    rmrf(TEST_ARCHIVE); mk(TEST_ARCHIVE);
    rmrf(TEST_PSTOREFS); mk(TEST_PSTOREFS);
    touch(TEST_PSTOREFS "/dmesg-ramoops-0");   /* must NOT be counted: archive exists */
    CHECK(pstore_count() == 0);
}

/* systemd-pstore disabled or not yet run: whatever the kernel recovered is still
 * in pstorefs, and that is the only case where reading it is correct. */
static void test_no_archive_falls_back_to_pstorefs(void) {
    rmrf(TEST_ARCHIVE);
    rmrf(TEST_PSTOREFS); mk(TEST_PSTOREFS);
    touch(TEST_PSTOREFS "/dmesg-ramoops-0");
    CHECK(pstore_count() == 1);
}

static void test_neither_present_is_zero(void) {
    rmrf(TEST_ARCHIVE); rmrf(TEST_PSTOREFS);
    CHECK(pstore_count() == 0);
}

/* Dotfiles are not crash dumps. */
static void test_dotfiles_are_ignored(void) {
    rmrf(TEST_ARCHIVE); mk(TEST_ARCHIVE);
    touch(TEST_ARCHIVE "/.hidden");
    touch(TEST_ARCHIVE "/dmesg-ramoops-0");
    CHECK(pstore_count() == 1);
}

int main(void) {
    test_flat_archive_is_counted();
    test_nested_archive_is_counted();
    test_an_empty_archive_is_zero_not_a_fallback();
    test_no_archive_falls_back_to_pstorefs();
    test_neither_present_is_zero();
    test_dotfiles_are_ignored();
    rmrf(TEST_ARCHIVE); rmrf(TEST_PSTOREFS);
    printf(fails ? "FAILED (%d)\n" : "OK\n", fails);
    return fails ? 1 : 0;
}
