# Roadmap

The roadmap is organized around reaching a narrow, honest JPEG2000 Part 1
encoder before broadening profile coverage.

Quantified ISO readiness is tracked in `docs/iso_coverage.md`. Keep that
scorecard in sync with this roadmap whenever a feature moves from fail-closed
metadata to tested payload behavior or when an independent decoder changes the
interop gate.

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
  refinement contexts. BYPASS, terminate-all, TERMALL-scoped reset-context,
  BYPASS+TERMALL, vertical-causal, TERMALL-scoped predictable termination, and
  segmentation-symbol behavior now have public payload paths where the required
  segment model exists. Standalone RESET, standalone ERTERM, and untested
  combinations remain fail-closed. Keep row-mask, stripe-mask,
  flag-word, and SIMD-aware T1 optimization going only when byte-for-byte
  oracle tests continue to pass.
- T2 packet state: make include tag-tree state, zero-bitplane tag-tree state,
  `numlenbits`, layer deltas, and packet header state explicit per
  resolution/precinct/component/layer. The RPCL path now tracks layer bounds,
  sequence, precinct coordinates, tag-tree lows/known-node state, whole-packet
  consumption, and rollback on failed reads; next extend the same discipline
  when adding LRCP, PCRL, and CPRL, each with matching writer, reader, and
  tests.
- JP2/JPX compatibility: add a stricter basic `.jp2` reader/writer for
  signature, `ftyp`, `jp2h`, `ihdr`, `colr`, and contiguous codestream boxes.
  Start with 8-bit and 16-bit RGB plus sRGB `colr`; the reader now also accepts
  final length-to-EOF codestream boxes and 64-bit `XLBox` lengths. Keep
  JPX-only features rejected until JPX boxes are intentionally implemented.
- ICC profile preservation: TIFF tag 34675 now roundtrips as a JP2 restricted
  ICC `colr` box and back to TIFF as opaque metadata for common RGB profiles
  such as eciRGBv2 and Adobe RGB. Malformed ICC box/tag rejection coverage is
  in place; optional LittleCMS-backed conversion should come only after the
  preservation path has interop coverage.
- Profiles: ICT, irreversible 9/7, scalar-expounded and scalar-derived QCD,
  BYPASS, reversible `--mct none`, and the currently wired style-bit
  combinations are supported on their documented narrow paths. Keep unsupported
  style combinations, broader profile mixes, and JPX-only behavior fail-closed
  until they have payload behavior and interop coverage.
- Rate allocation: `--rates` uses PCRD-style global slope allocation with
  distortion metadata and byte-targeted layer deltas. The remaining work is
  broadening fixtures and reducing the access-profile size/quality gap against
  Grok/OpenJPEG/Kakadu.
- Multi-tile: the v1 aligned-grid model is implemented for the reversible
  RCT/5-3 profile with per-tile DWT, packet state, and strict decode. Next
  expand the tile/profile matrix and scheduling while keeping unsupported
  geometry/style combinations fail-closed.
- Interop gate: for each major phase, keep OpenJPEG/Grok/Kakadu checks for
  encode/decode roundtrip, marker conformance, output size, strict reader
  validation, and single-thread plus multi-thread encode/decode benchmarks.
  Treat valid2000/jpylyzer-style validators as explicit hygiene gates rather
  than absolute truth: every warning should be checked against the strict
  reader, independent decoders, and the Part 1 text. ICC absence is acceptable
  when the source TIFF has no ICC tag.

## Next Implementation Slice

1. Turn the local JP2/ICC fixture coverage into a small interop matrix:
   ICC-absent RGB TIFF, ICC-present RGB TIFF, malformed ICC tag, and malformed
   `colr` box against OpenJPEG/Grok/Kakadu where applicable. The ICC-absent
   fixture already stays valid without inventing a profile.
2. Harden JP2 reader diagnostics around duplicate or misplaced required boxes,
   unsupported brands, ICC-vs-sRGB `colr` policy, mixed variable bits-per-component,
   extra components, and multiple contiguous codestream boxes. Basic
   length-to-EOF, `XLBox`, sequential `SOT` tile-part auditing, and `TLM/Psot`
   length matching are now covered for codestream boxes. JP2-boundary `PLT`
   parsing now also rejects unterminated packet lengths and packet spans that
   do not match the tile-part `SOD` byte count; packet `SOP`/`EPH` framing is
   checked against `COD/Scod` before trusting the codestream, and reversible
   `QCD` exponent bytes plus public 9/7 scalar-expounded/scalar-derived step
   sizes are checked against `SIZ` bit depth. `COD/Scod` implicit/default
   precinct geometry is supported in the strict foreign-stream decode path
   where packet spans can be derived; `COD` layer counts are capped to the
   current rate-allocation/T2 metadata limit.
3. Extend strict T2 audit fixtures from the current smoke file to deliberately
   corrupted PLT/TLM/SOP/EPH/header cases that can be compared against
   OpenJPEG/Grok/Kakadu behavior without assuming any validator is final.
4. Continue T1 style coverage after the JP2/T2 diagnostics are sharper:
   keep the implemented public style combinations green, add external
   BYPASS+TERMALL interop, and keep standalone RESET/ERTERM plus untested
   combinations fail-closed until each has writer, strict reader, oracle tests,
   and interop.
5. Run a comparative benchmark only after the above interop fixtures are green,
   so performance numbers are attached to output that external decoders accept.

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
- Keep ISO-MQ debug sidecar validation on the same strict SOD reconstruction
  path after BP8 metadata and shadow-stream bytes are checked.
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

- Keep packet parsing from codestream tile-parts active in the strict
  no-sidecar path.
- Keep SOP/EPH sequencing validation active. SOP remains default-on; EPH is
  opt-in until OpenJPEG/Kakadu packet-boundary interop is stable.
- Keep benchmarking gated on interop: current no-sidecar/no-EPH smoke decodes
  through z2000 strict path, OpenJPEG, Grok, and Kakadu without pixel
  differences; jpylyzer 2.2.1 accepts the current JP2. Validator reports remain
  diagnostic rather than authoritative.
- Validate PLT/TLM consistency against actual packet and tile-part lengths
  through z2000 strict path, OpenJPEG, Grok, Kakadu, and a validator where
  available; disagreements should be reduced to a minimal packet/marker case
  before treating either side as authoritative.
- Keep PLT/TLM consistency validation against actual packet and tile-part
  lengths, including ordered multi-segment TLM/PLT coverage.
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

Goal: broaden the v1 aligned multi-tile envelope and use it as the route to
large-image memory scaling and tile-level parallelism.

Tasks:

- Keep the current positive multi-tile encode/decode path green: lossless
  RCT/5-3, one layer, one tile-part per tile, row-major order, RPCL or LRCP
  packet order, plain or TERMALL code-block style, and ISO B.6/B.7-aligned
  geometry.
- Expand the tile/profile matrix one axis at a time: more fixtures for edge
  tiles and non-divisible dimensions, then additional progression orders,
  quality layers, and selected style-bit combinations only after strict decode
  and interop coverage exist.
- Preserve tile-component independence in DWT, T1, and T2 scheduling while
  keeping packet order deterministic.
- Rework scratch pools for tile-local reuse and later persistent worker
  resources.
- Add memory usage benchmarks.
- Add OpenJPEG/Grok/Kakadu interop fixtures for each newly opened multi-tile
  profile.

Exit criteria:

- The v1 envelope remains accepted by z2000 strict decode and independent
  decoders.
- Unsupported multi-tile/profile combinations fail closed with deterministic
  errors.
- Tile-level scheduling improves memory or throughput without changing output
  bytes.

## Phase 5: Irreversible And Lossy Paths

Goal: harden ICT, 9/7, scalar quantization, and rate allocation beyond the
first supported single-tile path.

Tasks:

- Keep the JP2 irreversible RGB path with ICT and 9/7 covered by OpenJPEG/Grok
  decode checks.
- Harden scalar-expounded quantization marker and inverse-quantization behavior
  against malformed QCD/QCC-style inputs.
- Keep scalar-derived marker behavior and payload decode covered by strict
  reader, JP2 wrapper, and reference-decoder checks.
- Add PCRD-style rate-control tests that compare quality layers, output bytes,
  and decoded error bounds against Grok/OpenJPEG on shared corpora.

Exit criteria:

- `--mct ict`, `--transform 9-7`, and scalar-expounded/scalar-derived QCD stay
  green across z2000, OpenJPEG, Grok, and the local strict reader.
- Access-profile output size and quality are close enough to Grok/OpenJPEG to
  make benchmark comparisons fair.

## Phase 6: Performance Work

Goal: reduce the gap to Grok/OpenJPEG/Kakadu without sacrificing clarity.

Tasks:

- Benchmark single-thread and multi-thread encode/decode after each major T1/T2
  change.
- Keep SIMD abstraction portable across AVX2 and NEON.
- Prioritize strict decode T1/MQ absolute CPU work: context update helpers,
  byte-in locality, flag book-keeping, and remaining per-symbol branch cost.
- Keep packed T1 experiments narrow and byte-exact; the full guarded packed
  context-word path is currently slower, so prefer smaller RLC/ZC/SC subpaths
  before replacing the u16 flag layer.
- Add horizontal 5/3 DWT SIMD and cache blocking after T1/MQ profiling, then
  extend DWT scheduling inside components rather than relying only on the
  three-component split.
- Treat the strict packet catalog as a measured serial Amdahl term. Recent scan,
  header, and finalize reductions keep it near 9-10 ms on the current smoke
  file; further T2 work should be justified by larger-image or multi-tile
  profiles unless it also improves ISO correctness.
- Avoid more block-order scheduling experiments until worker-balance counters
  show a real tail; the tested LPT-by-payload ordering was slower than the
  atomic next-block scheduler.
- Improve IO and memory locality for large TIFF inputs.
- Track output size separately from speed.
- Use real multi-tile support as the route to Grok-like many-core scaling once
  the single-tile T1/DWT costs are lower.

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
