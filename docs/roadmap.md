# Roadmap

This is the strategic plan for z2000. The exact execution order lives in
[`next_steps.md`](next_steps.md); the measured performance campaign lives in
[`optimization_plan.md`](optimization_plan.md). Completed feature campaigns
are preserved under `archive/`.

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
independent image/tile-partition origins, multi-tile assembly, complete POC
schedules using all five progression orders, sampled PPT and PPM with SOP/EPH
coverage, and explicit origin-anchored reference-grid
upsampling for bounded sRGB JP2-to-TIFF output. The matching single-tile
reversible writer emits canonical sampled RPCL or checked POC schedules on
single- and multi-tile grids
with inline PLT/PLT-less, PPT, or PPM packet headers, plus SOP/EPH and one or
more quality layers. OpenJPEG, Grok, and Kakadu reproduce the tested component
data.

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

Distinct tile-partition origins now have an independent Kakadu fixture and
bidirectional exact interop. Keep sampled MCT and irreversible combinations
closed until their transform and registration semantics are explicit.
Reordered sampled POC and the multi-tile diagnostic packet catalog share
production decode's component-local topology.

### 2. Colour And ICC

Preserve ICC profiles byte-for-byte as today and keep optional colour
conversion as a separate tool-layer operation. The first bounded slice now
recognizes sYCC and converts unsigned 8/16-bit 4:4:4 plus 4:2:2/4:2:0 input to
sRGB, including the pinned odd-origin OpenJPEG edge phase. Aligned Kakadu
fixtures match OpenJPEG and Grok rasters; an odd-origin Kakadu codestream
matches the complete OpenJPEG reference raster. A separate,
opt-in tool-layer path now converts bounded ICC v2/v4 RGB matrix/TRC profiles;
official eciRGB v2 and CC0 Adobe RGB-compatible fixtures match LittleCMS
reference vectors. The signalling-first slice now recognizes and emits native
CMYK, default-parameter CIELab, e-sRGB, and e-sYCC planes without conversion;
sampled e-sYCC preserves bounded YCC geometry. Follow with explicit display
conversion, monochrome refinements, and palette breadth. Never silently
reinterpret component samples from codestream metadata alone.

### 3. Format Front Ends And Metadata

The bounded 24/32-bit BI_RGB BMP adapter is complete with checked row/storage
semantics, fail-closed malformed coverage, CLI/batch dispatch, and an
independent ImageMagick oracle. The non-interlaced PNG adapter is likewise
complete for all standard color types/bit depths, `PLTE`/`tRNS`, filters,
CRC/zlib validation, CLI/batch, mutation sweeps, and independent pixel oracles.
The 8-bit baseline sequential JPEG adapter is complete for gray and JFIF
4:4:4/4:2:2/4:2:0 with Huffman/DCT/restart decoding, strict malformed gates,
CLI/batch, and independent ImageMagick/OpenJPEG/Grok evidence. The bounded
LinearRaw DNG adapter now covers uncompressed chunky 8/16-bit RGB,
normalization, camera-to-PCS ICC signalling, CLI/batch, mutation gates, and
OpenJPEG/Grok interop. The bounded OpenEXR adapter now covers normalized
finite `[0,1]` HALF RGB in one uncompressed scanline part, explicit
chromaticities, CLI/batch, mutation gates, and independent interop. HDR,
negative, compressed, tiled, multipart/deep, alpha/arbitrary-channel, and
metadata-bearing EXR remain future boundaries. Continue with explicit metadata
mappings; CFA/demosaicing and broader RAW profiles stay separate.
Preserve EXIF, XMP, and IPTC through explicit JP2 box or
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
- automatic colour conversion beyond bounded sYCC 4:4:4/4:2:2/4:2:0;
- tiled/compressed TIFF variants and broad camera-RAW workflows;
- unchecked architecture-specific fast paths.
