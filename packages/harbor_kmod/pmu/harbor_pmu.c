// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor Power Management Unit driver
 *
 * Each register sits in its own 8-byte slot: the controller sits on a
 * byte-addressed fabric that decodes the low bits of the byte address, like
 * every other Harbor peripheral. 4-byte spacing aliases every register onto its
 * neighbour.
 *
 * Global registers:
 *   0x00: CTRL         0x08: STATUS
 *   0x10: WAKEUP_EN    0x18: WAKEUP_STATUS
 *
 * Per-domain (0x40 + domain*0x20):
 *   +0x00: DOM_CTRL    +0x08: DOM_STATUS   +0x10: DOM_ISO
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/pm_domain.h>
#include <linux/io.h>
#include <linux/of.h>

#define HARBOR_PMU_CTRL		 0x00
#define HARBOR_PMU_STATUS	 0x08
#define HARBOR_PMU_WAKEUP_EN	 0x10
#define HARBOR_PMU_WAKEUP_STATUS 0x18
#define HARBOR_PMU_DOM_BASE	 0x40
#define HARBOR_PMU_DOM_STRIDE	 0x20
#define HARBOR_PMU_DOM_CTRL	 0x00
#define HARBOR_PMU_DOM_STATUS	 0x08
#define HARBOR_PMU_DOM_ISO	 0x10

#define HARBOR_PMU_MAX_DOMAINS 8

#define HARBOR_PMU_DOM_OFF 0x00
#define HARBOR_PMU_DOM_RET 0x01
#define HARBOR_PMU_DOM_ON  0x03

struct harbor_pmu_domain {
	struct generic_pm_domain genpd;
	void __iomem *reg;
	int index;
};

struct harbor_pmu {
	void __iomem *base;
	struct device *dev;
	int num_domains;
	struct harbor_pmu_domain domains[HARBOR_PMU_MAX_DOMAINS];
	struct genpd_onecell_data pd_data;
	struct generic_pm_domain *pd_list[HARBOR_PMU_MAX_DOMAINS];
};

static int harbor_pmu_domain_power_on(struct generic_pm_domain *domain)
{
	struct harbor_pmu_domain *pd =
	    container_of(domain, struct harbor_pmu_domain, genpd);

	writel(0, pd->reg + HARBOR_PMU_DOM_ISO);
	writel(HARBOR_PMU_DOM_ON, pd->reg + HARBOR_PMU_DOM_CTRL);
	return 0;
}

static int harbor_pmu_domain_power_off(struct generic_pm_domain *domain)
{
	struct harbor_pmu_domain *pd =
	    container_of(domain, struct harbor_pmu_domain, genpd);

	writel(1, pd->reg + HARBOR_PMU_DOM_ISO);
	writel(HARBOR_PMU_DOM_OFF, pd->reg + HARBOR_PMU_DOM_CTRL);
	return 0;
}

static int harbor_pmu_probe(struct platform_device *pdev)
{
	struct harbor_pmu *pmu;
	u32 num_domains = 1;
	int i, ret;

	pmu = devm_kzalloc(&pdev->dev, sizeof(*pmu), GFP_KERNEL);
	if (!pmu)
		return -ENOMEM;

	pmu->dev = &pdev->dev;

	pmu->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(pmu->base))
		return PTR_ERR(pmu->base);

	device_property_read_u32(&pdev->dev, "num-domains", &num_domains);
	if (num_domains > HARBOR_PMU_MAX_DOMAINS)
		num_domains = HARBOR_PMU_MAX_DOMAINS;
	pmu->num_domains = num_domains;

	/* Enable global PMU */
	writel(1, pmu->base + HARBOR_PMU_CTRL);

	for (i = 0; i < num_domains; i++) {
		struct harbor_pmu_domain *pd = &pmu->domains[i];

		pd->index = i;
		pd->reg =
		    pmu->base + HARBOR_PMU_DOM_BASE + i * HARBOR_PMU_DOM_STRIDE;

		pd->genpd.name =
		    devm_kasprintf(&pdev->dev, GFP_KERNEL, "harbor-pd%d", i);
		pd->genpd.power_on = harbor_pmu_domain_power_on;
		pd->genpd.power_off = harbor_pmu_domain_power_off;

		ret = pm_genpd_init(&pd->genpd, NULL, false);
		if (ret) {
			dev_err(&pdev->dev, "Failed to init domain %d\n", i);
			goto err_remove;
		}

		pmu->pd_list[i] = &pd->genpd;
	}

	pmu->pd_data.domains = pmu->pd_list;
	pmu->pd_data.num_domains = num_domains;

	/*
	 * genpd providers are looked up by OF phandle and have no ACPI
	 * counterpart, so under ACPI there is nothing for consumers to
	 * reference. The domains themselves are still created and usable
	 * through pm_genpd_*; only the phandle lookup table is skipped.
	 */
	if (pdev->dev.of_node) {
		ret = of_genpd_add_provider_onecell(pdev->dev.of_node,
						    &pmu->pd_data);
		if (ret)
			goto err_remove;
	} else {
		dev_info(&pdev->dev, "no OF node: power domains created "
				     "without a provider table\n");
	}

	platform_set_drvdata(pdev, pmu);
	return 0;

err_remove:
	while (--i >= 0)
		pm_genpd_remove(&pmu->domains[i].genpd);
	return ret;
}

static void harbor_pmu_remove(struct platform_device *pdev)
{
	struct harbor_pmu *pmu = platform_get_drvdata(pdev);
	int i;

	if (pdev->dev.of_node)
		of_genpd_del_provider(pdev->dev.of_node);
	for (i = 0; i < pmu->num_domains; i++)
		pm_genpd_remove(&pmu->domains[i].genpd);
}

static const struct of_device_id harbor_pmu_of_match[] = {
    {.compatible = "harbor,pmu"}, {}};
MODULE_DEVICE_TABLE(of, harbor_pmu_of_match);

static struct platform_driver harbor_pmu_driver = {
    .probe = harbor_pmu_probe,
    .remove = harbor_pmu_remove,
    .driver =
	{
	    .name = "harbor-pmu",
	    .of_match_table = harbor_pmu_of_match,
	},
};
module_platform_driver(harbor_pmu_driver);

MODULE_AUTHOR("Midstall Software");
MODULE_DESCRIPTION("Harbor Power Management Unit driver");
MODULE_LICENSE("GPL");
