# z2000 Architecture

This document describes the current implementation. Historical scaffold and
campaign notes are preserved in
[`archive/architecture-2026-07-14.md`](archive/architecture-2026-07-14.md).
Strategy and execution order live in `roadmap.md` and `next_steps.md`.

## System Boundaries

z2000 has two deliberately separate codec surfaces:

1. an educational grayscale `.z2000` format used by early wavelet experiments;
2. the ISO JPEG2000/JP2 path used by TIFF conversion, strict codestream decode,
   interoperability, and benchmarks.

The ISO path is fail-closed. Marker parsing may recognize more syntax than the
payload pipeline supports, but a profile is accepted only when its transform,
quantization, T1, T2, tile, and container behavior agree end to end.

`src/main.zig` owns CLI routing and conversion policy. `src/tiff.zig` and the
format modules own source-file parsing. `src/jp2.zig` owns JP2 boxes and colour/
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
`sampledRpclPackets` projects component-local precincts onto reference-grid
positions and merges them in canonical RPCL order.

The current sampled decode profile is no-MCT, reversible 5/3, RPCL, one or more
tiles, inline/PPT/PPM packet headers, all SOP/EPH combinations, matching
image/tile origins, and optional canonical-order POC in the main or first
tile-part header. PLT-less and packed-header state is component-local. Sampled
PPM+POC, reordered POC, and distinct tile-partition origins remain fail-closed.

The sampled writer currently emits one single tile in canonical RPCL order with
inline headers, PLT, and one or more untargeted quality layers. It encodes each
native component through the shared one-component machinery, then merges packet
streams using the same sampled RPCL sequence consumed by strict decode.
PLT-less/PPT/PPM and multi-tile sampled output are the next encode slices.

## JP2 And Metadata

`src/jp2.zig` validates the JP2 signature, `ftyp`, `jp2h`, `ihdr`, optional
`BPCC`, supported `colr`, bounded `pclr`/`cmap`/`cdef`, resolution boxes, and
exactly one contiguous codestream. Required ordering, duplicate boxes, lengths,
component precision, sampling, and SIZ agreement are checked.

Restricted ICC profiles are preserved byte-for-byte. Preservation is not colour
conversion. Unsupported JPX composition, arbitrary ICC interpretation, and
unknown component mappings fail closed.

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
