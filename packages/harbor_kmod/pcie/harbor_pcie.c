// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor PCIe host controller driver
 *
 * Registers:
 *   0x000: CTRL        0x008: STATUS      0x010: LINK_CTRL
 *   0x018: INT_STATUS  0x020: INT_ENABLE  0x028: ERR_STATUS
 *   0x080: MSI_ADDR    0x088: MSI_DATA    0x098: MSI_PEND
 *
 * ECAM config space starts at offset 0x1000.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/pci.h>
#include <linux/io.h>
#include <linux/of.h>

#define HARBOR_PCIE_CTRL	0x000
#define HARBOR_PCIE_STATUS	0x008
#define HARBOR_PCIE_LINK_CTRL	0x010
#define HARBOR_PCIE_INT_STATUS	0x018
#define HARBOR_PCIE_INT_ENABLE	0x020
#define HARBOR_PCIE_ERR_STATUS	0x028
#define HARBOR_PCIE_ECAM_OFFSET 0x1000

#define HARBOR_PCIE_STATUS_LINK_UP BIT(0)

struct harbor_pcie {
	void __iomem *base;
	struct pci_host_bridge *bridge;
};

static void __iomem *harbor_pcie_map_bus(struct pci_bus *bus,
					 unsigned int devfn, int where)
{
	struct pci_host_bridge *bridge = pci_find_host_bridge(bus);
	struct harbor_pcie *hp = pci_host_bridge_priv(bridge);

	return hp->base + HARBOR_PCIE_ECAM_OFFSET + (bus->number << 20) +
	       (devfn << 12) + where;
}

static struct pci_ops harbor_pcie_ops = {
    .map_bus = harbor_pcie_map_bus,
    .read = pci_generic_config_read,
    .write = pci_generic_config_write,
};

static int harbor_pcie_probe(struct platform_device *pdev)
{
	struct harbor_pcie *hp;
	struct pci_host_bridge *bridge;

	bridge = devm_pci_alloc_host_bridge(&pdev->dev, sizeof(*hp));
	if (!bridge)
		return -ENOMEM;

	hp = pci_host_bridge_priv(bridge);
	hp->bridge = bridge;

	hp->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hp->base))
		return PTR_ERR(hp->base);

	/* Enable controller and start link training */
	writel(1, hp->base + HARBOR_PCIE_CTRL);
	writel(1, hp->base + HARBOR_PCIE_LINK_CTRL);
	writel(0xFF, hp->base + HARBOR_PCIE_INT_ENABLE);

	bridge->ops = &harbor_pcie_ops;
	bridge->sysdata = hp;

	return pci_host_probe(bridge);
}

static const struct of_device_id harbor_pcie_of_match[] = {
    {.compatible = "harbor,pcie-host"}, {}};
MODULE_DEVICE_TABLE(of, harbor_pcie_of_match);

static struct platform_driver harbor_pcie_driver = {
    .probe = harbor_pcie_probe,
    .driver =
	{
	    .name = "harbor-pcie",
	    .of_match_table = harbor_pcie_of_match,
	},
};
module_platform_driver(harbor_pcie_driver);

MODULE_AUTHOR("Midstall Software");
MODULE_DESCRIPTION("Harbor PCIe host controller driver");
MODULE_LICENSE("GPL");
