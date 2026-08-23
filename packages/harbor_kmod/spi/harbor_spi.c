// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor SPI controller driver
 *
 * Each register sits in its own 8-byte slot: the controller sits on a
 * byte-addressed fabric that decodes the low bits of the byte address, like
 * every other Harbor peripheral. 4-byte spacing aliases every register onto its
 * neighbour.
 *
 *   0x00: CTRL    (RW) - enable, CPOL, CPHA, loopback
 *   0x08: STATUS  (RO) - busy, tx_empty, rx_ready
 *   0x10: DATA    (RW) - write = TX, read = RX
 *   0x18: DIVIDER (RW) - clock divider
 *   0x20: CS      (RW) - chip select, one active-high bit per line
 *
 * The chip-select register is active high and the controller inverts it onto
 * the active-low SPI_CS_N pads.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/spi/spi.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/of.h>
#include <linux/clk.h>

#define HARBOR_SPI_CTRL	   0x00
#define HARBOR_SPI_STATUS  0x08
#define HARBOR_SPI_DATA	   0x10
#define HARBOR_SPI_DIVIDER 0x18
#define HARBOR_SPI_CS	   0x20

#define HARBOR_SPI_CTRL_ENABLE BIT(0)
#define HARBOR_SPI_CTRL_CPOL   BIT(1)
#define HARBOR_SPI_CTRL_CPHA   BIT(2)
#define HARBOR_SPI_CTRL_LOOP   BIT(3)

#define HARBOR_SPI_ST_BUSY     BIT(0)
#define HARBOR_SPI_ST_TX_EMPTY BIT(1)
#define HARBOR_SPI_ST_RX_READY BIT(2)

/* The divider is 16 bits, and SCK is the input clock over 2 * (divider + 1). */
#define HARBOR_SPI_DIV_MAX 65535

/*
 * One byte takes 8 SCK periods, so the longest transfer at the largest divider
 * is far under this. A controller that never clears BUSY (unclocked or wedged)
 * fails the transfer instead of hanging the thread.
 */
#define HARBOR_SPI_TIMEOUT_US 1000000

struct harbor_spi {
	void __iomem *base;
	struct spi_controller *host;
	unsigned int freq;
	u32 ctrl;
};

static void harbor_spi_set_cs(struct spi_device *spi, bool enable)
{
	struct harbor_spi *hs = spi_controller_get_devdata(spi->controller);
	u8 cs_line = spi_get_chipselect(spi, 0);
	u32 cs;

	/*
	 * `enable` is the logic level to drive on the pad. The CS register is
	 * the active-high select, which the controller inverts onto the pad, so
	 * a high pad means the select bit is clear.
	 */
	cs = readl(hs->base + HARBOR_SPI_CS);
	if (enable)
		cs &= ~BIT(cs_line);
	else
		cs |= BIT(cs_line);
	writel(cs, hs->base + HARBOR_SPI_CS);
}

static int harbor_spi_wait_busy(struct harbor_spi *hs)
{
	u32 sts;

	return readl_poll_timeout(hs->base + HARBOR_SPI_STATUS, sts,
				  !(sts & HARBOR_SPI_ST_BUSY), 0,
				  HARBOR_SPI_TIMEOUT_US);
}

static void harbor_spi_set_speed(struct harbor_spi *hs, u32 speed_hz)
{
	unsigned int half;
	u32 div;

	if (!speed_hz || !hs->freq)
		return;

	half = hs->freq / (2 * speed_hz);
	div = half > 0 ? half - 1 : 0;
	if (div > HARBOR_SPI_DIV_MAX)
		div = HARBOR_SPI_DIV_MAX;
	writel(div, hs->base + HARBOR_SPI_DIVIDER);
}

/*
 * Program the mode before the first transfer of a message. CPOL and CPHA are
 * per-device, so a board with two devices at different modes needs this on
 * every message, not once at probe.
 */
static int harbor_spi_prepare_message(struct spi_controller *host,
				      struct spi_message *msg)
{
	struct harbor_spi *hs = spi_controller_get_devdata(host);
	u32 ctrl = HARBOR_SPI_CTRL_ENABLE;

	if (msg->spi->mode & SPI_CPOL)
		ctrl |= HARBOR_SPI_CTRL_CPOL;
	if (msg->spi->mode & SPI_CPHA)
		ctrl |= HARBOR_SPI_CTRL_CPHA;
	if (msg->spi->mode & SPI_LOOP)
		ctrl |= HARBOR_SPI_CTRL_LOOP;

	hs->ctrl = ctrl;
	writel(ctrl, hs->base + HARBOR_SPI_CTRL);
	return 0;
}

static int harbor_spi_transfer_one(struct spi_controller *host,
				   struct spi_device *spi,
				   struct spi_transfer *t)
{
	struct harbor_spi *hs = spi_controller_get_devdata(host);
	const u8 *tx = t->tx_buf;
	u8 *rx = t->rx_buf;
	unsigned int i;
	int ret;

	harbor_spi_set_speed(hs, t->speed_hz);

	for (i = 0; i < t->len; i++) {
		/*
		 * Idle MOSI high on a receive-only transfer. A device that
		 * reads a command byte off the bus sees 0xFF as no command,
		 * where a zero byte can start one.
		 */
		writel(tx ? tx[i] : 0xff, hs->base + HARBOR_SPI_DATA);

		ret = harbor_spi_wait_busy(hs);
		if (ret)
			return ret;

		if (rx)
			rx[i] = readl(hs->base + HARBOR_SPI_DATA) & 0xff;
		else
			readl(hs->base + HARBOR_SPI_DATA); /* clear RX_READY */
	}

	return 0;
}

static int harbor_spi_probe(struct platform_device *pdev)
{
	struct harbor_spi *hs;
	struct spi_controller *host;
	struct clk *clk;
	u32 num_cs = 1;
	int ret;

	host = devm_spi_alloc_host(&pdev->dev, sizeof(*hs));
	if (!host)
		return -ENOMEM;

	hs = spi_controller_get_devdata(host);
	hs->host = host;

	hs->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hs->base))
		return PTR_ERR(hs->base);

	/*
	 * The controller input clock. Harbor's device tree states the rate
	 * directly in `clock-frequency` rather than through a clock provider, so
	 * take that first and fall back to a `clocks` phandle. Without a rate the
	 * driver leaves the divider alone and the bus runs at whatever the reset
	 * value gives.
	 */
	clk = devm_clk_get_optional_enabled(&pdev->dev, NULL);
	if (IS_ERR(clk))
		return PTR_ERR(clk);
	if (device_property_read_u32(&pdev->dev, "clock-frequency", &hs->freq))
		hs->freq = clk ? clk_get_rate(clk) : 0;

	device_property_read_u32(&pdev->dev, "num-cs", &num_cs);

	host->bus_num = -1;
	host->num_chipselect = num_cs;
	host->mode_bits = SPI_CPOL | SPI_CPHA | SPI_LOOP;
	host->bits_per_word_mask = SPI_BPW_MASK(8);
	host->set_cs = harbor_spi_set_cs;
	host->prepare_message = harbor_spi_prepare_message;
	host->transfer_one = harbor_spi_transfer_one;
	/* Child enumeration follows this node, DT or ACPI alike. */
	device_set_node(&host->dev, dev_fwnode(&pdev->dev));
	if (hs->freq) {
		host->max_speed_hz = hs->freq / 2;
		host->min_speed_hz = hs->freq / (2 * (HARBOR_SPI_DIV_MAX + 1));
	}

	/* Enable the controller with every chip select released. */
	writel(0, hs->base + HARBOR_SPI_CS);
	hs->ctrl = HARBOR_SPI_CTRL_ENABLE;
	writel(hs->ctrl, hs->base + HARBOR_SPI_CTRL);

	ret = devm_spi_register_controller(&pdev->dev, host);
	if (ret)
		return ret;

	platform_set_drvdata(pdev, hs);
	return 0;
}

static const struct of_device_id harbor_spi_of_match[] = {
    {.compatible = "harbor,spi"}, {.compatible = "midstall,harbor-spi"}, {}};
MODULE_DEVICE_TABLE(of, harbor_spi_of_match);

static struct platform_driver harbor_spi_driver = {
    .probe = harbor_spi_probe,
    .driver =
	{
	    .name = "harbor-spi",
	    .of_match_table = harbor_spi_of_match,
	},
};
module_platform_driver(harbor_spi_driver);

MODULE_AUTHOR("Midstall Software");
MODULE_DESCRIPTION("Harbor SPI controller driver");
MODULE_LICENSE("GPL");
