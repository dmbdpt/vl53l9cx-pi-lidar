#!/bin/bash
# Rebind the RP1 CFE driver, XSHUT-cycle the sensor and check it answers on I2C.
set -u
REPO="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
[ -x "$REPO/tools/i2c_id" ] || make -C "$REPO/tools" >/dev/null
CFE=$(basename "$(readlink -f /sys/bus/platform/drivers/rp1-cfe/*.csi 2>/dev/null | head -1)")
[ -n "$CFE" ] && [ "$CFE" != . ] || CFE=1f00110000.csi
echo "=== rebind rp1-cfe ($CFE) ==="
echo "$CFE" > /sys/bus/platform/drivers/rp1-cfe/unbind 2>/dev/null
echo "$CFE" > /sys/bus/platform/drivers/rp1-cfe/bind && echo REBIND_OK || echo REBIND_FAIL
dmesg | tail -3
echo 1 > /sys/devices/platform/vl53l9/xshut_cycle
"$REPO/tools/i2c_id" /dev/i2c-6 /dev/i2c-4
