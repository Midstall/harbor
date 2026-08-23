// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor Audio Controller driver (ALSA SoC / ASoC)
 *
 * Each register sits in its own 8-byte slot: the controller sits on a
 * byte-addressed fabric that decodes the low bits of the byte address, like
 * every other Harbor peripheral. 4-byte spacing aliases every register onto its
 * neighbour.
 *
 * Registers:
 *   0x00: CTRL        0x08: STATUS      0x10: CLK_CFG
 *   0x18: FORMAT      0x20: TX_CTRL     0x28: RX_CTRL
 *   0x30: TX_DMA_ADDR 0x38: TX_DMA_SIZE 0x40: TX_DMA_WR
 *   0x48: TX_DMA_RD   0x50: RX_DMA_ADDR 0x58: RX_DMA_SIZE
 *   0x60: RX_DMA_WR   0x68: RX_DMA_RD   0x70: INT_STATUS
 *   0x78: INT_ENABLE  0x80: VOLUME_L    0x88: VOLUME_R
 *   0x90: MUTE
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/interrupt.h>
#include <sound/soc.h>
#include <sound/pcm.h>
#include <sound/pcm_params.h>

#define HARBOR_AUDIO_CTRL	 0x00
#define HARBOR_AUDIO_STATUS	 0x08
#define HARBOR_AUDIO_CLK_CFG	 0x10
#define HARBOR_AUDIO_FORMAT	 0x18
#define HARBOR_AUDIO_TX_CTRL	 0x20
#define HARBOR_AUDIO_RX_CTRL	 0x28
#define HARBOR_AUDIO_TX_DMA_ADDR 0x30
#define HARBOR_AUDIO_TX_DMA_SIZE 0x38
#define HARBOR_AUDIO_INT_STATUS	 0x70
#define HARBOR_AUDIO_INT_ENABLE	 0x78
#define HARBOR_AUDIO_VOLUME_L	 0x80
#define HARBOR_AUDIO_VOLUME_R	 0x88
#define HARBOR_AUDIO_MUTE	 0x90

struct harbor_audio {
	void __iomem *base;
	struct device *dev;
	int irq;
};

static int harbor_audio_dai_hw_params(struct snd_pcm_substream *substream,
				      struct snd_pcm_hw_params *params,
				      struct snd_soc_dai *dai)
{
	struct harbor_audio *ha = snd_soc_dai_get_drvdata(dai);
	u32 format = 0;

	/* Sample format */
	switch (params_format(params)) {
	case SNDRV_PCM_FORMAT_S16_LE:
		format |= 0;
		break;
	case SNDRV_PCM_FORMAT_S24_LE:
		format |= 1;
		break;
	case SNDRV_PCM_FORMAT_S32_LE:
		format |= 2;
		break;
	default:
		return -EINVAL;
	}

	/* Channels */
	format |= (params_channels(params) - 1) << 8;

	writel(format, ha->base + HARBOR_AUDIO_FORMAT);
	return 0;
}

static int harbor_audio_dai_trigger(struct snd_pcm_substream *substream,
				    int cmd, struct snd_soc_dai *dai)
{
	struct harbor_audio *ha = snd_soc_dai_get_drvdata(dai);

	switch (cmd) {
	case SNDRV_PCM_TRIGGER_START:
	case SNDRV_PCM_TRIGGER_RESUME:
		if (substream->stream == SNDRV_PCM_STREAM_PLAYBACK)
			writel(1, ha->base + HARBOR_AUDIO_TX_CTRL);
		else
			writel(1, ha->base + HARBOR_AUDIO_RX_CTRL);
		break;
	case SNDRV_PCM_TRIGGER_STOP:
	case SNDRV_PCM_TRIGGER_SUSPEND:
		if (substream->stream == SNDRV_PCM_STREAM_PLAYBACK)
			writel(0, ha->base + HARBOR_AUDIO_TX_CTRL);
		else
			writel(0, ha->base + HARBOR_AUDIO_RX_CTRL);
		break;
	default:
		return -EINVAL;
	}

	return 0;
}

static const struct snd_soc_dai_ops harbor_audio_dai_ops = {
    .hw_params = harbor_audio_dai_hw_params,
    .trigger = harbor_audio_dai_trigger,
};

static struct snd_soc_dai_driver harbor_audio_dai = {
    .name = "harbor-audio-dai",
    .playback =
	{
	    .stream_name = "Playback",
	    .channels_min = 1,
	    .channels_max = 8,
	    .rates = SNDRV_PCM_RATE_8000_192000,
	    .formats = SNDRV_PCM_FMTBIT_S16_LE | SNDRV_PCM_FMTBIT_S24_LE |
		       SNDRV_PCM_FMTBIT_S32_LE,
	},
    .capture =
	{
	    .stream_name = "Capture",
	    .channels_min = 1,
	    .channels_max = 8,
	    .rates = SNDRV_PCM_RATE_8000_192000,
	    .formats = SNDRV_PCM_FMTBIT_S16_LE | SNDRV_PCM_FMTBIT_S24_LE |
		       SNDRV_PCM_FMTBIT_S32_LE,
	},
    .ops = &harbor_audio_dai_ops,
};

static const struct snd_soc_component_driver harbor_audio_component = {
    .name = "harbor-audio",
};

static irqreturn_t harbor_audio_irq(int irq, void *data)
{
	struct harbor_audio *ha = data;
	u32 status;

	status = readl(ha->base + HARBOR_AUDIO_INT_STATUS);
	if (!status)
		return IRQ_NONE;

	writel(status, ha->base + HARBOR_AUDIO_INT_STATUS);
	return IRQ_HANDLED;
}

static int harbor_audio_probe(struct platform_device *pdev)
{
	struct harbor_audio *ha;
	int ret;

	ha = devm_kzalloc(&pdev->dev, sizeof(*ha), GFP_KERNEL);
	if (!ha)
		return -ENOMEM;

	ha->dev = &pdev->dev;

	ha->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(ha->base))
		return PTR_ERR(ha->base);

	ha->irq = platform_get_irq(pdev, 0);
	if (ha->irq >= 0) {
		ret = devm_request_irq(&pdev->dev, ha->irq, harbor_audio_irq, 0,
				       "harbor-audio", ha);
		if (ret)
			return ret;
	}

	/* Enable controller */
	writel(1, ha->base + HARBOR_AUDIO_CTRL);
	writel(0xFF, ha->base + HARBOR_AUDIO_INT_ENABLE);

	/* Default volume */
	writel(255, ha->base + HARBOR_AUDIO_VOLUME_L);
	writel(255, ha->base + HARBOR_AUDIO_VOLUME_R);

	platform_set_drvdata(pdev, ha);

	return devm_snd_soc_register_component(
	    &pdev->dev, &harbor_audio_component, &harbor_audio_dai, 1);
}

static const struct of_device_id harbor_audio_of_match[] = {
    {.compatible = "harbor,audio"}, {}};
MODULE_DEVICE_TABLE(of, harbor_audio_of_match);

static struct platform_driver harbor_audio_driver = {
    .probe = harbor_audio_probe,
    .driver =
	{
	    .name = "harbor-audio",
	    .of_match_table = harbor_audio_of_match,
	},
};
module_platform_driver(harbor_audio_driver);

MODULE_AUTHOR("Midstall Software");
MODULE_DESCRIPTION("Harbor Audio Controller driver");
MODULE_LICENSE("GPL");
