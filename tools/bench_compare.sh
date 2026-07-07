#!/bin/sh
# Comparative benchmark: z2000 vs Grok vs OpenJPEG vs Kakadu on one
# uncompressed RGB TIFF. Usage: sh tools/bench_compare.sh [input.tif]
# Requires: hyperfine plus at least one of grk_compress/opj_compress/
# kdu_compress (each reference codec is optional and benched when present;
# Kakadu demo apps live outside PATH on Windows — set KDU_COMPRESS/KDU_EXPAND).
set -eu

INPUT=${1:-bench-rgb-2048.tif}
RUNS=${RUNS:-8}
ZIG_BUILD_FLAGS=${ZIG_BUILD_FLAGS:-}
PRECINCTS='[256,256],[256,256],[128,128],[128,128],[128,128],[128,128]'
# Kakadu Cprecincts uses its own brace syntax; the trailing entry repeats.
KDU_PRECINCTS='{256,256},{256,256},{128,128}'
KDU_COMPRESS=${KDU_COMPRESS:-kdu_compress}
KDU_EXPAND=${KDU_EXPAND:-kdu_expand}

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

command -v hyperfine >/dev/null 2>&1 || { echo "missing: hyperfine" >&2; exit 1; }
HAS_GRK=0; HAS_OPJ=0; HAS_KDU=0
command -v grk_compress >/dev/null 2>&1 && command -v grk_decompress >/dev/null 2>&1 && HAS_GRK=1
command -v opj_compress >/dev/null 2>&1 && command -v opj_decompress >/dev/null 2>&1 && HAS_OPJ=1
command -v "$KDU_COMPRESS" >/dev/null 2>&1 && command -v "$KDU_EXPAND" >/dev/null 2>&1 && HAS_KDU=1
if [ "$HAS_GRK" = 0 ] && [ "$HAS_OPJ" = 0 ] && [ "$HAS_KDU" = 0 ]; then
  echo "missing reference codecs: need grk_compress, opj_compress, or kdu_compress" >&2
  exit 1
fi

zig build -Doptimize=ReleaseFast $ZIG_BUILD_FLAGS >/dev/null
Z=./zig-out/bin/z2000

echo "== host: $(uname -m), threads=$THREADS, input=$INPUT, zig_flags=${ZIG_BUILD_FLAGS:-default} =="
echo "== reference codecs: grok=$HAS_GRK openjpeg=$HAS_OPJ kakadu=$HAS_KDU =="

echo
echo "== ENCODE (archival profile parity: RPCL, 6 res, precincts, 64x64, SOP+EPH+TLM, bypass) =="
set -- --warmup 2 --runs "$RUNS" \
  --command-name "z2000 t1"          "$Z tiff-to-jp2 $INPUT bz-t1.jp2 --tile 4096,4096 --progression RPCL --resolutions 6 --precincts \"$PRECINCTS\" --block 64 --layers 1 --tile-parts R --sop --eph --tlm --bypass" \
  --command-name "z2000 t$THREADS"   "$Z tiff-to-jp2 $INPUT bz-tN.jp2 --tile 4096,4096 --progression RPCL --resolutions 6 --precincts \"$PRECINCTS\" --block 64 --layers 1 --tile-parts R --sop --eph --tlm --bypass --threads $THREADS"
[ "$HAS_GRK" = 1 ] && set -- "$@" \
  --command-name "grk_compress"      "grk_compress -i $INPUT -o bg.jp2 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -X -M 1 -S -E -u R"
[ "$HAS_OPJ" = 1 ] && set -- "$@" \
  --command-name "opj_compress"      "opj_compress -i $INPUT -o bo.jp2 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -TLM -M 1 -SOP -EPH -TP R"
[ "$HAS_KDU" = 1 ] && set -- "$@" \
  --command-name "kdu t1"            "\"$KDU_COMPRESS\" -i $INPUT -o bk.jp2 Creversible=yes Clevels=5 Cblk={64,64} Cprecincts=$KDU_PRECINCTS Corder=RPCL Cuse_sop=yes Cuse_eph=yes Cmodes=BYPASS ORGgen_plt=yes ORGtparts=R ORGgen_tlm=6 -num_threads 0 -quiet" \
  --command-name "kdu t$THREADS"     "\"$KDU_COMPRESS\" -i $INPUT -o bk.jp2 Creversible=yes Clevels=5 Cblk={64,64} Cprecincts=$KDU_PRECINCTS Corder=RPCL Cuse_sop=yes Cuse_eph=yes Cmodes=BYPASS ORGgen_plt=yes ORGtparts=R ORGgen_tlm=6 -num_threads $THREADS -quiet"
hyperfine "$@"

echo
echo "== SIZES =="
size_files="$INPUT bz-tN.jp2"
[ "$HAS_GRK" = 1 ] && size_files="$size_files bg.jp2"
[ "$HAS_OPJ" = 1 ] && size_files="$size_files bo.jp2"
[ "$HAS_KDU" = 1 ] && size_files="$size_files bk.jp2"
ls -l $size_files | awk '{printf "%-14s %10d B\n", $NF, $5}'

echo
echo "== DECODE own files =="
set -- --warmup 2 --runs "$RUNS" \
  --command-name "z2000 t1"        "$Z decode-temp-jp2 bz-tN.jp2 dz1.tif" \
  --command-name "z2000 t$THREADS" "$Z decode-temp-jp2 bz-tN.jp2 dzN.tif --threads $THREADS"
[ "$HAS_GRK" = 1 ] && set -- "$@" \
  --command-name "grk_decompress"  "grk_decompress -i bg.jp2 -o dg.tif"
[ "$HAS_OPJ" = 1 ] && set -- "$@" \
  --command-name "opj_decompress"  "opj_decompress -i bo.jp2 -o do.tif -quiet"
[ "$HAS_KDU" = 1 ] && set -- "$@" \
  --command-name "kdu t1"          "\"$KDU_EXPAND\" -i bk.jp2 -o dk.tif -num_threads 0 -quiet" \
  --command-name "kdu t$THREADS"   "\"$KDU_EXPAND\" -i bk.jp2 -o dk.tif -num_threads $THREADS -quiet"
hyperfine "$@"

echo
echo "== CROSS-DECODE z2000 output (interop timing) =="
set -- --warmup 2 --runs "$RUNS"
[ "$HAS_GRK" = 1 ] && set -- "$@" --command-name "grk <- z2000" "grk_decompress -i bz-tN.jp2 -o xg.tif"
[ "$HAS_OPJ" = 1 ] && set -- "$@" --command-name "opj <- z2000" "opj_decompress -i bz-tN.jp2 -o xo.tif -quiet"
[ "$HAS_KDU" = 1 ] && set -- "$@" --command-name "kdu <- z2000" "\"$KDU_EXPAND\" -i bz-tN.jp2 -o xk.tif -quiet"
hyperfine "$@"

echo
echo "== LOSSLESS VERIFICATION =="
cmp dz1.tif dzN.tif && echo "z2000 t1 == t$THREADS: OK"
if python3 -c "import PIL" >/dev/null 2>&1; then
  python3 tools/compare_tiff.py "$INPUT" dz1.tif "z2000 self-decode"
  [ "$HAS_GRK" = 1 ] && python3 tools/compare_tiff.py "$INPUT" xg.tif "grok decode of z2000"
  [ "$HAS_OPJ" = 1 ] && python3 tools/compare_tiff.py "$INPUT" xo.tif "openjpeg decode of z2000"
  [ "$HAS_KDU" = 1 ] && python3 tools/compare_tiff.py "$INPUT" xk.tif "kakadu decode of z2000"
else
  echo "pixel check skipped: pip install pillow to enable tools/compare_tiff.py"
fi
