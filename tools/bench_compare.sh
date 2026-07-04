#!/bin/sh
# Comparative benchmark: z2000 vs Grok vs OpenJPEG on one uncompressed RGB TIFF.
# Usage: sh tools/bench_compare.sh [input.tif]
# Requires: hyperfine, grk_compress/grk_decompress, opj_compress/opj_decompress.
set -eu

INPUT=${1:-bench-rgb-2048.tif}
RUNS=${RUNS:-8}
ZIG_BUILD_FLAGS=${ZIG_BUILD_FLAGS:-}
PRECINCTS='[256,256],[256,256],[128,128],[128,128],[128,128],[128,128]'

detect_logical_threads() {
  if command -v getconf >/dev/null 2>&1; then
    n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
    if [ -n "${n:-}" ] && [ "$n" -gt 0 ] 2>/dev/null; then
      echo "$n"
      return
    fi
  fi
  if command -v nproc >/dev/null 2>&1; then
    n=$(nproc 2>/dev/null || true)
    if [ -n "${n:-}" ] && [ "$n" -gt 0 ] 2>/dev/null; then
      echo "$n"
      return
    fi
  fi
  if command -v sysctl >/dev/null 2>&1; then
    n=$(sysctl -n hw.ncpu 2>/dev/null || true)
    if [ -n "${n:-}" ] && [ "$n" -gt 0 ] 2>/dev/null; then
      echo "$n"
      return
    fi
  fi
  if [ -n "${NUMBER_OF_PROCESSORS:-}" ] && [ "$NUMBER_OF_PROCESSORS" -gt 0 ] 2>/dev/null; then
    echo "$NUMBER_OF_PROCESSORS"
    return
  fi
  echo 4
}

resolve_z2000_threads() {
  case "${Z2000_THREADS:-all}" in
    ""|all|auto) detect_logical_threads ;;
    *) echo "$Z2000_THREADS" ;;
  esac
}

THREADS=$(resolve_z2000_threads)

if [ ! -f "$INPUT" ]; then
  python3 tools/make_bench_tiff.py 2048 2048 "$INPUT" >/dev/null
fi

for tool in hyperfine grk_compress grk_decompress opj_compress opj_decompress; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool" >&2; exit 1; }
done

zig build -Doptimize=ReleaseFast $ZIG_BUILD_FLAGS >/dev/null
Z=./zig-out/bin/z2000

echo "== host: $(uname -m), threads=$THREADS, input=$INPUT, zig_flags=${ZIG_BUILD_FLAGS:-default} =="

echo
echo "== ENCODE (archival profile parity: RPCL, 6 res, precincts, 64x64, SOP+EPH+TLM, bypass) =="
hyperfine --warmup 2 --runs "$RUNS" \
  --command-name "z2000 t1"          "$Z tiff-to-jp2 $INPUT bz-t1.jp2 --tile 4096,4096 --progression RPCL --resolutions 6 --precincts \"$PRECINCTS\" --block 64 --layers 1 --tile-parts R --sop --eph --tlm --bypass" \
  --command-name "z2000 t$THREADS"   "$Z tiff-to-jp2 $INPUT bz-tN.jp2 --tile 4096,4096 --progression RPCL --resolutions 6 --precincts \"$PRECINCTS\" --block 64 --layers 1 --tile-parts R --sop --eph --tlm --bypass --threads $THREADS" \
  --command-name "grk_compress"      "grk_compress -i $INPUT -o bg.jp2 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -X -M 1 -S -E -u R" \
  --command-name "opj_compress"      "opj_compress -i $INPUT -o bo.jp2 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -TLM -M 1 -SOP -EPH -TP R"

echo
echo "== SIZES =="
ls -l "$INPUT" bz-tN.jp2 bg.jp2 bo.jp2 | awk '{printf "%-14s %10d B\n", $NF, $5}'

echo
echo "== DECODE own files =="
hyperfine --warmup 2 --runs "$RUNS" \
  --command-name "z2000 t1"        "$Z decode-temp-jp2 bz-tN.jp2 dz1.tif" \
  --command-name "z2000 t$THREADS" "$Z decode-temp-jp2 bz-tN.jp2 dzN.tif --threads $THREADS" \
  --command-name "grk_decompress"  "grk_decompress -i bg.jp2 -o dg.tif" \
  --command-name "opj_decompress"  "opj_decompress -i bo.jp2 -o do.tif -quiet"

echo
echo "== CROSS-DECODE z2000 output (interop timing) =="
hyperfine --warmup 2 --runs "$RUNS" \
  --command-name "grk <- z2000" "grk_decompress -i bz-tN.jp2 -o xg.tif" \
  --command-name "opj <- z2000" "opj_decompress -i bz-tN.jp2 -o xo.tif -quiet"

echo
echo "== LOSSLESS VERIFICATION =="
cmp dz1.tif dzN.tif && echo "z2000 t1 == t$THREADS: OK"
if python3 -c "import PIL" >/dev/null 2>&1; then
  python3 tools/compare_tiff.py "$INPUT" dz1.tif "z2000 self-decode"
  python3 tools/compare_tiff.py "$INPUT" xg.tif  "grok decode of z2000"
  python3 tools/compare_tiff.py "$INPUT" xo.tif  "openjpeg decode of z2000"
else
  echo "pixel check skipped: pip install pillow to enable tools/compare_tiff.py"
fi
