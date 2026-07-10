# API Notes

z2000 is not yet a stable library. This document describes the current internal
APIs and CLI surface so future changes have a map.

## CLI

Build:

```sh
zig build
zig build test
```

Custom grayscale codec:

```sh
zig build run -- encode input.pgm output.z2000 --wavelet 5-3 --levels 3 --quant 1
zig build run -- decode output.z2000 reconstructed.pgm
```

TIFF and temporary JP2 scaffold:

```sh
zig build run -- tiff-info input.tif
zig build run -- dng-info input.dng
zig build run -- tiff-to-jp2 input.tif output.jp2 [options]
zig build run -- jp2-info output.jp2
zig build run -- jp2-stats output.jp2
zig build run -- decode-temp-jp2 output.jp2 reconstructed.tif [--threads N]
```

Important `tiff-to-jp2` options:

- `--levels N` or `--resolutions N`
- `--tile W,H`
- `--progression RPCL|LRCP|RLCP|PCRL|CPRL`
- `--precincts "[256,256],[128,128]"`
- `--block N`
- `--layers N`
- `--rates R1,R2,...`
- `--mct rct|ict|none`
- `--transform 5-3|9-7`
- `--qstyle none|scalar-derived|scalar-expounded`
- `--tile-parts none|R`
- `--sop`, `--eph`, `--tlm`
- `--t1-backend iso-mq|legacy-mq`
- `--bypass`
- `--threads N`
- `--debug-temp-sidecar`
- `--timings`

Supported public JP2 profiles are still narrow:

- lossless RGB: `--mct rct --transform 5-3 --qstyle none`
- irreversible RGB: `--mct ict --transform 9-7` with scalar-expounded or
  scalar-derived quantization
- reversible component-independent RGB: `--mct none --transform 5-3 --qstyle none`
- all five Part 1 progression orders on the documented single-tile path;
  multi-layer LRCP and position-major PCRL/CPRL use one tile-part because their
  streams cannot be divided per resolution
- a v1/v2 aligned multi-tile lossless envelope: RCT/5-3, one or more
  untargeted quality layers for all five progression orders, one tile-part per
  tile, row-major tiles, the implemented CAUSAL/SEGMARK/terminated resilience
  styles, and ISO B.6/B.7 geometry constraints
- 8/16-bit chunky RGB TIFF input, with optional ICC tag preservation
- `--bypass` for the ISO-MQ backend, including terminated raw/MQ codeword
  segments and packet-header segment length accounting
- selected code-block style profiles where the payload model is implemented:
  TERMALL, BYPASS+TERMALL, TERMALL-scoped RESET, vertical-causal, segmentation
  symbols, and TERMALL-scoped predictable termination

Unsupported combinations still fail closed. Examples include standalone RESET,
standalone ERTERM, BYPASS combined with RESET or ERTERM, tile-part divisions
other than none/R, JPX features, unsupported component layouts, and profile
mixes outside the bounded envelope. In multi-tile mode, BYPASS without TERMALL
also remains unsupported.
SOP is enabled by default for the current narrow profile. EPH is available via `--eph`; current OpenJPEG/Grok
smoke tests cover the common no-EPH and archival EPH paths, while
valid2000/jpylyzer-style validators remain diagnostic gates rather than
absolute sources of truth.

## `src/codestream.zig`

Primary public types:

- `CodestreamError`
- `ProgressionOrder`
- `PrecinctSize`
- `MultipleComponentTransform`
- `WaveletTransform`
- `QuantizationStyle`
- `LosslessOptions`
- `EncodeTimings`
- `DecodeTimings`
- `DecodeOptions`
- `TemporaryStats`
- `ComponentStats`
- `QualityLayerStats`
- `EbcotSegmentStats`
- `StrictPacketBlock`
- `StrictPacketBlockCatalog`

Primary public functions:

- `encodeLosslessSkeleton(allocator, rgb, requested_levels)`
- `encodeLosslessWithOptions(allocator, rgb, options)`
- `encodeLosslessWithOptionsProfiled(allocator, rgb, options, timings)`
- `decodeLosslessTemporary(allocator, bytes)`
- `decodeLosslessTemporaryWithOptions(allocator, bytes, options)`
- `analyzeLosslessTemporary(bytes)`
- `hasMarker(bytes, marker)`
- `markerValue(name)`
- `firstSotPsot(bytes)`
- `firstTlmPtlm(bytes)`
- `readStrictPacketCatalog(allocator, bytes)`
- `auditStrictPacketHeaders(allocator, bytes)`
- `readStrictPacketBlockCatalog(allocator, bytes)`

Notes:

- `encodeLosslessWithOptions` writes JPEG2000 markers with strict packet
  payloads in `SOD`. Despite the historical name, it now covers the reversible
  RCT/5-3 path, reversible `mct none`, the irreversible ICT/9-7 scalar
  quantization path, all five progression orders on the documented single-tile
  path, and the v1 aligned multi-tile lossless envelope.
- The latest private payload is BP8 and is emitted only when
  `emit_temporary_payload_sidecar` / `--debug-temp-sidecar` is enabled.
- `decodeLosslessTemporary*` decodes normal no-sidecar codestreams by
  reconstructing T2 block payloads from strict `SOD` packets and inferring
  continuous MQ/T1 pass metadata from the payload. The strict path covers
  z2000-produced RCT/5-3, ICT/9-7, progression-order, quality-layer, and v1
  multi-tile profiles, plus selected foreign OpenJPEG/Grok/Kakadu streams where
  packet spans can be derived, including the current PLT-less single-tile
  lossless matrix. Debug BP8 sidecar files are still accepted as an oracle/compat
  path for the reversible profile.
- `readStrictPacketBlockCatalog` reconstructs per-component code-block packet
  metadata and owned payload views from strict `SOD`/PLT/T2 state without
  requiring private BP8 `COM` payloads.
- `DecodeTimings` reports the strict decode split for metadata, packet catalog,
  T1 block payload, inverse DWT, and inverse MCT. The packet catalog timing is
  further split into SOD/PLT scan, packet-header assembly, and final block
  catalog materialization; strict block-payload timing also includes worker
  balance counters for max/average job wall time, decoded block count, and
  payload bytes. T1/MQ pass and branch counters are collected only for timed
  decodes, keeping the normal strict decode hot path free of profiling writes.
- Encode-side RPCL catalog construction uses a deterministic cost-ordered
  queue across Y/Cb/Cr code-blocks when `threads > 3`; worker-local bitplane
  and EBCOT scratch buffers are reused while packet emission still reads stable
  per-component catalog indexes.
- Strict packet catalog parsing validates SOT/TLM/PLT marker accounting,
  ordered multi-segment TLM/PLT indexes, SOP/EPH marker policy, packet-header
  marker stuffing, and terminal `0xff` packet-header padding. It also has a
  PLT-less catalog branch that derives packet spans from packet headers; the
  current foreign-stream gate covers OpenJPEG/Grok/Kakadu default lossless
  files and OpenJPEG/Grok multi-layer lossless ladders.

## `src/jp2.zig`

Primary public types:

- `Jp2Error`
- `Info`

Primary public functions:

- `wrapRgbCodestream(allocator, input, codestream)`
- `parseInfo(bytes)`
- `extractCodestream(bytes)`
- `extractIccProfile(allocator, bytes)`

The supported box profile is intentionally narrow: signature box first, `ftyp`
second with `jp2 ` compatibility, a basic `jp2h` containing first `ihdr` and
sRGB enumerated `colr`, and one contiguous `jp2c` codestream. The reader accepts
8-bit and 16-bit RGB metadata and rejects JPX-only or non-sRGB color/profile
features until they are intentionally implemented. The writer applies the same
basic guard rails for RGB input: non-empty dimensions, 8/16 bit depth, and a
sample buffer matching `width * height * 3`.

ICC support is staged as metadata preservation before color conversion. TIFF
tag 34675 is stored as owned RGB image metadata, `wrapRgbCodestream` writes a
JP2 restricted ICC `colr` box when present, `parseInfo` reports ICC presence and
profile byte count, and `extractIccProfile` returns an owned copy of the profile
payload. eciRGBv2, Adobe RGB, and other RGB ICC profiles are treated as opaque
payloads and preserved without transforming samples. Profile conversion remains
a later optional LittleCMS-backed path.

## `src/t2.zig`

Primary public types:

- `PacketHeaderWriter`
- `PacketHeaderReader`
- `TagTreeEncoder`
- `TagTreeDecoder`
- `PacketBlock`
- `PacketBlockLocation`
- `CodeBlockGrid`
- `CodeBlockPacketState`
- `LayerTruncation`
- `LayerPacketBlock`
- `EncodedLayerBlock`
- `PrecinctPacketWriterState`
- `PrecinctPacketReaderState`

Primary public functions:

- `layerContribution(previous, current)`
- `packetBlockForLayer(location, nominal_bitplanes, encoded_bitplanes, previous, current)`
- `layerPayloadSlice(bytes, previous, current)`
- `bandResolutionIndex(levels, band)`
- `codeBlockPacketRect(block)`
- `codeBlockIntersectsRpclPacket(plan, packet, levels, bands, block)`
- `collectRpclCodeBlockIndexes(allocator, plan, packet, levels, bands, blocks)`
- `layerPacketBlockFor(encoded, layer_index)`
- `layerPacketBlocksForIndexes(allocator, encoded_blocks, indexes, layer_index)`
- `appendRpclPacketForIndexes(state, allocator, out, packet, expected_resolution, expected_component, expected_precinct, encoded_blocks, indexes)`
- `appendPrecinctLayerPacket(...)`
- `readPrecinctLayerPacket(...)`
- `zeroBitPlaneCount(nominal_bitplanes, encoded_bitplanes)`

Usage pattern for the new RPCL bridge:

1. Build an array of `EncodedLayerBlock` for one precinct in tag-tree leaf order.
2. Initialize `PrecinctPacketWriterState.initForEncodedBlocks`.
3. Use `collectRpclCodeBlockIndexes` to select packet-relevant code-blocks.
4. Use `appendRpclPacketForIndexes` for each layer packet.
5. Keep the writer state alive across layers for the same precinct.

The RPCL writer/reader state is intentionally strict: it tracks the configured
layer count, next layer, next sequence, precinct coordinates, tag-tree lows and
known-node state, `numlenbits`, and cumulative pass/byte deltas.
`readRpclPacket` consumes exactly one packet slice and rejects trailing bytes.

## `src/packet_plan.zig`

Primary public types:

- `Precinct`
- `Rect`
- `Resolution`
- `Plan`
- `Packet`
- `RpclIterator`
- `LrcpIterator`
- `RlcpIterator`

Primary public functions:

- `rpclSingleTile(width, height, levels, components, layers, precincts)`
- `rpclPacketAt(plan, components, layers, sequence)`
- `precinctRect(plan, resolution_index, precinct_index)`
- `rectsIntersect(a, b)`

`RpclIterator` emits packets in resolution, precinct, component, layer order.
The non-RPCL progression orders are implemented as stream-order permutations
over the same packet body model: LRCP, RLCP, PCRL, and CPRL build deterministic
packet sequences for the writer and strict reader, then catalog entries are
reordered back to the internal RPCL grouping used by downstream reconstruction.
Future progression/tile-part combinations must still stay fail-closed until
their packet writer, strict reader, packet-state lifetime, corruption tests, and
interop gates exist.

## `src/ebcot.zig`

Primary public types:

- `PassKind`
- `Context`
- `SymbolKind`
- `Symbol`
- `Pass`
- `CodeBlockPassPayload`
- `EncodedBlock`
- `CodeBlockSegment`
- `CodeBlockStyle`
- `EncodedBlockView`
- `BlockScratch`
- `DirectBlockScratch`

Primary public functions:

- `encodeBlock(allocator, plane, stride, rect)`
- `encodeBlockScratch(scratch, plane, stride, rect)`
- `encodeSymbolsMq(allocator, symbols)`
- `decodeSymbolBitsMq(allocator, bytes, symbol_count, symbols)`
- `encodeCodeBlockSegment(allocator, plane, stride, rect)`
- `encodeCodeBlockSegmentContinuous(allocator, plane, stride, rect)`
- `encodeCodeBlockSegmentDirect(allocator, plane, stride, rect)`
- `encodeCodeBlockSegmentDirectScratch(scratch, plane, stride, rect)`
- `encodeBlockSymbolsSegment(allocator, block)`
- `decodeCodeBlockSegmentBits(allocator, segment, symbols)`
- `decodeCodeBlockSegmentCoefficients(allocator, segment, width, height)`
- `decodeCodeBlockPayloadContinuousInferred(allocator, bitplanes, pass_count, bytes, width, height)`
- `decodeCodeBlockSegmentCoefficientsPartial(allocator, segment, width, height)`
- `decodeCodeBlockSegmentCoefficientsContinuousPartial(allocator, segment, width, height)`

`CodeBlockSegment` carries MQ bytes plus per-pass byte offsets and cumulative
truncation points. It is the bridge from T1 work into T2 packet payloads.
`decodeCodeBlockSegmentCoefficients` reconstructs a single current-model
code-block from those MQ pass payloads without using the old private bitplane
payload; the partial variant decodes complete coding-pass prefixes from quality
layer truncation points for strict ISO packet validation.
The current codestream path uses continuous MQ code-block segments for quality
layers. The symbol oracle and direct MQ path remain useful test and comparison
surfaces, and share SIMD-aware block-stat scanning so bitplane and non-zero
metadata stay aligned across portable, AVX2-width, and NEON-width builds.

The direct ISO-MQ path is the default T1 backend. Cleanup run mode, directional
sign prediction contexts, refined magnitude-refinement contexts, direct MQ
emission, BYPASS raw segments, and terminated codeword segment metadata are
covered by oracle tests in the current narrow path. Segmentation-symbol cleanup
trailers, terminate-all pass-terminated MQ slices, vertical-causal context
formation, TERMALL-scoped reset-context, and TERMALL-scoped ERTERM are wired
through public codestream paths where their payload behavior has writer,
reader, tests, and interop coverage. BYPASS+TERMALL is locally public with
per-pass raw/MQ segment lengths and strict decode; OpenJPEG and Grok decode the
current smoke losslessly, with Kakadu still to check. The aligned multi-tile
envelope accepts all five progression orders with untargeted quality layers,
CAUSAL, SEGMARK, RESET+TERMALL, ERTERM+TERMALL, and BYPASS+TERMALL.
Larger no-sidecar ERTERM files are
accepted by z2000 strict decode, OpenJPEG, Grok, and Kakadu, including the
block-parallel strict decode path. Unsupported combinations, such as standalone
RESET or BYPASS with ERTERM/RESET, still return `UnsupportedPayload`.
The inferred continuous payload decoder and partial coefficient decode helpers
accept the same internal style state for future strict T2 audits and
quality-layer prefix validation; inferred decode rejects terminate-all payloads
because pass byte lengths are required.

## `src/rate_alloc.zig`

Primary public types:

- `Block`
- `PcrdBlock`
- `Truncation`

Primary public functions:

- `allocateEven(out, block)`
- `allocateFromCompressionRatios(out, block, rates)`
- `allocatePcrdPasses(allocator, blocks, layer_targets, out_passes)`

The allocator works on cumulative pass and byte targets. The legacy helpers
keep even and compression-ratio allocation available for tests, while the
current rate-driven path uses PCRD-style global slope allocation over
per-block distortion metadata. T2 then converts the chosen cumulative points
into per-layer deltas.

## `src/subband.zig`

Primary public types:

- `Kind`
- `Rect`
- `Band`
- `CodeBlock`

Primary public functions:

- `makeBands(allocator, width, height, levels)`
- `makeCodeBlocks(allocator, bands, block_width, block_height)`

Subband rectangles are currently used both for temporary payload ordering and
for RPCL packet selection.

## Stability Notes

- Public module functions are still internal project APIs, not a committed
  external library contract.
- Error behavior should remain fail-closed for unsupported JPEG2000 profiles.
- Existing tests are the best source of intended behavior for edge cases.
- Interop and benchmark updates should report z2000, Grok, OpenJPEG, and Kakadu
  encode/decode time, output bytes, strict reader status, and roundtrip
  correctness for single-thread and multi-thread runs.
