# Roadmap

The roadmap is organized around reaching a narrow, honest JPEG2000 Part 1
encoder before broadening profile coverage.

## Guiding Rules

- Fail closed when marker options imply payload behavior that is not implemented.
- Keep the temporary payload roundtrip stable until strict ISO packet payloads
  can replace it.
- Prefer small independently tested T1/T2 components over large hidden rewrites.
- Keep benchmarks comparable against Grok, OpenJPEG, and Kakadu.
- Avoid license contamination: use external implementations only for behavioral
  understanding, tests, and benchmarks, not copied code.

## Near-Term ISO Task Ledger

- T1/EBCOT: tighten the coding pass model with cleanup run mode, JPEG2000-style
  sign context and prediction, more precise refinement contexts, and real
  termination/reset behavior driven by COD code-block style flags. Keep
  row-mask and stripe-mask optimization going only when byte-for-byte oracle
  tests continue to pass.
- T2 packet state: make include tag-tree state, zero-bitplane tag-tree state,
  `numlenbits`, layer deltas, and packet header state explicit per
  resolution/precinct/component/layer. Finish RPCL first; add LRCP, PCRL, and
  CPRL only after each progression has a matching writer, reader, and tests.
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

- Keep the promoted BP8 RPCL packet stream as the main tile-part payload.
- Keep `PLT` sourced from real RPCL packet lengths.
- Keep the old temporary payload only as an opt-in debug `COM` sidecar.
- Use the strict ISO packet parser for the same narrow path.
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
- Keep RPCL as the first supported progression.
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
