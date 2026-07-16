# API Notes

z2000 is not yet a stable library. This document describes the current internal
APIs and CLI surface so future changes have a map.

## CLI

Build:

```sh
zig build
zig build test
```

The binary installs as both `z2000` and the `z2k` alias; conversions accept
the extension-inferred shorthand (`z2k input.tif output.jp2`). The custom
grayscale codec:

```sh
z2000 encode input.pgm output.z2000 --wavelet 5-3 --levels 3 --quant 1
z2000 decode output.z2000 reconstructed.pgm
```

TIFF and JP2 conversion:

```sh
zig build run -- --version
zig build run -- tiff-info input.tif
zig build run -- dng-info input.dng
zig build run -- tiff-to-jp2 input.tif output.jp2 [options]
zig build run -- jp2-info output.jp2
zig build run -- jp2-stats output.jp2
zig build run -- decode-temp-jp2 output.jp2 reconstructed.tif [--threads N] [--convert-to-srgb]
zig build run -- *.tif .jp2 [tiff-to-jp2 options]
zig build run -- *.jp2 .tif [jp2-to-tiff options]
```

`--version` (or `-V`) prints the generated SemVer application version including
its Git-derived build number and revision. It does not describe the internal
legacy `.z2000` payload version or JPEG2000 marker/profile syntax.

The TIFF module exposes `read`/`parse` for tagged RGB, grayscale, or alpha
dispatch, plus strict `readRgb`/`parseRgb`, `readGray`/`parseGray`, and
`readAlpha`/`parseAlpha` adapters. `AlphaImage` carries chunky gray+alpha or
RGBA samples plus `color.AlphaMode`; `writeAlpha` emits exactly one final TIFF
`ExtraSamples` value 1/2. The public `tiff-to-jp2` dispatches all three image
families. The grayscale branch
normalizes WhiteIsZero, selects no MCT by default, and emits the bounded
single-tile reversible 5/3/RPCL/ISO-MQ profile. Explicit incompatible options
fail closed. The alpha branch normalizes only a WhiteIsZero gray plane and
preserves alpha samples verbatim. Gray+alpha selects no MCT; RGBA selects RCT
by default, transforming only RGB while alpha receives the ordinary unsigned
DC level shift. Explicit `--mct none` keeps all four components independent.
`decode-temp-jp2` dispatches one- through four-component bounded JP2 output to
the matching TIFF writer; a supported one-component `pclr`/`cmap` stream is
expanded to RGB first.

The shorthand also has a non-recursive batch form. A first argument whose
filename contains `*` or `?` is expanded internally within its concrete parent
directory, and the second argument must be a bare target extension such as
`.jp2` or `.tif`. Matching is ASCII case-insensitive, results are sorted before
conversion, and all remaining options are applied to every file. Quoting the
pattern is unnecessary: z2000 accepts both an intact wildcard and the explicit
input list produced by shells that expand globs themselves. Empty matches,
wildcard parent directories, and two inputs mapping to one output fail before
any conversion; ordinary per-file errors stop the batch. Existing targets
follow the same overwrite behavior as single-file conversion.

Important `tiff-to-jp2` options:

- `--levels N` or `--resolutions N`
- `--tile W,H`
- `--progression RPCL|LRCP|RLCP|PCRL|CPRL`
- `--poc "RSpoc,CSpoc,LYEpoc,REpoc,CEpoc,ORDER;..."`
- `--poc-location main|tile`
- `--precincts "[256,256],[128,128]"`
- `--block N`
- `--layers N`
- `--rates R1,R2,...`
- `--mct rct|ict|none`
- `--transform 5-3|9-7`
- `--qstyle none|scalar-derived|scalar-expounded`
- `--tile-parts none|R|L|C|P`
- `--sop`, `--eph`, `--ppm`, `--ppt`, `--tlm`
- `--t1-backend iso-mq|legacy-mq`
- `--bypass`
- `--threads N`
- `--debug-temp-sidecar`
- `--timings`

Supported public JP2 profiles are still narrow:

- lossless RGB: `--mct rct --transform 5-3 --qstyle none`
- irreversible RGB: `--mct ict --transform 9-7` with scalar-expounded or
  scalar-derived quantization; bounded multi-tile irreversible RGB uses
  origin-aware 9/7 lifting, including odd tile origins, and global rate targets
- reversible component-independent RGB: `--mct none --transform 5-3 --qstyle none`
- reversible grayscale: one component, single tile, `--mct none --transform
  5-3 --qstyle none --progression RPCL`, in-band headers, PLT, and optional
  `R` resolution tile-parts/TLM/SOP/EPH
- reversible gray+alpha: two components with one final Typ 1/2 alpha channel,
  `--mct none --transform 5-3 --qstyle none --progression RPCL`
- reversible RGBA: four components with one final Typ 1/2 alpha channel;
  `--mct rct` transforms only RGB and is the CLI default, while `--mct none`
  keeps all four components independent; ICT remains fail-closed
- all five Part 1 progression orders on the documented single-tile path;
  multi-layer LRCP and position-major PCRL/CPRL use one tile-part because their
  streams cannot be divided per resolution
- checked main- or first-tile-part-header POC schedules on single- and multi-tile grids with one
  tile-part per tile, plus `R` parts when each resolution is contiguous, `L`
  parts when every quality layer is contiguous, and `C` parts when each RGB
  component is contiguous; `P` parts require the canonical PCRL position
  sequence while allowing packet reordering inside each position. The writer
  emits the requested order independently for each tile and strict decode
  appends tile-local records after inherited main-header records before
  normalizing each catalog to RPCL. `--poc-location tile` emits the marker in
  `TPsot=0`, updates `Psot` and TLM, and is not combined with PPM/PPT
- a bounded multi-tile lossless envelope: RCT/5-3, one or more quality layers
  for all five progression orders, deterministic row-major encode, reordered
  foreign tile decode, global cross-tile PCRD, and PLT-backed `R`/RPCL,
  `L`/LRCP, `C`/CPRL, and `P`/PCRL tile-part divisions; plus the
  implemented CAUSAL/SEGMARK/terminated resilience styles, reference-grid
  precinct/code-block/tag-tree partitions, and origin-aware reversible 5/3 lifting
- 8/16-bit chunky RGB TIFF input, with optional ICC tag preservation
- `--bypass` for the ISO-MQ backend, including terminated raw/MQ codeword
  segments and packet-header segment length accounting
- all six Part 1 code-block style bits in the documented ISO-MQ envelope,
  including BYPASS, RESET, TERMALL, vertical-causal, predictable termination,
  segmentation symbols, and their tested combinations
- tile-part packed packet headers via `--ppt` for RPCL with optional SOP/EPH:
  single-tile streams use one part or `R` resolution parts, and multi-tile
  streams require `R` parts; PLT measures SOD-resident SOP plus packet bodies,
  while PPT carries T2 headers plus EPH in one ordered stream per tile
- main-header packed packet headers via `--ppm` for RPCL with `R` resolution
  parts and optional SOP/EPH, including multi-tile streams; one checked
  `Nppm/Ippm` group maps to each codestream-order tile-part and drives a
  tile-local strict T2 packed-header state. PPM output omits redundant PLT and
  derives SOD body spans from decoded packet headers

Unsupported combinations still fail closed. Examples include tile-part
division/progression mismatches, JPX features, unsupported component layouts,
and profile mixes outside the bounded envelope. In
multi-tile mode, BYPASS without TERMALL and non-empty PLT-less multipart tiles
without PPM-backed RPCL/`R` derivation also remain unsupported. PPM/PPT are
mutually exclusive and multi-tile PPT
additionally rejects non-`R` layouts.
SOP is enabled by default for the current narrow profile. EPH is available via `--eph`; current OpenJPEG/Grok
smoke tests cover the common no-EPH and archival EPH paths, while
valid2000/jpylyzer-style validators remain diagnostic gates rather than
absolute sources of truth.

Future conversion-surface goals are deliberately not part of the current CLI
contract yet: JPEG/PNG/BMP input, RAW/DNG conversion, OpenEXR/HDR handling,
display conversion for preserved e-sRGB/e-sYCC/CIELab/CMYK samples,
EXIF/IPTC/XMP metadata, and component precision above 16 bits. Each should get
an explicit option, fail-closed parser policy, and interop fixture before
becoming public.

## `src/codestream.zig`

Primary public types:

- `CodestreamError`
- `ProgressionOrder`
- `PocProgression`
- `PocRecord`
- `PrecinctSize`
- `MultipleComponentTransform`
- `WaveletTransform`
- `QuantizationStyle`
- `LosslessOptions`
- `EncodeTimings`
- `DecodeTimings`
- `DecodeOptions`
- `TemporaryStats`
- `ComponentStats`
- `QualityLayerStats`
- `EbcotSegmentStats`
- `StrictPacketBlock`
- `StrictPacketBlockCatalog`

Primary public functions:

- `encodeLosslessSkeleton(allocator, rgb, requested_levels)`
- `encodeLosslessWithOptions(allocator, rgb, options)`
- `encodeLosslessWithOptionsProfiled(allocator, rgb, options, timings)`
- `encodeLosslessPlanarWithOptions(allocator, planes, options)` — bounded
  1..4-component layouts over `color.SamplePlanes`; reversible RGBA may use
  RCT over planes 0..2 while plane 3 remains independent. Mixed unsigned
  8/16-bit planes are supported for single-tile RPCL, reversible 5/3, no-MCT
  encoding and emit component-specific SIZ/QCC state
- `jp2.wrapPlanarCodestream(allocator, planes, icc, bytes)` — wraps bounded
  one-/three-component planar streams; mixed precision emits variable-BPC
  `ihdr` plus `BPCC`
- `jp2.AlphaMode` and
  `jp2.wrapPlanarAlphaCodestream(allocator, planes, alpha_mode, icc, bytes)` —
  bounded gray+alpha/RGBA JP2 wrapping for 2/4-component reversible streams;
  alpha is the final plane and is signalled explicitly through `cdef`
- `decodeLosslessPlanar(allocator, bytes)` /
  `decodeLosslessPlanarWithOptions(allocator, bytes, options)` — strict
  decode of bounded reversible 5/3 streams with SIZ Csiz 1..4, including
  single-tile no-MCT layouts, four-component RGB-triplet RCT, and bounded mixed unsigned
  8/16-bit no-MCT streams. Mixed output uses `SamplePlanes.bit_depth == 0` and
  exposes each precision through `component_bit_depths`/
  `componentBitDepth(component)`. Bounded subsampled no-MCT streams expose
  variable plane shapes through `component_widths`, `component_heights`, and
  `componentDimensions(component)`
- `encodeLosslessSampledPlanarWithOptions(allocator, planes, sampling, options)`
  — sampled reversible encode: per-component dimensions + `ComponentSampling`
  (XRsiz/YRsiz), RPCL, one or more untargeted quality layers, and reversible
  5/3. Single- and multi-tile output support inline headers with or without
  PLT, PPT with body-length PLT, or main-header PPM without PLT, with one
  tile-part per tile. `LosslessOptions.plt` defaults to true. Each
  tile-component is encoded independently and its packet streams are merged
  into canonical sampled RPCL order by default; complete POC schedules may
  compose LRCP, RLCP, RPCL, PCRL, and CPRL intervals. Absolute SIZ image and
  tile-partition origins use `LosslessOptions.image_origin_x/y` and
  `tile_origin_x/y`; these fields remain fail-closed on non-sampled encoders
- `decodeLosslessPlanarUpsampled(allocator, bytes)` /
  `decodeLosslessPlanarUpsampledWithOptions(allocator, bytes, options)` /
  `decodeLosslessPlanarUpsampledWithOptionsProfiled(...)` — decodes the same
  bounded planar profile and expands every component to the full SIZ reference
  grid by nearest-neighbour replication anchored to absolute image origin;
  no colour transform is implied
- `decodeLosslessPlanarWithOptionsProfiled(allocator, bytes, options, timings)`
  — native-size planar decode with the same timing breakdown as the upsampled
  entry point
- `color.interleaveRgb(allocator, planes)` — checked conversion of three
  equal-precision, full-resolution planes to `RgbImage`; callers remain
  responsible for establishing RGB semantics from the container
- `color.syccToSrgb(allocator, planes, sampling)` — explicit unsigned 8/16-bit
  sYCC 4:4:4, 4:2:2, or 4:2:0 native-plane conversion with checked dimensions,
  chroma-grid registration, range, and clipping; an odd image origin uses the
  pinned OpenJPEG edge phase without changing the native planes
- `color.sycc444ToSrgb(allocator, planes)` — full-resolution convenience
  entry point delegating to `syccToSrgb`
- `jp2.wrapPlanarColorCodestream(allocator, planes, color_space, codestream)` —
  emits full-resolution native planes with explicit CMYK (12),
  default-parameter CIELab (14), e-sRGB (20), or e-sYCC (24) signalling; it
  preserves samples and does not perform display conversion
- `icc.convertRgbToSrgb(allocator, input, profile_bytes)` — converts an
  unsigned 8/16-bit full-resolution RGB image through a bounded ICC v2/v4
  matrix/TRC PCSXYZ profile to an owned sRGB raster; source pixels/profile stay
  untouched and malformed, LUT, non-RGB, or non-PCSXYZ profiles fail closed
- `decodeLosslessTemporary(allocator, bytes)`
- `decodeLosslessTemporaryWithOptions(allocator, bytes, options)`
- `analyzeLosslessTemporary(bytes)`
- `hasMarker(bytes, marker)`
- `markerValue(name)`
- `firstSotPsot(bytes)`
- `firstTlmPtlm(bytes)`
- `readStrictPacketCatalog(allocator, bytes)`
- `auditStrictPacketHeaders(allocator, bytes)`
- `readStrictPacketBlockCatalog(allocator, bytes)`

Notes:

- `EncodeTimings.t1_pass_stats` accounts for MQ/RAW significance,
  refinement, and cleanup passes during measured single-thread encode. The
  CLI prints pass, symbol, and CPU-time totals under `--timings`; parallel
  encode leaves this diagnostic profile empty to avoid shared counters in
  worker hot paths.
- `encodeLosslessWithOptions` writes JPEG2000 markers with strict packet
  payloads in `SOD`. Despite the historical name, it now covers the reversible
  RCT/5-3 path, reversible `mct none`, the irreversible ICT/9-7 scalar
  quantization path, all five progression orders on the documented single-tile
  path, and the v1 bounded multi-tile lossless envelope.
- The latest private payload is BP8 and is emitted only when
  `emit_temporary_payload_sidecar` / `--debug-temp-sidecar` is enabled.
- `decodeLosslessTemporary*` decodes normal no-sidecar codestreams by
  reconstructing T2 block payloads from strict `SOD` packets and inferring
  continuous MQ/T1 pass metadata from the payload. The strict path covers
  z2000-produced RCT/5-3, ICT/9-7, progression-order, quality-layer, and v1
  multi-tile profiles, plus selected foreign OpenJPEG/Grok/Kakadu streams where
  packet spans can be derived, including the current PLT-less single-tile
  lossless matrix. Reference-grid-aware PLT-less multi-tile streams are also
  covered for explicit and default precincts, including an OpenJPEG/Grok/Kakadu smoke where Kakadu orders
  tile-parts as `0,1,3,2`.
  Debug BP8 sidecar files are still accepted as an oracle/compat path for the
  reversible profile.
- `readStrictPacketBlockCatalog` reconstructs per-component code-block packet
  metadata and owned payload views from strict `SOD`/PLT/T2 state without
  requiring private BP8 `COM` payloads.
- `readStrictPacketCatalog` also covers sampled multi-tile streams by joining
  the independently validated tile-local catalogs used by production decode;
  returned byte offsets address one normalized owned packet buffer.
- Strict decode accepts checked main-header and first-tile-part-header `POC` schedules on single- and
  multi-tile grids with one part per tile or compatible `R`/`L`/`C`/`P` parts,
  composes overlapping progression intervals without duplicate packets, and
  normalizes the resulting block catalog back to its internal RPCL grouping.
  `LosslessOptions.poc_records` writes the same bounded schedule independently
  for every tile. `LosslessOptions.poc_in_tile_header` selects `TPsot=0`
  instead of the default main-header placement; later tile-part POC markers
  fail closed.
- `DecodeTimings` reports the strict decode split for metadata, packet catalog,
  T1 block payload, inverse DWT, and inverse MCT. The packet catalog timing is
  further split into SOD/PLT scan, packet-header assembly, and final block
  catalog materialization; strict block-payload timing also includes worker
  balance counters for max/average job wall time, decoded block count, and
  payload bytes. T1/MQ pass and branch counters are collected only for timed
  decodes, keeping the normal strict decode hot path free of profiling writes.
- Encode-side RPCL catalog construction uses a deterministic cost-ordered
  queue across Y/Cb/Cr code-blocks when `threads > 3`; worker-local bitplane
  and EBCOT scratch buffers are reused while packet emission still reads stable
  per-component catalog indexes.
- Strict packet catalog parsing validates SOT/TLM/PLT marker accounting,
  ordered multi-segment TLM/PLT indexes, SOP/EPH marker policy, packet-header
  marker stuffing, and terminal `0xff` packet-header padding. It also has a
  PLT-less catalog branch that derives packet spans from packet headers; the
  current foreign-stream gate covers OpenJPEG/Grok/Kakadu default lossless
  files, OpenJPEG/Grok multi-layer lossless ladders, and explicit/default-
  precinct PLT-less multi-tile smokes from OpenJPEG/Grok/Kakadu.

## `src/jp2.zig`

Primary public types:

- `Jp2Error`
- `Info`
- `Palette`

`Info.bits_per_component` contains the common precision for uniform files and
is zero for mixed `BPCC` layouts. In the latter case
`Info.component_bit_depths[0..Info.components]` carries the unsigned 8/16-bit
precision of every codestream component; `componentBitDepth(index)` provides a
checked lookup. The strict planar decoder reconstructs matching single-tile
RPCL, reversible 5/3, no-MCT codestreams with per-component QCD/QCC state.
The legacy RGB/TIFF API remains uniform-depth; mixed multi-tile, MCT, 9/7, and
quantized profiles remain fail-closed.

`Info.component_xrsiz` and `Info.component_yrsiz` expose each codestream
component's SIZ sampling factors; `componentSampling(index)` returns the pair.
`Info.image_origin_x/y` and `Info.tile_origin_x/y` retain the independent SIZ
image and tile-partition origins for container/tool-layer registration.
Metadata parsing accepts nonzero factors, while normal JP2 wrapping still
requires unit sampling. Strict planar decode supports RPCL, reversible 5/3,
no-MCT subsampling with inline, PPT, or PPM packet headers and all SOP/EPH
combinations; PLT is optional where the layout permits it. It merges unequal
component precinct grids in reference-grid RPCL order and uses component-local
sampled bounds, subbands, code-block catalogs, T1 planes, and origin-aware
inverse DWT. Image and tile-partition origins are retained independently in
single- and multi-tile component plans; absolute tile rectangles are translated
into native-size image-local output planes per component. PPM combined with sampled
POC and MCT over subsampled planes remain fail-closed. The explicit
`decodeLosslessPlanarUpsampled` boundary expands native planes using absolute
reference-grid registration; `decode-temp-jp2` interleaves them only for a
bounded three-component sRGB JP2 wrapper. `Info.color_space` preserves the
selected grayscale, sRGB, sYCC, CMYK, default-parameter CIELab, e-sRGB,
e-sYCC, or restricted-ICC interpretation. For sYCC,
`decode-temp-jp2` converts unsigned uniform 8/16-bit 4:4:4, 4:2:2, and 4:2:0
native planes directly through `color.syccToSrgb`. For sampled input with an
odd `XOsiz/YOsiz`, missing leading chroma positions use code zero and 4:2:0
retains OpenJPEG's two-row edge phase. Invalid component geometry remains
fail-closed.
CMYK, CIELab, e-sRGB, and e-sYCC remain native planar interpretations: strict
codestream decode is plane-exact, while `decode-temp-jp2` rejects them until a
target-format conversion/mapping is explicit. Sampled e-sYCC preserves the
same bounded 4:4:4/4:2:2/4:2:0 geometry as sYCC without applying the sYCC
matrix. CIELab currently accepts only the standard default encoding (no EP
fields); partial or non-default parameter blocks fail closed.
Explicit POC in the main or first
tile-part header may compose LRCP, RLCP, RPCL, PCRL, and CPRL intervals when
the schedule covers every component-local packet exactly once. Sampled encode
covers single- and multi-tile RPCL with inline
PLT/PLT-less, PPT, or PPM headers, all with SOP/EPH framing and one or more
untargeted layers. Mixed-precision sampled multi-tile output fails closed.

Primary public functions:

- `encodeLosslessGrayWithOptions(allocator, input, options)`
- `decodeLosslessGray(allocator, codestream)`
- `decodeLosslessGrayWithOptions(allocator, codestream, options)`
- `decodeLosslessGrayWithOptionsProfiled(allocator, codestream, options, timings)`
- `wrapRgbCodestream(allocator, input, codestream)`
- `wrapGrayCodestream(allocator, input, codestream)`
- `wrapPlanarCodestream(allocator, planes, icc, codestream)`
- `wrapPlanarAlphaCodestream(allocator, planes, alpha_mode, icc, codestream)`
- `wrapPaletteCodestream(allocator, indexed, palette, codestream)`
- `parseInfo(bytes)`
- `extractCodestream(bytes)`
- `extractIccProfile(allocator, bytes)`
- `extractPalette(allocator, bytes)`

The supported box profile is intentionally narrow: signature box first, `ftyp`
second with `jp2 ` compatibility, a basic `jp2h` containing first `ihdr` and
enumerated CMYK (12), default-parameter CIELab (14), sRGB (16), grayscale (17),
bounded sYCC (18), e-sRGB (20), or bounded e-sYCC (24) `colr`, and one
contiguous `jp2c` codestream. The reader accepts bounded unsigned 8-bit and
16-bit one- through four-component metadata. A variable-BPC `ihdr` plus `BPCC` may describe a
bounded mixture of unsigned 8/16-bit component precisions and is checked
component-by-component against SIZ. Two additional bounded extensions are a
palette layout with
one index component, three uniform unsigned 8/16-bit `pclr` columns, and
explicit `cmap` records to sRGB output channels; and 2/4-component
gray+alpha/RGBA layouts whose final plane has complete Typ 1/2, Asoc 0 `cdef`
semantics. `Info.alpha_mode` preserves whether that plane is unassociated or
associated. Signed/mixed palettes, arbitrary auxiliary-channel mappings, and
JPX-only features fail closed. The writers require non-empty
dimensions, 8/16 bit depth, matching sample counts, codestream/JP2 shape
agreement, and no MCT for one component. `wrapGrayCodestream` accepts only
BlackIsZero-normalized samples; WhiteIsZero must be explicitly inverted before
codestream encoding. `Palette.expand` validates every index before copying an
interleaved RGB triplet, and reports `PaletteIndexOutOfRange` on malformed data.
`wrapPlanarAlphaCodestream` requires alpha to be the final plane. Gray+alpha
must use no MCT; RGBA accepts either no MCT or reversible MCT=1, interpreted as
RCT over RGB only with alpha independent. TIFF ExtraSamples input/output is
connected to both profiles.

TIFF tag 34675 is stored as owned RGB, grayscale, or alpha image metadata;
wrappers write a JP2 restricted ICC `colr` box when present, `parseInfo`
reports ICC presence and profile byte count, and `extractIccProfile` returns an
owned copy of the profile payload. Default decode treats profiles as opaque and
preserves them without transforming samples. `decode-temp-jp2
--convert-to-srgb` opts into the separate `src/icc.zig` matrix/TRC converter
for full-resolution three-component restricted-ICC JP2 input. It supports ICC
v2/v4 RGB input, display, or colour-space profiles with PCSXYZ matrix columns
and curve/parametric TRCs; LUT profiles and broader colour management remain
fail-closed. Successful conversion emits sRGB samples and does not attach the
source profile to the output TIFF.

## `src/t2.zig`

Primary public types:

- `PacketHeaderWriter`
- `PacketHeaderReader`
- `TagTreeEncoder`
- `TagTreeDecoder`
- `PacketBlock`
- `PacketBlockLocation`
- `CodeBlockGrid`
- `CodeBlockPacketState`
- `LayerTruncation`
- `LayerPacketBlock`
- `EncodedLayerBlock`
- `PrecinctPacketWriterState`
- `PrecinctPacketReaderState`

Primary public functions:

- `layerContribution(previous, current)`
- `packetBlockForLayer(location, nominal_bitplanes, encoded_bitplanes, previous, current)`
- `layerPayloadSlice(bytes, previous, current)`
- `bandResolutionIndex(levels, band)`
- `codeBlockPacketRect(block)`
- `codeBlockIntersectsRpclPacket(plan, packet, levels, bands, block)`
- `collectRpclCodeBlockIndexes(allocator, plan, packet, levels, bands, blocks)`
- `layerPacketBlockFor(encoded, layer_index)`
- `layerPacketBlocksForIndexes(allocator, encoded_blocks, indexes, layer_index)`
- `appendRpclPacketForIndexes(state, allocator, out, packet, expected_resolution, expected_component, expected_precinct, encoded_blocks, indexes)`
- `appendPrecinctLayerPacket(...)`
- `readPrecinctLayerPacket(...)`
- `zeroBitPlaneCount(nominal_bitplanes, encoded_bitplanes)`

Usage pattern for the new RPCL bridge:

1. Build an array of `EncodedLayerBlock` for one precinct in tag-tree leaf order.
2. Initialize `PrecinctPacketWriterState.initForEncodedBlocks`.
3. Use `collectRpclCodeBlockIndexes` to select packet-relevant code-blocks.
4. Use `appendRpclPacketForIndexes` for each layer packet.
5. Keep the writer state alive across layers for the same precinct.

The RPCL writer/reader state is intentionally strict: it tracks the configured
layer count, next layer, next sequence, precinct coordinates, tag-tree lows and
known-node state, `numlenbits`, and cumulative pass/byte deltas.
`readRpclPacket` consumes exactly one packet slice and rejects trailing bytes.

## `src/packet_plan.zig`

Primary public types:

- `Precinct`
- `Rect`
- `Resolution`
- `Plan`
- `Packet`
- `RpclIterator`
- `LrcpIterator`
- `RlcpIterator`

Primary public functions:

- `rpclSingleTile(width, height, levels, components, layers, precincts)`
- `rpclPacketAt(plan, components, layers, sequence)`
- `precinctRect(plan, resolution_index, precinct_index)`
- `rectsIntersect(a, b)`

`RpclIterator` emits packets in resolution, precinct, component, layer order.
The non-RPCL progression orders are implemented as stream-order permutations
over the same packet body model: LRCP, RLCP, PCRL, and CPRL build deterministic
packet sequences for the writer and strict reader, then catalog entries are
reordered back to the internal RPCL grouping used by downstream reconstruction.
Future progression/tile-part combinations must still stay fail-closed until
their packet writer, strict reader, packet-state lifetime, corruption tests, and
interop gates exist.

## `src/ebcot.zig`

Primary public types:

- `PassKind`
- `Context`
- `SymbolKind`
- `Symbol`
- `Pass`
- `CodeBlockPassPayload`
- `EncodedBlock`
- `CodeBlockSegment`
- `CodeBlockStyle`
- `EncodedBlockView`
- `BlockScratch`
- `DirectBlockScratch`

Primary public functions:

- `encodeBlock(allocator, plane, stride, rect)`
- `encodeBlockScratch(scratch, plane, stride, rect)`
- `encodeSymbolsMq(allocator, symbols)`
- `decodeSymbolBitsMq(allocator, bytes, symbol_count, symbols)`
- `encodeCodeBlockSegment(allocator, plane, stride, rect)`
- `encodeCodeBlockSegmentContinuous(allocator, plane, stride, rect)`
- `encodeCodeBlockSegmentDirect(allocator, plane, stride, rect)`
- `encodeCodeBlockSegmentDirectScratch(scratch, plane, stride, rect)`
- `encodeBlockSymbolsSegment(allocator, block)`
- `decodeCodeBlockSegmentBits(allocator, segment, symbols)`
- `decodeCodeBlockSegmentCoefficients(allocator, segment, width, height)`
- `decodeCodeBlockPayloadContinuousInferred(allocator, bitplanes, pass_count, bytes, width, height)`
- `decodeCodeBlockSegmentCoefficientsPartial(allocator, segment, width, height)`
- `decodeCodeBlockSegmentCoefficientsContinuousPartial(allocator, segment, width, height)`

`CodeBlockSegment` carries MQ bytes plus per-pass byte offsets and cumulative
truncation points. It is the bridge from T1 work into T2 packet payloads.
`decodeCodeBlockSegmentCoefficients` reconstructs a single current-model
code-block from those MQ pass payloads without using the old private bitplane
payload; the partial variant decodes complete coding-pass prefixes from quality
layer truncation points for strict ISO packet validation.
The current codestream path uses continuous MQ code-block segments for quality
layers. The symbol oracle and direct MQ path remain useful test and comparison
surfaces, and share SIMD-aware block-stat scanning so bitplane and non-zero
metadata stay aligned across portable, AVX2-width, and NEON-width builds.

The direct ISO-MQ path is the default T1 backend. Cleanup run mode, directional
sign prediction contexts, refined magnitude-refinement contexts, direct MQ
emission, BYPASS raw segments, and terminated codeword segment metadata are
covered by oracle tests. All six Part 1 code-block style bits and every style
byte `0x00..0x3f` are public on the documented ISO-MQ path: BYPASS, RESET,
TERMALL, vertical causal, predictable termination, segmentation symbols, and
their combinations carry segment/style metadata through strict T2/T1 decode.
Representative single- and multi-tile combinations are pixel-exact through
OpenJPEG, Grok, and Kakadu. The inferred continuous-payload helper remains a
narrow internal API and rejects TERMALL when pass byte lengths are unavailable;
the legacy MQ backend also keeps its separate fail-closed envelope.

## `src/rate_alloc.zig`

Primary public types:

- `Block`
- `PcrdBlock`
- `Truncation`

Primary public functions:

- `allocateEven(out, block)`
- `allocateFromCompressionRatios(out, block, rates)`
- `allocatePcrdPasses(allocator, blocks, layer_targets, out_passes)`

The allocator works on cumulative pass and byte targets. The legacy helpers
keep even and compression-ratio allocation available for tests, while the
current rate-driven path uses PCRD-style slope allocation over per-block
distortion metadata. The single-tile codestream layer charges measured packet
header overhead against non-final layer budgets, then T2 converts the chosen
cumulative points into per-layer deltas. Single- and multi-tile paths use one
global slope threshold across their active code-blocks; irreversible weights
remove the subband gain before applying the 9/7 synthesis norm. The
profile-matched `tools/pcrd_psnr_ladder.ps1` diagnostic and in-tree exact PLT
prefix regression guard future allocator changes.

Rate-targeted T1 uses
`encodeCodeBlockSegmentDirectIsoScratchWithStyleAndDistortions` to return the
normal ISO-MQ segment while filling one exact distortion delta per coding pass.
The public no-rate encoder remains compile-time specialized without distortion
bookkeeping. The symbol-based `passDistortions` helper remains the test oracle
and fallback for terminated or legacy paths.

## `src/subband.zig`

Primary public types:

- `Kind`
- `Rect`
- `Band`
- `CodeBlock`

Primary public functions:

- `makeBands(allocator, width, height, levels)`
- `makeCodeBlocks(allocator, bands, block_width, block_height)`

Subband rectangles are currently used both for temporary payload ordering and
for RPCL packet selection.

## Stability Notes

- Public module functions are still internal project APIs, not a committed
  external library contract.
- Error behavior should remain fail-closed for unsupported JPEG2000 profiles.
- Existing tests are the best source of intended behavior for edge cases.
- Interop and benchmark updates should report z2000, Grok, OpenJPEG, and Kakadu
  encode/decode time, output bytes, strict reader status, and roundtrip
  correctness for single-thread and multi-thread runs.
