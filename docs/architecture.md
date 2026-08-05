# z2000 Architecture

This document describes the current implementation. Historical scaffold and
campaign notes are preserved in
[`archive/architecture-2026-07-14.md`](archive/architecture-2026-07-14.md).
Strategy and execution order live in `roadmap.md` and `next_steps.md`.

## System Boundaries

z2000 has two deliberately separate codec surfaces:

1. an educational grayscale `.z2000` format used by early wavelet experiments;
2. the ISO JPEG2000/JP2 path used by TIFF/BMP/PNG/JPEG conversion, strict codestream decode,
   interoperability, and benchmarks.

The ISO path is fail-closed. Marker parsing may recognize more syntax than the
payload pipeline supports, but a profile is accepted only when its transform,
quantization, T1, T2, tile, and container behavior agree end to end.
`src/profile_signaling.zig` centralizes the main-header `Rsiz`/`CAP`/`PRF`
prefix used by both raw codestream and JP2 validation. It enforces marker
ordering, exact capability-word cardinality, canonical extended-profile words,
and the `Rsiz` bit-14 CAP requirement. Only unrestricted Part 1 `Rsiz == 0`
currently reaches payload decode; all structurally valid extension/profile
declarations fail closed before reconstruction.

`src/main.zig` owns CLI routing and conversion policy, while
`src/cli_dispatch.zig` keeps extension inference independently testable.
Raw `.j2k`/`.j2c` to PGX dispatch selects one native component, while ZRAW
dispatch preserves every native plane and its geometry; neither assigns
colour semantics. `src/tiff.zig` and the
isolated format modules own source-file parsing; the bounded BMP adapter maps
24/32-bit BI_RGB storage into the same owned `RgbImage` encode boundary.
The PNG adapter maps checked gray/RGB/palette/alpha scanlines into the existing
decoded raster union only after CRC, zlib, filter, and sample-bound validation.
The JPEG adapter owns legacy marker/Huffman/DCT decode and exposes only its
bounded reconstructed gray/RGB raster; JPEG coefficients never enter T1/T2.
`src/jp2.zig` owns JP2 boxes and colour/
channel metadata. `src/codestream.zig` is the integration layer for JPEG2000
markers and the encode/decode pipeline.

## Data Model

`color.ComponentPlanesOf(T)` is the component-generic carrier used by integer,
floating, and unsigned sample planes. It records:

- reference image width and height;
- common precision or per-component precision;
- native width and height per component;
- one owned slice per component.

The bounded legacy carrier supports one to four components. `RgbImage`,
`GrayImage`, and TIFF alpha layouts are conversion-layer views over those
planes. Alpha semantics remain explicit through TIFF ExtraSamples and JP2
`cdef`; the codec does not silently associate or unassociate samples.

`src/native_samples.zig` is the G1 replacement foundation rather than an
extension of that fixed array. Its SIZ inspector retains `Rsiz`, reference and
tile grids, arbitrary caller-bounded component counts, component-local
origins/sampling, signedness, and every Part 1 precision from 1 through 38
bits. Owned planes use `i64`, so neither unsigned 38-bit samples nor signed DC
values require biasing into `u16`. Component count, reference pixels, and
total native samples are checked before allocation. Range validation is
explicit. PGX serialization is available where that diagnostic format has an
8/16/32-bit storage container. The project-private ZRAW carrier instead stores
all planes component-major with fixed metadata records and canonical
big-endian 1/2/4/8-byte words, preserving the complete 1..38-bit native model.
Its bounded parser validates reserved fields, dimensions, counts, sample
ranges, and exact end-of-file before returning owned planes. The strict payload
slice reconstructs single- and multi-tile reversible no-MCT signed/unsigned
1..29-bit components, including mixed component precision and independently
sampled component grids, through
the production T2/T1/5/3 path directly into these planes. Each tile retains its
absolute component grid during independent synthesis and checked assembly.
Full and requested lower DWT resolutions preserve reduced reference/component
origins and dimensions while pruning discarded packet bodies before partial
synthesis. Signed output receives no DC level shift; unsigned output receives
`2^(precision-1)`. Reversible native decode is caller-limited up to the
256-component strict metadata boundary and is independently pinned at 19
components across four tiles. Independent Kakadu fixtures pin
5/7/8/12/13/16/19/20/23/29-bit T1/DWT payload reconstruction. The signed
7/13/23-bit four-tile fixture also pins 1x1, 2x1, and 2x2 component sampling
at full and reduced resolution. The 29-bit four-tile
fixture reaches the current `i32` T1 boundary: reversible HH can add two
magnitude bits, while T1 admits at most 31. Native inverse lifting therefore
uses `i64` sums with checked `i32` stores for both full and reduced synthesis.
Component counts above 256 and precisions beyond 29 bits remain fail-closed
rather than being silently truncated; a 30-bit mutation pins the precision boundary. The legacy `u16`
decode surface deliberately still rejects signed input, accepts only 8/16-bit
precision, and retains `color.max_components` (four).

The first six strict-pipeline dynamization slices replace component-indexed
assembly, public block-catalog, packet-plan, geometry-set, and RPCL-index fixed
arrays, the strict metadata header and its COC/QCC parser state, and persistent
precinct-group slot tables, parallel component-job thread handles, and the
generic irreversible decode working tables with allocator-owned slices sized
to the active component count.
Catalog `deinit` owns both the outer metadata/slice tables and every component's
block/payload storage; packet plans and geometry sets likewise release their
outer collections after all nested state. Precinct groups release every active
tag-tree/lblock group before their per-component and outer slot slices. Direct
19-component tests pin storage, planning, SIZ parsing, persistent precinct
state, and full/reduced multi-tile native assembly beyond the historical slot count. Metadata
parsing is bounded at 256 components, matching the default native-sample limit
and the Part 1 one-byte COC/QCC selector range. A direct 19-job regression pins
the parallel runner beyond its historical slot count. Legacy colour and encode
carriers retain their intentional narrower bounds; the generic irreversible
output still uses the bounded legacy colour carrier and is not yet a public
greater-than-four-component profile.

Native component geometry is the strict decode boundary. Component upsampling
is a separate operation: `decodeLosslessPlanarUpsampled` performs
nearest-neighbour expansion anchored to absolute SIZ `XOsiz/YOsiz` and
`XRsiz/YRsiz`. It does not infer YCC or perform colour conversion. A selected
tile or reference region shares that anchoring: the selection resolves to one
absolute output rectangle, and the native decode covers a source window widened
by `XRsiz-1`/`YRsiz-1` and clamped to the image, because replication reads
`floor(reference/XRsiz)` rather than the window's own ceil-div origin.
Resolution reduction composes with it: ceil-div composition is associative, so a
reduced component grid is still the ceil-div of the reduced reference grid and
only the widening is scaled. The bounded sYCC display conversion uses the same
idea in `chromaAlignedSelection`, aligning the decoded window down to a chroma
boundary so the conversion sees the absolute phase of a complete image.
`color.interleaveRgb` is called only after the JP2 container has established a
bounded three-component sRGB interpretation.
Enumerated sYCC is equally explicit: `jp2.Info.color_space` records the selected
`colr` specification, while `Info.image_origin_x/y` and
`tile_origin_x/y` retain the SIZ registration. Native component decode remains
unchanged. `color.syccToSrgb` converts 8/16-bit 4:4:4, 4:2:2, or 4:2:0 native
planes directly at the JP2-to-TIFF boundary without materializing three
upsampled planes. For an odd sampled image origin, missing leading chroma
positions use code zero; 4:2:0 also preserves the pinned OpenJPEG two-row edge
phase. Component geometry is still checked before conversion.
CMYK (12), default-parameter CIELab (14), e-sRGB (20), and e-sYCC (24) stop at
an explicit preservation boundary. `jp2.Info.color_space` records the selected
interpretation and `jp2.wrapPlanarColorCodestream` can emit matching
full-resolution native planes, but neither path converts them to RGB. Sampled
e-sYCC is accepted on the same bounded geometry as sYCC and remains planar.
The TIFF command rejects all four rather than silently interleaving their
samples as RGB or treating CMYK's fourth channel as alpha.
`src/icc.zig` owns the separate ICC conversion boundary. It parses only bounded
ICC v2/v4 RGB matrix/TRC profiles with PCSXYZ and converts an already-decoded,
full-resolution 8/16-bit `RgbImage` to sRGB. The codestream and native component
planes remain unchanged; conversion is opt-in through
`decode-temp-jp2 --convert-to-srgb`.

## Encode Pipeline

The production encode path is:

```text
TIFF/sample planes
  -> validation and component layout
  -> RCT, ICT, or independent DC level shift
  -> per-tile 5/3 or 9/7 DWT
  -> quantization/no quantization
  -> code-block catalog and EBCOT coding passes
  -> quality-layer truncation / global PCRD allocation
  -> T2 packet headers and payloads
  -> tile-part markers, PLT/TLM/POC/PPM/PPT as selected
  -> main codestream markers and EOC
  -> JP2 boxes and metadata
```

The encode-side block catalog is shared: bitplane metadata, T1 segments, pass
distortion/length data, layer truncations, and packet payload views are derived
once per block. Packet writers consume precomputed progression indexes instead
of rescanning all blocks.

Multi-tile encoding is production code, not a scaffold. Each tile owns its DWT
geometry, block catalog, packet state, and tile-part output. Global PCRD chooses
one cross-tile threshold for image-level rate targets before deterministic
packet assembly.

## Strict Decode Pipeline

The strict no-sidecar path is:

```text
JP2 box audit and jp2c extraction
  -> SIZ/COD/COC/QCD/QCC/POC metadata validation
  -> SOT/TLM/Psot tile-part walk
  -> PLT spans or open-ended T2 header-derived spans
  -> persistent packet/tag-tree/numlenbits state
  -> strict block catalog with style metadata
  -> T1 segment decode
  -> dequantization and inverse DWT
  -> inverse MCT or independent level shift
  -> native component planes
  -> optional explicit upsampling/colour/container conversion
```

`src/tlm.zig` supplies the allocation-free TLM segment view shared by raw and
JP2 validation. It decodes all Part 1 ST/SP widths, concatenates implicit
`ST=0` tile indexes across increasing `Ztlm`, and rejects reserved fields,
non-canonical tile indexes, short lengths, and partial entries before the SOT
walk proves exact tile/`Psot` agreement. The SOT reconciliation is what
enforces the `ST=0` one-part-per-tile, raster-order restriction.

SOP and EPH are validated at their signalled locations. PPT and PPM headers are
normalized into the same unframed packet view as inline headers. PLT-less
single-part streams derive payload spans from decoded packet headers; supported
multi-part layouts maintain tile-local packet state across parts.

The shared multi-tile selection window maps either one row-major tile or an
absolute SIZ `x0,y0,width,height` region onto the tile grid. Stage B and the
stateful T2 walk still visit every tile-part. Tiles outside the window retain no
code-block bodies and do not enter T1, inverse DWT, or inverse MCT; intersecting
tiles are reconstructed independently and only their reduced intersection is
copied into the bounded RGB, planar, or native output. Component intersections
use `ceil(reference/XRsiz)` followed by the requested DWT reduction, so
nonzero origins and subsampling retain their absolute phase.

Single-tile streams share that validation and the same component intersection
arithmetic. Inside every decoded tile, the catalog derives per-resolution
coefficient windows by following the subband recursion from the component-local
intersection and expanding each step by a conservative inverse-DWT synthesis
margin. Code blocks outside those windows keep their geometry, lengths, and
segmentation — the coverage audit still requires a complete partition — but are
never entropy-decoded, and their zero coefficients are exact because the inverse
DWT is linear with finite support. Packet assembly derives the same windows
through the shared `StrictRegionBandWindows`, so a pruned block's payload is
never appended to its component-owned buffer either; a disagreement between the
two would leave a required block without payload and fail closed.
Because coefficients outside the window are deliberately incomplete, region
decode saturates intermediate samples to the declared range exactly like the
resolution and quality-layer selectors.

All three bounded multi-tile output loops — planar, interleaved RGB, and native
— hand each reconstructed tile to a tile sink instead of owning the output
raster. A sink receives the complete window once through `begin`, with
per-component layouts on the planar and native paths and a single common grid
on the RGB path, which is fixed at three components. It then receives one
window per non-empty selected tile through `writeTile`, in codestream tile
order and in absolute reduced coordinates. The planar and RGB windows borrow
the tile raster with a stride; the native path converts `i32` coefficients into
level-shifted, range-checked `i64` samples on the way out, so its windows are
materialized per tile into tile-sized buffers instead, and that conversion is
where the declared sample range is enforced.

`decodeLosslessPlanarWithOptions`, `decodeLosslessTemporaryWithOptions`, and
`decodeLosslessNativeWithOptions` are each one sink over their own loop:
`AssemblingPlanarTileSink`, `AssemblingRgbTileSink`, and
`AssemblingNativeTileSink` allocate the whole output from `begin` and copy each
window into place. The whole-raster and streaming shapes therefore cannot
diverge in what they accept or produce; the profile gates themselves are shared
through `checkStrictPlanarProfile`, `checkStrictRgbProfile`, and
`checkStrictNativeProfile`, and the RGB path additionally shares its private
BP8 sidecar shortcut through `legacyTemporaryRgbImage`. A single-tile stream
reports one region, so the contract is total across tile layouts.

The reference-grid upsampled path takes a banded contract instead, and the
arithmetic forces it: replication reads the component sample at
`floor(reference/XRsiz)`, which for a subsampled component sits one sample
outside a tile's own ceil-div window, and the edge clamp would silently
substitute the tile's first sample there. A per-tile contract would therefore
disagree with a full decode at every internal tile boundary of a subsampled
image. A band spans the full requested width and one complete SIZ tile row, so
it can widen its source window the way a whole-image decode does; each band is
produced by the unchanged whole-image upsampling path with the band as its
`reference_region` and is by construction the matching crop. The cost is that
the widening reaches one reference row into the tile row above, so a subsampled
multi-row grid reconstructs that tile row again for the next band.

The planar surface accepts multi-tile reversible no-MCT RPCL with or without
subsampling; the per-tile machinery was always generic, and its reconstruction
now consumes component-local COC decomposition counts through
`componentLevelsForHeader` rather than the header count, matching the native
path.

`decodeLosslessPlanarBandsToSink` offers the same banded shape without
replication, for consumers that place rows rather than tiles. Its bands stay on
the native component grids, so a subsampled component window is its own ceil-div
intersection of the band; because nothing is replicated there is no source
widening and no tile is decoded twice.

The CLI conversion boundary consumes the banded contract for the layouts where
both ends would otherwise be held whole. A subsampled three-component
JP2 with no palette, no sYCC conversion, and no requested sRGB conversion is
decoded band by band into `tiff.RgbBandSink`, which interleaves each band and
appends it through the streaming `tiff.RgbBandWriter`. The bounded RGB TIFF
layout makes that possible: every offset follows from dimensions, precision,
and ICC length, so the header can be written before any raster byte exists.
The streaming and buffered writers share `RgbLayout` and the raster
serialization, and the interleave shares `color.interleaveRgbSamples` with the
whole-image path, so the streamed file is byte-identical. A one-component
conversion streams the same way through `tiff.GrayBandWriter`; because a
multi-tile reversible no-MCT grayscale stream is not a supported decode profile,
that case currently resolves to one band, so the benefit is the unbuffered file
rather than an unbuffered raster. Every other layout keeps the whole-raster
path.

Codestream input is still read whole and a selected tile still runs a full
inverse DWT into a full-tile plane, so those are the remaining memory
boundaries.

The former BP8 COM sidecar is not part of normal output. It remains an optional
debug/compatibility oracle for tests and old fixtures.

## T1 And MQ

`src/ebcot.zig`, `src/mq.zig`, and `src/mq_iso.zig` own coding-pass behavior and
binary arithmetic coding. The direct ISO MQ backend is the production default.
The implementation includes significance propagation, magnitude refinement,
cleanup run mode, sign prediction/context formation, byte stuffing, pass
metadata, partial layer reconstruction, and the six Part 1 code-block style
bits.

All style bytes `0x00..0x3f` are covered on the public ISO-MQ path, including
BYPASS, RESET, TERMALL, vertical causal, predictable termination, segmentation
symbols, and their combinations. Segment construction and decode are driven by
the style carried from COD/COC through the strict block catalog. The legacy MQ
backend retains a narrower fail-closed contract.

T1 work is block-parallel, but the MQ state inside one arithmetic segment is
serial. SIMD work therefore targets coefficient scans, masks, DWT,
quantization, colour transforms, and other independent lanes rather than
changing MQ symbol order.

## T2 And Progression

`src/t2.zig` owns packet-header bit I/O, inclusion and zero-bitplane tag trees,
code-block packet state, pass-count coding, segment lengths, and layer deltas.
`src/packet_plan.zig` owns progression traversal and component/precinct packet
indexes. `src/poc.zig` validates and builds progression changes.

Packet state is persistent per tile, component, resolution, and precinct.
Inclusion trees, zero-bitplane trees, known-node state, `numlenbits`, cumulative
passes/bytes, and payload cursors survive layer and tile-part boundaries.

All five Part 1 progression orders are public on their documented profiles.
Direct tile-part divisions are supported when packet order makes the requested
axis contiguous: resolution (`R`), layer (`L`), component (`C`), and position
(`P`). POC schedules must form a complete checked packet visit sequence.

## Component Sampling

Bounded sampled decode uses a distinct component geometry for each
`XRsiz/YRsiz` pair. Each geometry owns sampled bounds, subbands, code-block
locations, RPCL precinct indexes, inverse-DWT origin, and output dimensions.
`sampledOrderedPackets` projects component-local precincts onto reference-grid
positions and provides all five Part 1 orders; canonical RPCL is its default
specialization.

The primary sampled decode profile is no-MCT, reversible 5/3, RPCL, one or more
tiles, inline/PPT/PPM packet headers, all SOP/EPH combinations, independent
image and tile-partition origins, and checked POC in the main or first
tile-part header.
POC intervals may use any Part 1 progression and must cover every packet once.
PLT-less and packed-header state is component-local. Bounded sampled PPM+POC
uses one checked `Nppm` group per codestream-order tile-part while the complete
main- or first-tile-header POC schedule supplies packet identity; single- and
multi-tile one-part-per-tile streams are covered.

The sampled writer emits single- and multi-tile canonical RPCL with inline
PLT/PLT-less, PPT, or PPM packet headers, SOP/EPH framing, and one or more
untargeted quality layers. Each tile-component is cropped on
the component grid, transformed with its absolute origin, encoded through the
shared one-component machinery, and merged with the same sampled RPCL sequence
consumed by strict decode. Both single- and multi-tile framing delegate to the
common inline/PPT/PPM helpers and never rebuild T1 artifacts for a layout.
Reordered POC permutes those complete packet views. Strict T2 detects whether
layers remain precinct-contiguous; canonical streams retain the one-active-
precinct fast path, while reordered schedules use persistent per-precinct
inclusion, zero-bitplane, and `numlenbits` state.
The public strict packet diagnostic follows the same per-tile sampled catalogs
and rebases only their normalized byte storage when returning a whole-stream
view, so it does not maintain a second geometry or T2 parser.

The bounded G2 tile-override path records first-part `COD/QCD` and component-
specific `COC/QCC` into per-tile effective state. The Stage B packet-plan walk
and Stage C catalog/T1/DWT reconstruction use allocator-owned coding and
quantization tables for every tile/component; marker replay must equal those
tables. The current envelope is no-MCT RPCL with common layers, and no
effective decomposition count may exceed the main header.
It accepts one part per tile, PLT-backed RPCL resolution/padding parts, and the
same divergent reversible COC/QCC state through bounded packed layouts:
multipart PPT with PLT or PLT-less PPM without POC, including multiple parts
per tile. Inline PLT-less multipart state is likewise component-local. A
separate one-part-per-tile no-MCT 9/7 profile consumes
scalar-expounded main, tile, and component QCD/QCC tables through native planar
full/reduced reconstruction. A bounded single-tile profile
dispatches each no-MCT component through its effective COC transform and QCC:
reversible planes use checked integer 5/3 synthesis while irreversible planes
use their scalar-expounded steps and float 9/7 synthesis. Components may also
diverge in decomposition count, precincts, and block geometry; reduced catalog
compaction and both inverse transforms consume the same effective component
table. The same dispatch now applies after tile-header `COD/QCD`: a directly
emitted four-tile stream keeps three tiles on reversible 5/3 and switches tile
1 to scalar-expounded 9/7, with independent full/reduced synthesis before
absolute-grid assembly. Transform/quantization mismatches fail before packet
reconstruction. Strict component geometry derives an effective code-block
dimension for every subband by clamping the nominal COD/COC dimension to the
precinct-induced B.7 span. Decode and all bounded lossless encode front ends
share that T2-owned calculation; block catalogs and packet tag-tree grids use
the effective dimensions while COD retains the requested nominal size. The
same effective table now proves all three override levels in one directly
emitted four-tile stream: main reversible `COD/QCD`, tile 1 irreversible
`COD/QCD`, and tile 1 component 1 reversible `COC/QCC`. PLT-less multipart PPM
without POC is supported. PPM+POC is additionally supported for the bounded
sampled one-part-per-tile profile; general multipart POC and packed-header/TLM
combinations remain fail-closed.

Inline PLT-less multipart streams carry no packet count at the Stage B frame
scan. Their spans therefore retain an explicit deferred-count state and exact
`Psot` boundary. Stage C resumes the tile-local packet sequence and persistent
inclusion/zero-bitplane tag trees plus `numlenbits` state, decodes headers until
that boundary, and validates the accumulated count against the full tile plan.
PLT-less multipart PPM uses the same deferred state: the corresponding `Nppm`
group bounds packed headers while `Psot` bounds packet bodies, and the joined
tile still must consume its complete effective packet sequence exactly.
This also handles interleaved tiles, `TNsot == 0`, and empty padding parts;
hybrid or inconsistent PLT accounting is malformed.

Conformance decode distinguishes output image components from codestream image
components. The normal path applies the profile's inverse component transform;
the currently bounded diagnostic path covers RCT and stops
after inverse DWT and unsigned component formatting, which lets T.803 class-0
PGX references compare at their specified pre-MCT boundary without changing
normal RGB semantics.

Resolution reduction follows that same geometry. For sampled multi-tile 5/3
and bounded no-MCT 9/7,
each tile-component selects retained packets, skips discarded T1 blocks, and
performs partial inverse synthesis at its absolute component origin. The 9/7
path additionally dequantizes only retained bands. Assembly
first maps the clipped reference tile through `XRsiz/YRsiz`, then reduces those
component coordinates; this preserves odd image, tile, and sampling phases
without synthesizing or upsampling a full raster.

Quality-layer selection is an earlier filter on the same strict catalog rather
than a second packet parser. T2 walks the complete progression schedule and
updates inclusion, zero-bitplane, pass-count, and length state for every packet,
so malformed later layers still fail closed. Only bodies from the requested
leading layer prefix are appended to each block assembly and scheduled for T1;
the later checked spans are counted as discarded. This applies per tile before
the existing transform and absolute-grid assembly paths, and composes with
resolution selection. A zero limit means the complete signalled layer set.

Tile selection moves the output boundary to one clipped row-major SIZ tile.
The shared multi-tile Stage B state machine still scans every SOT/`Psot`, TLM,
PLT/PLM, PPM/PPT group, and tile-part override. Stage C builds and audits each
tile's stateful T2 catalog in turn, but only the selected tile retains code-block
bodies and enters T1, inverse DWT, and inverse MCT. RGB and planar outputs use
the selected reference rectangle as local output origin; native planes retain
its absolute reduced component coordinates. This avoids full-raster allocation
and composes with layer-prefix and resolution selection.

The irreversible planar backend reuses the same strict block
catalog without interleaving through a temporary RGB image. Each component owns
its quantized coefficient plane, effective QCD/QCC-derived subband steps, float
9/7 inverse job, reduced shape, and final precision saturation. The normal
surface covers no-MCT output; the conformance surface also exposes pre-ICT
codestream components for bounded three-component ICT streams, preserving
component-specific QCC state. Bounded component jobs share the existing worker
runner, while nearest-integer output matches the established interleaved
no-MCT reconstruction exactly. A genuine Kakadu ICT/9/7 stream pins distinct
QCC mantissas for components 1 and 2 at full and reduced resolution, while a
reserved `Sqcc` mutation fails before T1 allocation. Multi-tile sampled no-MCT
9/7 invokes that same
backend per tile-component and assembles reduced native planes without
upsampling them to the reference grid. Its packet-layout gate starts from an
independent Kakadu PLT-less codestream and moves only the T2 headers into PPT
or PPM framing; the foreign T1 packet bodies remain byte-identical. All three
layouts share the same full/reduction-1 PGX bounds and corruption checks, but
the repacked PPT/PPM framing is not claimed as independently encoded.

The G2 packed-override gate uses the same separation of evidence. Kakadu
supplies independent PLT-less one-part and resolution-part COC/QCC streams;
the test repacker preserves their tile headers and T1 bodies while moving only
packet headers into PPM or PPT. This pins packed-header consumption without
mislabeling the structural framing as independent encoder interoperability.

## JP2 And Metadata

`src/jp2.zig` validates the JP2 signature, `ftyp`, `jp2h`, `ihdr`, optional
`BPCC`, supported `colr`, bounded `pclr`/`cmap`/`cdef`, resolution boxes, and
exactly one contiguous codestream. Required ordering, duplicate boxes, lengths,
component precision, sampling, and SIZ agreement are checked.

Restricted ICC profiles are preserved byte-for-byte by default. Preservation is
not colour conversion. Enumerated sYCC (18) is recognized for three unsigned
uniform 8/16-bit components; the CLI converts 4:4:4, 4:2:2, and 4:2:0
input to sRGB. Opt-in ICC conversion accepts only full-resolution RGB matrix/TRC
profiles with PCSXYZ. Unsupported JPX composition, invalid sampled geometry,
non-default CIELab parameters, LUT/general ICC interpretation, and unknown
component mappings fail closed. CMYK, default CIELab, e-sRGB, and e-sYCC
signalling preserve native planes but deliberately have no TIFF/sRGB conversion
yet.

EXIF, XMP, and IPTC are separate opaque metadata families at this boundary.
`attachMetadata` validates standalone classic-TIFF EXIF, UTF-8 XML XMP, and
complete IPTC-IIM framing, then inserts canonical UUID boxes immediately before
`jp2c` without rewriting the codestream. `extractMetadata` recognizes canonical
and deployed alternate identifiers, returns owned byte-exact payloads, and
rejects duplicate families. The first source wiring strips only the standard
JPEG APP1 identifiers and the Photoshop APP13 IPTC resource wrapper. Semantic
tag interpretation, extended XMP assembly, general Photoshop resources, ICC
APP2 mapping, and JP2-to-TIFF restoration remain outside this bounded slice.

The bounded LinearRaw DNG input adapter shares only checked classic-TIFF IFD
value access with the general TIFF reader. It independently selects one raw
IFD, validates uncompressed chunky 8/16-bit RGB strips, applies DNG
linearization/black/white normalization, and derives `CameraToXYZ_D50` from
the one-illuminant `ForwardMatrix1` and `AsShotNeutral` path. A generated ICC
v4 matrix profile carries that linear interpretation through JP2; conversion
to display sRGB remains the existing explicit ICC boundary.

The bounded OpenEXR adapter is independent of TIFF/DNG parsing. It validates
the version flags and nine allowed header attributes, exact B/G/R HALF channel
layout, offset table, one uncompressed chunk per scanline, unique y coverage,
contiguous non-overlapping chunks, and normalized finite samples. Explicit RGB
chromaticities are converted to PCSXYZ D50 with Bradford adaptation and the
same generated linear ICC carrier. This makes the current `[0,1]` subset
deterministic while keeping HDR, negative, alpha, arbitrary-channel, tiled,
compressed, multipart, deep, and metadata-bearing EXR fail-closed.

## Parallelism And Memory

Persistent worker pools execute independent tile, component, DWT, colour, and
code-block jobs where profiling justifies the overhead. Work completion order
never determines packet order; final assembly is deterministic by tile and
packet index. Per-worker scratch buffers and wavelet workspaces are reused.

Portable Zig `@Vector` code is the SIMD baseline. Lane widths and generated code
are audited for x86 AVX2/AVX-512, ARM NEON, and RISC-V/RVV behavior, with scalar
oracles and cross-target tests. Architecture-specific paths must retain scalar
fallbacks and identical results.

All lengths, offsets, component counts, tile counts, and allocations are checked
before use. Corruption tests cover truncation and byte mutations across JP2,
markers, packet headers, tag trees, segment lengths, and T1 payloads in Debug,
ReleaseSafe, and ReleaseFast configurations.

Tile and region selection bound final raster allocation, avoid T1/DWT work for
non-intersecting tiles, and skip both T1 and payload materialization for code
blocks a selected region cannot reach inside the tiles that are decoded. The
output end is pushed rather than buffered: the tile and band sinks hand each
decoded window to the caller, and the CLI conversion path writes bounded TIFF
layouts through streaming writers. What remains is streaming codestream input
and reducing a selected tile's full-tile synthesis plane; those are the last G4
memory-scaling boundaries.

## Verification Ownership

- focused unit tests live beside the imported modules through `src/tests.zig`;
- full build gates are listed in `next_steps.md`;
- external decoder evidence is summarized in `iso_coverage.md`;
- reproducible speed measurements belong in `benchmarks.md`;
- strategy changes update `roadmap.md`, while completed work updates
  `changelog.md`.
