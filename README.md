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
- temporary RGB JP2 encode/decode roundtrip back to TIFF
- active code-block bounding boxes for faster sparse block payloads
- accurate SOT `Psot` tile-part lengths in the marker skeleton
- TLM marker segment for the current single tile-part length
- pass-oriented temporary code-block payloads: significance, refinement, cleanup
- swappable pass-stream entropy layer with raw/RLE/bit-RLE auto-selection
- explicit experimental adaptive arithmetic backend for pass streams

It is not yet an ISO/IEC 15444 compliant `.j2k` or `.jp2` encoder. The JP2
container boxes are now scaffolded, but the `jp2c` payload is still temporary.
The missing large pieces are precincts, packet progression orders, EBCOT coding
passes, MQ arithmetic coding, and strict ISO-compatible packet syntax.

## Build

```sh
zig build
zig build test
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
zig build run -- tiff-to-jp2 input.tif output.jp2 \
  [--levels 5|--resolutions 6] [--tile 4096,4096] [--progression RPCL] \
  [--precincts "[256,256],[256,256],[128,128]"] [--block 64] [--layers 1] \
  [--tlm|--no-tlm] [--timings]
zig build run -- jp2-info output.jp2
zig build run -- jp2-stats output.jp2
zig build run -- decode-temp-jp2 output.jp2 reconstructed.tif
```

Current TIFF support is deliberately narrow: TIFF 6.0 header + first IFD,
uncompressed RGB, chunky/interleaved samples, 8 or 16 bits per channel, strip
storage. Unsupported compression, planar layout, palette color, CMYK, tiled
TIFF, floating samples, and multipage handling fail closed.

## Profile Mapping

The CLI now accepts the JPEG2000 profile knobs used by the Grok/Kakadu command
lines we are targeting:

- `--tile W,H` maps to Grok `-t` and Kakadu `Stiles`.
- `--progression RPCL` maps to Grok `-p RPCL` and Kakadu `Corder=RPCL`.
- `--resolutions 6` maps to Grok `-n 6`; it is equivalent to `--levels 5`
  and Kakadu `Clevels=5`.
- `--precincts "[256,256],[256,256],[128,128]"` maps to Grok `-c` and Kakadu
  `Cprecincts`.
- `--block 64` maps to Grok `-b 64,64` and Kakadu `Cblk={64,64}`.
- `--bypass`, `--sop`, and `--eph` map to `Cmodes={BYPASS}`, `Cuse_sop=yes`,
  and `Cuse_eph=yes` at marker/config level.
- `--tlm` writes a TLM marker segment for the current single tile-part length.
- `--layers N` maps to `Clayers=N`.
- `--tile-parts R` maps to Kakadu `ORGtparts=R` and Grok `-u R`; the current
  temporary payload records resolution-ordered tile-part intent.
- `--timings` prints a phase breakdown for TIFF read, RCT, DWT, block payload
  generation, JP2 wrapping, and disk write. This is the first pass at deciding
  whether the next optimization should target SIMD compute, scratch-buffer
  reuse/cache locality, or IO.

Archival-style scaffold:

```sh
zig build run -- tiff-to-jp2 example.tif example.jp2 \
  --tile 4096,4096 --progression RPCL --resolutions 6 \
  --precincts "[256,256],[256,256],[128,128],[128,128],[128,128],[128,128]" \
  --block 64 --layers 1 --tile-parts R --bypass --sop --eph
```

Production-master-style scaffold:

```sh
zig build run -- tiff-to-jp2 example.tif example.jp2 \
  --tile 1024,1024 --progression RPCL --resolutions 6 \
  --precincts "[256,256],[256,256],[128,128]" \
  --block 64 --layers 12 --tile-parts R --bypass --no-sop --no-eph
```

These options are currently reflected in the marker skeleton (`SIZ`/`COD`/`TLM`)
and temporary payload metadata. `--tile-parts R` is recorded as a
resolution-ordered tile-part plan in temporary payload version `BP1`. Real RPCL
packet ordering, precinct packetization, SOP/EPH marker emission inside
packets, physical multi-tile-part division by resolution, quality layers, and
rate control still require the ISO packet writer. Lossy `--rate/--rates`
requests fail closed for now instead of silently producing a lossless file.

## Performance and Safety Direction

- Keep parsers bounds-checked and allocation-limited.
- Use checked integer math for dimensions, offsets, byte counts, and box sizes.
- Keep hot image data in contiguous component buffers before DWT.
- Add tile-level parallelism before code-block parallelism.
- Benchmark encode/decode throughput, memory peak, and lossless roundtrip
  against OpenJPEG and Grok on the same TIFF corpus.

## Smoke Benchmark

With OpenJPEG `opj_compress`, Grok `grk_compress`, and `hyperfine` installed:

```sh
sh tools/bench_smoke.sh
sh tools/bench_profiles.sh
```

For a single local phase breakdown, add `--timings` to `tiff-to-jp2`, for
example:

```sh
./zig-out/bin/z2000 tiff-to-jp2 bench-rgb-2048.tif bench-ours-profile.jp2 \
  --tile 4096,4096 --progression RPCL --resolutions 6 \
  --precincts "[256,256],[256,256],[128,128],[128,128],[128,128],[128,128]" \
  --block 64 --layers 1 --tile-parts R --bypass --sop --eph --tlm --timings
```

Current local baseline on a synthetic uncompressed RGB TIFF 2048x2048 after
adding RCT, integer 5/3 DWT, subband partitioning, pass-oriented code-block
payloads, and the temporary pass-stream entropy abstraction:

- `z2000 tiff-to-jp2`: 316.5 ms mean, marker skeleton + bitplane-ordered pass streams, 9.4 MB output
- `z2000 decode-temp-jp2`: 280.5 ms mean, temporary project-private payload decoder
- `grk_compress`: 113.3 ms mean, real lossless JP2, 5.9 MB output
- `opj_compress`: 462.2 ms mean, real lossless JP2, 5.9 MB output
- `grk_decompress`: 86.7 ms mean
- `opj_decompress`: 530.4 ms mean

The encode comparison is still not fair yet: `z2000` performs TIFF parsing, RCT,
integer 5/3 DWT, code-block partitioning, bitplane-ordered temporary pass
writing, and JPEG2000 marker emission, but it does not yet perform EBCOT coding
passes or MQ entropy coding. Treat the number as the transform/block pipeline
budget we must preserve while adding the real packet coder.

The temporary decoder is lossless for files produced by this project-private
payload. A 256x256 RGB TIFF generated by `tools/make_bench_tiff.py` roundtrips
bit-for-bit through `tiff-to-jp2` and `decode-temp-jp2`.

The codestream marker skeleton now writes a non-zero `SOT/Psot` value and a TLM
entry. Both lengths point to the current single tile-part, from the SOT marker
to the byte before `EOC`.

The block payload is now split into significance, bitplane-ordered refinement,
and a cleanup placeholder. The temporary decoder only needs significance and
refinement to roundtrip this project-private payload, so cleanup bytes are
intentionally not generated until the real EBCOT/MQ pass structure lands.

`jp2-stats` inspects the temporary payload without decoding pixels. On the
2048x2048 smoke file it reports 3072 code-blocks, all active, 12,183,966
non-zero coefficients, 2,951,286 encoded significance bytes, 6,686,962 encoded
refinement bytes, and zero cleanup payload bytes.

The temporary encoder accepts square code-block experiments through
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
temporary generic coder.

Latest local profile comparison on the same 2048x2048 RGB TIFF:

- Archival profile encode: `z2000` 280.5 ms, Grok 115.6 ms, OpenJPEG 424.2 ms.
- Archival profile decode: `z2000` 324.9 ms, Grok 84.0 ms, OpenJPEG 449.9 ms.
- Archival output size: `z2000` 9.4 MB, Grok 6.3 MB, OpenJPEG 6.3 MB.
- Access profile 1:8 encode: Grok 192.9 ms, OpenJPEG 484.5 ms, both about
  1.5 MB. The local Grok decoder crashed on this access file, while OpenJPEG
  decoded it, so no Grok access decode number is recorded yet.

The first `--timings` run on that archival encode showed the useful direction:
roughly 95% of wall time is inside codestream generation, with block payload
generation and DWT dominating. TIFF read, JP2 wrapping, and disk write were
small single-digit percentages on the synthetic smoke file.

Optimization read from those numbers:

- Grok wins wall-clock mainly through parallelism: its user CPU is much higher
  than wall time. The next speed step for `z2000` should be tile/component or
  code-block parallelism with scratch-buffer reuse.
- The largest size gap is entropy coding. `z2000` still stores 6.7 MB of encoded
  refinement stream bytes in the archival profile, so real EBCOT context passes
  plus MQ coding are the next compression step.
- 32x32 code-blocks decode a little faster locally, but grow the file by about
  1 MB. Keep 64x64 as the archival default.

## Roadmap

1. Emit real JPEG2000 Part 1 codestream marker segments: SOC, SIZ, COD, QCD,
   TLM, SOT, SOD, EOC.
2. Add MQ arithmetic coding for code-block pass streams.
3. Replace temporary pass layout with ISO packet headers and pass length fields.
4. Add packet progression and packet headers.
5. Replace the temporary decoder with strict ISO packet/header parsing.
6. Add tile-parallel scheduling and scratch-buffer reuse for Grok-class throughput.
