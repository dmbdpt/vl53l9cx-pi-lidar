# VL53L9CX ToF LiDAR on Raspberry Pi (MIPI CSI-2)

Live **54 × 42-zone depth streaming at 100 fps** from an ST **VL53L9CX** multi-zone
Time-of-Flight LiDAR, over **MIPI CSI-2** into a Raspberry Pi (4 or 5), decoded and
rendered in real time.

<p align="center">
  <img src="docs/images/depth-sample.png" width="480" alt="Live 54x42 depth map">
</p>

The VL53L9CX streams its result buffer over CSI-2 as RAW8. This project boots the
sensor over I²C, captures the raw stream with the Pi's Unicam receiver, un-packs the
ST result buffer, and colour-maps the depth array — all at the sensor's full 100 Hz.

---

## Features

- **Full-resolution 54 × 42 depth** (binning 2) at a true **100 fps**
- One-command bring-up + live viewer (`run_lidar.sh`) and a desktop launcher icon
- Correct decode of the ST result buffer (distance / amplitude / ambient / DSS layout)
- Live orientation control and per-frame stats overlay
- Selectable binning-4 (24 × 24) mode
- **Raspberry Pi 4 (Unicam) and Raspberry Pi 5 (RP1 CFE)** support from one codebase —
  board-specific device-tree overlays and launchers, software-controlled XSHUT on the Pi 5
- **GPU-shader particle viewer** (`run_lidar_gpu.sh`) — the whole simulation runs in
  GLSL on the Pi's V3D GPU; see [`docs/GPU_VIEWER_CONTROLS.md`](docs/GPU_VIEWER_CONTROLS.md)
- **LiDAR Web Viewer** (`run_lidar_web.sh`) — a networked browser dashboard with an
  orbitable WebGL 3D point cloud, depth heatmap and live stats (pure stdlib Python); the
  full-featured **Web Studio** (`web/lidar_web.py`: gesture recognition, theremin,
  recording/replay, PLY export) runs on the same pipeline — see
  [`docs/WEB_STUDIO.md`](docs/WEB_STUDIO.md)

---

## Hardware

| Part | Notes |
|------|-------|
| Raspberry Pi 4 (BCM2711) **or** Raspberry Pi 5 (BCM2712 + RP1) | Raspberry Pi OS, kernel 6.x. The Pi 4 uses the Unicam receiver (`bcm2835-unicam`); the Pi 5 uses the RP1 CFE CSI receiver |
| STEVAL-VL53L9 | ST evaluation board carrying the VL53L9CX module |
| FFC / flex cable | STEVAL flex → Pi CSI (camera) connector: 1 MIPI data lane + I²C |

### Wiring note — sensor clock (AP_CLK)

The VL53L9CX needs a reference clock on AP_CLK (6–27 MHz) before it will even ACK on
I²C. The STEVAL ships strapped for a **host-supplied** clock on FFC pin 18
(CAM_IO1, "LED enable / XCLK"); its onboard 12 MHz oscillator is disabled.

- **Pi 5 (no board changes):** pin 18 is RP1 GPIO 35 (MIPI0) / 48 (MIPI1), which has no
  GPCLK function, only PWM1 channel 0. The overlay muxes it to PWM and `dummy_cam`
  runs it at **12.5 MHz** (4 ticks of RP1's 50 MHz PWM clock, 50 % duty) from boot,
  before XSHUT is released. It reports the frequency in
  `/sys/devices/platform/vl53l9/ap_clk_hz`, and the launchers pass it to the
  bring-up app (`--ext-clock`), so the sensor's timing stays correct. The fan uses
  PWM1 channel 3, so they don't interfere.
- **Boards modified for the onboard oscillator** (R25 and R23 removed): load
  `dummy_cam` with `ap_clk=0` (e.g. `options dummy_cam ap_clk=0` in
  `/etc/modprobe.d/vl53l9.conf`); the bring-up then assumes 12 MHz.
- **Pi 4:** nothing on the 15-pin connector provides a clock; feed 12 MHz from a
  header GPCLK (e.g. GPIO 4) or enable the onboard oscillator.

Check: `dmesg | grep AP_CLK` should show `AP_CLK: 12500000 Hz on PWM`, and
`scripts/test/run_stream_test.sh` should report ~100 fps. A clearly different rate (e.g. ~80 or ~133 fps) likely means
the real clock and `--ext-clock` disagree (the RP1 PWM period quirk is handled by
`dummy_cam`'s `ap_clk_legacy_tick_ns` parameter: 20 on Raspberry Pi kernels up to
6.12, ignored on kernels with the PWM waveform API).

### Wiring note — XSHUT

The VL53L9CX's **XSHUT** (enable) pin must be held **HIGH** for the sensor to boot and
run; LOW = shutdown. How it is handled differs per board:

- **Pi 4:** on this setup XSHUT is not broken out to a controllable Pi GPIO through the
  ribbon. On the STEVAL **J2 header** it's **pin 5** — tie it to **pin 8 (3V3)** with a
  jumper so the sensor is enabled. Because XSHUT is hard-tied there is no software reset:
  a fresh power-up puts the sensor in `READY_TO_BOOT` for a clean firmware init, once per
  power cycle — see [Implementation notes](#implementation-notes).

- **Pi 5:** on the current FFC wiring XSHUT lands on MIPI0 connector pin 17 (`CD0_IO0`,
  RP1 GPIO line 34), and this module has no separate power-enable net. The `dummy_cam`
  driver therefore owns that line directly and exposes a software reset:

  ```bash
  sudo sh -c 'echo 1 > /sys/devices/platform/vl53l9/xshut_cycle'   # XSHUT LOW → HIGH, wait for boot
  cat /sys/devices/platform/vl53l9/xshut_state                     # 1 = running
  ```

  The Pi 5 launchers do this on every run. If your cable sits on MIPI1 instead of MIPI0,
  XSHUT is line 46; the overlay's `cam0` parameter picks the right one — see
  [`driver/vl53l9-mipi-pi5.dts`](driver/vl53l9-mipi-pi5.dts).

---

## Repository layout

```
.
├── app/
│   └── vl53l9_bringup.c      # I²C bring-up: init → profile → CSI config → start streaming
├── driver/
│   ├── dummy_cam.c           # stub CSI-2 subdev (+ XSHUT sysfs control on RPi5)
│   ├── vl53l9-mipi.dts       # Pi 4 device-tree overlay (csi1 + /dev/i2c-10)
│   ├── vl53l9-mipi-pi5.dts   # Pi 5 overlay (CFE; [cam0] = MIPI0 port) — see wiring note
│   └── Makefile              # builds dummy_cam.ko
├── tools/                    # userspace diagnostics: i2c_id / i2c_probe(_adv) / set_fmt
├── viewer/
│   ├── visualize.py          # OpenCV live view of the RAW8 FIFO (Pi 4 launcher)
│   ├── visualize_gpu.py      # GPU-shader particle viewer (run_lidar_gpu.sh)
│   ├── web_view.py           # pure-stdlib web dashboard (default for run_lidar_web.sh)
│   └── headless_decode.py    # no-display frame verifier / FPS + stats logger
├── web/                      # full Web Studio: gestures, theremin, recording, PLY export
├── vendor/st-uld/            # ST VL53L9CX ULD driver (SLA0111) — see LICENSE.txt
├── python/vl53l9_stream.py   # numpy frame reader for your own processing (FIFO -> arrays)
├── scripts/                  # .desktop launchers, pi5_pipeline.sh (shared Pi 5 setup),
│                             #   99-vl53l9.rules (sudo-less XSHUT); test/ = RPi5 tests
├── run_lidar.sh              # Pi 4: one-shot build-if-needed, stream + OpenCV viewer
├── run_lidar_gpu.sh          # Pi 4: GPU particle viewer
├── run_lidar_web.sh          # Pi 5 (CFE pipeline): web dashboard on :8080
├── Makefile                  # app; module(_install), overlay(_install), tools targets
└── docs/
```

---

## Build & install

### 1. Kernel module + device-tree overlay (one-time, per board)

The Pi needs a subdevice bound to the CSI port so the receiver will enable and DMA the
sensor's stream (the VL53L9CX is controlled out-of-band over I²C, so a small stub sensor
driver stands in on the media graph). Install the kernel headers, then build and
**install** the module so it loads automatically on every boot (`insmod` alone does not
survive the reboot below):

```bash
sudo apt install linux-headers-$(uname -r) device-tree-compiler v4l-utils
make module                    # -> driver/dummy_cam.ko
sudo make module_install       # -> /lib/modules/$(uname -r)/updates + depmod
make overlay                   # -> vl53l9-mipi.dtbo + vl53l9-mipi-pi5.dtbo (cpp | dtc)
sudo make overlay_install      # -> /boot/firmware/overlays/
```

(The Pi 5 overlay `#include`s a dt-bindings header, so it must go through the C
preprocessor before `dtc`; `make overlay` does that. Plain `dtc -I dts …` will not work.)

Then add **one** line to `/boot/firmware/config.txt` and reboot:

```
dtoverlay=vl53l9-mipi                 # Raspberry Pi 4
dtoverlay=vl53l9-mipi-pi5,cam0        # Raspberry Pi 5, sensor on MIPI0 (cam0 port)
dtoverlay=vl53l9-mipi-pi5             # Raspberry Pi 5, sensor on MIPI1 (cam1 port)
```

On the Pi 5 the `cam0` parameter switches the I²C bus, CSI port, XSHUT line (RP1 GPIO
34 vs 46) and the disabled camera regulator together. The MIPI0 variant is the one that
has been tested on hardware; the MIPI1 variant follows the same wiring logic but is
untested. `xshut_gpio=<n>` overrides the XSHUT line if your cable differs.

Optional, Pi 5: let the `video` group reset the sensor without sudo:

```bash
sudo cp scripts/99-vl53l9.rules /etc/udev/rules.d/ && sudo udevadm control --reload
```

Confirm after the reboot:

```bash
dmesg | grep -i 'dummy\|vl53l9'      # "VL53L9 dummy CSI-2 sensor registered (link freq 500000000 Hz)"
media-ctl -p | grep -A2 dummy-csi2   # sensor entity linked to the receiver
ls -l /sys/devices/platform/vl53l9/  # Pi 5: xshut_cycle, xshut_state
```

### 2. Bring-up app

```bash
make          # builds ./vl53l9_bringup from app/ + vendor/st-uld/
```

### 3. Desktop launcher (optional)

```bash
cp scripts/lidar.desktop ~/Desktop/
gio set ~/Desktop/lidar.desktop metadata::trusted true
```

---

## Run

**Pi 4** (Unicam pipeline):

```bash
./run_lidar.sh          # 54x42 @ 100 fps OpenCV view (default)
./run_lidar.sh 4        # 24x24 (binning 4)
./run_lidar_gpu.sh      # GPU-shader particle viewer
```

**Viewer keys:** `r` cycles orientation (raw / flipV / flipH / rot180), `q` quits.
Stop everything with `pkill -f 'viewer/visualiz[e]'; pkill -f 'v4l2-ctl.*stream-mmap'`.

**Pi 5** (CFE pipeline):

```bash
./run_lidar_web.sh                                  # web dashboard on http://<pi-ip>:8080
VL_APP=studio ./run_lidar_web.sh                    # full Web Studio instead
VL_APP=path/to/your_script.py ./run_lidar_web.sh  # your own Python consumer
scripts/test/run_stream_test.sh                     # headless check (FPS + stats)
```

Every run XSHUT-cycles the sensor first (so repeat runs start from a clean
`READY_TO_BOOT`), finds the I²C bus the sensor answers on, and looks up the media /
subdev / video nodes by entity name, so device numbering doesn't matter. The decoder
stride is read back from the receiver (112 bytes on the Pi 5) rather than hard-coded.
Without the udev rule above, the XSHUT cycle asks for sudo.

### Python API

`python/vl53l9_stream.py` turns the capture FIFO into numpy frames:

```python
import sys; sys.path.insert(0, "python")
from vl53l9_stream import FrameReader

with FrameReader() as reader:        # reads VL_PIPE / VL_BINNING / VL_STRIDE from env
    for f in reader:                 # ~100 frames/s
        f.depth_mm   # (42, 54) uint16, radial mm, 0 = invalid
        f.valid      # (42, 54) bool   (bit 15 of the distance word)
        f.amplitude  # (42, 54) uint16 signal strength
        f.ambient    # (42, 54) uint16 ambient light
```

Run your own script on the live stream with
`VL_APP=path/to/your_script.py ./run_lidar_web.sh`.

Or double-click a **ToF LiDAR** desktop icon (`scripts/*.desktop`).

---

## How it works

```
VL53L9CX ──MIPI CSI-2 (RAW8, 1 lane, 1 Gbps)──▶ Pi Unicam ──DMA──▶ /dev/video0
   ▲ I²C (0x29, /dev/i2c-10)                                           │
   │                                                    v4l2-ctl --stream-to
vl53l9_bringup                                                         ▼
   init → profile → CSI cfg → start                              /tmp/tof_pipe (FIFO)
                                                                       │
                                                        viewer/visualize.py (decode + render)
```

The sensor streams its **result buffer**, not an image. For binning 2 (54 × 42 = 2268
raw zones) each CSI frame is laid out as:

```
[ distance u16 × N | amplitude u16 × N | ambient u16 × N | DSS 4-bit/zone | status line ]
```

Unicam pads each 100-byte line to a 128-byte stride (the Pi 5 CFE to 112); the viewer de-strides, slices the
distance array, keeps zones with bit 15 set (valid
measurement) and masks the 15-bit value (`mm = raw & 0x7FFF`), reshapes to 54 × 42 and
colour-maps by range. The trailing **status line** (frame counter, temperature, metadata)
is the extra CSI row and is dropped.

On the **Pi 5** the same RAW8 stream arrives through the RP1 CFE receiver instead of
Unicam: the media pipeline is `csi2 → rp1-cfe-csi2_ch0 → /dev/video0`, the sensor's I²C
bus is the connector bus (`/dev/i2c-6` on MIPI0, `/dev/i2c-4` on MIPI1), and the video
format must be set with `tools/set_fmt` because the vendor fourcc for RAW8 there is
`'RGGB'`. The decoder side (FIFO → de-stride → 54 × 42 depth) is identical.

---

## Implementation notes

Things that were non-obvious and are baked into the code:

- **The result code from `vl53l9_init()` / `vl53l9_start()` is `-5` (TIMEOUT) even on
  success** — the ULD's command-ack poll is tuned for the STM32 reference and times out
  over Linux user-space I²C. Trust the **FSM register** (`0x008C`: 1 = `READY_TO_BOOT`,
  2 = `STANDBY`, 3 = `STREAMING`), not the return value.
- **Firmware-boot timeouts were widened** in the ULD (`_write_cmd`/`_wait_for_state`
  from 71 ms / 4 ms → 3000 ms) so the 32 KB patch load + boot handshake completes over
  I²C. A clean `vl53l9_init()` must run from `READY_TO_BOOT` (i.e. after a power-up).
- **100 fps requires DSS disabled.** With Dynamic SPAD Selection on, the extra
  acquisition pass caps the rate at exactly 50 fps; disabling it (per the datasheet's
  100 fps "Gaming" profile: precision context, regular power, 4 ms exposure) hits 100.
- **Unicam must be armed before the sensor's D-PHY (re)starts**, or no frames arrive.
  The dummy subdev pad format must match the capture height (148 for binning 2, 38 for
  binning 4).
- **Distances are raw radial, uncalibrated** 15-bit values. True perpendicular
  millimetres need ST's post-processing ISP (`transform` library) with a calibration
  buffer — not integrated here.

---

## Limitations / roadmap

- Depth is raw radial off the wire; the **Web Studio** applies ST's
  radial→perpendicular + point-cloud calibration (pinhole + distortion +
  parallax, default OTP-fallback params) for geometrically correct 3D / PLY —
  per-unit OTP calibration and TNR (ST ISP) are still not integrated
- Amplitude & ambient arrays are decoded off the wire but not yet displayed
- On the Pi 4, sensor reset is a manual power-cycle (XSHUT hard-tied); on the Pi 5 it is
  software-controlled via `xshut_cycle` sysfs (see wiring note)

---

## License

- Original work in this repository (bring-up app, viewer, kernel module, overlay,
  scripts, docs) — **MIT**, see [`LICENSE`](LICENSE).
- `vendor/st-uld/` — © STMicroelectronics, **SLA0111**, see
  [`vendor/st-uld/LICENSE.txt`](vendor/st-uld/LICENSE.txt). SLA0111 permits source
  redistribution provided the ST copyright notices and license text are retained.

Not affiliated with or endorsed by STMicroelectronics. VL53L9CX and STEVAL are ST
trademarks.
