// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor Ethernet MAC driver
 *
 * Registers:
 *   0x000: MAC_CTRL    0x008: MAC_STATUS    0x010: MAC_ADDR_LO
 *   0x018: MAC_ADDR_HI 0x020: INT_STATUS    0x028: INT_ENABLE
 *   0x040: TX_CTRL     0x050: TX_DESC_BASE  0x060: RX_CTRL
 *   0x070: RX_DESC_BASE 0x080: MDIO_CTRL    0x088: MDIO_DATA
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/of_net.h>
#include <linux/clk.h>
#include <linux/interrupt.h>

#define HARBOR_ETH_MAC_CTRL	0x000
#define HARBOR_ETH_MAC_STATUS	0x008
#define HARBOR_ETH_MAC_ADDR_LO	0x010
#define HARBOR_ETH_MAC_ADDR_HI	0x018
#define HARBOR_ETH_INT_STATUS	0x020
#define HARBOR_ETH_INT_ENABLE	0x028
#define HARBOR_ETH_TX_CTRL	0x040
#define HARBOR_ETH_TX_DESC_BASE 0x050
#define HARBOR_ETH_RX_CTRL	0x060
#define HARBOR_ETH_RX_DESC_BASE 0x070
#define HARBOR_ETH_MDIO_CTRL	0x080
#define HARBOR_ETH_MDIO_DATA	0x088

struct harbor_eth {
	void __iomem *base;
	struct net_device *ndev;
	int irq;
};

static int harbor_eth_open(struct net_device *ndev)
{
	struct harbor_eth *he = netdev_priv(ndev);

	/* Set MAC address */
	writel(ndev->dev_addr[0] | (ndev->dev_addr[1] << 8) |
		   (ndev->dev_addr[2] << 16) | (ndev->dev_addr[3] << 24),
	       he->base + HARBOR_ETH_MAC_ADDR_LO);
	writel(ndev->dev_addr[4] | (ndev->dev_addr[5] << 8),
	       he->base + HARBOR_ETH_MAC_ADDR_HI);

	/* Enable TX/RX */
	writel(1, he->base + HARBOR_ETH_TX_CTRL);
	writel(1, he->base + HARBOR_ETH_RX_CTRL);
	writel(1, he->base + HARBOR_ETH_MAC_CTRL);

	netif_start_queue(ndev);
	return 0;
}

static int harbor_eth_stop(struct net_device *ndev)
{
	struct harbor_eth *he = netdev_priv(ndev);

	netif_stop_queue(ndev);
	writel(0, he->base + HARBOR_ETH_MAC_CTRL);
	writel(0, he->base + HARBOR_ETH_TX_CTRL);
	writel(0, he->base + HARBOR_ETH_RX_CTRL);

	return 0;
}

static netdev_tx_t harbor_eth_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	/* TX would write to descriptor ring and kick DMA */
	dev_kfree_skb(skb);
	return NETDEV_TX_OK;
}

static const struct net_device_ops harbor_eth_ops = {
    .ndo_open = harbor_eth_open,
    .ndo_stop = harbor_eth_stop,
    .ndo_start_xmit = harbor_eth_xmit,
    .ndo_set_mac_address = eth_mac_addr,
    .ndo_validate_addr = eth_validate_addr,
};

static int harbor_eth_probe(struct platform_device *pdev)
{
	struct harbor_eth *he;
	struct net_device *ndev;
	int ret;

	ndev = devm_alloc_etherdev(&pdev->dev, sizeof(*he));
	if (!ndev)
		return -ENOMEM;

	he = netdev_priv(ndev);
	he->ndev = ndev;

	he->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(he->base))
		return PTR_ERR(he->base);

	ndev->netdev_ops = &harbor_eth_ops;
	SET_NETDEV_DEV(ndev, &pdev->dev);

	ret = device_get_ethdev_address(&pdev->dev, ndev);
	if (ret)
		eth_hw_addr_random(ndev);

	platform_set_drvdata(pdev, he);
	return register_netdev(ndev);
}

static const struct of_device_id harbor_eth_of_match[] = {
    {.compatible = "harbor,ethernet"}, {}};
MODULE_DEVICE_TABLE(of, harbor_eth_of_match);

static struct platform_driver harbor_eth_driver = {
    .probe = harbor_eth_probe,
    .driver =
	{
	    .name = "harbor-ethernet",
	    .of_match_table = harbor_eth_of_match,
	},
};
module_platform_driver(harbor_eth_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor Ethernet MAC driver");
MODULE_LICENSE("GPL");
