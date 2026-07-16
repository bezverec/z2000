# Changelog

This file tracks notable project changes. The repository is still pre-release;
entries are grouped by development milestone rather than semantic version.

## Unreleased

### Bounded PNG Input Adapter

- Added isolated non-interlaced PNG input for every standard color type and
  legal 1/2/4/8/16-bit depth. Critical chunk ordering, unknown critical chunks,
  CRCs, palette/transparency bounds, exact zlib output/checksum, and filters
  None/Sub/Up/Average/Paeth are checked before sample expansion.
- `PLTE` and all three legal `tRNS` forms map onto existing grayscale, RGB,
  gray+alpha, and RGBA carriers. Packed inputs expand to 8 bits; 8/16-bit
  samples remain exact and PNG alpha stays unassociated.
- Added `png-to-jp2`, shorthand and unquoted batch dispatch, truncation and
  single-bit mutation sweeps, ten independent ImageMagick PNG/raw fixtures,
  pixel-exact roundtrips for the full fixture matrix, and OpenJPEG/Grok `AE=0`
  decode gates for 8/16-bit RGB. Adam7, APNG, and unmapped color profiles stay
  fail-closed.

### Bounded BMP Input Adapter

- Added isolated Windows BMP input for the 14-byte file header plus 40-byte
  `BITMAPINFOHEADER`, `BI_RGB`, one plane, and 24/32-bit BGR pixels. Both
  bottom-up and top-down row order and DWORD padding are decoded into owned
  8-bit RGB samples; the reserved 32-bit byte is deliberately not alpha.
- Added `bmp-to-jp2`, extension-inferred `z2k input.bmp output.jp2`, and
  unquoted non-recursive `z2k *.bmp .jp2` batch dispatch through the existing
  encode path and options.
- Header/raster sizes and arithmetic fail closed. Focused malformed, full
  truncation, and single-bit mutation sweeps accompany an independent
  ImageMagick BMP3/raw oracle and a pixel-exact BMP -> JP2 -> TIFF live gate.

### Extended Colour-Space Signalling And Preservation

- Added explicit JP2 metadata for CMYK (EnumCS 12), default-parameter CIELab
  (14), e-sRGB (20), and e-sYCC (24). `ColorSpace` reports their semantics and
  `wrapPlanarColorCodestream` emits full-resolution native-plane wrappers.
- Added plane-exact 8-bit encode/wrap/parse/decode roundtrips for all four
  spaces and a sampled odd-origin e-sYCC regression using an independent
  Kakadu codestream. An independent Grok 20.3.4 EnumCS 12 fixture additionally
  matches every native CMYK sample from its ImageMagick source. The colour
  boundary never mutates native samples.
- Kept conversion fail-closed: `decode-temp-jp2` rejects these spaces rather
  than treating three components as RGB or CMYK's fourth component as alpha.
  CIELab EP parameters are not yet interpreted; only the standardized default
  encoding with no EP fields is accepted.

### Unaligned-Origin Sampled sYCC

- Extended direct unsigned 8/16-bit sYCC 4:2:2 and 4:2:0 conversion to odd
  image origins. Missing leading chroma positions use code zero, and 4:2:0
  preserves OpenJPEG's two-row left-edge phase; native decoded planes remain
  unchanged.
- Added a Kakadu 8.4.1 native 4:2:0 codestream with `XOsiz=5`, `YOsiz=3`; only
  its container colour-space enum is relabelled to sYCC. All 3,072 converted
  samples match an embedded OpenJPEG 2.5.4 reference TIFF, for single- and
  multi-tile decode, with focused 8/16-bit synthetic edge tests.
- Live `z2k` output matches the OpenJPEG reference with ImageMagick `AE=0`.
  Grok 20.3.4 retains this fixture as YCbCr rather than providing a converted
  RGB reference, so that producer/decoder caveat stays explicit.

### Non-Recursive Batch Conversion

- Added native shorthand batch dispatch for `z2k *.tif .jp2 [options]` and the
  reverse `z2k *.jp2 .tif [options]`. Quotes are not part of the syntax:
  z2000 expands intact `*`/`?` patterns itself and also accepts the explicit
  input list produced by shells such as Bash. Internal matching is ASCII
  case-insensitive and limited to filenames in one concrete directory.
- Batch planning is deterministic and happens before conversion. It rejects an
  empty match, wildcard directory segments, invalid target extensions, and
  output-name collisions. Per-file conversion reuses the ordinary command
  path and options; existing targets retain single-file overwrite behavior.
- Added focused matcher/planner tests plus a live multi-file TIFF-to-JP2 smoke.

### ICC Matrix/TRC RGB Conversion Boundary

- Added `src/icc.zig`, a bounded ICC v2/v4 RGB matrix/TRC parser and converter
  for unsigned 8/16-bit `RgbImage` samples. It accepts PCSXYZ input, display,
  and colour-space profiles with `rXYZ`/`gXYZ`/`bXYZ` plus `curveType` or
  `parametricCurveType` TRCs, converts through D50 PCSXYZ to sRGB, clips at the
  explicit tool boundary, and rejects malformed, LUT, non-RGB, and non-PCSXYZ
  profiles.
- Added opt-in `decode-temp-jp2 --convert-to-srgb`. Default JP2-to-TIFF
  behavior still preserves restricted ICC bytes and samples unchanged; the new
  flag requires a full-resolution three-component restricted-ICC JP2 and emits
  converted sRGB samples without copying the source profile to the TIFF.
- Embedded official eciRGB v2 ICC v2/v4 and CC0 Adobe RGB (1998)-compatible
  ICC v2/v4 fixtures. Their 8/16-bit conversion vectors match independent
  ImageMagick 7.1.2 / LittleCMS relative-colorimetric reference rasters within
  the documented quantization tolerance; fixture licenses and hashes are kept
  beside the profiles.

### Sampled sYCC Conversion Boundary

- Added direct unsigned 8/16-bit sYCC 4:2:2 and 4:2:0 native-plane conversion
  for chroma-grid-aligned image origins. The converter validates Cb/Cr geometry
  and avoids materializing three full-resolution intermediate planes.
- Embedded 7x5 Kakadu 8.4.1 sYCC fixtures with odd right/bottom dimensions;
  every converted RGB sample matches both OpenJPEG 2.5.4 and Grok 20.3.5.
  Unaligned image origins remain explicitly fail-closed.
- Exposed independent SIZ image and tile-partition origins through `jp2.Info`,
  added native planar decode profiling, and taught `jp2-info` to report origins.

### sYCC 4:4:4 Conversion Boundary

- Added explicit JP2 colour-space metadata for grayscale, sRGB, enumerated
  sYCC, and restricted ICC selection. `jp2-info` now reports the selected
  interpretation instead of leaving three-component samples ambiguous.
- Added checked unsigned 8/16-bit sYCC 4:4:4 to sRGB conversion at the
  JP2-to-TIFF boundary. Native codestream planes remain unchanged, and sampled
  sYCC conversion stays fail-closed pending a registration/interpolation gate.
- Embedded a Kakadu 8.4.1 sYCC fixture whose converted raster matches OpenJPEG
  2.5.4, plus clipping, precision, layout, and malformed chroma-sampling tests.

### Sampled Tile-Partition Origins

- Added explicit sampled-planar SIZ image and tile-partition origins through
  `LosslessOptions`. Component dimensions, tile cropping, packet geometry, DWT
  parity, strict multi-tile context, and JP2 tile counts now retain the two
  coordinate origins independently; other encode entry points stay fail-closed.
- Added malformed-grid gates plus an odd clipped 3x3 4:2:0 roundtrip with exact
  strict packet audit and 1/8-thread determinism.
- Embedded an independent Kakadu 8.4.1 fixture with `Sorigin={3,5}` and
  `Stile_origin={0,1}`. z2000 reconstructs its native planes exactly, while
  Kakadu reconstructs matching z2000 output byte-for-byte.

### Sampled Reordered POC

- Added one reference-grid scheduler for LRCP, RLCP, RPCL, PCRL, and CPRL over
  unequal component precinct grids. Sampled POC composition uses a stable
  component-local packet identity, rejects incomplete schedules, and drives
  both encode merge and strict decode without duplicating T1 payloads.
- Added main- and first-tile-part-header POC emission for single- and
  multi-tile sampled output, including `Psot`/TLM accounting, PPT, SOP/EPH,
  all five progression orders, odd 3x3 tile grids, and 1/8-thread determinism.
  PPM+POC remains fail-closed.
- Strict T2 now detects non-contiguous precinct revisits. Canonical streams keep
  the existing one-active-precinct fast path; reordered schedules preserve
  inclusion tag-tree, zero-bitplane tag-tree, and block state per precinct.
- Live single- and multi-tile 4:2:0 output for all five orders is accepted by
  OpenJPEG 2.5.4, Grok 20.3.6, and Kakadu 8.4.1. Kakadu reconstructs every
  native plane pixel-exactly. OpenJPEG and Grok both report success but their
  upsampled sampled+POC rasters disagree, recorded as an interop caveat rather
  than claimed pixel agreement.

### Sampled Multi-Tile Packet Layouts

- Generalized the planar tile front end to accept explicit component-grid tile
  coordinates and run reversible 5/3 with absolute-origin parity. The original
  single-tile entry point delegates to the same implementation.
- Added sampled multi-tile encode with one tile-part per reference tile. Every
  tile derives component-local bounds, DWT origins, precinct plans, T2 state,
  and output packet order from the absolute SIZ grid; one and three untargeted
  layers roundtrip native planes on aligned and odd-boundary grids.
- Reused the single-tile framing helpers for inline PLT/PLT-less, tile-local
  PPT with body-length PLT, and one checked PPM group per codestream-order tile
  part without PLT. Layout selection reuses each tile's merged RPCL stream and
  does not rebuild DWT, T1, or T2 artifacts.
- The full SOP/EPH matrix, malformed PPT/PPM lengths, tile-local SOP sequence,
  and 1/8-thread determinism are covered. Live odd-boundary 3x3, three-layer
  4:2:0 streams in all four layouts decode through OpenJPEG 2.5.4 and Grok
  20.3.6 to identical component rasters; Kakadu 8.4.1 reproduces all native
  planes pixel-exactly. Mixed precision, sampled MCT, and sampled 9/7 remain
  fail-closed.
- Extended `readStrictPacketCatalog` to aggregate the same validated tile-local
  sampled catalogs used by strict pixel decode. The layout matrix now requires
  identical packet identities, normalized offsets/lengths, and packet bytes
  across inline PLT/PLT-less, PPT, PPM, and every SOP/EPH combination.

### Sampled Encode Packet Layouts

- Added `LosslessOptions.plt`, defaulting to true, and opened PLT-less output
  for the bounded sampled single-tile encoder. `Psot` and optional TLM account
  for the shorter tile-part while strict decode derives packet spans from T2
  headers.
- Reused the common packed-header helpers to emit sampled PPT with body-length
  PLT and sampled main-header PPM without redundant PLT. Inline, PLT-less,
  PPT, and PPM now cover every SOP/EPH combination and one or more untargeted
  layers without a second packet-state model.
- The layout matrix reconstructs identical strict packet payloads, native
  planes, and byte-identical 1/8-thread output. Live three-layer 4:2:0 streams
  decoded through OpenJPEG 2.5.4 and Grok 20.3.6 with identical component
  outputs across layouts; Kakadu 8.4.1 returned all native planes pixel-exactly.

### Planning Sync After PRs #150-#157

- Reconciled the active documentation with the sampled-component campaign:
  PRs #150-#153 completed bounded sampled inline/PPT/PPM strict decode with
  SOP/EPH coverage, while PRs #154-#155 added single-tile sampled reversible
  encode with one or more untargeted quality layers.
- Recorded PRs #156-#157 as the current 5/3 performance baseline: an eight
  worker DWT cap followed by a persistent phase pool, both with byte-identical
  lossless output.
- Made `next_steps.md` the single active feature queue and archived the older
  overlapping feature plan. The next ISO slice is sampled encode packet-layout
  breadth, followed by sampled multi-tile encode and remaining origin/POC
  geometry.

### Performance

- Ported the 9/7 driver's persistent barrier thread pool to the reversible 5/3
  DWT (`wavelet_int.zig`), so both drivers share one design and the 5/3 phase
  no longer spawns fresh threads for each of its ten per-transform phases. The
  pool spawns `worker_count - 1` workers once and releases them per phase via a
  generation counter; the caller runs the final band. Band splits are
  unchanged, so lossless codestreams and decoded pixels stay byte-identical.
  Kept for a clean 2.8% lossless encode t16 improvement (inverse DWT stage
  ~27% faster) with no regression on decode or t1. See the second 2026-07-15
  `benchmarks.md` record.
- Capped the reversible 5/3 DWT phase at eight workers (`wavelet_int.zig`
  `max_dwt_workers` 32 -> 8), matching the 9/7 driver. The memory-bound DWT
  bands stop scaling past the eight physical cores on the x86 benchmark host,
  so the uncapped setting let the lossless inverse DWT regress at the full
  16-thread setting (17.3 ms) relative to eight threads (12.8 ms). Capping
  restored t16 to t8 and improved lossless decode t16 by 7.8% and encode t16 by
  6.1% with byte-identical codestreams and decoded pixels; T1 still receives
  the full caller thread count. See the 2026-07-15 `benchmarks.md` record.
- Removed `src/tmp_sl.zig`, an unreferenced hex-dump scaffold accidentally
  committed with the sampled quality-layer work.

### Sampled Reversible Encode (Single-Tile RPCL)

- New `codestream.encodeLosslessSampledPlanarWithOptions`: a planar no-MCT
  writer for 1..4 unsigned 8/16-bit components with explicit per-component
  dimensions and XRsiz/YRsiz subsampling. It encodes each component
  independently through the single-component scaffold at its own dimensions,
  then merges the per-component packet streams into the canonical sampled
  RPCL order (`packet_plan.sampledRpclPackets`); SIZ emits per-component
  XRsiz/YRsiz and a dedicated single-tile-part inline+PLT assembler carries
  the merged stream. Single-tile, inline headers, reversible 5/3, one or
  more untargeted quality layers (the merge indexes each component's stream
  at resolution offset + precinct * layers + layer).
- Verified: z2000 strict decode reproduces every native component plane
  across 2-, 3-, and 4-component 4:2:0/4:2:2/mixed layouts and 1/2/3 quality
  layers; the encoded
  stream decodes byte-identically to the trusted Kakadu 4:2:0 fixture
  through both z2000 (in-suite equivalence) and OpenJPEG 2.5.4 / Grok 20.3.6
  (out-of-band per-component PGX); cross-thread output is deterministic; and
  MCT, irreversible 9/7, non-RPCL orders, multi-layer, all-1 sampling, and
  dimension mismatches fail closed.
- This also supplies the independent-producer interop evidence the sampled
  packed-header decode work (PPT/PPM/SOP-EPH) was missing: our sampled
  encoder and Kakadu produce streams the reference decoders agree on.

### Sampled SOP/EPH Placement Coverage

- The strict decoder already handled SOP body frames and EPH header
  terminators on subsampled streams in all three header layouts; this
  slice proves it. The test repacker can now inject SOP/EPH while
  repacking (advertising the bits in COD Scod): inline layouts frame each
  packet as [SOP] header [EPH] body, packed layouts keep [SOP] body in the
  tile part with EPH terminating each packed header, and PLT entries under
  PPT count the SOP frame into the body length.
- Coverage matrix: single-tile and shifted-origin four-tile 4:2:0 fixtures
  x {inline, PPT, PPM} x {SOP+EPH, SOP-only, EPH-only} all decode
  plane-exact against the unframed originals, and a corrupted SOP sequence
  number fails closed in every placement.

### Sampled PPM Decode

- Subsampled streams now accept main-header PPM packed headers: the strict
  metadata gate and the per-tile-part reader drop their sampled PPM terms,
  and the sampled multi-tile driver forwards the collected PPM groups into
  the per-tile catalog reader. PPM combined with progression-order changes
  stays fail-closed (an explicit guard mirrors the non-sampled rule).
- The test repacker gained a `.ppm` placement mode: packet headers move
  into main-header PPM markers with one group per tile-part (via the
  encoder's own `ppm.buildMarkerPayloads` framing) and the tile-parts stay
  PLT-less, mirroring the encoder's PPM layout.
- Four 4:2:0 Kakadu fixtures (single- and four-tile, aligned and shifted
  origin) repack into PPM form and must decode plane-exact against their
  inline originals with matching audit counts; truncated PPM payloads and
  PPM+POC combinations fail closed.

### Sampled Multi-Tile PPT Decode

- The multi-tile per-tile-part reader now accepts PPT packed headers on
  subsampled streams: its packed-header branch already consumed the sampled
  sequence through the per-tile component-local stateful precinct groups, so
  the sampled+PPT term leaves that gate as well. Sampled PPM (and external
  packed headers generally) stay fail-closed.
- `collectStrictInlinePacketSpans` handles multi-tile streams: it walks the
  Stage B tile-part spans in stream order with lazily built per-tile
  sequences and stateful groups, reporting the same header/body spans and
  tile-part frames as the single-tile walk.
- The test repacker additionally emits a PLT carrying the packed-header
  body lengths, keeping Stage B span accounting on its PLT-backed path; the
  three four-tile 4:2:0 Kakadu fixtures (aligned, shifted origin, shifted
  origin with POC) repack into per-tile-part PPT form and must decode
  plane-exact against the inline originals with matching audit counts,
  failing closed on truncated packed headers.

### Sampled Single-Tile PPT Decode

- The strict single-tile reader now accepts PPT packed headers on subsampled
  streams: the packed-header branch already walked the canonical sampled
  RPCL sequence through the component-local stateful precinct groups, so the
  sampled+PPT rejection is removed for the single-tile path. Multi-tile
  sampled PPT and PPM (sampled or not beyond the existing envelope) stay
  fail-closed.
- New `collectStrictInlinePacketSpans` diagnostic reports per-packet
  header/body byte spans and tile-part frames for strict inline-header
  PLT-less single-tile streams (SOP/EPH-free); it is the splitting oracle
  the tests use to repack inline fixtures into PPT form for layouts the
  encoder cannot produce yet.
- Tests repack all four single-tile 4:2:0 Kakadu fixtures (multi-precinct,
  shifted origin, main-header POC, tile-header POC) into PPT and require
  plane-exact decode against the inline originals, matching audit counts,
  and fail-closed/differing behavior for corrupted or truncated packed
  headers. The repacked fixtures prove structure; an independent producer
  fixture remains the open interop evidence per the queue.

### Documentation Plan Consolidation

- Made `roadmap.md` the strategic source and `next_steps.md` the only ordered
  implementation queue. Added `docs/README.md` to describe document ownership
  and update rules.
- Replaced the checkpoint-heavy active optimization plan and scaffold-era
  architecture with concise current documents. Preserved the full architecture,
  optimization, SIMD, multi-tile, roadmap, and next-steps histories under
  `docs/archive/`.
- Clarified throughout that 100/100 applies to the explicitly bounded
  scorecards and is not a claim of complete JPEG2000 Part 1 or JPX coverage.

### Reference-Grid Sampled Output (F3b Slice 9)

- Added `decodeLosslessPlanarUpsampled` and its options/profiled variants.
  They expand native component planes by nearest-neighbour replication anchored
  to absolute SIZ `XOsiz/YOsiz` and `XRsiz/YRsiz`, without silently applying a
  colour transform.
- Added checked RGB interleaving for three equal-precision full-resolution
  planes. `decode-temp-jp2` now converts bounded sampled sRGB JP2 input to TIFF
  through that explicit boundary while preserving the native-plane API.
- Pinned zero-origin, shifted-origin, multi-tile, PLT-less, and canonical-POC
  cases against the existing independent Kakadu fixtures. Sampled packed
  headers, reordered POC, and sampled encode remain fail-closed.

### Canonical Sampled RPCL POC Decode (F3b Slice 8)

- Added sampled-component POC schedule validation over the canonical
  reference-grid RPCL sequence. Main-header and first-tile-part-header records
  may overlap, but their first visits must preserve packet-for-packet RPCL
  order and cover the complete stream.
- Added independent Kakadu 4:2:0 POC fixtures for main- and tile-header marker
  placement, PLT and PLT-less packet spans, and shifted-origin four-tile decode.
- Non-RPCL or reordered sampled schedules fail as `UnsupportedPayload`;
  incomplete schedules fail as `InvalidCodestream`. Packed sampled packet
  headers remain fail-closed pending an independent generator.

### Shifted-Origin Multi-Tile Subsampling Decode (F3b Slice 7)

- Carried SIZ `XOsiz/YOsiz` through strict metadata and rebuilt multi-tile
  grids from the original absolute reference coordinates instead of silently
  normalizing them to zero.
- Made sampled-plane and RGB tile assembly translate absolute tile/component
  rectangles back to image-local output coordinates while retaining absolute
  origins for packet planning and inverse 5/3 lifting.
- Added PLT-backed and PLT-less Kakadu 4:2:0 four-tile fixtures at
  `XOsiz/YOsiz=5/3`. Both audit 102 packets and 198 blocks and reconstruct the
  native 32x32/16x16/16x16 planes pixel-exactly. Distinct tile-partition
  origins remain fail-closed.

### Multi-Tile Component Subsampling Decode (F3b Slice 6)

- Extended the bounded RPCL/no-MCT/reversible-5/3 planar decoder across real
  tile grids. Each tile now derives aggregate packet counts from its sampled
  component plans and preserves independent inclusion, zero-bitplane, and
  `numlenbits` state while PLT-backed or open-ended inline packets are read.
- Corrected sampled RPCL ordering at non-top-left tile boundaries by clamping
  precinct reference positions to the tile origin before component ordering.
- Added independent Kakadu 4:2:0 four-tile fixtures with and without PLT. Both
  audit 36 packets and 86 blocks and reconstruct the native 32x32/16x16/16x16
  planes pixel-exactly. Packed headers, POC, shifted multi-tile origins, and
  subsampled encode remain fail-closed.

### Origin-Aware Subsampling Decode (F3b Slice 5)

- Single-tile strict metadata now builds packet plans from the actual SIZ tile
  rectangle instead of normalizing `XOsiz/YOsiz` to zero.
- Relaxed JP2 validation for matching nonzero image/tile origins while keeping
  a distinct tile-partition origin fail-closed.
- Added PLT-backed and PLT-less Kakadu 4:2:0 fixtures at `XOsiz/YOsiz=5/3`.
  Their clipped 3x3/5x5 precinct grids audit 60 packets and 139 blocks and
  reconstruct all 32x32/16x16/16x16 samples exactly.

### Component-Local PLT-Less T2 State (F3b Slice 4)

- Reworked the strict open-ended packet reader to own separate precinct-state
  slots over each component's sampled geometry instead of sharing the
  component-zero block index.
- Inclusion and zero-bitplane tag trees plus `numlenbits` now persist correctly
  while PLT-less packet spans are derived from unequal component precinct
  grids.
- Added a second independent Kakadu 32x32/16x16/16x16 4:2:0 fixture without
  PLT. Both PLT-backed and PLT-less streams audit 30 packets and 85 blocks and
  reconstruct every native-plane sample exactly.

### Reference-Grid Subsampling Packets (F3b Slice 3)

- Added an RPCL sequence builder that projects component-local precincts by
  `XRsiz/YRsiz` onto the image reference grid and merges unequal grids in ISO
  resolution-position-component-layer order.
- Strict metadata now derives aggregate per-resolution packet counts from all
  component plans, and strict T2/T1 reconstruction consumes those local
  precinct indexes without a shared-grid scan.
- Added a checked-in Kakadu 32x32/16x16/16x16 4:2:0 JP2 with 8x8 precincts and
  a pixel-exact 30-packet decode gate. SIZ/PLT topology mismatches fail as
  `InvalidCodestream`; PLT-less state followed in Slice 4 and nonzero origins
  in Slice 5, while packed-header, POC, and multi-tile profiles remain
  fail-closed.

### Component-Local Subsampling Decode (F3b Slice 2)

- Added component-local sampled bounds, subbands, code-block partitions, RPCL
  selectors, strict block-catalog dimensions, and origin-aware inverse 5/3
  reconstruction for bounded subsampled streams.
- Extended `SamplePlanes` with per-component dimensions and a checked
  variable-layout allocator. The planar decoder now returns native-size planes
  instead of silently upsampling chroma.
- Promoted the embedded Kakadu 4:2:0 fixture from metadata-only rejection to a
  pixel-exact 8x8/4x4/4x4 strict T2/T1/DWT roundtrip. Unequal multi-precinct
  component grids followed in F3b Slice 3.

### Component-Subsampling Metadata Audit (F3b Slice 1)

- Added per-component SIZ `XRsiz/YRsiz` metadata to `jp2.Info` and exposed it
  through `componentSampling`; `jp2-info` prints non-unit sampling layouts.
- JP2 parsing accepts bounded nonzero sampling factors while normal writer
  wrappers retain unit-sampling validation. Pixel reconstruction followed in
  F3b Slice 2.
- Added an embedded Kakadu 8x8 4:2:0 JP2 fixture (`1x1,2x2,2x2`) plus zero
  sampling corruption and wrapper rejection gates.

### Mixed-Precision Strict Encode (F3a Slice 3)

- Extended the bounded planar encoder to unsigned mixed 8/16-bit components
  on the single-tile RPCL, reversible 5/3, no-MCT path. Component-local DC
  shifts and packet-scaffold Mb values now follow each SIZ precision.
- Added component-specific SIZ output, QCD inheritance from component zero,
  and QCC emission for differing components. The JP2 writer now emits
  variable-BPC `ihdr` plus `BPCC` through `wrapPlanarCodestream`.
- Added an 8/16/8 codestream/JP2 roundtrip with exact marker checks. A live
  64x64 output decoded pixel-exactly through OpenJPEG 2.5.4, Grok 20.3.6, and
  Kakadu 8.4.1 (all nine PGX component comparisons had zero mismatches).

### Mixed-Precision Strict Decode (F3a Slice 2)

- Carried unsigned 8/16-bit component precision and per-component QCD/QCC
  metadata through the strict codestream header, packet geometry, and T1
  nominal-bitplane reconstruction.
- Added per-plane inverse DC shifts and a mixed-precision `SamplePlanes`
  carrier for bounded single-tile RPCL, reversible 5/3, no-MCT decode.
- Added a pixel-exact embedded Kakadu 8/16/8 QCC fixture plus malformed-QCC
  and unsupported-MCT gates. The legacy RGB/TIFF API and mixed-precision
  encode remain fail-closed.

### Mixed-Precision BPCC Metadata Audit (F3a Slice 1)

- Extended `jp2.Info` with fixed per-component bit-depth metadata. Uniform
  files retain the existing `bits_per_component` value; mixed BPCC files use
  zero there and expose their unsigned 8/16-bit values through
  `component_bit_depths` and `componentBitDepth`.
- JP2 parsing now accepts bounded mixed 8/16-bit BPCC layouts only when every
  descriptor agrees with the matching codestream SIZ component. Signed,
  unsupported, missing, duplicate, or mismatched descriptors fail closed.
- `jp2-info` reports mixed component depths explicitly. Pixel reconstruction
  followed in F3a Slice 2.

### RGB-Triplet RCT With Independent Alpha (F2 Slice 3)

- Extended the bounded four-component reversible path so COD MCT=1 applies
  RCT only to RGB planes 0..2; the final alpha plane is independently DC
  level-shifted, wavelet transformed, packetized, and reconstructed.
- The strict planar reader and JP2 validator now accept this reversible RGBA
  profile while gray+alpha MCT, RGBA ICT, and irreversible four-component MCT
  remain fail-closed. Explicit no-MCT RGBA remains supported.
- `tiff-to-jp2` now selects RCT by default for RGBA and no MCT for gray+alpha.
  Added 8/16-bit transform and codestream roundtrips, COD MCT marker checks,
  JP2 `cdef` validation, and an RCT-backed TIFF/ICC alpha roundtrip.
- A live 32x32 RCT+alpha JP2 is accepted by OpenJPEG 2.5.4, Grok 20.3.6,
  and Kakadu 8.4.1. Grok/Kakadu TIFF output is pixel-exact and preserves
  unassociated alpha; OpenJPEG again proves codestream acceptance but omits
  TIFF ExtraSamples tag 338.

### TIFF ExtraSamples Alpha Conversion (F2 Slice 2)

- Added a shared `color.AlphaMode` plus `tiff.AlphaImage` for chunky 8/16-bit
  gray+alpha and RGBA. The strict TIFF reader/writer accepts exactly one final
  ExtraSamples value 1 (associated) or 2 (unassociated), preserves ICC bytes,
  and rejects unspecified, malformed, or multiple auxiliary samples.
- Connected `tiff-to-jp2` and strict JP2-to-TIFF decode to the 2/4-component
  reversible no-MCT planar path. WhiteIsZero normalization changes only the
  grayscale plane; alpha samples are never silently premultiplied or
  unpremultiplied. At this intermediate slice explicit RCT/ICT remained
  fail-closed; reversible RGBA RCT lands in slice 3 above.
- Added 8-bit gray+alpha and 16-bit RGBA TIFF roundtrips, malformed
  ExtraSamples coverage, and a complete TIFF RGBA -> JP2 -> strict decode ->
  TIFF regression preserving pixels, alpha mode, and ICC payload bytes.
- Live 32x32 RGBA output is accepted by OpenJPEG 2.5.4, Grok 20.3.6, and
  Kakadu 8.4.1. Grok/Kakadu TIFF outputs preserve unassociated alpha and are
  pixel-exact against the source. OpenJPEG decodes the JP2 but its TIFF writer
  omits ExtraSamples tag 338, so that leg is recorded as codestream acceptance
  rather than a semantic TIFF roundtrip.

### Bounded JP2 Alpha Channel Definitions (F2 Slice 1)

- Added `jp2.AlphaMode` and `wrapPlanarAlphaCodestream` for gray+alpha and
  RGBA wrappers over the existing 2/4-component no-MCT planar codestreams.
  The final plane is signalled as unassociated opacity (`cdef` Typ 1) or
  associated/premultiplied opacity (Typ 2), with whole-image association 0;
  pixels are never silently premultiplied or unpremultiplied.
- The strict JP2 reader now accepts 2/4-component layouts only when a complete
  identity-color-plus-alpha `cdef` is present, exposes the alpha mode through
  `Info`, and rejects missing, duplicate, mistyped, or reassociated entries.
  COC/QCC validation storage now follows the four-component bound.
- Added local gray+alpha/RGBA wrapper-to-strict-planar roundtrips and malformed
  `cdef` coverage. TIFF ExtraSamples is connected by F2 slice 2 above;
  RGB-triplet-only MCT was still fail-closed at this first slice and lands in
  slice 3 above.

### Bounded Planar Component Layouts (F1c) And Grayscale Unification

- New codestream-level surface for 1..4-component no-MCT layouts:
  `color.SamplePlanes` carries one unsigned 8/16-bit plane per component,
  `encodeLosslessPlanarWithOptions` encodes single-tile reversible 5/3 RPCL
  streams with SIZ Csiz = plane count (quality layers and rates included),
  and `decodeLosslessPlanar`/`decodeLosslessPlanarWithOptions` strict-decode
  them back to planes. At this F1 milestone non-3-component streams were
  MCT-free; the bounded RGBA RCT extension lands in F2 slice 3 above.
  Csiz > 4 stays fail-closed.
- The strict metadata/catalog/assembly machinery was already component-count
  generic; the {1,3} guards widened to the bounded envelope
  (`max_codestream_components = 4`) and the [3]-sized catalog arrays grew
  accordingly. Multi-tile remains 3-component only.
- The grayscale encoder, decoder, and tile builder are now thin one-plane
  delegates of the planar path (completing the F1 stage-b plumbing
  deletion); grayscale and RGB outputs verified byte-identical to the
  pre-change binary.
- Interop: 64x48 2- and 4-component streams decode pixel-exactly through
  OpenJPEG 2.5.4 and Grok 20.3.6 (12/12 per-component PGX legs).
- Documentation pass: README (status/rc1, features, supported boundary,
  docs index gained the SIMD plan), docs/api.md (planar API, z2k/shorthand
  CLI examples), and the now-archived feature plan (F1 marked complete, F2
  next) are
  reconciled with the current state.

### z2k Alias And All-Threads Default

- The build installs the CLI twice: as `z2000` and as the short alias
  `z2k` (a portable copy of the same artifact). Every command and option
  behaves identically under both names.
- The encode and decode commands now default to all logical CPU threads
  instead of one; `--threads N` limits the workers and `--threads 0` still
  means all. The resolution happens at the CLI boundary only — the library
  defaults (`LosslessOptions.threads`/`DecodeOptions.threads` = 1) are
  unchanged, and output streams are thread-count invariant (covered by the
  existing cross-thread determinism gates), so encoded bytes do not change.
- README examples use the alias and drop the now-redundant `--threads 0`.

### CLI Shorthand Conversion Syntax

- Conversions no longer need a subcommand: `z2000 input.tif output.jp2`
  routes to the TIFF encoder and `z2000 input.jp2 output.tif` to the strict
  JP2 decoder, inferred from the two leading path extensions
  (case-insensitive `.tif`/`.tiff`/`.jp2`; options follow as before).
  Explicit subcommand names are matched first and keep working, and
  unrecognized extension pairs still print usage and fail.
- README command examples now call the built binary directly with the
  shorthand syntax instead of `zig build run --` invocations, and the usage
  text documents both shorthand forms.

### CLI: --threads 0 Selects All Logical CPUs

- The README has documented `--threads 0` as "use all logical CPU threads",
  but the CLI passed the zero straight into the codec layers, which
  correctly require an explicit nonzero worker count - so the documented
  conversion examples failed with InvalidCodestream. The zero is now
  resolved to the logical CPU count at the CLI boundary (encode and decode
  commands alike), and every README example runs verbatim; the rate-layered
  conversion example was verified through to a lossless roundtrip.

### Shared Single-Tile Codestream Assembly (F1 Stage B, First Slice)

- The RGB and grayscale encoders now share one component-count-generic
  `assembleSingleTileCodestream`: main header (SIZ/COD/QCD, optional POC,
  sidecar comments, TLM, PPM), the tile-part loop (SOT, tile-header POC,
  PLT/PPT, SOD, packet bodies), and EOC live in a single assembler driven
  by a `SingleTileAssemblyInput` view over the packet stream. The grayscale
  encoder's duplicated ~90-line assembly is gone; branches its gate rejects
  (POC/PPM/PPT) simply never fire.
- Byte-identical output verified against the pre-change binary across ten
  profiles: lossless archival, 9/7 lossy, three-layer LRCP, PPM, PPT,
  BYPASS+TERMALL, CPRL, 512x512 multi-tile, and grayscale with and without
  quality layers. Full suite green in Debug and ReleaseFast.
- The tile-part Psot length now uses a checked u32 cast in the shared
  assembler (previously the RGB path used an unchecked cast; oversized
  tile-parts now fail closed as ImageTooLarge).

### Component-Generic Plane Carrier (F1 Stage A)

- `color.RctPlanes` and `color.IctPlanes` are now instances of a shared
  generic `ComponentPlanesOf(Sample)` carrier holding `planes: [][]Sample`
  (bounded by `color.max_components = 4`) instead of fixed `y`/`cb`/`cr`
  fields. All call sites across the color, codestream, and tile-pipeline
  layers index components generically; the tile decode scaffold now sizes
  its carrier by the actual component count instead of allocating empty
  cb/cr planes for grayscale.
- Behavior is unchanged by construction and verified: six encode profiles
  (lossless archival, 9/7 lossy, 512x512 multi-tile, three-layer LRCP,
  BYPASS+TERMALL, 10-thread) plus grayscale encode and lossy/lossless decode
  are byte-identical to the pre-change binary, the full suite is green in
  Debug and ReleaseFast, and the maintained t10 metrics are perf-neutral
  (within +/-1.2%, inside the no-regression tolerance).
- The refactor also removes a latent double-free: the legacy sidecar decode
  path declared `errdefer` frees for planes whose ownership had already
  moved into the carrier that a `defer deinit` also released; ownership now
  transfers exactly once. This is the enabling slice for alpha, mixed
  precision, and CMYK layouts (archived feature-plan F1).

### Release Candidate Infrastructure

- Added a portable static `riscv64-linux-musl` release archive and a full
  QEMU-backed RISC-V test gate. The release binary does not require RVV.
- Made the Linux x86-64 release target explicitly use musl rather than the
  hosted runner's native libc while retaining native Linux tests.
- Added explicit SemVer prerelease labels for release builds, producing
  versions such as `0.1.0-rc.1+build.404.gabcdef12` while preserving the
  existing development and final-release forms.
- Added a manual-only GitHub release workflow with separate dry-run and publish
  modes. Commits and tag pushes cannot create releases. Publication requires
  an existing tag that matches the tested revision exactly.
- Added native Windows x86-64, Linux x86-64 musl, and macOS arm64 release
  packages, SHA-256 checksums, pinned Zig 0.16.0 downloads, and release notes
  that distinguish the engineering scorecard from formal certification.

### Parallel Inverse Color Transform

- Added SIMD-aligned band scheduling for inverse RCT and ICT in strict RGB
  decode. Large images use at most four workers; small images remain serial,
  spawn failures fall back safely, and RCT range errors propagate after joins.
- Preserved the fused three-component dequantize plus inverse 9/7 DWT path and
  handed the full requested thread count only to the following inverse ICT.
  Serial/parallel tests cover odd dimensions, SIMD tails, 8/16-bit data,
  overprovisioned thread counts, and worker-side range failures.
- On the Ryzen 5700X, the 30-run lossy t16 gate improved from
  148.2 +/- 5.1 to 136.5 +/- 4.1 ms (-7.9%); lossless and both t1 metrics had
  no credible regression. ReleaseFast lossless/lossy TIFF hashes match the
  baseline exactly.

### Persistent Parallel 9/7 Forward DWT

- Added a multi-plane 9/7 row/column band scheduler with private worker
  scratch and one persistent eight-worker pool per transform. The sequential
  level cascade and per-sample floating-point operation order are unchanged.
- Promoted the scheduler only into single-tile irreversible encode; multi-tile
  keeps tile-level scheduling, and decode keeps fused dequantize+inverse-DWT
  component jobs. A symmetric inverse kernel is standalone and oracle-tested,
  but its hot-path integration was rejected after regressing t16 decode by
  4.9%.
- The Ryzen 5700X interleaved gate improved lossy t16 encode from
  161.1 +/- 4.5 to 152.8 +/- 4.1 ms (-5.2%, 16 runs). t1 encode and both
  decode metrics had no credible regression. Streams remained byte-identical
  across baseline/candidate and t1/t16 (4,798,568 bytes, SHA-256
  `7597eb209f70f3dc36717c08b4e0029f4c65895758f549a029a1f0612fd9c9ee`).
- Added exact serial/parallel 9/7 oracle coverage for minimal, one-dimensional,
  odd, origin-shifted, SIMD-tail, and overprovisioned-worker geometries, plus
  end-to-end irreversible encode/decode thread determinism.

### S6 RISC-V Functional Gate, Feature Plan, And Remaining-Levers Assessment

- Closed the SIMD plan's S6 RISC-V gate: the full 360-test suite passed on
  `riscv64/alpine` under Docker Desktop's qemu binfmt emulation
  (`riscv64-linux-musl -Dcpu=baseline_rv64+v`, ReleaseFast, built via
  `zig test --test-no-exec`), proving the portable `@Vector` code —
  including the new 32-lane 9/7 lifting blocks — is functionally correct
  with RVV enabled. Functional gate only; no performance claims per the
  ISA policy. With S0-S4, S6 done and S3 closed, the SIMD plan's routine
  execution is complete; only the S5 research campaign remains as a
  deliberate decision.
- Added the feature plan, now archived as
  `docs/archive/feature-plan-2026-07-15.md`: the staged post-Part 1 breadth plan —
  F1 component-generic core (the enabling N-plane refactor), F2 alpha,
  F3 mixed precision/subsampling, F4 colourspace breadth (sYCC/CMYK,
  signalling-first), F5 format front ends (BMP -> PNG -> JPEG -> linear
  DNG -> OpenEXR), F6 EXIF/IPTC/XMP preservation — with dependencies,
  sizes, verification requirements, and explicit non-goals.
- Added optimization-plan Checkpoint #6: the honest remaining-levers
  assessment after the micro-optimization space measured out — parallel
  decode efficiency (t16 gap 2.1x vs Kakadu against 1.5x at t1) and the
  fused dequantize-into-inverse-DWT angle rank ahead of the S5 T1 SWAR
  research; the corrected pass profile shows lossy encode's largest pass
  is MQ refinement.

### Lossy Encode Timing Split And S6 Compile Gates

- Fixed the `--timings` phase attribution on the irreversible encode path:
  the whole ICT + 9/7 DWT + quantization front end used to account to the
  MCT row with an empty DWT row (the profile that drives optimization
  decisions reported "MCT 108.7 ms, DWT 0.000 ms"). The measured front end
  now splits ICT into the colour row and the fused per-plane DWT +
  quantization jobs into the wavelet row (post-fix on the 32-lane build:
  MCT 7.2 ms, DWT 62.5 ms). Output streams are bit-identical; the reversible
  path's accounting is unchanged.
- S6 compile half recorded: the `riscv64-linux-musl -Dcpu=baseline_rv64+v`
  exe build and the AVX-512 `x86_64_v4` build (16 i32 lanes, 32-lane f32
  blocks lowering to 2 zmm per lift step) both succeed at ReleaseFast. This
  was the compile-only checkpoint; the qemu run half was completed later and
  is recorded in the S6 close-out above.

### S3 Lane Audit Close-Out (9/7 Lifting Block Width 32)

- Closed the SIMD plan's S3 lane audit on the Ryzen 5700X. The 9/7 lifting
  block width (`simd.f32_block_lanes`) moves 16 -> 32 after an interleaved
  four-variant hyperfine A/B on the lossy profile: encode t1 -6.0%
  (836.3 -> 786.5 ms), decode t1 -4.3% on the 20-run confirmation
  (758.8 -> 726.2 ms), encode/decode t16 -4.9%/-5.1%, lossless unchanged,
  and all variants produced bit-identical streams. The 8-lane variant
  regressed both directions and narrowing `ict_lanes` to 4 stayed below the
  3% gate; both were reverted per the keep rule. A generated-code spot check
  (`-mcpu=native -femit-asm` probe root) confirmed the lifting lowers to
  256-bit AVX2 (`vmulps`/`vaddps` on ymm, scalar ops only in boundary
  tails) with no FMA contraction — intentional, since FMA would change f32
  rounding and break stream bit-exactness. A fresh four-codec ledger record
  at `66807d7` (lossless + lossy, t1/t16) is in `docs/benchmarks.md`;
  follow-up: re-run the block-width A/B on the M4 before assuming the NEON
  win.

### Encode T1 Pass Profiling

- Extended single-thread encode `--timings` with separate MQ significance,
  refinement, cleanup/RLC, RAW significance, and RAW refinement pass totals,
  including pass and symbol counts. A focused EBCOT test checks that the
  profile accounts for every emitted pass and symbol.
- On the Ryzen 7 5700X 2048x2048 lossless corpus, MQ significance is the
  largest encode pass group at 244.5 ms, followed by cleanup/RLC at 202.7 ms
  and MQ refinement at 166.6 ms. Cleanup remains the most expensive MQ group
  per symbol.
- Reverted two byte-exact candidates below the 3% keep rule: reusing an
  already-loaded cleanup coefficient for sign coding improved t1 encode by
  1.1%, while avoiding a duplicate full-width row-mask scan improved encode
  by 1.3% and decode by 1.9%. The next candidate should reduce per-symbol MQ
  significance work rather than add more stripe-level gating.
- A second measured series also stayed below the keep rule and was reverted:
  CLZ-batched MQ encode renormalization was neutral, removing a write-only
  context state byte improved encode by 1.2%, explicit four-row significance
  unrolling was neutral, and a one-claim-per-RGB-block worker queue was neutral
  in its 30-run confirmation. The optimization plan records the full numbers
  and now reserves further O3 work for a different context/column data layout.

### ISO MQ Decode Branch Layout

- Reordered the ISO MQ decoder around the arithmetic-code `c_high >= Qe`
  partition, sharing the MPS-side code before splitting fast and renormalizing
  transitions. The profiled reader mirrors the unchecked hot path exactly.
- Ryzen 7 5700X A/B measurements improved lossless t1 decode by 3.1% and
  lossy t1 decode by 3.9%; pooled t16 measurements were approximately 1%
  faster but scheduler-noisy. Decoded lossless and lossy TIFFs remained
  byte-identical.
- Reverted an immutable full-context transition-table candidate after it
  improved decode by only 0.7%, below the optimization keep rule.
- Added a focused four-codec 5/3 lossless benchmark record. z2000 now beats
  Grok encode at t16 but remains behind at t1 and on decode; profiling assigns
  88.2% of lossless encode to T1 and only 8.9% to 5/3 DWT.
- Kept the existing AVX2 8-lane i32 policy after it beat a forced 4-lane build
  by 7.9% encode t1, 3.5% encode t16, and 2.7% decode t1. Two MQ encoder
  layout/inlining candidates were byte-exact but reverted below the keep rule.

### Direct PCRD Distortion Capture And Lossy Benchmark Gate

- The direct ISO-MQ T1 encoder can now collect exact per-pass coefficient
  distortion while emitting the real significance, refinement, and cleanup
  passes. Rate-targeted single- and multi-tile encode reuse that metadata
  instead of rerunning the symbol reference coder for every block; TERMALL and
  legacy/style paths retain the conservative fallback.
- Added an exact oracle regression across default, BYPASS, vertical-causal,
  segmentation-symbol, and non-LL band styles. Pass distortions, pass metadata,
  and output bytes must all match the previous path.
- Extended both comparative harnesses with an optional two-layer ICT/9/7
  profile and aligned the Windows lossless marker, tile-part, BYPASS, and thread
  flags across z2000, Grok, OpenJPEG, and Kakadu.
- On Ryzen 7 5700X (warmup 2, 8 runs), z2000 lossy encode fell from
  2256/367 ms to 809/159 ms at t1/t16 (-64.1/-56.6%), with byte-identical
  output. Lossless performance was unchanged. Full tables are recorded in
  `docs/benchmarks.md`.

### Parallel 9/7 Component Pipeline

- The irreversible encode pipeline (per-component 9/7 DWT + deadzone
  quantization) and its decode mirror (dequantization + inverse 9/7 DWT) now
  run the three components as parallel jobs on the existing component-job
  infrastructure, exactly like the 5/3 path. Per-plane arithmetic is
  untouched, so streams and decodes stay byte-identical; single-thread runs
  keep the serial order. Multi-tile keeps this stage serial inside its
  already-parallel tile workers.
- Measured on M4 (hyperfine, warmup 2, 8 runs): lossy encode t10 -23.1%,
  lossy decode t10 -23.9% on top of the S1 kernels; t1 and the lossless
  archival profile are unchanged. Cumulative with S1, the lossy t10 profile
  is ~44-46% faster than the pre-campaign baseline.

### Vectorized 9/7 Wavelet (SIMD Plan S1)

- The irreversible 9/7 DWT now lifts on the line split into contiguous
  even/odd halves (16-lane blocks) instead of gathering interleaved samples
  into 2-lane vectors, and the vertical pass processes 16-column bands with
  wide row-vector lifts instead of per-column strided gathers. Horizontal
  line copies are gone. Results are bit-identical to the previous
  implementation (proven by a scalar-reference matrix test across 16x16
  dimensions, 4 origins, 3 levels, plus byte-identical 2048x2048 lossy and
  lossless streams).
- Measured on M4 (hyperfine, warmup 2, 8 runs, keep rule >=3% with
  non-overlapping +/-sigma): lossy encode t1 -11.6%, t10 -28.1%; lossy
  decode t1 -13.2%, t10 -28.9%. The lossless archival profile is unchanged.
- The follow-up S2 candidate (vectorized quantize/dequantize band loops)
  measured -1.0% to -2.1% and was reverted per the keep rule; numbers are
  recorded in the archived SIMD-plan progress log.

### Reproducible Comparative Benchmark Ledger

- Added `docs/benchmarks.md` as an append-only record of comparative runs,
  including commit and application version, date, machine and OS, power state,
  tool versions, input checksum, exact codec profile, thread count, statistics,
  output sizes, and correctness validation.
- Made `tools/bench_compare.sh` compare explicit one-thread and equal-N-thread
  configurations for z2000, Grok, and OpenJPEG. Grok is pinned to CPU execution;
  optional `BENCH_RESULTS_DIR` exports Hyperfine JSON for all benchmark groups.
- Recorded the 2026-07-13 Apple M4 baseline against Grok 20.3.6 and OpenJPEG
  2.5.4, including native-output and common-z2000-stream decode measurements.

### Conservative Application Versioning

- Established `0.1.0` as the first pre-1.0 application/API line in the
  root `VERSION` file; this is intentionally separate from internal `.z2000`
  payload versions and JPEG2000 syntax/profile signaling.
- Build provenance is generated as valid SemVer. Development binaries report
  `0.1.0-dev.BUILD+gCOMMIT[.dirty]`; release-mode binaries report
  `0.1.0+build.BUILD.gCOMMIT[.dirty]`. The build number is the reachable Git
  commit count and the revision is an eight-character SHA.
- Added `z2000 --version`/`-V`, typed runtime version constants, source-archive
  fallback `0.1.0-dev.0+gunknown`, and deterministic `-Dbuild-number`,
  `-Dgit-sha`, and `-Dgit-dirty` overrides for CI/package builds.
- Documented the pre-1.0 increment policy, release tags, full-history
  requirement, dirty-worktree meaning, and the gate for eventually declaring
  1.0.0.

### Bounded JP2 Palette Vertical And 100/100 Scorecard

- Added `jp2.Palette`, `wrapPaletteCodestream`, and `extractPalette` for a
  deliberately bounded Part 1 layout: one unsigned 8/16-bit index component,
  three uniform unsigned 8/16-bit RGB `pclr` columns, explicit identity `cmap`,
  sRGB `colr`, and optional identity RGB `cdef`.
- `Palette.expand` uses checked dimensions, allocation sizes, palette indices,
  and interleaved RGB output. Missing mappings, malformed lengths, duplicate or
  nonidentity columns, signed/mixed palettes, ICC-first palette colour, alpha,
  and indices outside the table fail closed.
- `decode-temp-jp2` now decodes the one-component codestream through the shared
  grayscale ISO-MQ path and expands supported palette output to RGB TIFF;
  `jp2-info` reports codestream and output component counts separately.
- The local 8/16-bit fixture matrix covers emit, parse, extract, strict decode,
  expansion, `cdef`, truncation, bad `cmap`, and out-of-range indices. A live
  macOS fixture decoded through OpenJPEG 2.5.4 and Grok 20.3.6 to RGBA pixels
  identical to z2000 (`tiffcmp` exit 0 for both).
- This closes the final containers/metadata point and moves the engineering
  scorecard from **99/100 to 100/100**. The score remains an implementation
  estimate, not formal ISO certification; alpha, mixed component precision,
  general N-component layouts, broader colour spaces, and JPX remain explicit
  future breadth.

### Gain-Normalized Irreversible PCRD

- Corrected irreversible PCRD weighting to remove the ISO subband gain before
  applying the 9/7 synthesis norm, matching OpenJPEG's Tier-1 distortion
  model and the measured z2000 inverse basis norms (`HL / 2`, `HH / 4`).
- On the profile-matched 256x256 ladder, z2000 layer PSNR improves by
  0.26/0.38/0.36/1.44 dB. The OpenJPEG deficit is now
  1.60/0.31/0.65/0.15 dB (0.68 dB average versus 1.31 dB before); exact PLT
  prefixes and thread determinism are pinned in-tree. The benchmark now gives
  OpenJPEG matching levels, order, code-blocks, and precincts.
- Lossy encode/decode moves from 14/15 to 15/15 and the full Part 1 estimate
  moves from 98/100 to 99/100. Extreme-low-rate tuning remains useful but is no
  longer treated as a missing codec capability.

### Grayscale JP2 Encode And Strict Decode

- Added a real one-component coefficient, ISO-MQ T1, T2 packet, and codestream
  path for unsigned 8/16-bit grayscale. The bounded profile is single-tile,
  reversible 5/3, no-MCT, RPCL, in-band packet headers, PLT, optional
  TLM/SOP/EPH, and either one tile-part or resolution-ordered `R` tile-parts.
- Generalized packet scaffolds, encoded catalogs, packet ordering, and
  validation from fixed RGB components to checked one- or three-component
  operation while preserving the existing RGB defaults. A local artifact
  oracle roundtrips both bit depths exactly through MQ and inverse 5/3.
- `tiff-to-jp2` now dispatches grayscale TIFF input, normalizes WhiteIsZero,
  preserves optional ICC metadata, and chooses no MCT unless the user supplied
  an explicit profile. OpenJPEG 2.5.4 and Grok 20.3.6 decode generated 8/16-bit
  files pixel-exactly.
- Generalized strict SIZ metadata, RPCL indexes, packet sequences, active
  assemblies, block catalogs, and PLT-less reader state to one or three active
  components. `decodeLosslessGray*` reconstructs single-tile reversible
  grayscale through the block-level T1 scheduler and inverse 5/3;
  `decode-temp-jp2` dispatches grayscale JP2 back to TIFF with ICC preservation.
  z2000 decodes 8/16-bit output from OpenJPEG 2.5.4 and Grok 20.3.6
  pixel-exactly, completing bidirectional live interop and moving the full Part
  1 estimate from 97/100 to 98/100.

### Grayscale JP2 Metadata Foundation

- Added the second component-generic foundation slice. `wrapGrayCodestream`
  writes checked one-component `ihdr` metadata with enumerated grayscale
  `colr` (17) or restricted ICC, while `parseInfo` accepts matching unsigned
  8/16-bit grayscale codestream metadata. Identity grayscale `cdef` is accepted;
  mismatched color spaces, MCT, component indexes, and WhiteIsZero direct wraps
  fail closed. SIZ writing and packet planning now have component-count-generic
  internal cores without changing the RGB call path or ISO score (97/100).
  Live metadata smokes accept grayscale JP2 output from OpenJPEG and Grok.

### Grayscale TIFF Foundation

- Added owned `GrayImage` storage and a tagged `DecodedImage` TIFF surface.
  One shared checked parser now handles uncompressed chunky RGB plus 8/16-bit
  BlackIsZero and WhiteIsZero grayscale strips while preserving optional ICC
  bytes; strict RGB/gray adapters reject the opposite photometric profile.
- Added a grayscale TIFF writer with checked raster sizing, SIMD-covered 8-bit
  narrowing, 16-bit little-endian output, polarity preservation, and optional
  ICC storage. `tiff-info` reports either RGB or grayscale metadata. Focused
  roundtrip and malformed-tag tests established the input boundary later used
  by the one-component encode path. ISO score remained 97/100 at this stage.

### Packed Packet Boundary Markers

- Extended both `--ppt` and `--ppm` through every SOP/EPH combination on the
  bounded RPCL profile. ISO placement is explicit: SOP remains in SOD before
  each packet body and counts toward PLT, `Psot`, and TLM; EPH follows the T2
  header in the packed PPM/PPT stream. The shared strict reader validates
  marker presence, `Nsop`, EPH placement, and packed/body lengths before
  rebuilding its internal unframed header+body packet bytes. JP2 structural
  validation now admits the same bounded profiles.
- Added single- and multi-tile roundtrips for SOP-only, EPH-only, and combined
  framing, including PLT-less PPM, zero-body PPT packets, threaded determinism,
  malformed `Nsop`/EPH rejection, and wrapper acceptance. ReleaseFast macOS
  smokes over the 1024x1024 RGB fixture decode pixel-exactly through z2000,
  OpenJPEG 2.5.4, and Grok 20.3.6. The formerly open 16-tile/48-part two-layer
  PPM Grok gate also passes in the current tree. T2 completeness is now 10/10;
  the full Part 1 estimate moves from 96/100 to 97/100.

### POC Scheduling Foundation

- Added a standalone POC parser and packet scheduler. It handles Part 1's
  one- or two-byte component indices, validates resolution/component/layer
  bounds and progression values, applies overlapping records in order while
  skipping already-sequenced packets, and requires complete packet coverage.
  Tests use the exact two-record payload emitted by Kakadu for an LRCP first
  layer followed by RPCL and cover malformed and incomplete schedules.
- Connected main-header POC to the single-tile strict reader. The main-header
  index owns parsed records, the packet catalog walks their composed stream
  order, and downstream reconstruction receives the entries reordered to its
  internal RPCL grouping. A generated Kakadu LRCP-layer-0 then RPCL JP2 decodes
  pixel-exactly against `kdu_expand`; a self-contained CI test covers valid and
  malformed POC through raw decode, packet audit, and JP2 wrapping.
- Added the bounded single-tile main-header POC writer. `LosslessOptions` and
  CLI `--poc` accept checked records, the encoder permutes the real packet
  stream to their complete duplicate-free schedule, and the marker payload is
  serialized by the same standalone component as the reader. z2000,
  OpenJPEG 2.5.4, and Kakadu decode the two-layer LRCP-to-RPCL output
  pixel-exactly. Grok 20.3.6 misdecodes both this output and an equivalent
  Kakadu-produced POC file; this is tracked as an external interop limitation.
  The same main-header schedule now applies independently to every tile in the
  one-part-per-tile multi-tile path; strict decode preserves tile-local T2
  state and normalizes each catalog to RPCL. A 2x2-tile CLI fixture is
  pixel-exact through z2000, OpenJPEG, and Kakadu.
- Extended POC through `L` tile-parts when the composed schedule keeps every
  quality layer contiguous. Encode and strict decode validate the actual
  packet sequence against each part boundary and preserve tile-local T2 state
  across parts; incompatible/interleaved schedules fail closed. A dense 2x2
  tile fixture with 8x8 precincts and 4x4 blocks is pixel-exact through z2000,
  OpenJPEG, and Kakadu.
- Added component-contiguous POC across `C` tile-parts. Three checked records
  delimit RGB component ranges, encode/decode validate the composed sequence
  against the three PLT/TLM part spans, and tile-local T2 state persists across
  every boundary. The dense 2x2-tile fixture is pixel-exact through z2000,
  OpenJPEG, Grok, and Kakadu.
- Added resolution-contiguous POC across `R` tile-parts. Per-tile validators
  use each resolution's exact packet count rather than equal slices, and
  compare every PLT/TLM span against the reference-grid packet plan. A dense
  fixture using LRCP inside COD-RPCL resolution parts is pixel-exact through
  z2000, OpenJPEG, Grok, and Kakadu.
- Added reference-grid position POC across `P` tile-parts. The validator
  compares every composed packet's projected position against canonical PCRL,
  derives variable per-tile part boundaries from position runs, and checks
  each PLT/TLM span. The dense 2x2-tile fixture is pixel-exact through z2000,
  OpenJPEG, Grok, and Kakadu. Main-header POC now covers all direct division
  modes. Score at this stage: 95/100.
- Added bounded tile-part-header POC. Strict decode parses records only from
  `TPsot=0`, appends them after inherited main-header records independently per
  tile, and rejects malformed or later-part markers. `--poc-location tile`
  writes the checked schedule into every tile's first part and includes its
  bytes in both `Psot` and TLM; one-part and compatible `R`/`L`/`C`/`P`
  layouts share the existing packet scheduler. A 16-tile/48-part `R` JP2 is
  pixel-exact through z2000, OpenJPEG 2.5.4, and Grok 20.3.6, while jpylyzer
  2.2.1 reports valid JP2. POC remains intentionally incompatible with
  PPM/PPT until packed-header combinations have their own independent gates.
  Full Part 1 estimate: 96/100.

### PPM Framing Foundation

- Added an owned PPM framing component. It joins ordered `Zppm`
  marker payloads even when marker boundaries split `Nppm` or `Ippm`, iterates
  length-delimited tile-part header groups with checked arithmetic, and builds
  bounded marker payloads from groups. Focused tests cover split length/data,
  empty groups, malformed segment order, truncation, the 256-segment ceiling,
  and the ISO marker-length bound.
- Connected PPM to the bounded single-tile RPCL writer and strict reader for
  one part or `R` resolution parts with SOP/EPH disabled. Each tile-part gets
  one `Nppm/Ippm` group; the initial version used PLT for SOD bodies, and the
  follow-up below removes that redundancy. The JP2 wrapper checks
  marker ordering/conflicts, and strict decode validates all framing and T2
  state. A 128x128, two-layer, three-part live output decodes pixel-exactly
  through z2000, OpenJPEG, Grok, and Kakadu. This first integration kept
  multi-tile PPM fail-closed; the following increment opens it. Score: 95/100.
- Extended PPM across multi-tile RPCL `R` streams. Main-header groups follow
  codestream tile-part order while inclusion/zero-bitplane tag-trees and
  `numlenbits` remain independent per tile. PPM output is now PLT-less: strict
  decode derives each SOD body span from its decoded packed header, avoiding
  redundant and decoder-sensitive PL accounting. A 16-tile/48-part output is
  pixel-exact through z2000, OpenJPEG, and Kakadu. Grok 20.3.6 decodes the
  one-part-per-tile and all single-tile PPM cases losslessly but misdecodes
  multiple PPM groups per tile; that interop gate remains open. Score: 95/100.

### PPT Packed Packet Headers

- Added a real opt-in `--ppt` encode/decode path for RPCL JP2 streams with
  SOP/EPH disabled. Single-tile streams support one part or `R` resolution
  parts; multi-tile streams require `R` parts and preserve independent `Zppt`
  and T2 precinct/tag-tree state for each tile. The
  writer concatenates byte-stuffed T2
  headers into ordered PPT segments, writes PLT lengths for SOD packet bodies,
  and emits bodies without inline headers. Strict decode parses the packed
  header stream with persistent precinct/tag-tree state and reconstructs the
  normal internal header+body packet view. Coverage includes multi-layer
  roundtrip, empty packets with zero-length bodies, malformed `Zppt`, wrapper
  validation, globally ordered tile-local `Zppt` across parts, and fail-closed
  SOP/EPH or multi-tile non-`R` combinations. Live one-part, three-part, and
  16-tile/48-part outputs decode pixel-exactly through z2000, OpenJPEG, Grok,
  and Kakadu. Main-header PPM is covered by the newer slices above, with the
  multi-part Grok gate still open. The score stays 95/100.

### Per-Position Tile-Part Divisions (`--tile-parts P`)

- Added PLT-backed precinct-position tile-parts for multi-tile PCRL streams.
  Packet runs are grouped by their upper-left precinct coordinate on the image
  reference grid, reusing `packet_plan.packetPosition`; edge tiles may carry
  different `TNsot` counts. The shared multipart writer now derives each
  tile's part count from its plan instead of assuming one global count. A
  multi-layer regression covers PLT/TLM/Psot accounting, continuous SOP state,
  strict `P` metadata, threaded determinism, pixel-exact decode, and
  progression mismatch rejection. A live 16-tile/256-part JP2 decodes
  losslessly through z2000, OpenJPEG, Grok, and Kakadu. The score remains
  95/100 because POC and packed-header breadth were still open at that stage.

### Per-Component Tile-Part Divisions (`--tile-parts C`)

- Added PLT-backed component tile-parts for multi-tile CPRL streams. Each RGB
  tile is split into three component-contiguous packet ranges with ordered
  `TPsot`, `TNsot = 3`, per-part PLT, TLM/Psot accounting, and continuous SOP
  sequence state. Strict metadata now reports the division as `C` rather than
  assuming every multipart stream is `R`. A 16-tile, two-layer regression is
  deterministic across thread counts and roundtrips losslessly; the live JP2
  smoke is pixel-exact through z2000, OpenJPEG, Grok, and Kakadu. `C` with a
  non-CPRL order fails closed. The subsequent `P` slice above completes the
  direct tile-part division set; POC and PPM remained open at that stage.

### Origin-Aware Multi-Tile Irreversible 9/7

- Removed the multi-tile 9/7 alignment guard by carrying each tile's
  reference-grid `x0/y0` through all decomposition levels. Odd origins swap
  the local high/low lifting parity, scaling, and packed layout; inverse 9/7
  and scalar quantization use the same origin-aware subband catalog. Added
  direct floating-point roundtrips for four odd-origin geometries and a 17x17
  public multi-tile ICT/9/7 roundtrip with cross-thread determinism and JP2
  validation. Bidirectional live interop is within max byte diff 1: OpenJPEG,
  Grok, and Kakadu decode z2000 output, and z2000 decodes each reference's
  odd-origin 9/7 output against that reference's own raster. The score remains
  95/100 because the lossy row's final point still includes the measured PCRD
  PSNR gap.

### Rate-Targeted Multi-Tile Irreversible 9/7

- Lifted the last multi-tile 9/7 gate: `--rates` are now accepted with
  irreversible tiles. The global cross-tile PCRD allocation gained a per-band
  distortion weight table `(reconstruction step delta x 9/7 synthesis norm)^2`
  (built once in codestream.zig, identical for every tile, threaded through
  `PacketScaffoldOptions.band_weights`) that converts the quantized-domain
  squared error `passDistortions` measures into weighted reconstruction
  squared error — the reversible path keeps its squared 5/3 norm. Coverage: a
  rate-targeted multi-tile 9/7 roundtrip (lossless final layer, cross-thread
  determinism, first layer smaller than the lossless final layer via the PLT
  byte sums) plus the existing odd-origin fail-closed guard. Live interop
  (2048x2048 noise, 512x512 tiles, `--rates 20,10,1`): layer prefixes progress
  11.6 -> 12.3 -> 53 dB under `opj -l`, and the full stream decodes through
  kdu_expand, opj_decompress, and grk_decompress within max byte diff 1 of
  z2000's own decode. Scorecard: full lossy encode/decode 13->14, moving the
  full codec estimate to 95/100.

### Multi-Tile Irreversible 9/7

- Opened the multi-tile gate for the lossy path: a tile front-end hook
  (`TileFrontEnd`) lets codestream's ICT + 9/7 + deadzone-quantization
  stage replace the RCT + 5/3 stage per tile while the tile pipeline stays
  transform-agnostic, and per-band nominal bitplanes (Mb) now come from a
  scaffold-carried table built from the signalled irreversible step
  exponents (E-2) instead of the reversible bit-depth rule. Tile origins
  must be multiples of 2^levels (tile-local 9/7 lifting parity equals the
  reference grid there); odd origins and 9/7 rate targets stay fail-closed.
  Coverage: scalar-expounded and scalar-derived multi-tile roundtrips
  within lossy tolerance with cross-thread determinism and JP2 acceptance,
  plus fail-closed rates/odd-origin cases. Live interop on 2048x2048 noise
  with 512x512 tiles: kdu_expand, opj_decompress, and grk_decompress all
  reconstruct z2000's multi-tile 9/7 output within max byte diff 1 of
  z2000's own decode; conversely, foreign kdu (-rate 1/4), opj (-I -r 6),
  and grok (-I -r 6) lossy multi-tile files decode through z2000 within
  max 2 / 53-55 dB of each reference's own output — the foreign lossy
  multi-tile decode surface needed no new code and is now documented and
  claimed. Scorecard: full lossy encode/decode 12->13, moving the full
  codec estimate to 94/100.

### Per-Layer Tile-Part Divisions (`--tile-parts L`)

- Added the `L` tile-part division for the multi-tile LRCP path: the layer
  is the outermost packet loop inside every tile, so each tile emits one
  tile-part per quality layer (TPsot 0..layers-1, TNsot = layers) with its
  own PLT, reusing the generalized multi-part sequence writer the `R`
  divisions introduced. The single-tile assembler normalizes `L` to one
  part (mirroring the existing multi-layer-LRCP `R` normalization), `L`
  with non-LRCP progressions fails closed, and unknown divisions are now
  validated on the multi-tile gate too. The decoded side needs no new code:
  z2000's own `L` output rides the general foreign multi-part tile walk.
  Coverage: a 4x3 part-layout regression (SOT walk, per-part PLT packet
  counts, lossless 1/3-thread decode, deterministic re-encode, JP2
  acceptance, RPCL+L fail-closed, single-tile normalization) plus a live
  16-tile x 3-layer 2048x2048 smoke decoding pixel-exactly through z2000
  strict decode, kdu_expand, opj_decompress, and grk_decompress (with
  `opj -l 1` consuming the layer prefix). Scorecard: full T2 completeness
  8->9, moving the full codec estimate to 93/100.

### Global Cross-Tile PCRD Rate Targets

- Replaced the tile-local `--rates` allocation with a global cross-tile PCRD
  pass: every tile stores its blocks' band-weighted per-pass distortions
  while its RCT planes are alive, and after all tiles are encoded one slope
  threshold is allocated over every code-block of every tile with layer
  byte targets referenced to the whole-image compressed payload
  (`applyGridPcrdTargets`). Each tile's packet stream is rebuilt from the
  global truncations; a single-tile grid reduces exactly to the former
  tile-local allocation, so single-tile output is unchanged. A new
  heterogeneous-grid regression (one noisy tile, three shallow-gradient
  tiles) pins the cumulative layer-1 payload landing at or under the global
  /8 target while individual tiles deviate from the proportional shares the
  old allocation produced. Live interop: the 2048x2048 `--tile 512,512
  --progression LRCP --tile-parts none --rates 20,10,1` smoke decodes
  pixel-exactly through z2000 strict decode, kdu_expand, opj_decompress,
  and grk_decompress, and `opj -l 1` decodes the layer prefix. Scorecard:
  full lossless encode profiles 14->15 (row complete), moving the full
  codec estimate to 92/100.

### JP2 Container Metadata Breadth

- Broadened the JP2 reader beyond the minimal box set while keeping the
  fail-closed policy for semantics the codec does not implement:
  - Top-level `xml `, `uuid` (16-byte identifier enforced), and `uinf`
    metadata boxes are accepted anywhere after `ftyp` — before `jp2h`,
    between `jp2h` and `jp2c`, and after the codestream (Photoshop-style
    XMP / GeoJP2 placement). A jpylyzer-valid metadata-rich fixture decodes
    through z2000.
  - Multiple `colr` boxes follow the ISO I.5.3.3 rule: the reader keeps the
    first supported specification (method 1 sRGB or method 2 restricted
    ICC) and skips unsupported ones; PREC and APPROX (0..4) are treated as
    informative, APPROX > 4 is malformed. `extractIccProfile` mirrors the
    same choice.
  - Identity RGB `cdef` channel definitions (Cn=k, Typ=0, Asoc=k+1 in any
    order) are accepted; alpha, auxiliary, or reassociated channels fail
    closed, duplicates are malformed.
  - `res ` resolution superboxes are structurally validated (at most one
    `resc`/`resd`, 10-byte records, nonzero numerators/denominators)
    instead of blindly skipped.
  - Palette (`pclr`/`cmap`) stays fail-closed until palette expansion is
    implemented. Scorecard: containers/metadata 7->8, moving the full codec
    estimate to 91/100.

### Complete Code-Block Style Matrix (BYPASS+RESET, BYPASS+ERTERM)

- Landed the last two missing style-bit payload models, so every one of the
  64 combinations of the six Part 1 code-block style bits (0x00..0x3f) now
  has an implemented writer and strict reader. Raw BYPASS segments gained
  the predictable ER-TERM termination (ported from opj_mqc_bypass_flush_enc
  with erterm: partial bytes fill with the alternating 0,1 sequence, and
  the empty post-0xff byte is emitted as 0x2a instead of dropping the
  0xff — Kakadu verifies this in fussy mode). RESET now restarts the MQ
  contexts at every coding-pass boundary of the BYPASS and BYPASS+TERMALL
  segment models on both encode and decode. The direct/symbols byte-equality
  matrix gained the BYPASS+RESET/ERTERM rows, roundtrip tests cover 0x03,
  0x11, 0x13, 0x07, 0x15, and the full 0x3f, and the JP2 wrapper accepts
  every style byte up to 0x3f (reserved bits still rejected). Interop on
  the 2048x2048 noise smoke, all pixel-exact: the encode leg decodes through
  kdu_expand, opj_decompress, AND grk_decompress for BYPASS+RESET,
  BYPASS+ERTERM, BYPASS+RESET+ERTERM, both TERMALL triples, and the
  all-six-bit style; the decode leg reconstructs seven kdu Cmodes
  combinations up to {BYPASS|RESET|RESTART|ERTERM|CAUSAL|SEGMARK}.
  tools/interop_kakadu_styles.ps1 carries the new cases and drops the old
  BYPASS+ERTERM fail-closed assertion. Scorecard: full T1 completeness
  14->15 (row complete), moving the full codec estimate to 90/100.

### Foreign Multi-Part Tile Sequences

- Generalized the strict multi-tile SOT walk beyond z2000's own layouts:
  multi-part tiles are accepted in any progression when every non-empty part
  carries PLT — each part's packet count comes from its own PLT, parts
  consume the tile's packet sequence in TPsot order (grouped or interleaved
  across tiles), and the completed tile must land exactly on the tile packet
  plan. TNsot 0 ("count not signalled", ISO A.4.2) is supported: a later
  part may carry the real count, and unsignalled tiles complete via packet
  accounting at EOC. Empty SOT+SOD padding parts (Kakadu pads tiles to a
  fixed TNsot) need no PLT; joined non-RPCL tiles reorder to RPCL once
  assembled; the JP2 wrapper mirrors the TNsot rules and its TLM capacity is
  now tile-part sized (4096 entries). Non-empty PLT-less multi-part tiles
  stay fail-closed. Coverage: two embedded Kakadu 8.4.1 fixtures
  (ORGtparts=L interleaved TNsot-0 layer parts with genuine packet splits;
  ORGgen_tlm=8 empty-padding parts with a 32-entry TLM) decode the 64x64
  four-tile gradient exactly at 1 and 4 threads, with fail-closed negatives
  for stripped PLT, undershooting TNsot, and unsatisfied TNsot; the live
  Kakadu matrix (16- and 32-part 512x512 tiles, LRCP/RPCL/CPRL-3layers/
  ERTERM over 2048x2048 noise) decodes pixel-exactly, closing the historical
  kdu-multitile interop gap. Scorecard: full lossless decode profiles
  14->15, moving the full codec estimate to 89/100.

### Documentation And CLI Reference Fixes

- Corrected the README rate-layering example (`--rates` sets the layer count;
  a trailing `1` makes the lossless-final ladder explicit) and documented the
  `--rates` semantics: ratios reference the total compressed payload, unlike
  OpenJPEG's `-r`, which references the uncompressed size. Refreshed the
  `--tile` wording to the reference-grid envelope, updated the project
  direction note (narrow target is 100/100 and must stay green), and added
  the missing `--tile-parts`, `--sop`, and `--eph` options to the CLI usage
  text.

### Multi-Tile Resolution Parts

- Added PLT-backed RPCL `R` divisions to the bounded multi-tile encoder and
  strict decoder. Each tile emits `NL+1` SOT/SOD parts, TLM/PLT lengths are
  validated per resolution, SOP numbering remains continuous across a tile's
  parts, and the reader joins packet views into one tile catalog before T2/T1
  reconstruction. The JP2 boundary validates per-tile `TPsot`/`TNsot` state;
  malformed part indexes/counts fail deterministically. The 17x17 odd-origin
  gate decodes pixel-exactly through z2000, OpenJPEG, Grok, and Kakadu.
  PLT-less multi-part streams and non-RPCL `R` combinations remain fail-closed.
  This broadens the existing `R` profile without changing the 88/100 score.

### Reference-Grid Multi-Tile Strict Decode

- Added tile-region packet plans that retain each resolution's reference-grid
  bounds and first precinct indexes, so clipped precinct rectangles no longer
  assume a tile-local partition origin. Strict multi-tile metadata, PLT-less
  span derivation, packet audit, and decode now use those plans. Encode now
  partitions code-blocks and tag-tree leaves from each subband's global origin,
  removing the old `2^levels * precinct` tile-size guard. Origin-aware 5/3
  lifting, low/high subband origins, and global-to-band precinct projection
  then remove the remaining `2^levels` parity guard. Extended
  `tools/interop_pltless_multitile.ps1` with default-precinct and 17x17
  odd-origin OpenJPEG, Grok, and Kakadu files. All explicit, default, and
  odd-origin cases strict-audit and decode pixel-exactly. The strict T2 reader
  accepts the present geometry-empty edge packets emitted by the reference
  encoders while requiring zero block contributions and zero payload. The same
  gate encodes a 17x17 z2000 tile grid whose lifting parity starts inside
  precinct/code-block partitions and verifies pixel-exact decode through
  z2000, OpenJPEG, Grok, and Kakadu. Scorecard: the initial reference-grid
  decode slice moved lossless decode profiles 12->13 and the reconciled total
  86->87/100; bidirectional foreign odd-origin coverage moves that row 13->14
  and the total 87->88/100.

### Multi-Tile Rate Targets

- Opened `--rates` for the aligned multi-tile reversible profile with a
  tile-local PCRD allocation pass. Each tile now rewrites its T2 layer
  truncations from per-pass distortion metadata instead of even per-block
  splits, while preserving strict decode roundtrip and cross-thread
  deterministic encode output. Added `tools/interop_rate_multitile.ps1`, which
  encodes a 2x2 LRCP/rate-targeted multi-tile JP2 and verifies final-layer
  lossless decode through z2000 strict decode, OpenJPEG, Grok, and Kakadu.
  Cross-tile/global byte-target refinement and broader progression/style
  coverage remain before raising the scorecard.

### PCRD PSNR Ladder

- Added `tools/pcrd_psnr_ladder.ps1` plus an in-tree regression over the same
  256x256 mixed corpus. The test pins rate-targeted layer byte accounting,
  cross-thread deterministic output, and final-layer 9/7 reconstruction quality.
  The script decodes z2000 layer prefixes with OpenJPEG and compares them with
  OpenJPEG encodes at matched byte sizes. Current 2026-07-11 baseline:
  z2000 trails OpenJPEG by 1.78 / 0.69 / 1.21 / 1.78 dB across layers 1-4.
  No scorecard bump yet; this gives future PCRD changes a concrete quality gate.

### CI Reference-Relative 9/7 Decode Matrix

- Added a six-case embedded decode matrix that turns the out-of-process
  foreign-9/7 comparisons into an always-on CI gate: OpenJPEG 2.5.4 `-I -r
  4/16`, Grok 20.3.6 `-I -r 4/16`, and Kakadu 8.4.1 `Creversible=no -rate
  4/1` files of the shared 32x32 gradient, each paired with the reference
  decoder's own decoded RGB8 raster. The test decodes every fixture through
  the strict ISO-MQ path, asserts cross-thread determinism (1 vs 4 threads),
  and recomputes reference-relative agreement on every run: max byte diff
  <= 3 and PSNR >= 50 dB when not byte-identical (measured max 0-2 with
  55 dB up to byte-exact for `kdu -rate 1`). Scorecard: full lossy
  encode/decode 11->12, moving the full codec estimate to 85/100; the
  remaining lossy gap is encoder-side (PCRD PSNR regression at matched byte
  ladders, tile-aware rate targets).

### Kakadu 9/7 Lossy Decode Fixture And Ladder

- Added an embedded Kakadu 8.4.1 9/7 lossy decode fixture (32x32 gradient,
  `kdu_compress Creversible=no -rate 3`, 494 bytes): Kakadu signals
  scalar-expounded QCD with one guard bit and its own step mantissas
  (different from both z2000's generated OpenJPEG table and the Grok
  fixture), LRCP order, no PLT, and `res `/`resc` wrapper boxes. The
  regression pins a deterministic FNV-1a-64 hash of the decoded samples plus
  a source-error bound; out-of-process, z2000's decode agrees with
  kdu_expand's own within max byte diff 1 / 56.4 dB. The wider Kakadu
  reference-relative ladder (`-rate 1..8` on the 2048x2048 noise smoke) is
  within max byte diff 2-3 / 51-55 dB of kdu_expand — the same band as the
  documented OpenJPEG/Grok ladders. All three reference encoders now have
  pinned 9/7 decode fixtures. Scorecard: full lossy encode/decode 10->11,
  moving the full codec estimate to 84/100.

### Multi-Tile Standalone RESET/ERTERM

- Opened `validateMultiTileCodingPath` for standalone RESET (COD `0x02`),
  standalone ERTERM (`0x10`), and their combination (`0x12`): the tile
  pipeline already routes non-TERMALL styles through the same direct ISO-MQ
  block encoder as the single-tile path, so the guards were pure
  defense-in-depth duplicates. Added a 2x2 LRCP three-layer multi-tile
  roundtrip matrix (COD style byte, byte determinism at 1 and 3 encode
  threads, 1- and 3-thread strict decode, JP2 acceptance) and extended
  `tools/interop_kakadu_styles.ps1` with the three multi-tile standalone
  forward legs. Verified live: kdu_expand decodes genuine 512x512-tile
  z2000 output for all three profiles pixel-exactly, and z2000 strict
  decode roundtrips the same files. No scorecard change; this is breadth
  inside the already-counted multi-tile resilience rows.

### Standalone Predictable Termination (ERTERM)

- Opened COD code-block style `0x10` without TERMALL as a public single-tile
  opt-in: the continuous ISO-MQ encoders (symbol-based and hot direct-scratch,
  kept byte-identical by the extended direct/symbols equality matrix) flush
  the code-block's single termination point with the interop-verified ER-TERM
  procedure (ISO 15444-1 D.4.2), and the strict continuous decoders accept the
  style because MQ decode is flush-independent. `0x12` (ERTERM+RESET) is
  public as well; the legacy backend, BYPASS+ERTERM, and multi-tile standalone
  ERTERM stay fail-closed. Verified bidirectionally against Kakadu 8.4.1:
  kdu_expand decodes z2000 `--predictable-termination` (and `--reset-context`)
  output pixel-exactly, and z2000 strict decode reconstructs kdu
  `Cmodes=ERTERM`, `{ERTERM|RESET}`, and `{ERTERM|CAUSAL|SEGMARK}` files
  pixel-exactly. Scorecard: full T1 completeness 13->14, moving the full
  codec estimate to 83/100.

### PLT-less Multi-Tile Strict Decode And Interop

- Extended the aligned multi-tile strict path so z2000-generated streams can
  omit `PLT`: Stage B records PLT-less tile spans, and the per-tile catalog now
  derives packet boundaries from tile-local T2 packet headers. Added a 3x3
  multi-tile regression that strips every `PLT` segment, adjusts `SOT/Psot` and
  0x60 `TLM/Ptlm`, strict-decodes byte-exactly, and audits packet headers, plus
  no-TLM/no-SOP/no-EPH and reordered unique tile-part regressions. Added
  `tools/interop_pltless_multitile.ps1`, which generates aligned PLT-less
  multi-tile JP2s with OpenJPEG, Grok, and Kakadu and verifies z2000 strict
  decode pixel-exactly. Scorecard: full lossless decode profiles 10->12,
  moving the full codec estimate to 82/100.

### Narrow RGB Lossless JP2 Target Reaches 100/100

- Added a final no-sidecar strict T1 corpus regression over sparse,
  dense/sign-heavy, and refinement-heavy RGB inputs. The test verifies strict
  packet block catalogs contain metadata-ready, non-empty, multi-pass and
  multi-bitplane T1 payloads before strict decode reconstructs each image
  byte-exactly. Scorecard: narrow T1/EBCOT/MQ 19->20, bringing the narrow RGB
  lossless JP2 target to 100/100. The full JPEG2000 Part 1 codec family remains
  tracked separately.

### Narrow T2 Later-Layer State Corruption Gate

- Added a no-sidecar, rate-targeted, three-layer RPCL regression that verifies
  repeated block inclusions across layers, flips the header byte of packet
  index 1 using PLT-derived packet boundaries, and requires both strict packet
  audit and normal strict decode to fail as `InvalidCodestream`. Scorecard:
  narrow T2 RPCL packetization 14->15 (98->99).

### Narrow Strict Decode Sidecar-Retirement Proof

- Strengthened the BYPASS strict SOD roundtrip so it now asserts no BP8 sidecar
  is present, reads the strict packet block catalog, verifies BYPASS style
  metadata plus multi-segment lengths and non-empty payload views, then decodes
  through the normal no-sidecar path. Scorecard: narrow strict decode 9->10
  (97->98).

### Narrow T2 Consistent-Truncation Gate

- Added a no-sidecar rate-targeted multi-layer RPCL regression that removes the
  final SOD payload byte while shortening the final `PLT` packet length and
  `SOT`/`TLM` tile-part lengths consistently. Strict packet-catalog read and
  normal strict decode now fail deterministically as `TruncatedData` once the
  T2 packet reader reaches the incomplete packet. Scorecard: narrow T2 RPCL
  packetization 13->14 (96->97).

### Narrow Tile-Part Marker Phase Hardening

- Added a strict no-sidecar regression that moves a valid `PLT` segment out of
  the tile-part header and into the packet payload after `SOD`; both strict
  packet-catalog read and normal strict decode now reject the stream as
  `InvalidCodestream`. Scorecard: narrow tile-part markers 9->10 (95->96).

### Narrow Core Marker Duplicate/Ordering Hardening

- Tightened the strict codestream and JP2 main-header policy for supported
  marker segments: duplicate `SIZ`, `COD`, `QCD`, and same-index `TLM` are now
  explicitly rejected, and `TLM` must appear only after `COD` and `QCD` have
  established packet/tile-part context. Scorecard: narrow core main markers
  9->10 (94->95).

### Narrow Core Marker Fail-Closed Coverage

- Extended the raw strict codestream marker regression to cover unsupported
  main-header CAP, PLM, RGN, POC, PPM, and CRG marker segments, plus tile-part
  RGN/POC alongside the existing PPT/COC/QCC override cases. These remain
  `UnsupportedPayload` in the narrow profile instead of falling through to
  ambiguous parse failures. Scorecard: narrow core main markers 8->9
  (93->94).

### Narrow TIFF 6.0 Fail-Closed Matrix

- Added an explicit TIFF parser matrix for unsupported narrow RGB variants:
  compressed TIFF, palette/unsupported photometric interpretation, planar RGB,
  extra alpha/sample channels, mixed bit depths, signed sample format, and
  tile-only TIFFs without strip tags. All now have focused fail-closed tests,
  while the supported path remains uncompressed chunky RGB strips with 8/16-bit
  unsigned samples and optional ICC preservation. Scorecard: narrow
  TIFF input/output 6->7 (92->93).

### Narrow T2 Strict Decode Hardening

- Added no-sidecar strict T2 coverage for rate-targeted multi-layer streams:
  the packet-header audit now exercises real RPCL layer deltas from SOD bytes,
  confirms repeated block inclusions across layers, and the strict decoder
  reconstructs the final lossless layer without the BP8 oracle.
- Added a no-sidecar packet-header corruption regression that flips the first
  real SOD packet-header byte after SOP framing and requires both
  `auditStrictPacketHeaders` and normal strict decode to fail deterministically.
  This locks the narrow path closer to a pure strict T2 reader before the next
  scorecard bump.

### Kakadu Style and COC/QCC Interop Matrix

- Added `tools/interop_kakadu_styles.ps1`, a reproducible Windows smoke that
  exercises z2000 -> Kakadu and Kakadu -> z2000 code-block style profiles on
  `C:\temp\tools\images\0004.tif`. The current run is pixel-exact for z2000
  RESET, TERMALL, RESET+TERMALL, ERTERM+TERMALL, BYPASS+TERMALL,
  CAUSAL+SEGMARK, and the aligned multi-tile CAUSAL+SEGMARK,
  RESET+TERMALL, ERTERM+TERMALL, and BYPASS+TERMALL profiles. The reverse
  direction is pixel-exact for Kakadu RESTART, RESET+RESTART,
  ERTERM+RESTART, BYPASS+RESTART, CAUSAL+SEGMARK, and a uniform QCD guard-bit
  override fixture.
- The strict codestream reader and JP2 wrapper now accept main-header COC/QCC
  markers as uniform overrides across all RGB components when the signalled
  COD/QCD style is otherwise supported. Partial or divergent COC/QCC override
  sets fail closed in both paths; a standalone Kakadu ERTERM stream is also
  intentionally rejected until non-terminated ER-TERM payload behavior exists.
  Scorecard: narrow T1/EBCOT 18->19 (91->92), full T1 completeness 12->13
  (79->80).

### Standalone RESET Code-Block Style

- The COD RESET style bit (`0x02`, ISO 15444-1 D.4) is now a public opt-in
  profile without requiring TERMALL: `--reset-context` restarts the MQ
  contexts to the JPEG2000 initial states (Table D.7) at every coding-pass
  boundary inside the continuous codeword stream. The direct ISO encoder,
  the symbol-based reference encoder, the strict COD reader, and the JP2
  wrapper all accept COD style `0x02`; the byte-for-byte direct-vs-symbols
  equality matrix gained a RESET dimension.
- The inferred continuous decoder's per-pass reset now restores the JPEG2000
  initial context states (previously the all-default reset, unreachable
  through public gates) to match the encoder and OpenJPEG's `resetstates`.
- Interop: z2000 `--reset-context` streams decode losslessly in OpenJPEG
  2.5.4 and Grok 20.3.6; OpenJPEG and Grok `-M 2` streams decode losslessly
  in z2000 (all four legs pixel-exact on the 2048x2048 smoke; COD style byte
  verified `0x02`; jpylyzer-valid).
- BYPASS+RESET, RESET on the legacy T1 backend, and multi-tile standalone
  RESET stay fail-closed.

### Truncated-Plane Midpoint Reconstruction

- T1 decode now embeds the ISO-conventional uncertainty midpoint while
  decoding (matching OpenJPEG): a newly significant sample at plane p is
  reconstructed at 1.5*2^p, and each refinement re-centers the half at the
  new plane (+2^(p-1) for bit 1, -2^(p-1) for bit 0; exact at plane 0).
  Fully decoded blocks are unchanged (the half vanishes at plane 0), so all
  lossless byte-exactness invariants hold untouched; truncated blocks now
  reconstruct at the interval midpoint instead of the floor. Foreign
  truncated 9/7 decode agreement with the reference decoders jumps from
  ~34-38 dB PSNR (max byte diff 13-20) to ~50-55 dB (max 1-3) across the
  OpenJPEG and Grok -r 2..24 ladders, and z2000's own truncated-layer
  reconstruction improves the same way. The two embedded truncated-fixture
  gates were re-pinned with the new hashes and tightened error bounds
  (OpenJPEG -r 10: 7.93M vs old 8.5M bound; Grok -r 8: 2.21M vs old 3M).
  Scorecard: full "Lossy" 9->10 (77->78).

### Multi-Tile Progressions

- Multi-tile LRCP and RLCP now accept multiple untargeted quality layers. A
  tile-local state table keeps one T2 packet-reader state per
  resolution/precinct/component and enforces contiguous layer numbers when the
  stream revisits that precinct. Generated 2x2, three-layer LRCP and RLCP JP2s
  decode pixel-exactly through z2000, OpenJPEG 2.5.4, and Grok 20.3.6.
- Multi-tile lossless encode/decode now accepts PCRL and CPRL, including
  multiple untargeted quality layers. The tile pipeline reuses the shared ISO
  B.12 reference-grid position sort and keeps layers consecutive per precinct,
  so its existing packet-header state validator remains applicable. Generated
  2x2, three-layer PCRL and CPRL JP2s decode pixel-exactly through z2000,
  OpenJPEG 2.5.4, and Grok 20.3.6.
- Multi-tile lossless encode/decode now also accepts single-layer RLCP. Each
  tile's checked RPCL packet stream is permuted with the shared ISO B.12 RLCP
  iterator, and strict decode maps the tile-local catalog back to RPCL before
  the existing T2/T1 reconstruction. A generated 2x2 RLCP JP2 decodes
  pixel-exactly through z2000, OpenJPEG 2.5.4, and Grok 20.3.6. Multi-layer RLCP
  remains fail-closed until the tile-stream validator carries packet-header
  state across revisited precincts.
- Multi-tile lossless encode/decode now accepts the single-layer LRCP packet
  order inside the aligned RCT/5-3 tile envelope. The tile pipeline still
  builds packets from the checked RPCL scaffold, then byte-preservingly
  permutes each tile-part payload and PLT table into LRCP order; strict
  multi-tile decode reads the tile-part in COD progression order and reorders
  the packet catalog back to RPCL for the existing T2/T1 reconstruction path.
  That increment kept multi-layer LRCP/RLCP fail-closed; the stateful validator
  described above has since lifted the restriction.
- Multi-tile RPCL now accepts more than one untargeted quality layer. This
  reuses the existing per-block layer truncation table and per-precinct RPCL
  packet-state lifetime while keeping multi-tile compression-ratio targets
  fail-closed at that point; the later tile-local PCRD slice in Unreleased now
  lifts the bounded reversible `--rates` gate.

### T1 Code-Block Styles

- The aligned multi-tile RCT/5-3 path now accepts CAUSAL, SEGMARK,
  CAUSAL+SEGMARK, RESET+TERMALL, ERTERM+TERMALL, and BYPASS+TERMALL. T1 BYPASS
  metadata is preserved explicitly in the T2 layer-block view, so packet
  readback uses the encoded raw/MQ segment mode without inferring it from
  lengths. Focused 2x2 strict roundtrips cover threaded determinism, parallel
  decode, and corrupt second-tile PLT rejection; OpenJPEG and Grok decode the
  representative combined/terminated fixtures pixel-exactly. The malformed
  corpus sweep now includes multi-tile BYPASS+TERMALL.
- Multi-tile lossless encode now accepts TERMALL (`COD` code-block style
  `0x04`) inside the aligned v1 tile envelope. The tile encoder routes
  TERMALL blocks through the per-pass ISO-MQ segment writer, the tile-packet
  readback validator understands the resulting one-length-per-pass packet
  headers, and strict single-threaded/threaded decode reconstructs the source
  byte-exactly. The malformed-input fuzz sweep now includes a multi-tile
  TERMALL profile, and a dedicated multi-tile TERMALL corruption matrix checks
  second-tile PLT length damage, final tile-part truncation, and SOD payload
  byte flips.
- BYPASS+TERMALL (`COD` code-block style `0x05`) is now locally public for the
  ISO-MQ path. The encoder emits one terminated segment per coding pass, using
  D.6 raw bypass for eligible significance/refinement passes and MQ for
  cleanup/non-bypass passes; the strict decoder consumes the same per-pass
  segment table. RESET/ERTERM combined with BYPASS remains fail-closed until
  those segment models have their own tests and interop gates. A 256x256
  single-layer RPCL/RCT/5-3 smoke decodes losslessly through z2000 strict
  decode, OpenJPEG 2.5.4, Grok 20.3.6, and Kakadu 8.4.1. BYPASS+TERMALL now
  also participates in the
  malformed-input fuzz sweep and terminated-style corruption matrix, and T2
  packet-header decoding rejects terminated segment counts above the fixed
  per-block segment table capacity before reading segment lengths.

### JP2 Container Metadata

- The JP2 reader now accepts an `ihdr` BPC value of `255` when a matching
  `bpcc` child box supplies uniform unsigned RGB component precision. The
  supported boundary stays narrow and fail-closed: exactly three components,
  all 8-bit or all 16-bit, `bpcc` immediately following `ihdr`, matching the
  codestream SIZ component precision, with either enumerated sRGB or restricted
  ICC colour boxes. Missing `bpcc`, signed components, mixed precision,
  malformed lengths, and optional boxes inserted before required `bpcc` are
  rejected explicitly.
- The same JP2 header walk now treats only `res ` as safely ignorable metadata
  in the narrow RGB profile. Palette, component-mapping, channel-definition,
  and unknown `jp2h` boxes fail closed until their colour/component semantics
  are implemented.

### Foreign 9/7 Lossy Decode

- z2000 now decodes foreign OpenJPEG 2.5.4 irreversible 9/7 lossy JP2s
  byte-identically to OpenJPEG's own decode across a moderate rate ladder
  (`opj_compress -I` at `-r 1..8`, plus `-q`). A regression test embeds a 32x32
  OpenJPEG 9/7 file and asserts z2000's strict decode matches the reference by
  an FNV-1a hash over the decoded samples. This is the first "arbitrary lossy
  decode" capability (Lossy row 7->8, full 68->69).
- The continuous inferred T1 decoders now accept rate-truncated pass prefixes
  instead of requiring the full coding-pass count. A focused regression covers
  both legacy MQ and ISO-MQ inferred decode with two-pass prefixes, which
  removes the local T1-side blocker for heavily truncated foreign 9/7 packets;
  the embedded OpenJPEG `-r 10` fixture below now pins the real interop corner
  that motivated that partial-pass relaxation.
- Strict decode now also carries signalled QCD exponents into the irreversible
  scalar-expounded/scalar-derived `Mb = G + epsilon_b - 1` calculation instead
  of falling back to a locally re-derived table after validation. A local
  diagnostic OpenJPEG 2.5.4 `-I -r 10` smoke now decodes through z2000 without
  `InvalidBlock`; reconstruction still differs from OpenJPEG's own decode on
  that tiny fixture (about 30.67 dB PSNR, max byte diff 41), so the formal N4
  follow-up is a pinned PSNR/error-bound fixture matrix rather than a score
  claim.
- A focused embedded regression now pins the same heavily truncated OpenJPEG
  2.5.4 `opj_compress -I -r 10` JP2 on the strict ISO-MQ decode path. The test
  asserts deterministic decoded samples by FNV-1a and a bounded reconstruction
  error against the original synthetic gradient, keeping this interop corner
  covered without requiring OpenJPEG at unit-test runtime.
- The strict irreversible QCD parser now accepts signalled scalar-expounded and
  scalar-derived `(epsilon_b, mu_b)` step sizes instead of requiring z2000's
  locally generated OpenJPEG-compatible table byte-for-byte. Strict decode uses
  those signalled mantissas for 9/7 dequantization and derives `Mb` from the
  signalled guard bits plus exponents (E-2). A synthetic mantissa-rewrite
  regression plus scalar-expounded and scalar-derived guard-bit-one roundtrips
  keep the parser and dequantization path tied together; scalar-derived now has
  its own mantissa-rewrite regression proving the single signalled step reaches
  dequantization.
- The JP2 wrapper now applies the same signalled-step policy at the codestream
  boundary instead of rejecting foreign irreversible QCD mantissas before strict
  decode can see them. A new embedded Grok 20.3.6 `grk_compress -I -r 8`
  fixture exercises JP2 extraction, strict ISO-MQ decode, and bounded
  reconstruction on the shared 32x32 gradient. This closes the first real Grok
  9/7 QCD-step interop gate (Lossy row 8->9, full 69->70); Kakadu and broader
  reference-relative PSNR coverage remain open. The JP2 wrapper keeps malformed
  irreversible QCD fail-closed with explicit zero-step and zero-guard
  regressions, and now has positive scalar-derived metadata coverage plus
  scalar-derived zero-step/length regressions too; scalar-expounded wrapper
  coverage also rejects no-quantization, malformed scalar-derived, and invalid
  qstyle rewrites. The strict reader also has a focused irreversible-QCD
  corruption matrix for no-quantization style,
  malformed scalar-derived length, invalid qstyle, and zero scalar steps.

### Redundant COC/QCC Component Markers

- The strict reader and JP2 wrapper now accept COC (A.6.2) and QCC (A.6.5)
  component-specific coding/quantization markers when they byte-replicate the
  main COD/QCD for a valid component (some encoders emit a redundant COC/QCC
  per component even when identical to the main marker). Any genuine
  per-component override fails closed, since z2000 has no per-component coding
  path. A splice-oracle test inserts a redundant COC (component 1) and QCC
  (component 2) into a valid codestream and asserts byte-exact decode plus JP2
  acceptance. Mismatched COC and QCC overrides now fail closed in both the
  strict reader and JP2 wrapper, as do COC/QCC component indexes outside the
  RGB component set. COC `Scoc` plus SPcoc coding bytes are structurally
  validated before byte-replica comparison, and both paths validate QCC's
  QCD-style payload first too, so malformed COC/QCC qstyle/coding bytes report
  a bad codestream instead of being treated as merely unsupported. Shortened
  COC/QCC lengths are bounded as truncation in the raw reader and invalid at
  the JP2 boundary; syntactically known but unsupported COC style combinations
  still report `Unsupported*` rather than malformed input. COD/QCD and COC/QCC
  in tile-part headers also fail closed as unsupported, since z2000 only
  accepts redundant main-header component markers today.
  Scorecard: full
  "Core codestream syntax" 11→12 (full 67→68). Note: OpenJPEG/Grok do not emit
  COC/QCC for plain RGB, so this is strict-reader-gated (no reference file on
  hand); the follow-up is a Kakadu/tuned-encoder file that carries them.

### 16-bit RGB End-to-End

- Confirmed and locked in the full 16-bit RGB archival pipeline. A new test
  encodes a 16-bit gradient image (content spanning the full 16-bit range,
  SOP+EPH+TLM, four resolutions) and reconstructs it byte-exactly through
  z2000 strict decode, with the JP2 wrapper carrying the 16-bit depth. The
  equivalent 80x64 16-bit TIFF was verified out-of-process to decode
  losslessly through OpenJPEG 2.5.4 and Grok 20.3.6 and to be jpylyzer-valid,
  closing the 16-bit leg of the interop evidence (previously only the 8-bit
  smoke profile was interop-confirmed).

### Odd/Edge Dimension Coverage

- Added an odd/thin/minimal-dimension roundtrip matrix (1x1, 5x5, 17x13,
  3x100, 100x3, 255x1, 33x31, 63x65, 127x129, 2x2) through the archival
  encode/decode (SOP+EPH+TLM, 3 requested resolution levels so the clamp
  path runs on tiny dimensions). Each stresses the odd 5/3 DWT edge lifting,
  sub-band/precinct/code-block edge derivation, and the resolution clamp,
  and reconstructs byte-exactly through z2000 strict decode. Every case was
  also confirmed lossless through OpenJPEG 2.5.4 and Grok 20.3.6, including
  the archival profile with precincts. Scorecard: narrow RCT/5-3 DWT row
  9→10 (narrow 90→91).

### Malformed-Input Fuzzing Gate

- Added a CI-enforced corruption-sweep test that fuzzes every strict-decode
  parse surface. It builds a valid archival codestream (SOP+EPH+TLM, two
  resolutions, 8x8 blocks) and its JP2 wrapper, then sweeps truncation at
  every length plus single-byte corruption across SIZ/COD/QCD/TLM/SOT/SOD/
  PLT/SOP/EPH framing, packet headers, tag-trees, and T1 payloads, asserting
  every case is handled with a bounded error and no panic or out-of-bounds
  read under Debug, ReleaseSafe, and ReleaseFast. An out-of-process
  ReleaseSafe sweep over the full smoke JP2 (byte-flip, truncation, and
  multi-value corruption, ~96 K malformed inputs) independently found zero
  crashes, confirming the bounds-checked readers and fail-closed validation
  hold across the whole file. Scorecard: full-codec interop/conformance row
  4→5 (66→67).
- Broadened the corruption-sweep gate to four profiles: single-tile archival
  RCT/5-3, multi-tile RCT/5-3 (exercising the per-tile SOT/PLT walk and
  multi-tile strict decode), irreversible ICT/9-7 (QCD step-size parsing plus
  the float inverse-DWT/ICT path), and terminate-all (TERMALL) exercising the
  per-pass terminated-segment T1 decoder and multi-segment PLT/packet path.
  All green in Debug/ReleaseSafe/ReleaseFast; out-of-process ReleaseSafe
  sweeps of the multi-tile and 9/7 smoke JP2s independently found zero
  crashes.

### Balanced Low-Thread Decode

- Strict decode now routes every multi-thread run (2 threads and up) through
  the per-component block-level atomic scheduler instead of the special-case
  component-parallel path (one thread per component). Component-parallel was
  only load-balanced at exactly 3 threads and left a 2:1 imbalance at 2
  threads (~1.31x); on the 2048 noise image at 2 threads block-level
  balancing lifts decode from ~362 ms to ~291 ms (-19.5%). Scaling is now
  monotone across thread counts (the old path could make 3 threads
  accidentally faster than 4 via nested oversubscription, which would thrash
  on low-core machines). Single-thread and t10 are unchanged; byte-identical
  output verified across thread counts. Removes two now-dead worker types.

### Parallel Forward RCT

- The forward reversible color transform now splits its per-pixel work across
  the requested workers (bands aligned to the SIMD width, last band taking the
  scalar tail), the same "parallelize the phases the full-core DWT left as a
  serial tail" cleanup. Byte-identical to the serial transform (unit test
  across dimensions x worker counts). Measured encode t10 on the 2048 noise
  image (M4): ~123.6 -> 119.3 ms (-3.5% mean, reproducible across two A/B
  runs, and much tighter variance ±4.5 -> ±1.7); encode t1 unchanged. The
  inverse RCT (decode) was tried too but reverted — at ~3.4 ms the phase is
  too small for the thread-spawn + range-error-check overhead to pay off.

### Full-Core Parallel DWT

- The reversible 5/3 DWT now distributes each of the three components'
  per-level row and column bands across every requested worker instead of
  capping at three component threads. On multi-core machines the DWT phase
  was a large tail of threaded runs (forward DWT ~30% of encode t10, inverse
  ~13% of decode t10) with most cores idle. `wavelet_int.forward53Parallel` /
  `inverse53Parallel` keep the sequential per-level cascade but split column
  bands at SIMD-vector boundaries (final band takes the scalar tail) and row
  bands evenly, each worker with private scratch. Output is byte-identical to
  the serial workspace transform (unit test across 6 dimensions x 5 worker
  counts), so encode bytes and external interop are unaffected. Measured on
  a 2048x2048 noise image (Apple M4, 4P+6E): encode t10 143 -> 121 ms
  (-15.4%), decode t10 115 -> 110 ms (-4.2%); single-thread encode/decode
  unchanged (serial path untouched). See the optimization-plan history.

### Predictable Termination (ERTERM) Bring-up

- Added an ISO MQ ER-TERM flush path for `--terminate-all
  --predictable-termination`. The flush mirrors OpenJPEG/Grok's ERTERM
  treatment of the final guard byte, keeps standalone short MQ streams
  roundtrippable, and allows the public COD style byte `0x10` only when
  TERMALL (`0x04`) is also present.
- T2 segment-length handling now permits zero-byte terminated segments only
  through explicit segment metadata; the normal layer-delta path still rejects
  included zero-byte contributions. The ER-TERM final-byte handling now drops
  the non-payload trailing `0xff` case as well as the guard byte case, and a
  larger no-sidecar single-tile smoke decodes pixel-exactly through both z2000
  strict decode and Kakadu `kdu_expand`.
- Added `tools/interop_erterm.ps1` and ran the larger no-sidecar ERTERM smoke
  through OpenJPEG 2.5.4, Grok 20.3.6, and Kakadu 8.4.1 on
  `C:\temp\tools\images\0002.tif` and `0004.tif`; all three external decoders
  reconstructed the source pixels losslessly.
- Fixed the block-parallel strict decoder for TERMALL/ERTERM payloads: the
  worker now routes terminated code-blocks through the explicit per-pass
  segment decoder instead of the continuous MQ path. z2000 strict decode now
  reconstructs the same ERTERM smoke files losslessly at 16 threads, and the
  predictable-termination test covers the threaded path. The scorecard moves
  to 90/100 narrow and 66/100 full.
- Removed the obsolete tracked `sample.pgm` manual fixture; PGM support remains
  documented, but tests now generate their small fixtures directly.

### RESET+TERMALL Code-Block Style

- Opened COD style `RESET` (`0x02`) only in the implemented TERMALL ISO-MQ
  segment model: `--reset-context --terminate-all` resets JPEG2000 MQ context
  states between pass-terminated segments while preserving explicit T2 segment
  lengths. At that milestone, standalone RESET and BYPASS+TERMALL still
  remained fail-closed; BYPASS+TERMALL has since gained local strict coverage
  in the Unreleased T1 style section above.
- Added public roundtrip and strict COD mutation coverage. A larger no-sidecar
  single-tile smoke from `0002.tif` decodes pixel-exactly through z2000 strict
  decode, Kakadu, OpenJPEG, and Grok.
- Rechecked documentation against the row-level scorecard: the narrow RGB
  lossless JP2 target reached 89/100 and the broader Part 1 family reached
  63/100 before the later PLT-less foreign-stream and ERTERM interop gates.

### Foreign Stream Decode (Stage A)

- z2000 now decodes JP2 files produced by other encoders when they carry
  PLT packet lengths. The one missing profile piece was COD without
  precinct bytes (Scod bit 0 unset — the OpenJPEG/Grok default): the strict
  reader and the JP2 wrapper now map it to the ISO B.6 "no precinct
  partition" geometry (maximal 2^15 precinct, one per resolution) instead
  of failing closed. Verified pixel-lossless against the encoders' own
  decodes: OpenJPEG 2.5.4 and Grok 20.3.6 default configurations (LRCP,
  no precincts) plus RPCL, explicit precincts, 32x32 blocks with 4 levels,
  multi-layer rate-truncated ladders, and OpenJPEG 9/7 lossy (max-diff 1
  reconstruction agreement, identical to the z2000-encoded baseline).
- Stage B PLT-less foreign decode interop is now green for the current
  single-tile lossless profile. Real OpenJPEG 2.5.4, Grok 20.3.6, and Kakadu
  8.4.1 JP2 files were generated without PLT/TLM/SOP/EPH; z2000 strict decode
  matched both the source TIFF and each reference decoder byte-for-byte for
  default LRCP/no-precinct files, plus OpenJPEG/Grok `-r 20,10,1` multi-layer
  lossless-final ladders. The full scorecard estimate moves from 63/100 to
  65/100 by raising the lossless decode profile row from 8 to 10.
  Broader PLT-less foreign streams, especially multi-tile, remain a later
  matrix. Local oracle: splicing the precinct bytes out of a
  maximal-precinct z2000 stream decodes byte-exactly.

### Scalar-Derived Quantization

- Added `--qstyle scalar-derived` (ISO 15444-1 A.6.4) for the irreversible
  9/7 path: the QCD signals a single (exponent, mantissa) pair for the NL LL
  band and both sides derive every other subband step via E-5 (epsilon
  drops by one per resolution, mantissa shared). The fix that made external
  interop exact: the nominal bit-plane budget Mb (E-2) now derives from the
  *signalled* epsilon table — under derived quantization the expounded
  norm table would disagree with what decoders reconstruct, shifting
  zero-bitplane interpretation. OpenJPEG 2.5.4 reconstructs z2000
  scalar-derived output within max-diff 1 of z2000's own decode (identical
  agreement to the scalar-expounded baseline); Grok differs by its usual
  max-diff 3 reconstruction bias against both. jpylyzer reports valid JP2
  with `<qStyle>scalar derived</qStyle>`. Reversible + scalar-derived stays
  fail-closed.

### PCRD Refinements

- Layer byte targets now charge the real packet-header overhead: a probe
  assembly of the first allocation measures per-layer header bytes and one
  refinement round subtracts them from the budgets, so assembled layer
  sizes (headers included) land under the requested ladder (verified
  10603/21200/53157 against targets 10646/21293/53233 at rates 100/50/20).
- Parallelized the PCRD distortion extraction (the symbol-coder re-run)
  across code blocks with per-worker scratch; each slot writes a disjoint
  span, so the allocation stays byte-identical across thread counts
  (4-thread rate-targeted encode of the 1024x1024 fixture drops ~0.42 s ->
  ~0.15 s end to end).

### PCRD Rate Allocation

- Replaced the per-block proportional `--rates` split with a global
  PCRD-style allocation (ISO 15444-1 J.14). The symbol-based reference
  coder yields exact per-pass squared-error reductions (midpoint
  reconstruction model), weighted by (synthesis-basis norm x quantization
  step)^2 per band; `rate_alloc.allocatePcrdPasses` builds each block's
  convex hull over (bytes, distortion) truncation candidates and picks a
  global slope threshold per layer byte target. Runs single-threaded after
  the parallel block encode, so allocation is thread-count independent
  (covered by a determinism test). Layer payloads now land on the byte
  targets (the old split overshot the first layer by ~10x), and PSNR at
  matched sizes is within 0.2-0.4 dB of OpenJPEG's own PCRD (previous
  allocator trailed by 15+ dB at the first layer). BYPASS segment snapping
  is preserved via the existing truncation normalization; the full stream
  still decodes losslessly on the reversible path (opj/grk verified,
  jpylyzer valid).

### PCRL and CPRL Progressions

- Completed the Part 1 progression-order matrix: `--progression PCRL`
  (B.12.1.4) and `--progression CPRL` (B.12.1.5) order packets by precinct
  position on the image reference grid (upper-left corner scaled by
  `2^(levels - r)`), with component hoisted outermost for CPRL. Both are
  byte-preserving permutations of the RPCL packets built by a sorted
  sequence builder that now backs every non-RPCL order on both the encoder
  reorder and the strict-decoder slot walk. Position-major streams cannot be
  divided per resolution, so PCRL/CPRL always emit one tile-part. OpenJPEG
  2.5.4 and Grok 20.3.6 decode PCRL/CPRL output pixel-losslessly (1 and 4
  layers, plus dense 64x64-precinct/32x32-block configurations); jpylyzer
  confirms the signalled order. The undefined COD progression values 5+
  stay fail-closed.

### LRCP and RLCP Progressions

- Added the RLCP progression order (`--progression RLCP`, ISO 15444-1
  B.12.1.2) on top of the LRCP permutation machinery: a shared
  progression-aware stream iterator drives both the encoder reorder and the
  strict decoder slot walk. Resolution stays outermost in RLCP, so
  per-resolution R tile-part divisions remain valid for any layer count.
  OpenJPEG 2.5.4 and Grok 20.3.6 decode RLCP output pixel-losslessly (1, 4,
  and 4+BYPASS layers); jpylyzer confirms `<order>RLCP</order>` on valid
  JP2s. PCRL and CPRL stay fail-closed.

- Added the LRCP progression order (`--progression LRCP`, ISO 15444-1
  B.12.1.1) for the single-tile path. Packet bodies are order-independent
  (T2 coder state is per-precinct and layer order within each precinct is
  preserved), so the encoder emits the RPCL-built packets as a byte-preserving
  permutation into layer-major stream order; the strict decoder walks the
  stream with an LRCP slot iterator and permutes the packet catalog back to
  RPCL grouping for the unchanged downstream chain. Multi-layer LRCP encodes
  one tile-part (the stream cannot be divided per resolution); single-layer
  LRCP keeps R-divisions. The JP2 wrapper accepts progression 0/2; RLCP,
  PCRL, CPRL, and multi-tile LRCP stay fail-closed. OpenJPEG 2.5.4 and Grok
  20.3.6 decode LRCP output pixel-losslessly (1, 4, and 4+BYPASS layers) and
  jpylyzer confirms `<order>LRCP</order>` on valid JP2s.

### Interop Gates Closed

- Opened the JP2 wrapper profile validation to the code-block style bits the
  codestream layer already codes end-to-end (TERMALL `0x04`, CAUSAL `0x08`,
  SEGMARK `0x20`) and to disabled MCT (`0`), unblocking `--terminate-all`,
  `--vertical-causal`, `--segmentation-symbols`, and `--mct none` through the
  public `tiff-to-jp2` CLI. At that milestone, RESET (`0x02`) and ERTERM
  (`0x10`) still stayed fail-closed; accepted-profile and rejected-bit COD
  mutation tests were added.
- Passed the external interop gates staged in the next-steps history:
  OpenJPEG 2.5.4 and Grok 20.3.6 decode z2000 output pixel-losslessly for
  vertical-causal, segmentation-symbols, terminate-all, `--mct none`, and
  genuine multi-tile streams (2x2 aligned grid and 3x3 edge-tile grid), and
  jpylyzer reports every feature file as valid JP2.

### Multi-Tile Foundation

- Added a standalone JPEG2000 tile-grid helper for image/tile reference-grid
  geometry, including edge-tile rectangles for non-divisible dimensions and
  non-zero reference origins. Encoder and strict SIZ validation now use this
  shared geometry while still failing closed for real multi-tile payloads until
  per-tile DWT/T1/T2 state exists.
- Added tile-local RGB extraction and copy-back helpers with edge-tile
  roundtrip tests, giving future per-tile encode/decode scheduling a shared
  checked row-copy primitive.
- Added row-major tile descriptors and an iterator over the tile grid, including
  edge-tile classification for future tile work queues.
- Added a standalone tile-local RCT pipeline scaffold that transforms one tile
  descriptor into local RCT planes and roundtrips it back into the full RGB
  image without enabling multi-tile codestream output.
- Added in-place tile-local reversible 5/3 DWT and inverse-DWT scaffolding over
  the RCT tile planes, reusing the production integer wavelet workspace and
  roundtripping edge tiles in tests.
- Added a tile-local packet scaffold that derives subbands, code-block
  rectangles, and an RPCL packet plan for one transformed tile without emitting
  multi-tile codestream payloads yet.
- Added deterministic component-block job descriptors over the tile packet
  scaffold, giving future T1 scheduling an explicit component/block/band/rect
  iteration order.
- Added checked component-block plane views for tile-local T1 jobs, carrying a
  borrowed component plane, stride, and block rect in the shape expected by the
  existing EBCOT block encoder.
- Added an isolated tile-local ISO-MQ EBCOT component-block encode helper,
  byte-checked against the existing symbol-based EBCOT oracle while still
  leaving multi-tile packet emission disabled.
- Added a tile-local encoded block catalog builder that encodes every
  component-block job for one tile, owns the resulting EBCOT segments, and
  preserves deterministic component-major ordering for later T2 integration.
- Added tile-local quality-layer truncation metadata to each encoded block,
  using the same normalized `LayerTruncation` shape as the current RPCL packet
  writer so future per-tile T2 assembly can avoid recomputing block metadata.
- Added a borrowed tile-local `t2.EncodedLayerBlock` view over encoded catalog
  entries, including band-local leaf coordinates, EBCOT payload bytes, segment
  spans, and bitplane metadata for future RPCL packet assembly.
- Added a tile-local `RpclPacketIndex` that precomputes packet-sequence to
  code-block-index selections and maps those selections into the encoded block
  catalog, avoiding repeated per-packet code-block scans in the future per-tile
  T2 writer.
- Added tile-local RPCL packet band grouping with packet-local leaf coordinate
  normalization, producing borrowed `t2.EncodedLayerBlock` arrays that can
  initialize T2 tag-tree packet writer state.
- Added a standalone tile-local RPCL packet stream builder with packet and
  packet-header length tables, exercising real T2 packet-header and payload
  emission without enabling multi-tile codestream output yet.
- Added a tile-local RPCL packet stream readback validator that replays the
  emitted packets through T2 reader state and checks header lengths, decoded
  layer deltas, and payload slices against the shared encoded block catalog.
- Added an owned tile-local RPCL encode artifact wrapper that runs one tile
  through RCT, reversible 5/3 DWT, ISO-MQ EBCOT catalog construction, RPCL
  index creation, packet stream emission, and immediate T2 readback validation.
  This gives future multi-tile scheduling a single checked work item without
  enabling multi-tile codestream output yet.
- Added a deterministic tile-grid artifact builder that produces the same owned
  RPCL encode artifact for every tile in row-major order, providing a serial
  correctness baseline for the future persistent tile work queue.
- Added a parallel tile-grid RPCL artifact builder backed by an atomic tile work
  index. Results are written to their tile-index slots and tested byte-for-byte
  against the serial builder to preserve deterministic output.
- Added a deterministic cost-ordered tile work list for the parallel builder so
  larger tiles start first while output remains indexed in row-major tile order.
- Added a standalone tile-part layout derivation over tile-grid artifacts,
  computing one future tile-part per tile with packet counts, raw/framed packet
  bytes, PLT byte counts, and `Psot` values for later SOT/TLM/PLT writer wiring.
- Added a standalone TLM plan over tile-part layout entries, carrying 16-bit
  tile indexes and 32-bit `Psot` values plus marker byte-count validation for
  the future multi-tile writer.
- Added a standalone PLT plan over tile-part layout entries, grouping framed
  packet lengths per future tile-part and validating PLT marker byte totals
  against the computed `Psot` layout.
- Added standalone TLM and PLT marker-segment writers for the tile pipeline
  scaffold, with tests decoding the emitted bytes back to tile indexes, `Psot`
  values, and framed packet lengths.
- Added a standalone future tile-part byte writer over tile-grid artifacts,
  emitting `SOT`, optional `PLT`, `SOD`, and SOP/EPH-framed RPCL packet payloads
  while keeping real multi-tile codestream output disabled. Tests parse the
  generated tile-part bytes and compare packet payload slices back to the
  tile-local RPCL stream.
- Added a standalone tile-part sequence writer that concatenates all row-major
  future tile-parts, optionally prefixed by the derived `TLM` marker segment.
  Tests cover both TLM-present and no-TLM sequence buffers and compare each
  tile-part slice against the per-entry writer.
- Added an owned indexed tile-part sequence form carrying the emitted bytes,
  `TLM` span length, and per-tile-part offsets so future codestream assembly can
  use checked byte ranges instead of marker rescans.
- Added a standalone `SOC`/`EOC` codestream-fragment wrapper around indexed
  tile-part sequences, including validation that every `SOT/Psot` span matches
  the stored offsets. This keeps multi-tile output fail-closed while moving the
  scaffold closer to real Part 1 codestream structure.
- Added a matching strict parser for the standalone codestream fragment. It
  rebuilds the `TLM` span and tile-part offset map from bytes and rejects
  corrupted `SOC`, `EOC`, `SOT/Psot`, and `SOD` boundaries in tests.
- Extended the standalone fragment parser to decode explicit `TLM` entries
  (`Stlm=0x60`) and validate each tile index and `Psot` value against the parsed
  tile-part headers, with corrupt `Stlm` and TLM length regressions.
- Extended the standalone fragment parser to decode ordered `PLT` marker
  segments, expand variable-length packet lengths, and validate that each
  tile-part's PLT length sum exactly matches its `SOD` payload span. Tests now
  cover corrupt `Zplt`, packet-length bytes, and PLT marker corruption.
- Added parsed packet spans derived from those PLT lengths, exposing exact
  tile-part `SOD` payload slices for future strict T2 packet decode work.
- Added a standalone fragment-vs-grid-artifacts validator that checks parsed
  tile-part packet spans against the original tile-local RPCL streams,
  including SOP/EPH framing and corrupted packet-payload coverage.
- Added a raw RPCL stream extractor for parsed tile-part packet spans and a
  standalone fragment T2 readback validator that replays those reconstructed
  streams through the existing T2 packet reader state and tile-local EBCOT
  catalog.
- Added a marker-only parsed tile-part audit table with tile identity, `Psot`,
  PLT bytes, packet counts, framed bytes, and raw packet bytes. Tests now cover
  both SOP/EPH-framed tile-parts and no-framing tile-parts.
- Added full no-TLM standalone codestream-fragment coverage:
  `SOC -> SOT/PLT/SOD -> EOC` now parses, audits, validates against tile-grid
  artifacts, and replays through T2 readback without relying on `TLM`.
- Added an explicit single-part tile-order validator for the standalone
  multi-tile scaffold. It requires row-major tile indexes and exactly one
  tile-part per tile, with coverage for malformed tile order and tile-part
  count metadata.
- Added a tile-local encoded block catalog coverage validator and wired it into
  tile artifact construction. It checks that each component's code-block rects
  match the scaffold and cover the transformed tile plane exactly once.
- Added standalone tile-grid pixel reconstruction from encoded tile artifacts:
  direct-ISO T1 payloads decode through the inferred continuous ISO-MQ path,
  inverse 5-3 and inverse RCT run per tile, and the reconstructed edge tiles are
  copied back into the full RGB image in tests.

### Performance Instrumentation

- Added `decode-temp-jp2 --timings` and a public `DecodeTimings` profiling API
  for the supported strict JP2 decode path. The breakdown now separates JP2
  read, codestream extraction, metadata parsing, T2 packet catalog construction,
  T1 block payload reconstruction, inverse DWT, inverse MCT, ICC extraction,
  and TIFF write.
- Updated comparative benchmark scripts so `Z2000_THREADS=all` / `auto`
  resolves to all detected logical CPUs, including Windows environments via
  `NUMBER_OF_PROCESSORS`; profile benchmarks now default to the all-thread
  z2000 mode instead of a fixed three-worker run.
- Added `tools/bench_compare.ps1`, a Windows-native comparative benchmark for
  z2000, Grok, OpenJPEG, and Kakadu that uses `hyperfine --shell=none`, exports
  encode/decode JSON results, reports output sizes, and runs optional pixel
  checks when a Python with NumPy/Pillow is available.
- Switched the encode-side component block catalog builder from fixed contiguous
  worker ranges to an atomic block queue, matching the strict decode work-queue
  shape and improving all-thread encode load balance.
- Ordered encode-side block catalog work by estimated block cost before feeding
  the atomic queue, so large high-resolution code-blocks start earlier without
  changing deterministic catalog/output ordering.
- Flattened encode-side Y/Cb/Cr code-block catalog work into one cost-ordered
  atomic queue for `threads > 3`, keeping stable per-component catalogs while
  reducing the three sequential component payload phases.
- Sorted strict decode block work by payload size before feeding the atomic
  worker queue, reducing tail imbalance while keeping deterministic block
  scatter/output behavior.
- Reduced strict single-layer packet-catalog finalize overhead by storing
  decoded packet payloads in component-owned buffers and transferring those
  buffers into the block catalog instead of copying every code-block payload
  through an intermediate per-block `ArrayList`.
- Reduced strict single-layer packet-header assembly allocation churn by
  building short-lived T2 audit groups from a retained per-packet arena; the
  local timed decode split moved packet-header assembly from about 41 ms to
  about 32 ms on the 3520x5115 smoke file.
- Skipped full coefficient-plane zero-initialization for strict decodes whose
  packet block catalog has no zero blocks. On the local dense 3520x5115
  no-sidecar output, z2000 t16 decode measured about 548 ms with lossless
  output.
- Kept T1/MQ pass and branch profiling out of the normal strict decode hot path;
  worker T1 stats are now collected only when decode timings are requested.
- Added ReleaseFast T1 significance/refinement/cleanup decode paths for the
  common style without vertical causal mode; they derive candidate/context
  directly from the neighborhood flag word while Debug/ReleaseSafe keep the
  packed-context shadow assertions. On the local 3520x5115 smoke file, the
  combined shortcuts moved z2000 decode to about 3.58 s single-thread and
  566 ms with 16 threads.
- Added the matching ReleaseFast direct T1 refinement encode shortcut for the
  common non-vertical-causal style.
- Extended the ReleaseFast direct T1 encode shortcut to significance and
  cleanup passes. On the local 3520x5115 smoke file, z2000 encode measured
  about 3.35 s single-thread and 500 ms with 16 threads, with z2000,
  Grok/OpenJPEG/Kakadu decode all lossless.
- Fixed T2 packet-header termination when the final header byte is `0xff` by
  emitting and validating the required zero stuffing/padding byte; this aligns
  PLT packet lengths with Grok/OpenJPEG/Kakadu packet parsers on the current
  no-sidecar output.
- Updated the ISO scorecard after the current no-sidecar z2000/OpenJPEG/Grok/
  Kakadu lossless gate and jpylyzer 2.2.1 validity check: the narrow RGB
  lossless JP2 target is now estimated at 86/100 and the broader Part 1 codec
  family at 40/100. Validator warnings are treated as diagnostic leads rather
  than absolute failures, and ICC absence is acceptable when the source TIFF has
  no ICC tag.
- Split strict packet-catalog timing into scan, packet-header assembly, and
  final block-catalog materialization phases.
- Reduced packet-header assembly allocation churn by filling strict and legacy
  reader band-group block maps directly instead of allocating temporary
  location and occupancy buffers for each layer-zero packet.
- Reduced strict SOD packet scan overhead by pre-reserving the packet byte
  buffer per tile-part and by scanning only possible marker prefix bytes while
  validating unexpected SOP/EPH markers.
- Reduced strict packet-header assembly staging by appending decoded packet
  payloads directly into component assemblies instead of first storing temporary
  payload slices per audit band group.
- Skipped unnecessary decoded-block clearing for absent strict packets; the
  strict audit path now validates the absent packet length and returns before
  touching per-block temporary decode storage.
- Folded strict block-catalog validation/stat collection into final catalog
  construction, removing a separate assembly-wide pass from the serial finalize
  phase.
- Reused the validated per-tile-part packet payload byte count for strict SOD
  buffer reservation and span checks instead of summing PLT lengths again.
- Moved strict packet-reader band-group lists to fixed three-slot stack storage;
  legacy packet-reader lists are pre-sized to the same JPEG2000 bound and both
  paths reject malformed geometry that would exceed it.
- Skipped scratch pack/unpack copies for two-sample horizontal 5/3 DWT rows,
  where even/odd layout is already unchanged.
- Removed the unreachable non-renormalizing tail from ISO MQ decode MPS slow
  paths; after the fast-MPS and LPS tests, the remaining MPS case necessarily
  renormalizes.
- Updated the optimization roadmap after strict T2 profiling and MQ/DWT hygiene:
  LPT-by-payload scheduling is no longer prioritized, packet catalog is tracked
  as a smaller serial Amdahl term, and the next highest-leverage work is T1/MQ
  CPU cost, narrow packed-flag subpaths, horizontal 5/3 SIMD, and multi-tile
  scheduling.
- Split strict T1 significance candidate checks from zero-context lookup in the
  direct encode and inferred decode hot paths, so non-candidate samples avoid
  the extra context-table work while packed shadow parity checks remain active.
- Cached the current ISO MQ decoder byte across `byteIn()` calls, reducing
  repeated slice indexing in the renormalization path while preserving
  `reinitStream` segment restart behavior.
- Added portable SIMD shuffles to the horizontal integer 5/3 row lifting and
  pack/unpack steps, covering the repeated interior predict/update groups and
  low/high rearrangement used by both forward and inverse DWT.
- Batched T2 packet-header `readBits` consumption from the current byte instead
  of dispatching every bit through `readBit`, while preserving marker-stuffing
  validation at byte boundaries.
- Added pass-level T1 decode profiling for the strict ISO MQ/BYPASS path:
  significance, refinement, cleanup/RLC, and raw BYPASS passes now report
  CPU-sum timing, pass counts, and symbol counts across decode workers.
- Added strict block-payload worker balance counters to `decode-temp-jp2
  --timings`, reporting worker-job count plus max/average wall time, decoded
  blocks, and payload bytes.
- Added optional ISO MQ branch counters to the T1 decode timing profile:
  fast MPS, LPS, MPS-with-renormalization, renormalization shifts, and byte-in
  counts are aggregated per pass type without affecting non-profiled decode.
- Tightened ISO MQ branch-counter accounting by removing an unreachable
  profiled fast-MPS increment, documenting that profiled and unchecked decode
  transitions must stay in sync, and adding a test that profiled decode matches
  unchecked decisions while branch counters account for every symbol.
- Cached the ISO MQ state-table row inside each adaptive context, removing the
  per-symbol `state -> state_table[state]` lookup from the encoder and decoder
  hot loops while keeping the state index for diagnostics and reset parity.
- Batched ISO MQ decoder renormalization with a CLZ-derived shift count instead
  of shifting one bit per loop iteration; profiling still reports the logical
  number of renormalization bit shifts.
- Re-ran a short macOS 2048x2048 archival decode benchmark after the MQ context
  cache pass (`hyperfine --runs 5`, ten z2000 threads): z2000 decode of its
  current output measured 173.3 ms, Grok 85.6 ms on the same JP2, and OpenJPEG
  523.1 ms; `tiffcmp` confirmed pixel-lossless output for all three decoders.
- Reduced TIFF write overhead by reserving the exact output capacity and
  filling the 8/16-bit raster slice directly instead of issuing fallible
  appends per sample. The 8-bit output path now validates and narrows `u16`
  samples with the shared portable SIMD lane policy, while 16-bit output uses
  a native little-endian byte copy with an explicit big-endian fallback. A
  decode timing run on the 2048x2048 macOS sample showed the TIFF write phase
  at about 9 ms; the same output remained pixel-identical by `tiffcmp`.
- Vectorized TIFF 8-bit sample widening with the shared portable SIMD lane
  policy. A profiled encode pass on the 2048x2048 macOS sample reported TIFF
  read at 9.0 ms while preserving the existing RGB parser tests.
- Added a native little-endian byte-copy fast path for 16-bit TIFF strip reads
  with a scalar fallback for big-endian input/targets, plus a parser test that
  pins little-endian 16-bit RGB sample order.
- Added a big-endian 16-bit RGB TIFF parser test to pin the scalar endian
  conversion fallback used outside the native little-endian fast path.
- Added TIFF parser coverage for inline `SHORT` `StripOffsets` and
  `StripByteCounts` tags, matching another legal TIFF 6.0 encoding of small
  strip metadata.
- Added TIFF parser coverage for RGB data split across multiple strips, pinning
  offset/count array handling and sample-order continuity across strip
  boundaries.
- Added negative TIFF strip metadata coverage for mismatched `StripByteCounts`
  totals and truncated strip payload offsets.
- Hardened TIFF scalar metadata readers so `readU16` and `readU32` now
  bounds-check their offsets and return `TruncatedData`, improving ReleaseFast
  behavior for malformed tags and future parser changes.
- Added a public TIFF writer/reader roundtrip test for the optimized 8-bit and
  16-bit raster paths, plus negative coverage that the 8-bit SIMD narrowing
  path rejects out-of-range `u16` samples instead of truncating them.
- Tightened SIMD coverage so the TIFF 8-bit overflow test enters the vector
  narrowing branch and the ICT roundtrip test exercises vector-body plus scalar
  tail paths across NEON, AVX2, and AVX-512 lane widths.
- Tightened the TIFF raster append helper to restore the previous output
  length on validation failure.
- Added the first ISO MQ decoder fast-path slice: `mq_iso.Decoder` now exposes
  an inline unchecked read path, and EBCOT T1 decode dispatches ISO MQ reads
  through it while preserving the checked legacy MQ path.
- Kept the ISO MQ branch-counter wrapper out of the default hot loop: T1 pass
  dispatch hoists the per-block profiling flag once, then uses the unchecked
  decoder directly unless timing collection asks for detailed branch counters.
- Narrowed the direct T1 encode/decode decision helpers: significance and
  cleanup paths now compute sign coding only after a newly significant sample
  is known, MQ refinement computes only its membership and context, and raw
  BYPASS significance/refinement use even smaller membership predicates.
  Debug and ReleaseSafe builds still assert parity against the packed T1
  shadow state.
- Marked the tiny T1 index, row-mask, flag, and magnitude-bit helpers inline so
  the direct encode/decode loops keep those arithmetic operations local to the
  sample hot path.
- Reused the loaded coefficient value inside direct T1 significance and
  cleanup encode paths, avoiding duplicate plane indexing when the same sample
  needs both magnitude-bit and sign tests.
- Vectorized the irreversible ICT color transform with the shared portable SIMD
  lane policy: f32 lanes map to NEON-128 on AArch64 and AVX-family widths on
  x86_64 builds, with scalar tails covered for non-multiple pixel counts.
- Switched strict block-level decode workers from static contiguous block ranges
  to an atomic next-block scheduler so uneven code-block payloads balance better
  across decode threads.
- Added scratch-owned borrowed coefficient decode helpers for the strict ISO MQ
  and BYPASS paths, removing the per-code-block dupe/free cycle before
  scattering coefficients into the final component plane.
- Consolidated strict packet-catalog main-header scanning for COD/TLM/SOT,
  avoided a duplicate metadata parse when building strict block catalogs, and
  preallocated packet catalog entries from the RPCL packet plan. The strict
  metadata parser now also validates TLM entries during its existing main-header
  scan instead of running a second TLM-only pass, and the main decode path now
  reuses its already-parsed strict metadata when constructing the block catalog.
- Reduced strict SOD packet marker scanning from separate SOP and EPH searches
  to one pass that still rejects unexpected SOP markers and duplicate EPH
  markers while preserving EPH-before-payload packets.
- Kept legacy debug sidecar timing coarse while exposing the ISO/T2/T1 path
  phases needed for the next MQ decoder optimization pass.

### JPEG2000 Profile Handling

- Added fail-closed profile option handling for unsupported marker/payload
  combinations.
- Allowed only RPCL progression for now.
- Allowed only no tile-part division or resolution tile-part division (`R`).
- Rejected tile sizes smaller than the image until real multi-tile encoding
  exists.
- Distinguished RCT and ICT instead of mapping `ict` to generic MCT enabled.
- Added tests that reject unsupported LRCP/PCRL/CPRL progression, L/C/P
  tile-parts, scalar-derived quantization, invalid ICT/9-7 combinations, and
  multi-tile requests.
- Tightened the basic JP2 box reader for the supported `.jp2` profile:
  signature and `ftyp` ordering, `jp2 ` compatibility, RGB `ihdr`, sRGB `colr`,
  and one contiguous codestream are now validated fail-closed.
- Extended the JP2 box reader to accept standard Annex I codestream box lengths:
  `LBox == 0` for a final length-to-EOF box and `LBox == 1` with a 64-bit
  `XLBox`, with malformed/truncated XLBox coverage.
- Hardened JP2 big-endian numeric field reads so short box payloads return
  deterministic `InvalidBox` errors instead of relying on unchecked indexing.
- Kept `LBox == 0` fail-closed for nested JP2 header child boxes, so
  length-to-EOF remains a top-level final-box mechanism rather than silently
  consuming the rest of a superbox.
- Rejected empty contiguous codestream boxes in both JP2 wrapping and parsing
  so malformed `.jp2` inputs cannot pass metadata validation with a zero-byte
  `jp2c` payload.
- Tightened JP2 profile diagnostics further: `ftyp` now rejects any compatible
  brand outside the narrow `jp2 ` profile, and tests explicitly cover extra RGB
  components plus duplicate `colr` boxes.
- Added explicit JP2 header required-box regression coverage for missing
  `ihdr`, missing `colr`, and misplaced `colr` before `ihdr`.
- Added a narrow `jp2c` payload signature check: JP2 wrapping and metadata
  parsing now reject codestream boxes that do not start with `SOC` or end with
  `EOC`, while leaving full strict marker validation to the codestream reader.
- Extended that JP2 sanity check to the first `SIZ` marker: the reader now
  rejects codestream boxes whose width, height, component count, bit depth, or
  component sampling disagree with the JP2 `ihdr` metadata.
- Tightened the JP2 `SIZ` sanity gate to the current fail-closed profile:
  nonzero `Rsiz`, nonzero image origins, tile origins that differ from the image
  origin, or tile sizes that imply real multi-tile payloads are rejected until
  that path is enabled.
- Added explicit `SIZ` length validation in the JP2 container sanity check so
  malformed `Lsiz`/component-table combinations fail before metadata is trusted.
- Added a positive JP2 wrapper regression using a real z2000 lossless
  codestream, proving the stricter `SIZ` sanity gate still accepts normal
  encoder output and returns the exact embedded `jp2c` bytes.
- Added the same real-codestream JP2 `SIZ` sanity coverage for 16-bit RGB,
  including a negative `ihdr` bit-depth mismatch check.
- Added writer-side JP2 `SIZ` mismatch regressions so wrapping an image with
  codestream metadata for a different bit depth or image shape fails before
  emitting a container.
- Added real-codestream JP2 `SIZ` component-table regressions for signed
  components, mismatched per-component precision, and unsupported component
  subsampling.
- Consolidated the real-codestream JP2 test fixtures so the 8-bit and 16-bit
  `SIZ` sanity tests share one owned RGB fixture helper.
- Added a combined real-codestream JP2 + restricted ICC preservation regression
  that validates `SIZ` metadata, `jp2c` extraction, and ICC extraction together.
- Added a real-codestream JP2 negative ICC regression so empty restricted ICC
  payloads are rejected before emitting a `colr` box.
- Hardened JP2 codestream sanity checks so corrupted bytes immediately after
  the `SIZ` marker segment are rejected unless they start the next marker.
- Normalized malformed JP2 `XLBox` overflow handling to deterministic
  `InvalidBox` diagnostics.
- Added JP2 `ihdr` fail-closed regressions for unknown colorspace and
  intellectual-property flags in the narrow RGB profile.
- Tightened JP2 `ftyp` validation so nonzero minor versions fail closed for the
  current basic `jp2 ` profile.
- Added a lightweight JP2 codestream main-header walk so duplicate `SIZ`,
  premature `SOD`, malformed marker lengths, or non-marker bytes before the
  first tile-part are rejected before container metadata is trusted.
- Extended that JP2 main-header sanity gate to require `COD` and `QCD` before
  the first `SOT` in real tile-part codestreams.
- Tightened the same JP2 main-header gate to reject duplicate `COD` or `QCD`
  marker segments in the narrow single-profile codestream.
- Kept per-component `COC`/`QCC` main-header marker segments fail-closed in the
  JP2 wrapper/parser until their payload behavior is wired end-to-end.
- Kept additional profile-changing main-header markers (`CAP`, `RGN`, `POC`,
  `PPM`, `PPT`, and `CRG`) fail-closed at the JP2 wrapper/parser boundary.
- Changed the JP2 main-header sanity walk to a narrow whitelist: only `COD`,
  `QCD`, `TLM`, and `COM` are accepted before the first `SOT`; unknown
  length-segment markers now fail closed.
- Added a first-`SOT` sanity check in the JP2 wrapper/parser so malformed
  `Lsot` values are rejected before container metadata is trusted.
- Extended first-`SOT` sanity validation for the narrow single-tile profile:
  nonzero tile indexes, nonzero first tile-part indexes, unknown tile-part
  counts, zero `Psot`, and out-of-range `Psot` are rejected at the JP2 boundary.
- Added a lightweight first tile-part header sanity pass so JP2 wrapping/parsing
  requires a `SOD` delimiter after optional `PLT`/`COM` marker segments.
- Added JP2 boundary checks for minimum marker segment lengths on whitelisted
  `COD`, `QCD`, `TLM`, `PLT`, and `COM` segments.
- Tightened JP2 `TLM` sanity for the narrow single-tile profile: unsupported
  `Stlm`, nonzero tile indexes, malformed entry byte counts, and zero `Psot`
  entries fail closed.
- Tightened JP2 `PLT` sanity in the first tile-part header: empty length
  payloads and non-sequential `Zplt` indexes now fail closed.
- Added JP2 `COD` profile sanity for the current public path: reserved `Scod`,
  unsupported progression orders, zero layers, unsupported MCT flags,
  unsupported code-block style bits, malformed precinct payload lengths, and
  unknown transform bytes fail closed before container metadata is trusted.
- Extended JP2 `COD` sanity to reject oversized code-block exponents and
  code-block areas above the Part 1 limit used by the strict reader.
- Tightened JP2 `COD` MCT sanity so RGB codestreams with MCT disabled fail
  closed until `--mct none` has real payload behavior.
- Added JP2 `QCD` profile sanity so unsupported guard bits, scalar-derived
  quantization, invalid qstyle values, and band-count length mismatches fail
  closed at the wrapper/parser boundary.
- Added positive JP2 wrapper coverage for the public 9/7 ICT scalar-expounded
  codestream path so profile hardening keeps the irreversible RGB path green.
- Tightened JP2 codestream tile-part sanity so real z2000 codestream payloads
  audit every sequential `SOT` through `EOC`, reject hidden multi-tile indexes,
  skipped `TPsot` values, inconsistent `TNsot` counts, and missing final
  tile-parts while preserving the current resolution tile-part profile.
- Connected JP2-boundary `TLM` sanity to the audited tile-part sequence: `Ptlm`
  entries are now collected from the main header and checked against each
  corresponding `SOT/Psot` value in the current narrow profile.
- Tightened JP2-boundary `PLT` sanity for the same profile: tile-part `PLT`
  segments now parse JPEG2000 variable-length packet spans, reject unterminated
  length values, and require the summed packet spans to match the actual `SOD`
  payload byte count.
- Extended the same JP2-boundary packet audit to `COD/Scod` packet-marker
  policy: `SOP` and `EPH` framing must match the advertised flags across
  `PLT` packet spans, and `SOP` sequence numbers are checked before the
  codestream is trusted.
- Tightened JP2-boundary `QCD` sanity for the reversible 5/3 path: no-quant
  exponent bytes must now match the `SIZ` component bit depth and expected
  LL/HL/LH/HH subband gains before the codestream is trusted.
- Tightened JP2-boundary `QCD` sanity for the public irreversible 9/7 path as
  well: scalar-expounded step-size values must match the encoder's
  OpenJPEG-style 9/7 norm table and LL/HL/LH/HH band ordering.
- Tightened JP2-boundary `COD` sanity so real z2000 codestreams must carry
  explicit precinct size bytes in `Scod`; implicit/default precinct geometry
  remains fail-closed until it is wired through the RPCL/T2 profile.
- Tightened JP2-boundary `COD` layer-count sanity so quality-layer counts above
  the current rate-allocation/T2 fixed metadata limit fail closed at the
  wrapper/parser boundary.
- Reconciled the ISO coverage scorecard totals with the current row-level
  estimates: narrow RGB lossless JP2 is 86/100 and the broader Part 1 family is
  44/100; the TIFF reader hardening is robustness work rather than a new ISO
  coverage point.
- Tightened the JP2 wrapper writer to reject unsupported bit depths and RGB
  sample buffers that do not match `width * height * 3`.
- Tightened strict codestream metadata parsing for the supported packet path:
  SIZ component precision/sign/subsampling, single-tile geometry, COD layer
  count/segment length, and QCD ordering are now validated before T2 audit.
- Locked strict COD code-block style policy to fail-closed for every nonzero
  style byte; standalone EBCOT style tests remain internal until their payload
  behavior is wired through strict codestream decode.
- Defaulted normal encode to SOP-on and EPH-off for the current independent
  decoder interop path; explicit `--eph` remains available for packet-boundary
  diagnostics while EPH sequencing is hardened.
- Added the first ICC preservation slice: TIFF tag 34675 is carried as owned RGB
  image metadata, JP2 wrapping writes a restricted ICC `colr` box, `jp2-info`
  reports ICC presence/size, and `decode-temp-jp2` writes the profile back to
  TIFF without transforming pixel values.
- Added malformed ICC coverage for zero-length/truncated TIFF profile tags and
  unsupported restricted-ICC JP2 `colr` box variants.
- Added an ICC-absent TIFF-to-JP2 fixture test to keep no-profile RGB input
  explicit and valid without inventing a JP2 ICC profile.
- Recorded the current interop gate: no-sidecar/no-EPH output strict-decodes in
  z2000 and is accepted losslessly by OpenJPEG and Grok; Grok no longer reports
  PL marker length warnings after RPCL subband precinct projection was fixed.
- Added the first public irreversible profile path: ICT, ISO-scaled 9/7,
  scalar-expounded QCD, deadzone quantization, and inverse quantization for the
  narrow single-tile RPCL profile.

### Temporary JP2 Payload

- Advanced the private payload through BP5, BP6, BP7, and BP8 style metadata.
- BP5 records quality-layer allocation metadata.
- BP6 records EBCOT/MQ segment metadata for stats and future packetization.
- BP7 additionally carries actual EBCOT/MQ bytes while the temporary decoder
  still consumes the legacy bitplane payload.
- BP8 adds a shadow RPCL packet stream built from normalized packet-local
  code-block leaf locations.
- `jp2-stats` reports block, pass-stream, quality-layer, and EBCOT/MQ segment
  statistics plus shadow RPCL packet counts/bytes.
- For normal no-sidecar codestreams, `jp2-stats` now relies on strict SOD packet
  audit data instead of private BP metadata.

### T1 And MQ

- Added a standalone JPEG2000-style binary MQ coder module with context state
  table and marker-stuffing aware byte output.
- Added roundtrip tests for short, all-zero, all-one, alternating, and context
  reset symbol streams.
- Added EBCOT coding pass metadata and MQ-backed code-block segment assembly.
- Added direct MQ emission for code-block segments to avoid a separate symbol
  oracle on the hot path.
- Added scratch-buffer reuse for EBCOT direct encoding.
- Added cleanup pass run-mode symbols for full four-row clean stripes in both
  the symbol oracle and direct MQ T1 paths, with matching coefficient decode.
- Split EBCOT sign coding into JPEG2000-style horizontal and vertical sign
  contributions, including sign prediction and mixed-neighbor context tests.
- Added magnitude-refinement context selection for first refinement with and
  without significant neighbors, plus later refinement passes.
- Added standalone EBCOT segmentation-symbol cleanup trailers behind an
  internal code-block style flag, with direct MQ roundtrip and corruption tests.
- Added standalone EBCOT reset-context style support for continuous MQ segments,
  resetting probability states at coding-pass boundaries while preserving the
  continuous payload stream.
- Extended inferred continuous MQ/T1 payload decoding to honor the same
  internal reset-context and segmentation-symbol style state.
- Added standalone EBCOT vertical-causal context handling, ignoring south
  neighbors across stripe boundaries in the symbol oracle, direct MQ path, and
  coefficient decoder.
- Added style-aware partial coefficient decode helpers for direct and continuous
  EBCOT segments so quality-layer pass prefixes can be validated with the same
  internal code-block style state.
- Added standalone EBCOT terminate-all style support, writing pass-terminated
  MQ segments and decoding them through the continuous API when the internal
  style is supplied.
- Added explicit `CodeBlockStyle` metadata for all six COD code-block style
  bits. BYPASS is now wired through public codestream payloads for the ISO-MQ
  backend; the other style bits remain fail-closed until their payload behavior
  is implemented end to end.
- Tightened strict COD parsing so every nonzero code-block style byte remains
  `UnsupportedPayload` until that exact style is wired end-to-end through the
  writer, reader, tests, and interop gates.

### Quality Layers And Rate Allocation

- Added `rate_alloc.zig`.
- Added even layer allocation.
- Added compression-ratio target mapping.
- Stored per-code-block cumulative pass and byte truncation points.
- Connected layer truncation metadata to T2 packet delta helpers.
- Connected `--rates` to public quality-layer counts. Current allocation is
  byte-target based, so access-profile output can be larger and higher-PSNR
  than Grok/OpenJPEG for the same nominal compression-ratio ladder.

### T2 Packet Work

- Added packet-header bit writer/reader with JPEG2000 marker-safe stuffing.
- Added tag-tree encoder/decoder.
- Added tag-tree known-node state and rollback so continued packets do not
  re-consume already proven inclusion/zero-bitplane tag-tree bits after a
  successful threshold decision.
- Added code-block packet state, `numlenbits`/segment length state, and zero
  bit-plane handling.
- Added precinct packet writer/reader tests for first inclusion, continued
  inclusion, payload deltas, and truncated-payload rollback.
- Added RPCL packet iterator and direct packet lookup.
- Added precinct rectangle helpers and edge clipping.
- Added code-block selection helpers for RPCL packets.
- Added encoded-block to `LayerPacketBlock` bridge helpers.
- Added writer-state initialization from encoded blocks, including delayed first
  inclusion tests.
- Added a strict SOD-backed packet block catalog that reconstructs per-component
  code-block metadata, cumulative pass/byte counts, and owned payload views
  without requiring the BP8 debug sidecar.
- Normal no-sidecar decode now validates the strict packet block catalog
  instead of treating SOD bytes as a temporary payload; current T1
  reconstruction uses that catalog for the RPCL/RCT/5-3 roundtrip.
- BP8 debug validation now compares the public strict block catalog against the
  BP8 EBCOT catalog for geometry, cumulative pass/byte deltas, and payload bytes.
- ISO-MQ BP8 debug validation now uses the same strict SOD packet block catalog
  as normal no-sidecar decode for image reconstruction, while keeping byte-for-
  byte BP8 shadow-stream checks as the diagnostic oracle.
- Fixed RPCL code-block indexing so each block is assigned to one precinct cell
  instead of every intersecting precinct, avoiding duplicate first-inclusion
  state and reducing packet payload size on larger images.
- Fixed RPCL high-pass precinct projection so packet code-block selection uses
  subband-local low/high coordinates instead of transformed-plane offsets,
  aligning PLT packet lengths with Grok's packet parser.
- Fixed terminal `0xff` packet-header stuffing so PLT packet lengths also match
  independent decoder packet parsers when a packet header ends exactly on an
  all-ones byte.
- Strict main-header and tile-part readers now reject unsupported marker
  segments such as COC, QCC, POC, PPM/PPT, RGN, CRG, PLM, and CAP instead of
  silently skipping payload behavior that is not implemented.
- Tightened strict marker validation for the current no-sidecar path: SOT
  sequence/count, TLM tile indexes and Psot values, PLT packet spans, SOP/EPH
  policy and duplicate markers, and packet-header marker stuffing now have
  explicit regression coverage.
- Accepted ordered multi-segment TLM and PLT metadata in the strict reader while
  rejecting skipped marker indexes.
- Accepted tile-part COM marker segments as metadata before SOD.
- Added a metadata-inferred continuous MQ code-block decoder and wired complete
  single-layer strict RPCL reconstruction to use SOD payload bytes without
  relying on BP8 per-pass payload tables.
- Normal no-sidecar strict decode now reconstructs the current single-layer
  RPCL/RCT/5-3 path from the strict T2 block catalog, including zero-block
  geometry derived from codestream subband layout.
- Multi-layer lossless encode now uses continuous MQ code-block segments too,
  with quality-layer byte ranges snapped to actual coding-pass truncation
  points and mirrored consistently in BP8 debug metadata.

### Parallelism And Performance

- Added deterministic component-level encode/decode parallelism.
- Added encode-side code-block range scheduling for high thread counts.
- Reused scratch buffers in bitplane, entropy, and EBCOT paths.
- Added timing output for TIFF read, RCT, DWT, payload generation, JP2 wrapping,
  and disk write.
- Ran comparative local benchmarks against Grok, OpenJPEG, and Kakadu where
  available.
- Added `tools/bench_compare.sh` and `tools/compare_tiff.py` for local macOS
  benchmark and pixel-check workflows.
- Started the MQ fast-path optimization: direct ISO-MQ block encoding now
  finalizes codeword segments into the reusable per-worker payload buffer
  instead of returning a temporary owned slice. Raw BYPASS segments now use
  the same direct payload sink, MQ BYTEOUT keeps that active sink local through
  carry/marker handling, and the common MPS/no-renorm branch is split out in
  the ISO MQ encoder/decoder.
- Tightened continuous ISO/NBF decode state updates so inferred and BYPASS
  decode paths stop writing legacy per-sample `u8` flags when the packed
  neighborhood flags already carry the required significance/refinement state.
- Replaced generic scan-iterator use in raw BYPASS significance/refinement
  decode with direct stripe/x/dy loops matching the inferred ISO/NBF pass
  walkers, advancing packed-flag and coefficient indices incrementally inside
  each stripe column.
- Vectorized packed-neighborhood visit-bit clearing with the portable SIMD
  lane policy already used elsewhere in T1 scratch cleanup.
- Added word-granular T1 range skipping inside active 4-row stripes: inferred
  ISO-MQ and raw BYPASS significance/refinement passes now skip 64-column
  chunks whose row-significance window proves they cannot emit symbols.
- Added a guarded packed-column T1 cleanup-run cache prototype and measured the
  isolated RLC-only version as a regression on the local 2048 RGB lossless
  profile.
- Removed the measured-slower RLC-only packed cleanup-run cache and its scratch
  storage after the full OpenJPEG-style packed T1 context-word scaffold gained
  equivalent cleanup-run parity coverage.
- Added an OpenJPEG-style packed sigma/sign-window scaffold using the `3 * ci`
  shift layout, plus unit tests that prove zero-coding and sign-coding context
  parity with the current u16 neighborhood flags.
- Added PI/MU packed-bit parity tests for significance-pass membership,
  refinement-pass membership, and refinement context selection.
- Added an incremental OpenJPEG-style packed-word updater test that matches
  full rebuilds across block edges and 4-row stripe boundaries, covering sigma,
  CHI, PI, and MU state before the packed T1 hot path is enabled.
- Added packed ZC, SC, significance, and refinement helper parity tests against
  the current `u16` flag path for every subband and vertical-causal rows.
- Added a disabled packed T1 context-word scratch buffer/guard so the ZC/SC
  packed migration can be staged around the full OpenJPEG-style layout.
- Centralized packed T1 decision parity in helper functions and added a dense
  edge/stripe-boundary stress test covering all subbands and vertical-causal
  rows.
- Wired the disabled packed T1 context buffer into guarded visit, refine,
  significance, and per-bitplane visit-clear updates, with PI clear parity
  coverage against full rebuilds.
- Routed NBF/ISO significance, refinement, and cleanup context selection
  through shared T1 decision helpers, preserving the `u16` path while giving
  the packed guard a debug-checked loop boundary.
- Enabled Debug/ReleaseSafe packed T1 shadow maintenance with loop-boundary
  parity assertions, while keeping ReleaseFast free of shadow work unless the
  packed guard is explicitly enabled.
- Added a `-Dpacked-t1-context-flags=true` build option so the experimental
  packed T1 hot path can be tested and benchmarked without editing source.
- Added a cleanup-run eligibility helper over the full OpenJPEG-style packed
  T1 words, with parity coverage for PI blocking and vertical-causal
  stripe-boundary masking. The active cleanup-run hot path remains on the
  existing `u16` flags until the packed path is benchmarked as a shared
  ZC/SC/RLC replacement.
- Routed encode/decode cleanup-run candidate selection through scratch-aware
  helpers so a future packed T1 guard flip uses the shared packed context-word
  buffer.
- Routed decode cleanup-run sign-context selection through the shared T1
  decision helper after runlength decoding, extending packed shadow parity to
  the RLC decode corner and removing a local `u16`-only calculation.
- Added Debug/ReleaseSafe packed T1 shadow assertions for cleanup-run
  eligibility inside the real encode/decode RLC loops, while keeping ReleaseFast
  on the existing `u16` hot path unless the packed T1 guard is enabled.
- Removed the obsolete cleanup-sample `causal_row` plumbing now that
  vertical-causal handling is centralized in the shared T1 decision helpers.
- Removed the now-obsolete RLC-only cleanup-run cache test coverage; cleanup-run
  parity now lives on the full packed T1 context-word helper.
- Extended `tools/bench_compare.sh` with `ZIG_BUILD_FLAGS` so experimental
  build options can be benchmarked without editing source.
- Re-ran the local macOS 2048x2048 archival benchmark (`RUNS=3`, ten threads):
  z2000 encode 169.3 ms, decode 185.5 ms; Grok encode 109.9 ms, decode 78.0 ms;
  OpenJPEG encode 419.8 ms, decode 442.6 ms. `tiffcmp` confirmed pixel-lossless
  z2000 single-thread/ten-thread decode and Grok/OpenJPEG decodes of z2000
  output; the optional Python pixel checker was skipped because Pillow was not
  installed.
- Benchmarked the experimental packed T1 hot path with
  `ZIG_BUILD_FLAGS="-Dpacked-t1-context-flags=true"`: output remained
  lossless, but encode/decode regressed to 241.9 ms / 226.3 ms at ten threads
  and 918.1 ms / 837.2 ms single-thread, so the guard stays disabled by
  default.
- Updated the optimization roadmap to prioritize decode-side T1/MQ
  instrumentation, MQ decoder fast paths, block-level decode scheduling, and
  lower-maintenance packed T1 experiments before any packed hot-path default.
- Removed per-sample parity branches from integer inverse 5/3 unpacking by
  splitting low/high samples into separate even/odd loops for rows and columns.
- Added block-level strict decode workers for `--threads > 3`: each component
  validates block coverage first, then partitions code-block decoding across
  worker-local `DecodeBlockScratch` instances and scatters into disjoint rects.
- Changed the parallel strict decode coverage audit from a full per-pixel bool
  map to row-granular `u64` bitsets, reducing temporary RAM and validation
  memory traffic before worker scatter.
- Tightened RPCL packet assembly by preparing packet blocks directly from the
  cached encoded block table instead of allocating an intermediate
  `LayerPacketBlock` slice for every packet group/layer.
- Kept the small per-packet prepared group table on the stack for RPCL packet
  assembly, avoiding another heap allocation in the T2 hot path.
- Removed the now-redundant identity index table from encode-side RPCL band
  groups; encoded blocks are already stored in local tag-tree order.
- Removed the per-packet-group payload-slice array from RPCL assembly; payload
  slices are derived directly from encoded layer truncation points when needed.
- Applied the same payload-slice elision to the shared T2
  `appendPrecinctLayerPacket` helper, keeping only the packet-block array
  needed by the header writer.
- Removed the generic `appendRpclPacketForIndexes` `LayerPacketBlock` staging
  allocation; indexed RPCL helpers now prepare packet blocks directly from
  encoded layer blocks before writing payload bytes.
- Centralized T2 `LayerPacketBlock` to `PacketBlock` preparation so segment
  length validation is shared by precinct and indexed RPCL packet writers.
- Removed the extra worker-owned plane allocation/copy from the
  component-parallel strict decode path; workers now fill preallocated final
  Y/Cb/Cr planes while keeping temporary scratch state local.
- Changed strict decode scatter/coverage updates to operate row-by-row with
  slice copies and row coverage fills instead of per-sample destination writes.
- Tightened strict PLT parsing so a PLT marker segment that carries only an
  index byte and no packet lengths is rejected, with a malformed-codestream
  regression test that keeps SOT/TLM framing internally consistent.
- Added matching strict TLM malformed coverage for a TLM segment with `Ztlm`
  and `Stlm` but no tile-part entry payload.

### Documentation

- Added `docs/architecture.md`.
- Added `docs/changelog.md`.
- Added `docs/roadmap.md`.
- Added `docs/api.md`.
- Added `docs/iso_coverage.md` to track estimated progress toward the narrow
  RGB lossless JP2 target and the broader JPEG2000 Part 1 codec family.

## Initial Milestone

- Added grayscale PGM encode/decode for a custom `.z2000` codestream.
- Added reversible 5/3 and irreversible 9/7 wavelet experiments.
- Added multi-level decomposition and scalar quantization experiments.
- Added a narrow TIFF reader and JP2 box scaffold.
- Added reversible RCT for RGB.
- Added temporary RGB JP2 roundtrip back to TIFF.
