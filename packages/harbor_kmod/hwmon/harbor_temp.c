// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor temperature sensor driver (hwmon)
 *
 * Registers:
 *   0x00: CTRL       0x08: STATUS     0x10: TEMP_RAW
 *   0x18: TEMP_C     0x20: ALARM_HI   0x28: ALARM_LO
 *   0x30: INT_STATUS 0x38: INT_ENABLE
 *
 * TEMP_C is in millidegrees Celsius (signed 32-bit).
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/hwmon.h>
#include <linux/io.h>
#include <linux/of.h>

#define HARBOR_TEMP_CTRL       0x00
#define HARBOR_TEMP_STATUS     0x08
#define HARBOR_TEMP_RAW	       0x10
#define HARBOR_TEMP_C	       0x18
#define HARBOR_TEMP_ALARM_HI   0x20
#define HARBOR_TEMP_ALARM_LO   0x28
#define HARBOR_TEMP_INT_STATUS 0x30
#define HARBOR_TEMP_INT_ENABLE 0x38

#define HARBOR_TEMP_CTRL_EN   BIT(0)
#define HARBOR_TEMP_CTRL_CONT BIT(1)

#define HARBOR_TEMP_STATUS_VALID    BIT(0)
#define HARBOR_TEMP_STATUS_OVERTEMP BIT(1)

struct harbor_temp {
	void __iomem *base;
};

static int harbor_temp_read(struct device *dev, enum hwmon_sensor_types type,
			    u32 attr, int channel, long *val)
{
	struct harbor_temp *ht = dev_get_drvdata(dev);

	if (type != hwmon_temp)
		return -EOPNOTSUPP;

	switch (attr) {
	case hwmon_temp_input:
		*val = (s32)readl(ht->base + HARBOR_TEMP_C);
		return 0;
	case hwmon_temp_max:
		*val = (s32)readl(ht->base + HARBOR_TEMP_ALARM_HI);
		return 0;
	case hwmon_temp_min:
		*val = (s32)readl(ht->base + HARBOR_TEMP_ALARM_LO);
		return 0;
	case hwmon_temp_max_alarm:
		*val = !!(readl(ht->base + HARBOR_TEMP_STATUS) &
			  HARBOR_TEMP_STATUS_OVERTEMP);
		return 0;
	default:
		return -EOPNOTSUPP;
	}
}

static int harbor_temp_write(struct device *dev, enum hwmon_sensor_types type,
			     u32 attr, int channel, long val)
{
	struct harbor_temp *ht = dev_get_drvdata(dev);

	if (type != hwmon_temp)
		return -EOPNOTSUPP;

	switch (attr) {
	case hwmon_temp_max:
		writel((s32)val, ht->base + HARBOR_TEMP_ALARM_HI);
		return 0;
	case hwmon_temp_min:
		writel((s32)val, ht->base + HARBOR_TEMP_ALARM_LO);
		return 0;
	default:
		return -EOPNOTSUPP;
	}
}

static umode_t harbor_temp_is_visible(const void *data,
				      enum hwmon_sensor_types type, u32 attr,
				      int channel)
{
	if (type != hwmon_temp)
		return 0;

	switch (attr) {
	case hwmon_temp_input:
	case hwmon_temp_max_alarm:
		return 0444;
	case hwmon_temp_max:
	case hwmon_temp_min:
		return 0644;
	default:
		return 0;
	}
}

static const struct hwmon_channel_info *harbor_temp_info[] = {
    HWMON_CHANNEL_INFO(temp, HWMON_T_INPUT | HWMON_T_MAX | HWMON_T_MIN |
				 HWMON_T_MAX_ALARM),
    NULL};

static const struct hwmon_ops harbor_temp_ops = {
    .is_visible = harbor_temp_is_visible,
    .read = harbor_temp_read,
    .write = harbor_temp_write,
};

static const struct hwmon_chip_info harbor_temp_chip_info = {
    .ops = &harbor_temp_ops,
    .info = harbor_temp_info,
};

static int harbor_temp_probe(struct platform_device *pdev)
{
	struct harbor_temp *ht;
	struct device *hwmon;

	ht = devm_kzalloc(&pdev->dev, sizeof(*ht), GFP_KERNEL);
	if (!ht)
		return -ENOMEM;

	ht->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(ht->base))
		return PTR_ERR(ht->base);

	/* Enable sensor in continuous mode */
	writel(HARBOR_TEMP_CTRL_EN | HARBOR_TEMP_CTRL_CONT,
	       ht->base + HARBOR_TEMP_CTRL);

	hwmon = devm_hwmon_device_register_with_info(
	    &pdev->dev, "harbor_temp", ht, &harbor_temp_chip_info, NULL);
	return PTR_ERR_OR_ZERO(hwmon);
}

static const struct of_device_id harbor_temp_of_match[] = {
    {.compatible = "harbor,temp-sensor"}, {}};
MODULE_DEVICE_TABLE(of, harbor_temp_of_match);

static struct platform_driver harbor_temp_driver = {
    .probe = harbor_temp_probe,
    .driver =
	{
	    .name = "harbor-temp",
	    .of_match_table = harbor_temp_of_match,
	},
};
module_platform_driver(harbor_temp_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor temperature sensor driver");
MODULE_LICENSE("GPL");
