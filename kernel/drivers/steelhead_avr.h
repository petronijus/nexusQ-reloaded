/* SPDX-License-Identifier: GPL-2.0 */
/* Google Nexus Q (steelhead) front-panel AVR: 32 RGB ring LEDs + mute LED
 * + capacitive mute/volume keys, over i2c. Register protocol from AOSP. */
#ifndef _LEDS_STEELHEAD_AVR_H
#define _LEDS_STEELHEAD_AVR_H

#include <linux/types.h>

#define AVR_REG_KEY_FIFO	0x00
#define AVR_REG_MUTE_THRESH	0x01
#define AVR_REG_LED_MODE	0x02
#define   AVR_LED_MODE_BOOT_ANIM	0x00
#define   AVR_LED_MODE_HOST_AUTO	0x01
#define   AVR_LED_MODE_HOST		0x02
#define   AVR_LED_MODE_POWERUP_ANIM	0x03
#define AVR_REG_SET_ALL		0x03
#define AVR_REG_SET_RANGE	0x04
#define AVR_REG_COMMIT		0x05
#define   AVR_COMMIT_IMMEDIATE	0x00
#define   AVR_COMMIT_INTERPOLATE 0x01
#define AVR_REG_SET_MUTE	0x06
#define AVR_REG_GET_COUNT	0x07
#define AVR_REG_HW_TYPE		0x08
#define AVR_REG_HW_REV		0x09
#define AVR_REG_FW_VER		0x0A

#define AVR_KEY_DOWN		0x80
#define AVR_KEY_CODE_MASK	0x3F
#define AVR_KEY_RESET		0xFE
#define AVR_KEY_EMPTY		0xFF
#define AVR_KEYCODE_MUTE	0x00
#define AVR_KEYCODE_VOL_UP	0x01
#define AVR_KEYCODE_VOL_DOWN	0x02

#define AVR_RING_LEDS		32
#define AVR_I2C_RETRIES		5

struct avr_rgb { u8 r, g, b; };

/* Encode a SET_RANGE write into buf: [reg, start, count, r,g,b ...].
 * Returns total bytes written, or -EINVAL on bad args / buffer too small. */
int avr_encode_set_range(u8 *buf, size_t buflen, u8 start,
			 const struct avr_rgb *leds, u8 count);

/* Decode one KEY_FIFO byte. Returns 0 + fills keycode/down for a real key;
 * -EAGAIN for EMPTY (0xFF); -ERESTART for RESET (0xFE); -EINVAL for unknown. */
int avr_decode_key(u8 fifo_byte, u16 *keycode, bool *down);

#endif /* _LEDS_STEELHEAD_AVR_H */
