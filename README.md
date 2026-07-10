# z2000

z2000 is a JPEG2000-style codec project written from scratch in Zig.

The main goal is a correct, inspectable TIFF -> JP2 conversion path before
broadening into a general-purpose codec. Unsupported JPEG2000 options are meant
to fail closed instead of silently producing payloads whose behavior is not
implemented.

Current status is tracked in [docs/iso_coverage.md](docs/iso_coverage.md). As
of 2026-07-10, the narrow RGB lossless JP2 target is estimated at **97/100**;
the broader JPEG2000 Part 1 codec family is estimated at **80/100**.

## Features

- TIFF 6.0 RGB input for uncompressed chunky 8-bit and 16-bit strips.
- JP2 output with strict codestream packet payloads and optional ICC
  preservation.
- Lossless RGB path: RCT, reversible 5/3 DWT, RPCL and other bounded
  progression orders, quality layers, PLT/TLM, strict no-sidecar decode.
- Lossy experimental path: ICT, irreversible 9/7 DWT, scalar-derived or
  scalar-expounded quantization.
- Selected JPEG2000 code-block styles where payload behavior is implemented,
  including BYPASS, terminate-all, vertical-causal, segmentation symbols, and
  scoped reset/predictable-termination profiles.
- Aligned multi-tile lossless envelope with per-tile strict decode and
  OpenJPEG/Grok/Kakadu smoke coverage for supported profiles.
- Custom educational grayscale `.z2000` path for early wavelet experiments.
- SIMD-aware kernels using Zig vectors for portable AVX2/AVX-512/NEON-style
  execution where supported by the target CPU.

Not yet complete: arbitrary JP2/JPX profiles, general component layouts,
standalone ERTERM, full multi-tile rate allocation, broad color management,
JPEG/PNG/BMP/RAW/OpenEXR input, and full metadata handling beyond the staged ICC
path.

## Build From Source

Requirements:

- Zig 0.16.x
- Git

```sh
git clone https://github.com/bezverec/z2000.git
cd z2000
zig build
zig build test
```

Build an optimized native binary:

```sh
zig build -Doptimize=ReleaseFast -Dtarget=native
```

The executable is written to:

```sh
zig-out/bin/z2000
```

## Command Examples

Inspect TIFF or DNG metadata:

```sh
zig build run -- tiff-info input.tif
zig build run -- dng-info input.dng
```

Convert TIFF to lossless JP2:

```sh
zig build run -- tiff-to-jp2 input.tif output.jp2 \
  --mct rct --transform 5-3 --qstyle none \
  --levels 5 --progression RPCL --block 64 --layers 1 --tlm
```

Convert TIFF to a rate-layered JP2:

```sh
zig build run -- tiff-to-jp2 input.tif output.jp2 \
  --mct rct --transform 5-3 --qstyle none \
  --layers 3 --rates 16,8 --threads 0 --timings
```

Inspect and decode a JP2 produced by z2000:

```sh
zig build run -- jp2-info output.jp2
zig build run -- jp2-stats output.jp2
zig build run -- decode-temp-jp2 output.jp2 reconstructed.tif --threads 0
```

Run the older educational grayscale codec:

```sh
zig build run -- encode input.pgm output.z2000 --wavelet 5-3 --levels 3 --quant 1
zig build run -- decode output.z2000 reconstructed.pgm
```

Useful debug option:

```sh
--debug-temp-sidecar
```

This emits the private BP8 `COM` sidecar used as a diagnostic/oracle payload.
Normal encode omits it.

## Supported Input Boundary

The production TIFF path is deliberately narrow:

- one TIFF image / first IFD;
- RGB photometric interpretation;
- chunky/interleaved samples;
- 8 or 16 unsigned bits per channel;
- uncompressed strip storage;
- optional ICC tag 34675 copied into JP2 restricted ICC `colr`.

Unsupported compression, palette color, planar RGB, CMYK, tiled TIFF,
floating-point samples, extra alpha/sample channels, mixed bit depth, signed
sample formats, and multipage handling fail closed.

## Documentation

Detailed notes live in `docs/`:

- [Architecture](docs/architecture.md)
- [API notes](docs/api.md)
- [ISO coverage scorecard](docs/iso_coverage.md)
- [Roadmap](docs/roadmap.md)
- [Next steps](docs/next_steps.md)
- [Optimization plan](docs/optimization_plan.md)
- [Multi-tile plan](docs/multi_tile_plan.md)
- [Changelog](docs/changelog.md)

## Project Direction

Near term: keep closing the narrow RGB lossless JP2 target, especially strict
T2/T1 behavior and interop gates.

Full codec target: broaden JPEG2000 Part 1 support across tiles, packet orders,
profiles, quantization, code-block styles, and foreign decode surfaces.

Later conversion-tool target: add JPEG/PNG/BMP input first, then RAW/DNG and
OpenEXR workflows; broaden color spaces to monochrome, sRGB, palette, YCC,
extended YCC, CIELab, and CMYK; preserve EXIF/IPTC/XMP; and evaluate component
depths above 16 bits where the source format and JPEG2000 profile support them
cleanly.
