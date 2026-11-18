# shellcheck shell=bash
# Shared Raspberry Pi 5 (RP1 CFE) pipeline helpers. Source this file; it does
# not run anything on its own.
#
#   vl_pi5_reset_sensor            XSHUT-cycle the sensor (fresh READY_TO_BOOT)
#   vl_pi5_find_bus                -> VL_I2C_BUS  (bus where 0x29 ACKs)
#   vl_pi5_find_nodes              -> VL_MEDIA VL_SENSOR_SD VL_CSI2_SD VL_VIDEO
#   vl_pi5_configure W H           set pad/video formats, enable link -> VL_STRIDE
#
# Device numbers (/dev/mediaN, /dev/v4l-subdevN, /dev/videoN) depend on probe
# order, so every node is looked up by media-entity name instead.

VL_XSHUT_DIR=/sys/devices/platform/vl53l9
VL_SRGGB8=0x3014   # MEDIA_BUS_FMT_SRGGB8_1X8 (v4l2-ctl wants the number)

vl_die() { echo "[-] $*" >&2; exit 1; }

# Write to a dummy_cam sysfs attribute; use sudo only if the udev rule
# (scripts/99-vl53l9.rules) hasn't made it group-writable.
vl_xshut_write() {
    local attr="$VL_XSHUT_DIR/$1" val="$2"
    [ -e "$attr" ] || vl_die "$attr missing -- is dummy_cam loaded and the vl53l9-mipi-pi5 overlay active?"
    if [ -w "$attr" ]; then
        echo "$val" > "$attr"
    else
        echo "[i] $attr is root-only; using sudo (install scripts/99-vl53l9.rules to avoid this)"
        sudo sh -c "echo $val > $attr"
    fi
}

# Always give the sensor a fresh XSHUT edge. A sensor left in STANDBY or
# STREAMING by a previous run can't be re-profiled, so repeat runs need this.
vl_pi5_reset_sensor() {
    local st
    st=$(cat "$VL_XSHUT_DIR/xshut_state" 2>/dev/null || echo missing)
    [ "$st" = unavailable ] && vl_die "dummy_cam has no xshut-gpios (wrong overlay?)"
    echo "[+] XSHUT cycle (sensor -> READY_TO_BOOT)..."
    vl_xshut_write xshut_cycle 1 || vl_die "XSHUT cycle failed"
    sleep 0.1
}

# Find the camera I2C bus the sensor ACKs on (MIPI0 = i2c-6, MIPI1 = i2c-4).
vl_pi5_find_bus() {
    local repo="$1" b
    if [ -n "${VL_I2C_BUS:-}" ]; then echo "[i] using VL_I2C_BUS=$VL_I2C_BUS"; return; fi
    [ -x "$repo/tools/i2c_id" ] || make -sC "$repo/tools" || vl_die "building tools failed"
    for b in /dev/i2c-6 /dev/i2c-4; do
        if "$repo/tools/i2c_id" "$b" >/dev/null 2>&1; then
            VL_I2C_BUS=$b; echo "[+] sensor ACKs on $b"; return
        fi
    done
    vl_die "sensor did not ACK on /dev/i2c-6 or /dev/i2c-4 after the XSHUT cycle.
    Check: FFC seated, overlay connector matches the cable (cam0 = MIPI0),
    12 MHz clock on the STEVAL AP_CLK (onboard oscillator or external GPCLK)."
}

vl_pi5_find_nodes() {
    local m
    command -v media-ctl >/dev/null || vl_die "media-ctl not found (sudo apt install v4l-utils)"
    VL_MEDIA=""
    for m in /dev/media*; do
        [ -e "$m" ] || continue
        if media-ctl -d "$m" -e rp1-cfe-csi2_ch0 >/dev/null 2>&1; then VL_MEDIA=$m; break; fi
    done
    [ -n "$VL_MEDIA" ] || vl_die "no rp1-cfe media device -- is the overlay active (csi enabled)?"
    VL_SENSOR_SD=$(media-ctl -d "$VL_MEDIA" -e dummy-csi2 2>/dev/null)
    VL_CSI2_SD=$(media-ctl -d "$VL_MEDIA" -e csi2 2>/dev/null)
    VL_VIDEO=$(media-ctl -d "$VL_MEDIA" -e rp1-cfe-csi2_ch0 2>/dev/null)
    [ -n "$VL_SENSOR_SD" ] || vl_die "dummy-csi2 entity not in $VL_MEDIA -- dummy_cam not bound?"
    [ -n "$VL_CSI2_SD" ] && [ -n "$VL_VIDEO" ] || vl_die "csi2 / csi2_ch0 entities missing in $VL_MEDIA"
    echo "[+] media=$VL_MEDIA sensor=$VL_SENSOR_SD csi2=$VL_CSI2_SD video=$VL_VIDEO"
}

# Configure sensor pad -> csi2 sink -> csi2 ch0 source -> video node, enable
# the csi2 -> ch0 link, and read back the receiver's real line stride.
vl_pi5_configure() {
    local repo="$1" w="$2" h="$3" out
    [ -x "$repo/tools/set_fmt" ] || make -sC "$repo/tools" || vl_die "building tools failed"
    v4l2-ctl -d "$VL_SENSOR_SD" --set-subdev-fmt "pad=0,width=$w,height=$h,code=$VL_SRGGB8" \
        || vl_die "setting sensor pad format failed"
    v4l2-ctl -d "$VL_CSI2_SD" --set-subdev-fmt "pad=0,width=$w,height=$h,code=$VL_SRGGB8" \
        || vl_die "setting csi2 sink format failed"
    v4l2-ctl -d "$VL_CSI2_SD" --set-subdev-fmt "pad=4,width=$w,height=$h,code=$VL_SRGGB8" \
        || vl_die "setting csi2 ch0 format failed"
    out=$("$repo/tools/set_fmt" 0 "$VL_VIDEO" "$w" "$h" RGGB) || vl_die "VIDIOC_S_FMT failed: $out"
    echo "    $out"
    VL_STRIDE=$(sed -n 's/.*bpl=\([0-9]*\).*/\1/p' <<<"$out")
    [ -n "$VL_STRIDE" ] || vl_die "could not read bytesperline from set_fmt"
    media-ctl -d "$VL_MEDIA" -l '"csi2":4->"rp1-cfe-csi2_ch0":0 [1]' \
        || vl_die "enabling csi2 -> csi2_ch0 link failed"
}
