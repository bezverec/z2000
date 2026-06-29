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
- `--progression RPCL`
- `--precincts "[256,256],[128,128]"`
- `--block N`
- `--layers N`
- `--rates R1,R2,...`
- `--mct rct`
- `--transform 5-3`
- `--qstyle none`
- `--tile-parts none|R`
- `--sop`, `--eph`, `--tlm`
- `--threads N`
- `--debug-temp-sidecar`
- `--timings`

Unsupported progression orders, ICT, 9-7 JP2 output, scalar quantization,
multi-tile requests, unsupported tile-part divisions, and code-block style
options whose payload behavior is not implemented should fail closed.

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

- `encodeLosslessWithOptions` writes JPEG2000 markers with strict RPCL packet
  payloads in `SOD`.
- The latest private payload is BP8 and is emitted only when
  `emit_temporary_payload_sidecar` / `--debug-temp-sidecar` is enabled.
- `decodeLosslessTemporary*` decodes normal no-sidecar codestreams for the
  current RPCL/RCT/5-3 path by reconstructing T2 block payloads from strict
  `SOD` packets and inferring continuous MQ/T1 pass metadata from the payload.
  Debug BP8 sidecar files are still accepted as an oracle/compat path.
- `readStrictPacketBlockCatalog` reconstructs per-component code-block packet
  metadata and owned payload views from strict `SOD`/PLT/T2 state without
  requiring private BP8 `COM` payloads.

## `src/jp2.zig`

Primary public types:

- `Jp2Error`
- `Info`

Primary public functions:

- `wrapRgbCodestream(allocator, input, codestream)`
- `parseInfo(bytes)`
- `extractCodestream(bytes)`

The supported box profile is intentionally narrow: signature box first, `ftyp`
second with `jp2 ` compatibility, a basic `jp2h` containing first `ihdr` and
sRGB enumerated `colr`, and one contiguous `jp2c` codestream. The reader accepts
8-bit and 16-bit RGB metadata and rejects JPX-only or non-sRGB color/profile
features until they are intentionally implemented.

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
layer count, next layer, next sequence, precinct coordinates, tag-tree lows,
`numlenbits`, and cumulative pass/byte deltas. `readRpclPacket` consumes exactly
one packet slice and rejects trailing bytes.

## `src/packet_plan.zig`

Primary public types:

- `Precinct`
- `Rect`
- `Resolution`
- `Plan`
- `Packet`
- `RpclIterator`

Primary public functions:

- `rpclSingleTile(width, height, levels, components, layers, precincts)`
- `rpclPacketAt(plan, components, layers, sequence)`
- `precinctRect(plan, resolution_index, precinct_index)`
- `rectsIntersect(a, b)`

`RpclIterator` emits packets in resolution, precinct, component, layer order for
the current single-tile RPCL path.

Future progression iterators must not be exposed as supported CLI options until
their packet writer, strict reader, packet-state lifetime, and corruption tests
exist.

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
- `EncodedBlockView`
- `BlockScratch`
- `DirectBlockScratch`

Primary public functions:

- `encodeBlock(allocator, plane, stride, rect)`
- `encodeBlockScratch(scratch, plane, stride, rect)`
- `encodeSymbolsMq(allocator, symbols)`
- `decodeSymbolBitsMq(allocator, bytes, symbol_count, symbols)`
- `encodeCodeBlockSegment(allocator, plane, stride, rect)`
- `encodeCodeBlockSegmentDirect(allocator, plane, stride, rect)`
- `encodeCodeBlockSegmentDirectScratch(scratch, plane, stride, rect)`
- `encodeBlockSymbolsSegment(allocator, block)`
- `decodeCodeBlockSegmentBits(allocator, segment, symbols)`
- `decodeCodeBlockSegmentCoefficients(allocator, segment, width, height)`
- `decodeCodeBlockSegmentCoefficientsPartial(allocator, segment, width, height)`
- `decodeCodeBlockSegmentCoefficientsContinuousPartial(allocator, segment, width, height)`

`CodeBlockSegment` carries MQ bytes plus per-pass byte offsets and cumulative
truncation points. It is the bridge from T1 work into T2 packet payloads.
`decodeCodeBlockSegmentCoefficients` reconstructs a single current-model
code-block from those MQ pass payloads without using the old private bitplane
payload; the partial variant decodes complete coding-pass prefixes from quality
layer truncation points for strict ISO packet validation.
The symbol oracle and direct MQ path share SIMD-aware block-stat scanning so
bitplane and non-zero metadata stay aligned across portable, AVX2-width, and
NEON-width builds.

The T1 TODO is to bring the direct MQ path closer to JPEG2000 Part 1 by adding
cleanup run mode, sign prediction contexts, refined magnitude-refinement
contexts, and real COD style flag behavior before advertising those flags as
supported.

## `src/rate_alloc.zig`

Primary public types:

- `Block`
- `Truncation`

Primary public functions:

- `allocateEven(out, block)`
- `allocateFromCompressionRatios(out, block, rates)`

The allocator works on cumulative pass and byte targets. T2 then converts those
cumulative points into per-layer deltas.

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
