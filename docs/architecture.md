# z2000 Architecture

This document describes the current implementation. Historical scaffold and
campaign notes are preserved in
[`archive/architecture-2026-07-14.md`](archive/architecture-2026-07-14.md).
Strategy and execution order live in `roadmap.md` and `next_steps.md`.

## System Boundaries

z2000 has two deliberately separate codec surfaces:

1. an educational grayscale `.z2000` format used by early wavelet experiments;
2. the ISO JPEG2000/JP2 path used by TIFF/BMP conversion, strict codestream decode,
   interoperability, and benchmarks.

The ISO path is fail-closed. Marker parsing may recognize more syntax than the
payload pipeline supports, but a profile is accepted only when its transform,
quantization, T1, T2, tile, and container behavior agree end to end.

`src/main.zig` owns CLI routing and conversion policy. `src/tiff.zig` and the
isolated format modules own source-file parsing; the bounded BMP adapter maps
24/32-bit BI_RGB storage into the same owned `RgbImage` encode boundary.
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

The bounded public carrier supports one to four components. `RgbImage`,
`GrayImage`, and TIFF alpha layouts are conversion-layer views over those
planes. Alpha semantics remain explicit through TIFF ExtraSamples and JP2
`cdef`; the codec does not silently associate or unassociate samples.

Native component geometry is the strict decode boundary. Component upsampling
is a separate operation: `decodeLosslessPlanarUpsampled` performs
nearest-neighbour expansion anchored to absolute SIZ `XOsiz/YOsiz` and
`XRsiz/YRsiz`. It does not infer YCC or perform colour conversion.
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

SOP and EPH are validated at their signalled locations. PPT and PPM headers are
normalized into the same unframed packet view as inline headers. PLT-less
single-part streams derive payload spans from decoded packet headers; supported
multi-part layouts maintain tile-local packet state across parts.

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

The current sampled decode profile is no-MCT, reversible 5/3, RPCL, one or more
tiles, inline/PPT/PPM packet headers, all SOP/EPH combinations, independent
image and tile-partition origins, and checked POC in the main or first
tile-part header.
POC intervals may use any Part 1 progression and must cover every packet once.
PLT-less and packed-header state is component-local. Sampled PPM+POC remains
fail-closed.

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

## Verification Ownership

- focused unit tests live beside the imported modules through `src/tests.zig`;
- full build gates are listed in `next_steps.md`;
- external decoder evidence is summarized in `iso_coverage.md`;
- reproducible speed measurements belong in `benchmarks.md`;
- strategy changes update `roadmap.md`, while completed work updates
  `changelog.md`.
