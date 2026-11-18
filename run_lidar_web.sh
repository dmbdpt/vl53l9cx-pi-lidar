#!/bin/bash
# VL53L9CX LiDAR Web Viewer launcher (Raspberry Pi 5, RP1 CFE pipeline).
#
# Resets the sensor (XSHUT), configures the CFE media pipeline, boots the sensor
# (bring-up usecase 1 = binning 2 / 100x148 @ 100 Hz) and feeds the RAW8 stream
# to a web dashboard. Open http://<pi-ip>:8080 from any device on the LAN.
#
#   ./run_lidar_web.sh [port]           # lightweight viewer (viewer/web_view.py)
#   VL_APP=studio ./run_lidar_web.sh    # full Web Studio (web/lidar_web.py)
#   VL_APP=path/to/your_script.py ./run_lidar_web.sh    # any FIFO consumer
#                                       # (gets VL_PIPE / VL_STRIDE / VL_BINNING)
#
# Env overrides: VL_I2C_BUS=/dev/i2c-N (skip bus auto-detect).
# Both this and scripts/test/run_stream_test.sh consume the CSI receiver; run one.
set -u
# Resolve a custom VL_APP path against the caller's directory before cd'ing.
case "${VL_APP:-viewer}" in viewer|studio) ;; *) VL_APP="$(readlink -f "$VL_APP")" ;; esac
REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$REPO" || exit 1
# shellcheck source=scripts/pi5_pipeline.sh
. "$REPO/scripts/pi5_pipeline.sh"

BIN=2; WIDTH=100; HEIGHT=148
EXP=4; PERIOD=10000; POWER=0; DSS=0
PIPE=/tmp/tof_pipe_web
PORT=${1:-8080}
case "${VL_APP:-viewer}" in
    viewer) APP="$REPO/viewer/web_view.py" ;;
    studio) APP="$REPO/web/lidar_web.py" ;;
    *)      APP="$VL_APP"   # your own FIFO consumer script
            [ -f "$APP" ] || { echo "[-] VL_APP=$VL_APP not found"; exit 1; } ;;
esac

echo "========================================================="
echo "  VL53L9CX LiDAR Web Viewer (binning $BIN, ${EXP}ms, 100 Hz)"
echo "========================================================="

[ -x ./vl53l9_bringup ] || make -s || exit 1

echo "[+] Clearing previous consumers..."
pkill -f 'web_vie[w].py' 2>/dev/null
pkill -f 'lidar_we[b].py' 2>/dev/null
pkill -f 'headless_dec[o]de.py' 2>/dev/null
pkill -f 'v4l2-ctl.*stream-mmap' 2>/dev/null
sleep 1

vl_pi5_ext_clock
vl_pi5_reset_sensor
vl_pi5_find_bus "$REPO"
vl_pi5_find_nodes
echo "[+] Configuring CFE pipeline (RAW8 ${WIDTH}x${HEIGHT})..."
vl_pi5_configure "$REPO" "$WIDTH" "$HEIGHT"
echo "[+] Receiver line stride: $VL_STRIDE bytes"

echo "[+] Launching $(basename "$APP") on $PIPE (port $PORT)..."
rm -f "$PIPE"
mkfifo "$PIPE"
VL_BINNING=$BIN VL_STRIDE=$VL_STRIDE VL_PIPE=$PIPE VL_PORT=$PORT \
    nohup python3 "$APP" >/tmp/lidar_web.log 2>&1 &
APP_PID=$!
sleep 1
kill -0 "$APP_PID" 2>/dev/null || { tail -20 /tmp/lidar_web.log; vl_die "viewer exited at startup"; }

# Arm the receiver BEFORE starting the sensor: CFE needs to see the D-PHY's
# LP->HS transition at stream start.
echo "[+] Arming V4L2 receiver ($VL_VIDEO -> $PIPE)..."
nohup v4l2-ctl -d "$VL_VIDEO" --stream-mmap --stream-to="$PIPE" >/tmp/v4l2_web.log 2>&1 &
V4L2_PID=$!
sleep 1.5
kill -0 "$V4L2_PID" 2>/dev/null || { tail -20 /tmp/v4l2_web.log; vl_die "v4l2-ctl exited at startup"; }

echo "[+] Booting sensor + starting MIPI stream on $VL_I2C_BUS..."
./vl53l9_bringup --i2c "$VL_I2C_BUS" 1 $EXP $PERIOD $POWER $DSS >/tmp/bringup_web.log 2>&1
BRINGUP_RC=$?
grep -E 'SUCCESS|WARNING|No sensor response|ret=-|\[-\]' /tmp/bringup_web.log || true
if [ "$BRINGUP_RC" -ne 0 ] || ! grep -q 'STREAMING' /tmp/bringup_web.log; then
    echo "[-] bring-up did not reach STREAMING (rc=$BRINGUP_RC); full log: /tmp/bringup_web.log"
    exit 1
fi

IP=$(hostname -I | awk '{print $1}')
echo ""
echo "========================================================="
echo "  Open the dashboard in a browser on any LAN device:"
echo "      http://${IP}:${PORT}"
echo "  Stop: pkill -f '$(basename "$APP")'; pkill -f 'v4l2-ctl.*stream-mmap'"
echo "========================================================="
