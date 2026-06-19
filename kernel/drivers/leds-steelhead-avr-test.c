// SPDX-License-Identifier: GPL-2.0
#include <kunit/test.h>
#include <linux/input.h>
#include "steelhead_avr.h"

static void test_encode_set_range_basic(struct kunit *test)
{
	struct avr_rgb leds[2] = { {1,2,3}, {4,5,6} };
	u8 buf[16];
	int n = avr_encode_set_range(buf, sizeof(buf), 0, leds, 2);

	KUNIT_EXPECT_EQ(test, n, 10);         /* reg+start+count+rgb_triples + 2*3 */
	KUNIT_EXPECT_EQ(test, buf[0], AVR_REG_SET_RANGE);
	KUNIT_EXPECT_EQ(test, buf[1], 0);     /* start */
	KUNIT_EXPECT_EQ(test, buf[2], 2);     /* count */
	KUNIT_EXPECT_EQ(test, buf[3], 2);     /* rgb_triples == count */
	KUNIT_EXPECT_EQ(test, buf[4], 1);     /* first R */
	KUNIT_EXPECT_EQ(test, buf[9], 6);     /* last B */
}

static void test_encode_set_range_buf_too_small(struct kunit *test)
{
	struct avr_rgb leds[2] = { {1,2,3}, {4,5,6} };
	u8 buf[4];
	KUNIT_EXPECT_EQ(test, avr_encode_set_range(buf, sizeof(buf), 0, leds, 2), -EINVAL);
}

static void test_decode_key_down_up(struct kunit *test)
{
	u16 code; bool down;
	KUNIT_EXPECT_EQ(test, avr_decode_key(AVR_KEY_DOWN | AVR_KEYCODE_MUTE, &code, &down), 0);
	KUNIT_EXPECT_EQ(test, code, (u16)KEY_MUTE);
	KUNIT_EXPECT_TRUE(test, down);
	KUNIT_EXPECT_EQ(test, avr_decode_key(AVR_KEYCODE_VOL_UP, &code, &down), 0);
	KUNIT_EXPECT_EQ(test, code, (u16)KEY_VOLUMEUP);
	KUNIT_EXPECT_FALSE(test, down);
}

static void test_decode_key_empty_and_reset(struct kunit *test)
{
	u16 code; bool down;
	KUNIT_EXPECT_EQ(test, avr_decode_key(AVR_KEY_EMPTY, &code, &down), -EAGAIN);
	KUNIT_EXPECT_EQ(test, avr_decode_key(AVR_KEY_RESET, &code, &down), -ERESTART);
	KUNIT_EXPECT_EQ(test, avr_decode_key(0x3F, &code, &down), -EINVAL);
}

static struct kunit_case avr_test_cases[] = {
	KUNIT_CASE(test_encode_set_range_basic),
	KUNIT_CASE(test_encode_set_range_buf_too_small),
	KUNIT_CASE(test_decode_key_down_up),
	KUNIT_CASE(test_decode_key_empty_and_reset),
	{}
};
static struct kunit_suite avr_test_suite = {
	.name = "leds-steelhead-avr", .test_cases = avr_test_cases,
};
kunit_test_suite(avr_test_suite);
MODULE_LICENSE("GPL");
