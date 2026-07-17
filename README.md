# z2000

z2000 is a JPEG2000-style codec project written from scratch in Zig.

The main goal is a correct, inspectable TIFF -> JP2 conversion path before
broadening into a general-purpose codec. Unsupported JPEG2000 options are meant
to fail closed instead of silently producing payloads whose behavior is not
implemented.

Current status is tracked in [docs/iso_coverage.md](docs/iso_coverage.md). As
of 2026-07-17, both the narrow RGB lossless JP2 target and the broader
JPEG2000 Part 1 engineering scorecard are estimated at **100/100**. The current
prerelease is [`v0.2.0-rc.1`](https://github.com/bezverec/z2000/releases/tag/v0.2.0-rc.1).
This is a project-readiness estimate, not a formal ISO conformance
certification.

## Features

- TIFF 6.0 RGB, grayscale, gray+alpha, and RGBA input: uncompressed chunky
  8-bit or 16-bit strips, including optional ICC profile preservation and
  associated/unassociated alpha semantics.
- Bounded Windows BMP input: uncompressed 24/32-bit `BITMAPINFOHEADER` pixels,
  including DWORD row padding and top-down or bottom-up storage. Unsupported
  compression, bitfields, palettes, alpha interpretation, and newer DIB
  headers fail closed.
- Bounded PNG input: non-interlaced grayscale, truecolor, indexed-color,
  grayscale+alpha, and RGBA with every legal 1/2/4/8/16-bit combination,
  `PLTE`/`tRNS`, all five scanline filters, zlib, and strict chunk CRC/order
  validation. Packed samples and transparency expand into existing grayscale,
  RGB, or unassociated-alpha carriers.
- Bounded JPEG input: 8-bit Huffman-coded baseline sequential DCT with one
  complete interleaved scan, grayscale or JFIF YCbCr 4:4:4/4:2:2/4:2:0,
  centered chroma interpolation, optional restart intervals, and exact
  preservation of standard Exif/XMP APP1 plus one Photoshop APP13 IPTC-IIM
  resource. Progressive, arithmetic/lossless, CMYK/YCCK, multi-scan, extended
  XMP, ICC APP2, and arbitrary Photoshop resources fail closed.
- Lossless JP2 encoding with RCT, reversible 5/3 DWT, quality layers, all five
  progression orders, PLT/TLM, and strict no-sidecar decode.
- Lossy JP2 encoding with irreversible 9/7 DWT, ICT or bounded single-tile
  no-MCT component coding, scalar-derived or scalar-expounded quantization,
  and rate allocation. Single-tile no-MCT or transform-appropriate RCT/ICT
  decode can reconstruct a selected lower DWT resolution directly.
- Reference-grid-aware single- and multi-tile encode/decode, including odd
  tile origins and global cross-tile rate targets.
- ISO-MQ T1 coding with all six Part 1 code-block style bits, plus in-band,
  PPM, and PPT packet headers on their documented profiles.
- Bounded grayscale and palette JP2 profiles, plus bounded 1..4-component
  planar layouts, alpha-aware JP2 `cdef` signalling, and reversible RGBA RCT
  over the RGB triplet only, with strict malformed-input handling and
  OpenJPEG/Grok/Kakadu interoperability tests.
- Explicit JP2 colour metadata with sRGB, grayscale, restricted ICC, sYCC,
  CMYK, default-parameter CIELab, e-sRGB, and e-sYCC recognition. The latter
  four are lossless signalling/native-plane preservation boundaries and are
  never silently treated as RGB. The JP2-to-TIFF path converts unsigned
  8/16-bit sYCC 4:4:4,
  4:2:2, and 4:2:0 to sRGB, including the explicit odd-origin edge phase;
  `--convert-to-srgb` separately converts bounded ICC v2/v4 RGB matrix/TRC
  PCSXYZ profiles. General/LUT ICC transforms remain fail-closed.
- Byte-preserving EXIF, XMP, and IPTC-IIM metadata carriers in checked JP2 UUID
  boxes, with bounded baseline JPEG APP1/APP13 ingestion. Managed duplicates
  and malformed TIFF/XML/IIM payloads fail closed.
- Bounded planar encode/decode for mixed unsigned 8/16-bit component
  precision, including JP2 `BPCC`/codestream `SIZ` agreement and
  per-component QCD/QCC on the single-tile RPCL 5/3 path. z2000 output is
  pixel-exact through OpenJPEG, Grok, and Kakadu PGX decode.
- Bounded component-subsampling decode with per-component SIZ `XRsiz/YRsiz`,
  reference-grid RPCL merging across unequal component precinct grids,
  component-local T1/DWT geometry, and variable-size planar output. Embedded
  Kakadu 4:2:0 fixtures reconstruct one- and multi-precinct single-tile planes
  plus multi-tile planes at zero, matching, or distinct image/tile-partition
  origins exactly, with or without PLT. Checked POC schedules may use LRCP, RLCP, RPCL, PCRL,
  or CPRL from the main or first tile-part header. A reference-grid
  nearest-neighbour API expands native
  planes without colour conversion, and the extension-inferred JP2-to-TIFF
  path uses it for bounded
  three-component sRGB output. Inline, PPT, and PPM headers plus SOP/EPH are
  covered. The sampled reversible API emits single- and multi-tile RPCL with
  inline PLT/PLT-less, PPT, or PPM packet headers; all layouts carry one or
  more quality layers.
- Custom educational grayscale `.z2000` path for early wavelet experiments.
- SIMD-aware kernels using Zig vectors for portable AVX2/AVX-512/NEON-style
  execution where supported by the target CPU.

Not yet complete: arbitrary JP2/JPX profiles, component layouts beyond the
bounded 1..4 envelope (including mixed-precision sampled multi-tile/MCT),
non-empty PLT-less multi-part tiles, broad color management, CFA/general RAW
and HDR/general OpenEXR input, broader BMP/PNG/JPEG/DNG/EXR profiles, and metadata handling
beyond the staged ICC and JPEG UUID-carrier paths. See the [ISO coverage scorecard](docs/iso_coverage.md) for the exact
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
zig build part1-corpus
```

The official T.803 profile-0 files are optional and stay outside the
repository. On PowerShell, pin the maintained WG1 checkout and require every
local corpus entry with:

```powershell
.\tools\setup_part1_corpus.ps1
$env:Z2000_PART4_ROOT = (Resolve-Path .zig-cache\part4\htj2k-codestreams).Path
zig build part1-corpus -- --require-optional
```

Build an optimized native binary:

```sh
zig build -Doptimize=ReleaseFast -Dtarget=native
```

The executable is written to `zig-out/bin` under two equivalent names:

```sh
zig-out/bin/z2000
zig-out/bin/z2k
```

Inspect the application version and exact source provenance:

```sh
zig build run -- --version
# z2000 0.2.0-dev.BUILD+gCOMMIT
```

The active development line is `0.2.x`. Development builds use the SemVer
form `0.2.0-dev.BUILD+gCOMMIT`; release builds use
`0.2.0+build.BUILD.gCOMMIT`, and release candidates use
`0.2.0-rc.N+build.BUILD.gCOMMIT`. `BUILD` is the reachable Git commit count
and `COMMIT` is the eight-character revision. See
[Versioning](docs/versioning.md) for release and source-archive rules.

## Command Examples

The examples call the built binary directly; add `zig-out/bin` to `PATH` or
prefix the commands with `./zig-out/bin/`. The build installs the binary
twice: as `z2000` and as the short alias `z2k` — every command works
identically under both names. Conversions need no subcommand — the
direction is inferred from the file extensions (`.tif`/`.tiff`, `.bmp`,
`.png`, `.jpg`/`.jpeg`, `.dng`, `.exr`, and `.jp2`,
case-insensitive); the explicit `tiff-to-jp2` and `decode-temp-jp2`
subcommands keep working, as do `bmp-to-jp2`, `png-to-jp2`, and
`jpeg-to-jp2`, `dng-to-jp2`, and `exr-to-jp2`. All commands
default to using every logical CPU thread; pass `--threads N` to limit the
worker count.

Convert TIFF to lossless JP2 (the defaults already produce the archival
RCT + reversible 5/3 profile):

```sh
z2k input.tif output.jp2
```

Convert a bounded 24/32-bit BMP to lossless JP2:

```sh
z2k input.bmp output.jp2
```

Convert a bounded PNG to lossless JP2:

```sh
z2k input.png output.jp2
```

Decode a bounded baseline JPEG and store its reconstructed raster losslessly
in JP2:

```sh
z2k input.jpg output.jp2
```

Convert a bounded three-channel LinearRaw DNG while retaining its linear
camera-to-PCS interpretation in a restricted ICC profile:

```sh
z2k input.dng output.jp2
```

Convert a bounded normalized-linear OpenEXR to JP2:

```sh
z2k input.exr output.jp2
```

Convert every matching TIFF in one directory, keeping each basename:

```sh
z2k *.tif .jp2
z2k *.bmp .jp2
z2k *.png .jp2
z2k *.jpg .jp2
z2k *.dng .jp2
z2k *.exr .jp2
z2k incoming/*.tiff .jp2 --threads 8
```

Batch patterns support `*` and `?`, are non-recursive and case-insensitive,
and must have a concrete parent directory. The target is a bare extension.
Quotes are not part of the syntax: PowerShell passes the pattern to z2000 for
internal expansion, while shells such as Bash may expand it to an explicit
input list that z2000 accepts as the same batch. All normal conversion options
apply to every match. Output-name collisions are rejected before conversion;
existing target files retain the single-file overwrite behavior.

Convert TIFF to a rate-layered JP2 (the `--rates` list sets the layer count;
the final layer always carries the complete stream, so a trailing `1` makes
the lossless-final intent explicit):

```sh
z2k input.tif output.jp2 --rates 16,8,1 --timings
```

Decode a JP2 back to TIFF and inspect it:

```sh
z2k output.jp2 reconstructed.tif
z2k jp2-info output.jp2
z2k jp2-stats output.jp2
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
z2000 input.bmp output.jp2 [options]
z2000 bmp-to-jp2 input.bmp output.jp2 [options]
z2000 input.png output.jp2 [options]
z2000 png-to-jp2 input.png output.jp2 [options]
z2000 input.jpg output.jp2 [options]
z2000 jpeg-to-jp2 input.jpg output.jp2 [options]
z2000 input.dng output.jp2 [options]
z2000 dng-to-jp2 input.dng output.jp2 [options]
z2000 input.exr output.jp2 [options]
z2000 exr-to-jp2 input.exr output.jp2 [options]
```

The DNG adapter accepts exactly one uncompressed, chunky, unsigned 8/16-bit
three-channel `LinearRaw` IFD at orientation 1 and DNG version 1.2 through
1.7.1. It applies optional
`LinearizationTable`, scalar/per-channel black and white levels, and the
bounded one-illuminant `ForwardMatrix1`/`AsShotNeutral` path. The normalized
samples remain linear and carry a matrix/identity-TRC ICC profile; they are not
silently relabelled as sRGB. CFA mosaics, tiles, compression, crop/opcode
processing, multiple calibrations, and EXIF/XMP/IPTC payloads fail closed.

This product includes DNG technology under license by Adobe.

The OpenEXR adapter accepts a single-part, uncompressed scanline image with
exactly full-resolution HALF `R`, `G`, and `B` channels, matching data/display
windows, square pixels, explicit chromaticities, and no unmapped attributes.
Only finite linear samples in `[0,1]` are accepted; they are scaled to the
unsigned 16-bit carrier and retain their primaries through a generated linear
ICC profile. Negative/HDR values, alpha/arbitrary channels, compression,
tiles, multipart/deep files, and metadata fail closed until their OpenEXR
source semantics have an explicit mapping into the existing JP2 carriers.

For normal lossless conversion, the defaults are usually sufficient. The most
useful options are grouped below. Unsupported combinations fail closed rather
than silently changing the codestream profile.

### Profile And Quality

- **--mct MODE**: Color transform: **rct** for reversible RGB, **ict** for
  irreversible RGB, or **none** for component-independent coding. RGBA
  defaults to **rct** over RGB only; gray+alpha always uses **none**.
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

- **--threads N**: Worker count. The default already uses all logical CPU
  threads; pass an explicit N to limit the workers (0 also means all).
- **--timings**: Print encode/decode phase timings and T1 work profiles.
- **--debug-temp-sidecar**: Emit the private BP8 COM sidecar for diagnostics.
  Normal files omit it.

Other commands:

- **tiff-info INPUT**: Inspect supported TIFF metadata.
- **dng-info INPUT**: Inspect TIFF-style DNG metadata.
- **jp2-info INPUT**: Show the JP2 container and codestream summary.
- **jp2-stats INPUT**: Audit packet headers, block catalogs, and payload sizes.
- **decode-temp-jp2 INPUT OUTPUT**: Strict-decode JP2 into TIFF. The command
  keeps its historical name for compatibility and accepts --threads,
  --t1-backend, --convert-to-srgb, and --timings. ICC conversion is opt-in;
  without the flag, profile bytes and samples are preserved unchanged.

The full profile matrix and internal API surface are documented in
[API notes](docs/api.md).

## Supported Input Boundary

The BMP adapter accepts only the 14-byte Windows file header followed by the
40-byte `BITMAPINFOHEADER`, `BI_RGB`, one plane, and 24- or 32-bit pixels.
Widths must be positive; positive and negative heights select bottom-up and
top-down storage. Rows are DWORD-aligned, BGR is converted to RGB, and the
reserved fourth byte in 32-bit `BI_RGB` is ignored. Header lengths, offsets,
dimensions, raster sizes, and arithmetic are checked before allocation.

The PNG adapter accepts all standard color types and legal bit depths in the
non-interlaced profile. It validates the signature, every chunk CRC, critical
chunk ordering, palette/transparency bounds, exact decompressed size, zlib
checksum, and scanline filters before expanding samples. Packed grayscale is
scaled exactly to 8 bits; palette and `tRNS` are expanded without compositing;
16-bit samples remain 16-bit. Adam7, APNG, ICC/cICP, and non-sRGB chromaticity/
gamma chunks fail closed. Other ancillary metadata is not yet preserved.

The JPEG adapter accepts one 8-bit SOF0 frame and one complete interleaved
baseline scan using Huffman entropy coding and 8-bit quantization tables.
One-component grayscale and three-component JFIF YCbCr with 1x1, 2x1, or 2x2
luma sampling are decoded through dequantization, reference IDCT, and centered
chroma interpolation. DRI/RST intervals are supported. Because JPEG input is
already lossy, the JP2 contains the chosen decoded 8-bit raster losslessly; it
does not preserve JPEG DCT coefficients. Standard Exif APP1 is normalized to a
standalone TIFF payload, standard XMP APP1 to its UTF-8 XML packet, and one
Photoshop APP13 IPTC resource to its exact IIM bytes; all three are stored in
checked JP2 UUID boxes. Progressive/multi-scan, arithmetic,
lossless/hierarchical, CMYK/YCCK, non-8-bit, extended XMP, ICC APP2, arbitrary
Photoshop resources, and unsupported sampling fail closed. Metadata is not yet
restored by the JP2-to-TIFF command.

The production `tiff-to-jp2` path is deliberately narrow:

- one TIFF image / first IFD;
- RGB, BlackIsZero grayscale, or WhiteIsZero grayscale photometric
  interpretation, optionally with one final associated or unassociated alpha
  sample;
- chunky/interleaved samples;
- 8 or 16 unsigned bits per channel;
- uncompressed strip storage;
- optional ICC tag 34675 copied into JP2 restricted ICC `colr`.

The one-component CLI path is currently single-tile RPCL with reversible 5/3,
ISO MQ, in-band packet headers, PLT, optional TLM/SOP/EPH, and either one tile
part or `R` resolution tile-parts. OpenJPEG 2.5.4 and Grok 20.3.6 decode the
8-bit and 16-bit output pixel-exactly; z2000 strict-decodes both references'
grayscale output pixel-exactly too. The same planar engine also serves
bounded 2- and 4-component planar layouts through the library API
(`encodeLosslessPlanarWithOptions`/`decodeLosslessPlanar`, OpenJPEG/Grok
pixel-exact). The CLI now maps TIFF `ExtraSamples` values 1/2 to strict
gray+alpha or RGBA JP2 `cdef` semantics and back without changing
associated/unassociated samples. Gray+alpha uses no MCT; RGBA defaults to RCT
over RGB while alpha remains an independently level-shifted component.
Explicit `--mct none` remains available for RGBA. Mixed unsigned 8/16-bit
foreign codestreams can be reconstructed through the strict planar library
API when they are single-tile RPCL, reversible 5/3, and no-MCT; the same
bounded library path can encode them and emit JP2 `BPCC`. The TIFF CLI remains
uniform-depth and mixed multi-tile/MCT profiles stay fail-closed. The planar
decoder also accepts the bounded RPCL/no-MCT/5-3 subsampling
profile with inline packet headers, with or without PLT, including unequal
component precinct grids; component dimensions are available through
`SamplePlanes.componentDimensions`. Matching or distinct image and
tile-partition origins are supported for single- and multi-tile streams, which
assemble native component planes tile by tile.
`decodeLosslessPlanarUpsampled` provides explicit
origin-anchored nearest-neighbour expansion to full reference-grid planes;
the JP2-to-TIFF CLI interleaves those planes only after the JP2 wrapper has
established bounded sRGB semantics. Sampled PPT/PPM and SOP/EPH decode are
covered; the sampled writer emits single- and multi-tile RPCL with inline PLT,
inline PLT-less, PPT, or PPM packet headers, untargeted layers, and SOP/EPH
framing. Reordered sampled POC is supported except with PPM. The sampled
library encoder accepts absolute SIZ origins through
`LosslessOptions.image_origin_x/y` and `tile_origin_x/y`; the TIFF CLI
continues to emit zero-origin images.

Unsupported compression, palette color, planar RGB, CMYK, tiled TIFF,
floating-point samples, unspecified or multiple auxiliary channels, mixed bit
depth, signed sample formats, and multipage handling fail closed.

## Documentation

Detailed notes live in `docs/`:

- [Documentation index](docs/README.md)
- [Architecture](docs/architecture.md)
- [API notes](docs/api.md)
- [ISO coverage scorecard](docs/iso_coverage.md)
- [Part 1 corpus gate](docs/part1_corpus.md)
- [Roadmap](docs/roadmap.md)
- [Next steps](docs/next_steps.md)
- [Optimization plan](docs/optimization_plan.md)
- [Comparative benchmarks](docs/benchmarks.md)
- [Versioning](docs/versioning.md)
- [Changelog](docs/changelog.md)
- [Completed plan archive](docs/archive/README.md)

Run the maintained four-codec benchmark on Windows with an optional lossy
ICT/9/7 rate-target profile:

```powershell
.\tools\bench_compare.ps1 -InputPath .\zig-out\bench-rgb-2048.tif `
  -Runs 8 -Warmup 2 -Threads all -IncludeLossy
```

The POSIX harness accepts the same extension through `INCLUDE_LOSSY=1`.
Locally licensed Kakadu demo applications can be supplied on Linux or macOS
without copying them into the repository:

```sh
KDU_HOME=/path/to/kakadu-8.4.1 INCLUDE_LOSSY=1 \
  sh tools/bench_compare.sh bench-rgb-2048.tif
```

For the standard macOS package, use `KDU_HOME=/Library/Kakadu/8.4.1`.

Run the bounded BMP adapter gate (z2000 roundtrip, OpenJPEG/Grok decode, and
batch dispatch) with paths to locally installed reference tools when needed:

```powershell
.\tools\interop_bmp.ps1 -Magick magick `
  -OpenJpeg C:\tools\openjpeg\bin\opj_decompress.exe `
  -Grok C:\tools\grok\bin\grk_decompress.exe
```

Run the corresponding PNG matrix, including packed/palette/alpha and 8/16-bit
fixtures:

```powershell
.\tools\interop_png.ps1 -Magick magick `
  -OpenJpeg C:\tools\openjpeg\bin\opj_decompress.exe `
  -Grok C:\tools\grok\bin\grk_decompress.exe
```

Run the baseline JPEG matrix, including grayscale, 4:4:4/4:2:2/4:2:0,
restart markers, and lossless JP2 decode through OpenJPEG/Grok:

```powershell
.\tools\interop_jpeg.ps1 -Magick magick `
  -OpenJpeg C:\tools\openjpeg\bin\opj_decompress.exe `
  -Grok C:\tools\grok\bin\grk_decompress.exe
```

## Project Direction

Near term: keep both engineering scorecards at 100/100 while maintaining the
completed sampled-component profiles, hardening release gates and
interoperability, and improving performance inside the documented profile
envelope. The score is for that bounded envelope, not a claim that every Part 1
or JPX profile is implemented.

Full codec target: broaden JPEG2000 Part 1 support across tiles, packet orders,
profiles, quantization, code-block styles, and foreign decode surfaces.

Later conversion-tool target: broaden the bounded DNG/OpenEXR front ends,
add display conversion for the preserved extended YCC,
CIELab, and CMYK spaces; extend EXIF/IPTC/XMP ingestion beyond the bounded JPEG
profile and restore mapped metadata on JP2 output conversion; and evaluate
component depths above 16 bits where the source format and JPEG2000 profile
support them cleanly.
