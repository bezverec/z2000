#!/usr/bin/env python3
import pathlib
import struct
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: make_bench_tiff.py <width> <height> <output.tif>", file=sys.stderr)
        return 2

    width = int(sys.argv[1])
    height = int(sys.argv[2])
    out_path = pathlib.Path(sys.argv[3])

    entry_count = 10
    bits_offset = 8 + 2 + entry_count * 12 + 4
    raster_offset = bits_offset + 6
    raster_bytes = width * height * 3

    entries = [
        (256, 4, 1, width),
        (257, 4, 1, height),
        (258, 3, 3, bits_offset),
        (259, 3, 1, 1),
        (262, 3, 1, 2),
        (273, 4, 1, raster_offset),
        (277, 3, 1, 3),
        (278, 4, 1, height),
        (279, 4, 1, raster_bytes),
        (284, 3, 1, 1),
    ]

    header = bytearray()
    header += b"II" + struct.pack("<HI", 42, 8)
    header += struct.pack("<H", entry_count)
    for entry in entries:
        header += struct.pack("<HHII", *entry)
    header += struct.pack("<I", 0)
    header += struct.pack("<HHH", 8, 8, 8)

    row = bytearray(width * 3)
    for x in range(width):
        red = (x * 255) // max(width - 1, 1)
        row[x * 3] = red
        row[x * 3 + 2] = 255 - red

    with out_path.open("wb") as f:
        f.write(header)
        for y in range(height):
            green = (y * 255) // max(height - 1, 1)
            for x in range(width):
                row[x * 3 + 1] = green ^ ((x * 17 + y * 31) & 0x3f)
            f.write(row)

    print(out_path.stat().st_size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
