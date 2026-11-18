#!/bin/bash
# Live RPi5 test for dummy_cam XSHUT sysfs control.
# Run as root (or with scripts/99-vl53l9.rules installed) with dummy_cam loaded:
#   sudo bash scripts/test/test_power_cycle.sh
set -u
REPO="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
[ -x "$REPO/tools/i2c_id" ] || make -C "$REPO/tools" >/dev/null
D=/sys/devices/platform/vl53l9
fail() { echo "FAIL: $*"; exit 1; }

echo "=== [1] module + attrs present ==="
lsmod | grep -q dummy_cam || fail "dummy_cam not loaded"
for a in xshut_cycle xshut_state; do
    [ -f "$D/$a" ] && echo "OK: $a (mode $(stat -c '%a %G' "$D/$a"))" || fail "no $a"
done
[ "$(cat $D/xshut_state)" = unavailable ] && fail "no xshut-gpios in DT (wrong overlay?)"

echo "=== [2] shutdown: XSHUT LOW -> sensor must NOT ACK ==="
echo 0 > $D/xshut_state || fail "write 0 to xshut_state"
sleep 0.05
[ "$(cat $D/xshut_state)" = 0 ] || fail "xshut_state readback != 0"
"$REPO/tools/i2c_id" >/dev/null && fail "sensor still ACKs with XSHUT LOW (XSHUT on a different line?)"
echo "OK: no ACK while in shutdown"

echo "=== [3] xshut_cycle -> sensor boots and ACKs ==="
t0=$(date +%s%N)
echo 1 > $D/xshut_cycle || fail "xshut_cycle write"
echo "cycle took $(( ($(date +%s%N)-t0)/1000000 )) ms (expect ~210)"
[ "$(cat $D/xshut_state)" = 1 ] || fail "xshut_state readback != 1"
"$REPO/tools/i2c_id" || fail "no ACK at 0x29 after cycle"

echo "=== [4] second cycle ==="
echo 1 > $D/xshut_cycle && "$REPO/tools/i2c_id" >/dev/null || fail "no ACK after cycle #2"
echo "OK"

echo "=== [5] invalid input rejected ==="
echo 0 > $D/xshut_cycle 2>/dev/null && fail "xshut_cycle accepted 0" || echo "OK: 0 rejected"
echo abc > $D/xshut_cycle 2>/dev/null && fail "xshut_cycle accepted garbage" || echo "OK: garbage rejected"

echo "=== [6] dmesg ==="
dmesg | grep -iE 'dummy_cam|vl53l9|xshut' | tail -8
echo "=== PASS ==="
