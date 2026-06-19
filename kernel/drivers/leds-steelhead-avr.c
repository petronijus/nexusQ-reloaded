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

#include <linux/i2c.h>
#include <linux/gpio/consumer.h>
#include <linux/mutex.h>
#include <linux/delay.h>
#include <linux/of.h>

/* The AVR runs a boot sequence after reset and may NAK i2c for up to a
 * second or more before it is ready. Poll for readiness rather than using a
 * fixed delay. */
#define AVR_READY_POLL_MS	50
#define AVR_READY_TIMEOUT_MS	2000

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

/* Quiet single-shot register read for the post-reset readiness poll: no
 * retries and no dev_err, so a NAK from a still-booting AVR does not spam
 * dmesg. Returns 0 on success, negative errno (e.g. -EREMOTEIO) otherwise. */
static int avr_read_reg_quiet(struct avr_dev *a, u8 reg, u8 *val)
{
	int ret;

	ret = i2c_master_send(a->client, &reg, 1);
	if (ret == 1) {
		ret = i2c_master_recv(a->client, val, 1);
		if (ret == 1)
			return 0;
	}
	return ret < 0 ? ret : -EIO;
}

/* Wait for the AVR to finish its post-reset boot and start ACKing on i2c.
 * Polls AVR_REG_FW_VER quietly up to AVR_READY_TIMEOUT_MS. Returns 0 once it
 * ACKs, -ENODEV on timeout. */
static int avr_wait_ready(struct avr_dev *a)
{
	unsigned long deadline = jiffies + msecs_to_jiffies(AVR_READY_TIMEOUT_MS);
	u8 fw;
	int ret;

	for (;;) {
		ret = avr_read_reg_quiet(a, AVR_REG_FW_VER, &fw);
		if (!ret)
			return 0;
		if (time_after(jiffies, deadline))
			return -ENODEV;
		msleep(AVR_READY_POLL_MS);
	}
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

	mutex_lock(&a->io_lock);
	/* The AVR is not ready to ACK on i2c for some time after reset; wait
	 * for it instead of using a fixed delay (a fixed 50 ms NAKs on real
	 * hardware). */
	ret = avr_wait_ready(a);
	if (ret) {
		mutex_unlock(&a->io_lock);
		return dev_err_probe(&client->dev, ret,
				     "AVR not ready after reset\n");
	}

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
