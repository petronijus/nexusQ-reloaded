# Nexus Q LED Ring — Kernel Driver Implementation Plan (Plan 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A modern mainline-6.12 i2c driver `leds-steelhead-avr` that binds the
existing `google,steelhead-avr` DT node and exposes the 32-LED ring + mute LED
(multicolor LED class + a batch "frame" sysfs channel) and the mute/volume keys
(input device), with AVR-reset state restore.

**Architecture:** A `devm_`-based i2c client driver. Pure protocol logic (frame
encoding, FIFO key decode) is factored into host-testable functions covered by
KUnit. Hardware-touching paths (i2c/gpio/irq) and the sysfs/LED/input surfaces are
verified on-device. Built as a loadable module so iteration is `scp` + `modprobe`
with no kernel reflash.

**Tech Stack:** C (Linux kernel), KUnit, i2c, leds-class-multicolor, input, gpiod,
threaded IRQ. Cross-build via the repo's Docker pipeline (Arm GNU Toolchain
13.3.Rel1). Device: postmarketOS on Linux 6.12.12, AVR at i2c-1 0x20.

## Global Constraints

- Toolchain: **Arm GNU Toolchain 13.3.Rel1 only** (prefix `arm-none-linux-gnueabihf-`); Ubuntu/other GCC produce non-booting kernels.
- Kernel image ceiling **≤ 6.5 MB** — driver and its deps build as **modules** (`=m`), never `=y`.
- Never set `CONFIG_SMP=y`; keep `CONFIG_ARM_ATAG_DTB_COMPAT=y`, `CONFIG_CMDLINE_FORCE=y` (boot depends on these).
- DT node is fixed: `compatible = "google,steelhead-avr"`, `reg = <0x20>` on i2c-1, `reset-gpios = <&gpio2 16 GPIO_ACTIVE_LOW>`, INT `interrupts = <17 IRQ_TYPE_EDGE_FALLING>` on `&gpio2`.
- AVR register map (verbatim): `0x00` KEY_EVENT_FIFO, `0x01` MUTE_THRESHOLD, `0x02` LED_MODE (0x02=HOST), `0x03` SET_ALL, `0x04` SET_RANGE, `0x05` COMMIT (0x00 immediate / 0x01 interpolate), `0x06` SET_MUTE, `0x07` GET_COUNT, `0x08` HW_TYPE, `0x09` HW_REV, `0x0A` FW_VER. Key event byte: bit7 (0x80)=DOWN, bits0-5 (0x3F)=code; 0xFE=RESET, 0xFF=EMPTY. Keycodes: 0x00=MUTE, 0x01=VOLUME_UP, 0x02=VOLUME_DOWN.
- LED indexing matches the original: ring has **32** LEDs; the mute LED is separate (original CLI used index 0 = mute, 1.. = ring). SET_RANGE payload: `start, count, R,G,B,R,G,B,…`.
- i2c is flaky: **retry up to 5 times** on transfer error (original used MAX_I2C_ATTEMPTS=5).
- Device access for on-device tests: `root@192.168.20.179` (key installed; fallback password documented in HANDOFF). i2c device currently has **no driver bound** — unbind nothing; the module will bind on load.

## File Structure

- `kernel/drivers/leds-steelhead-avr.c` — the driver (repo-tracked source of truth).
- `kernel/drivers/steelhead_avr.h` — register/constant definitions + pure-logic prototypes.
- `kernel/drivers/leds-steelhead-avr-test.c` — KUnit tests for the pure logic.
- `kernel/patches/0005-leds-add-steelhead-avr.patch` — installs the above into the linux tree + Kconfig/Makefile hunks (generated in the final task).
- `kernel/configs/steelhead_defconfig` — add `CONFIG_LEDS_STEELHEAD_AVR=m`, `CONFIG_LEDS_CLASS_MULTICOLOR=m` (and `CONFIG_INPUT_EVDEV=m`, already present). NOTE: `CONFIG_LEDS_STEELHEAD_AVR_KUNIT_TEST` / `CONFIG_KUNIT` are deliberately NOT enabled in the device defconfig — KUnit runs host-only (UML via `kunit.py`), so the test object is not built into the device kernel.
- `scripts/build-led-module.sh` — helper to build just the `.ko` in the extracted kernel tree and print its path.

Development model: write/iterate the source under `kernel/drivers/`. For build, the
source is copied into `drivers/leds/` of the linux tree (the build script does this);
KUnit runs on host (UML/`kunit.py`) against the pure logic; the on-device gate loads
the cross-built `.ko`.

---

### Task 1: Header with register map + pure-logic prototypes

**Files:**
- Create: `kernel/drivers/steelhead_avr.h`

**Interfaces:**
- Produces: `enum`/`#define` register constants (names below); structs
  `struct avr_rgb { u8 r, g, b; }`; prototypes
  `int avr_encode_set_range(u8 *buf, size_t buflen, u8 start, const struct avr_rgb *leds, u8 count);`
  (returns bytes written, or -EINVAL), and
  `int avr_decode_key(u8 fifo_byte, u16 *keycode, bool *down);`
  (returns 0 and sets `*keycode`/`*down`, or -EAGAIN for EMPTY, or -ERESTART for RESET, or -EINVAL for unknown code).

- [ ] **Step 1: Write the header**

```c
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
```

- [ ] **Step 2: Commit**

```bash
git add kernel/drivers/steelhead_avr.h
git commit -m "leds-steelhead-avr: add register map + pure-logic header"
```

---

### Task 2: Pure-logic functions + KUnit tests (host TDD)

**Files:**
- Create: `kernel/drivers/leds-steelhead-avr-test.c`
- Create (logic portion): `kernel/drivers/leds-steelhead-avr.c` (only the two pure functions for now)

**Interfaces:**
- Consumes: constants + prototypes from `steelhead_avr.h`.
- Produces: working `avr_encode_set_range` and `avr_decode_key` (signatures as in Task 1) used by all later tasks.

- [ ] **Step 1: Write the failing KUnit tests**

```c
// SPDX-License-Identifier: GPL-2.0
#include <kunit/test.h>
#include "steelhead_avr.h"

static void test_encode_set_range_basic(struct kunit *test)
{
	struct avr_rgb leds[2] = { {1,2,3}, {4,5,6} };
	u8 buf[16];
	int n = avr_encode_set_range(buf, sizeof(buf), 0, leds, 2);

	KUNIT_EXPECT_EQ(test, n, 9);          /* reg+start+count + 2*3 */
	KUNIT_EXPECT_EQ(test, buf[0], AVR_REG_SET_RANGE);
	KUNIT_EXPECT_EQ(test, buf[1], 0);     /* start */
	KUNIT_EXPECT_EQ(test, buf[2], 2);     /* count */
	KUNIT_EXPECT_EQ(test, buf[3], 1);
	KUNIT_EXPECT_EQ(test, buf[8], 6);
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
```

- [ ] **Step 2: Run tests to verify they fail (link error: functions undefined)**

Run (in an extracted linux-6.12 tree with the files copied to `drivers/leds/`):
`./tools/testing/kunit/kunit.py run --kunitconfig=drivers/leds 'leds-steelhead-avr*'`
Expected: build/link FAIL — `avr_encode_set_range` / `avr_decode_key` undefined.

- [ ] **Step 3: Implement the two pure functions**

```c
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./tools/testing/kunit/kunit.py run --kunitconfig=drivers/leds 'leds-steelhead-avr*'`
Expected: PASS, 4/4.

- [ ] **Step 5: Commit**

```bash
git add kernel/drivers/leds-steelhead-avr.c kernel/drivers/leds-steelhead-avr-test.c
git commit -m "leds-steelhead-avr: pure SET_RANGE encode + key decode with KUnit"
```

---

### Task 3: i2c helpers + probe skeleton (read & log FW/HW/count)

**Files:**
- Modify: `kernel/drivers/leds-steelhead-avr.c`

**Interfaces:**
- Consumes: `steelhead_avr.h` constants; `avr_encode_set_range`.
- Produces: `struct avr_dev` (driver state: `struct i2c_client *client; struct gpio_desc *reset; struct mutex io_lock; struct avr_rgb ring[AVR_RING_LEDS]; struct avr_rgb mute; u8 mode;`);
  `static int avr_write(struct avr_dev*, const u8 *buf, size_t len)` (retrying);
  `static int avr_read_reg(struct avr_dev*, u8 reg, u8 *val)` (write reg then read 1 byte, retrying);
  module bind on `google,steelhead-avr`.

- [ ] **Step 1: Add includes, state struct, i2c helpers, and probe**

Append to `kernel/drivers/leds-steelhead-avr.c`:

```c
#include <linux/i2c.h>
#include <linux/gpio/consumer.h>
#include <linux/mutex.h>
#include <linux/delay.h>
#include <linux/of.h>

struct avr_dev {
	struct i2c_client *client;
	struct gpio_desc *reset;
	struct mutex io_lock;
	struct avr_rgb ring[AVR_RING_LEDS];
	struct avr_rgb mute;
	u8 mode;
};

static int avr_write(struct avr_dev *a, const u8 *buf, size_t len)
{
	int i, ret = -EIO;

	for (i = 0; i < AVR_I2C_RETRIES; i++) {
		ret = i2c_master_send(a->client, buf, len);
		if (ret == (int)len)
			return 0;
		usleep_range(1000, 2000);
	}
	dev_err(&a->client->dev, "i2c write failed: %d\n", ret);
	return ret < 0 ? ret : -EIO;
}

static int avr_read_reg(struct avr_dev *a, u8 reg, u8 *val)
{
	int i, ret = -EIO;

	for (i = 0; i < AVR_I2C_RETRIES; i++) {
		ret = i2c_master_send(a->client, &reg, 1);
		if (ret == 1) {
			ret = i2c_master_recv(a->client, val, 1);
			if (ret == 1)
				return 0;
		}
		usleep_range(1000, 2000);
	}
	dev_err(&a->client->dev, "i2c read reg 0x%02x failed: %d\n", reg, ret);
	return ret < 0 ? ret : -EIO;
}

static int avr_set_mode(struct avr_dev *a, u8 mode)
{
	u8 buf[2] = { AVR_REG_LED_MODE, mode };
	int ret = avr_write(a, buf, sizeof(buf));

	if (!ret)
		a->mode = mode;
	return ret;
}

static int avr_probe(struct i2c_client *client)
{
	struct avr_dev *a;
	u8 fw = 0, hw = 0, rev = 0, count = 0;
	int ret;

	a = devm_kzalloc(&client->dev, sizeof(*a), GFP_KERNEL);
	if (!a)
		return -ENOMEM;
	a->client = client;
	mutex_init(&a->io_lock);
	i2c_set_clientdata(client, a);

	a->reset = devm_gpiod_get(&client->dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(a->reset))
		return dev_err_probe(&client->dev, PTR_ERR(a->reset),
				     "no reset gpio\n");
	/* pulse reset: active-low asserted by OUT_HIGH above, release */
	msleep(10);
	gpiod_set_value_cansleep(a->reset, 0);
	msleep(50);	/* let AVR boot */

	mutex_lock(&a->io_lock);
	ret = avr_read_reg(a, AVR_REG_FW_VER, &fw);
	if (!ret) ret = avr_read_reg(a, AVR_REG_HW_TYPE, &hw);
	if (!ret) ret = avr_read_reg(a, AVR_REG_HW_REV, &rev);
	if (!ret) ret = avr_read_reg(a, AVR_REG_GET_COUNT, &count);
	if (!ret) ret = avr_set_mode(a, AVR_LED_MODE_HOST);
	mutex_unlock(&a->io_lock);
	if (ret)
		return ret;

	dev_info(&client->dev,
		 "steelhead-avr: fw=0x%02x hw=0x%02x rev=0x%02x leds=%u, HOST mode\n",
		 fw, hw, rev, count);
	if (count != AVR_RING_LEDS)
		dev_warn(&client->dev, "expected %d LEDs, got %u\n",
			 AVR_RING_LEDS, count);
	return 0;
}

static const struct of_device_id avr_of_match[] = {
	{ .compatible = "google,steelhead-avr" },
	{ }
};
MODULE_DEVICE_TABLE(of, avr_of_match);

static struct i2c_driver avr_driver = {
	.driver = { .name = "steelhead-avr", .of_match_table = avr_of_match },
	.probe = avr_probe,
};
module_i2c_driver(avr_driver);

MODULE_DESCRIPTION("Google Nexus Q steelhead-AVR LED ring + keys");
MODULE_AUTHOR("nexusQ-reloaded");
MODULE_LICENSE("GPL");
```

Note: remove the duplicate `MODULE_LICENSE` from the pure-logic section so only one remains in the driver object (the KUnit file keeps its own).

- [ ] **Step 2: Build the module (cross), expecting clean compile**

Run: `bash scripts/build-led-module.sh` (created in Task 8; until then build in-tree with `make M=drivers/leds modules`).
Expected: produces `leds-steelhead-avr.ko`, no warnings.

- [ ] **Step 3: On-device load test**

```bash
scp leds-steelhead-avr.ko root@192.168.20.179:/tmp/
ssh root@192.168.20.179 'rmmod leds_steelhead_avr 2>/dev/null; insmod /tmp/leds-steelhead-avr.ko; dmesg | tail -5'
```
Expected: dmesg shows `fw=… hw=0x01 rev=… leds=32, HOST mode` and the driver bound to `1-0020` (no longer "no driver"). Verify: `ssh … 'ls -l /sys/bus/i2c/devices/1-0020/driver'` resolves to `…/steelhead-avr`.

- [ ] **Step 4: Commit**

```bash
git add kernel/drivers/leds-steelhead-avr.c
git commit -m "leds-steelhead-avr: i2c helpers + probe (reset, read FW/HW/count, HOST mode)"
```

---

### Task 4: Multicolor LED class (32 ring + 1 mute)

**Files:**
- Modify: `kernel/drivers/leds-steelhead-avr.c`

**Interfaces:**
- Consumes: `struct avr_dev`, `avr_write`, `avr_encode_set_range`, `io_lock`.
- Produces: `static int avr_flush_range(struct avr_dev*, u8 start, u8 count)`
  (encodes SET_RANGE from the shadow `ring[]`/`mute` + COMMIT immediate, under `io_lock`);
  registered `led_classdev_mc` devices named `steelhead:rgb:ring-N` and `steelhead:rgb:mute`.

- [ ] **Step 1: Add the flush helper + LED class registration**

```c
#include <linux/leds.h>
#include <linux/led-class-multicolor.h>

static int avr_commit(struct avr_dev *a, u8 mode)
{
	u8 buf[2] = { AVR_REG_COMMIT, mode };
	return avr_write(a, buf, sizeof(buf));
}

/* caller holds io_lock */
static int avr_flush_range_locked(struct avr_dev *a, u8 start, u8 count)
{
	u8 buf[3 + AVR_RING_LEDS * 3];
	int n, ret;

	n = avr_encode_set_range(buf, sizeof(buf), start, &a->ring[start], count);
	if (n < 0)
		return n;
	ret = avr_write(a, buf, n);
	if (ret)
		return ret;
	return avr_commit(a, AVR_COMMIT_IMMEDIATE);
}

struct avr_mc_led {
	struct led_classdev_mc mc;
	struct mc_subled subs[3];
	struct avr_dev *avr;
	int index;		/* 0 = mute, 1..32 = ring (ring[index-1]) */
};
#define to_avr_mc(c) container_of(c, struct avr_mc_led, mc.led_cdev)

static int avr_mc_set(struct led_classdev *cdev, enum led_brightness bright)
{
	struct led_classdev_mc *mc = lcdev_to_mccdev(cdev);
	struct avr_mc_led *l = to_avr_mc(mc);
	struct avr_dev *a = l->avr;
	struct avr_rgb rgb;
	int ret;

	led_mc_calc_color_components(mc, bright);
	rgb.r = mc->subled_info[0].brightness;
	rgb.g = mc->subled_info[1].brightness;
	rgb.b = mc->subled_info[2].brightness;

	mutex_lock(&a->io_lock);
	if (l->index == 0) {
		u8 buf[4] = { AVR_REG_SET_MUTE, rgb.r, rgb.g, rgb.b };
		a->mute = rgb;
		ret = avr_write(a, buf, sizeof(buf));
		if (!ret) ret = avr_commit(a, AVR_COMMIT_IMMEDIATE);
	} else {
		a->ring[l->index - 1] = rgb;
		ret = avr_flush_range_locked(a, l->index - 1, 1);
	}
	mutex_unlock(&a->io_lock);
	return ret;
}

static int avr_register_one_mc(struct avr_dev *a, int index)
{
	struct device *dev = &a->client->dev;
	struct avr_mc_led *l;
	struct led_init_data init = {};
	char *name;

	l = devm_kzalloc(dev, sizeof(*l), GFP_KERNEL);
	if (!l)
		return -ENOMEM;
	l->avr = a;
	l->index = index;
	l->subs[0].color_index = LED_COLOR_ID_RED;
	l->subs[1].color_index = LED_COLOR_ID_GREEN;
	l->subs[2].color_index = LED_COLOR_ID_BLUE;
	l->subs[0].intensity = l->subs[1].intensity = l->subs[2].intensity = 0;
	l->mc.subled_info = l->subs;
	l->mc.num_colors = 3;
	l->mc.led_cdev.max_brightness = 255;
	l->mc.led_cdev.brightness_set_blocking = avr_mc_set;

	if (index == 0)
		name = devm_kasprintf(dev, GFP_KERNEL, "steelhead:rgb:mute");
	else
		name = devm_kasprintf(dev, GFP_KERNEL, "steelhead:rgb:ring-%d",
				      index - 1);
	if (!name)
		return -ENOMEM;
	init.devicename = NULL;
	l->mc.led_cdev.name = name;

	return devm_led_classdev_multicolor_register(dev, &l->mc);
}

static int avr_register_leds(struct avr_dev *a)
{
	int i, ret;

	for (i = 0; i <= AVR_RING_LEDS; i++) {	/* 0=mute, 1..32=ring */
		ret = avr_register_one_mc(a, i);
		if (ret)
			return ret;
	}
	return 0;
}
```

Then call `avr_register_leds(a)` at the end of `avr_probe()` before the final `return 0;` (propagate errors).

- [ ] **Step 2: Build the module**

Run: `bash scripts/build-led-module.sh`
Expected: clean build; `leds-steelhead-avr.ko` produced.

- [ ] **Step 3: On-device test — sysfs nodes + light one LED**

```bash
scp leds-steelhead-avr.ko root@192.168.20.179:/tmp/
ssh root@192.168.20.179 'rmmod leds_steelhead_avr; insmod /tmp/leds-steelhead-avr.ko;
  ls /sys/class/leds | grep steelhead | head;
  echo 255 > /sys/class/leds/steelhead:rgb:ring-0/multi_intensity 2>/dev/null;
  echo "255 0 0" > /sys/class/leds/steelhead:rgb:ring-0/multi_intensity;
  echo 255 > /sys/class/leds/steelhead:rgb:ring-0/brightness'
```
Expected: 33 nodes (`steelhead:rgb:ring-0..31`, `steelhead:rgb:mute`); ring LED 0 turns **red**. (Visual confirmation on the device.)

- [ ] **Step 4: Commit**

```bash
git add kernel/drivers/leds-steelhead-avr.c
git commit -m "leds-steelhead-avr: multicolor LED class for 32 ring + mute"
```

---

### Task 5: Frame channel (batch sysfs: frame / commit_mode / mute)

**Files:**
- Modify: `kernel/drivers/leds-steelhead-avr.c`

**Interfaces:**
- Consumes: `avr_flush_range_locked`, `avr_commit`, `io_lock`, shadow `ring[]`.
- Produces: device attributes group on `&client->dev`: binary attr `frame`
  (write 96 bytes = 32×RGB), `commit_mode` (text "0"/"1"), `mute` (write "R G B").
  `a->commit_mode` (u8) added to `struct avr_dev`.

- [ ] **Step 1: Add the frame bin attribute + commit_mode/mute attrs**

```c
#include <linux/sysfs.h>

/* add to struct avr_dev: u8 commit_mode; */

static ssize_t frame_write(struct file *fp, struct kobject *kobj,
			   struct bin_attribute *attr, char *buf,
			   loff_t off, size_t count)
{
	struct device *dev = kobj_to_dev(kobj);
	struct avr_dev *a = i2c_get_clientdata(to_i2c_client(dev));
	int i, ret;

	if (off != 0 || count != AVR_RING_LEDS * 3)
		return -EINVAL;
	mutex_lock(&a->io_lock);
	for (i = 0; i < AVR_RING_LEDS; i++) {
		a->ring[i].r = buf[i*3 + 0];
		a->ring[i].g = buf[i*3 + 1];
		a->ring[i].b = buf[i*3 + 2];
	}
	{
		u8 obuf[3 + AVR_RING_LEDS * 3];
		int n = avr_encode_set_range(obuf, sizeof(obuf), 0,
					     a->ring, AVR_RING_LEDS);
		ret = (n < 0) ? n : avr_write(a, obuf, n);
		if (!ret)
			ret = avr_commit(a, a->commit_mode);
	}
	mutex_unlock(&a->io_lock);
	return ret ? ret : (ssize_t)count;
}
static BIN_ATTR(frame, 0200, NULL, frame_write, AVR_RING_LEDS * 3);

static ssize_t commit_mode_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	struct avr_dev *a = i2c_get_clientdata(to_i2c_client(dev));
	return sysfs_emit(buf, "%u\n", a->commit_mode);
}
static ssize_t commit_mode_store(struct device *dev,
				 struct device_attribute *attr,
				 const char *buf, size_t count)
{
	struct avr_dev *a = i2c_get_clientdata(to_i2c_client(dev));
	u8 v;
	if (kstrtou8(buf, 0, &v) || v > AVR_COMMIT_INTERPOLATE)
		return -EINVAL;
	a->commit_mode = v;
	return count;
}
static DEVICE_ATTR_RW(commit_mode);

static ssize_t mute_store(struct device *dev, struct device_attribute *attr,
			  const char *buf, size_t count)
{
	struct avr_dev *a = i2c_get_clientdata(to_i2c_client(dev));
	unsigned int r, g, b;
	u8 obuf[4];
	int ret;
	if (sscanf(buf, "%u %u %u", &r, &g, &b) != 3 || r > 255 || g > 255 || b > 255)
		return -EINVAL;
	obuf[0] = AVR_REG_SET_MUTE; obuf[1] = r; obuf[2] = g; obuf[3] = b;
	mutex_lock(&a->io_lock);
	a->mute = (struct avr_rgb){ r, g, b };
	ret = avr_write(a, obuf, sizeof(obuf));
	if (!ret) ret = avr_commit(a, AVR_COMMIT_IMMEDIATE);
	mutex_unlock(&a->io_lock);
	return ret ? ret : (ssize_t)count;
}
static DEVICE_ATTR_WO(mute);

static struct attribute *avr_attrs[] = {
	&dev_attr_commit_mode.attr, &dev_attr_mute.attr, NULL,
};
static struct bin_attribute *avr_bin_attrs[] = { &bin_attr_frame, NULL };
static const struct attribute_group avr_group = {
	.attrs = avr_attrs, .bin_attrs = avr_bin_attrs,
};
```

Register in `avr_probe()`: `ret = devm_device_add_group(&client->dev, &avr_group);` (after LED registration).

- [ ] **Step 2: Build the module**

Run: `bash scripts/build-led-module.sh`
Expected: clean build.

- [ ] **Step 3: On-device test — write a full frame**

```bash
scp leds-steelhead-avr.ko root@192.168.20.179:/tmp/
ssh root@192.168.20.179 'rmmod leds_steelhead_avr; insmod /tmp/leds-steelhead-avr.ko;
  python3 -c "import sys; sys.stdout.buffer.write(bytes([0,0,64]*32))" > /sys/bus/i2c/devices/1-0020/frame;
  echo 1 > /sys/bus/i2c/devices/1-0020/commit_mode;
  echo "0 64 0" > /sys/bus/i2c/devices/1-0020/mute'
```
Expected: whole ring dim blue; mute LED dim green. (Visual.)

- [ ] **Step 4: Commit**

```bash
git add kernel/drivers/leds-steelhead-avr.c
git commit -m "leds-steelhead-avr: batch frame channel (frame/commit_mode/mute sysfs)"
```

---

### Task 6: input device + threaded IRQ (mute/volume keys) + reset restore

**Files:**
- Modify: `kernel/drivers/leds-steelhead-avr.c`

**Interfaces:**
- Consumes: `avr_read_reg`, `avr_decode_key`, `avr_set_mode`, `avr_flush_range_locked`, shadow state.
- Produces: `a->input` (`struct input_dev *`); threaded IRQ handler `avr_irq` draining the FIFO; `static int avr_restore_state_locked(struct avr_dev*)` (re-asserts HOST + reloads ring + mute).

- [ ] **Step 1: Add input device, restore helper, and IRQ handler**

```c
#include <linux/interrupt.h>
#include <linux/input.h>

/* add to struct avr_dev: struct input_dev *input; */

/* caller holds io_lock */
static int avr_restore_state_locked(struct avr_dev *a)
{
	u8 mbuf[4] = { AVR_REG_SET_MUTE, a->mute.r, a->mute.g, a->mute.b };
	int ret = avr_set_mode(a, AVR_LED_MODE_HOST);

	if (!ret) ret = avr_write(a, mbuf, sizeof(mbuf));
	if (!ret) ret = avr_flush_range_locked(a, 0, AVR_RING_LEDS);
	return ret;
}

static irqreturn_t avr_irq(int irq, void *data)
{
	struct avr_dev *a = data;
	int budget = 64;	/* FIFO drain cap */

	while (budget--) {
		u8 b; u16 code; bool down; int ret;

		mutex_lock(&a->io_lock);
		ret = avr_read_reg(a, AVR_REG_KEY_FIFO, &b);
		mutex_unlock(&a->io_lock);
		if (ret)
			break;

		ret = avr_decode_key(b, &code, &down);
		if (ret == -EAGAIN)
			break;			/* FIFO empty */
		if (ret == -ERESTART) {		/* AVR reset: restore */
			mutex_lock(&a->io_lock);
			avr_restore_state_locked(a);
			mutex_unlock(&a->io_lock);
			continue;
		}
		if (ret)
			continue;		/* unknown code */
		input_report_key(a->input, code, down);
		input_sync(a->input);
	}
	return IRQ_HANDLED;
}

static int avr_register_input(struct avr_dev *a)
{
	struct input_dev *in = devm_input_allocate_device(&a->client->dev);

	if (!in)
		return -ENOMEM;
	in->name = "steelhead-avr-keys";
	in->id.bustype = BUS_I2C;
	input_set_capability(in, EV_KEY, KEY_MUTE);
	input_set_capability(in, EV_KEY, KEY_VOLUMEUP);
	input_set_capability(in, EV_KEY, KEY_VOLUMEDOWN);
	a->input = in;
	return input_register_device(in);
}
```

In `avr_probe()`: after LED+group registration, call `avr_register_input(a)`, then request the IRQ:

```c
	ret = devm_request_threaded_irq(&client->dev, client->irq, NULL,
					avr_irq, IRQF_ONESHOT | IRQF_TRIGGER_FALLING,
					"steelhead-avr", a);
	if (ret)
		return dev_err_probe(&client->dev, ret, "irq request failed\n");
```

- [ ] **Step 2: Build the module**

Run: `bash scripts/build-led-module.sh`
Expected: clean build.

- [ ] **Step 3: On-device test — keys via evtest**

```bash
scp leds-steelhead-avr.ko root@192.168.20.179:/tmp/
ssh root@192.168.20.179 'rmmod leds_steelhead_avr; insmod /tmp/leds-steelhead-avr.ko;
  apk add evtest 2>/dev/null; DEV=$(grep -l steelhead-avr-keys /sys/class/input/event*/device/name 2>/dev/null);
  ls -l /dev/input/by-path 2>/dev/null; echo "Now touch mute / rotate volume on the device, then Ctrl-C"; timeout 15 evtest /dev/input/event2'
```
Expected: touching mute emits `KEY_MUTE`; rotating the top emits `KEY_VOLUMEUP`/`KEY_VOLUMEDOWN`. (Confirm the correct `eventN` from the listing.)

- [ ] **Step 4: On-device test — reset restore**

Set a distinctive frame, then trigger an AVR reset (power-cycle is too coarse; instead verify indirectly): set ring red, then `rmmod`+`insmod` and confirm probe re-asserts HOST and ring is controllable again. Document that a true FIFO 0xFE path is exercised when the AVR resets in the field.

- [ ] **Step 5: Commit**

```bash
git add kernel/drivers/leds-steelhead-avr.c
git commit -m "leds-steelhead-avr: input device + threaded IRQ key handling + reset restore"
```

---

### Task 7: Kconfig/Makefile + KUnit config wiring

**Files:**
- Create: `kernel/drivers/Kconfig.steelhead` (hunk text reused by the patch)
- Modify: `kernel/configs/steelhead_defconfig`

**Interfaces:**
- Produces: `CONFIG_LEDS_STEELHEAD_AVR`, `CONFIG_LEDS_STEELHEAD_AVR_KUNIT_TEST`.

- [ ] **Step 1: Write the Kconfig entries**

Record these hunks (applied into `drivers/leds/Kconfig` by the Task 8 patch):

```kconfig
config LEDS_STEELHEAD_AVR
	tristate "Google Nexus Q steelhead-AVR LED ring + keys"
	depends on I2C && OF
	select LEDS_CLASS
	select LEDS_CLASS_MULTICOLOR
	select INPUT
	help
	  32 RGB ring LEDs + mute LED and the capacitive mute/volume keys on the
	  Google Nexus Q, behind the steelhead-AVR MCU on i2c.

config LEDS_STEELHEAD_AVR_KUNIT_TEST
	tristate "KUnit tests for steelhead-AVR" if !KUNIT_ALL_TESTS
	depends on LEDS_STEELHEAD_AVR && KUNIT
	default KUNIT_ALL_TESTS
```

And the `drivers/leds/Makefile` hunk:
```make
obj-$(CONFIG_LEDS_STEELHEAD_AVR)            += leds-steelhead-avr.o
obj-$(CONFIG_LEDS_STEELHEAD_AVR_KUNIT_TEST) += leds-steelhead-avr-test.o
```

- [ ] **Step 2: Add config to defconfig**

Append to `kernel/configs/steelhead_defconfig`:
```
CONFIG_LEDS_CLASS_MULTICOLOR=m
CONFIG_LEDS_STEELHEAD_AVR=m
```

- [ ] **Step 3: Commit**

```bash
git add kernel/drivers/Kconfig.steelhead kernel/configs/steelhead_defconfig
git commit -m "leds-steelhead-avr: Kconfig/Makefile entries + enable in defconfig"
```

---

### Task 8: Build/flash integration (patch 0005 + helper script + full boot.img)

**Files:**
- Create: `scripts/build-led-module.sh`
- Create: `kernel/patches/0005-leds-add-steelhead-avr.patch`
- Modify: `pmos/linux-google-steelhead/APKBUILD` (add the patch + SKIP its sha512), per the existing 0003 pattern.

**Interfaces:**
- Produces: reproducible module build + a boot.img with the module config enabled.

- [ ] **Step 1: Write the module build helper**

```bash
#!/bin/sh
# Build only leds-steelhead-avr.ko against the extracted 6.12.12 tree.
# Usage: build-led-module.sh /path/to/linux-6.12.12
set -e
LINUX="${1:?path to linux tree}"
TC="$(ls -d "$PWD"/build/arm-gnu-toolchain-13.3.rel1-*/bin)"
export ARCH=arm CROSS_COMPILE="$TC/arm-none-linux-gnueabihf-"
cp kernel/drivers/steelhead_avr.h kernel/drivers/leds-steelhead-avr.c \
   kernel/drivers/leds-steelhead-avr-test.c "$LINUX/drivers/leds/"
# ensure config + Kconfig/Makefile hunks are present (applied via patch 0005)
make -C "$LINUX" M=drivers/leds modules
echo "MODULE: $LINUX/drivers/leds/leds-steelhead-avr.ko"
```

- [ ] **Step 2: Generate the patch from the repo sources**

Create `0005-leds-add-steelhead-avr.patch` adding `drivers/leds/leds-steelhead-avr.c`,
`drivers/leds/leds-steelhead-avr-test.c` (copies of the repo files) plus the
Kconfig/Makefile hunks from Task 7. Add it to the linux APKBUILD `source=` and
`sha512sums` as `SKIP` (matching how `0003-ARM-dts-omap4-add-steelhead.patch` is
listed).

- [ ] **Step 3: Full clean kernel build + flash**

```bash
docker build -t nexusq-builder . && \
docker run --rm --privileged -v "${PWD}:/src:ro" -v nexusq-output:/tmp/output \
  -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap --name nexusq-build \
  nexusq-builder /src/docker-build.sh && \
docker run --rm -v nexusq-output:/data -v "${PWD}/output:/out" alpine:3.21 \
  sh -c 'cp /data/*.img /out/'
```
Then flash from the running device (keep `output/boot-wifi-v5.img` as fallback):
```bash
ssh root@192.168.20.179 'cat > /tmp/boot.img && dd if=/tmp/boot.img of=/dev/mmcblk0p9 bs=1M conv=fsync && systemctl reboot' < output/boot.img
```
Expected: device boots (retry power-cycle if the ~1/3 flaky boot hits); after boot
`modprobe leds-steelhead-avr` (or it autoloads) → `/sys/class/leds/steelhead:rgb:*`
present, keys work, ring controllable. Image stays ≤ 6.5 MB.

- [ ] **Step 4: Verify KUnit still green in-tree**

Run: `./tools/testing/kunit/kunit.py run --kunitconfig=drivers/leds 'leds-steelhead-avr*'`
Expected: 4/4 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/build-led-module.sh kernel/patches/0005-leds-add-steelhead-avr.patch pmos/linux-google-steelhead/APKBUILD
git commit -m "leds-steelhead-avr: build/flash integration (patch 0005 + module build script)"
```

---

## Self-Review

**Spec coverage (kernel-driver portion of the spec):**
- Multicolor LED class (32 ring + 1 mute) → Task 4 ✅
- Frame channel (frame/commit_mode/mute) → Task 5 ✅
- input_dev + IRQ FIFO drain → Task 6 ✅
- Probe: reset gpio, read FW/HW/count, HOST mode → Task 3 ✅
- i2c retry (5) → Task 3 ✅
- AVR-reset state restore → Task 6 ✅
- Module build, defconfig (=m), patch 0005, flash-from-running → Tasks 7–8 ✅
- Pure-logic TDD via KUnit → Task 2 ✅
- DT node consumed as-is (no DTS change needed) ✅
- Daemon, visualizer, themes, assets → **out of scope for Plan 1** (Plans 2 & 3).

**Placeholder scan:** Task 6 Step 4 (reset restore) is verified indirectly (rmmod/insmod) because forcing a live FIFO 0xFE without hardware reset is not safely scriptable — this is an explicit, justified limitation, not a placeholder. No TBD/TODO elsewhere.

**Type consistency:** `avr_dev` fields (`client, reset, io_lock, ring[], mute, mode, commit_mode, input`) are introduced incrementally and used consistently; `avr_encode_set_range`/`avr_decode_key`/`avr_flush_range_locked`/`avr_restore_state_locked`/`avr_commit`/`avr_set_mode` signatures match across tasks.

## Notes for Plans 2 & 3 (not yet written)

- **Plan 2 (nexusqd daemon + assets):** `setup-leds-assets.sh`, theme JSON loader,
  compositor (idle/volume/status), input handling, control socket, `nexusled` CLI,
  systemd unit. Resolve open item: exact **volume-ring** + **mute LED** behavior
  (reverse-engineer for pixel-perfect).
- **Plan 3 (visualizer):** confirm device audio stack (PipeWire/ALSA), Android-FFT
  capture, shader-port-to-C with the golden test harness, offline simulator.
