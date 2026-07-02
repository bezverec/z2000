#!/usr/bin/env python3
"""Pixel-exact comparison of two images (any format PIL reads)."""
import sys

import numpy as np
from PIL import Image


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: compare_tiff.py <a> <b> [label]", file=sys.stderr)
        return 2
    label = sys.argv[3] if len(sys.argv) > 3 else f"{sys.argv[1]} vs {sys.argv[2]}"
    a = np.array(Image.open(sys.argv[1]))
    b = np.array(Image.open(sys.argv[2]))
    if a.shape != b.shape:
        print(f"{label}: SHAPE MISMATCH {a.shape} vs {b.shape}")
        return 1
    if np.array_equal(a, b):
        print(f"{label}: LOSSLESS OK")
        return 0
    diff = a.astype(np.int64) - b.astype(np.int64)
    print(f"{label}: DIFFERS (max {abs(diff).max()}, pixels {np.count_nonzero(diff.any(axis=-1))})")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
