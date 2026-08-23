// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor eFuse (OTP) controller driver (nvmem)
 *
 * Registers:
 *   0x00: CTRL       0x08: STATUS     0x10: ADDR
 *   0x18: RDATA      0x20: WDATA      0x28: LOCK
 *   0x30: TIMING     0x38: KEY
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/nvmem-provider.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/delay.h>

#define HARBOR_EFUSE_CTRL   0x00
#define HARBOR_EFUSE_STATUS 0x08
#define HARBOR_EFUSE_ADDR   0x10
#define HARBOR_EFUSE_RDATA  0x18
#define HARBOR_EFUSE_WDATA  0x20
#define HARBOR_EFUSE_LOCK   0x28
#define HARBOR_EFUSE_TIMING 0x30
#define HARBOR_EFUSE_KEY    0x38

#define HARBOR_EFUSE_STATUS_BUSY BIT(0)
#define HARBOR_EFUSE_STATUS_DONE BIT(1)
#define HARBOR_EFUSE_STATUS_ERR	 BIT(2)

struct harbor_efuse {
	void __iomem *base;
	int total_bits;
	int bits_per_word;
	u32 unlock_key;
};

static int harbor_efuse_wait(struct harbor_efuse *he)
{
	u32 status;
	int timeout = 10000;

	while (timeout--) {
		status = readl(he->base + HARBOR_EFUSE_STATUS);
		if (!(status & HARBOR_EFUSE_STATUS_BUSY))
			break;
		udelay(1);
	}

	if (status & HARBOR_EFUSE_STATUS_ERR)
		return -EIO;
	if (status & HARBOR_EFUSE_STATUS_BUSY)
		return -ETIMEDOUT;

	return 0;
}

static int harbor_efuse_read(void *context, unsigned int offset, void *val,
			     size_t bytes)
{
	struct harbor_efuse *he = context;
	u32 *buf = val;
	int word_offset = offset / (he->bits_per_word / 8);
	int words = bytes / (he->bits_per_word / 8);
	int i, ret;

	for (i = 0; i < words; i++) {
		writel(word_offset + i, he->base + HARBOR_EFUSE_ADDR);
		writel(BIT(0), he->base + HARBOR_EFUSE_CTRL); /* read start */

		ret = harbor_efuse_wait(he);
		if (ret)
			return ret;

		buf[i] = readl(he->base + HARBOR_EFUSE_RDATA);
	}

	return 0;
}

static int harbor_efuse_write(void *context, unsigned int offset, void *val,
			      size_t bytes)
{
	struct harbor_efuse *he = context;
	u32 *buf = val;
	int word_offset = offset / (he->bits_per_word / 8);
	int words = bytes / (he->bits_per_word / 8);
	int i, ret;

	/* Unlock programming */
	writel(he->unlock_key, he->base + HARBOR_EFUSE_KEY);

	for (i = 0; i < words; i++) {
		writel(word_offset + i, he->base + HARBOR_EFUSE_ADDR);
		writel(buf[i], he->base + HARBOR_EFUSE_WDATA);
		writel(BIT(1),
		       he->base + HARBOR_EFUSE_CTRL); /* program start */

		ret = harbor_efuse_wait(he);
		if (ret) {
			/* Re-lock on error */
			writel(0, he->base + HARBOR_EFUSE_KEY);
			return ret;
		}
	}

	/* Re-lock */
	writel(0, he->base + HARBOR_EFUSE_KEY);
	return 0;
}

static int harbor_efuse_probe(struct platform_device *pdev)
{
	struct harbor_efuse *he;
	struct nvmem_config cfg = {};
	struct nvmem_device *nvmem;
	u32 total_bits = 256;
	u32 bits_per_word = 32;

	he = devm_kzalloc(&pdev->dev, sizeof(*he), GFP_KERNEL);
	if (!he)
		return -ENOMEM;

	he->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(he->base))
		return PTR_ERR(he->base);

	device_property_read_u32(&pdev->dev, "harbor,total-bits", &total_bits);
	device_property_read_u32(&pdev->dev, "harbor,bits-per-word",
				 &bits_per_word);

	he->total_bits = total_bits;
	he->bits_per_word = bits_per_word;
	he->unlock_key = 0x4F545021; /* default "OTP!" */
	device_property_read_u32(&pdev->dev, "harbor,unlock-key",
				 &he->unlock_key);

	cfg.name = "harbor-efuse";
	cfg.dev = &pdev->dev;
	cfg.priv = he;
	cfg.reg_read = harbor_efuse_read;
	cfg.reg_write = harbor_efuse_write;
	cfg.size = total_bits / 8;
	cfg.word_size = bits_per_word / 8;
	cfg.stride = bits_per_word / 8;
	cfg.type = NVMEM_TYPE_OTP;
	cfg.read_only = false;

	nvmem = devm_nvmem_register(&pdev->dev, &cfg);
	return PTR_ERR_OR_ZERO(nvmem);
}

static const struct of_device_id harbor_efuse_of_match[] = {
    {.compatible = "harbor,efuse"}, {.compatible = "harbor,otp"}, {}};
MODULE_DEVICE_TABLE(of, harbor_efuse_of_match);

static struct platform_driver harbor_efuse_driver = {
    .probe = harbor_efuse_probe,
    .driver =
	{
	    .name = "harbor-efuse",
	    .of_match_table = harbor_efuse_of_match,
	},
};
module_platform_driver(harbor_efuse_driver);

MODULE_AUTHOR("Midstall Software");
MODULE_DESCRIPTION("Harbor eFuse OTP controller driver");
MODULE_LICENSE("GPL");
