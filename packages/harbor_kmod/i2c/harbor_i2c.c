// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor I2C controller driver
 *
 * Each register sits in its own 8-byte slot: the controller sits on a
 * byte-addressed fabric that decodes the low bits of the byte address, like
 * every other Harbor peripheral. 4-byte spacing aliases every register onto its
 * neighbour.
 *
 *   0x00: CTRL     (RW) - enable, interrupt enable
 *   0x08: STATUS   (RW) - busy, ack, arb_lost, rx_ready, cmd_done
 *   0x10: DATA     (RW) - write=TX, read=RX
 *   0x18: ADDR     (RW) - own address, slave mode only
 *   0x20: PRESCALE (RW) - clock prescaler
 *   0x28: CMD      (WO) - start/stop/read/write triggers
 *
 * The slave address rides DATA as the first byte of the frame
 * (address << 1 | read), which is what the shift engine sends.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/i2c.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/clk.h>

#define HARBOR_I2C_CTRL	    0x00
#define HARBOR_I2C_STATUS   0x08
#define HARBOR_I2C_DATA	    0x10
#define HARBOR_I2C_ADDR	    0x18
#define HARBOR_I2C_PRESCALE 0x20
#define HARBOR_I2C_CMD	    0x28

#define HARBOR_I2C_CTRL_ENABLE BIT(0)
#define HARBOR_I2C_CTRL_IRQ_EN BIT(1)

#define HARBOR_I2C_ST_BUSY     BIT(0)
#define HARBOR_I2C_ST_ACK      BIT(1)
#define HARBOR_I2C_ST_ARB_LOST BIT(2)
#define HARBOR_I2C_ST_RX_READY BIT(4)
#define HARBOR_I2C_ST_CMD_DONE BIT(5)

#define HARBOR_I2C_CMD_START BIT(0)
#define HARBOR_I2C_CMD_STOP  BIT(1)
#define HARBOR_I2C_CMD_WRITE BIT(2)
#define HARBOR_I2C_CMD_READ  BIT(3)

struct harbor_i2c {
	void __iomem *base;
	struct i2c_adapter adap;
	unsigned int freq;
};

static int harbor_i2c_wait_done(struct harbor_i2c *hi)
{
	int timeout = 100000;

	while (
	    !(readl(hi->base + HARBOR_I2C_STATUS) & HARBOR_I2C_ST_CMD_DONE)) {
		if (--timeout == 0)
			return -ETIMEDOUT;
		cpu_relax();
	}
	/* Clear done flag */
	writel(HARBOR_I2C_ST_CMD_DONE, hi->base + HARBOR_I2C_STATUS);
	return 0;
}

static int harbor_i2c_xfer(struct i2c_adapter *adap, struct i2c_msg *msgs,
			   int num)
{
	struct harbor_i2c *hi = i2c_get_adapdata(adap);
	int i, j, ret;

	for (i = 0; i < num; i++) {
		struct i2c_msg *msg = &msgs[i];
		u8 addr_byte =
		    (msg->addr << 1) | (msg->flags & I2C_M_RD ? 1 : 0);

		/* START + address */
		writel(addr_byte, hi->base + HARBOR_I2C_DATA);
		writel(HARBOR_I2C_CMD_START | HARBOR_I2C_CMD_WRITE,
		       hi->base + HARBOR_I2C_CMD);

		ret = harbor_i2c_wait_done(hi);
		if (ret)
			goto out;

		/* Check ACK */
		if (!(readl(hi->base + HARBOR_I2C_STATUS) &
		      HARBOR_I2C_ST_ACK)) {
			ret = -ENXIO;
			goto out;
		}

		/* Data phase */
		for (j = 0; j < msg->len; j++) {
			if (msg->flags & I2C_M_RD) {
				writel(HARBOR_I2C_CMD_READ,
				       hi->base + HARBOR_I2C_CMD);
				ret = harbor_i2c_wait_done(hi);
				if (ret)
					goto out;
				msg->buf[j] =
				    readl(hi->base + HARBOR_I2C_DATA) & 0xFF;
			} else {
				writel(msg->buf[j], hi->base + HARBOR_I2C_DATA);
				writel(HARBOR_I2C_CMD_WRITE,
				       hi->base + HARBOR_I2C_CMD);
				ret = harbor_i2c_wait_done(hi);
				if (ret)
					goto out;
			}
		}
	}

	ret = num;

out:
	/* STOP */
	writel(HARBOR_I2C_CMD_STOP, hi->base + HARBOR_I2C_CMD);
	harbor_i2c_wait_done(hi);
	return ret;
}

static u32 harbor_i2c_functionality(struct i2c_adapter *adap)
{
	return I2C_FUNC_I2C | I2C_FUNC_SMBUS_EMUL;
}

static const struct i2c_algorithm harbor_i2c_algo = {
    .master_xfer = harbor_i2c_xfer,
    .functionality = harbor_i2c_functionality,
};

static int harbor_i2c_probe(struct platform_device *pdev)
{
	struct harbor_i2c *hi;
	struct clk *clk;
	u32 bus_freq = I2C_MAX_STANDARD_MODE_FREQ;
	int ret;

	hi = devm_kzalloc(&pdev->dev, sizeof(*hi), GFP_KERNEL);
	if (!hi)
		return -ENOMEM;

	hi->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hi->base))
		return PTR_ERR(hi->base);

	/*
	 * The controller input clock. Harbor's device tree states it directly in
	 * `harbor,input-clock-hz`, and NOT in `clock-frequency`: on an I2C node
	 * the standard binding gives `clock-frequency` the SCL bus rate, which is
	 * read separately below. Fall back to a `clocks` phandle.
	 */
	clk = devm_clk_get_optional_enabled(&pdev->dev, NULL);
	if (IS_ERR(clk))
		return PTR_ERR(clk);
	if (device_property_read_u32(&pdev->dev, "harbor,input-clock-hz",
				     &hi->freq))
		hi->freq = clk ? clk_get_rate(clk) : 0;

	device_property_read_u32(&pdev->dev, "clock-frequency", &bus_freq);

	/*
	 * Prescale = input / (5 * SCL) - 1. Skip it when the input clock is too
	 * slow for the requested bus rate, rather than underflowing to a huge
	 * divider that would stall SCL.
	 */
	if (hi->freq && bus_freq && hi->freq >= 5 * bus_freq)
		writel(hi->freq / (5 * bus_freq) - 1,
		       hi->base + HARBOR_I2C_PRESCALE);
	else if (hi->freq && bus_freq)
		dev_warn(&pdev->dev,
			 "input clock %u Hz too slow for %u Hz SCL, keeping "
			 "the reset prescale\n",
			 hi->freq, bus_freq);

	/* Enable controller */
	writel(HARBOR_I2C_CTRL_ENABLE, hi->base + HARBOR_I2C_CTRL);

	hi->adap.owner = THIS_MODULE;
	hi->adap.algo = &harbor_i2c_algo;
	hi->adap.dev.parent = &pdev->dev;
	/* Child enumeration follows this node, DT or ACPI alike. */
	device_set_node(&hi->adap.dev, dev_fwnode(&pdev->dev));
	strscpy(hi->adap.name, "harbor-i2c", sizeof(hi->adap.name));
	i2c_set_adapdata(&hi->adap, hi);

	ret = devm_i2c_add_adapter(&pdev->dev, &hi->adap);
	if (ret)
		return ret;

	platform_set_drvdata(pdev, hi);
	return 0;
}

static const struct of_device_id harbor_i2c_of_match[] = {
    {.compatible = "harbor,i2c"}, {}};
MODULE_DEVICE_TABLE(of, harbor_i2c_of_match);

static struct platform_driver harbor_i2c_driver = {
    .probe = harbor_i2c_probe,
    .driver =
	{
	    .name = "harbor-i2c",
	    .of_match_table = harbor_i2c_of_match,
	},
};
module_platform_driver(harbor_i2c_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor I2C controller driver");
MODULE_LICENSE("GPL");
