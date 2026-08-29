// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor Watchdog timer driver
 *
 * Each register sits in its own 8-byte slot: the controller sits on a
 * byte-addressed fabric that decodes the low bits of the byte address, like
 * every other Harbor peripheral. 4-byte spacing aliases every register onto its
 * neighbour.
 *
 * Registers:
 *   0x00: CTRL      0x08: STATUS    0x10: TIMEOUT
 *   0x18: WINDOW    0x20: KICK      0x28: COUNT
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/watchdog.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/clk.h>

#define HARBOR_WDT_CTRL	   0x00
#define HARBOR_WDT_STATUS  0x08
#define HARBOR_WDT_TIMEOUT 0x10
#define HARBOR_WDT_WINDOW  0x18
#define HARBOR_WDT_KICK	   0x20
#define HARBOR_WDT_COUNT   0x28

#define HARBOR_WDT_KICK_MAGIC 0x4B494B

struct harbor_wdt {
	void __iomem *base;
	struct watchdog_device wdd;
	unsigned long clk_rate;
};

static int harbor_wdt_start(struct watchdog_device *wdd)
{
	struct harbor_wdt *hw = watchdog_get_drvdata(wdd);

	writel(wdd->timeout * hw->clk_rate, hw->base + HARBOR_WDT_TIMEOUT);
	writel(0x03, hw->base + HARBOR_WDT_CTRL); /* enable + reset_en */
	return 0;
}

static int harbor_wdt_stop(struct watchdog_device *wdd)
{
	struct harbor_wdt *hw = watchdog_get_drvdata(wdd);

	writel(0, hw->base + HARBOR_WDT_CTRL);
	return 0;
}

static int harbor_wdt_ping(struct watchdog_device *wdd)
{
	struct harbor_wdt *hw = watchdog_get_drvdata(wdd);

	writel(HARBOR_WDT_KICK_MAGIC, hw->base + HARBOR_WDT_KICK);
	return 0;
}

static int harbor_wdt_set_timeout(struct watchdog_device *wdd, unsigned int t)
{
	struct harbor_wdt *hw = watchdog_get_drvdata(wdd);

	wdd->timeout = t;
	writel(t * hw->clk_rate, hw->base + HARBOR_WDT_TIMEOUT);
	return 0;
}

static unsigned int harbor_wdt_get_timeleft(struct watchdog_device *wdd)
{
	struct harbor_wdt *hw = watchdog_get_drvdata(wdd);
	u32 count = readl(hw->base + HARBOR_WDT_COUNT);
	u32 timeout = readl(hw->base + HARBOR_WDT_TIMEOUT);

	if (hw->clk_rate == 0 || count >= timeout)
		return 0;
	return (timeout - count) / hw->clk_rate;
}

static const struct watchdog_ops harbor_wdt_ops = {
    .owner = THIS_MODULE,
    .start = harbor_wdt_start,
    .stop = harbor_wdt_stop,
    .ping = harbor_wdt_ping,
    .set_timeout = harbor_wdt_set_timeout,
    .get_timeleft = harbor_wdt_get_timeleft,
};

static const struct watchdog_info harbor_wdt_info = {
    .identity = "Harbor Watchdog",
    .options = WDIOF_SETTIMEOUT | WDIOF_KEEPALIVEPING | WDIOF_MAGICCLOSE,
};

static int harbor_wdt_probe(struct platform_device *pdev)
{
	struct harbor_wdt *hw;
	struct clk *clk;

	hw = devm_kzalloc(&pdev->dev, sizeof(*hw), GFP_KERNEL);
	if (!hw)
		return -ENOMEM;

	hw->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hw->base))
		return PTR_ERR(hw->base);

	clk = devm_clk_get_optional_enabled(&pdev->dev, NULL);
	if (IS_ERR(clk))
		return PTR_ERR(clk);
	hw->clk_rate = clk ? clk_get_rate(clk) : 1000000;

	hw->wdd.info = &harbor_wdt_info;
	hw->wdd.ops = &harbor_wdt_ops;
	hw->wdd.min_timeout = 1;
	hw->wdd.max_timeout = 0xFFFFFFFF / hw->clk_rate;
	hw->wdd.timeout = 30;
	hw->wdd.parent = &pdev->dev;

	watchdog_set_drvdata(&hw->wdd, hw);
	watchdog_init_timeout(&hw->wdd, 0, &pdev->dev);

	return devm_watchdog_register_device(&pdev->dev, &hw->wdd);
}

static const struct of_device_id harbor_wdt_of_match[] = {
    {.compatible = "harbor,watchdog"}, {}};
MODULE_DEVICE_TABLE(of, harbor_wdt_of_match);

static struct platform_driver harbor_wdt_driver = {
    .probe = harbor_wdt_probe,
    .driver =
	{
	    .name = "harbor-wdt",
	    .of_match_table = harbor_wdt_of_match,
	},
};
module_platform_driver(harbor_wdt_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor Watchdog timer driver");
MODULE_LICENSE("GPL");
