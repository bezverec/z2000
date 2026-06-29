# Roadmap

The roadmap is organized around reaching a narrow, honest JPEG2000 Part 1
encoder before broadening profile coverage.

## Guiding Rules

- Fail closed when marker options imply payload behavior that is not implemented.
- Keep strict no-sidecar RPCL/RCT/5-3 roundtrip stable; keep the temporary BP8
  sidecar only as an opt-in oracle/compatibility path.
- Prefer small independently tested T1/T2 components over large hidden rewrites.
- Keep benchmarks comparable against Grok, OpenJPEG, and Kakadu.
- Avoid license contamination: use external implementations only for behavioral
  understanding, tests, and benchmarks, not copied code.

## Near-Term ISO Task Ledger

- T1/EBCOT: continue tightening the coding pass model after cleanup run mode,
  JPEG2000-style directional sign context/prediction, and more precise
  refinement contexts. Reset-context, terminate-all, vertical-causal, and
  segmentation-symbol behavior now exist in standalone T1 style paths, including
  inferred continuous-payload decode where pass lengths are not required and
  partial quality-layer prefix decode, but public codestream support remains
  fail-closed until COD style handling is end-to-end. The remaining code-block
  style flags still need full payload behavior. Keep
  row-mask, stripe-mask, and SIMD-aware block-stats optimization going only when
  byte-for-byte oracle tests continue to pass. Code-block style flags currently
  fail closed until that behavior is connected to the emitted payload.
- T2 packet state: make include tag-tree state, zero-bitplane tag-tree state,
  `numlenbits`, layer deltas, and packet header state explicit per
  resolution/precinct/component/layer. The RPCL path now tracks layer bounds,
  sequence, precinct coordinates, whole-packet consumption, and rollback on
  failed reads; next extend the same discipline when adding LRCP, PCRL, and
  CPRL, each with matching writer, reader, and tests.
- JP2/JPX compatibility: add a stricter basic `.jp2` reader/writer for
  signature, `ftyp`, `jp2h`, `ihdr`, `colr`, and contiguous codestream boxes.
  Start with 8-bit and 16-bit RGB plus sRGB `colr`; keep JPX-only features
  rejected until JPX boxes are intentionally implemented.
- Profiles: enable ICT, irreversible 9/7, and scalar quantization only after
  the corresponding transform, quantization, T1, and T2 payload behavior exists.
  Until then, continue returning `UnsupportedPayload`.
- Multi-tile: introduce a real tile grid, per-tile DWT, per-tile packet state,
  and tile-part scheduling before allowing tile sizes smaller than the image.
- Interop gate: for each major phase, keep OpenJPEG/Grok/Kakadu checks for
  encode/decode roundtrip, marker conformance, output size, strict reader
  validation, and single-thread plus multi-thread encode/decode benchmarks.

## Phase 1: Finish The Narrow Lossless RPCL Path

Goal: single-tile RGB lossless JP2 with RCT, 5/3, RPCL, no exotic code-block
style behavior, and real packet payload interleaving.

Tasks:

- Keep the real RPCL packet stream as the main tile-part payload.
- Keep `PLT` sourced from real RPCL packet lengths.
- Keep the old temporary payload only as an opt-in debug `COM` sidecar.
- Keep strict RPCL/T2 packet state validation active for the same narrow path.
- Keep the current no-sidecar strict decode path green for RPCL/RCT/5-3:
  strict T2 block catalog, inferred continuous MQ/T1 pass metadata, quality
  layers snapped to pass truncation points, inverse 5/3, and inverse RCT.
- Close remaining packet-header/T1 conformance gaps found by OpenJPEG, Grok,
  and Kakadu smoke tests.

Exit criteria:

- z2000 output decodes in at least one independent JPEG2000 decoder.
- z2000 can decode its own strict packets without private payload data.
- Existing fail-closed unsupported profile tests still pass.

## Phase 2: Complete T1 Behavior For The Narrow Path

Goal: make the EBCOT/MQ segment payload the primary T1 output.

Tasks:

- Audit cleanup, significance, and refinement pass behavior against Part 1.
- Add missing context modeling details and edge cases.
- Implement or reject each code-block style bit based on payload behavior:
  bypass, reset context, terminate all, vertical causal, predictable termination,
  and segmentation symbols.
- Add conformance-style tests for empty blocks, sparse blocks, dense blocks,
  sign handling, stripe boundaries, and truncation points.
- Verify marker-stuffing and termination behavior under random-symbol tests.

Exit criteria:

- Temporary bitplane payload is no longer required for lossless decode.
- EBCOT payload byte counts and truncation points remain deterministic across
  thread counts.

## Phase 3: T2 Robustness And Packet Ordering

Goal: make T2 packetization strict, inspectable, and ready for more profiles.

Tasks:

- Add packet parsing from codestream tile-parts.
- Validate SOP/EPH sequencing.
- Validate PLT/TLM consistency against actual packet and tile-part lengths.
- Keep RPCL as the first supported progression, with bounded per-precinct state
  and whole-packet reader validation.
- Add LRCP/PCRL/CPRL only after packet payload ordering is implemented and
  tested for each.
- Extend tile-part division beyond none and `R` only after payload order and
  marker accounting are correct.

Exit criteria:

- Packet writer and reader agree on packet lengths, payload slices, and state.
- Corrupted packet headers fail with bounded, deterministic errors.

## Phase 4: Multi-Tile And Memory Scaling

Goal: support large images without requiring a single full-image tile path.

Tasks:

- Add real tile partitioning in image coordinates.
- Preserve tile-component independence in DWT, T1, and T2 scheduling.
- Rework scratch pools for tile-local reuse.
- Add memory usage benchmarks.
- Add tests for edge tiles and non-divisible image sizes.

Exit criteria:

- Tile sizes smaller than the image are supported.
- Current fail-closed multi-tile test is replaced with positive coverage.

## Phase 5: Irreversible And Lossy Paths

Goal: add ICT, 9/7, and scalar quantization as actual payload behavior.

Tasks:

- Implement a JP2 irreversible RGB path with ICT.
- Connect 9/7 DWT into the TIFF/JP2 pipeline.
- Implement scalar-derived and scalar-expounded quantization in marker and
  payload behavior.
- Add rate-control tests that compare quality layers and decoded error bounds.

Exit criteria:

- `--mct ict`, `--transform 9-7`, and scalar quantization no longer fail closed
  for supported profiles.
- Decoded output is validated with independent decoders.

## Phase 6: Performance Work

Goal: reduce the gap to Grok/OpenJPEG/Kakadu without sacrificing clarity.

Tasks:

- Benchmark single-thread and multi-thread encode/decode after each major T1/T2
  change.
- Keep SIMD abstraction portable across AVX2 and NEON.
- Optimize bitplane packing, significance emission, and MQ hot paths.
- Improve IO and memory locality for large TIFF inputs.
- Track output size separately from speed.

Exit criteria:

- Benchmarks are reproducible from documented commands.
- Performance changes include tests or checks that preserve deterministic output.

## External Implementation Study Notes

Grok and OpenJPEG are useful references for architecture and behavior, not for
copying code. The current takeaways for z2000 are:

- T1 should treat code-block coding as reusable per-thread state: aligned data
  buffers, padded flag rows, and per-worker coder/scratch objects reused across
  blocks. z2000 already has scratch reuse; the next step is to reduce flag clear
  and neighbor-update work with row/stripe masks while preserving byte-for-byte
  oracle tests.
- Cleanup run mode should be implemented as an explicit stripe-level path before
  further micro-optimizing byte packing. It is a correctness and speed feature:
  all-clean four-sample stripes avoid per-sample work and emit compact run
  information.
- T2 should keep packet progression geometry cached rather than recomputing
  packet-to-precinct/block mapping in the hot loop. z2000's RPCL index should be
  extended into a durable packet/progression cache before LRCP/PCRL/CPRL are
  enabled.
- Segment length coding should be modeled around terminated pass groups, not
  only per-layer byte totals. `numlenbits`, pass counts, termination points, and
  payload byte slices need to remain visible in the internal catalog so COD
  style flags can be implemented one at a time.
- Rate allocation should eventually move from even byte/pass splitting toward a
  PCRD-style slope model. A conservative histogram of pass slopes can later be
  used to avoid coding passes that are very likely to be discarded, but only
  after T1 distortion metadata is trustworthy.
- Decode scheduling can benefit from strict region-of-interest and empty-block
  skips even before full random-access decode exists. The same block catalog that
  drives strict T2 validation should expose enough geometry to skip irrelevant
  or all-zero blocks cheaply.
- Parallelism should remain deterministic but move toward persistent worker
  resources: per-thread T1 coders, per-thread DWT buffers, and packet/precinct
  work queues. Tile-level scheduling belongs after real multi-tile support.
