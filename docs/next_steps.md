# Next Steps

This is the only active implementation queue. Strategic policy is in
[`roadmap.md`](roadmap.md); completed plans and campaign detail are in
[`archive/`](archive/README.md).

## Current State

- The bounded ISO scorecards remain 100/100 within the envelope documented in
  [`iso_coverage.md`](iso_coverage.md).
- Sampled RPCL/no-MCT/reversible-5/3 strict decode supports native planes,
  PLT/PLT-less inline headers, PPT, PPM, SOP/EPH, matching shifted origins,
  single/multi-tile streams, canonical main/tile-header POC, and explicit
  reference-grid upsampling for bounded sRGB JP2-to-TIFF.
- PRs #150–#153 closed the sampled packed-header decode campaign. Repacked
  Kakadu fixtures prove inline/PPT/PPM structure and corruption handling;
  z2000 sampled output decoded by OpenJPEG and Grok supplies independent
  cross-codec evidence for the common sampled packet/T1 path. A native packed-
  header fixture from an independent producer remains useful matrix breadth,
  not a blocker for the next slice.
- PRs #154–#155 added sampled reversible encode for one single tile, RPCL,
  no-MCT, 5/3, inline headers with PLT, and one or more untargeted quality
  layers. Output is deterministic and plane-exact through z2000, OpenJPEG, and
  Grok on the tested 4:2:0 profile.
- The packet-layout follow-up completed sampled inline PLT/PLT-less, PPT with
  body-length PLT, PPM without redundant PLT, and all SOP/EPH combinations.
  One- through three-layer strict payloads are equivalent and live 4:2:0
  output is accepted by OpenJPEG, Grok, and Kakadu.
- Sampled multi-tile encode now covers one tile-part per tile with inline PLT,
  inline PLT-less, PPT with body-length PLT, or PPM without PLT. The full
  SOP/EPH matrix, packed-header corruption, one/three layers, and 1/8-thread
  determinism are pinned on odd component/tile boundaries. OpenJPEG, Grok, and
  Kakadu accept every live three-layer 4:2:0 layout; Kakadu reproduces the
  native planes exactly.
- `readStrictPacketCatalog` now joins the same checked tile-local sampled
  catalogs used by production decode. Normalized packet entries and bytes are
  identical across the multi-tile inline/PPT/PPM and SOP/EPH matrix.
- Sampled POC now composes LRCP, RLCP, RPCL, PCRL, and CPRL intervals over
  component-local precinct grids on single- and multi-tile output. Main- and
  tile-header markers, PPT, malformed/incomplete schedules, and deterministic
  threading are covered. Kakadu 8.4.1 reconstructs live output for every order
  exactly; OpenJPEG/Grok accept it but disagree on sampled POC raster output,
  so that combination remains an explicit reference-decoder caveat. PPM+POC
  stays fail-closed.
- Sampled strict decode and encode retain `XOsiz/YOsiz` independently from
  `XTOsiz/YTOsiz`. An odd clipped 3x3 4:2:0 grid is plane-exact and
  deterministic; an independent Kakadu 8.4.1 fixture decodes exactly through
  z2000, and Kakadu reproduces matching z2000 output exactly on all native
  planes.
- PRs #156–#157 capped the 5/3 DWT phase at eight workers and gave it a
  persistent pool. Lossless output stayed byte-identical while t16 encode
  improved; detailed numbers live in `benchmarks.md`.
- The bounded colour-metadata boundary recognizes CMYK (12), default-parameter
  CIELab (14), e-sRGB (20), and e-sYCC (24). Explicit writer output and strict
  decode preserve native planes exactly; sampled e-sYCC retains the bounded
  YCC geometry, while TIFF/display conversion remains fail-closed.

## Ordered Queue

### 1. Colour And ICC Conversion Boundary

Keep native component decode and byte-preserving ICC storage unchanged. The
current boundary recognizes EnumCS 18 and converts unsigned 8/16-bit sYCC
4:4:4 plus 4:2:2/4:2:0 directly from native planes at the JP2-to-TIFF boundary,
including the pinned odd-origin OpenJPEG edge phase. Aligned Kakadu fixtures
match the complete OpenJPEG and Grok sRGB rasters; the odd-origin fixture
matches OpenJPEG exactly. The separate conversion API supports bounded ICC v2/v4
RGB matrix/TRC profiles, with official eciRGB v2 and CC0 Adobe RGB-compatible
fixtures matching LittleCMS reference vectors. CMYK, default-parameter CIELab,
e-sRGB, and e-sYCC now have explicit, plane-exact signalling/preservation APIs;
they remain deliberately unavailable to TIFF/display conversion. This bounded
colour slice is complete.

No colour conversion belongs inside T1/T2, and no component layout may be
silently interpreted as RGB or YCC.

### 2. Format And Metadata Adapters

The first bounded BMP slice is complete: isolated 24/32-bit BI_RGB parsing,
top-down/bottom-up row semantics, checked padding/size arithmetic, explicit
single-file and batch CLI dispatch, malformed/truncation/mutation sweeps, an
independent ImageMagick BMP3 pixel oracle, and end-to-end BMP -> JP2 -> TIFF
interop.

The bounded PNG slice is also complete: critical chunks plus `PLTE`/`tRNS`,
all standard color types and legal bit depths, exact zlib/filter reconstruction,
CRC/order validation, packed-sample expansion, CLI/batch dispatch, mutation
sweeps, independent ImageMagick pixel oracles, and pixel-exact z2000/OpenJPEG/
Grok interop. Adam7 and color/metadata mappings remain explicitly closed.

The bounded baseline JPEG raster slice is complete as well: one 8-bit SOF0/interleaved
Huffman scan, checked DQT/DHT/DRI/RST and marker state, grayscale plus JFIF
4:4:4/4:2:2/4:2:0, reference IDCT, centered chroma interpolation, CLI/batch,
malformed/mutation sweeps, independent ImageMagick oracles, and exact
OpenJPEG/Grok reconstruction of the resulting reversible JP2. Progressive,
arithmetic, CMYK/YCCK, and multi-scan JPEG remain closed.

The bounded LinearRaw DNG slice is complete: exactly one IFD0/direct-SubIFD
uncompressed chunky unsigned three-channel 8/16-bit raster, checked strips,
orientation 1, optional linearization and black/white normalization, and a
one-illuminant camera-to-PCS matrix carried as a restricted linear ICC profile.
Grok preserves the synthetic linear raster exactly; OpenJPEG's ICC-rendered
TIFF agrees with the explicit z2000 sRGB path within two 16-bit sample values.
CFA/demosaicing, compression, tiles, crop/opcodes, multiple calibrations, and
unmapped metadata remain closed.

The bounded normalized-linear OpenEXR slice is complete: one single-part,
uncompressed scanline image with exact HALF B/G/R channels, matching windows,
explicit chromaticities, checked chunk coverage, CLI/batch, mutation gates,
and ImageMagick/OpenJPEG/Grok interop. Only finite `[0,1]` samples enter the
unsigned 16-bit carrier. HDR/negative values, compression, tiles,
multipart/deep data, arbitrary channels, alpha, and metadata remain closed.

The first metadata slice is complete: standalone-TIFF EXIF, UTF-8 XML XMP, and
IPTC-IIM map byte-for-byte into canonical checked JP2 UUID boxes, extraction
accepts the deployed alternate EXIF/IPTC identifiers, and malformed/duplicate
families fail closed. Bounded baseline JPEG now ingests standard Exif/XMP APP1
and exactly one Photoshop APP13 IPTC resource without changing the reversible
JP2 codestream. Extended XMP, ICC APP2, arbitrary Photoshop resources, semantic
tag interpretation, and JP2-to-TIFF restoration remain explicit later breadth.
Evaluate depths above 16 bits only after a source format and target JP2 profile
have checked semantics. This first format/metadata campaign is complete.

### 3. Release Readiness

Prepare intentional prereleases rather than commit-triggered releases. Keep
Windows/Linux/macOS builds, portable RISC-V and optional RVV compile/functional
gates, strict corruption tests, deterministic threading, current interop,
concise docs, and benchmark provenance green. See `versioning.md`.

`v0.2.0-rc.1` was published on 2026-07-16 from commit `7b8c01c`. Windows and
Linux x86-64 passed local Debug/ReleaseFast gates; the portable RISC-V
ReleaseFast suite ran locally under QEMU; macOS arm64 passed its dedicated
hosted Debug/ReleaseFast job. Every archive contains both CLI names and is
covered by the published `SHA256SUMS`. The next release action is to collect
candidate feedback and decide whether fixes require `v0.2.0-rc.2` or the same
commit family is ready for a final `v0.2.0` gate. Release maintenance may run
in parallel; general codec development resumes at item 4.

### 4. General Part 1 Decode Foundation — Next Active

Start by separating broad Part 1 readiness from the completed bounded
scorecards. This item is intentionally decode-first.

#### 4.1 Capability And Corpus Matrix

1. Extend `iso_coverage.md` with a broad matrix whose rows distinguish parser,
   strict decode, encode, malformed-input, and independent-interop status.
2. Add a machine-readable corpus manifest containing source, version, licence,
   checksum, exercised feature rows, expected output, and permitted local-only
   paths. Do not commit redistributability-unclear conformance assets.
3. Add one runner for the manifest and optional Part 4 corpus. It must report
   pass, expected fail-closed, unexpected acceptance, and raster mismatch
   separately.
4. Seed independent streams for multiple tiles, signed and low-bit-depth
   components, divergent `QCC`/`COC`, `POC`, `CRG`, `TLM`, and `RGN`. Add
   `PLM`, `CAP`, and `PRF` cases as applicable to the declared Part 1 profile.
5. Record OpenJPEG, Grok, and Kakadu disagreement instead of selecting a
   convenient oracle. Part 4 expected results and exact samples take priority
   when available.

Exit when every existing public profile maps to the new matrix and the runner
can demonstrate at least one expected unsupported row without inflating the
current 100/100 bounded scores.

#### 4.2 Generic Native Sample Carrier

1. Audit every `u16`, RGB, three/four-component, and common-grid assumption at
   the codestream/API/container boundaries.
2. Introduce a checked native integer representation that preserves Part
   1-legal precision and signedness without clipping or bias ambiguity.
3. Remove the four-component public ceiling and carry per-component precision,
   sign, origin, and subsampling through allocation, T1/DWT, assembly, and
   diagnostics. Resource limits remain explicit even when the syntax allows a
   larger count.
4. Add PGX plus checked PAM/raw-planar diagnostic output for sample layouts
   that TIFF cannot represent exactly. Add direct `.j2k`/`.j2c` decode dispatch
   without requiring a JP2 wrapper.
5. Pin lossless fixtures covering signed data, sub-byte precision, precision
   above 16 bits, mixed component precision, more than four components, and
   independently subsampled components without MCT.

Exit when those fixtures round-trip through the native API and diagnostic
outputs with exact values, while legacy JP2/TIFF paths remain unchanged.

#### 4.3 Component And Tile Overrides

Implement genuinely divergent main- and tile-header `COD`, `COC`, `QCD`, and
`QCC` semantics. Cover per-component decomposition, code-block, precinct,
style, transform, and quantization choices where Part 1 permits them. Reject
illegal transform/component combinations before allocation. Decode independent
foreign streams first; expose encoder controls only under item 7.

Exit when byte-redundant override shortcuts are no longer required for claimed
profiles and every accepted override combination has a divergent fixture plus
a malformed counterpart.

### 5. Remaining Part 1 Codestream Breadth

Implement in small marker-to-raster slices:

1. `RGN` Maxshift ROI and `CRG` component registration, including their effect
   on sample reconstruction rather than parser-only acceptance.
2. `PLM` packet lengths and applicable `CAP`/`PRF` profile signalling with
   checked consistency against `Rsiz` and actual payload behavior.
3. General legal tile-part ordering and repetition, including non-empty
   PLT-less multipart streams and checked `TLM` variations.
4. Legal `POC` schedules across inline, `PPT`, and `PPM` headers, removing the
   current sampled `PPM` + `POC` fail-closed boundary only after packet identity
   is unambiguous.
5. A single normalized packet index shared by strict decode, diagnostics, and
   later selective decode. Do not add a second permissive packet parser.

Each marker slice needs parser/state-machine corruption cases, exact sample
evidence, and at least one independently produced stream. Syntax recognition
alone does not complete an item.

### 6. Scalable And Bounded-Memory Decode

Expose explicit limits for quality layers, resolution reduction, tiles, and
reference-grid regions. Build the requests on the normalized packet index and
schedule only the required packet/code-block/DWT work. Add incremental
codestream input and row/tile-oriented output so peak memory scales with the
requested working set rather than the complete raster.

For every selection mode, compare the result with the corresponding crop or
reduction of a full strict decode. Cover odd origins, subsampling, ROI, tile
boundaries, packed headers, truncation, cancellation, and caller-provided
resource ceilings. A benchmark improvement is useful evidence but not the
correctness gate.

### 7. General Part 1 Encoder

Promote decoder-proven capabilities to the writer in this order:

1. generic component counts, signedness, precision, subsampling, and direct
   raw-codestream output;
2. per-component coding style and quantization controls;
3. `RGN` Maxshift ROI, component registration, and general tile-part/header
   schedules;
4. deterministic layer formation with practical exact-byte and quality-target
   modes, with overshoot and distortion reported explicitly;
5. streaming/memory-bounded tile encode and public resource limits.

Every writer option needs z2000 exact decode plus OpenJPEG, Grok, and Kakadu
interop where supported. An independently accepted codestream is necessary
but not sufficient: decoded samples, requested layer behavior, marker
semantics, and 1/8/all-thread determinism must also match.

### 8. General JP2 And Conversion Surface

Complete legal Part 1 palette, component mapping, channel definition, colour,
resolution, XML/UUID/IPR, and metadata-order/preservation behavior without
assuming that all images are sRGB display rasters. Preserve unrecognized
permitted metadata byte-for-byte where safe, and keep any rendering conversion
explicit and opt-in.

Document raw codestream versus JP2 behavior consistently across the API,
single-file CLI, and unquoted batch syntax. Add representability diagnostics
when TIFF, PNG, BMP, or another target cannot preserve native components.
Multiple codestreams, JPX composition, and Part 2-only boxes stay outside this
item.

### 9. Conformance, Hardening, And 1.0 Gate

Run the claimed Part 4 decoder and encoder classes, the full manifested foreign
corpus, mutation/fuzz campaigns, deterministic threading, allocation/resource
limits, and Windows/Linux/macOS/RISC-V builds. Keep exact tool versions,
commands, hashes, and discrepancies in the release evidence.

Before `1.0.0`, freeze the public API/CLI for one release-candidate cycle,
publish the broad capability matrix, verify every claimed row from clean
archives, and close or explicitly unclaim every discrepancy. Internal success
must not be described as formal third-party certification.

After this gate, scope JPX/Part 2, HTJ2K/Part 15, MJ2/JPM, or JPIP as separate
programs rather than silently broadening the Part 1 claim.

## Parallel Performance Track

Performance work may run between correctness slices under
[`optimization_plan.md`](optimization_plan.md).

The 5/3 worker-cap and persistent-pool experiments are complete. The 2026-07-16
i5-14500 checkpoint measured 5/3 lossless and 9/7 lossy at t1/t20 across
z2000, Grok, OpenJPEG, and Kakadu. z2000 t20 lossless encode now beats Grok and
nearly matches OpenJPEG, while common-stream decode remains 1.37x behind Grok
and 1.43x behind Kakadu. The next measurement should therefore isolate decode
packet/block readiness overlap, output/TIFF serialization, and allocation
locality. Reopen broad T1 SWAR/packed-column work only with a new layout
hypothesis and the normal keep rule.

## Gate For Every Slice

```powershell
zig build test
zig build test -Doptimize=ReleaseFast -Dtarget=native
zig build -Doptimize=ReleaseFast -Dtarget=native
```

Also run focused tests, `git diff --check`, and the relevant
OpenJPEG/Grok/Kakadu smoke. Update `changelog.md`, `iso_coverage.md` when its
boundary changes, API/architecture for behavioral changes, and this queue in
the same commit.
