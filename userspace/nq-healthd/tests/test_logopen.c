/* userspace/nq-healthd/tests/test_logopen.c
 *
 * open_jsonl(): a power cut mid-write leaves a log's tail as NULs with no
 * newline (health.jsonl on 2026-10-14), and the next boot's first record must
 * still start a line of its own. Pinned here: a torn tail is sealed with one
 * newline, an intact log and an empty or new file get nothing extra, and
 * reopening a sealed log does not add blank lines.
 *
 * The source is #included so the static is reachable, with main() renamed
 * out of the way. */
#define main healthd_main_unused
#include "nq-healthd.c"
#undef main

#include <stdio.h>

static int fails;
#define CHECK(cond) do { if (!(cond)) { fails++; \
    printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

#define LOG "/tmp/nqh-test-logopen.jsonl"

static void put(const char *data, size_t n) { FILE *f = fopen(LOG, "wb"); if (f) { fwrite(data, 1, n, f); fclose(f); } }
static size_t read_log(char *buf, size_t cap) {
    FILE *f = fopen(LOG, "rb"); if (!f) return 0;
    size_t n = fread(buf, 1, cap, f); fclose(f); return n;
}
static void append(const char *rec) { FILE *f = open_jsonl(LOG); if (f) { fputs(rec, f); fclose(f); } }

static void test_torn_tail_is_sealed(void) {
    const char torn[] = "{\"t_mono\":1}\n\0\0\0\0";   /* the last write lost to the cut */
    put(torn, sizeof torn - 1);
    append("{\"t_mono\":27}\n");
    char b[256]; size_t n = read_log(b, sizeof b);
    const char want[] = "{\"t_mono\":1}\n\0\0\0\0\n{\"t_mono\":27}\n";
    CHECK(n == sizeof want - 1 && memcmp(b, want, n) == 0);
}
static void test_half_record_is_sealed(void) {
    put("{\"t_mono\":1}\n{\"t_mo", 19);
    append("{\"t_mono\":27}\n");
    char b[256]; size_t n = read_log(b, sizeof b); b[n] = 0;
    CHECK(strcmp(b, "{\"t_mono\":1}\n{\"t_mo\n{\"t_mono\":27}\n") == 0);
}
static void test_intact_log_untouched(void) {
    put("{\"t_mono\":1}\n", 13);
    append("{\"t_mono\":2}\n");
    append("{\"t_mono\":3}\n");
    char b[256]; size_t n = read_log(b, sizeof b); b[n] = 0;
    CHECK(strcmp(b, "{\"t_mono\":1}\n{\"t_mono\":2}\n{\"t_mono\":3}\n") == 0);
}
static void test_empty_and_new_file(void) {
    put("", 0);
    append("{\"t_mono\":1}\n");
    char b[256]; size_t n = read_log(b, sizeof b); b[n] = 0;
    CHECK(strcmp(b, "{\"t_mono\":1}\n") == 0);
    remove(LOG);
    append("{\"t_mono\":1}\n");
    n = read_log(b, sizeof b); b[n] = 0;
    CHECK(strcmp(b, "{\"t_mono\":1}\n") == 0);
}

int main(void)
{
    test_torn_tail_is_sealed();
    test_half_record_is_sealed();
    test_intact_log_untouched();
    test_empty_and_new_file();
    remove(LOG);
    if (fails) { printf("test_logopen: %d FAILED\n", fails); return 1; }
    printf("test_logopen: OK\n");
    return 0;
}
