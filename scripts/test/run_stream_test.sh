#!/bin/bash
# VL53L9CX streaming test (Raspberry Pi 5, RP1 CFE): reset the sensor, configure
# the media pipeline, arm the CSI receiver, boot the sensor over I2C, then verify
# frames headlessly through a FIFO decoder (FPS + depth stats).
set -u
REPO="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
cd "$REPO" || exit 1
# shellcheck source=../pi5_pipeline.sh
. "$REPO/scripts/pi5_pipeline.sh"

[ -x ./vl53l9_bringup ] || make -s || exit 1

pkill -f 'headless_dec[o]de.py' 2>/dev/null
pkill -f 'v4l2-ctl.*stream-mmap' 2>/dev/null
sleep 0.3

vl_pi5_reset_sensor
vl_pi5_find_bus "$REPO"
vl_pi5_find_nodes
vl_pi5_configure "$REPO" 100 148
echo "[+] stride=$VL_STRIDE"

rm -f /tmp/tof_pipe
mkfifo /tmp/tof_pipe
nohup env VL_BINNING=2 VL_STRIDE="$VL_STRIDE" VL_PIPE=/tmp/tof_pipe \
    python3 "$REPO/viewer/headless_decode.py" > /tmp/decode.log 2>&1 &
sleep 1

nohup v4l2-ctl -d "$VL_VIDEO" --stream-mmap --stream-to=/tmp/tof_pipe \
    > /tmp/v4l2.log 2>&1 &
sleep 1.5

# usecase 1 = binning 2, 4 ms exposure, 100 Hz, REGULAR power, DSS off
./vl53l9_bringup --i2c "$VL_I2C_BUS" 1 4 10000 0 0

echo ---DECODE---
sleep 8
tail -25 /tmp/decode.log
echo ---V4L2LOG---
tail -5 /tmp/v4l2.log
echo ---DMESG---
dmesg | tail -12
