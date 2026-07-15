# Next Steps

This is the only ordered implementation queue. Strategic context is in
[`roadmap.md`](roadmap.md); completed campaign history is in
[`archive/`](archive/README.md).

## Current State

- Bounded ISO scorecards: 100/100, with the limits documented in
  [`iso_coverage.md`](iso_coverage.md).
- F3b slices 1–9: sampled RPCL/no-MCT/reversible-5/3 strict decode supports
  native component planes, PLT/PLT-less packet spans, matching shifted origins,
  single/multi-tile streams, canonical main/tile-header POC, and explicit
  reference-grid nearest-neighbour output for bounded sRGB JP2-to-TIFF.
- Current sampled exclusions: PPT/PPM, reordered POC, distinct tile-partition
  origins, encode, MCT, and irreversible transforms.

## Ordered Queue

### 1. Sampled Packed Headers

Implement strict sampled PPT first, then PPM. Reuse the existing
component-local `StrictStatefulPrecinctGroups` and canonical sampled RPCL
sequence rather than introducing a parallel packet reader.

**Slice 1 landed (2026-07-15): single-tile sampled PPT.** The single-tile
strict reader's packed-header branch already consumed the canonical sampled
sequence through the component-local stateful groups, so the sampled+PPT
rejection is gone and the path is exercised by repacked fixtures: a new
`collectStrictInlinePacketSpans` diagnostic walks an inline PLT-less stream
and reports per-packet header/body spans, and the test suite repacks the
four single-tile 4:2:0 Kakadu fixtures (multi-precinct, shifted origin,
main-header POC, tile-header POC) into PPT form, requiring plane-exact
decode against the inline originals plus packed-header corruption and
truncation failure. Remaining in this item: four-tile sampled PPT (the
multi-tile catalog gate stays closed), PPM, SOP/EPH placement cases, and an
independent producer fixture when a generator is available (the repacked
fixtures prove structure, not interop).

Acceptance gate:

- single-tile and four-tile 4:2:0;
- PLT-backed PPT, then PPM group accounting without PLT;
- SOP/EPH placement and corruption cases;
- matching nonzero origin and canonical POC combinations;
- native planes and upsampled output pixel-exact;
- independent producer fixture when available. A locally repacked fixture may
  test structure but is not sufficient interop evidence by itself.

### 2. Sampled Reversible Encode

Add a planar no-MCT writer with explicit per-component dimensions and
`XRsiz/YRsiz`. Start with single-tile RPCL, one layer, inline headers, and 5/3;
then add layers, PLT-less/packed variants, and multi-tile only after byte and
pixel interop is green.

Acceptance gate:

- SIZ/component dimensions agree exactly;
- z2000 strict decode reproduces every native plane;
- OpenJPEG, Grok, and Kakadu decode equivalent component rasters;
- cross-thread output is deterministic;
- malformed layout and unsupported MCT/9-7 combinations fail closed.

### 3. Remaining Sampled Geometry Breadth

Implement reordered RPCL POC over component-local grids, followed by distinct
`XTOsiz/YTOsiz` tile-partition origins. Each requires independent origin and
edge-tile fixtures; do not generalize common-grid helpers by assumption.

### 4. Colour Conversion Boundary

Add explicit colour-space metadata to the decoded container result and a
separate conversion API. Start with sYCC to sRGB and ICC-backed RGB transforms
(eciRGB v2 and Adobe RGB fixtures), preserving the existing no-conversion
native-plane path. Then proceed according to `feature_plan.md`.

### 5. Format And Metadata Adapters

Begin BMP and PNG modules once the sampled encode surface is stable. Keep each
parser isolated and fuzz-gated. JPEG, DNG/RAW, OpenEXR, EXIF, XMP, and IPTC
follow in the order defined by `feature_plan.md`.

## Parallel Performance Track

Performance work may proceed between correctness slices under
[`optimization_plan.md`](optimization_plan.md). Current preferred experiment:
improve high-thread decode efficiency by overlapping packet/block readiness
with T1 work or by reducing output/TIFF serialization cost. Measure lossless
5/3 and lossy 9/7 separately. Do not reopen broad T1/SWAR rewrites without a
new layout hypothesis and a profile-matched keep gate.

## Required Gate For Every Slice

```powershell
zig build test
zig build test -Doptimize=ReleaseFast -Dtarget=native
zig build -Doptimize=ReleaseFast -Dtarget=native
```

Also run the focused tests for the touched subsystem, `git diff --check`, and
the relevant OpenJPEG/Grok/Kakadu smoke. Update changelog, API/architecture,
and this queue in the same change.

