// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor Media Engine driver
 *
 * Uses V4L2 M2M when CONFIG_V4L2_MEM2MEM_DEV is enabled for
 * out-of-the-box FFmpeg/GStreamer/Chromium support.
 * Falls back to miscdevice + ioctl when V4L2 M2M is not available.
 *
 * Each register sits in its own 8-byte slot: the controller sits on a
 * byte-addressed fabric that decodes the low bits of the byte address, like
 * every other Harbor peripheral. 4-byte spacing aliases every register onto its
 * neighbour.
 *
 * Global registers:
 *   0x000: ENGINE_CTRL   0x008: ENGINE_STATUS  0x010: ENGINE_CAPS
 *   0x018: ENGINE_VER    0x020: INT_STATUS     0x028: INT_ENABLE
 *
 * Per-session (0x100 + session*0x100):
 *   +0x00: SESS_CTRL     +0x08: SESS_STATUS   +0x10: SESS_SRC_ADDR
 *   +0x18: SESS_SRC_SIZE +0x20: SESS_DST_ADDR +0x28: SESS_DST_SIZE
 *   +0x30: SESS_WIDTH    +0x38: SESS_HEIGHT   +0x40: SESS_PIXEL_FMT
 *   +0x48: SESS_BITRATE  +0x50: SESS_QP       +0x58: SESS_RC_MODE
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/miscdevice.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/interrupt.h>
#include <linux/fs.h>

#if IS_ENABLED(CONFIG_V4L2_MEM2MEM_DEV)
#include <media/v4l2-device.h>
#include <media/v4l2-mem2mem.h>
#include <media/v4l2-ioctl.h>
#define HARBOR_MEDIA_V4L2 1
#endif

#define HARBOR_MEDIA_ENGINE_CTRL   0x000
#define HARBOR_MEDIA_ENGINE_STATUS 0x008
#define HARBOR_MEDIA_ENGINE_CAPS   0x010
#define HARBOR_MEDIA_INT_STATUS	   0x020
#define HARBOR_MEDIA_INT_ENABLE	   0x028

#define HARBOR_MEDIA_SESS_BASE	   0x100
#define HARBOR_MEDIA_SESS_STRIDE   0x100
#define HARBOR_MEDIA_SESS_CTRL	   0x00
#define HARBOR_MEDIA_SESS_STATUS   0x08
#define HARBOR_MEDIA_SESS_SRC_ADDR 0x10

#define HARBOR_SESS_START  BIT(0)
#define HARBOR_SESS_DECODE (0 << 4)
#define HARBOR_SESS_ENCODE (1 << 4)

struct harbor_media {
	void __iomem *base;
	struct device *dev;
	int irq;
	u32 caps;
#ifdef HARBOR_MEDIA_V4L2
	struct v4l2_device v4l2_dev;
	struct v4l2_m2m_dev *m2m_dev;
	struct video_device vfd;
#else
	struct miscdevice misc;
#endif
};

static inline void __iomem *sess_reg(struct harbor_media *hm, int sess)
{
	return hm->base + HARBOR_MEDIA_SESS_BASE +
	       sess * HARBOR_MEDIA_SESS_STRIDE;
}

static irqreturn_t harbor_media_irq(int irq, void *data)
{
	struct harbor_media *hm = data;
	u32 status;

	status = readl(hm->base + HARBOR_MEDIA_INT_STATUS);
	if (!status)
		return IRQ_NONE;

	writel(status, hm->base + HARBOR_MEDIA_INT_STATUS);
	return IRQ_HANDLED;
}

#ifdef HARBOR_MEDIA_V4L2
/* ---- V4L2 M2M path ---- */

struct harbor_media_ctx {
	struct v4l2_fh fh;
	struct harbor_media *hm;
	int session;
};

static void harbor_media_device_run(void *priv)
{
	struct harbor_media_ctx *ctx = priv;
	struct harbor_media *hm = ctx->hm;

	writel(HARBOR_SESS_START | HARBOR_SESS_DECODE,
	       sess_reg(hm, ctx->session) + HARBOR_MEDIA_SESS_CTRL);
}

static const struct v4l2_m2m_ops harbor_media_m2m_ops = {
    .device_run = harbor_media_device_run,
};

static int harbor_media_v4l2_open(struct file *file)
{
	struct harbor_media *hm = video_drvdata(file);
	struct harbor_media_ctx *ctx;

	ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;

	ctx->hm = hm;
	ctx->session = 0;

	v4l2_fh_init(&ctx->fh, &hm->vfd);
	ctx->fh.m2m_ctx = v4l2_m2m_ctx_init(hm->m2m_dev, ctx, NULL);
	if (IS_ERR(ctx->fh.m2m_ctx)) {
		int ret = PTR_ERR(ctx->fh.m2m_ctx);
		v4l2_fh_exit(&ctx->fh);
		kfree(ctx);
		return ret;
	}

	v4l2_fh_add(&ctx->fh, file);
	return 0;
}

static int harbor_media_v4l2_release(struct file *file)
{
	struct harbor_media_ctx *ctx =
	    container_of(file->private_data, struct harbor_media_ctx, fh);

	v4l2_m2m_ctx_release(ctx->fh.m2m_ctx);
	v4l2_fh_del(&ctx->fh, file);
	v4l2_fh_exit(&ctx->fh);
	kfree(ctx);
	return 0;
}

static const struct v4l2_file_operations harbor_media_v4l2_fops = {
    .owner = THIS_MODULE,
    .open = harbor_media_v4l2_open,
    .release = harbor_media_v4l2_release,
    .poll = v4l2_m2m_fop_poll,
    .unlocked_ioctl = video_ioctl2,
    .mmap = v4l2_m2m_fop_mmap,
};

static const struct v4l2_ioctl_ops harbor_media_ioctl_ops = {};

static int harbor_media_register_v4l2(struct harbor_media *hm)
{
	int ret;

	ret = v4l2_device_register(hm->dev, &hm->v4l2_dev);
	if (ret)
		return ret;

	hm->m2m_dev = v4l2_m2m_init(&harbor_media_m2m_ops);
	if (IS_ERR(hm->m2m_dev)) {
		ret = PTR_ERR(hm->m2m_dev);
		v4l2_device_unregister(&hm->v4l2_dev);
		return ret;
	}

	hm->vfd.fops = &harbor_media_v4l2_fops;
	hm->vfd.ioctl_ops = &harbor_media_ioctl_ops;
	hm->vfd.v4l2_dev = &hm->v4l2_dev;
	hm->vfd.vfl_dir = VFL_DIR_M2M;
	hm->vfd.device_caps = V4L2_CAP_VIDEO_M2M | V4L2_CAP_STREAMING;
	snprintf(hm->vfd.name, sizeof(hm->vfd.name), "harbor-media");
	video_set_drvdata(&hm->vfd, hm);

	ret = video_register_device(&hm->vfd, VFL_TYPE_VIDEO, -1);
	if (ret) {
		v4l2_m2m_release(hm->m2m_dev);
		v4l2_device_unregister(&hm->v4l2_dev);
		return ret;
	}

	return 0;
}

static void harbor_media_unregister_v4l2(struct harbor_media *hm)
{
	video_unregister_device(&hm->vfd);
	v4l2_m2m_release(hm->m2m_dev);
	v4l2_device_unregister(&hm->v4l2_dev);
}

#else
/* ---- Fallback miscdevice path ---- */

static int harbor_media_misc_open(struct inode *inode, struct file *file)
{
	return 0;
}

static long harbor_media_misc_ioctl(struct file *file, unsigned int cmd,
				    unsigned long arg)
{
	return -ENOTTY;
}

static const struct file_operations harbor_media_misc_fops = {
    .owner = THIS_MODULE,
    .open = harbor_media_misc_open,
    .unlocked_ioctl = harbor_media_misc_ioctl,
};

static int harbor_media_register_misc(struct harbor_media *hm)
{
	hm->misc.minor = MISC_DYNAMIC_MINOR;
	hm->misc.name = "harbor-media";
	hm->misc.fops = &harbor_media_misc_fops;
	hm->misc.parent = hm->dev;
	return misc_register(&hm->misc);
}

static void harbor_media_unregister_misc(struct harbor_media *hm)
{
	misc_deregister(&hm->misc);
}
#endif /* HARBOR_MEDIA_V4L2 */

static int harbor_media_probe(struct platform_device *pdev)
{
	struct harbor_media *hm;
	int ret;

	hm = devm_kzalloc(&pdev->dev, sizeof(*hm), GFP_KERNEL);
	if (!hm)
		return -ENOMEM;

	hm->dev = &pdev->dev;

	hm->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hm->base))
		return PTR_ERR(hm->base);

	hm->irq = platform_get_irq(pdev, 0);
	if (hm->irq >= 0) {
		ret = devm_request_irq(&pdev->dev, hm->irq, harbor_media_irq, 0,
				       "harbor-media", hm);
		if (ret)
			return ret;
	}

	writel(1, hm->base + HARBOR_MEDIA_ENGINE_CTRL);
	hm->caps = readl(hm->base + HARBOR_MEDIA_ENGINE_CAPS);
	writel(0xFF, hm->base + HARBOR_MEDIA_INT_ENABLE);

#ifdef HARBOR_MEDIA_V4L2
	ret = harbor_media_register_v4l2(hm);
#else
	ret = harbor_media_register_misc(hm);
#endif
	if (ret)
		return ret;

	dev_info(&pdev->dev, "Harbor Media Engine (caps=0x%08x%s)\n", hm->caps,
#ifdef HARBOR_MEDIA_V4L2
		 ", V4L2 M2M"
#else
		 ", miscdev"
#endif
	);

	platform_set_drvdata(pdev, hm);
	return 0;
}

static void harbor_media_remove(struct platform_device *pdev)
{
	struct harbor_media *hm = platform_get_drvdata(pdev);

#ifdef HARBOR_MEDIA_V4L2
	harbor_media_unregister_v4l2(hm);
#else
	harbor_media_unregister_misc(hm);
#endif
}

static const struct of_device_id harbor_media_of_match[] = {
    {.compatible = "harbor,media-engine"}, {}};
MODULE_DEVICE_TABLE(of, harbor_media_of_match);

static struct platform_driver harbor_media_driver = {
    .probe = harbor_media_probe,
    .remove = harbor_media_remove,
    .driver =
	{
	    .name = "harbor-media",
	    .of_match_table = harbor_media_of_match,
	},
};
module_platform_driver(harbor_media_driver);

MODULE_AUTHOR("Midstall Software");
MODULE_DESCRIPTION("Harbor Media Engine driver");
MODULE_LICENSE("GPL");
