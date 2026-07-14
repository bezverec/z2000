# Roadmap

This is the strategic plan for z2000. The exact execution order lives in
[`next_steps.md`](next_steps.md); detailed feature and performance campaigns
live in [`feature_plan.md`](feature_plan.md) and
[`optimization_plan.md`](optimization_plan.md).

## Current Baseline

The two project scorecards are 100/100 for their explicitly bounded targets.
That does **not** mean every JPEG2000 Part 1 profile or JPX feature exists.
The production baseline is a strict, fail-closed codec family with tested
lossless and lossy RGB paths, real T1/T2 payloads, quality layers, all five
progression orders, bounded tile-part divisions, multi-tile support, code-block
style coverage, JP2 wrapping, strict foreign decode, and reference-decoder
interop. See [`iso_coverage.md`](iso_coverage.md) for the exact envelope.

The component-generic campaign has additionally landed grayscale, bounded
palette and alpha layouts, mixed 8/16-bit planar precision, and native-plane
decode for bounded RPCL/no-MCT/reversible-5/3 component subsampling. F3b now
includes component-local packet/T1/DWT geometry, PLT and PLT-less streams,
matching nonzero origins, multi-tile assembly, canonical RPCL POC, and explicit
origin-anchored reference-grid upsampling for bounded sRGB JP2-to-TIFF output.

## Rules For Promotion

- Unsupported payload behavior fails closed; metadata parsing alone never
  unlocks an encode/decode profile.
- A profile becomes public only after writer/reader symmetry or a deliberate
  decode-only contract, malformed-input tests, and deterministic threading.
- Interop gates use z2000 strict decode plus OpenJPEG, Grok, and Kakadu where
  the reference tool supports the profile. Validators are useful evidence,
  not an absolute source of truth.
- Performance changes are kept only when profile-matched measurements improve
  without changing pixels, packet semantics, safety, or determinism.
- Native component planes remain the codec boundary. Upsampling, colour
  conversion, alpha interpretation, and metadata mapping stay explicit in the
  conversion/container layer.

## Strategic Sequence

### 1. Finish F3 Component Layout Breadth

Broaden sampled strict decode from inline headers to PPT and PPM, then add
sampled no-MCT reversible encode. Follow with reordered sampled POC and
distinct tile-partition origins only when packet ordering and geometry have
independent fixtures. Keep sampled MCT and irreversible combinations closed
until their transform and registration semantics are explicit.

### 2. Colour And ICC

Preserve ICC profiles byte-for-byte as today, then add optional colour
conversion as a separate tool-layer operation. Prioritize sYCC and common RGB
profiles such as eciRGB v2 and Adobe RGB; follow with CMYK, extended YCC,
CIELab, monochrome refinements, and palette breadth. Never silently reinterpret
component samples from codestream metadata alone.

### 3. Format Front Ends And Metadata

Implement isolated, fuzz-gated adapters in this order: BMP, PNG, JPEG, linear
DNG/RAW, then OpenEXR. Preserve EXIF, XMP, and IPTC through explicit JP2 box or
side metadata mappings. Evaluate depths above 16 bits only after the internal
sample carrier and each source format have checked semantics.

### 4. Performance And Scale

Continue separate 5/3 lossless and 9/7 lossy campaigns. Near-term value is in
decode parallel efficiency, catalog/T1 overlap, I/O locality, and carefully
measured T1 work. Portable Zig vectors remain the default SIMD abstraction;
AVX2, AVX-512, NEON, and RVV must share scalar-oracle tests. The long-term goal
is to exceed Grok and then Kakadu without relaxing correctness or safety.

### 5. Release Readiness

Keep prereleases intentional rather than commit-triggered. A release candidate
requires native Windows and Linux builds, the RISC-V compile/functional gate,
the full corruption suite, deterministic threaded output, current four-codec
interop, documented CLI/API boundaries, and reproducible benchmark provenance.
The detailed policy is in [`versioning.md`](versioning.md).

## Explicitly Outside The Current Baseline

- arbitrary JPX box families and JPX-only composition;
- arbitrary component counts, signed/floating codestream samples, and general
  mixed subsampling/precision/MCT combinations;
- sampled packed headers, reordered sampled POC, sampled encode, and distinct
  tile-partition origins until the gates in `next_steps.md` land;
- automatic non-sRGB colour conversion;
- tiled/compressed TIFF variants and broad camera-RAW workflows;
- unchecked architecture-specific fast paths.

