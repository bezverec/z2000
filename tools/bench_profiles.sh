#!/bin/sh
set -eu

INPUT=${1:-bench-rgb-2048.tif}

if [ ! -f "$INPUT" ]; then
  python3 tools/make_bench_tiff.py 2048 2048 "$INPUT" >/dev/null
fi

zig build -Doptimize=ReleaseFast >/dev/null

PRECINCTS='[256,256],[256,256],[128,128],[128,128],[128,128],[128,128]'
RATES='362,256,181,128,90,64,45,32,22,16,11,8'

./zig-out/bin/z2000 tiff-to-jp2 "$INPUT" bench-ours-profile-timings.jp2 \
  --tile 4096,4096 --progression RPCL --resolutions 6 --precincts "$PRECINCTS" \
  --block 64 --layers 1 --tile-parts R --bypass --sop --eph --tlm --timings >/dev/null

hyperfine --warmup 2 --runs 6 \
  "./zig-out/bin/z2000 tiff-to-jp2 $INPUT bench-ours-profile.jp2 --tile 4096,4096 --progression RPCL --resolutions 6 --precincts \"$PRECINCTS\" --block 64 --layers 1 --tile-parts R --bypass --sop --eph --tlm" \
  "grk_compress -i $INPUT -o bench-grok-profile.jp2 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -X -M 1 -S -E -u R" \
  "opj_compress -i $INPUT -o bench-openjpeg-profile.jp2 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -TLM -M 1 -SOP -EPH -TP R"

hyperfine --warmup 2 --runs 6 \
  "./zig-out/bin/z2000 decode-temp-jp2 bench-ours-profile.jp2 bench-ours-profile-decoded.tif" \
  "grk_decompress -i bench-grok-profile.jp2 -o bench-grok-profile-decoded.tif" \
  "opj_decompress -i bench-openjpeg-profile.jp2 -o bench-openjpeg-profile-decoded.tif -quiet"

hyperfine --warmup 2 --runs 6 \
  "grk_compress -i $INPUT -o bench-grok-access.jp2 -r \"$RATES\" -I -t 1024,1024 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -X -M 1 -u R -H 4" \
  "opj_compress -i $INPUT -o bench-openjpeg-access.jp2 -r \"$RATES\" -I -t 1024,1024 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -TLM -M 1 -TP R"

hyperfine --warmup 2 --runs 5 \
  "./zig-out/bin/z2000 tiff-to-jp2 $INPUT bench-ours-r6-b64.jp2 --resolutions 6 --block 64 --tile-parts R --tlm" \
  "./zig-out/bin/z2000 tiff-to-jp2 $INPUT bench-ours-r6-b32.jp2 --resolutions 6 --block 32 --tile-parts R --tlm" \
  "./zig-out/bin/z2000 tiff-to-jp2 $INPUT bench-ours-r4-b64.jp2 --resolutions 4 --block 64 --tile-parts R --tlm"

ls -lh \
  bench-ours-profile.jp2 \
  bench-grok-profile.jp2 \
  bench-openjpeg-profile.jp2 \
  bench-grok-access.jp2 \
  bench-openjpeg-access.jp2 \
  bench-ours-r6-b32.jp2 \
  bench-ours-r4-b64.jp2
