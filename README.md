# z2000

z2000 is a JPEG2000-style codec project written from scratch in Zig.

The main goal is a correct, inspectable TIFF -> JP2 conversion path before
broadening into a general-purpose codec. Unsupported JPEG2000 options are meant
to fail closed instead of silently producing payloads whose behavior is not
implemented.

Current status is tracked in [docs/iso_coverage.md](docs/iso_coverage.md). As
of 2026-07-13, both the narrow RGB lossless JP2 target and the broader
JPEG2000 Part 1 engineering scorecard are estimated at **100/100**. This is a
project-readiness estimate, not a formal ISO conformance certification.

## Features

- TIFF 6.0 RGB and grayscale input: uncompressed chunky 8-bit or 16-bit
  strips, including optional ICC profile preservation.
- Lossless JP2 encoding with RCT, reversible 5/3 DWT, quality layers, all five
  progression orders, PLT/TLM, and strict no-sidecar decode.
- Lossy JP2 encoding with ICT, irreversible 9/7 DWT, scalar-derived or
  scalar-expounded quantization, and rate allocation.
- Reference-grid-aware single- and multi-tile encode/decode, including odd
  tile origins and global cross-tile rate targets.
- ISO-MQ T1 coding with all six Part 1 code-block style bits, plus in-band,
  PPM, and PPT packet headers on their documented profiles.
- Bounded grayscale and palette JP2 profiles, strict malformed-input handling,
  and OpenJPEG/Grok/Kakadu interoperability tests.
- Custom educational grayscale `.z2000` path for early wavelet experiments.
- SIMD-aware kernels using Zig vectors for portable AVX2/AVX-512/NEON-style
  execution where supported by the target CPU.

Not yet complete: arbitrary JP2/JPX profiles, general component layouts,
non-empty PLT-less multi-part tiles, broad color management,
JPEG/PNG/BMP/RAW/OpenEXR input, and metadata handling beyond the staged ICC
path. See the [ISO coverage scorecard](docs/iso_coverage.md) for the exact
supported envelope.

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

Inspect the application version and exact source provenance:

```sh
zig build run -- --version
# z2000 0.1.0-dev.382+ge93a31e0
```

z2000 starts conservatively on the `0.1.x` line. Development builds use the
SemVer form `0.1.0-dev.BUILD+gCOMMIT`; release builds use
`0.1.0+build.BUILD.gCOMMIT`, and release candidates use
`0.1.0-rc.N+build.BUILD.gCOMMIT`. `BUILD` is the reachable Git commit count
and `COMMIT` is the eight-character revision. See
[Versioning](docs/versioning.md) for release and source-archive rules.

## Command Examples

The examples call the built binary directly; add `zig-out/bin` to `PATH` or
prefix the commands with `./zig-out/bin/`. Conversions need no subcommand —
the direction is inferred from the file extensions (`.tif`/`.tiff` and
`.jp2`, case-insensitive); the explicit `tiff-to-jp2` and `decode-temp-jp2`
subcommands keep working.

Convert TIFF to lossless JP2 (the defaults already produce the archival
RCT + reversible 5/3 profile):

```sh
z2000 input.tif output.jp2
```

Convert TIFF to a rate-layered JP2 (the `--rates` list sets the layer count;
the final layer always carries the complete stream, so a trailing `1` makes
the lossless-final intent explicit):

```sh
z2000 input.tif output.jp2 --rates 16,8,1 --threads 0 --timings
```

Decode a JP2 back to TIFF and inspect it:

```sh
z2000 output.jp2 reconstructed.tif --threads 0
z2000 jp2-info output.jp2
z2000 jp2-stats output.jp2
```

Inspect TIFF or DNG metadata:

```sh
z2000 tiff-info input.tif
z2000 dng-info input.dng
```

Run the older educational grayscale codec:

```sh
z2000 encode input.pgm output.z2000 --wavelet 5-3 --levels 3 --quant 1
z2000 decode output.z2000 reconstructed.pgm
```

## CLI Reference

Main conversion command (the subcommand is optional when the extensions
identify the direction):

```sh
z2000 input.tif output.jp2 [options]
z2000 tiff-to-jp2 input.tif output.jp2 [options]
```

For normal lossless conversion, the defaults are usually sufficient. The most
useful options are grouped below. Unsupported combinations fail closed rather
than silently changing the codestream profile.

### Profile And Quality

- **--mct MODE**: Color transform: **rct** for reversible RGB, **ict** for
  irreversible RGB, or **none** for component-independent coding.
- **--transform MODE**: Wavelet transform: reversible **5-3** or irreversible
  **9-7**.
- **--qstyle STYLE**: Quantization: **none**, **scalar-derived**, or
  **scalar-expounded**. Use none with 5-3 and a scalar style with 9-7.
- **--guard-bits N**: Number of QCD guard bits.
- **--layers N**: Number of untargeted quality layers.
- **--rates LIST**: Comma-separated compression-ratio targets, for example
  **16,8,1**. The list sets the layer count; a final 1 requests a complete
  final layer.

### Resolution, Tiles, And Packet Order

- **--levels N**: Number of wavelet decomposition levels.
- **--resolutions N**: Alternative spelling where resolutions equal levels
  plus one.
- **--block N**: Square code-block size.
- **--precincts LIST**: Per-resolution precinct sizes, for example
  **"[256,256],[128,128]"**.
- **--tile W,H**: Tile dimensions. A tile smaller than the image enables the
  bounded multi-tile path.
- **--progression ORDER**: Packet order: **RPCL**, **LRCP**, **RLCP**,
  **PCRL**, or **CPRL**.
- **--tile-parts MODE**: Tile-part division: **none**, **R**, **L**, **C**,
  or **P**. The mode must match a compatible packet order.
- **--poc RECORDS**: Advanced progression changes using ISO fields in the
  form **RSpoc,CSpoc,LYEpoc,REpoc,CEpoc,ORDER**. Separate records with a
  semicolon.
- **--poc-location PLACE**: Write POC in the **main** header or first **tile**
  header. Tile-header POC cannot be combined with PPM or PPT.

### Markers And T1 Resilience

Boolean marker and style options also accept a **--no-...** form.

- **--sop**, **--eph**, **--tlm**: Emit SOP, EPH, or TLM markers.
- **--ppm**, **--ppt**: Move packet headers into PPM or PPT markers. These
  options are mutually exclusive and profile-bounded.
- **--t1-backend BACKEND**: Use the normal **iso-mq** backend or the internal
  **legacy-mq** compatibility backend.
- **--bypass**: Enable selective arithmetic-coding bypass.
- **--reset-context**: Reset MQ contexts at coding-pass boundaries.
- **--terminate-all**: Terminate every coding pass.
- **--vertical-causal**: Enable vertical-causal context formation.
- **--predictable-termination**: Enable ER-TERM predictable termination.
- **--segmentation-symbols**: Append cleanup-pass segmentation symbols.

### Runtime And Diagnostics

- **--threads N**: Worker count. Zero uses all logical CPU threads.
- **--timings**: Print encode/decode phase timings and available T1 profiles.
- **--debug-temp-sidecar**: Emit the private BP8 COM sidecar for diagnostics.
  Normal files omit it.

Other commands:

- **tiff-info INPUT**: Inspect supported TIFF metadata.
- **dng-info INPUT**: Inspect TIFF-style DNG metadata.
- **jp2-info INPUT**: Show the JP2 container and codestream summary.
- **jp2-stats INPUT**: Audit packet headers, block catalogs, and payload sizes.
- **decode-temp-jp2 INPUT OUTPUT**: Strict-decode JP2 into TIFF. The command
  keeps its historical name for compatibility and accepts --threads,
  --t1-backend, and --timings.

The full profile matrix and internal API surface are documented in
[API notes](docs/api.md).

## Supported Input Boundary

The production `tiff-to-jp2` path is deliberately narrow:

- one TIFF image / first IFD;
- RGB, BlackIsZero grayscale, or WhiteIsZero grayscale photometric
  interpretation;
- chunky/interleaved samples;
- 8 or 16 unsigned bits per channel;
- uncompressed strip storage;
- optional ICC tag 34675 copied into JP2 restricted ICC `colr`.

The one-component CLI path is currently single-tile RPCL with reversible 5/3,
ISO MQ, in-band packet headers, PLT, optional TLM/SOP/EPH, and either one tile
part or `R` resolution tile-parts. OpenJPEG 2.5.4 and Grok 20.3.6 decode the
8-bit and 16-bit output pixel-exactly; z2000 strict-decodes both references'
grayscale output pixel-exactly too. Multi-tile grayscale and general or mixed
component layouts remain fail-closed.

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
- [Post-Part 1 feature plan](docs/feature_plan.md)
- [Comparative benchmarks](docs/benchmarks.md)
- [Multi-tile plan](docs/multi_tile_plan.md)
- [Versioning](docs/versioning.md)
- [Changelog](docs/changelog.md)

Run the maintained four-codec benchmark on Windows with an optional lossy
ICT/9/7 rate-target profile:

```powershell
.\tools\bench_compare.ps1 -InputPath .\zig-out\bench-rgb-2048.tif `
  -Runs 8 -Warmup 2 -Threads all -IncludeLossy
```

The POSIX harness accepts the same extension through `INCLUDE_LOSSY=1`.

## Project Direction

Near term: keep both engineering scorecards at 100/100 while hardening release
gates, strict decode, interoperability, and performance inside the documented
profile envelope.

Full codec target: broaden JPEG2000 Part 1 support across tiles, packet orders,
profiles, quantization, code-block styles, and foreign decode surfaces.

Later conversion-tool target: add JPEG/PNG/BMP input first, then RAW/DNG and
OpenEXR workflows; broaden color spaces beyond the bounded sRGB palette path to YCC,
extended YCC, CIELab, and CMYK; preserve EXIF/IPTC/XMP; and evaluate component
depths above 16 bits where the source format and JPEG2000 profile support them
cleanly.
