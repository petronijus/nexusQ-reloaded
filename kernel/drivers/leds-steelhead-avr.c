// SPDX-License-Identifier: GPL-2.0
#include <linux/module.h>
#include <linux/input.h>
#include "steelhead_avr.h"

int avr_encode_set_range(u8 *buf, size_t buflen, u8 start,
			 const struct avr_rgb *leds, u8 count)
{
	size_t need = 3 + (size_t)count * 3;
	int i;

	if (!buf || !leds || count == 0 || buflen < need)
		return -EINVAL;
	buf[0] = AVR_REG_SET_RANGE;
	buf[1] = start;
	buf[2] = count;
	for (i = 0; i < count; i++) {
		buf[3 + i*3 + 0] = leds[i].r;
		buf[3 + i*3 + 1] = leds[i].g;
		buf[3 + i*3 + 2] = leds[i].b;
	}
	return (int)need;
}

int avr_decode_key(u8 b, u16 *keycode, bool *down)
{
	u8 code;

	if (b == AVR_KEY_EMPTY)
		return -EAGAIN;
	if (b == AVR_KEY_RESET)
		return -ERESTART;
	*down = !!(b & AVR_KEY_DOWN);
	code = b & AVR_KEY_CODE_MASK;
	switch (code) {
	case AVR_KEYCODE_MUTE:     *keycode = KEY_MUTE;       return 0;
	case AVR_KEYCODE_VOL_UP:   *keycode = KEY_VOLUMEUP;   return 0;
	case AVR_KEYCODE_VOL_DOWN: *keycode = KEY_VOLUMEDOWN; return 0;
	default:                   return -EINVAL;
	}
}

MODULE_LICENSE("GPL");
