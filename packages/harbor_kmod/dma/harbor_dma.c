// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor DMA controller driver
 *
 * Each register sits in its own 8-byte slot: the controller sits on a
 * byte-addressed fabric that decodes the low bits of the byte address, like
 * every other Harbor peripheral. 4-byte spacing aliases every register onto its
 * neighbour. A block is 8 slots (0x40).
 *
 * Per-channel registers (0x40 + ch*0x40):
 *   +0x00: CH_CTRL   +0x08: CH_STATUS  +0x10: CH_SRC
 *   +0x18: CH_DST    +0x20: CH_LEN
 *
 * Global registers:
 *   0x00: CTRL       0x08: INT_STATUS   0x10: INT_ENABLE
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/dmaengine.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/interrupt.h>

#define HARBOR_DMA_CTRL	      0x000
#define HARBOR_DMA_INT_STATUS 0x008
#define HARBOR_DMA_INT_ENABLE 0x010
#define HARBOR_DMA_CH_BASE    0x40
#define HARBOR_DMA_CH_STRIDE  0x40

#define HARBOR_DMA_CH_CTRL   0x00
#define HARBOR_DMA_CH_STATUS 0x08
#define HARBOR_DMA_CH_SRC    0x10
#define HARBOR_DMA_CH_DST    0x18
#define HARBOR_DMA_CH_LEN    0x20

struct harbor_dma {
	void __iomem *base;
	struct dma_device dma_dev;
	int irq;
	int num_channels;
};

static int harbor_dma_probe(struct platform_device *pdev)
{
	struct harbor_dma *hd;
	u32 num_channels = 4;

	hd = devm_kzalloc(&pdev->dev, sizeof(*hd), GFP_KERNEL);
	if (!hd)
		return -ENOMEM;

	hd->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hd->base))
		return PTR_ERR(hd->base);

	device_property_read_u32(&pdev->dev, "dma-channels", &num_channels);
	hd->num_channels = num_channels;

	/* Enable controller */
	writel(1, hd->base + HARBOR_DMA_CTRL);

	platform_set_drvdata(pdev, hd);
	dev_info(&pdev->dev, "Harbor DMA with %d channels\n", num_channels);
	return 0;
}

static const struct of_device_id harbor_dma_of_match[] = {
    {.compatible = "harbor,dma"}, {}};
MODULE_DEVICE_TABLE(of, harbor_dma_of_match);

static struct platform_driver harbor_dma_driver = {
    .probe = harbor_dma_probe,
    .driver =
	{
	    .name = "harbor-dma",
	    .of_match_table = harbor_dma_of_match,
	},
};
module_platform_driver(harbor_dma_driver);

MODULE_AUTHOR("Midstall Software");
MODULE_DESCRIPTION("Harbor DMA controller driver");
MODULE_LICENSE("GPL");
