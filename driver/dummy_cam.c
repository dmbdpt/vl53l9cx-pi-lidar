// SPDX-License-Identifier: GPL-2.0-only
/*
 * Stub CSI-2 "sensor" subdevice for the ST VL53L9CX (STEVAL-VL53L9).
 *
 * The VL53L9CX is configured from userspace over I2C (app/vl53l9_bringup); this
 * driver only gives the CSI receiver (Pi 4 Unicam / Pi 5 RP1 CFE) a source
 * subdevice to bind to, plus optional XSHUT control on boards where the XSHUT
 * pin is wired to a GPIO (Pi 5: camera connector pin 17, see the overlay).
 *
 * XSHUT policy (only when the DT node has xshut-gpios):
 *   probe   -> XSHUT LOW (sensor in shutdown), stays LOW
 *   echo 1 > /sys/devices/platform/vl53l9/xshut_cycle
 *           -> LOW, 10 ms, HIGH, 200 ms ROM boot; sensor is then READY_TO_BOOT
 *   echo 0|1 > /sys/devices/platform/vl53l9/xshut_state
 *           -> drive XSHUT LOW / HIGH directly
 *   remove  -> XSHUT LOW
 *
 * Link frequency: the RP1 CFE programs its D-PHY from V4L2_CID_LINK_FREQ. The
 * bring-up app runs the sensor at 1 Gbps/lane (DDR) = 500 MHz link frequency.
 * If you change csi_data_rate in the bring-up app, load this module with
 * link_freq_hz=<rate/2> to match.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/mod_devicetable.h>
#include <linux/mutex.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/gpio/consumer.h>
#include <linux/version.h>
#include <media/v4l2-subdev.h>
#include <media/v4l2-ctrls.h>
#include <media/media-entity.h>

#define VL53L9_XSHUT_HOLD_MS    10
#define VL53L9_BOOT_SETTLE_MS   200

/* Defaults match binning 4 (100 x 38); the launchers set the real size. */
#define DUMMY_DEF_WIDTH         100
#define DUMMY_DEF_HEIGHT        38
#define DUMMY_MAX_DIM           4096

static unsigned long link_freq_hz = 500000000UL;
module_param(link_freq_hz, ulong, 0444);
MODULE_PARM_DESC(link_freq_hz,
		 "CSI-2 link frequency in Hz reported to the receiver (default 500000000 = 1 Gbps/lane)");

/* RAW8, CSI-2 datatype 0x2A. Y8 maps to GREY, SRGGB8 to 'RGGB' on both receivers. */
static const u32 dummy_mbus_codes[] = {
	MEDIA_BUS_FMT_Y8_1X8,
	MEDIA_BUS_FMT_SRGGB8_1X8,
};

struct dummy_cam {
	struct v4l2_subdev sd;
	struct media_pad pad;
	struct v4l2_ctrl_handler ctrls;
	s64 link_freq_menu[1];

	/* Protects fmt and serialises XSHUT against stream on/off. */
	struct mutex lock;
	struct v4l2_mbus_framefmt fmt;

	struct gpio_desc *xshut;	/* optional */
};

static inline struct dummy_cam *to_dummy(struct v4l2_subdev *sd)
{
	return container_of(sd, struct dummy_cam, sd);
}

/* ------------------------------------------------------------------------- */
/* V4L2                                                                      */
/* ------------------------------------------------------------------------- */

static void dummy_fixup_fmt(struct v4l2_mbus_framefmt *f)
{
	unsigned int i;
	bool known = false;

	for (i = 0; i < ARRAY_SIZE(dummy_mbus_codes); i++)
		if (f->code == dummy_mbus_codes[i])
			known = true;
	if (!known)
		f->code = dummy_mbus_codes[0];

	f->width = clamp_t(u32, f->width, 1, DUMMY_MAX_DIM);
	f->height = clamp_t(u32, f->height, 1, DUMMY_MAX_DIM);
	f->field = V4L2_FIELD_NONE;
	f->colorspace = V4L2_COLORSPACE_RAW;
	f->ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT;
	f->quantization = V4L2_QUANTIZATION_DEFAULT;
	f->xfer_func = V4L2_XFER_FUNC_NONE;
}

static int dummy_enum_mbus_code(struct v4l2_subdev *sd,
				struct v4l2_subdev_state *state,
				struct v4l2_subdev_mbus_code_enum *code)
{
	if (code->pad != 0 || code->index >= ARRAY_SIZE(dummy_mbus_codes))
		return -EINVAL;
	code->code = dummy_mbus_codes[code->index];
	return 0;
}

static int dummy_get_fmt(struct v4l2_subdev *sd,
			 struct v4l2_subdev_state *state,
			 struct v4l2_subdev_format *format)
{
	struct dummy_cam *dc = to_dummy(sd);

	if (format->pad != 0)
		return -EINVAL;

	mutex_lock(&dc->lock);
	format->format = dc->fmt;
	mutex_unlock(&dc->lock);
	return 0;
}

static int dummy_set_fmt(struct v4l2_subdev *sd,
			 struct v4l2_subdev_state *state,
			 struct v4l2_subdev_format *format)
{
	struct dummy_cam *dc = to_dummy(sd);

	if (format->pad != 0)
		return -EINVAL;

	dummy_fixup_fmt(&format->format);

	/* TRY formats are validated and echoed back but never touch the
	 * active configuration. */
	if (format->which == V4L2_SUBDEV_FORMAT_ACTIVE) {
		mutex_lock(&dc->lock);
		dc->fmt = format->format;
		mutex_unlock(&dc->lock);
	}
	return 0;
}

static int dummy_s_stream(struct v4l2_subdev *sd, int enable)
{
	struct dummy_cam *dc = to_dummy(sd);

	/* The sensor is started/stopped from userspace; just make sure a
	 * stream transition never overlaps an XSHUT cycle. */
	mutex_lock(&dc->lock);
	mutex_unlock(&dc->lock);
	return 0;
}

static const struct v4l2_subdev_pad_ops dummy_pad_ops = {
	.enum_mbus_code = dummy_enum_mbus_code,
	.get_fmt = dummy_get_fmt,
	.set_fmt = dummy_set_fmt,
};

static const struct v4l2_subdev_video_ops dummy_video_ops = {
	.s_stream = dummy_s_stream,
};

static const struct v4l2_subdev_ops dummy_ops = {
	.pad = &dummy_pad_ops,
	.video = &dummy_video_ops,
};

/* ------------------------------------------------------------------------- */
/* XSHUT sysfs control                                                       */
/* ------------------------------------------------------------------------- */

static ssize_t xshut_state_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	struct dummy_cam *dc = dev_get_drvdata(dev);

	if (!dc || !dc->xshut)
		return sysfs_emit(buf, "unavailable\n");
	return sysfs_emit(buf, "%d\n", gpiod_get_value_cansleep(dc->xshut));
}

static ssize_t xshut_state_store(struct device *dev,
				 struct device_attribute *attr,
				 const char *buf, size_t count)
{
	struct dummy_cam *dc = dev_get_drvdata(dev);
	bool val;

	if (!dc || !dc->xshut)
		return -ENODEV;
	if (kstrtobool(buf, &val))
		return -EINVAL;

	mutex_lock(&dc->lock);
	gpiod_set_value_cansleep(dc->xshut, val);
	mutex_unlock(&dc->lock);

	dev_info(dev, "xshut_state: XSHUT %s\n", val ? "HIGH" : "LOW");
	return count;
}
static DEVICE_ATTR_RW(xshut_state);

/* Reading xshut_cycle reports the current level, same as xshut_state. */
static ssize_t xshut_cycle_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	return xshut_state_show(dev, attr, buf);
}

static ssize_t xshut_cycle_store(struct device *dev,
				 struct device_attribute *attr,
				 const char *buf, size_t count)
{
	struct dummy_cam *dc = dev_get_drvdata(dev);
	int val;

	if (!dc || !dc->xshut)
		return -ENODEV;
	if (kstrtoint(buf, 10, &val) || val != 1)
		return -EINVAL;

	mutex_lock(&dc->lock);
	gpiod_set_value_cansleep(dc->xshut, 0);
	msleep(VL53L9_XSHUT_HOLD_MS);
	gpiod_set_value_cansleep(dc->xshut, 1);
	msleep(VL53L9_BOOT_SETTLE_MS);
	mutex_unlock(&dc->lock);

	dev_info(dev, "xshut_cycle: XSHUT HIGH, waited %d ms for ROM boot\n",
		 VL53L9_BOOT_SETTLE_MS);
	return count;
}
static DEVICE_ATTR_RW(xshut_cycle);

static struct attribute *dummy_attrs[] = {
	&dev_attr_xshut_cycle.attr,
	&dev_attr_xshut_state.attr,
	NULL,
};
ATTRIBUTE_GROUPS(dummy);

/* ------------------------------------------------------------------------- */
/* Probe / remove                                                            */
/* ------------------------------------------------------------------------- */

static int dummy_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct dummy_cam *dc;
	struct v4l2_ctrl *ctrl;
	int ret;

	dc = devm_kzalloc(dev, sizeof(*dc), GFP_KERNEL);
	if (!dc)
		return -ENOMEM;

	mutex_init(&dc->lock);

	dc->xshut = devm_gpiod_get_optional(dev, "xshut", GPIOD_OUT_LOW);
	if (IS_ERR(dc->xshut)) {
		ret = PTR_ERR(dc->xshut);
		/* -EBUSY usually means camN_reg still owns the line. */
		dev_err_probe(dev, ret, "failed to get xshut-gpios\n");
		goto err_mutex;
	}
	if (dc->xshut)
		dev_info(dev, "XSHUT held LOW; write 1 to xshut_cycle to boot the sensor\n");
	else
		dev_info(dev, "no xshut-gpios in DT; XSHUT control unavailable\n");

	platform_set_drvdata(pdev, dc);

	v4l2_subdev_init(&dc->sd, &dummy_ops);
	dc->sd.dev = dev;
	dc->sd.owner = THIS_MODULE;
	dc->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	snprintf(dc->sd.name, sizeof(dc->sd.name), "dummy-csi2");

	dc->fmt.code = dummy_mbus_codes[0];
	dc->fmt.width = DUMMY_DEF_WIDTH;
	dc->fmt.height = DUMMY_DEF_HEIGHT;
	dummy_fixup_fmt(&dc->fmt);

	/* Read-only LINK_FREQ so the receiver can program its D-PHY. */
	dc->link_freq_menu[0] = (s64)link_freq_hz;
	v4l2_ctrl_handler_init(&dc->ctrls, 1);
	ctrl = v4l2_ctrl_new_int_menu(&dc->ctrls, NULL, V4L2_CID_LINK_FREQ,
				      0, 0, dc->link_freq_menu);
	if (ctrl)
		ctrl->flags |= V4L2_CTRL_FLAG_READ_ONLY;
	if (dc->ctrls.error) {
		ret = dc->ctrls.error;
		dev_err(dev, "failed to init controls: %d\n", ret);
		goto err_ctrls;
	}
	dc->sd.ctrl_handler = &dc->ctrls;

	dc->pad.flags = MEDIA_PAD_FL_SOURCE;
	dc->sd.entity.function = MEDIA_ENT_F_CAM_SENSOR;
	ret = media_entity_pads_init(&dc->sd.entity, 1, &dc->pad);
	if (ret)
		goto err_ctrls;

	ret = v4l2_async_register_subdev(&dc->sd);
	if (ret)
		goto err_entity;

	dev_info(dev, "VL53L9 dummy CSI-2 sensor registered (link freq %lu Hz)\n",
		 link_freq_hz);
	return 0;

err_entity:
	media_entity_cleanup(&dc->sd.entity);
err_ctrls:
	v4l2_ctrl_handler_free(&dc->ctrls);
err_mutex:
	mutex_destroy(&dc->lock);
	return ret;
}

static void dummy_remove(struct platform_device *pdev)
{
	struct dummy_cam *dc = platform_get_drvdata(pdev);

	v4l2_async_unregister_subdev(&dc->sd);
	media_entity_cleanup(&dc->sd.entity);
	v4l2_ctrl_handler_free(&dc->ctrls);

	/* Leave the sensor in shutdown. */
	if (dc->xshut) {
		mutex_lock(&dc->lock);
		gpiod_set_value_cansleep(dc->xshut, 0);
		mutex_unlock(&dc->lock);
	}
	mutex_destroy(&dc->lock);
}

static const struct of_device_id dummy_dt_ids[] = {
	{ .compatible = "raspberrypi,dummy-csi2-sensor" },
	{ }
};
MODULE_DEVICE_TABLE(of, dummy_dt_ids);

static struct platform_driver dummy_driver = {
	.driver = {
		.name = "dummy_cam",
		.of_match_table = dummy_dt_ids,
		.dev_groups = dummy_groups,	/* created after probe, removed before remove */
	},
	.probe = dummy_probe,
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 11, 0)
	.remove_new = dummy_remove,	/* void-returning remove before 6.11 */
#else
	.remove = dummy_remove,
#endif
};
module_platform_driver(dummy_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("VL53L9CX stub MIPI CSI-2 sensor with optional GPIO XSHUT control");
