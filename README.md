# z2000

z2000 is a JPEG2000-style codec project written from scratch in Zig.

The main goal is a correct, inspectable TIFF -> JP2 conversion path before
broadening into a general-purpose codec. Unsupported JPEG2000 options are meant
to fail closed instead of silently producing payloads whose behavior is not
implemented.

Current status is tracked in [docs/iso_coverage.md](docs/iso_coverage.md). As
of 2026-07-12, the narrow RGB lossless JP2 target is estimated at **100/100**;
the broader JPEG2000 Part 1 codec family is estimated at **95/100**.

## Features

- TIFF 6.0 RGB input for uncompressed chunky 8-bit and 16-bit strips.
- JP2 output with strict codestream packet payloads and optional ICC
  preservation.
- Lossless RGB path: RCT, reversible 5/3 DWT, RPCL and other bounded
  progression orders, quality layers, PLT/TLM, strict no-sidecar decode.
- Lossy experimental path: ICT, irreversible 9/7 DWT, scalar-derived or
  scalar-expounded quantization, single-tile and reference-grid-aware
  multi-tile including odd tile origins.
- All six JPEG2000 code-block style bits (BYPASS, RESET, terminate-all,
  vertical-causal, predictable termination, segmentation symbols) in every
  combination, with three-decoder interop coverage on the ISO-MQ path.
- Reference-grid-aware multi-tile lossless encode/decode with origin-aware
  reversible 5/3 lifting, OpenJPEG/Grok/Kakadu smoke coverage for supported
  profiles, foreign PLT-less streams using explicit, default, or odd-origin
  precinct/tile partitions, and foreign multi-part tile sequences (grouped or
  interleaved PLT-backed parts, TNsot 0, empty padding parts).
- Custom educational grayscale `.z2000` path for early wavelet experiments.
- SIMD-aware kernels using Zig vectors for portable AVX2/AVX-512/NEON-style
  execution where supported by the target CPU.

Not yet complete: arbitrary JP2/JPX profiles, general component layouts,
full multi-tile rate allocation, non-empty PLT-less multi-part tiles,
broad color management,
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

Convert TIFF to a rate-layered JP2 (the `--rates` list sets the layer count;
the final layer always carries the complete stream, so a trailing `1` makes
the lossless-final intent explicit):

```sh
zig build run -- tiff-to-jp2 input.tif output.jp2 \
  --mct rct --transform 5-3 --qstyle none \
  --rates 16,8,1 --threads 0 --timings
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

## Supported CLI Options

Main conversion command:

```sh
z2000 tiff-to-jp2 input.tif output.jp2 [options]
```

Profile and transform options:

| Option | Meaning |
| --- | --- |
| `--mct rct|ict|none` | Multi-component transform: reversible RGB color transform, irreversible color transform, or no color transform. |
| `--transform 5-3|9-7` | Wavelet transform: reversible 5/3 for lossless, irreversible 9/7 for lossy experiments. |
| `--qstyle none|scalar-derived|scalar-expounded` | Quantization marker style. Use `none` with 5/3 lossless; scalar styles belong to the 9/7 path. |
| `--guard-bits N` | QCD guard bits. Defaults are chosen for the current profile; unusual values remain bounded by strict validation. |

Packet, layer, and geometry options:

| Option | Meaning |
| --- | --- |
| `--levels N` | Number of DWT decomposition levels. |
| `--resolutions N` | Alternative to `--levels`; resolutions are levels + 1. |
| `--progression RPCL|LRCP|RLCP|PCRL|CPRL` | JPEG2000 progression order. Supported paths are still profile-bounded and fail closed when unsafe. |
| `--layers N` | Number of quality layers (untargeted even split). When `--rates` is given, the rate-list length sets the layer count and overrides `--layers`. |
| `--rates R1,R2,...` | Compression-ratio targets for layered output, referenced to the total compressed payload (unlike OpenJPEG's `-r`, which references the uncompressed size). The final layer always carries the complete stream, so end the list with `1` for an explicit lossless-final ladder. Single- and multi-tile paths use global PCRD; single-tile also charges measured packet-header bytes directly. |
| `--precincts "[W,H],[W,H]"` | Per-resolution precinct sizes. Values must satisfy the current ISO B.6/B.7 geometry guards. |
| `--block N` | Square code-block size. |
| `--tile W,H` | Tile size. Multi-tile support is the bounded reference-grid lossless envelope (explicit, default, or odd-origin partitions). |
| `--tile-parts none|R|L|C|P` | Tile-part division mode: one part per tile, per resolution (`R` with RPCL), layer (`L` with LRCP), RGB component (`C` with CPRL), or reference-grid precinct position (`P` with PCRL). Divided layouts are currently multi-tile. |

Marker, T1, and diagnostics:

| Option | Meaning |
| --- | --- |
| `--sop` / `--no-sop` | Enable or disable SOP packet markers. SOP is enabled by default for the narrow archival profile. |
| `--eph` / `--no-eph` | Enable or disable EPH packet-header markers. |
| `--ppm` / `--no-ppm` | Move packet headers into main-header PPM markers. Supported for RPCL `R` layouts with SOP/EPH disabled, including multi-tile streams. PPM and PPT are mutually exclusive. Multi-part PPM is lossless through z2000, OpenJPEG, and Kakadu; Grok 20.3.6 currently misdecodes the multi-tile/multi-part combination. |
| `--ppt` / `--no-ppt` | Move packet headers into PPT markers. Supported for RPCL with SOP/EPH disabled: single-tile streams may use one part or `R` resolution parts, while multi-tile streams require `R` parts. Other combinations fail closed. |
| `--tlm` / `--no-tlm` | Enable or disable TLM tile-part length markers. |
| `--t1-backend iso-mq|legacy-mq` | Select the T1 entropy backend. `iso-mq` is the normal JPEG2000-style path. |
| `--bypass` / `--no-bypass` | Enable or disable BYPASS coding style where the payload model is implemented. |
| `--reset-context` / `--no-reset-context` | Toggle RESET context style in supported envelopes. |
| `--terminate-all` / `--no-terminate-all` | Toggle TERMALL pass termination. |
| `--vertical-causal` / `--no-vertical-causal` | Toggle vertical-causal context behavior. |
| `--predictable-termination` / `--no-predictable-termination` | Toggle predictable (ER-TERM) termination, standalone or TERMALL-scoped. |
| `--segmentation-symbols` / `--no-segmentation-symbols` | Toggle segmentation symbols where supported. |
| `--threads N` | Worker count. `0` means use all logical threads. |
| `--timings` | Print encode/decode timing breakdowns. |
| `--debug-temp-sidecar` | Emit the private BP8 sidecar for diagnostics; normal encode omits it. |

Inspection and decode commands:

| Command | Meaning |
| --- | --- |
| `tiff-info input.tif` | Print TIFF metadata accepted by the current parser. |
| `dng-info input.dng` | Print DNG/TIFF-style metadata for inspection. |
| `jp2-info output.jp2` | Print JP2 container and codestream summary. |
| `jp2-stats output.jp2` | Audit packet headers, strict packet catalog, and payload statistics. |
| `decode-temp-jp2 output.jp2 reconstructed.tif [--threads N] [--timings]` | Strict-decode a JP2 into TIFF. The historical command name remains for compatibility. |

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

Near term: hold the narrow RGB lossless JP2 target at 100/100 (strict T2/T1
behavior and interop gates must stay green) while broadening the full Part 1
coverage tracked in the scorecard.

Full codec target: broaden JPEG2000 Part 1 support across tiles, packet orders,
profiles, quantization, code-block styles, and foreign decode surfaces.

Later conversion-tool target: add JPEG/PNG/BMP input first, then RAW/DNG and
OpenEXR workflows; broaden color spaces to monochrome, sRGB, palette, YCC,
extended YCC, CIELab, and CMYK; preserve EXIF/IPTC/XMP; and evaluate component
depths above 16 bits where the source format and JPEG2000 profile support them
cleanly.
