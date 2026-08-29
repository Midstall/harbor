// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor PWM/Timer driver
 *
 * Each register sits in its own 8-byte slot: the controller sits on a
 * byte-addressed fabric that decodes the low bits of the byte address, like
 * every other Harbor peripheral. 4-byte spacing aliases every register onto its
 * neighbour.
 *
 * Per-channel registers (0x20 + ch*0x20):
 *   +0x00: CTRL     +0x08: COUNT    +0x10: COMPARE   +0x18: DUTY
 *
 * Global: 0x00: GLOBAL_CTRL  0x08: INT_STATUS
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/pwm.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/clk.h>

#define HARBOR_PWM_GLOBAL_CTRL 0x00
#define HARBOR_PWM_INT_STATUS  0x08
#define HARBOR_PWM_CH_BASE     0x20
#define HARBOR_PWM_CH_STRIDE   0x20

#define HARBOR_PWM_CH_CTRL    0x00
#define HARBOR_PWM_CH_COUNT   0x08
#define HARBOR_PWM_CH_COMPARE 0x10
#define HARBOR_PWM_CH_DUTY    0x18

struct harbor_pwm {
	void __iomem *base;
	unsigned long clk_rate;
};

static int harbor_pwm_apply(struct pwm_chip *chip, struct pwm_device *pwm,
			    const struct pwm_state *state)
{
	struct harbor_pwm *hp = pwmchip_get_drvdata(chip);
	void __iomem *ch =
	    hp->base + HARBOR_PWM_CH_BASE + pwm->hwpwm * HARBOR_PWM_CH_STRIDE;
	u32 period, duty;

	if (!state->enabled) {
		writel(0, ch + HARBOR_PWM_CH_CTRL);
		return 0;
	}

	if (hp->clk_rate == 0)
		return -EINVAL;

	period = (u32)div_u64((u64)state->period * hp->clk_rate, NSEC_PER_SEC);
	duty =
	    (u32)div_u64((u64)state->duty_cycle * hp->clk_rate, NSEC_PER_SEC);

	writel(period, ch + HARBOR_PWM_CH_COMPARE);
	writel(duty, ch + HARBOR_PWM_CH_DUTY);
	/* Mode 2 = auto-reload, enable, IRQ off */
	writel(0x05, ch + HARBOR_PWM_CH_CTRL);

	return 0;
}

static int harbor_pwm_get_state(struct pwm_chip *chip, struct pwm_device *pwm,
				struct pwm_state *state)
{
	struct harbor_pwm *hp = pwmchip_get_drvdata(chip);
	void __iomem *ch =
	    hp->base + HARBOR_PWM_CH_BASE + pwm->hwpwm * HARBOR_PWM_CH_STRIDE;
	u32 ctrl, period, duty;

	ctrl = readl(ch + HARBOR_PWM_CH_CTRL);
	period = readl(ch + HARBOR_PWM_CH_COMPARE);
	duty = readl(ch + HARBOR_PWM_CH_DUTY);

	state->enabled = !!(ctrl & 1);
	if (hp->clk_rate) {
		state->period =
		    div_u64((u64)period * NSEC_PER_SEC, hp->clk_rate);
		state->duty_cycle =
		    div_u64((u64)duty * NSEC_PER_SEC, hp->clk_rate);
	}
	state->polarity = PWM_POLARITY_NORMAL;

	return 0;
}

static const struct pwm_ops harbor_pwm_ops = {
    .apply = harbor_pwm_apply,
    .get_state = harbor_pwm_get_state,
};

static int harbor_pwm_probe(struct platform_device *pdev)
{
	struct harbor_pwm *hp;
	struct pwm_chip *chip;
	struct clk *clk;
	u32 num_channels = 4;

	device_property_read_u32(&pdev->dev, "num-channels", &num_channels);

	chip = devm_pwmchip_alloc(&pdev->dev, num_channels, sizeof(*hp));
	if (IS_ERR(chip))
		return PTR_ERR(chip);

	hp = pwmchip_get_drvdata(chip);

	hp->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hp->base))
		return PTR_ERR(hp->base);

	clk = devm_clk_get_optional_enabled(&pdev->dev, NULL);
	if (IS_ERR(clk))
		return PTR_ERR(clk);
	hp->clk_rate = clk ? clk_get_rate(clk) : 0;

	chip->ops = &harbor_pwm_ops;

	/* Enable global */
	writel(1, hp->base + HARBOR_PWM_GLOBAL_CTRL);

	return devm_pwmchip_add(&pdev->dev, chip);
}

static const struct of_device_id harbor_pwm_of_match[] = {
    {.compatible = "harbor,pwm-timer"}, {}};
MODULE_DEVICE_TABLE(of, harbor_pwm_of_match);

static struct platform_driver harbor_pwm_driver = {
    .probe = harbor_pwm_probe,
    .driver =
	{
	    .name = "harbor-pwm",
	    .of_match_table = harbor_pwm_of_match,
	},
};
module_platform_driver(harbor_pwm_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor PWM/Timer driver");
MODULE_LICENSE("GPL");
