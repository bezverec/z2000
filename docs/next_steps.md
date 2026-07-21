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

The foundation landed on 2026-07-17:

- `iso_coverage.md` now has an unscored broad matrix separating parser, strict
  decode, encode, malformed-input, and independent-interop status.
- `src/testdata/part1-corpus.json` records capability rows, provenance,
  licence/redistribution status, input hashes, expected native hashes/errors,
  optional environment-rooted local paths, and exact checksummed PGX
  references.
- `zig build part1-corpus` verifies inputs and reports decode pass, expected
  fail-closed, unexpected acceptance, mismatch, and skipped optional assets.
- Sixteen foreign-encoded streams now pin sampled multi-precinct/origin/POC,
  Grok four-component CMYK, all six T1 style bits, uniform `COC/QCC`, a
  24-part `TLM` layout, signed 8-bit single-/multi-tile native decode, five-
  component native assembly, signed 20-bit, mixed signed 5/12/19-bit plus
  8/16/20-bit, and independently sampled signed 7/13/23-bit native
  decode. Four mutations
  pin reserved COC/QCC values, TLM length accounting, and unsupported payload
  behavior.
- Each entry selects the real legacy-planar, generic-native, or interleaved RGB
  strict path. Legacy planar/RGB results normalize to one component-major hash;
  native signed output uses exact PGX references. JP2 entries validate their
  container metadata before codestream extraction.
- The official WG1 T.803 corpus is pinned at commit `f6b9ede0` through
  `tools/setup_part1_corpus.ps1` and remains local under its conformance-use
  terms. All 16 profile-0 inputs and 18 class-0 PGX references now run with
  `Z2000_PART4_ROOT`: `p0_01`, `p0_02`, `p0_11`, `p0_12`, `p0_16`, `p0_04`,
  `p0_09`, `p0_10`, and `p0_14` pass their class-0 references; seven broader legal
  profiles pin the current fail-closed boundary. QCD-before-COD moved `p0_01`
  to an exact pass;
  uniform full COC, LRCP layers, SOP/EPH, T1 termination styles, and reserved
  segment-less marker handling move `p0_02` to an exact pass;
  bounded single-span edge clipping plus NL=0/EPH/SEGMARK move `p0_11` to an
  exact 128x1 pass while general B.7 clamping stays fail-closed;
  component-specific irreversible QCC plus reduced ICT/9-7 codestream-component
  output covers `p0_04`; reduced no-MCT 9/7 and reversible saturation cover
  `p0_09`/`p0_14`; and legal zero
  guard bits plus sampled RCT and inline PLT-less multipart state cover
  `p0_10`.
- The PGX oracle now accepts reference lists, component selectors, signed or
  unsigned 1..31-bit ML/LM samples, reduction metadata, peak-error limits, and
  independent MSE limits. Every declared reference is checksum-verified even
  when its input is an expected fail-closed profile.
- `DecodeOptions.resolution_reduction` now drives direct partial synthesis for
  bounded single-tile decode: reversible 5/3 no-MCT through planar, grayscale,
  sampled native-component, and interleaved output, reversible RCT/5/3 through
  interleaved RGB, and irreversible 9/7 with either no MCT or ICT through
  interleaved RGB. Component-local sampling factors and nonzero image/tile
  origins drive each reduced native plane independently. It preserves odd
  dimensions, dequantizes only retained 9/7 bands, applies the inverse
  component transform before checked output saturation, rejects reductions
  above COD/NL, and is wired into each corpus reference. It does not synthesize
  a full raster and downsample it.
- Common-grid multi-tile interleaved RGB now applies the same selection inside
  every tile catalog and assembles reduced tiles by their absolute ceil-div
  boundaries. An odd 3x3 RCT/5-3 grid is exact against a manually assembled
  per-tile oracle; ICT/9-7 reduced output is deterministic across worker counts
  and reports discarded T1 blocks/bytes.
- Sampled multi-tile no-MCT 9/7 now applies component-local packet selection,
  selective dequantization, partial inverse synthesis, and reduced absolute
  assembly on each native grid. A committed Kakadu 8.4.1 four-tile RPCL/PLT
  fixture pins full and reduction-1 output for all three components against six
  PGX references (peak <= 1, MSE <= 0.12) and proves 1/8-thread determinism.
  A matching independent PLT-less stream additionally drives inline, PPT, and
  PPM full/reduced decode, packed-marker corruption, and 1/8-thread gates. PPT
  and PPM are deterministic structural repacks, not foreign encoder output.
- Reduced decode now validates the complete packet-header catalog but skips T1
  entropy reconstruction for detail subbands at or below the discarded DWT
  levels. Both sequential and parallel paths report skipped blocks and payload
  bytes through `DecodeTimings`; full-resolution decode reports zero.
- After that complete validation, reduced decode compacts each component's
  working block catalog to retain payload only for the selected subbands.
  Discarded blocks keep their lengths, segmentation, and geometry for audit;
  `DecodeTimings` reports retained and discarded catalog bytes.
- Resolution selection now reaches packet assembly itself. Discarded payload
  spans are range-checked and consumed according to the fully decoded headers,
  but are not appended to component-owned buffers. The materialized-byte
  counter equals the final retained-byte count in sequential and parallel
  regression paths.
- The production single-tile inline reader now uses absolute checked spans into
  the caller-owned codestream and allocates packet entries but no normalized
  packet-byte copy. SOP advances the borrowed packet start after validating its
  marker/sequence; EPH is represented by separate header/body spans whose
  consumption is checked independently. The public catalog remains owned, and
  PPT/PPM store only their decoded T2 headers in an auxiliary owned buffer while
  borrowing SOD body spans. Timings report borrowed versus materialized input
  bytes; the internal single-tile production path no longer normalizes a full
  packet-byte stream for inline, PPT, or PPM headers.

The active G0/G4 corpus expansion is:

1. Extend sampling through the remaining applicable colour transforms and
   component layouts. Uniform sampled RCT now decodes in output-component and
   codestream-component space and passes multipart T.803 `p0_10`. Native-planar
   no-MCT 9/7 output now covers bounded single-tile scalar-derived and scalar-
   expounded streams at full and reduced resolution. Sampled no-MCT 5/3
   selection now covers single- and multi-tile streams: tile-component packet
   selection, T1 skipping, partial
   synthesis, and assembly all use the independent sampled/reduced grid.
   The 9/7 slice already pins reduced support extents, selective
   dequantization, floating-point workspace bounds, inverse ICT,
   nearest-integer reconstruction, and precision saturation; reduced RCT pins
   post-transform rather than chroma-plane saturation. The sampled multi-tile
   oracle covers odd image/tile bounds and inline, PPT, and PPM headers. Keep
   the public packet catalog owned and the production scatter/gather
   validation pinned throughout. Sampled multi-tile no-MCT 9/7 additionally
   covers odd tile bounds with independent inline PLT/PLT-less Kakadu payloads
   and full/reduced PGX references. Deterministic PPT/PPM repacks preserve the
   foreign T1 bodies and pass the same gates; a natively emitted packed-header
   fixture from an independent producer remains useful matrix breadth.
2. Add class-1 all-component reference lists as G1/G2 make those profiles
   decodable, retaining the published peak and MSE bounds per component.
3. Expand the landed signed mixed-precision evidence beyond the pinned
   5/7/8/12/13/16/19/20/23/29-bit payloads; add explicit `PLM`, `CAP`, and
   `PRF` handling where applicable. Broaden the
   seeded `TLM` case as G3 requires. Inline PLT-less multipart packet-count
   derivation is complete; packed-header/POC combinations remain.
4. Record OpenJPEG, Grok, and Kakadu disagreement instead of selecting a
   convenient oracle. Part 4 expected results and exact samples take priority
   when available.
5. Map the remaining public profiles to manifested decode and malformed cases,
   then run optional assets with `--require-optional` in release evidence.

Exit when every existing public profile maps to the new matrix and the runner
can evaluate the relevant T.803 references and tolerances without inflating
the current 100/100 bounded scores.

#### 4.2 Generic Native Sample Carrier

The first non-breaking foundation is now in place. `src/native_samples.zig`
adds a caller-limited SIZ inspector and dynamic `i64` planes carrying per-
component 1..38-bit precision, signedness, native origin, subsampling, and
dimensions. It validates sample ranges and emits checked PGX for 8/16/32-bit
storage widths. A five-component mixed 1/8/12/20/38-bit regression plus the
existing signed-SIZ mutation pin metadata preservation, allocation ceilings,
range failures, and Zig 0.16 behavior. The legacy `u16` decoder remains
unchanged and unsigned-only. Committed Kakadu 8.4.1 signed 8-bit single- and
four-tile streams now pass exact PGX comparison through `decodeLosslessNative`
at full and reduction-1 resolution. A third Kakadu fixture carries five signed
components across four tiles and matches ten per-component PGX references. A
fourth fixture carries signed 20-bit samples, including both extrema and zero,
and matches Kakadu at full and reduction-1 resolution. A fifth Kakadu stream combines signed
8/16/20-bit components and matches all six full/reduction-1 PGX references,
proving that T2/T1/DWT reconstruction retains component-local precision. The
bounded native payload path is reversible 5/3, no-MCT, caller-limited up to
256 components at every precision from 1 through 29 bits, including mixed
precision and independent component sampling, with exact
1/8-thread output and caller-controlled lower limits. A 19-component,
four-tile Kakadu fixture pins full and reduction-1 assembly beyond the former
strict ceiling. A further mixed 5/12/19-bit Kakadu fixture matches all six
full/reduction-1 PGX references exactly and pins sub-byte plus intermediate
precision reconstruction. A signed 29-bit four-tile fixture reaches the
31-magnitude-bitplane T1/HH boundary and matches Kakadu full/reduction-1 PGX
exactly. Native full and reduced inverse 5/3 synthesis now uses `i64` lifting
sums with checked `i32` stores; a 30-bit mutation keeps the wider boundary closed.
Packet pruning and per-tile partial synthesis retain reduced absolute
component origins and dimensions; reductions above COD/NL fail closed. Signed
components skip the unsigned DC shift; the same codestreams remain fail-closed
in legacy planar/gray APIs.
A signed mixed 7/13/23-bit four-tile fixture now pins independent 1x1, 2x1,
and 2x2 component grids against all six Kakadu full/reduction-1 PGX outputs;
one/eight-thread decode and canonical ZRAW round-trip remain exact.
The first six strict-storage migrations are complete: component assembly,
public block catalog, component packet plans, deduplicated geometry storage,
RPCL indexes, the strict metadata header/parser state, persistent precinct
groups, assembly block-count scratch, parallel job handles, and generic
irreversible component working tables now allocate exact-length component
slices rather than reserving 16 slots. Direct 19-component storage, planning,
SIZ-parser, active precinct-state, end-to-end 19-component multi-tile, and
19-job tests pin this foundation. Metadata and reversible native decode are
bounded at 256 components; legacy colour/encode APIs retain their narrower
contracts, and generic irreversible output remains on that legacy carrier.

1. Continue the audit of every `u16`, RGB, three/four-component, and common-
   grid assumption through T1/DWT, tile assembly, JP2 validation, and CLI
   conversion boundaries. The SIZ/API allocation boundary is complete.
2. Continue replacing bounded strict-pipeline arrays with caller-limited
   dynamic structures as they enter the generic path. Assembly, final block-
   catalog storage, component packet plans/geometries, RPCL indexes, metadata,
   precinct groups, parallel component jobs, and generic irreversible working
   tables are complete; reversible native tile output/assembly and the job
   runner now pass beyond 16 components. The reversible native T1/DWT path now
   carries every 1..29-bit precision without clipping or bias ambiguity.
   The coefficient audit and checked inverse-lifting migration are complete;
   widening beyond 29 bits requires an `i64` T1 coefficient carrier.
3. The landed PGX writer is wired into direct raw `.j2k`/`.j2c` CLI
   decode without a JP2 wrapper. Explicit, extension-inferred, and unquoted
   batch forms select one component, resolution reduction, threads, T1
   backend, and `ML`/`LM` byte order. Canonical ZRAW now covers the exact all-
   component case through the same three CLI forms, retaining signedness,
   component grids, and origins with a bounded round-trip parser. The ZRAW
   API/container spans 1..38 bits; direct codestream payload decode currently
   supplies the landed continuous 1..29-bit profile. A future PAM adapter
   should be added only for the subset
   PAM can represent faithfully; it must not replace ZRAW or silently narrow.
4. **Complete:** independently subsampled signed components without MCT now
   have a committed mixed 7/13/23-bit, four-tile Kakadu fixture. Signed data,
   continuous 1..29-bit payload support, mixed precision, more-than-four-
   component assembly, and the independent 29-bit boundary fixture are all
   covered within the current bounded path.

Exit achieved: the fixtures round-trip through the native API and exact PGX/
ZRAW diagnostics, while legacy JP2/TIFF paths remain unchanged. Continue with
4.3 divergent component and tile overrides.

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
3. General legal tile-part ordering and repetition beyond the landed inline
   PLT-less multipart state machine, including packed-header combinations and
   checked `TLM` variations.
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

Raw codestream-to-PGX behavior is now consistent across the API, single-file
CLI, and unquoted batch syntax. Extend the same distinction to future targets
and add representability diagnostics
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
