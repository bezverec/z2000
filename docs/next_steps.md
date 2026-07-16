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
they remain deliberately unavailable to TIFF/display conversion. The bounded
colour slice is complete, so the next active implementation item is section 2.

No colour conversion belongs inside T1/T2, and no component layout may be
silently interpreted as RGB or YCC.

### 2. Format And Metadata Adapters

The first bounded BMP slice is complete: isolated 24/32-bit BI_RGB parsing,
top-down/bottom-up row semantics, checked padding/size arithmetic, explicit
single-file and batch CLI dispatch, malformed/truncation/mutation sweeps, an independent
ImageMagick BMP3 pixel oracle, and end-to-end BMP -> JP2 -> TIFF interop.

Continue with an isolated, fuzz-gated PNG module, then JPEG, linear DNG/RAW,
and OpenEXR. Preserve EXIF, XMP, and IPTC through explicit mappings. Evaluate
depths above 16 bits only after the internal carrier and target JP2 profile have
checked semantics.

### 3. Release Readiness

Prepare intentional prereleases rather than commit-triggered releases. Keep
Windows/Linux native builds, RISC-V/RVV compile and functional gates, strict
corruption tests, deterministic threading, current interop, concise docs, and
benchmark provenance green. See `versioning.md`.

## Parallel Performance Track

Performance work may run between correctness slices under
[`optimization_plan.md`](optimization_plan.md).

The 5/3 worker-cap and persistent-pool experiments are complete. The preferred
next measurement is high-thread decode pipeline efficiency: packet/block
readiness overlap, output/TIFF serialization, and allocation locality. Measure
5/3 lossless and 9/7 lossy separately at t1 and all threads. Reopen broad T1
SWAR/packed-column work only with a new layout hypothesis and the normal keep
rule.

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
