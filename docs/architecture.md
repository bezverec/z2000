# z2000 Architecture

z2000 is an educational JPEG2000-style codec core written from scratch in Zig.
The current codebase has two codec surfaces:

- a small custom grayscale `.z2000` path used for early wavelet experiments;
- a JP2 path for RGB TIFF input, with strict packet payloads in `jp2c`,
  selected Part 1 profiles, strict no-sidecar decode, and an optional private
  debug sidecar.

The project is intentionally fail-closed. Profile options that would require
payload behavior not implemented yet are rejected with `UnsupportedPayload`.

The codec-core roadmap is separate from the future conversion-tool roadmap. The
current architecture optimizes for a correct JPEG2000 Part 1 core first; later
input formats such as JPEG, PNG, BMP, RAW/DNG, and OpenEXR, broader color spaces
such as monochrome, palette, YCC/eYCC, CIELab, and CMYK, richer metadata
families such as EXIF/IPTC/XMP, and component depths above 16 bits should enter
through explicit front-end modules and strict metadata/color-management
contracts rather than ad hoc changes inside T1/T2.

## High-Level Pipeline

Current RGB TIFF to JP2 encode:

1. `src/tiff.zig` reads a narrow subset of TIFF 6.0:
   uncompressed chunky RGB, 8 or 16 bits per channel, strip storage, and an
   optional embedded ICC profile from tag 34675.
2. `src/color.zig` converts RGB samples through RCT, ICT, or no-MCT depending
   on the accepted profile.
3. `src/wavelet_int.zig` and `src/wavelet_float.zig` apply the reversible
   integer 5/3 or irreversible 9/7 transform.
4. `src/subband.zig` builds subband and code-block grids.
5. `src/bitplane.zig` can still write the old debug sidecar block payload.
6. `src/ebcot.zig` builds EBCOT-style coding passes and MQ-backed code-block
   segment bytes used by the current RPCL packet payload.
7. `src/rate_alloc.zig` maps quality layers or target rates to cumulative
   code-block truncation points; the rate-targeted path uses global PCRD over
   per-pass distortion metadata and then charges measured T2 header overhead.
8. `src/packet_plan.zig` describes packet order and precinct geometry for the
   implemented progression orders.
9. `src/t2.zig` owns packet-header primitives, tag-trees, layer deltas,
   packet read/write state, and RPCL packet assembly helpers.
10. `src/codestream.zig` writes JPEG2000 markers, PLT-backed RPCL tile-part
    payloads, and optional debug private `COM` sidecar metadata.
11. `src/jp2.zig` wraps the codestream in JP2 boxes, using enumerated sRGB
    `colr` by default or restricted ICC `colr` when the TIFF supplied an ICC
    profile.

JP2 decode for z2000-produced files now uses the strict RPCL packet block
catalog for the current RPCL/RCT/5-3 path. Debug sidecar decode remains as an
oracle/compatibility path. If the JP2 wrapper carries a restricted ICC color
profile, `decode-temp-jp2` preserves it back into TIFF tag 34675 without color
conversion.

## Codestream Layers

`src/codestream.zig` is currently the integration hub. It writes:

- `SIZ`, `COD`, `QCD`;
- optional `TLM`, including ordered multi-segment TLM in the strict reader;
- tile-part headers with `SOT`/`SOD`/`EOC`;
- optional `SOP` and `EPH` marker instances. SOP is enabled by default; EPH is
  currently opt-in because the independent-decoder interop gate is more stable
  without it while packet-header/state semantics are hardened for Grok and
  Kakadu;
- `PLT` packet-length marker segments, including ordered multi-segment PLT in
  the strict reader;
- tile-part `COM` comments, accepted as metadata before `SOD`;
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
- optional segmentation-symbol cleanup trailers in the standalone T1 style
  test path;
- optional reset-context behavior in the standalone continuous MQ style path,
  preserving one payload stream while resetting MQ probability states between
  coding passes, plus public TERMALL-scoped RESET in the ISO-MQ codestream path;
- optional terminate-all behavior in the standalone T1 style path, storing
  pass-terminated MQ byte slices with explicit pass payload lengths;
- optional vertical-causal context formation in the standalone T1 style path,
  ignoring south neighbors across four-row stripe boundaries;
- inferred continuous MQ/T1 payload decoding with the same internal style state
  so strict packet audits can validate styled payloads without stored pass
  templates;
- style-aware partial coefficient decoding for pass-prefix quality-layer
  validation;
- explicit internal `CodeBlockStyle` metadata for all six COD style bits, with
  BYPASS, BYPASS+TERMALL, TERMALL-scoped RESET, and TERMALL-scoped predictable
  termination carried through the strict payload path;
- MQ encode/decode roundtrip tests;
- direct MQ emission with scratch-buffer reuse;
- shared SIMD-aware code-block stats for the symbol oracle and direct MQ path;
- per-pass byte truncation metadata for quality layers.

The implementation is still not a complete Part 1 T1 coder. Strict codestream
metadata policy is fail-closed per combination: a COD code-block style byte is
accepted only when the matching payload model is wired through T1, T2 segment
lengths, strict decode, tests, and interop smoke. BYPASS, TERMALL,
TERMALL-scoped RESET, BYPASS+TERMALL, vertical-causal, TERMALL-scoped ERTERM,
and segmentation-symbol profiles are public where their segment model exists;
large no-sidecar ERTERM files are green through z2000 strict decode, OpenJPEG,
Grok, and Kakadu. BYPASS+TERMALL is strict-decode covered and lossless through
OpenJPEG/Grok/Kakadu on the current smoke, and the aligned multi-tile style
matrix has a reproducible Kakadu gate. Standalone RESET is public only on the
single-tile ISO-MQ envelope; standalone ERTERM and untested combinations still
return `UnsupportedPayload`. The next T1 work should
continue tightening remaining cleanup edge cases, COD-driven termination
combinations, and byte-for-byte oracle coverage.

## T2 Direction

`t2.zig` owns the current T2 building blocks:

- marker-safe packet-header bit IO, including terminal `0xff` stuffing/padding
  so PLT packet lengths match independent decoder packet parsers;
- tag-tree encoder/decoder with known-node state so continued packets do not
  consume duplicate inclusion bits for already proven leaves;
- code-block packet state;
- coding pass count and segment length coding;
- first inclusion and zero bit-plane handling;
- layer contribution deltas;
- precinct packet writer/reader;
- RPCL packet helpers over encoded block catalogs.

The bridge pieces that feed both the current v1 path and future broader tile
support are:

- `collectRpclCodeBlockIndexes`, which maps an RPCL packet to code-block indexes;
- `layerPacketBlocksForIndexes`, which converts encoded blocks into packet blocks;
- `appendRpclPacketForIndexes`, which appends a packet from selected encoded
  blocks and updates writer state.
- RPCL writer/reader state now tracks layer bounds, next layer, next sequence,
  precinct coordinates, inclusion tag-tree state, zero-bitplane tag-tree state,
  tag-tree known-node state, `numlenbits`, cumulative pass/byte deltas, and
  strict whole-packet consumption.
- The standalone tile-local RPCL packet stream can now be read back through T2
  packet-header state immediately after emission. The validator checks packet
  inclusion bits, header byte lengths, decoded pass/byte deltas, and payload
  slices against the tile-local encoded block catalog before this path is wired
  into real multi-tile codestream output.
- `tile_pipeline.TileRpclEncodeArtifacts` now owns the complete per-tile
  encode-side scaffold for this future writer path: tile-local packet scaffold,
  EBCOT encoded block catalog, precomputed RPCL packet index, and validated RPCL
  packet stream. This is still isolated from production codestream output, but
  it is shaped as the unit that can later move through a persistent tile work
  queue.
- `tile_pipeline.TileRpclEncodeGridArtifacts` builds those owned per-tile
  artifacts for an entire `tile_grid.Grid` in deterministic row-major order.
  The current implementation is intentionally serial and acts as the correctness
  baseline for later worker-pool scheduling.
- A parallel tile-grid artifact builder now uses an atomic tile index queue while
  storing results back by tile index, so its output can be compared byte-for-byte
  against the serial builder. It is still a standalone scaffold and does not
  enable multi-tile codestream emission.
- The parallel tile-grid builder consumes a deterministic cost-ordered work list
  (larger tile rectangles first, tile-index tie break) before writing results
  back to row-major tile slots. This improves future load balance on edge-tile
  grids without changing output order.
- A standalone tile-part layout pass now derives one future tile-part per tile
  from the grid artifacts, including packet counts, raw/framed packet byte
  totals, PLT byte counts, and `Psot` values. This provides the next SOT/TLM/PLT
  writer input while multi-tile codestream output remains fail-closed.
- The tile-part layout can now be converted into a standalone TLM plan with
  `(tile index, Psot)` entries, using 16-bit tile indexes and 32-bit tile-part
  lengths for the future multi-tile marker writer.
- The same layout can now produce a PLT plan with framed packet lengths grouped
  per future tile-part, keeping raw T2 packet streams separate from SOP/EPH
  framing overhead while preserving the marker byte counts used by `Psot`.
- The TLM and PLT plans now have standalone marker-segment byte writers in the
  tile pipeline scaffold. They emit complete `TLM`/`PLT` marker segments for the
  future multi-tile codestream writer.
- The same scaffold can now write one complete standalone future tile-part byte
  buffer per tile: `SOT`, optional `PLT`, `SOD`, and the RPCL packet stream with
  optional `SOP`/`EPH` framing. Tests parse the generated tile-part bytes back to
  marker fields and packet payload slices. This is still not connected to normal
  encode output.
- A standalone tile-part sequence writer can concatenate all row-major future
  tile-parts, optionally prefixed by the derived `TLM` marker segment. Tests
  compare every emitted tile-part slice with the per-entry writer output so the
  future codestream writer can consume the same checked sequence without
  changing production multi-tile policy yet.
- The sequence writer also has an owned indexed form that carries the emitted
  bytes, the `TLM` byte span, and every tile-part offset. This gives future
  codestream assembly and strict multi-tile validation exact byte ranges instead
  of rediscovering them by scanning markers.
- A standalone codestream-fragment wrapper can now place that indexed tile-part
  sequence between `SOC` and `EOC`, preserve all tile-part offsets shifted past
  `SOC`, and validate each `SOT/Psot` span. It is still a scaffold, but it gives
  the future multi-tile writer a checked byte shape that is closer to Part 1
  codestream structure.
- The same fragment shape now has a standalone strict parser that rebuilds the
  `TLM` span and tile-part offset map from bytes, verifies `SOC`, `EOC`,
  `SOT/Psot`, and `SOD` boundaries, and rejects targeted corruptions before this
  logic is connected to public multi-tile decode.
- The fragment parser also decodes the scaffold's explicit `TLM` form
  (`Stlm=0x60`, 16-bit tile index plus 32-bit `Psot`) and validates each entry
  against the parsed tile-part `SOT/Psot` fields. Unsupported `TLM` encodings
  remain fail-closed in this standalone path.
- The fragment parser also decodes ordered `PLT` marker segments per tile-part,
  expands JPEG2000 variable-length packet lengths, and validates that their sum
  exactly covers the parsed `SOD` payload bytes. Corrupted `Zplt`, malformed
  packet-length coding, and marker mismatches remain deterministic
  `InvalidPacket` failures while this stays a standalone multi-tile scaffold.
- The same parsed `PLT` lengths can now be materialized as packet spans relative
  to each tile-part `SOD` payload, giving future strict T2 integration exact
  byte views for packet-by-packet decode without another marker scan.
- The standalone fragment can also be checked packet-by-packet against the
  tile-grid encode artifacts. That validation walks each parsed tile-part,
  verifies `SOT` tile identity, expands PLT packet spans, checks SOP/EPH framing
  when enabled, and compares every framed packet payload slice against the
  tile-local RPCL packet stream. This is still internal scaffolding, but it is
  the shape needed before real multi-tile SOD payloads are accepted by the
  strict reader.
- Parsed tile-part packet spans can now be stripped from SOP/EPH framing back
  into a raw tile-local RPCL packet stream. The standalone fragment validator
  feeds that reconstructed stream through the existing T2 packet reader state
  against the tile-local EBCOT catalog, so malformed packet headers or payloads
  are rejected after real T2 header/body decode rather than only by byte-length
  checks.
- The fragment parser can now derive a marker-only tile-part audit table:
  tile index, tile-part index/count, `Psot`, PLT bytes, packet count, framed
  packet bytes, and raw packet bytes after SOP/EPH overhead removal. Tests cover
  both SOP/EPH-framed tile-parts and the no-framing default shape.
- `TLM` remains optional in the standalone codestream fragment path. Tests now
  cover full `SOC -> SOT/PLT/SOD -> EOC` fragments without `TLM`, including the
  same PLT audit, artifact comparison, and T2 readback checks used by the
  TLM-present path.
- A separate single-part tile-order validator now checks the current narrow
  scaffold policy: parsed tile-parts must appear in row-major tile-index order,
  and every tile must have exactly one tile-part. This keeps the parser
  reusable while making the current fail-closed multi-tile assumptions explicit
  before real tile-part division is enabled.
- Tile-local encode artifact construction now validates encoded block catalog
  coverage before packet indexing: for each component, code-block rectangles
  must match the scaffold, cover the entire tile-local transformed plane, and
  never overlap. This is a decode-readiness guard for future pixel
  reconstruction.
- The same tile-local encoded catalogs can now be reconstructed back to RGB in a
  standalone grid path: direct-ISO T1 payloads are decoded through the inferred
  continuous ISO-MQ decoder, coefficient blocks are copied into tile-local
  transformed planes, inverse 5-3 and inverse RCT run per tile, and edge tiles
  are copied back into the full image. This is still internal scaffolding, but
  it proves the future multi-tile decode half has enough per-tile information
  for pixel reconstruction.

The current strict path connects T2 packet views to real T1 image
reconstruction from the EBCOT/MQ payload and has closed the known PLT
packet-length mismatch caused by terminal packet-header stuffing. RPCL remains
the primary internal grouping for reconstruction, but all five Part 1
progression orders are public on the documented single-tile path: LRCP, RLCP,
PCRL, and CPRL are emitted/read as deterministic stream-order permutations and
then normalized back to the internal RPCL grouping.

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
The strict marker layer validates SOT tile-part sequence/count, TLM tile indexes
and Psot values, PLT packet spans and ordered Zplt indexes, SOP/EPH policy and
duplicates, and packet-header marker stuffing before packet payloads are exposed
to T1 reconstruction.

## Parallelism And Scratch Reuse

The current TIFF/JP2 encoder is deterministic across thread counts.

- `threads=1`: serial path.
- `threads=2..3`: component-level scheduling for Y, Cb, Cr.
- `threads>3`: code-block catalog work for Y, Cb, and Cr is flattened into one
  deterministic queue ordered by estimated block cost, pulled atomically by
  workers, and encoded with per-worker scratch buffers. The resulting catalogs
  keep stable component/block indexes, so packet emission remains deterministic
  in RPCL order.

Hot-path scratch reuse currently exists in bitplane, entropy, and direct EBCOT
encoding paths. SIMD lane selection is centralized in `src/simd.zig`, with
portable vector widths selected for native x86 and AArch64 targets.
Strict decode also uses an atomic block queue; block indexes are ordered by
payload size before dispatch so expensive T1 blocks are spread across workers.
For the common single-layer strict path, T2 packet assembly stores code-block
payload bytes in component-owned buffers and transfers those buffers into the
strict block catalog, avoiding a second payload copy during catalog finalize.
The same single-layer path also builds short-lived packet audit groups from a
retained per-packet arena, reducing allocator churn while keeping multi-layer
reader state on the original long-lived allocation path.
During strict reconstruction, coefficient planes are zero-initialized only when
the packet block catalog contains zero blocks; dense single-layer outputs rely
on decoded block scatter to cover the whole plane.
ReleaseFast T1 significance/refinement/cleanup encode and decode also have
plain neighborhood-flag paths for the common style without vertical causal
mode. Debug builds retain the packed-context shadow assertions.

## Tile Grid Foundation

`src/tile_grid.zig` owns the JPEG2000 reference-grid tile geometry used by the
encoder, strict SIZ validation, and the current public multi-tile envelope. It
computes tile columns, rows, total tile count, clipped edge-tile rectangles for
non-divisible image dimensions and non-zero reference origins, plus row-major
tile descriptors. It also provides tile-local RGB sample extraction and
copy-back helpers so per-tile encode/decode work can move rectangular image
regions without ad hoc row math. Multi-tile support is intentionally bounded:
lossless RCT/5-3, quality layers across all five progression orders,
tile-local rate targets in the bounded reversible profile, one tile-part per
tile, deterministic row-major encode, reordered foreign tile-part decode,
plain coding and the implemented
CAUSAL/SEGMARK/terminated resilience combinations, and ISO B.6/B.7-aligned
geometry.

`src/tile_pipeline.zig` is the tile-local implementation layer. It runs the
reversible component transform, tile-local 5/3 DWT/inverse-DWT, T1 code-block
encoding, tile-local packet indexing, T2 packet emission, tile-part assembly,
and strict tile-local decode/reconstruction for the v1 envelope. The earlier
standalone fragment/parser scaffolds remain useful as unit-test surfaces, but
the public path now uses the same concepts to write and decode genuine
multi-tile codestreams.

## Remaining Boundaries

These are intentionally not treated as complete yet:

- arbitrary JP2/JPX box families and JPX-only features;
- arbitrary component layouts, subsampling, palettes, alpha channels, and
  variable bits-per-component;
- multi-tile combinations outside the bounded envelope, including BYPASS
  without TERMALL, unsupported style combinations, global cross-tile rate
  budgeting, and tile-part divisions beyond the current supported policy;
- BYPASS combined with standalone RESET/ERTERM, other unsupported style
  envelopes, and untested code-block style combinations;
- broader PLT-less foreign decode coverage beyond the current single-tile
  lossless OpenJPEG/Grok/Kakadu matrix and aligned OpenJPEG/Grok/Kakadu
  multi-tile PLT-less smoke;
- general-purpose lossy decode/error-bound coverage beyond the current narrow
  ICT/9-7/scalar-quantization gates.

## Interop Gates

Each major ISO-facing slice should be checked against OpenJPEG, Grok, and
Kakadu where the current feature set is expected to be accepted. The gate should
record encode time, decode time, output bytes, marker conformance, strict reader
validation, and roundtrip correctness for both single-thread and multi-thread
runs.
