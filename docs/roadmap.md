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

### 1. Maintain F3 Component Layout Breadth

The bounded F3 campaign is complete. Distinct tile-partition origins have an
independent Kakadu fixture and bidirectional exact interop; reordered sampled
POC and the multi-tile diagnostic packet catalog share production decode's
component-local topology. Keep sampled MCT and irreversible combinations closed
until their transform and registration semantics are explicit.

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
metadata-bearing EXR remain future boundaries. The first explicit metadata
mapping is complete: bounded JPEG Exif/XMP APP1 and Photoshop APP13 IPTC-IIM
payloads map byte-for-byte into checked JP2 UUID boxes. Continue with extended
XMP, broader source ingestion, semantic mapping, and JP2-to-output restoration;
CFA/demosaicing and broader RAW profiles stay separate. Evaluate depths above
16 bits only after the internal sample carrier and each source format have
checked semantics.

### 4. Performance And Scale

Continue separate 5/3 lossless and 9/7 lossy campaigns. Near-term value is in
decode parallel efficiency, catalog/T1 overlap, I/O locality, and carefully
measured T1 work. Portable Zig vectors remain the default SIMD abstraction;
AVX2, AVX-512, NEON, and RVV must share scalar-oracle tests. The long-term goal
is to exceed Grok and then Kakadu without relaxing correctness or safety.

### 5. Release Readiness

Keep prereleases intentional rather than commit-triggered. Prefer locally
assembled and verified release archives so the RISC-V functional gate does not
consume hosted Actions minutes. A release candidate still requires Windows,
Linux, macOS, and RISC-V evidence, the full corruption suite, deterministic
threaded output, current four-codec interop, documented CLI/API boundaries, and
reproducible benchmark provenance. The detailed policy is in
[`versioning.md`](versioning.md).

## Path To A General-Purpose Part 1 Codec

The next product target is a general-purpose JPEG 2000 Part 1 codestream and
JP2 codec, not an attempt to claim the entire JPEG 2000 family at once. Part 1
defines the core codestream and JP2 file format; JPX/Part 2 and HTJ2K/Part 15
are separate standards and therefore separate future programs. The target is
grounded in the [T.800 marker and syntax inventory](https://www.itu.int/dms_pubrec/itu-t/rec/t/T-REC-T.800-201906-S%21%21TOC-HTM-E.htm),
the [JPEG 2000 standards overview](https://jpeg.org/jpeg2000/index.html), and
the [Part 4 conformance framework](https://www.iso.org/standard/85636.html).

Decode breadth comes first because accepting independent codestreams exposes
format assumptions earlier than adding writer switches. Encode support follows
only after the matching decoder and conformance evidence exist. The current
bounded scorecards remain frozen evidence for their defined profiles; a new
broad Part 1 matrix will track each capability independently as parsed,
decoded, encoded, malformed-tested, and independently reproduced.

| Phase | Deliverable | Promotion evidence |
| --- | --- | --- |
| G0 | Capability matrix, licensed corpus manifest, differential runner, and Part 4 test integration | Every claimed row has a pinned input, expected result, malformed cases, and provenance |
| G1 | Generic integer component/sample model | Part 1-legal signedness, precision, component counts, and mixed sampling decode without an RGB/u16 assumption |
| G2 | General coding-style and quantization overrides | Divergent `COC`/`QCC` plus main- and tile-header `COD`/`QCD`/`COC`/`QCC` combinations reconstruct independently |
| G3 | Remaining Part 1 marker, tile-part, packet, and ROI breadth | `RGN` Maxshift, `CRG`, `PLM`, applicable `CAP`/`PRF`, legal `POC`/`PPM`/`PPT`, and non-trivial tile-part schedules pass strict decode and corruption gates |
| G4 | Scalable, selective, and bounded-memory decode | Layer, resolution, tile, and region selection plus incremental input/output produce the same requested samples as full decode |
| G5 | General Part 1 encoder | Generic components, per-component styles, ROI, tile-part scheduling, and practical rate/quality control round-trip through independent codecs |
| G6 | General JP2 tool surface | Raw codestream and JP2 workflows, legal palette/channel/colour/resolution mappings, and checked metadata preservation work without assuming sRGB |
| G7 | 1.0 conformance and hardening gate | Part 4 evidence, fuzz/corruption campaigns, resource limits, deterministic cross-platform builds, stable API/CLI, and no unresolved claimed-row discrepancy |

G0 is active. Its 2026-07-17 foundation includes an unscored broad capability
matrix plus a provenance/checksum/oracle manifest and strict corpus runner.
Seven committed foreign-encoded streams cover sampled origins/POC,
four-component CMYK, all T1 style bits, uniform COC/QCC, and padded multipart
TLM; four mutations pin malformed and unsupported fail-closed behavior. The
official WG1 T.803 checkout is additionally pinned as a local-only corpus: all
16 profile-0 streams and 18 class-0 PGX references are checksummed. Three
streams produce exact reduction-0 passes and 13 pin expected fail-closed
boundaries, for a complete 27-entry result of ten decode passes and 17 expected
fail-closed cases. The oracle already represents component/reduction selectors,
signed 1..16-bit PGX data, peak error, and MSE. G0 remains open for independent
fixtures covering the remaining rows. G4 has started with a bounded
`DecodeOptions.resolution_reduction` slice: single-tile reversible 5/3 and
irreversible 9/7 decode stop synthesis at the requested DWT level and compact
the reduced grid. Interleaved RGB supports no MCT plus the transform-appropriate
RCT or ICT; 5/3 no-MCT also supports native planar/grayscale output. The 9/7
path dequantizes only retained bands and uses checked nearest-integer rounding
plus precision saturation. Reduced RCT and ICT are applied to the compact
planes before output saturation. Packet headers remain fully validated,
but discarded detail subbands are now skipped before T1 entropy decode in both
sequential and parallel paths, with explicit skipped-block/byte timings. The
post-validation working catalog retains only selected subband payloads and
reports the retained/discarded byte split. Packet assembly receives the same
selection and never appends discarded bodies to its component-owned buffers;
the common single-tile inline path also borrows checked spans from the input
instead of owning a normalized packet-stream copy. SOP is validated and skipped
by span offset; EPH uses independently checked header/body spans. PPT/PPM retain
only decoded T2 headers in an auxiliary owned buffer and borrow their SOD
bodies. Sampling, multi-tile assembly, and native-planar 9/7 output remain
subsequent G4 gates. Class-1 all-component evaluation advances with G1/G2
decode breadth.

G1 must define a lossless internal carrier before adding source adapters above
16 bits. Part 1 samples are integers; floating-point codestream samples and
general multiple-component transforms belong to extension work rather than
being smuggled into this milestone. Diagnostic PGX/PAM/raw planar output is
needed for combinations that TIFF or a display-oriented conversion cannot
represent faithfully.

G2 and G3 replace the current byte-redundant/uniform override shortcuts with
real component- and tile-local semantics. Unknown or profile-inapplicable
markers must be validated deliberately, not blindly ignored. Packet indexing
created here becomes the basis for G4 random access instead of a second packet
parser.

G4 is part of codec completeness, not only an optimization campaign. Its first
bounded reduced-resolution synthesis, T1-selection, and post-validation
catalog-compaction slice has landed, and component assembly no longer creates
a complete-payload duplicate. The common unframed inline packet catalog is now
span-backed, including SOP/EPH framing; PPT/PPM use auxiliary header storage and
borrowed bodies rather than a full normalized stream. Reduced single-tile 5/3
and 9/7 now share the same selection and partial-synthesis path, including
no-MCT, RCT, and ICT output; 9/7 additionally performs selective
dequantization. Sampling, multi-tile selection, and native-planar 9/7 are the
next functional gates. A large image
still must not require retaining every discarded layer, tile, or pixel when the
caller requests a bounded subset.
Performance work continues in parallel, but no throughput result substitutes
for the phase evidence above.

G7 is an evidence gate, not a promise of third-party certification. A 1.0
release may claim only the conformance classes and matrix rows actually run;
formal certification must remain distinct from internal test success.

## Still Outside The Bounded Baseline Today

- arbitrary component counts, signed samples, and general mixed
  subsampling/precision combinations, planned under G1;
- divergent component/tile coding styles, remaining Part 1 ROI/registration
  markers, broad tile-part schedules, and selective decode, planned under
  G2-G4;
- automatic colour conversion beyond bounded sYCC 4:4:4/4:2:2/4:2:0;
- tiled/compressed TIFF variants and broad camera-RAW workflows;
- unchecked architecture-specific fast paths.

JPX composition and other Part 2-only box/codestream extensions, arbitrary
multiple-component transforms, floating-point extensions, HTJ2K/Part 15,
MJ2, JPM, and JPIP remain outside the Part 1/JP2 1.0 target. Each needs its own
scope, corpus, interoperability matrix, and release claim after G7.
