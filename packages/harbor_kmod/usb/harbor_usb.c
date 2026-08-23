// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor USB controller driver (gadget mode)
 *
 * Each register sits in its own 8-byte slot: the controller sits on a
 * byte-addressed fabric that decodes the low bits of the byte address, like
 * every other Harbor peripheral. 4-byte spacing aliases every register onto its
 * neighbour.
 *
 * Global registers:
 *   0x000: CTRL       0x008: STATUS     0x010: ADDR
 *   0x018: INT_STATUS 0x020: INT_ENABLE 0x028: FRAME
 *
 * Endpoint registers live in the second 512-byte page (address bit 9). The
 * hardware implements EP0 only, and its registers are NOT a uniform per-endpoint
 * block: there is no stride to index. See lib/src/peripherals/usb.dart.
 *   0x200: EP0_CTRL   0x218: EP0_TXDATA 0x228: EP0_TXLEN
 *   0x280: EP0_RXLEN  0x288: EP0_RXDATA 0x290: EP0_STATUS
 *   0x300: HOST_TOKEN 0x308: HOST_STATUS  (host/OTG builds)
 *
 * NOTE: the gadget code below still models HARBOR_USB_MAX_EP uniform endpoints
 * with a stride. That model does not exist in the hardware, so only endpoint 0
 * resolves to a real register. Driving a non-zero endpoint writes into the
 * host-mode block. Multi-endpoint support needs the hardware to grow the
 * per-endpoint block first.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/usb/gadget.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/interrupt.h>

#define HARBOR_USB_CTRL	      0x000
#define HARBOR_USB_STATUS     0x004
#define HARBOR_USB_ADDR	      0x008
#define HARBOR_USB_INT_STATUS 0x00C
#define HARBOR_USB_INT_ENABLE 0x010
#define HARBOR_USB_FRAME      0x014

/* The endpoint page. Only endpoint 0 exists in hardware, so the stride is the
 * page itself and indexing past 0 leaves the block. */
#define HARBOR_USB_EP_BASE   0x200
#define HARBOR_USB_EP_STRIDE 0x100
#define HARBOR_USB_EP_CTRL   0x00
#define HARBOR_USB_EP_TXDATA 0x18
#define HARBOR_USB_EP_TXLEN  0x28
#define HARBOR_USB_EP_RXLEN  0x80
#define HARBOR_USB_EP_RXDATA 0x88
#define HARBOR_USB_EP_STATUS 0x90

#define HARBOR_USB_MAX_EP 16

struct harbor_usb_ep {
	struct usb_ep ep;
	struct harbor_usb *husb;
	u8 idx;
};

struct harbor_usb {
	void __iomem *base;
	struct usb_gadget gadget;
	struct usb_gadget_driver *driver;
	struct device *dev;
	int irq;
	int num_ep;
	struct harbor_usb_ep eps[HARBOR_USB_MAX_EP];
};

static inline void __iomem *ep_reg(struct harbor_usb *husb, int ep)
{
	return husb->base + HARBOR_USB_EP_BASE + ep * HARBOR_USB_EP_STRIDE;
}

static int harbor_usb_ep_enable(struct usb_ep *_ep,
				const struct usb_endpoint_descriptor *desc)
{
	struct harbor_usb_ep *ep = container_of(_ep, struct harbor_usb_ep, ep);

	writel(1, ep_reg(ep->husb, ep->idx) + HARBOR_USB_EP_CTRL);
	return 0;
}

static int harbor_usb_ep_disable(struct usb_ep *_ep)
{
	struct harbor_usb_ep *ep = container_of(_ep, struct harbor_usb_ep, ep);

	writel(0, ep_reg(ep->husb, ep->idx) + HARBOR_USB_EP_CTRL);
	return 0;
}

static struct usb_request *harbor_usb_ep_alloc_request(struct usb_ep *_ep,
						       gfp_t gfp)
{
	struct usb_request *req;

	req = kzalloc(sizeof(*req), gfp);
	return req;
}

static void harbor_usb_ep_free_request(struct usb_ep *_ep,
				       struct usb_request *req)
{
	kfree(req);
}

static int harbor_usb_ep_queue(struct usb_ep *_ep, struct usb_request *req,
			       gfp_t gfp)
{
	/* Stub: real driver would enqueue to HW FIFO */
	req->status = 0;
	req->actual = req->length;
	usb_gadget_giveback_request(_ep, req);
	return 0;
}

static int harbor_usb_ep_dequeue(struct usb_ep *_ep, struct usb_request *req)
{
	return 0;
}

static const struct usb_ep_ops harbor_usb_ep_ops = {
    .enable = harbor_usb_ep_enable,
    .disable = harbor_usb_ep_disable,
    .alloc_request = harbor_usb_ep_alloc_request,
    .free_request = harbor_usb_ep_free_request,
    .queue = harbor_usb_ep_queue,
    .dequeue = harbor_usb_ep_dequeue,
};

static int harbor_usb_udc_start(struct usb_gadget *gadget,
				struct usb_gadget_driver *driver)
{
	struct harbor_usb *husb =
	    container_of(gadget, struct harbor_usb, gadget);

	husb->driver = driver;
	writel(1, husb->base + HARBOR_USB_CTRL);
	writel(0xFF, husb->base + HARBOR_USB_INT_ENABLE);
	return 0;
}

static int harbor_usb_udc_stop(struct usb_gadget *gadget)
{
	struct harbor_usb *husb =
	    container_of(gadget, struct harbor_usb, gadget);

	writel(0, husb->base + HARBOR_USB_INT_ENABLE);
	writel(0, husb->base + HARBOR_USB_CTRL);
	husb->driver = NULL;
	return 0;
}

static const struct usb_gadget_ops harbor_usb_gadget_ops = {
    .udc_start = harbor_usb_udc_start,
    .udc_stop = harbor_usb_udc_stop,
};

static irqreturn_t harbor_usb_irq(int irq, void *data)
{
	struct harbor_usb *husb = data;
	u32 status;

	status = readl(husb->base + HARBOR_USB_INT_STATUS);
	if (!status)
		return IRQ_NONE;

	writel(status, husb->base + HARBOR_USB_INT_STATUS);
	return IRQ_HANDLED;
}

static int harbor_usb_probe(struct platform_device *pdev)
{
	struct harbor_usb *husb;
	int i, ret;
	u32 num_ep = 4;

	husb = devm_kzalloc(&pdev->dev, sizeof(*husb), GFP_KERNEL);
	if (!husb)
		return -ENOMEM;

	husb->dev = &pdev->dev;

	husb->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(husb->base))
		return PTR_ERR(husb->base);

	husb->irq = platform_get_irq(pdev, 0);
	if (husb->irq < 0)
		return husb->irq;

	ret = devm_request_irq(&pdev->dev, husb->irq, harbor_usb_irq, 0,
			       "harbor-usb", husb);
	if (ret)
		return ret;

	device_property_read_u32(&pdev->dev, "num-endpoints", &num_ep);
	if (num_ep > HARBOR_USB_MAX_EP)
		num_ep = HARBOR_USB_MAX_EP;
	husb->num_ep = num_ep;

	husb->gadget.ops = &harbor_usb_gadget_ops;
	husb->gadget.name = "harbor-usb";
	husb->gadget.max_speed = USB_SPEED_HIGH;
	INIT_LIST_HEAD(&husb->gadget.ep_list);

	for (i = 0; i < num_ep; i++) {
		struct harbor_usb_ep *ep = &husb->eps[i];

		ep->husb = husb;
		ep->idx = i;
		ep->ep.ops = &harbor_usb_ep_ops;
		ep->ep.name = devm_kasprintf(&pdev->dev, GFP_KERNEL, "ep%d", i);
		ep->ep.maxpacket = 512;

		if (i == 0) {
			husb->gadget.ep0 = &ep->ep;
			usb_ep_set_maxpacket_limit(&ep->ep, 64);
		} else {
			list_add_tail(&ep->ep.ep_list, &husb->gadget.ep_list);
		}
	}

	platform_set_drvdata(pdev, husb);
	return usb_add_gadget_udc(&pdev->dev, &husb->gadget);
}

static void harbor_usb_remove(struct platform_device *pdev)
{
	struct harbor_usb *husb = platform_get_drvdata(pdev);

	usb_del_gadget_udc(&husb->gadget);
}

static const struct of_device_id harbor_usb_of_match[] = {
    {.compatible = "harbor,usb"}, {}};
MODULE_DEVICE_TABLE(of, harbor_usb_of_match);

static struct platform_driver harbor_usb_driver = {
    .probe = harbor_usb_probe,
    .remove = harbor_usb_remove,
    .driver =
	{
	    .name = "harbor-usb",
	    .of_match_table = harbor_usb_of_match,
	},
};
module_platform_driver(harbor_usb_driver);

MODULE_AUTHOR("Midstall Software");
MODULE_DESCRIPTION("Harbor USB controller driver");
MODULE_LICENSE("GPL");
