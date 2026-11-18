"""
vl53l9_stream -- read VL53L9CX frames from the CSI capture FIFO as numpy arrays.

The launchers (run_lidar_web.sh / run_stream_test.sh on the Pi 5) arm the CSI
receiver with `v4l2-ctl --stream-to=<fifo>`. This module reads that FIFO and
decodes each frame of the ST result buffer:

    [ distance u16 x N | amplitude u16 x N | ambient u16 x N | DSS 4-bit x N | meta ]

Distance words: bits 0-14 = radial distance in mm, bit 15 = 1 for a valid
measurement (not in the datasheet; confirmed on hardware by independent drivers).

Usage:
    from vl53l9_stream import FrameReader
    with FrameReader() as reader:           # env: VL_PIPE, VL_BINNING, VL_STRIDE
        for f in reader:
            print(f.seq, f.depth_mm[f.valid].min())

Or run your own script through the Pi 5 launcher, which sets those env vars:
    VL_APP=path/to/your_script.py ./run_lidar_web.sh
"""
from __future__ import annotations

import os
import time
from dataclasses import dataclass

import numpy as np

# binning -> (zones wide, zones high, captured CSI lines)
GEOM = {2: (54, 42, 148), 4: (24, 24, 38)}
CSI_W = 100          # payload bytes per CSI line
DIST_MASK = 0x7FFF
VALID_BIT = 0x8000


@dataclass
class Frame:
    seq: int                 # frame counter (host side)
    t: float                 # host timestamp, time.monotonic()
    depth_mm: np.ndarray     # (H, W) uint16, radial mm; 0 where invalid
    valid: np.ndarray        # (H, W) bool
    amplitude: np.ndarray    # (H, W) uint16, signal strength
    ambient: np.ndarray      # (H, W) uint16, ambient light


def decode(buf: bytes, binning: int = 2, stride: int = 112) -> tuple:
    """Decode one captured frame (stride * lines bytes) into (depth, valid, amp, amb)."""
    w, h, lines = GEOM[binning]
    n = w * h
    rows = np.frombuffer(buf, np.uint8, count=stride * lines).reshape(lines, stride)
    payload = np.ascontiguousarray(rows[:, :CSI_W]).reshape(-1)
    words = payload[: 6 * n].view("<u2")
    dist, amp, amb = words[:n], words[n:2 * n], words[2 * n:3 * n]
    valid = (dist & VALID_BIT) != 0
    depth = np.where(valid, dist & DIST_MASK, 0).astype(np.uint16)
    return (depth.reshape(h, w), valid.reshape(h, w),
            amp.reshape(h, w).copy(), amb.reshape(h, w).copy())


class FrameReader:
    """Iterate decoded frames from the capture FIFO. Blocks until frames arrive."""

    def __init__(self, pipe: str | None = None, binning: int | None = None,
                 stride: int | None = None):
        self.pipe = pipe or os.environ.get("VL_PIPE", "/tmp/tof_pipe_web")
        self.binning = binning or int(os.environ.get("VL_BINNING", "2"))
        # Pi 5 CFE: 112, Pi 4 Unicam: 128. The Pi 5 launchers export the real value.
        self.stride = stride or int(os.environ.get("VL_STRIDE", "112"))
        self.frame_bytes = self.stride * GEOM[self.binning][2]
        self._f = None
        self._seq = 0

    def open(self):
        self._f = open(self.pipe, "rb", buffering=0)
        return self

    def close(self):
        if self._f:
            self._f.close()
            self._f = None

    def __enter__(self):
        return self.open()

    def __exit__(self, *exc):
        self.close()

    def _read_exact(self) -> bytes:
        buf = bytearray(self.frame_bytes)
        view, got = memoryview(buf), 0
        while got < self.frame_bytes:
            n = self._f.readinto(view[got:])
            if not n:
                raise EOFError("capture FIFO closed (v4l2-ctl stopped?)")
            got += n
        return bytes(buf)

    def read(self) -> Frame:
        if self._f is None:
            self.open()
        raw = self._read_exact()
        depth, valid, amp, amb = decode(raw, self.binning, self.stride)
        self._seq += 1
        return Frame(self._seq, time.monotonic(), depth, valid, amp, amb)

    def __iter__(self):
        while True:
            try:
                yield self.read()
            except EOFError:
                return
