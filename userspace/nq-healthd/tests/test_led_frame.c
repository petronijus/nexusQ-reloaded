/* userspace/nq-healthd/tests/test_led_frame.c
 *
 * led_sum / led_changed are what tell a live LED ring from a frozen one in
 * health.jsonl. From the C rewrite (r77) to device r120 healthd looked for the
 * frame under a LED name the driver never registers (`steelhead:rgb:ring`; it
 * is `ring-0`..`ring-N`), so every sample read 0 and led_static fired on a
 * breathing ring (found by the full diag, 2026-09-28). Pinned here, against a
 * fixture tree shaped like the unit's sysfs:
 *   - the frame is found through the LED class device (ring-0/device/frame);
 *   - without the class device, by scanning the i2c devices, as the shell did;
 *   - with neither, nothing is found (healthd then reports 0, and says so);
 *   - the fingerprint moves when the frame does and not otherwise.
 *
 * The source is #included so the statics are reachable, with main() renamed
 * out of the way and the sysfs roots pointed at fixtures. */
#define main healthd_main_unused
#define LEDS_ROOT TEST_LEDSROOT
#define I2C_DEVS  TEST_I2CDEVS
#include "nq-healthd.c"
#undef main

#include <stdio.h>

static int fails;
#define CHECK(cond) do { if (!(cond)) { fails++; \
    printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static void sh(const char *c) { if (system(c)) {} }
static void put(const char *p, const char *v) { FILE *f = fopen(p, "w"); if (f) { fputs(v, f); fclose(f); } }

int main(void)
{
    char got[512];
    const char *frame = TEST_I2CDEVS "/1-0020/frame";

    /* The unit's shape: the AVR at i2c 1-0020 carries `frame`; the LED class
     * devices are symlinks whose `device` points back at it. A second i2c
     * device without the attribute sorts first, so the scan must skip it. */
    sh("rm -rf " TEST_LEDSROOT " " TEST_I2CDEVS);
    sh("mkdir -p " TEST_I2CDEVS "/1-0020 " TEST_I2CDEVS "/0-0000 "
       TEST_LEDSROOT "/steelhead:rgb:ring-0 " TEST_LEDSROOT "/steelhead:rgb:mute");
    put(frame, "\x01\x02\x03");
    sh("ln -s " TEST_I2CDEVS "/1-0020 " TEST_LEDSROOT "/steelhead:rgb:ring-0/device");
    sh("ln -s " TEST_I2CDEVS "/1-0020 " TEST_LEDSROOT "/steelhead:rgb:mute/device");

    printf("found through the LED class device\n");
    CHECK(find_frame_attr(got, sizeof got) == 1);
    CHECK(!strcmp(got, TEST_LEDSROOT "/steelhead:rgb:ring-0/device/frame"));

    printf("fingerprint follows the frame\n");
    long long s1, h1, s2, h2, s3, h3;
    led_frame(got, &s1, &h1);
    CHECK(s1 == 6);
    led_frame(got, &s2, &h2);
    CHECK(s2 == s1 && h2 == h1);                 /* unchanged frame: same hash */
    put(frame, "\x03\x02\x01");
    led_frame(got, &s3, &h3);
    CHECK(s3 == s1 && h3 != h1);                 /* same sum, moved pixels: new hash */

    printf("found by scanning the i2c devices without the class device\n");
    sh("rm -rf " TEST_LEDSROOT "/steelhead:rgb:ring-0");
    CHECK(find_frame_attr(got, sizeof got) == 1);
    CHECK(!strcmp(got, frame));

    printf("the name the driver never had is not enough\n");
    sh("mkdir -p " TEST_LEDSROOT "/steelhead:rgb:ring");
    sh("rm -rf " TEST_I2CDEVS);
    CHECK(find_frame_attr(got, sizeof got) == 0);
    CHECK(got[0] == '\0');

    sh("rm -rf " TEST_LEDSROOT " " TEST_I2CDEVS);
    printf(fails ? "test_led_frame: %d FAILED\n" : "test_led_frame: ok\n", fails);
    return fails != 0;
}
