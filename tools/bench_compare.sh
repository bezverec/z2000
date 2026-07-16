#!/bin/sh
# Comparative benchmark: z2000 vs Grok vs OpenJPEG vs Kakadu on one
# uncompressed RGB TIFF. Usage: sh tools/bench_compare.sh [input.tif]
# Requires: hyperfine plus at least one of grk_compress/opj_compress/
# kdu_compress. Each reference codec is optional and benched when present.
# Set KDU_HOME to either an extracted Linux demo-app directory or the macOS
# install root; explicit KDU_COMPRESS/KDU_EXPAND paths take precedence.
# Set Z2000_BIN to benchmark an existing binary instead of building in-tree.
# Set BENCH_RESULTS_DIR to retain Hyperfine JSON for all three benchmark groups.
set -eu

INPUT=${1:-bench-rgb-2048.tif}
RUNS=${RUNS:-8}
WARMUP=${WARMUP:-2}
ZIG_BUILD_FLAGS=${ZIG_BUILD_FLAGS:-}
Z2000_BIN=${Z2000_BIN:-}
INCLUDE_LOSSY=${INCLUDE_LOSSY:-0}
PRECINCTS='[256,256],[256,256],[128,128],[128,128],[128,128],[128,128]'
# Kakadu Cprecincts uses its own brace syntax; the trailing entry repeats.
KDU_PRECINCTS='{256,256},{256,256},{128,128}'
KDU_HOME=${KDU_HOME:-}
KDU_COMPRESS=${KDU_COMPRESS:-}
KDU_EXPAND=${KDU_EXPAND:-}
BENCH_RESULTS_DIR=${BENCH_RESULTS_DIR:-}

if [ -n "$KDU_HOME" ]; then
  if [ -x "$KDU_HOME/bin/kdu_compress" ]; then
    kdu_bin_dir=$KDU_HOME/bin
    kdu_lib_dir=$KDU_HOME/lib
  elif [ -x "$KDU_HOME/kdu_compress" ]; then
    kdu_bin_dir=$KDU_HOME
    kdu_lib_dir=$KDU_HOME
  else
    echo "KDU_HOME has no kdu_compress: $KDU_HOME" >&2
    exit 1
  fi
  KDU_COMPRESS=${KDU_COMPRESS:-$kdu_bin_dir/kdu_compress}
  KDU_EXPAND=${KDU_EXPAND:-$kdu_bin_dir/kdu_expand}
  case "$(uname -s 2>/dev/null || true)" in
    Darwin)
      DYLD_LIBRARY_PATH="$kdu_lib_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
      export DYLD_LIBRARY_PATH
      ;;
    *)
      LD_LIBRARY_PATH="$kdu_lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      export LD_LIBRARY_PATH
      ;;
  esac
fi
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

if [ -n "$BENCH_RESULTS_DIR" ]; then
  mkdir -p "$BENCH_RESULTS_DIR"
fi

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

if [ -n "$Z2000_BIN" ]; then
  Z=$Z2000_BIN
  [ -x "$Z" ] || { echo "Z2000_BIN is not executable: $Z" >&2; exit 1; }
else
  # ZIG_BUILD_FLAGS intentionally expands into zero or more separate flags.
  # shellcheck disable=SC2086
  zig build -Doptimize=ReleaseFast $ZIG_BUILD_FLAGS >/dev/null
  Z=./zig-out/bin/z2000
fi

echo "== host: $(uname -m), threads=$THREADS, input=$INPUT, zig_flags=${ZIG_BUILD_FLAGS:-default} =="
echo "== reference codecs: grok=$HAS_GRK openjpeg=$HAS_OPJ kakadu=$HAS_KDU =="

echo
echo "== ENCODE (archival profile parity: RPCL, 6 res, precincts, 64x64, SOP+EPH+TLM, bypass) =="
set -- --warmup "$WARMUP" --runs "$RUNS" \
  --command-name "z2000 t1"          "$Z tiff-to-jp2 $INPUT bench-compare-z2000-t1.jp2 --tile 4096,4096 --progression RPCL --resolutions 6 --precincts \"$PRECINCTS\" --block 64 --layers 1 --tile-parts R --sop --eph --tlm --bypass --threads 1" \
  --command-name "z2000 t$THREADS"   "$Z tiff-to-jp2 $INPUT bench-compare-z2000-tN.jp2 --tile 4096,4096 --progression RPCL --resolutions 6 --precincts \"$PRECINCTS\" --block 64 --layers 1 --tile-parts R --sop --eph --tlm --bypass --threads $THREADS"
[ "$HAS_GRK" = 1 ] && set -- "$@" \
  --command-name "grok t1"           "grk_compress -i $INPUT -o bench-compare-grok-t1.jp2 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -Y 1 -X -M 1 -S -E -u R -H 1 -G -2" \
  --command-name "grok t$THREADS"    "grk_compress -i $INPUT -o bench-compare-grok-tN.jp2 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -Y 1 -X -M 1 -S -E -u R -H $THREADS -G -2"
[ "$HAS_OPJ" = 1 ] && set -- "$@" \
  --command-name "openjpeg t1"       "opj_compress -i $INPUT -o bench-compare-openjpeg-t1.jp2 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -mct 1 -TLM -PLT -M 1 -SOP -EPH -TP R -threads 1" \
  --command-name "openjpeg t$THREADS" "opj_compress -i $INPUT -o bench-compare-openjpeg-tN.jp2 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -mct 1 -TLM -PLT -M 1 -SOP -EPH -TP R -threads $THREADS"
[ "$HAS_KDU" = 1 ] && set -- "$@" \
  --command-name "kdu t1"            "\"$KDU_COMPRESS\" -i $INPUT -o bench-compare-kakadu-t1.jp2 Creversible=yes Cycc=yes Clevels=5 Cblk={64,64} Cprecincts=$KDU_PRECINCTS Corder=RPCL Cuse_sop=yes Cuse_eph=yes Cmodes=BYPASS ORGtparts=R ORGgen_plt=yes ORGgen_tlm=6 -num_threads 0 -quiet" \
  --command-name "kdu t$THREADS"     "\"$KDU_COMPRESS\" -i $INPUT -o bench-compare-kakadu-tN.jp2 Creversible=yes Cycc=yes Clevels=5 Cblk={64,64} Cprecincts=$KDU_PRECINCTS Corder=RPCL Cuse_sop=yes Cuse_eph=yes Cmodes=BYPASS ORGtparts=R ORGgen_plt=yes ORGgen_tlm=6 -num_threads $THREADS -quiet"
[ -n "$BENCH_RESULTS_DIR" ] && set -- "$@" --export-json "$BENCH_RESULTS_DIR/encode.json"
hyperfine "$@"

echo
echo "== SIZES =="
size_files="$INPUT bench-compare-z2000-tN.jp2"
[ "$HAS_GRK" = 1 ] && size_files="$size_files bench-compare-grok-tN.jp2"
[ "$HAS_OPJ" = 1 ] && size_files="$size_files bench-compare-openjpeg-tN.jp2"
[ "$HAS_KDU" = 1 ] && size_files="$size_files bench-compare-kakadu-tN.jp2"
# size_files is a generated whitespace-separated list of fixed filenames.
# shellcheck disable=SC2012,SC2086
ls -l $size_files | awk '{printf "%-14s %10d B\n", $NF, $5}'

echo
echo "== DECODE own files =="
set -- --warmup "$WARMUP" --runs "$RUNS" \
  --command-name "z2000 t1"        "$Z decode-temp-jp2 bench-compare-z2000-tN.jp2 bench-compare-z2000-decoded-t1.tif --threads 1" \
  --command-name "z2000 t$THREADS" "$Z decode-temp-jp2 bench-compare-z2000-tN.jp2 bench-compare-z2000-decoded-tN.tif --threads $THREADS"
[ "$HAS_GRK" = 1 ] && set -- "$@" \
  --command-name "grok t1"         "grk_decompress -i bench-compare-grok-tN.jp2 -o bench-compare-grok-decoded-t1.tif -H 1 -G -2" \
  --command-name "grok t$THREADS"  "grk_decompress -i bench-compare-grok-tN.jp2 -o bench-compare-grok-decoded-tN.tif -H $THREADS -G -2"
[ "$HAS_OPJ" = 1 ] && set -- "$@" \
  --command-name "openjpeg t1"     "opj_decompress -i bench-compare-openjpeg-tN.jp2 -o bench-compare-openjpeg-decoded-t1.tif -quiet -threads 1" \
  --command-name "openjpeg t$THREADS" "opj_decompress -i bench-compare-openjpeg-tN.jp2 -o bench-compare-openjpeg-decoded-tN.tif -quiet -threads $THREADS"
[ "$HAS_KDU" = 1 ] && set -- "$@" \
  --command-name "kdu t1"          "\"$KDU_EXPAND\" -i bench-compare-kakadu-tN.jp2 -o bench-compare-kakadu-decoded-t1.tif -num_threads 0 -quiet" \
  --command-name "kdu t$THREADS"   "\"$KDU_EXPAND\" -i bench-compare-kakadu-tN.jp2 -o bench-compare-kakadu-decoded-tN.tif -num_threads $THREADS -quiet"
[ -n "$BENCH_RESULTS_DIR" ] && set -- "$@" --export-json "$BENCH_RESULTS_DIR/decode-own.json"
hyperfine "$@"

echo
echo "== CROSS-DECODE z2000 output (interop timing) =="
set -- --warmup "$WARMUP" --runs "$RUNS" \
  --command-name "z2000 t1"        "$Z decode-temp-jp2 bench-compare-z2000-tN.jp2 bench-compare-cross-z2000-t1.tif --threads 1" \
  --command-name "z2000 t$THREADS" "$Z decode-temp-jp2 bench-compare-z2000-tN.jp2 bench-compare-cross-z2000-tN.tif --threads $THREADS"
[ "$HAS_GRK" = 1 ] && set -- "$@" \
  --command-name "grok t1"         "grk_decompress -i bench-compare-z2000-tN.jp2 -o bench-compare-cross-grok-t1.tif -H 1 -G -2" \
  --command-name "grok t$THREADS"  "grk_decompress -i bench-compare-z2000-tN.jp2 -o bench-compare-cross-grok-tN.tif -H $THREADS -G -2"
[ "$HAS_OPJ" = 1 ] && set -- "$@" \
  --command-name "openjpeg t1"     "opj_decompress -i bench-compare-z2000-tN.jp2 -o bench-compare-cross-openjpeg-t1.tif -quiet -threads 1" \
  --command-name "openjpeg t$THREADS" "opj_decompress -i bench-compare-z2000-tN.jp2 -o bench-compare-cross-openjpeg-tN.tif -quiet -threads $THREADS"
[ "$HAS_KDU" = 1 ] && set -- "$@" \
  --command-name "kdu t1"          "\"$KDU_EXPAND\" -i bench-compare-z2000-tN.jp2 -o bench-compare-cross-kakadu-t1.tif -num_threads 0 -quiet" \
  --command-name "kdu t$THREADS"   "\"$KDU_EXPAND\" -i bench-compare-z2000-tN.jp2 -o bench-compare-cross-kakadu-tN.tif -num_threads $THREADS -quiet"
[ -n "$BENCH_RESULTS_DIR" ] && set -- "$@" --export-json "$BENCH_RESULTS_DIR/decode-cross.json"
hyperfine "$@"

echo
echo "== LOSSLESS VERIFICATION =="
cmp bench-compare-z2000-decoded-t1.tif bench-compare-z2000-decoded-tN.tif && echo "z2000 t1 == t$THREADS: OK"
if python3 -c "import PIL" >/dev/null 2>&1; then
  python3 tools/compare_tiff.py "$INPUT" bench-compare-z2000-decoded-t1.tif "z2000 self-decode"
  [ "$HAS_GRK" = 1 ] && python3 tools/compare_tiff.py "$INPUT" bench-compare-cross-grok-tN.tif "grok decode of z2000"
  [ "$HAS_OPJ" = 1 ] && python3 tools/compare_tiff.py "$INPUT" bench-compare-cross-openjpeg-tN.tif "openjpeg decode of z2000"
  [ "$HAS_KDU" = 1 ] && python3 tools/compare_tiff.py "$INPUT" bench-compare-cross-kakadu-tN.tif "kakadu decode of z2000"
elif command -v tiffcmp >/dev/null 2>&1; then
  tiffcmp "$INPUT" bench-compare-z2000-decoded-t1.tif
  echo "z2000 self-decode: LOSSLESS OK"
  if [ "$HAS_GRK" = 1 ]; then
    tiffcmp "$INPUT" bench-compare-cross-grok-tN.tif
    echo "grok decode of z2000: LOSSLESS OK"
  fi
  if [ "$HAS_OPJ" = 1 ]; then
    tiffcmp "$INPUT" bench-compare-cross-openjpeg-tN.tif
    echo "openjpeg decode of z2000: LOSSLESS OK"
  fi
  if [ "$HAS_KDU" = 1 ]; then
    tiffcmp "$INPUT" bench-compare-cross-kakadu-tN.tif
    echo "kakadu decode of z2000: LOSSLESS OK"
  fi
else
  echo "pixel check skipped: install Pillow or libtiff's tiffcmp"
fi

if [ "$INCLUDE_LOSSY" = 1 ]; then
  echo
  echo "== LOSSY 9/7 ENCODE (ICT, scalar quantization, 2 layers, complete final layer) =="
  set -- --warmup "$WARMUP" --runs "$RUNS" \
    --command-name "z2000 t1"        "$Z tiff-to-jp2 $INPUT bench-lossy-z2000-t1.jp2 --tile 4096,4096 --progression RPCL --resolutions 6 --precincts \"$PRECINCTS\" --block 64 --rates 8,1 --tile-parts R --sop --eph --tlm --transform 9-7 --mct ict --qstyle scalar-expounded --threads 1" \
    --command-name "z2000 t$THREADS" "$Z tiff-to-jp2 $INPUT bench-lossy-z2000-tN.jp2 --tile 4096,4096 --progression RPCL --resolutions 6 --precincts \"$PRECINCTS\" --block 64 --rates 8,1 --tile-parts R --sop --eph --tlm --transform 9-7 --mct ict --qstyle scalar-expounded --threads $THREADS"
  [ "$HAS_GRK" = 1 ] && set -- "$@" \
    --command-name "grok t1"         "grk_compress -i $INPUT -o bench-lossy-grok-t1.jp2 -I -r 8,1 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -X -S -E -u R -H 1 -G -2" \
    --command-name "grok t$THREADS"  "grk_compress -i $INPUT -o bench-lossy-grok-tN.jp2 -I -r 8,1 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -X -S -E -u R -H $THREADS -G -2"
  [ "$HAS_OPJ" = 1 ] && set -- "$@" \
    --command-name "openjpeg t1"        "opj_compress -i $INPUT -o bench-lossy-openjpeg-t1.jp2 -I -r 8,1 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -TLM -SOP -EPH -TP R -threads 1" \
    --command-name "openjpeg t$THREADS" "opj_compress -i $INPUT -o bench-lossy-openjpeg-tN.jp2 -I -r 8,1 -t 4096,4096 -p RPCL -n 6 -c \"$PRECINCTS\" -b 64,64 -TLM -SOP -EPH -TP R -threads $THREADS"
  [ "$HAS_KDU" = 1 ] && set -- "$@" \
    --command-name "kdu t1"          "\"$KDU_COMPRESS\" -i $INPUT -o bench-lossy-kakadu-t1.jp2 Creversible=no Clevels=5 Clayers=2 Cblk={64,64} Cprecincts=$KDU_PRECINCTS Corder=RPCL Cuse_sop=yes Cuse_eph=yes ORGtparts=R ORGgen_plt=yes ORGgen_tlm=6 -rate -,3 -num_threads 0 -quiet" \
    --command-name "kdu t$THREADS"   "\"$KDU_COMPRESS\" -i $INPUT -o bench-lossy-kakadu-tN.jp2 Creversible=no Clevels=5 Clayers=2 Cblk={64,64} Cprecincts=$KDU_PRECINCTS Corder=RPCL Cuse_sop=yes Cuse_eph=yes ORGtparts=R ORGgen_plt=yes ORGgen_tlm=6 -rate -,3 -num_threads $THREADS -quiet"
  [ -n "$BENCH_RESULTS_DIR" ] && set -- "$@" --export-json "$BENCH_RESULTS_DIR/encode-lossy.json"
  hyperfine "$@"

  echo
  echo "== LOSSY 9/7 DECODE own files =="
  set -- --warmup "$WARMUP" --runs "$RUNS" \
    --command-name "z2000 t1"        "$Z decode-temp-jp2 bench-lossy-z2000-tN.jp2 bench-lossy-z2000-decoded-t1.tif --threads 1" \
    --command-name "z2000 t$THREADS" "$Z decode-temp-jp2 bench-lossy-z2000-tN.jp2 bench-lossy-z2000-decoded-tN.tif --threads $THREADS"
  [ "$HAS_GRK" = 1 ] && set -- "$@" \
    --command-name "grok t1"         "grk_decompress -i bench-lossy-grok-tN.jp2 -o bench-lossy-grok-decoded-t1.tif -H 1 -G -2" \
    --command-name "grok t$THREADS"  "grk_decompress -i bench-lossy-grok-tN.jp2 -o bench-lossy-grok-decoded-tN.tif -H $THREADS -G -2"
  [ "$HAS_OPJ" = 1 ] && set -- "$@" \
    --command-name "openjpeg t1"        "opj_decompress -i bench-lossy-openjpeg-tN.jp2 -o bench-lossy-openjpeg-decoded-t1.tif -quiet -threads 1" \
    --command-name "openjpeg t$THREADS" "opj_decompress -i bench-lossy-openjpeg-tN.jp2 -o bench-lossy-openjpeg-decoded-tN.tif -quiet -threads $THREADS"
  [ "$HAS_KDU" = 1 ] && set -- "$@" \
    --command-name "kdu t1"          "\"$KDU_EXPAND\" -i bench-lossy-kakadu-tN.jp2 -o bench-lossy-kakadu-decoded-t1.tif -num_threads 0 -quiet" \
    --command-name "kdu t$THREADS"   "\"$KDU_EXPAND\" -i bench-lossy-kakadu-tN.jp2 -o bench-lossy-kakadu-decoded-tN.tif -num_threads $THREADS -quiet"
  [ -n "$BENCH_RESULTS_DIR" ] && set -- "$@" --export-json "$BENCH_RESULTS_DIR/decode-lossy.json"
  hyperfine "$@"

  echo
  echo "== LOSSY SIZES AND DETERMINISM =="
  size_files="bench-lossy-z2000-tN.jp2"
  [ "$HAS_GRK" = 1 ] && size_files="$size_files bench-lossy-grok-tN.jp2"
  [ "$HAS_OPJ" = 1 ] && size_files="$size_files bench-lossy-openjpeg-tN.jp2"
  [ "$HAS_KDU" = 1 ] && size_files="$size_files bench-lossy-kakadu-tN.jp2"
  # size_files is a generated whitespace-separated list of fixed filenames.
  # shellcheck disable=SC2012,SC2086
  ls -l $size_files | awk '{printf "%-14s %10d B\n", $NF, $5}'
  cmp bench-lossy-z2000-t1.jp2 bench-lossy-z2000-tN.jp2
  echo "z2000 lossy t1 == t$THREADS codestream: OK"
fi
