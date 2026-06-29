# z2000 Architecture

z2000 is an educational JPEG2000-style codec core written from scratch in Zig.
The current codebase has two codec surfaces:

- a small custom grayscale `.z2000` path used for early wavelet experiments;
- a narrow JP2/RPCL/RCT/5-3 path for RGB TIFF input, with strict packet
  payloads in `jp2c` and an optional private debug sidecar.

The project is intentionally fail-closed. Profile options that would require
payload behavior not implemented yet are rejected with `UnsupportedPayload`.

## High-Level Pipeline

Current RGB TIFF to temporary JP2 encode:

1. `src/tiff.zig` reads a narrow subset of TIFF 6.0:
   uncompressed chunky RGB, 8 or 16 bits per channel, strip storage.
2. `src/color.zig` converts RGB samples into reversible RCT planes.
3. `src/wavelet_int.zig` applies the reversible integer 5/3 transform.
4. `src/subband.zig` builds subband and code-block grids.
5. `src/bitplane.zig` can still write the old debug sidecar block payload.
6. `src/ebcot.zig` builds EBCOT-style coding passes and MQ-backed code-block
   segment bytes used by the current RPCL packet payload.
7. `src/rate_alloc.zig` maps quality layers or target rates to cumulative
   code-block truncation points.
8. `src/packet_plan.zig` describes RPCL packet order and precinct geometry.
9. `src/t2.zig` owns packet-header primitives, tag-trees, layer deltas,
   packet read/write state, and RPCL packet assembly helpers.
10. `src/codestream.zig` writes JPEG2000 markers, PLT-backed RPCL tile-part
    payloads, and optional debug private `COM` sidecar metadata.
11. `src/jp2.zig` wraps the codestream in JP2 boxes.

JP2 decode for z2000-produced files now uses the strict RPCL packet block
catalog for the current RPCL/RCT/5-3 path. Debug sidecar decode remains as an
oracle/compatibility path.

## Codestream Layers

`src/codestream.zig` is currently the integration hub. It writes:

- `SIZ`, `COD`, `QCD`;
- optional `TLM`;
- tile-part headers with `SOT`/`SOD`/`EOC`;
- optional `SOP` and `EPH` marker instances;
- `PLT` packet-length marker segments;
- an optional debug private payload sidecar identified by `ZJ2K-CBLK-BP*`,
  stored in chunked `COM` marker segments when explicitly requested.

The latest debug sidecar payload version is `BP8`. It keeps the old bitplane
streams for legacy project-private checks, carries actual EBCOT/MQ bytes per
code-block segment, and stores a shadow RPCL packet stream built by the T2
writer. That RPCL packet stream is now the primary tile-part `SOD` payload, and
its packet lengths are the source for `PLT`. The private sidecar is no longer
emitted by default; it remains as a debug/compatibility oracle while strict T1
behavior continues to move closer to Part 1.

## T1 Direction

The T1 work is split into two paths:

- `bitplane.zig`: legacy debug sidecar payload writer/reader.
- `ebcot.zig`: JPEG2000-style coding pass and MQ segment work.

`ebcot.zig` has:

- cleanup, significance, and refinement pass metadata;
- zero, sign, and refinement context selection shared by the symbol oracle,
  direct MQ encoder, and coefficient decoder;
- cleanup run-mode aggregation/run-length symbols for full four-row clean
  stripes;
- MQ encode/decode roundtrip tests;
- direct MQ emission with scratch-buffer reuse;
- shared SIMD-aware code-block stats for the symbol oracle and direct MQ path;
- per-pass byte truncation metadata for quality layers.

The implementation is still not a complete Part 1 T1 coder. Code-block style
options such as BYPASS, RESET, TERMALL, vertical causal, predictable
termination, and segmentation symbols are parsed but rejected with
`UnsupportedPayload` until their exact payload effect is implemented. The next
T1 work should continue tightening remaining cleanup edge cases, COD-driven
termination/reset behavior, and byte-for-byte oracle coverage before the
options are advertised as supported.

## T2 Direction

`t2.zig` owns the current T2 building blocks:

- marker-safe packet-header bit IO;
- tag-tree encoder/decoder;
- code-block packet state;
- coding pass count and segment length coding;
- first inclusion and zero bit-plane handling;
- layer contribution deltas;
- precinct packet writer/reader;
- RPCL packet helpers over encoded block catalogs.

The most recent bridge pieces are:

- `collectRpclCodeBlockIndexes`, which maps an RPCL packet to code-block indexes;
- `layerPacketBlocksForIndexes`, which converts encoded blocks into packet blocks;
- `appendRpclPacketForIndexes`, which appends a packet from selected encoded
  blocks and updates writer state.
- RPCL writer/reader state now tracks layer bounds, next layer, next sequence,
  precinct coordinates, inclusion tag-tree state, zero-bitplane tag-tree state,
  `numlenbits`, cumulative pass/byte deltas, and strict whole-packet
  consumption.

The next integration step is to connect strict T2 packet views to real T1 image
reconstruction from the EBCOT/MQ payload, then close packet-header differences
reported by independent decoders. RPCL remains the priority path; LRCP, PCRL,
and CPRL stay fail-closed until their ordering is implemented on both write and
read sides.

The strict RPCL validation path now also reassembles per-code-block payload
contributions from decoded T2 packets and compares the resulting cumulative
bytes/pass state against the BP8 EBCOT/MQ catalog when the debug sidecar is
present.
The same strict SOD-backed assembly can now be exposed as a block catalog with
per-component block metadata and owned payload views, so stats and the next T1
decode step no longer need BP8 just to recover T2 packet state. When BP8 is
present, validation also compares that public strict block catalog against the
BP8 EBCOT catalog for geometry, cumulative pass/byte deltas, and payload bytes.
For complete block payloads, validation also runs the assembled bytes through
the continuous MQ T1 coefficient decoder. Layer-truncated blocks now decode
available complete coding-pass prefixes and keep byte/pass validation as the
outer T2 guard. The decoded blocks are now scattered back into full component
coefficient planes with bounds, overlap, and coverage checks, then fed through
inverse DWT/RCT. Complete-block BP8/RPCL decodes now return the strict `SOD`
image, with the temporary sidecar decode retained as a sample-for-sample oracle.
Normal no-sidecar files on the current RPCL/RCT/5-3 path also decode from the
strict block catalog: zero blocks get geometry from the codestream-derived
subband layout, and included blocks infer continuous MQ/T1 pass metadata from
their SOD payload bytes. Quality layers now use the same continuous MQ segment
and their T2 byte ranges are snapped to actual coding-pass truncation points.

## Parallelism And Scratch Reuse

The current TIFF/JP2 encoder is deterministic across thread counts.

- `threads=1`: serial path.
- `threads=2..3`: component-level scheduling for Y, Cb, Cr.
- `threads>3`: component order remains stable while code-block ranges are
  encoded in parallel with per-worker scratch buffers.

Hot-path scratch reuse currently exists in bitplane, entropy, and direct EBCOT
encoding paths. SIMD lane selection is centralized in `src/simd.zig`, with
portable vector widths selected for native x86 and AArch64 targets.

## Current Non-Goals

These are intentionally not treated as complete yet:

- arbitrary progression orders;
- real multi-tile payload layout;
- ICT and irreversible 9/7 JP2 output;
- scalar-derived or scalar-expounded JP2 quantization payloads;
- JPX-only box features;
- independent-decoder-compatible T1 payload conformance;
- full code-block style bit behavior in T1.

## Interop Gates

Each major ISO-facing slice should be checked against OpenJPEG, Grok, and
Kakadu where the current feature set is expected to be accepted. The gate should
record encode time, decode time, output bytes, marker conformance, strict reader
validation, and roundtrip correctness for both single-thread and multi-thread
runs.
