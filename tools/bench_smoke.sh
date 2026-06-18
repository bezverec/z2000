#!/bin/sh
set -eu

python3 tools/make_bench_tiff.py 2048 2048 bench-rgb-2048.tif >/dev/null
zig build -Doptimize=ReleaseFast >/dev/null
./zig-out/bin/z2000 tiff-to-jp2 bench-rgb-2048.tif bench-ours.jp2 >/dev/null

hyperfine --warmup 2 --runs 8 \
  './zig-out/bin/z2000 tiff-to-jp2 bench-rgb-2048.tif bench-ours.jp2' \
  './zig-out/bin/z2000 decode-temp-jp2 bench-ours.jp2 bench-ours-decoded.tif' \
  'opj_compress -i bench-rgb-2048.tif -o bench-openjpeg.jp2' \
  'grk_compress -i bench-rgb-2048.tif -o bench-grok.jp2'

hyperfine --warmup 2 --runs 8 \
  'opj_decompress -i bench-openjpeg.jp2 -o bench-openjpeg-decoded.tif -quiet' \
  'grk_decompress -i bench-grok.jp2 -o bench-grok-decoded.tif'
