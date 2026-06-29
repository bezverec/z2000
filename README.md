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
- JP2 box-level scaffold writer/parser for RGB metadata
- reversible RGB color transform (RCT) for the future lossless 5/3 path
- subband/code-block partitioning plus raw bit-plane block payloads
- narrow RGB JP2 encode/decode roundtrip back to TIFF
- active code-block bounding boxes for faster sparse block payloads
- accurate SOT `Psot` tile-part lengths in the marker skeleton
- TLM marker segments for current tile-part lengths
- PLT packet-length marker segments in tile-part headers
- physical resolution-ordered tile-parts for `--tile-parts R`
- explicit RPCL packet sequence iterator for single-tile packet ordering
- T2 packet-header bitstream, tag-tree, coding-pass, and segment-length
  primitives with marker-safe bit stuffing
- fail-closed validation for standalone RPCL/T2 packet metadata helpers
- T2 code-block grid mapping from subband block rects to tag-tree leaves
- quality-layer-to-packet delta mapping for EBCOT code-block segment slices
- standalone T2 precinct layer packet assembly/reader for EBCOT payload slices
- legacy debug sidecar pass streams: significance, refinement, cleanup
- swappable pass-stream entropy layer with raw/RLE/bit-RLE auto-selection
- explicit experimental adaptive arithmetic backend for pass streams
- EBCOT/MQ code-block segments used as the current RPCL packet payload
- strict no-sidecar RPCL/RCT/5-3 decode for z2000-produced codestreams

It is not yet a full ISO/IEC 15444 compliant `.j2k` or `.jp2` encoder. The
current `jp2c` payload is a narrow single-tile RPCL/RCT/5-3 codestream with
strict packet headers, PLT-backed packet lengths, and MQ-backed code-block
payloads, but T1 context modeling and external decoder interop still need more
work before calling the output generally compliant.

## Build

```sh
zig build
zig build test
```

SIMD lane selection is centralized in `src/simd.zig`. Native AArch64 targets use
an explicit NEON-128 4xi32 policy for portable `@Vector` kernels, x86_64 AVX2
builds use 8xi32, and x86_64 AVX-512F builds use 16xi32 for wider block scans.
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
zig build run -- decode-temp-jp2 output.jp2 reconstructed.tif [--threads N]
```

Current TIFF support is deliberately narrow: TIFF 6.0 header + first IFD,
uncompressed RGB, chunky/interleaved samples, 8 or 16 bits per channel, strip
storage. Unsupported compression, planar layout, palette color, CMYK, tiled
TIFF, floating samples, and multipage handling fail closed.

`dng-info` uses the generic TIFF/IFD metadata layer to inspect DNG-style files
without decoding RAW CFA data. It reports DNG version tags, camera strings, CFA
metadata, the primary IFD, and SubIFD image summaries. This is the safe staging
ground for a later narrow `dng-to-jp2` RGB/preview path.

## Profile Mapping

The CLI now accepts the JPEG2000 profile knobs used by the Grok/Kakadu command
lines we are targeting:

- `--tile W,H` maps to Grok `-t` and Kakadu `Stiles`; tile sizes smaller than
  the image fail closed until multi-tile encoding exists.
- `--progression RPCL` maps to Grok `-p RPCL` and Kakadu `Corder=RPCL`; other
  progression orders fail closed until matching payload packetization exists.
- `--mct rct` maps to COD multiple component transform 1. The current supported
  path is RCT for reversible lossless RGB; `--mct ict` and `--mct none` fail
  closed until those tile pipelines exist.
- `--transform 5-3` maps to COD wavelet transform 1. `--transform 9-7` parses
  but fails closed until the TIFF/JP2 path has a real irreversible ICT/9-7
  pipeline.
- `--qstyle none` and `--guard-bits 2` map to QCD `Sqcd`. Scalar-derived and
  scalar-expounded quantization parse but fail closed until lossy quantization
  is implemented for JP2 output.
- `--resolutions 6` maps to Grok `-n 6`; it is equivalent to `--levels 5`
  and Kakadu `Clevels=5`.
- `--precincts "[256,256],[256,256],[128,128]"` maps to Grok `-c` and Kakadu
  `Cprecincts`.
- `--block 64` maps to Grok `-b 64,64` and Kakadu `Cblk={64,64}`.
- `--bypass`, `--reset-context`, `--terminate-all`, `--vertical-causal`,
  `--predictable-termination`, and `--segmentation-symbols` are parsed but fail
  closed with `UnsupportedPayload` until the matching JPEG2000 Part 1
  code-block style behavior is wired through the codestream path. Segmentation
  symbol payloads, terminate-all pass-terminated MQ slices, vertical-causal
  context formation, and reset-context continuous MQ behavior are implemented
  only in standalone EBCOT test paths for now, including inferred
  continuous-payload decode where possible and partial quality-layer prefix
  decode.
- `--sop` and `--eph` map to COD `Scod` flags and Kakadu `Cuse_sop=yes` /
  `Cuse_eph=yes` at marker/config level.
- `--tlm` writes TLM marker entries for the current tile-part lengths.
- `--layers N` maps to `Clayers=N`.
- `--tile-parts R` maps to Kakadu `ORGtparts=R` and Grok `-u R`; L/C/P
  tile-part divisions fail closed until their payload ordering exists. Use
  `--tile-parts none` to disable tile-part division.
- `--timings` prints a phase breakdown for TIFF read, RCT, DWT, block payload
  generation, JP2 wrapping, and disk write. This is the first pass at deciding
  whether the next optimization should target SIMD compute, scratch-buffer
  reuse/cache locality, or IO.
- `--threads N` enables deterministic parallelism for the current TIFF/JP2
  encoder. `N=1` keeps the original single-threaded path; `2..3` parallelizes
  independent Y/Cb/Cr DWT and component payload encoding; `N>3` keeps component
  order stable and parallelizes payload code-block ranges with per-worker
  scratch buffers. The decoder accepts the same flag for component
  payload decode and inverse DWT.

Archival-style scaffold:

```sh
zig build run -- tiff-to-jp2 example.tif example.jp2 \
  --tile 4096,4096 --progression RPCL --resolutions 6 \
  --precincts "[256,256],[256,256],[128,128],[128,128],[128,128],[128,128]" \
  --block 64 --layers 1 --tile-parts R --sop --eph
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

## Performance and Safety Direction

- Keep parsers bounds-checked and allocation-limited.
- Use checked integer math for dimensions, offsets, byte counts, and box sizes.
- Keep hot image data in contiguous component buffers before DWT.
- Keep tile-level parallelism fail-closed until real multi-tile payload layout
  exists; the current hot path uses component-level scheduling plus encode-side
  code-block range scheduling with per-worker scratch-buffer reuse.
- Benchmark encode/decode throughput, memory peak, and lossless roundtrip
  against OpenJPEG and Grok on the same TIFF corpus.

## Smoke Benchmark

With OpenJPEG `opj_compress`, Grok `grk_compress`, and `hyperfine` installed:

```sh
sh tools/bench_smoke.sh
sh tools/bench_profiles.sh
```

`tools/bench_profiles.sh` also includes the `bezverec/tif2jp2` wrapper when a
`tif2jp2` binary is in `PATH`. To use a local checkout or release binary
explicitly:

```sh
TIF2JP2=/path/to/tif2jp2 sh tools/bench_profiles.sh
```

For a single local phase breakdown, add `--timings` to `tiff-to-jp2`, for
example:

```sh
./zig-out/bin/z2000 tiff-to-jp2 bench-rgb-2048.tif bench-ours-profile.jp2 \
  --tile 4096,4096 --progression RPCL --resolutions 6 \
  --precincts "[256,256],[256,256],[128,128],[128,128],[128,128],[128,128]" \
  --block 64 --layers 1 --tile-parts R --sop --eph --tlm --timings
```

Current local baseline on a synthetic uncompressed RGB TIFF 2048x2048 after
adding RCT, integer 5/3 DWT, subband partitioning, pass-oriented code-block
payloads, temporary pass-stream entropy, and resolution-ordered tile-parts:

- `z2000 tiff-to-jp2`: 152.2 ms mean, marker skeleton + bitplane-ordered pass streams, 9.4 MB output
- `grk_compress`: 101.5 ms mean, real lossless JP2, 6.3 MB output
- `opj_compress`: 424.1 ms mean, real lossless JP2, 6.3 MB output
- `tif2jp2 --archival-master-ndk`: 275.2 ms mean, OpenJPEG FFI wrapper, 6.3 MB output
- `z2000 decode-temp-jp2`: 286.9 ms mean, current z2000 JP2 decoder
- `grk_decompress`: 76.6 ms mean
- `opj_decompress`: 440.9 ms mean
- `tif2jp2 --decode`: 224.6 ms mean

The encode comparison is still not fully fair yet: `z2000` performs TIFF
parsing, RCT, integer 5/3 DWT, code-block partitioning, JPEG2000 marker
emission, strict RPCL packet assembly, and MQ-backed code-block payload writing.
The remaining size and interop gap is mostly T1 model fidelity, not absence of a
packet stream.

The current decoder is lossless for z2000-produced narrow RPCL/RCT/5-3 files. A
256x256 RGB TIFF generated by `tools/make_bench_tiff.py` roundtrips bit-for-bit
through `tiff-to-jp2` and `decode-temp-jp2`.

The codestream marker skeleton now writes non-zero `SOT/Psot` values and TLM
entries for resolution-ordered tile-parts. OpenJPEG `opj_dump` indexes the
current single-tile archival profile as six tile-parts for six resolutions.

The block payload is now a continuous MQ-backed EBCOT-style segment. BP8 debug
metadata, when requested, records the same EBCOT/MQ segment bytes and T2 layer
deltas so the strict SOD packet stream can be checked against an oracle.

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

Latest local profile comparison on the same 2048x2048 RGB TIFF:

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

1. Tighten remaining T1/EBCOT cleanup edge cases and COD-driven termination
   behavior for the current continuous MQ payload.
2. Cross-check the narrow RPCL/RCT/5-3 path against independent decoders.
3. Close packet/header differences found by OpenJPEG, Grok, and Kakadu.
4. Add real multi-tile payload layout, then tile-parallel scheduling on top of
   the per-worker scratch-buffer model.
