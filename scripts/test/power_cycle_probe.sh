#!/bin/bash
# XSHUT-cycle the VL53L9 via sysfs and poll the camera I2C buses for the sensor.
# Also reports undervoltage/throttling, which can stop the sensor booting.
uptime
echo ===UNDERVOLTAGE===
dmesg | grep -c -i undervoltage
vcgencmd get_throttled 2>/dev/null || true
REPO="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
[ -x "$REPO/tools/i2c_id" ] || make -C "$REPO/tools" >/dev/null
echo ===CYCLE+PROBE===
echo 1 > /sys/devices/platform/vl53l9/xshut_cycle
for i in $(seq 1 12); do
    if "$REPO/tools/i2c_id" /dev/i2c-6 /dev/i2c-4; then echo "t=${i}s: sensor up"; exit 0; fi
    echo "t=${i}s: no ACK"; sleep 1
done
exit 1
