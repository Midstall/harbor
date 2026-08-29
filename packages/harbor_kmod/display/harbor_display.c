// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Harbor Display controller driver (DRM/KMS)
 *
 * Registers:
 *   0x00: CTRL       0x08: STATUS     0x10: FB_BASE
 *   0x18: FB_STRIDE  0x20: H_ACTIVE   0x28: H_TIMING
 *   0x30: V_ACTIVE   0x38: V_TIMING   0x40: INT_STATUS
 *   0x48: INT_ENABLE
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/io.h>
#include <linux/of.h>

#include <drm/drm_drv.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_gem_dma_helper.h>
#include <drm/drm_gem_framebuffer_helper.h>
#include <drm/drm_mode_config.h>
#include <drm/drm_connector.h>
#include <drm/drm_edid.h>
#include <drm/drm_encoder.h>
#include <drm/drm_crtc.h>
#include <drm/drm_plane.h>
#include <drm/drm_atomic_helper.h>
#include <drm/drm_probe_helper.h>
#include <drm/drm_vblank.h>

#define HARBOR_DISP_CTRL       0x00
#define HARBOR_DISP_STATUS     0x08
#define HARBOR_DISP_FB_BASE    0x10
#define HARBOR_DISP_FB_STRIDE  0x18
#define HARBOR_DISP_H_ACTIVE   0x20
#define HARBOR_DISP_H_TIMING   0x28
#define HARBOR_DISP_V_ACTIVE   0x30
#define HARBOR_DISP_V_TIMING   0x38
#define HARBOR_DISP_INT_STATUS 0x40
#define HARBOR_DISP_INT_ENABLE 0x48

struct harbor_display {
	void __iomem *base;
	struct drm_device drm;
	struct drm_crtc crtc;
	struct drm_plane primary;
	struct drm_encoder encoder;
	struct drm_connector connector;
};

DEFINE_DRM_GEM_DMA_FOPS(harbor_display_fops);

static const struct drm_driver harbor_display_drm_driver = {
    .driver_features = DRIVER_GEM | DRIVER_MODESET | DRIVER_ATOMIC,
    .name = "harbor-display",
    .desc = "Harbor Display Controller",
    .fops = &harbor_display_fops,
    DRM_GEM_DMA_DRIVER_OPS,
};

static void harbor_display_crtc_enable(struct drm_crtc *crtc,
				       struct drm_atomic_state *state)
{
	struct harbor_display *hd =
	    container_of(crtc, struct harbor_display, crtc);
	struct drm_display_mode *m = &crtc->state->adjusted_mode;

	writel(m->hdisplay, hd->base + HARBOR_DISP_H_ACTIVE);
	writel((m->hsync_start - m->hdisplay) |
		   ((m->hsync_end - m->hsync_start) << 8) |
		   ((m->htotal - m->hsync_end) << 16),
	       hd->base + HARBOR_DISP_H_TIMING);

	writel(m->vdisplay, hd->base + HARBOR_DISP_V_ACTIVE);
	writel((m->vsync_start - m->vdisplay) |
		   ((m->vsync_end - m->vsync_start) << 8) |
		   ((m->vtotal - m->vsync_end) << 16),
	       hd->base + HARBOR_DISP_V_TIMING);

	writel(1, hd->base + HARBOR_DISP_CTRL);
}

static void harbor_display_crtc_disable(struct drm_crtc *crtc,
					struct drm_atomic_state *state)
{
	struct harbor_display *hd =
	    container_of(crtc, struct harbor_display, crtc);

	writel(0, hd->base + HARBOR_DISP_CTRL);
}

static const struct drm_crtc_helper_funcs harbor_display_crtc_helper = {
    .atomic_enable = harbor_display_crtc_enable,
    .atomic_disable = harbor_display_crtc_disable,
};

static const struct drm_crtc_funcs harbor_display_crtc_funcs = {
    .set_config = drm_atomic_helper_set_config,
    .page_flip = drm_atomic_helper_page_flip,
    .destroy = drm_crtc_cleanup,
    .reset = drm_atomic_helper_crtc_reset,
    .atomic_duplicate_state = drm_atomic_helper_crtc_duplicate_state,
    .atomic_destroy_state = drm_atomic_helper_crtc_destroy_state,
};

static const struct drm_plane_funcs harbor_display_plane_funcs = {
    .update_plane = drm_atomic_helper_update_plane,
    .disable_plane = drm_atomic_helper_disable_plane,
    .destroy = drm_plane_cleanup,
    .reset = drm_atomic_helper_plane_reset,
    .atomic_duplicate_state = drm_atomic_helper_plane_duplicate_state,
    .atomic_destroy_state = drm_atomic_helper_plane_destroy_state,
};

static const struct drm_plane_helper_funcs harbor_display_plane_helper = {};

static const u32 harbor_display_formats[] = {
    DRM_FORMAT_XRGB8888,
    DRM_FORMAT_ARGB8888,
    DRM_FORMAT_RGB565,
    DRM_FORMAT_RGB888,
};

static int harbor_display_connector_get_modes(struct drm_connector *conn)
{
	return drm_add_modes_noedid(conn, 1920, 1080);
}

static const struct drm_connector_helper_funcs harbor_display_conn_helper = {
    .get_modes = harbor_display_connector_get_modes,
};

static const struct drm_connector_funcs harbor_display_conn_funcs = {
    .fill_modes = drm_helper_probe_single_connector_modes,
    .destroy = drm_connector_cleanup,
    .reset = drm_atomic_helper_connector_reset,
    .atomic_duplicate_state = drm_atomic_helper_connector_duplicate_state,
    .atomic_destroy_state = drm_atomic_helper_connector_destroy_state,
};

static const struct drm_encoder_funcs harbor_display_enc_funcs = {
    .destroy = drm_encoder_cleanup,
};

static const struct drm_mode_config_funcs harbor_display_mode_config_funcs = {
    .fb_create = drm_gem_fb_create,
    .atomic_check = drm_atomic_helper_check,
    .atomic_commit = drm_atomic_helper_commit,
};

static int harbor_display_probe(struct platform_device *pdev)
{
	struct harbor_display *hd;
	struct drm_device *drm;
	int ret;

	hd = devm_drm_dev_alloc(&pdev->dev, &harbor_display_drm_driver,
				struct harbor_display, drm);
	if (IS_ERR(hd))
		return PTR_ERR(hd);

	drm = &hd->drm;

	hd->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(hd->base))
		return PTR_ERR(hd->base);

	ret = drmm_mode_config_init(drm);
	if (ret)
		return ret;

	drm->mode_config.min_width = 640;
	drm->mode_config.min_height = 480;
	drm->mode_config.max_width = 1920;
	drm->mode_config.max_height = 1080;
	drm->mode_config.funcs = &harbor_display_mode_config_funcs;

	ret = drm_universal_plane_init(
	    drm, &hd->primary, 0, &harbor_display_plane_funcs,
	    harbor_display_formats, ARRAY_SIZE(harbor_display_formats), NULL,
	    DRM_PLANE_TYPE_PRIMARY, NULL);
	if (ret)
		return ret;
	drm_plane_helper_add(&hd->primary, &harbor_display_plane_helper);

	ret = drm_crtc_init_with_planes(drm, &hd->crtc, &hd->primary, NULL,
					&harbor_display_crtc_funcs, NULL);
	if (ret)
		return ret;
	drm_crtc_helper_add(&hd->crtc, &harbor_display_crtc_helper);

	drm_encoder_init(drm, &hd->encoder, &harbor_display_enc_funcs,
			 DRM_MODE_ENCODER_NONE, NULL);
	hd->encoder.possible_crtcs = drm_crtc_mask(&hd->crtc);

	drm_connector_init(drm, &hd->connector, &harbor_display_conn_funcs,
			   DRM_MODE_CONNECTOR_Unknown);
	drm_connector_helper_add(&hd->connector, &harbor_display_conn_helper);
	drm_connector_attach_encoder(&hd->connector, &hd->encoder);

	drm_mode_config_reset(drm);

	platform_set_drvdata(pdev, hd);

	return drm_dev_register(drm, 0);
}

static void harbor_display_remove(struct platform_device *pdev)
{
	struct harbor_display *hd = platform_get_drvdata(pdev);

	drm_dev_unregister(&hd->drm);
}

static const struct of_device_id harbor_display_of_match[] = {
    {.compatible = "harbor,display"}, {}};
MODULE_DEVICE_TABLE(of, harbor_display_of_match);

static struct platform_driver harbor_display_driver = {
    .probe = harbor_display_probe,
    .remove = harbor_display_remove,
    .driver =
	{
	    .name = "harbor-display",
	    .of_match_table = harbor_display_of_match,
	},
};
module_platform_driver(harbor_display_driver);

MODULE_AUTHOR("Lilith Semiconductor");
MODULE_DESCRIPTION("Harbor Display controller driver");
MODULE_LICENSE("GPL");
