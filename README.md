# z2000

Educational JPEG2000-style codec core written from scratch in Zig.

This first milestone is intentionally small and honest:

- binary grayscale `P5` PGM input/output
- reversible Le Gall 5/3 lifting transform for lossless-style paths
- irreversible CDF 9/7 lifting transform for lossy-style paths
- multi-level 2D wavelet decomposition
- scalar quantization
- a tiny custom `.z2000` codestream
- CLI encode/decode roundtrip tests
- safe narrow RGB TIFF 6.0 reader for uncompressed chunky RGB strips
- JP2 box-level scaffold writer/parser for RGB metadata, including standard
  length-to-EOF and 64-bit `XLBox` codestream box lengths
- reversible RGB color transform (RCT) for the future lossless 5/3 path
- subband/code-block partitioning plus raw bit-plane block payloads
- narrow RGB JP2 encode/decode roundtrip back to TIFF
- active code-block bounding boxes for faster sparse block payloads
- accurate SOT `Psot` tile-part lengths in the marker skeleton
- TLM marker segments for current tile-part lengths, with strict ordered
  multi-segment validation
- PLT packet-length marker segments in tile-part headers, with strict ordered
  multi-segment validation
- physical resolution-ordered tile-parts for `--tile-parts R`
- explicit RPCL packet sequence iterator for single-tile packet ordering
- T2 packet-header bitstream, tag-tree, coding-pass, and segment-length
  primitives with marker-safe bit stuffing, including the terminal `0xff`
  header-byte padding case needed for independent PLT parsers
- T2 tag-tree known-state tracking so repeated included leaves do not consume
  duplicate packet-header bits
- fail-closed validation for standalone RPCL/T2 packet metadata helpers
- T2 code-block grid mapping from subband block rects to tag-tree leaves
- quality-layer-to-packet delta mapping for EBCOT code-block segment slices
- standalone T2 precinct layer packet assembly/reader for EBCOT payload slices
- legacy debug sidecar pass streams: significance, refinement, cleanup
- swappable pass-stream entropy layer with raw/RLE/bit-RLE auto-selection
- explicit experimental adaptive arithmetic backend for pass streams
- EBCOT/MQ code-block segments used as the current RPCL packet payload
- ISO Annex C MQ coder with band-oriented T1 contexts as the default T1
  backend (`--t1-backend iso-mq`); the experimental range-coder backend
  remains available as `--t1-backend legacy-mq`
- verified OpenJPEG lossless interop: `tiff-to-jp2` output (8- and 16-bit RGB,
  multi-layer, archival precinct/tile-part profiles) decodes bit-for-bit in
  current OpenJPEG smoke tests after fixing four ISO conformance gaps:
  zero-bitplane signalling now uses Mb = guard + exponent - 1 (E-2), RCT
  applies the B.1.1 DC level shift on Y, the ZC context orientation swap moved
  from LH to HL (Table D.1), and the forward 5/3 DWT filters vertically before
  horizontally (F.4.8) so floor-rounding matches independent codecs
- irreversible lossy pipeline for `tiff-to-jp2 --transform 9-7 --mct ict
  --qstyle scalar-expounded`: float ICT (G.3), ISO-scaled 9/7 lifting
  (K = 1.230174105), deadzone scalar quantization with OpenJPEG-compatible
  explicit step sizes, QCD scalar-expounded signalling, and E.1 inverse
  quantization with Table E-1 gains; OpenJPEG decodes the output at the same
  PSNR as the z2000 decoder for 8- and 16-bit RGB
- arithmetic coder BYPASS (`--bypass`, COD style 0x01) end to end: raw
  significance/refinement passes below the fourth bitplane (D.6), terminated
  MQ/raw codeword segments, and multi-segment packet-header lengths
  (B.10.7.2); OpenJPEG decodes bypass output losslessly. Quality layers and
  `--rates` work with BYPASS by snapping layer truncation points to codeword
  segment boundaries, and rate-driven layers also apply to the irreversible
  9/7 path. Rate allocation is PCRD-style (ISO J.14): exact per-pass
  distortion from the reference coder, band-weighted, with a global slope
  threshold per layer byte target — layer sizes land on the requested ladder
  and PSNR at matched sizes tracks OpenJPEG's allocator within a few tenths
  of a dB.
- explicit COD code-block style metadata for all six Part 1 style bits;
  BYPASS is implemented end to end, the remaining style bits stay fail-closed
- strict no-sidecar RPCL/RCT/5-3 decode for z2000-produced codestreams
- decode of foreign (OpenJPEG/Grok) JP2 files that carry PLT packet lengths,
  including their default LRCP/no-precinct profiles, multi-layer ladders,
  and 9/7 lossy output; PLT-less foreign streams still fail closed
- strict marker checks for SOT/TLM/PLT/SOP/EPH packet metadata and tile-part
  `COM` comments

It is not yet a full ISO/IEC 15444 compliant `.j2k` or `.jp2` encoder, but
the narrow single-tile RPCL profiles (lossless RCT/5-3 and lossy ICT/9-7,
with or without BYPASS and quality layers) decode losslessly/pixel-identically
in the current z2000/OpenJPEG/Grok/Kakadu smoke gates.

The current ISO readiness estimate is tracked in `docs/iso_coverage.md`. As of
2026-07-06, the narrow RGB lossless JP2 target is estimated at 86/100, while
the broader JPEG2000 Part 1 codec family is estimated at 44/100.

## Build

```sh
zig build
zig build test
```

SIMD lane selection is centralized in `src/simd.zig`. Native AArch64 targets use
an explicit NEON-128 policy for portable `@Vector` kernels, x86_64 AVX2 builds
use 8-wide vectors, and x86_64 AVX-512F builds use 16xi32 for wider block scans.
Integer RCT/5-3 kernels and the irreversible ICT float path share this policy:
ICT uses f32 vectors, giving a modern NEON/AVX-family equivalent of the old
packed-float 3DNow-style idea without relying on obsolete x86-only opcodes.
Cross-compile checks used during development:

```sh
zig build -Dtarget=x86_64-macos -Dcpu=haswell -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-macos -Dcpu=skylake_avx512 -Doptimize=ReleaseFast
```

## Encode

```sh
zig build run -- encode input.pgm output.z2000 --wavelet 5-3 --levels 3 --quant 1
```

For a lossy-style transform:

```sh
zig build run -- encode input.pgm output.z2000 --wavelet 9-7 --levels 4 --quant 8
```

## Decode

```sh
zig build run -- decode output.z2000 reconstructed.pgm
```

## TIFF / JP2 Scaffold

```sh
zig build run -- tiff-info input.tif
zig build run -- dng-info input.dng
zig build run -- tiff-to-jp2 input.tif output.jp2 \
  [--levels 5|--resolutions 6] [--tile 4096,4096] [--progression RPCL] \
  [--precincts "[256,256],[256,256],[128,128]"] [--block 64] [--layers 1] \
  [--mct rct|ict|none] [--transform 5-3|9-7] [--qstyle none|scalar-derived|scalar-expounded] \
  [--guard-bits 2] [--tlm|--no-tlm] [--threads N] [--timings]
zig build run -- jp2-info output.jp2
zig build run -- jp2-stats output.jp2
zig build run -- decode-temp-jp2 output.jp2 reconstructed.tif [--threads N] [--timings]
```

Current TIFF support is deliberately narrow: TIFF 6.0 header + first IFD,
uncompressed RGB, chunky/interleaved samples, 8 or 16 bits per channel, strip
storage. Unsupported compression, planar layout, palette color, CMYK, tiled
TIFF, floating samples, and multipage handling fail closed.

ICC profile handling is staged. The current TIFF -> JP2 path preserves an
embedded TIFF ICC profile from tag 34675 byte-for-byte into a JP2 restricted
ICC `colr` box without changing pixel values, and `decode-temp-jp2` writes that
profile back to TIFF. This targets common RGB profiles such as eciRGBv2 and
Adobe RGB as opaque ICC payloads first. Actual color conversion between
profiles is a later optional LittleCMS-backed step, not part of the current
narrow path.

`dng-info` uses the generic TIFF/IFD metadata layer to inspect DNG-style files
without decoding RAW CFA data. It reports DNG version tags, camera strings, CFA
metadata, the primary IFD, and SubIFD image summaries. This is the safe staging
ground for a later narrow `dng-to-jp2` RGB/preview path.

## Profile Mapping

The CLI now accepts the JPEG2000 profile knobs used by the Grok/Kakadu command
lines we are targeting:

- `--tile W,H` maps to Grok `-t` and Kakadu `Stiles`. Multi-tile encode and
  decode work end-to-end in a v1 envelope (lossless RCT/5-3, one quality
  layer, one tile-part per tile in row-major order, plain code-block style);
  the geometry must satisfy ISO B.6/B.7 partition anchoring (tile sizes a
  multiple of `2^levels x` the largest precinct, precincts >= code-blocks
  with the r>0 half-span rule) and every tile must achieve the global
  decomposition level count. Configurations outside the envelope fail
  closed. See `docs/multi_tile_plan.md`.
- `--progression RPCL` maps to Grok `-p RPCL` and Kakadu `Corder=RPCL`. All
  five Part 1 progression orders are supported on the single-tile path: the
  non-RPCL orders (LRCP, RLCP, PCRL, CPRL) emit the same per-precinct packet
  bodies permuted into the ISO B.12 stream order. Multi-layer LRCP and the
  position-major PCRL/CPRL use one tile-part (their streams cannot be
  divided per resolution); RLCP and single-layer LRCP keep per-resolution
  tile-parts.
- `--mct rct` maps to COD multiple component transform 1 with the reversible
  5/3 path; `--mct ict` selects the irreversible ICT and requires
  `--transform 9-7 --qstyle scalar-expounded`. `--mct none` codes the three
  components independently on the reversible path (single-tile only).
- `--transform 5-3` maps to COD wavelet transform 1 (lossless RCT path).
  `--transform 9-7` maps to COD wavelet transform 0 and enables the
  irreversible ICT/9-7/scalar-quantization pipeline.
- `--qstyle none` and `--guard-bits 2` map to QCD `Sqcd` on the lossless path.
  `--qstyle scalar-expounded` is the lossy default quantization with
  OpenJPEG-compatible explicit step sizes. `--qstyle scalar-derived` signals a
  single step size for the deepest LL band and derives every other subband via
  ISO E-5 (the nominal bit-plane budget derives from the same signalled
  exponents, so external decoders reconstruct identically).
- `--resolutions 6` maps to Grok `-n 6`; it is equivalent to `--levels 5`
  and Kakadu `Clevels=5`.
- `--precincts "[256,256],[256,256],[128,128]"` maps to Grok `-c` and Kakadu
  `Cprecincts`.
- `--block 64` maps to Grok `-b 64,64` and Kakadu `Cblk={64,64}`.
- `--bypass` (Grok `-M 1`, Kakadu `Cmodes=BYPASS`) is implemented end to end
  for single-layer codestreams with the ISO MQ backend, including raw
  segment termination and multi-segment packet-header lengths.
  `--terminate-all`, `--vertical-causal`, and `--segmentation-symbols` are
  public opt-in strict profiles with end-to-end payload behavior. Predictable
  termination is wired only with `--terminate-all --predictable-termination`:
  it emits COD style `0x10` and ER-TERM-flushed per-pass MQ segments, and the
  current single-tile smoke is accepted by Kakadu `kdu_expand`; larger z2000
  strict decode coverage is still being hardened. `--reset-context` remains
  fail-closed in the public profile.
- `--sop` and `--eph` map to COD `Scod` flags and Kakadu `Cuse_sop=yes` /
  `Cuse_eph=yes` at marker/config level. SOP is enabled by default; EPH is
  disabled by default for the current independent-decoder interop path. Use
  `--eph` only for packet-boundary diagnostics until packet header/state
  semantics are accepted by Grok and Kakadu.
- `--tlm` writes TLM marker entries for the current tile-part lengths.
- `--layers N` maps to `Clayers=N`.
- `--tile-parts R` maps to Kakadu `ORGtparts=R` and Grok `-u R`; L/C/P
  tile-part divisions fail closed until their payload ordering exists. Use
  `--tile-parts none` to disable tile-part division.
- `--timings` prints a phase breakdown for TIFF/JP2 IO, codestream work, DWT,
  color transform, block payload work, wrapping, and disk write. On
  `decode-temp-jp2` the strict ISO path also splits metadata parsing, T2 packet
  catalog construction, T1 block payload reconstruction, inverse DWT, and
  inverse MCT. The packet catalog line includes scan/header/finalize subphases,
  and strict block payload timing includes worker balance counters for max/avg
  job wall time, decoded blocks, and payload bytes. It also reports a T1 pass
  profile for the ISO MQ/BYPASS decoder: MQ significance, refinement,
  cleanup/RLC, and raw BYPASS pass CPU-sum, pass count, and symbol count across
  workers. The MQ profile also separates fast MPS reads, LPS reads, MPS reads
  needing renormalization, renormalization shifts, and byte-in calls. This is
  intentionally collected only when `--timings` is enabled, so normal decode
  benchmarks avoid the MQ branch-counter overhead. This is the first pass at
  deciding whether the next optimization should target MQ decode, SIMD compute,
  scratch-buffer reuse/cache locality, or IO.
- `--threads N` enables deterministic parallelism for the current TIFF/JP2
  encoder. `N=1` keeps the original single-threaded path; `2..3` parallelizes
  independent Y/Cb/Cr DWT and component payload encoding; `N>3` uses one
  deterministic cost-ordered queue across Y/Cb/Cr code-block catalog work with
  per-worker scratch buffers, then emits packets in stable RPCL order. The
  decoder accepts the same flag for component payload decode and inverse DWT.

Archival-style scaffold:

```sh
zig build run -- tiff-to-jp2 example.tif example.jp2 \
  --tile 4096,4096 --progression RPCL --resolutions 6 \
  --precincts "[256,256],[256,256],[128,128],[128,128],[128,128],[128,128]" \
  --block 64 --layers 1 --tile-parts R --sop --no-eph
```

Production-master-style scaffold:

```sh
zig build run -- tiff-to-jp2 example.tif example.jp2 \
  --tile 1024,1024 --progression RPCL --resolutions 6 \
  --precincts "[256,256],[256,256],[128,128]" \
  --block 64 --layers 12 --tile-parts R --no-sop --no-eph
```

These options are currently reflected in the codestream markers (`SIZ`/`COD`/
`QCD`/`TLM`/`PLT`) and in the real RPCL packet payload. `--tile-parts R` writes
physical resolution-ordered tile-parts. Quality layers are encoded as T2 layer
deltas over one continuous MQ code-block segment, with byte ranges snapped to
actual coding-pass truncation points. The optional BP8 debug sidecar mirrors the
same metadata for oracle checks; it is no longer emitted by default or required
for normal z2000 decode. Code-block style options remain fail-closed until their
payload behavior is implemented.

## Performance Notes (current pass)

- The default ISO MQ encode path is now direct: code-blocks stream straight
  into the ISO MQ coder (and raw BYPASS segments) from per-worker scratch,
  with no per-block Symbol materialization or allocator churn. A test pins
  the direct output byte-for-byte to the symbol-based reference coders.
- ISO MQ codeword segments can now finish directly into the reusable
  per-worker payload buffer, avoiding a temporary owned slice and second copy
  in the default direct T1 path. Raw BYPASS segments use the same direct
  payload sink, and MQ BYTEOUT keeps that sink local through the carry/marker
  path. The MQ encoder/decoder also has an explicit fast branch for the common
  MPS-without-renormalization case, cached context transition rows, and a
  batched CLZ-based decoder renormalization loop.
- Significance and refinement passes skip whole 4-row stripes whose
  neighborhood window carries no significance (encode and decode); this is
  content-dependent and helps most on smooth imagery.
- TIFF output now reserves exact file capacity and fills the raster slice
  directly, using SIMD validation/narrowing for 8-bit samples and native
  little-endian byte copies for 16-bit samples while removing per-sample
  fallible appends from the decode write path.
- TIFF input widens 8-bit samples into the internal `u16` RGB buffer with the
  shared portable SIMD lane policy, leaving scalar tails for non-multiple strip
  lengths. Little-endian 16-bit TIFF strip reads use a native byte-copy fast
  path with scalar fallback for big-endian data.
- The same T1 passes now also skip 64-column row-mask chunks inside active
  stripes when their local significance window is empty. This keeps the code
  on the existing row-word model while moving toward the packed-column flag
  layout used by mature JPEG2000 codecs.
- The earlier RLC-only packed-column cleanup-run cache was removed after it
  regressed the 2048 RGB lossless profile. The remaining packed scaffold uses
  the full OpenJPEG-style T1 context-word layout, while the active ReleaseFast
  path stays on `u16` neighborhood words until the shared ZC/SC/RLC path is
  ready to benchmark.
- The packed-column scaffold mirrors OpenJPEG's `3 * ci`
  sigma/sign-window layout and has unit tests proving zero-coding and
  sign-coding context parity with the current u16 neighborhood flags.
- PI/MU bits are covered as well, so the scaffold now proves significance-pass
  membership, refinement-pass membership, and refinement context parity before
  the packed layout is enabled on the hot path.
- Incremental packed-word updates are covered against full rebuilds across
  block edges and 4-row stripe boundaries, including sigma, CHI, PI, and MU
  bits. This keeps the next ZC/SC hot-path migration testable before flipping
  any runtime guard.
- Packed ZC, SC, significance, and refinement helper contexts are tested
  against the existing `u16` flag path for all subbands and vertical-causal
  rows, giving the eventual hot-path switch a narrow equivalence surface.
- The full packed T1 context-word buffer has its own disabled guard, so ZC/SC
  migration can proceed without reviving the measured-slower RLC-only cache.
- Packed T1 decision helpers now centralize ZC/SC/significance/refinement
  parity checks and include dense edge/stripe-boundary stress coverage.
- The disabled packed T1 context path is wired into the same visit, refine,
  significance, and per-bitplane visit-clear lifecycle as `nb_flags`, with
  unit coverage for PI-bit clearing against a full rebuild.
- NBF/ISO significance, refinement, and cleanup loops now select
  ZC/SC/refinement decisions through the shared T1 decision helpers. With the
  packed guard disabled this still uses the `u16` path; with it enabled, debug
  builds assert packed-vs-`u16` parity at the loop boundary.
- Debug and ReleaseSafe builds now maintain the packed T1 context buffer as a
  shadow state and assert decision parity in the normal T1 loops, while
  ReleaseFast keeps the shadow path compiled out unless explicitly enabled.
- The experimental packed T1 hot path can be built with
  `zig build -Dpacked-t1-context-flags=true`; it is intended for correctness
  checks and comparative benchmarks before becoming the default.
- Cleanup-run eligibility has a parity-checked helper over the full
  OpenJPEG-style packed T1 words, including PI blocking and vertical-causal
  stripe-boundary behavior.
- Encode/decode cleanup loops now route their future packed cleanup-run choice
  through scratch-aware helpers: default builds still use `u16` flags, while a
  future packed T1 guard flip will share the same context-word buffer used for
  ZC/SC/refinement decisions.
- Decode cleanup-run sign coding now also goes through the shared T1 decision
  helper after the runlength, removing the last local sign-context calculation
  from that path and extending packed shadow parity to the RLC decode corner.
- Debug and ReleaseSafe cleanup-run eligibility now assert the full packed T1
  context-word result against the active `u16` decision in the real encode and
  decode RLC loops. ReleaseFast still compiles this shadow assertion out unless
  the packed T1 guard is explicitly enabled.
- Cleanup sample helpers now rely on the shared T1 decision helpers for
  vertical-causal handling instead of carrying a separate `causal_row` argument.
- The obsolete RLC-only cache and scratch storage have been removed, leaving a
  single packed T1 migration target and fewer inactive branches in the encode
  and decode cleanup paths.
- Continuous ISO/NBF decode no longer mirrors significant samples into the
  legacy per-sample `u8` flag array; it updates only coefficients,
  row-significance words, and packed neighborhood flags.
- Raw BYPASS significance/refinement decode now uses the same direct
  stripe/x/dy scan loops as the inferred ISO/NBF passes instead of the generic
  scan iterator, with packed-flag and coefficient indices advanced
  incrementally through each stripe column.
- Packed-neighborhood visit-bit clearing now uses the same portable SIMD lane
  policy as the existing flag clears, mapping to NEON-width vectors on Apple
  Silicon and wider AVX-family vectors on matching x86 targets.
- Integer inverse 5/3 unpack now separates low/high samples with branchless
  even/odd loops for both horizontal rows and strided vertical columns.
- Strict no-sidecar decode can now use block-level workers inside each
  component when `--threads` exceeds the old three-component cap; block
  coverage is validated before worker scatter so parallel writes stay
  disjoint. The parallel coverage audit uses row bitsets instead of one bool
  per pixel, trimming the validation working set before workers scatter into
  disjoint rectangles.
- The component-parallel strict decode path now writes directly into the final
  Y/Cb/Cr planes, avoiding the previous worker-owned plane allocation and
  full-plane copy back to the caller allocator.
- Strict single-layer packet catalog assembly now transfers component-owned
  payload buffers into the final block catalog, avoiding an extra per-block
  payload copy in the no-sidecar decode path.
- Strict single-layer packet-header assembly reuses a per-packet arena for
  short-lived T2 audit groups; multi-layer decoding keeps the original
  long-lived group state across layers.
- Strict decode scatters reconstructed code-block rows with slice copies and
  row coverage updates instead of per-sample destination index arithmetic.
- Strict no-sidecar decode now runs component-parallel with `--threads`,
  reuses one T1 scratch and one ISO MQ decoder per component, and skips
  context-index bounds checks in the hot MQ loops (debug asserts remain).
- Strict decode only zero-initializes coefficient planes when the packet block
  catalog contains zero blocks; dense no-sidecar outputs let decoded block
  scatter fill the full plane directly.
- ReleaseFast strict T1 significance, refinement, and cleanup decode use shorter
  neighborhood-flag paths for the common non-vertical-causal style;
  Debug/ReleaseSafe continue to maintain packed-context shadow checks.
- ReleaseFast direct T1 significance, refinement, and cleanup encode use the
  same shorter neighborhood-flag path for the common non-vertical-causal style.
- T1 neighborhood state is now incremental (openjpeg-style flag words): one
  u16 per sample in a bordered grid carries the eight neighbor significance
  bits, four neighbor signs, and self/visit/refine state, updated when a
  sample becomes significant. Zero-coding contexts come from comptime LUTs
  (4 x 256) generated from the reference context functions, sign coding from
  a 256-entry LUT, so contexts stay provably identical to the symbol-based
  coders (byte-equality test). Vertical causal mode is a mask on the stripe's
  last row.
- macOS/Apple M4 baseline on the synthetic 2048x2048 RGB TIFF, archival
  lossless profile with BYPASS, RPCL, six resolutions, SOP/EPH/TLM, and ten
  threads: z2000 encode 180 ms vs Grok 107 ms and OpenJPEG 103 ms; output size
  is effectively identical (6,636,048 B vs 6,635,206 B / 6,635,203 B), and
  `tiffcmp` confirms lossless self/cross decode. z2000 decode remains the
  larger gap: 262 ms at ten threads vs Grok 77 ms and OpenJPEG 116 ms.
- On a 1024x1024 single-tile access-style ICT/9-7 run with the NDK 12-layer
  rate ladder, z2000 encode is close in wall time (65 ms vs Grok 57 ms and
  OpenJPEG 46 ms) but produces a much larger, higher-quality file
  (1,288,181 B and about 52.6 dB PSNR vs about 393 kB for Grok/OpenJPEG).
  This is a rate-allocation issue, not a transform/interoperability gate.

## Performance and Safety Direction

- Keep parsers bounds-checked and allocation-limited.
- Use checked integer math for dimensions, offsets, byte counts, and box sizes.
- Keep hot image data in contiguous component buffers before DWT.
- Keep tile-level parallelism fail-closed until real multi-tile payload layout
  exists. A shared tile-grid geometry helper now computes edge-tile rectangles
  and feeds encoder/strict SIZ validation, but the current hot path still uses
  component-level scheduling plus encode-side code-block range scheduling with
  per-worker scratch-buffer reuse.
- Benchmark encode/decode throughput, memory peak, and lossless roundtrip
  against OpenJPEG and Grok on the same TIFF corpus.

## Smoke Benchmark

With OpenJPEG `opj_compress`, Grok `grk_compress`, and `hyperfine` installed:

```sh
sh tools/bench_smoke.sh
sh tools/bench_profiles.sh
```

`tools/bench_compare.sh` and `tools/bench_profiles.sh` default z2000's
threaded runs to all detected logical CPUs. Override with `Z2000_THREADS=N` for
a fixed worker count, or use `Z2000_THREADS=all` / `auto` explicitly when
recording benchmark commands. On Windows, `tools/bench_compare.ps1` provides
the same comparative encode/decode benchmark without shell quoting issues:

```powershell
.\tools\bench_compare.ps1 -Input C:\temp\tools\images\0004.tif -Threads all
```

`tools/bench_profiles.sh` also includes the `bezverec/tif2jp2` wrapper when a
`tif2jp2` binary is in `PATH`. To use a local checkout or release binary
explicitly:

```sh
TIF2JP2=/path/to/tif2jp2 sh tools/bench_profiles.sh
```

For a single local phase breakdown, add `--timings` to `tiff-to-jp2` or
`decode-temp-jp2`, for example:

```sh
./zig-out/bin/z2000 tiff-to-jp2 bench-rgb-2048.tif bench-ours-profile.jp2 \
  --tile 4096,4096 --progression RPCL --resolutions 6 \
  --precincts "[256,256],[256,256],[128,128],[128,128],[128,128],[128,128]" \
  --block 64 --layers 1 --tile-parts R --sop --no-eph --tlm --timings

./zig-out/bin/z2000 decode-temp-jp2 bench-ours-profile.jp2 bench-ours-profile.tif \
  --threads 10 --timings
```

Current local baseline on macOS/Apple M4 for a synthetic uncompressed RGB TIFF
2048x2048, archival lossless RPCL profile, BYPASS, SOP/EPH/TLM, and ten
threads (`RUNS=3 THREADS=10 sh tools/bench_compare.sh
.bench/macos-analysis/rgb-2048.tif`, 2026-07-03):

- `z2000 tiff-to-jp2 --threads 10`: 169.3 ms mean, 6,636,048 B output.
- `z2000 tiff-to-jp2` single-thread: 602.6 ms mean.
- `grk_compress`: 109.9 ms mean, 6,635,206 B output.
- `opj_compress`: 419.8 ms mean, 6,635,203 B output.
- `z2000 decode-temp-jp2 --threads 10`: 185.5 ms mean.
- `z2000 decode-temp-jp2` single-thread: 620.1 ms mean.
- `grk_decompress`: 78.0 ms mean on its own file, 77.8 ms on z2000 output.
- `opj_decompress`: 442.6 ms mean on its own file, 444.6 ms on z2000 output.

`tiffcmp` confirms the z2000 single-thread/ten-thread decode and
Grok/OpenJPEG decodes of z2000 output are pixel-lossless; external decoders may
add TIFF orientation metadata or different strip layouts. The optional Python
pixel checker was skipped in this run because Pillow was not installed.

The same benchmark script accepts `ZIG_BUILD_FLAGS`; for example
`ZIG_BUILD_FLAGS="-Dpacked-t1-context-flags=true"` builds the experimental
packed T1 hot path before timing. On the same input that path is currently a
regression despite producing lossless output: z2000 encode t10 241.9 ms,
decode t10 226.3 ms, encode t1 918.1 ms, and decode t1 837.2 ms.

The encode comparison is now much fairer for the narrow archival profile:
z2000 writes real strict RPCL packets and EBCOT/MQ payloads with byte size close
to Grok/OpenJPEG. Decode hot paths remain the largest performance gap.

Latest local T1 range-skip check on the stricter SOP/EPH/TLM + tile-parts-R
2048x2048 profile improved the prior cleanup-run-unroll benchmark from
202.8 ms to 199.7 ms for encode and from 200.1 ms to 193.6 ms for z2000
decode, with z2000 decode byte-identical to the source TIFF and Grok/OpenJPEG
both accepting the produced JP2.
After switching the parallel strict coverage audit to row bitsets, the same
decode profile reran at 192.8 ms mean while staying byte-identical.
After switching block-level strict decode from static ranges to an atomic
next-block scheduler, a decode-only check on the same z2000 JP2 ran at
182.9 ms +/- 5.2 ms over eight runs with `tiffcmp` still clean.

The current decoder is lossless for z2000-produced narrow RPCL/RCT/5-3 files. A
256x256 RGB TIFF generated by `tools/make_bench_tiff.py` roundtrips bit-for-bit
through `tiff-to-jp2` and `decode-temp-jp2`.

The codestream marker skeleton now writes non-zero `SOT/Psot` values and TLM
entries for resolution-ordered tile-parts. OpenJPEG `opj_dump` indexes the
current single-tile archival profile as six tile-parts for six resolutions.
On the current no-sidecar smoke path, z2000 strict decode, OpenJPEG, Grok, and
Kakadu accept the output losslessly. Grok no longer reports PL marker length
warnings after the RPCL subband precinct projection and terminal packet-header
stuffing fixes. jpylyzer 2.2.1 reports the current JP2 as valid with no
warnings. External validators such as valid2000 or jpylyzer are hygiene gates,
not absolute sources of truth: any warning should be reduced against the strict
reader, independent decoders, and the Part 1 text. ICC absence is acceptable
when the source TIFF has no ICC tag.

Strict marker handling now checks SOT tile-part sequence/count, TLM tile indexes
and tile-part lengths, PLT packet spans, ordered multi-segment TLM/PLT marker
indexes, empty TLM/PLT segments, SOP/EPH marker policy from COD, duplicate
SOP/EPH markers inside one packet frame, and packet-header marker stuffing.
Tile-part `COM` markers are accepted as metadata before `SOD`.

The block payload is now a continuous MQ-backed EBCOT-style segment. BP8 debug
metadata, when requested, records the same EBCOT/MQ segment bytes and T2 layer
deltas so the strict SOD packet stream can be checked against an oracle.
`jp2-stats --t1-backend iso-mq` now validates ISO-MQ debug sidecars through the
same strict SOD packet block catalog used by normal no-sidecar decode.
T2 tag-trees now retain known included-node state across packets, which keeps
continued-layer packet headers from re-emitting already proven inclusion bits.

`jp2-stats` inspects codestream markers, strict packet headers, and debug
sidecar metadata when present. On the historical 2048x2048 smoke file it
reported 3072 code-blocks, all active, 12,183,966 non-zero coefficients,
2,951,286 encoded significance bytes, 6,686,962 encoded refinement bytes, and
zero cleanup payload bytes.

The TIFF/JP2 encoder accepts square code-block experiments through
`tiff-to-jp2 --block N`. On the same smoke file, 64x64 remains the best
compression point at 9.4 MB. 32x32 encoded faster in one local run
(`271.7 ms`) but grew to 10 MB; 16x16 grew to 13 MB and slowed encode to
`334.5 ms`.

Pass streams now go through a small entropy abstraction. The current backend
auto-selects raw bytes, byte-RLE, or bit-RLE. An adaptive binary arithmetic
backend exists and roundtrips in tests, but it is intentionally explicit rather
than part of auto-selection because the current generic implementation improves
some stream sizes at too much encode/decode cost. The next compression step
should be a JPEG2000-style context/MQ backend, not further tuning of the
generic pass-stream coder.

Historical local profile comparison on the same 2048x2048 RGB TIFF before the
current ISO-MQ/BYPASS work:

- Archival profile encode: `z2000` 254.1 ms, Grok 115.6 ms, OpenJPEG 424.2 ms.
- Archival profile decode: `z2000` 294.0 ms, Grok 84.0 ms, OpenJPEG 449.9 ms.
- Archival output size: `z2000` 9.4 MB, Grok 6.3 MB, OpenJPEG 6.3 MB.
- Access profile 1:8 encode: Grok 192.9 ms, OpenJPEG 484.5 ms, both about
  1.5 MB. The local Grok decoder crashed on this access file, while OpenJPEG
  decoded it, so no Grok access decode number is recorded yet.

The first `--timings` run on that archival encode showed the useful direction:
roughly 95% of wall time is inside codestream generation, with block payload
generation and DWT dominating. TIFF read, JP2 wrapping, and disk write were
small single-digit percentages on the synthetic smoke file.

The first memory-side pass keeps per-component bitplane scratch buffers and
borrows raw entropy streams instead of copying them before immediately writing
them into the codestream. This mostly reduces allocator churn in the hottest
block payload path; larger wins still require a better pass coder and
parallelism.

The first retained SIMD passes are the bitplane block scanner and AArch64 RCT.
The block scanner scans contiguous coefficient rows in integer vectors to
combine non-zero detection and max-magnitude discovery in one pass before
writing significance and refinement streams. On NEON targets, the reversible RGB
color transform handles four pixels at a time while keeping a scalar tail for
non-multiple-of-four image widths.

The integer 5/3 DWT now transforms horizontal rows in place and keeps the line
buffer only for strided vertical columns. This removes a full row copy in each
horizontal pass on encode and decode. Codestream encode/decode also reuse one
DWT workspace across Y/Cb/Cr instead of allocating line buffers per component.

Optimization read from those numbers:

- Grok wins wall-clock mainly through parallelism: its user CPU is much higher
  than wall time. The next speed steps for `z2000` are real tile scheduling and
  broader code-block parallelism with scratch-buffer reuse.
- The largest size gap is entropy coding. `z2000` still stores 6.7 MB of encoded
  refinement stream bytes in the archival profile, so real EBCOT context passes
  plus MQ coding are the next compression step.
- 32x32 code-blocks decode a little faster locally, but grow the file by about
  1 MB. Keep 64x64 as the archival default.

## Roadmap

Features:

1. Real multi-tile payload layout, then tile-parallel scheduling on top of
   the per-worker scratch-buffer model.
2. Expand the full profile matrix across OpenJPEG/Grok/Kakadu and
   valid2000/jpylyzer-style validators, treating validator warnings as
   diagnostic leads rather than authoritative failures until checked against
   the strict reader, independent decoders, and Part 1.
3. Distortion-aware rate allocation (PCRD-style) so early quality layers
   carry more PSNR than the current byte-even/ratio split.

Performance (decode remains the larger Grok gap; ordered by current expected
win per effort after the strict T2 profiling pass):

1. T1/MQ absolute CPU work: strict decode timing still puts most wall time in
   block payload reconstruction. The useful wins so far are inline unchecked
   ISO MQ reads, cached context transition rows, CLZ-batched renormalization,
   worker-local `DecodeBlockScratch`, direct scatter, and removal of an
   unreachable MQ MPS slow-path branch. Next, profile instructions rather than
   only phase time, then target flag book-keeping, context lookup/update
   helpers, byte-in locality, and any remaining per-symbol branches that survive
   in the MQ significance/refinement/cleanup profiles.
2. T1 scan/flag layout, but only with byte-equality gates: the guarded
   OpenJPEG-style packed T1 context-word build is correct but slower on the
   local profile, so do not flip it wholesale. Future attempts should be
   narrower: RLC-only reads from full packed words, lazy stripe/word rebuilds,
   partial ZC/SC lookup from packed sigma/sign windows, or word-granular smooth
   stripe skipping. Keep the u16 path until a packed subpath is faster and
   byte-identical.
3. Horizontal 5/3 DWT SIMD and better DWT scheduling: vertical integer 5/3 is
   vectorized, but horizontal lifting is still scalar apart from small no-op
   pack/unpack skips. A portable NEON/AVX `@Vector` row kernel, row-pair
   processing, and cache blocking should help both encode and decode. Longer
   term, split inverse DWT work inside a component instead of only across the
   three components.
4. Packet catalog remains a serial Amdahl term, but it is no longer the first
   lever. The strict catalog timing now exposes scan/header/finalize, reuses
   validated PLT byte totals, avoids temporary payload slice staging, keeps
   strict band groups on stack storage, and usually sits around 9-10 ms on the
   2048 lossless decode smoke file. Next T2 work should focus on correctness
   and future multi-progression caching unless a new benchmark shows catalog
   growth with larger images or more tile-parts.
5. Parallel efficiency: block-level decode uses an atomic next-block scheduler
   and worker balance counters. A tested LPT-by-payload ordering experiment was
   slower, and current max/average worker wall times do not show a dominant
   serial tail. Further gains likely require persistent worker resources,
   larger work units with less scheduling overhead, DWT row-band parallelism,
   or true tile-level scheduling rather than more block reordering.
6. Multi-tile architecture: this is the structural route past Grok on many
   cores. Single-tile z2000 can parallelize T1 blocks and some component work,
   but catalog, DWT/MCT tails, and whole-image memory flow remain serial enough
   to cap scaling. Real tile grids, per-tile DWT/T1/T2 state, and tile-part
   work queues are the path to linear many-core behavior.
7. TIFF I/O strip handling: decode write uses exact-capacity direct raster
   slice fills with SIMD 8-bit narrowing and native 16-bit byte copies, while
   encode read uses SIMD 8-bit widening and native little-endian 16-bit byte
   copies. The remaining low-risk I/O work is broader strip/write policy and
   deciding whether streaming TIFF output is cleaner than one contiguous buffer.
8. PCRD-style rate allocation: not primarily a speed item, but necessary for
   fair access-copy comparisons and smaller quality-layer outputs.
9. Lossy path SIMD and quantization: dequantization and float 9/7 lifting remain
   scalar per band. NEON f32x4 and AVX f32 lanes should mirror the integer
   kernels once the lossless decode bottleneck is less dominant.
10. Allocator/RSS hygiene: per-worker arenas and high-water scratch retention
   should be considered for large tiles, but recent strict decode changes have
   already removed several short-lived packet-catalog allocations.
