# Next Steps

This is the only active implementation queue. Strategic policy is in
[`roadmap.md`](roadmap.md); completed plans and campaign detail are in
[`archive/`](archive/README.md).

## Current State (After PR #157)

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
- PRs #156–#157 capped the 5/3 DWT phase at eight workers and gave it a
  persistent pool. Lossless output stayed byte-identical while t16 encode
  improved; detailed numbers live in `benchmarks.md`.

## Ordered Queue

### 1. Sampled Encode Packet Layouts

Extend `encodeLosslessSampledPlanarWithOptions` without widening its transform
profile:

1. PLT-less inline output;
2. PPT output with body-length PLT accounting;
3. PPM output with one checked header group per tile-part and no redundant PLT;
4. all SOP/EPH combinations for inline, PPT, and PPM.

Reuse the same sampled RPCL packet merge and packed-header framing helpers used
by uniform-component encode. Do not create a second packet-state model.

Acceptance gate:

- one-, two-, and three-layer 4:2:0 roundtrips are native-plane exact;
- inline/PLT-less/PPT/PPM variants carry the same T1 payload contributions;
- PLT, PPM group, SOP sequence, EPH placement, truncation, and corruption cases
  fail deterministically;
- OpenJPEG, Grok, and Kakadu accept representative output where supported;
- threads 1 and all produce byte-identical codestreams.

### 2. Sampled Multi-Tile Encode

Move the sampled per-component artifacts into the existing production tile
grid. Each tile must derive component-local sampled bounds, DWT origins,
precinct indexes, packet state, and output spans from the absolute SIZ grid.
Start with inline+PLT, then reuse item 1's packet layouts.

Acceptance gate:

- aligned and shifted-origin 4:2:0 grids, including clipped edge tiles;
- one and multiple quality layers;
- strict native-plane decode plus OpenJPEG/Grok/Kakadu component-raster checks;
- deterministic tile scheduling;
- sampled MCT, 9/7, unsupported progressions, and inconsistent dimensions stay
  fail-closed.

### 3. Remaining Sampled Geometry Breadth

Implement reordered sampled POC over component-local precinct grids, then
distinct tile-partition origins (`XTOsiz/YTOsiz`). These are separate slices:
POC changes packet visitation; tile origins change geometry and lifting parity.
Each needs an independent producer fixture and edge-tile corruption cases.

### 4. Colour And ICC Conversion Boundary

Keep native component decode and byte-preserving ICC storage unchanged. Add
explicit container colour metadata and a separate conversion API, starting with:

1. sYCC to sRGB;
2. ICC-backed RGB conversion with eciRGB v2 and Adobe RGB fixtures;
3. CMYK, extended YCC, and CIELab signalling/preservation before conversion.

No colour conversion belongs inside T1/T2, and no component layout may be
silently interpreted as RGB or YCC.

### 5. Format And Metadata Adapters

Add isolated, fuzz-gated modules in this order: BMP, PNG, JPEG, linear DNG/RAW,
then OpenEXR. Preserve EXIF, XMP, and IPTC through explicit mappings. Evaluate
depths above 16 bits only after the internal carrier and target JP2 profile have
checked semantics.

### 6. Release Readiness

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
