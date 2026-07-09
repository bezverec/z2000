# Changelog

This file tracks notable project changes. The repository is still pre-release;
entries are grouped by development milestone rather than semantic version.

## Unreleased

### Multi-Tile Progressions

- Multi-tile lossless encode/decode now accepts the single-layer LRCP packet
  order inside the aligned RCT/5-3 tile envelope. The tile pipeline still
  builds packets from the checked RPCL scaffold, then byte-preservingly
  permutes each tile-part payload and PLT table into LRCP order; strict
  multi-tile decode reads the tile-part in COD progression order and reorders
  the packet catalog back to RPCL for the existing T2/T1 reconstruction path.
  RLCP/PCRL/CPRL and multi-layer LRCP remain fail-closed.
- Multi-tile RPCL now accepts more than one untargeted quality layer. This
  reuses the existing per-block layer truncation table and per-precinct RPCL
  packet-state lifetime while keeping multi-tile compression-ratio targets
  fail-closed until PCRD allocation is made tile-aware.

### T1 Code-Block Styles

- Multi-tile lossless encode now accepts TERMALL (`COD` code-block style
  `0x04`) inside the aligned v1 tile envelope. The tile encoder routes
  TERMALL blocks through the per-pass ISO-MQ segment writer, the tile-packet
  readback validator understands the resulting one-length-per-pass packet
  headers, and strict single-threaded/threaded decode reconstructs the source
  byte-exactly. The malformed-input fuzz sweep now includes a multi-tile
  TERMALL profile, and a dedicated multi-tile TERMALL corruption matrix checks
  second-tile PLT length damage, final tile-part truncation, and SOD payload
  byte flips.
- BYPASS+TERMALL (`COD` code-block style `0x05`) is now locally public for the
  ISO-MQ path. The encoder emits one terminated segment per coding pass, using
  D.6 raw bypass for eligible significance/refinement passes and MQ for
  cleanup/non-bypass passes; the strict decoder consumes the same per-pass
  segment table. RESET/ERTERM combined with BYPASS remains fail-closed until
  those segment models have their own tests and interop gates. A 256x256
  single-layer RPCL/RCT/5-3 smoke decodes losslessly through z2000 strict
  decode, OpenJPEG 2.5.4, and Grok 20.3.6; Kakadu remains the next external
  check for this style combination. BYPASS+TERMALL now also participates in the
  malformed-input fuzz sweep and terminated-style corruption matrix, and T2
  packet-header decoding rejects terminated segment counts above the fixed
  per-block segment table capacity before reading segment lengths.

### JP2 Container Metadata

- The JP2 reader now accepts an `ihdr` BPC value of `255` when a matching
  `bpcc` child box supplies uniform unsigned RGB component precision. The
  supported boundary stays narrow and fail-closed: exactly three components,
  all 8-bit or all 16-bit, `bpcc` immediately following `ihdr`, matching the
  codestream SIZ component precision, with either enumerated sRGB or restricted
  ICC colour boxes. Missing `bpcc`, signed components, mixed precision,
  malformed lengths, and optional boxes inserted before required `bpcc` are
  rejected explicitly.
- The same JP2 header walk now treats only `res ` as safely ignorable metadata
  in the narrow RGB profile. Palette, component-mapping, channel-definition,
  and unknown `jp2h` boxes fail closed until their colour/component semantics
  are implemented.

### Foreign 9/7 Lossy Decode

- z2000 now decodes foreign OpenJPEG 2.5.4 irreversible 9/7 lossy JP2s
  byte-identically to OpenJPEG's own decode across a moderate rate ladder
  (`opj_compress -I` at `-r 1..8`, plus `-q`). A regression test embeds a 32x32
  OpenJPEG 9/7 file and asserts z2000's strict decode matches the reference by
  an FNV-1a hash over the decoded samples. This is the first "arbitrary lossy
  decode" capability (Lossy row 7->8, full 68->69).
- The continuous inferred T1 decoders now accept rate-truncated pass prefixes
  instead of requiring the full coding-pass count. A focused regression covers
  both legacy MQ and ISO-MQ inferred decode with two-pass prefixes, which
  removes the local T1-side blocker for heavily truncated foreign 9/7 packets;
  the embedded OpenJPEG `-r 10` fixture below now pins the real interop corner
  that motivated that partial-pass relaxation.
- Strict decode now also carries signalled QCD exponents into the irreversible
  scalar-expounded/scalar-derived `Mb = G + epsilon_b - 1` calculation instead
  of falling back to a locally re-derived table after validation. A local
  diagnostic OpenJPEG 2.5.4 `-I -r 10` smoke now decodes through z2000 without
  `InvalidBlock`; reconstruction still differs from OpenJPEG's own decode on
  that tiny fixture (about 30.67 dB PSNR, max byte diff 41), so the formal N4
  follow-up is a pinned PSNR/error-bound fixture matrix rather than a score
  claim.
- A focused embedded regression now pins the same heavily truncated OpenJPEG
  2.5.4 `opj_compress -I -r 10` JP2 on the strict ISO-MQ decode path. The test
  asserts deterministic decoded samples by FNV-1a and a bounded reconstruction
  error against the original synthetic gradient, keeping this interop corner
  covered without requiring OpenJPEG at unit-test runtime.
- The strict irreversible QCD parser now accepts signalled scalar-expounded and
  scalar-derived `(epsilon_b, mu_b)` step sizes instead of requiring z2000's
  locally generated OpenJPEG-compatible table byte-for-byte. Strict decode uses
  those signalled mantissas for 9/7 dequantization and derives `Mb` from the
  signalled guard bits plus exponents (E-2). A synthetic mantissa-rewrite
  regression plus scalar-expounded and scalar-derived guard-bit-one roundtrips
  keep the parser and dequantization path tied together; scalar-derived now has
  its own mantissa-rewrite regression proving the single signalled step reaches
  dequantization.
- The JP2 wrapper now applies the same signalled-step policy at the codestream
  boundary instead of rejecting foreign irreversible QCD mantissas before strict
  decode can see them. A new embedded Grok 20.3.6 `grk_compress -I -r 8`
  fixture exercises JP2 extraction, strict ISO-MQ decode, and bounded
  reconstruction on the shared 32x32 gradient. This closes the first real Grok
  9/7 QCD-step interop gate (Lossy row 8->9, full 69->70); Kakadu and broader
  reference-relative PSNR coverage remain open. The JP2 wrapper keeps malformed
  irreversible QCD fail-closed with explicit zero-step and zero-guard
  regressions, and now has positive scalar-derived metadata coverage plus
  scalar-derived zero-step/length regressions too; scalar-expounded wrapper
  coverage also rejects no-quantization, malformed scalar-derived, and invalid
  qstyle rewrites. The strict reader also has a focused irreversible-QCD
  corruption matrix for no-quantization style,
  malformed scalar-derived length, invalid qstyle, and zero scalar steps.

### Redundant COC/QCC Component Markers

- The strict reader and JP2 wrapper now accept COC (A.6.2) and QCC (A.6.5)
  component-specific coding/quantization markers when they byte-replicate the
  main COD/QCD for a valid component (some encoders emit a redundant COC/QCC
  per component even when identical to the main marker). Any genuine
  per-component override fails closed, since z2000 has no per-component coding
  path. A splice-oracle test inserts a redundant COC (component 1) and QCC
  (component 2) into a valid codestream and asserts byte-exact decode plus JP2
  acceptance. Mismatched COC and QCC overrides now fail closed in both the
  strict reader and JP2 wrapper, as do COC/QCC component indexes outside the
  RGB component set. COC `Scoc` plus SPcoc coding bytes are structurally
  validated before byte-replica comparison, and both paths validate QCC's
  QCD-style payload first too, so malformed COC/QCC qstyle/coding bytes report
  a bad codestream instead of being treated as merely unsupported. Shortened
  COC/QCC lengths are bounded as truncation in the raw reader and invalid at
  the JP2 boundary; syntactically known but unsupported COC style combinations
  still report `Unsupported*` rather than malformed input. COD/QCD and COC/QCC
  in tile-part headers also fail closed as unsupported, since z2000 only
  accepts redundant main-header component markers today.
  Scorecard: full
  "Core codestream syntax" 11→12 (full 67→68). Note: OpenJPEG/Grok do not emit
  COC/QCC for plain RGB, so this is strict-reader-gated (no reference file on
  hand); the follow-up is a Kakadu/tuned-encoder file that carries them.

### 16-bit RGB End-to-End

- Confirmed and locked in the full 16-bit RGB archival pipeline. A new test
  encodes a 16-bit gradient image (content spanning the full 16-bit range,
  SOP+EPH+TLM, four resolutions) and reconstructs it byte-exactly through
  z2000 strict decode, with the JP2 wrapper carrying the 16-bit depth. The
  equivalent 80x64 16-bit TIFF was verified out-of-process to decode
  losslessly through OpenJPEG 2.5.4 and Grok 20.3.6 and to be jpylyzer-valid,
  closing the 16-bit leg of the interop evidence (previously only the 8-bit
  smoke profile was interop-confirmed).

### Odd/Edge Dimension Coverage

- Added an odd/thin/minimal-dimension roundtrip matrix (1x1, 5x5, 17x13,
  3x100, 100x3, 255x1, 33x31, 63x65, 127x129, 2x2) through the archival
  encode/decode (SOP+EPH+TLM, 3 requested resolution levels so the clamp
  path runs on tiny dimensions). Each stresses the odd 5/3 DWT edge lifting,
  sub-band/precinct/code-block edge derivation, and the resolution clamp,
  and reconstructs byte-exactly through z2000 strict decode. Every case was
  also confirmed lossless through OpenJPEG 2.5.4 and Grok 20.3.6, including
  the archival profile with precincts. Scorecard: narrow RCT/5-3 DWT row
  9→10 (narrow 90→91).

### Malformed-Input Fuzzing Gate

- Added a CI-enforced corruption-sweep test that fuzzes every strict-decode
  parse surface. It builds a valid archival codestream (SOP+EPH+TLM, two
  resolutions, 8x8 blocks) and its JP2 wrapper, then sweeps truncation at
  every length plus single-byte corruption across SIZ/COD/QCD/TLM/SOT/SOD/
  PLT/SOP/EPH framing, packet headers, tag-trees, and T1 payloads, asserting
  every case is handled with a bounded error and no panic or out-of-bounds
  read under Debug, ReleaseSafe, and ReleaseFast. An out-of-process
  ReleaseSafe sweep over the full smoke JP2 (byte-flip, truncation, and
  multi-value corruption, ~96 K malformed inputs) independently found zero
  crashes, confirming the bounds-checked readers and fail-closed validation
  hold across the whole file. Scorecard: full-codec interop/conformance row
  4→5 (66→67).
- Broadened the corruption-sweep gate to four profiles: single-tile archival
  RCT/5-3, multi-tile RCT/5-3 (exercising the per-tile SOT/PLT walk and
  multi-tile strict decode), irreversible ICT/9-7 (QCD step-size parsing plus
  the float inverse-DWT/ICT path), and terminate-all (TERMALL) exercising the
  per-pass terminated-segment T1 decoder and multi-segment PLT/packet path.
  All green in Debug/ReleaseSafe/ReleaseFast; out-of-process ReleaseSafe
  sweeps of the multi-tile and 9/7 smoke JP2s independently found zero
  crashes.

### Balanced Low-Thread Decode

- Strict decode now routes every multi-thread run (2 threads and up) through
  the per-component block-level atomic scheduler instead of the special-case
  component-parallel path (one thread per component). Component-parallel was
  only load-balanced at exactly 3 threads and left a 2:1 imbalance at 2
  threads (~1.31x); on the 2048 noise image at 2 threads block-level
  balancing lifts decode from ~362 ms to ~291 ms (-19.5%). Scaling is now
  monotone across thread counts (the old path could make 3 threads
  accidentally faster than 4 via nested oversubscription, which would thrash
  on low-core machines). Single-thread and t10 are unchanged; byte-identical
  output verified across thread counts. Removes two now-dead worker types.

### Parallel Forward RCT

- The forward reversible color transform now splits its per-pixel work across
  the requested workers (bands aligned to the SIMD width, last band taking the
  scalar tail), the same "parallelize the phases the full-core DWT left as a
  serial tail" cleanup. Byte-identical to the serial transform (unit test
  across dimensions x worker counts). Measured encode t10 on the 2048 noise
  image (M4): ~123.6 -> 119.3 ms (-3.5% mean, reproducible across two A/B
  runs, and much tighter variance ±4.5 -> ±1.7); encode t1 unchanged. The
  inverse RCT (decode) was tried too but reverted — at ~3.4 ms the phase is
  too small for the thread-spawn + range-error-check overhead to pay off.

### Full-Core Parallel DWT

- The reversible 5/3 DWT now distributes each of the three components'
  per-level row and column bands across every requested worker instead of
  capping at three component threads. On multi-core machines the DWT phase
  was a large tail of threaded runs (forward DWT ~30% of encode t10, inverse
  ~13% of decode t10) with most cores idle. `wavelet_int.forward53Parallel` /
  `inverse53Parallel` keep the sequential per-level cascade but split column
  bands at SIMD-vector boundaries (final band takes the scalar tail) and row
  bands evenly, each worker with private scratch. Output is byte-identical to
  the serial workspace transform (unit test across 6 dimensions x 5 worker
  counts), so encode bytes and external interop are unaffected. Measured on
  a 2048x2048 noise image (Apple M4, 4P+6E): encode t10 143 -> 121 ms
  (-15.4%), decode t10 115 -> 110 ms (-4.2%); single-thread encode/decode
  unchanged (serial path untouched). See `docs/optimization_plan.md`.

### Predictable Termination (ERTERM) Bring-up

- Added an ISO MQ ER-TERM flush path for `--terminate-all
  --predictable-termination`. The flush mirrors OpenJPEG/Grok's ERTERM
  treatment of the final guard byte, keeps standalone short MQ streams
  roundtrippable, and allows the public COD style byte `0x10` only when
  TERMALL (`0x04`) is also present.
- T2 segment-length handling now permits zero-byte terminated segments only
  through explicit segment metadata; the normal layer-delta path still rejects
  included zero-byte contributions. The ER-TERM final-byte handling now drops
  the non-payload trailing `0xff` case as well as the guard byte case, and a
  larger no-sidecar single-tile smoke decodes pixel-exactly through both z2000
  strict decode and Kakadu `kdu_expand`.
- Added `tools/interop_erterm.ps1` and ran the larger no-sidecar ERTERM smoke
  through OpenJPEG 2.5.4, Grok 20.3.6, and Kakadu 8.4.1 on
  `C:\temp\tools\images\0002.tif` and `0004.tif`; all three external decoders
  reconstructed the source pixels losslessly.
- Fixed the block-parallel strict decoder for TERMALL/ERTERM payloads: the
  worker now routes terminated code-blocks through the explicit per-pass
  segment decoder instead of the continuous MQ path. z2000 strict decode now
  reconstructs the same ERTERM smoke files losslessly at 16 threads, and the
  predictable-termination test covers the threaded path. The scorecard moves
  to 90/100 narrow and 66/100 full.
- Removed the obsolete tracked `sample.pgm` manual fixture; PGM support remains
  documented, but tests now generate their small fixtures directly.

### RESET+TERMALL Code-Block Style

- Opened COD style `RESET` (`0x02`) only in the implemented TERMALL ISO-MQ
  segment model: `--reset-context --terminate-all` resets JPEG2000 MQ context
  states between pass-terminated segments while preserving explicit T2 segment
  lengths. At that milestone, standalone RESET and BYPASS+TERMALL still
  remained fail-closed; BYPASS+TERMALL has since gained local strict coverage
  in the Unreleased T1 style section above.
- Added public roundtrip and strict COD mutation coverage. A larger no-sidecar
  single-tile smoke from `0002.tif` decodes pixel-exactly through z2000 strict
  decode, Kakadu, OpenJPEG, and Grok.
- Rechecked documentation against the row-level scorecard: the narrow RGB
  lossless JP2 target reached 89/100 and the broader Part 1 family reached
  63/100 before the later PLT-less foreign-stream and ERTERM interop gates.

### Foreign Stream Decode (Stage A)

- z2000 now decodes JP2 files produced by other encoders when they carry
  PLT packet lengths. The one missing profile piece was COD without
  precinct bytes (Scod bit 0 unset — the OpenJPEG/Grok default): the strict
  reader and the JP2 wrapper now map it to the ISO B.6 "no precinct
  partition" geometry (maximal 2^15 precinct, one per resolution) instead
  of failing closed. Verified pixel-lossless against the encoders' own
  decodes: OpenJPEG 2.5.4 and Grok 20.3.6 default configurations (LRCP,
  no precincts) plus RPCL, explicit precincts, 32x32 blocks with 4 levels,
  multi-layer rate-truncated ladders, and OpenJPEG 9/7 lossy (max-diff 1
  reconstruction agreement, identical to the z2000-encoded baseline).
- Stage B PLT-less foreign decode interop is now green for the current
  single-tile lossless profile. Real OpenJPEG 2.5.4, Grok 20.3.6, and Kakadu
  8.4.1 JP2 files were generated without PLT/TLM/SOP/EPH; z2000 strict decode
  matched both the source TIFF and each reference decoder byte-for-byte for
  default LRCP/no-precinct files, plus OpenJPEG/Grok `-r 20,10,1` multi-layer
  lossless-final ladders. The full scorecard estimate moves from 63/100 to
  65/100 by raising the lossless decode profile row from 8 to 10.
  PLT-less foreign streams remain fail-closed (packet-length derivation
  from header parsing is the next stage). Local oracle: splicing the
  precinct bytes out of a maximal-precinct z2000 stream decodes
  byte-exactly.

### Scalar-Derived Quantization

- Added `--qstyle scalar-derived` (ISO 15444-1 A.6.4) for the irreversible
  9/7 path: the QCD signals a single (exponent, mantissa) pair for the NL LL
  band and both sides derive every other subband step via E-5 (epsilon
  drops by one per resolution, mantissa shared). The fix that made external
  interop exact: the nominal bit-plane budget Mb (E-2) now derives from the
  *signalled* epsilon table — under derived quantization the expounded
  norm table would disagree with what decoders reconstruct, shifting
  zero-bitplane interpretation. OpenJPEG 2.5.4 reconstructs z2000
  scalar-derived output within max-diff 1 of z2000's own decode (identical
  agreement to the scalar-expounded baseline); Grok differs by its usual
  max-diff 3 reconstruction bias against both. jpylyzer reports valid JP2
  with `<qStyle>scalar derived</qStyle>`. Reversible + scalar-derived stays
  fail-closed.

### PCRD Refinements

- Layer byte targets now charge the real packet-header overhead: a probe
  assembly of the first allocation measures per-layer header bytes and one
  refinement round subtracts them from the budgets, so assembled layer
  sizes (headers included) land under the requested ladder (verified
  10603/21200/53157 against targets 10646/21293/53233 at rates 100/50/20).
- Parallelized the PCRD distortion extraction (the symbol-coder re-run)
  across code blocks with per-worker scratch; each slot writes a disjoint
  span, so the allocation stays byte-identical across thread counts
  (4-thread rate-targeted encode of the 1024x1024 fixture drops ~0.42 s ->
  ~0.15 s end to end).

### PCRD Rate Allocation

- Replaced the per-block proportional `--rates` split with a global
  PCRD-style allocation (ISO 15444-1 J.14). The symbol-based reference
  coder yields exact per-pass squared-error reductions (midpoint
  reconstruction model), weighted by (synthesis-basis norm x quantization
  step)^2 per band; `rate_alloc.allocatePcrdPasses` builds each block's
  convex hull over (bytes, distortion) truncation candidates and picks a
  global slope threshold per layer byte target. Runs single-threaded after
  the parallel block encode, so allocation is thread-count independent
  (covered by a determinism test). Layer payloads now land on the byte
  targets (the old split overshot the first layer by ~10x), and PSNR at
  matched sizes is within 0.2-0.4 dB of OpenJPEG's own PCRD (previous
  allocator trailed by 15+ dB at the first layer). BYPASS segment snapping
  is preserved via the existing truncation normalization; the full stream
  still decodes losslessly on the reversible path (opj/grk verified,
  jpylyzer valid).

### PCRL and CPRL Progressions

- Completed the Part 1 progression-order matrix: `--progression PCRL`
  (B.12.1.4) and `--progression CPRL` (B.12.1.5) order packets by precinct
  position on the image reference grid (upper-left corner scaled by
  `2^(levels - r)`), with component hoisted outermost for CPRL. Both are
  byte-preserving permutations of the RPCL packets built by a sorted
  sequence builder that now backs every non-RPCL order on both the encoder
  reorder and the strict-decoder slot walk. Position-major streams cannot be
  divided per resolution, so PCRL/CPRL always emit one tile-part. OpenJPEG
  2.5.4 and Grok 20.3.6 decode PCRL/CPRL output pixel-losslessly (1 and 4
  layers, plus dense 64x64-precinct/32x32-block configurations); jpylyzer
  confirms the signalled order. The undefined COD progression values 5+
  stay fail-closed.

### LRCP and RLCP Progressions

- Added the RLCP progression order (`--progression RLCP`, ISO 15444-1
  B.12.1.2) on top of the LRCP permutation machinery: a shared
  progression-aware stream iterator drives both the encoder reorder and the
  strict decoder slot walk. Resolution stays outermost in RLCP, so
  per-resolution R tile-part divisions remain valid for any layer count.
  OpenJPEG 2.5.4 and Grok 20.3.6 decode RLCP output pixel-losslessly (1, 4,
  and 4+BYPASS layers); jpylyzer confirms `<order>RLCP</order>` on valid
  JP2s. PCRL and CPRL stay fail-closed.

- Added the LRCP progression order (`--progression LRCP`, ISO 15444-1
  B.12.1.1) for the single-tile path. Packet bodies are order-independent
  (T2 coder state is per-precinct and layer order within each precinct is
  preserved), so the encoder emits the RPCL-built packets as a byte-preserving
  permutation into layer-major stream order; the strict decoder walks the
  stream with an LRCP slot iterator and permutes the packet catalog back to
  RPCL grouping for the unchanged downstream chain. Multi-layer LRCP encodes
  one tile-part (the stream cannot be divided per resolution); single-layer
  LRCP keeps R-divisions. The JP2 wrapper accepts progression 0/2; RLCP,
  PCRL, CPRL, and multi-tile LRCP stay fail-closed. OpenJPEG 2.5.4 and Grok
  20.3.6 decode LRCP output pixel-losslessly (1, 4, and 4+BYPASS layers) and
  jpylyzer confirms `<order>LRCP</order>` on valid JP2s.

### Interop Gates Closed

- Opened the JP2 wrapper profile validation to the code-block style bits the
  codestream layer already codes end-to-end (TERMALL `0x04`, CAUSAL `0x08`,
  SEGMARK `0x20`) and to disabled MCT (`0`), unblocking `--terminate-all`,
  `--vertical-causal`, `--segmentation-symbols`, and `--mct none` through the
  public `tiff-to-jp2` CLI. At that milestone, RESET (`0x02`) and ERTERM
  (`0x10`) still stayed fail-closed; accepted-profile and rejected-bit COD
  mutation tests were added.
- Passed the external interop gates staged in `docs/next_steps.md`:
  OpenJPEG 2.5.4 and Grok 20.3.6 decode z2000 output pixel-losslessly for
  vertical-causal, segmentation-symbols, terminate-all, `--mct none`, and
  genuine multi-tile streams (2x2 aligned grid and 3x3 edge-tile grid), and
  jpylyzer reports every feature file as valid JP2.

### Multi-Tile Foundation

- Added a standalone JPEG2000 tile-grid helper for image/tile reference-grid
  geometry, including edge-tile rectangles for non-divisible dimensions and
  non-zero reference origins. Encoder and strict SIZ validation now use this
  shared geometry while still failing closed for real multi-tile payloads until
  per-tile DWT/T1/T2 state exists.
- Added tile-local RGB extraction and copy-back helpers with edge-tile
  roundtrip tests, giving future per-tile encode/decode scheduling a shared
  checked row-copy primitive.
- Added row-major tile descriptors and an iterator over the tile grid, including
  edge-tile classification for future tile work queues.
- Added a standalone tile-local RCT pipeline scaffold that transforms one tile
  descriptor into local RCT planes and roundtrips it back into the full RGB
  image without enabling multi-tile codestream output.
- Added in-place tile-local reversible 5/3 DWT and inverse-DWT scaffolding over
  the RCT tile planes, reusing the production integer wavelet workspace and
  roundtripping edge tiles in tests.
- Added a tile-local packet scaffold that derives subbands, code-block
  rectangles, and an RPCL packet plan for one transformed tile without emitting
  multi-tile codestream payloads yet.
- Added deterministic component-block job descriptors over the tile packet
  scaffold, giving future T1 scheduling an explicit component/block/band/rect
  iteration order.
- Added checked component-block plane views for tile-local T1 jobs, carrying a
  borrowed component plane, stride, and block rect in the shape expected by the
  existing EBCOT block encoder.
- Added an isolated tile-local ISO-MQ EBCOT component-block encode helper,
  byte-checked against the existing symbol-based EBCOT oracle while still
  leaving multi-tile packet emission disabled.
- Added a tile-local encoded block catalog builder that encodes every
  component-block job for one tile, owns the resulting EBCOT segments, and
  preserves deterministic component-major ordering for later T2 integration.
- Added tile-local quality-layer truncation metadata to each encoded block,
  using the same normalized `LayerTruncation` shape as the current RPCL packet
  writer so future per-tile T2 assembly can avoid recomputing block metadata.
- Added a borrowed tile-local `t2.EncodedLayerBlock` view over encoded catalog
  entries, including band-local leaf coordinates, EBCOT payload bytes, segment
  spans, and bitplane metadata for future RPCL packet assembly.
- Added a tile-local `RpclPacketIndex` that precomputes packet-sequence to
  code-block-index selections and maps those selections into the encoded block
  catalog, avoiding repeated per-packet code-block scans in the future per-tile
  T2 writer.
- Added tile-local RPCL packet band grouping with packet-local leaf coordinate
  normalization, producing borrowed `t2.EncodedLayerBlock` arrays that can
  initialize T2 tag-tree packet writer state.
- Added a standalone tile-local RPCL packet stream builder with packet and
  packet-header length tables, exercising real T2 packet-header and payload
  emission without enabling multi-tile codestream output yet.
- Added a tile-local RPCL packet stream readback validator that replays the
  emitted packets through T2 reader state and checks header lengths, decoded
  layer deltas, and payload slices against the shared encoded block catalog.
- Added an owned tile-local RPCL encode artifact wrapper that runs one tile
  through RCT, reversible 5/3 DWT, ISO-MQ EBCOT catalog construction, RPCL
  index creation, packet stream emission, and immediate T2 readback validation.
  This gives future multi-tile scheduling a single checked work item without
  enabling multi-tile codestream output yet.
- Added a deterministic tile-grid artifact builder that produces the same owned
  RPCL encode artifact for every tile in row-major order, providing a serial
  correctness baseline for the future persistent tile work queue.
- Added a parallel tile-grid RPCL artifact builder backed by an atomic tile work
  index. Results are written to their tile-index slots and tested byte-for-byte
  against the serial builder to preserve deterministic output.
- Added a deterministic cost-ordered tile work list for the parallel builder so
  larger tiles start first while output remains indexed in row-major tile order.
- Added a standalone tile-part layout derivation over tile-grid artifacts,
  computing one future tile-part per tile with packet counts, raw/framed packet
  bytes, PLT byte counts, and `Psot` values for later SOT/TLM/PLT writer wiring.
- Added a standalone TLM plan over tile-part layout entries, carrying 16-bit
  tile indexes and 32-bit `Psot` values plus marker byte-count validation for
  the future multi-tile writer.
- Added a standalone PLT plan over tile-part layout entries, grouping framed
  packet lengths per future tile-part and validating PLT marker byte totals
  against the computed `Psot` layout.
- Added standalone TLM and PLT marker-segment writers for the tile pipeline
  scaffold, with tests decoding the emitted bytes back to tile indexes, `Psot`
  values, and framed packet lengths.
- Added a standalone future tile-part byte writer over tile-grid artifacts,
  emitting `SOT`, optional `PLT`, `SOD`, and SOP/EPH-framed RPCL packet payloads
  while keeping real multi-tile codestream output disabled. Tests parse the
  generated tile-part bytes and compare packet payload slices back to the
  tile-local RPCL stream.
- Added a standalone tile-part sequence writer that concatenates all row-major
  future tile-parts, optionally prefixed by the derived `TLM` marker segment.
  Tests cover both TLM-present and no-TLM sequence buffers and compare each
  tile-part slice against the per-entry writer.
- Added an owned indexed tile-part sequence form carrying the emitted bytes,
  `TLM` span length, and per-tile-part offsets so future codestream assembly can
  use checked byte ranges instead of marker rescans.
- Added a standalone `SOC`/`EOC` codestream-fragment wrapper around indexed
  tile-part sequences, including validation that every `SOT/Psot` span matches
  the stored offsets. This keeps multi-tile output fail-closed while moving the
  scaffold closer to real Part 1 codestream structure.
- Added a matching strict parser for the standalone codestream fragment. It
  rebuilds the `TLM` span and tile-part offset map from bytes and rejects
  corrupted `SOC`, `EOC`, `SOT/Psot`, and `SOD` boundaries in tests.
- Extended the standalone fragment parser to decode explicit `TLM` entries
  (`Stlm=0x60`) and validate each tile index and `Psot` value against the parsed
  tile-part headers, with corrupt `Stlm` and TLM length regressions.
- Extended the standalone fragment parser to decode ordered `PLT` marker
  segments, expand variable-length packet lengths, and validate that each
  tile-part's PLT length sum exactly matches its `SOD` payload span. Tests now
  cover corrupt `Zplt`, packet-length bytes, and PLT marker corruption.
- Added parsed packet spans derived from those PLT lengths, exposing exact
  tile-part `SOD` payload slices for future strict T2 packet decode work.
- Added a standalone fragment-vs-grid-artifacts validator that checks parsed
  tile-part packet spans against the original tile-local RPCL streams,
  including SOP/EPH framing and corrupted packet-payload coverage.
- Added a raw RPCL stream extractor for parsed tile-part packet spans and a
  standalone fragment T2 readback validator that replays those reconstructed
  streams through the existing T2 packet reader state and tile-local EBCOT
  catalog.
- Added a marker-only parsed tile-part audit table with tile identity, `Psot`,
  PLT bytes, packet counts, framed bytes, and raw packet bytes. Tests now cover
  both SOP/EPH-framed tile-parts and no-framing tile-parts.
- Added full no-TLM standalone codestream-fragment coverage:
  `SOC -> SOT/PLT/SOD -> EOC` now parses, audits, validates against tile-grid
  artifacts, and replays through T2 readback without relying on `TLM`.
- Added an explicit single-part tile-order validator for the standalone
  multi-tile scaffold. It requires row-major tile indexes and exactly one
  tile-part per tile, with coverage for malformed tile order and tile-part
  count metadata.
- Added a tile-local encoded block catalog coverage validator and wired it into
  tile artifact construction. It checks that each component's code-block rects
  match the scaffold and cover the transformed tile plane exactly once.
- Added standalone tile-grid pixel reconstruction from encoded tile artifacts:
  direct-ISO T1 payloads decode through the inferred continuous ISO-MQ path,
  inverse 5-3 and inverse RCT run per tile, and the reconstructed edge tiles are
  copied back into the full RGB image in tests.

### Performance Instrumentation

- Added `decode-temp-jp2 --timings` and a public `DecodeTimings` profiling API
  for the supported strict JP2 decode path. The breakdown now separates JP2
  read, codestream extraction, metadata parsing, T2 packet catalog construction,
  T1 block payload reconstruction, inverse DWT, inverse MCT, ICC extraction,
  and TIFF write.
- Updated comparative benchmark scripts so `Z2000_THREADS=all` / `auto`
  resolves to all detected logical CPUs, including Windows environments via
  `NUMBER_OF_PROCESSORS`; profile benchmarks now default to the all-thread
  z2000 mode instead of a fixed three-worker run.
- Added `tools/bench_compare.ps1`, a Windows-native comparative benchmark for
  z2000, Grok, OpenJPEG, and Kakadu that uses `hyperfine --shell=none`, exports
  encode/decode JSON results, reports output sizes, and runs optional pixel
  checks when a Python with NumPy/Pillow is available.
- Switched the encode-side component block catalog builder from fixed contiguous
  worker ranges to an atomic block queue, matching the strict decode work-queue
  shape and improving all-thread encode load balance.
- Ordered encode-side block catalog work by estimated block cost before feeding
  the atomic queue, so large high-resolution code-blocks start earlier without
  changing deterministic catalog/output ordering.
- Flattened encode-side Y/Cb/Cr code-block catalog work into one cost-ordered
  atomic queue for `threads > 3`, keeping stable per-component catalogs while
  reducing the three sequential component payload phases.
- Sorted strict decode block work by payload size before feeding the atomic
  worker queue, reducing tail imbalance while keeping deterministic block
  scatter/output behavior.
- Reduced strict single-layer packet-catalog finalize overhead by storing
  decoded packet payloads in component-owned buffers and transferring those
  buffers into the block catalog instead of copying every code-block payload
  through an intermediate per-block `ArrayList`.
- Reduced strict single-layer packet-header assembly allocation churn by
  building short-lived T2 audit groups from a retained per-packet arena; the
  local timed decode split moved packet-header assembly from about 41 ms to
  about 32 ms on the 3520x5115 smoke file.
- Skipped full coefficient-plane zero-initialization for strict decodes whose
  packet block catalog has no zero blocks. On the local dense 3520x5115
  no-sidecar output, z2000 t16 decode measured about 548 ms with lossless
  output.
- Kept T1/MQ pass and branch profiling out of the normal strict decode hot path;
  worker T1 stats are now collected only when decode timings are requested.
- Added ReleaseFast T1 significance/refinement/cleanup decode paths for the
  common style without vertical causal mode; they derive candidate/context
  directly from the neighborhood flag word while Debug/ReleaseSafe keep the
  packed-context shadow assertions. On the local 3520x5115 smoke file, the
  combined shortcuts moved z2000 decode to about 3.58 s single-thread and
  566 ms with 16 threads.
- Added the matching ReleaseFast direct T1 refinement encode shortcut for the
  common non-vertical-causal style.
- Extended the ReleaseFast direct T1 encode shortcut to significance and
  cleanup passes. On the local 3520x5115 smoke file, z2000 encode measured
  about 3.35 s single-thread and 500 ms with 16 threads, with z2000,
  Grok/OpenJPEG/Kakadu decode all lossless.
- Fixed T2 packet-header termination when the final header byte is `0xff` by
  emitting and validating the required zero stuffing/padding byte; this aligns
  PLT packet lengths with Grok/OpenJPEG/Kakadu packet parsers on the current
  no-sidecar output.
- Updated the ISO scorecard after the current no-sidecar z2000/OpenJPEG/Grok/
  Kakadu lossless gate and jpylyzer 2.2.1 validity check: the narrow RGB
  lossless JP2 target is now estimated at 86/100 and the broader Part 1 codec
  family at 40/100. Validator warnings are treated as diagnostic leads rather
  than absolute failures, and ICC absence is acceptable when the source TIFF has
  no ICC tag.
- Split strict packet-catalog timing into scan, packet-header assembly, and
  final block-catalog materialization phases.
- Reduced packet-header assembly allocation churn by filling strict and legacy
  reader band-group block maps directly instead of allocating temporary
  location and occupancy buffers for each layer-zero packet.
- Reduced strict SOD packet scan overhead by pre-reserving the packet byte
  buffer per tile-part and by scanning only possible marker prefix bytes while
  validating unexpected SOP/EPH markers.
- Reduced strict packet-header assembly staging by appending decoded packet
  payloads directly into component assemblies instead of first storing temporary
  payload slices per audit band group.
- Skipped unnecessary decoded-block clearing for absent strict packets; the
  strict audit path now validates the absent packet length and returns before
  touching per-block temporary decode storage.
- Folded strict block-catalog validation/stat collection into final catalog
  construction, removing a separate assembly-wide pass from the serial finalize
  phase.
- Reused the validated per-tile-part packet payload byte count for strict SOD
  buffer reservation and span checks instead of summing PLT lengths again.
- Moved strict packet-reader band-group lists to fixed three-slot stack storage;
  legacy packet-reader lists are pre-sized to the same JPEG2000 bound and both
  paths reject malformed geometry that would exceed it.
- Skipped scratch pack/unpack copies for two-sample horizontal 5/3 DWT rows,
  where even/odd layout is already unchanged.
- Removed the unreachable non-renormalizing tail from ISO MQ decode MPS slow
  paths; after the fast-MPS and LPS tests, the remaining MPS case necessarily
  renormalizes.
- Updated the optimization roadmap after strict T2 profiling and MQ/DWT hygiene:
  LPT-by-payload scheduling is no longer prioritized, packet catalog is tracked
  as a smaller serial Amdahl term, and the next highest-leverage work is T1/MQ
  CPU cost, narrow packed-flag subpaths, horizontal 5/3 SIMD, and multi-tile
  scheduling.
- Split strict T1 significance candidate checks from zero-context lookup in the
  direct encode and inferred decode hot paths, so non-candidate samples avoid
  the extra context-table work while packed shadow parity checks remain active.
- Cached the current ISO MQ decoder byte across `byteIn()` calls, reducing
  repeated slice indexing in the renormalization path while preserving
  `reinitStream` segment restart behavior.
- Added portable SIMD shuffles to the horizontal integer 5/3 row lifting and
  pack/unpack steps, covering the repeated interior predict/update groups and
  low/high rearrangement used by both forward and inverse DWT.
- Batched T2 packet-header `readBits` consumption from the current byte instead
  of dispatching every bit through `readBit`, while preserving marker-stuffing
  validation at byte boundaries.
- Added pass-level T1 decode profiling for the strict ISO MQ/BYPASS path:
  significance, refinement, cleanup/RLC, and raw BYPASS passes now report
  CPU-sum timing, pass counts, and symbol counts across decode workers.
- Added strict block-payload worker balance counters to `decode-temp-jp2
  --timings`, reporting worker-job count plus max/average wall time, decoded
  blocks, and payload bytes.
- Added optional ISO MQ branch counters to the T1 decode timing profile:
  fast MPS, LPS, MPS-with-renormalization, renormalization shifts, and byte-in
  counts are aggregated per pass type without affecting non-profiled decode.
- Tightened ISO MQ branch-counter accounting by removing an unreachable
  profiled fast-MPS increment, documenting that profiled and unchecked decode
  transitions must stay in sync, and adding a test that profiled decode matches
  unchecked decisions while branch counters account for every symbol.
- Cached the ISO MQ state-table row inside each adaptive context, removing the
  per-symbol `state -> state_table[state]` lookup from the encoder and decoder
  hot loops while keeping the state index for diagnostics and reset parity.
- Batched ISO MQ decoder renormalization with a CLZ-derived shift count instead
  of shifting one bit per loop iteration; profiling still reports the logical
  number of renormalization bit shifts.
- Re-ran a short macOS 2048x2048 archival decode benchmark after the MQ context
  cache pass (`hyperfine --runs 5`, ten z2000 threads): z2000 decode of its
  current output measured 173.3 ms, Grok 85.6 ms on the same JP2, and OpenJPEG
  523.1 ms; `tiffcmp` confirmed pixel-lossless output for all three decoders.
- Reduced TIFF write overhead by reserving the exact output capacity and
  filling the 8/16-bit raster slice directly instead of issuing fallible
  appends per sample. The 8-bit output path now validates and narrows `u16`
  samples with the shared portable SIMD lane policy, while 16-bit output uses
  a native little-endian byte copy with an explicit big-endian fallback. A
  decode timing run on the 2048x2048 macOS sample showed the TIFF write phase
  at about 9 ms; the same output remained pixel-identical by `tiffcmp`.
- Vectorized TIFF 8-bit sample widening with the shared portable SIMD lane
  policy. A profiled encode pass on the 2048x2048 macOS sample reported TIFF
  read at 9.0 ms while preserving the existing RGB parser tests.
- Added a native little-endian byte-copy fast path for 16-bit TIFF strip reads
  with a scalar fallback for big-endian input/targets, plus a parser test that
  pins little-endian 16-bit RGB sample order.
- Added a big-endian 16-bit RGB TIFF parser test to pin the scalar endian
  conversion fallback used outside the native little-endian fast path.
- Added TIFF parser coverage for inline `SHORT` `StripOffsets` and
  `StripByteCounts` tags, matching another legal TIFF 6.0 encoding of small
  strip metadata.
- Added TIFF parser coverage for RGB data split across multiple strips, pinning
  offset/count array handling and sample-order continuity across strip
  boundaries.
- Added negative TIFF strip metadata coverage for mismatched `StripByteCounts`
  totals and truncated strip payload offsets.
- Hardened TIFF scalar metadata readers so `readU16` and `readU32` now
  bounds-check their offsets and return `TruncatedData`, improving ReleaseFast
  behavior for malformed tags and future parser changes.
- Added a public TIFF writer/reader roundtrip test for the optimized 8-bit and
  16-bit raster paths, plus negative coverage that the 8-bit SIMD narrowing
  path rejects out-of-range `u16` samples instead of truncating them.
- Tightened SIMD coverage so the TIFF 8-bit overflow test enters the vector
  narrowing branch and the ICT roundtrip test exercises vector-body plus scalar
  tail paths across NEON, AVX2, and AVX-512 lane widths.
- Tightened the TIFF raster append helper to restore the previous output
  length on validation failure.
- Added the first ISO MQ decoder fast-path slice: `mq_iso.Decoder` now exposes
  an inline unchecked read path, and EBCOT T1 decode dispatches ISO MQ reads
  through it while preserving the checked legacy MQ path.
- Kept the ISO MQ branch-counter wrapper out of the default hot loop: T1 pass
  dispatch hoists the per-block profiling flag once, then uses the unchecked
  decoder directly unless timing collection asks for detailed branch counters.
- Narrowed the direct T1 encode/decode decision helpers: significance and
  cleanup paths now compute sign coding only after a newly significant sample
  is known, MQ refinement computes only its membership and context, and raw
  BYPASS significance/refinement use even smaller membership predicates.
  Debug and ReleaseSafe builds still assert parity against the packed T1
  shadow state.
- Marked the tiny T1 index, row-mask, flag, and magnitude-bit helpers inline so
  the direct encode/decode loops keep those arithmetic operations local to the
  sample hot path.
- Reused the loaded coefficient value inside direct T1 significance and
  cleanup encode paths, avoiding duplicate plane indexing when the same sample
  needs both magnitude-bit and sign tests.
- Vectorized the irreversible ICT color transform with the shared portable SIMD
  lane policy: f32 lanes map to NEON-128 on AArch64 and AVX-family widths on
  x86_64 builds, with scalar tails covered for non-multiple pixel counts.
- Switched strict block-level decode workers from static contiguous block ranges
  to an atomic next-block scheduler so uneven code-block payloads balance better
  across decode threads.
- Added scratch-owned borrowed coefficient decode helpers for the strict ISO MQ
  and BYPASS paths, removing the per-code-block dupe/free cycle before
  scattering coefficients into the final component plane.
- Consolidated strict packet-catalog main-header scanning for COD/TLM/SOT,
  avoided a duplicate metadata parse when building strict block catalogs, and
  preallocated packet catalog entries from the RPCL packet plan. The strict
  metadata parser now also validates TLM entries during its existing main-header
  scan instead of running a second TLM-only pass, and the main decode path now
  reuses its already-parsed strict metadata when constructing the block catalog.
- Reduced strict SOD packet marker scanning from separate SOP and EPH searches
  to one pass that still rejects unexpected SOP markers and duplicate EPH
  markers while preserving EPH-before-payload packets.
- Kept legacy debug sidecar timing coarse while exposing the ISO/T2/T1 path
  phases needed for the next MQ decoder optimization pass.

### JPEG2000 Profile Handling

- Added fail-closed profile option handling for unsupported marker/payload
  combinations.
- Allowed only RPCL progression for now.
- Allowed only no tile-part division or resolution tile-part division (`R`).
- Rejected tile sizes smaller than the image until real multi-tile encoding
  exists.
- Distinguished RCT and ICT instead of mapping `ict` to generic MCT enabled.
- Added tests that reject unsupported LRCP/PCRL/CPRL progression, L/C/P
  tile-parts, scalar-derived quantization, invalid ICT/9-7 combinations, and
  multi-tile requests.
- Tightened the basic JP2 box reader for the supported `.jp2` profile:
  signature and `ftyp` ordering, `jp2 ` compatibility, RGB `ihdr`, sRGB `colr`,
  and one contiguous codestream are now validated fail-closed.
- Extended the JP2 box reader to accept standard Annex I codestream box lengths:
  `LBox == 0` for a final length-to-EOF box and `LBox == 1` with a 64-bit
  `XLBox`, with malformed/truncated XLBox coverage.
- Hardened JP2 big-endian numeric field reads so short box payloads return
  deterministic `InvalidBox` errors instead of relying on unchecked indexing.
- Kept `LBox == 0` fail-closed for nested JP2 header child boxes, so
  length-to-EOF remains a top-level final-box mechanism rather than silently
  consuming the rest of a superbox.
- Rejected empty contiguous codestream boxes in both JP2 wrapping and parsing
  so malformed `.jp2` inputs cannot pass metadata validation with a zero-byte
  `jp2c` payload.
- Tightened JP2 profile diagnostics further: `ftyp` now rejects any compatible
  brand outside the narrow `jp2 ` profile, and tests explicitly cover extra RGB
  components plus duplicate `colr` boxes.
- Added explicit JP2 header required-box regression coverage for missing
  `ihdr`, missing `colr`, and misplaced `colr` before `ihdr`.
- Added a narrow `jp2c` payload signature check: JP2 wrapping and metadata
  parsing now reject codestream boxes that do not start with `SOC` or end with
  `EOC`, while leaving full strict marker validation to the codestream reader.
- Extended that JP2 sanity check to the first `SIZ` marker: the reader now
  rejects codestream boxes whose width, height, component count, bit depth, or
  component sampling disagree with the JP2 `ihdr` metadata.
- Tightened the JP2 `SIZ` sanity gate to the current fail-closed profile:
  nonzero `Rsiz`, nonzero image origins, tile origins that differ from the image
  origin, or tile sizes that imply real multi-tile payloads are rejected until
  that path is enabled.
- Added explicit `SIZ` length validation in the JP2 container sanity check so
  malformed `Lsiz`/component-table combinations fail before metadata is trusted.
- Added a positive JP2 wrapper regression using a real z2000 lossless
  codestream, proving the stricter `SIZ` sanity gate still accepts normal
  encoder output and returns the exact embedded `jp2c` bytes.
- Added the same real-codestream JP2 `SIZ` sanity coverage for 16-bit RGB,
  including a negative `ihdr` bit-depth mismatch check.
- Added writer-side JP2 `SIZ` mismatch regressions so wrapping an image with
  codestream metadata for a different bit depth or image shape fails before
  emitting a container.
- Added real-codestream JP2 `SIZ` component-table regressions for signed
  components, mismatched per-component precision, and unsupported component
  subsampling.
- Consolidated the real-codestream JP2 test fixtures so the 8-bit and 16-bit
  `SIZ` sanity tests share one owned RGB fixture helper.
- Added a combined real-codestream JP2 + restricted ICC preservation regression
  that validates `SIZ` metadata, `jp2c` extraction, and ICC extraction together.
- Added a real-codestream JP2 negative ICC regression so empty restricted ICC
  payloads are rejected before emitting a `colr` box.
- Hardened JP2 codestream sanity checks so corrupted bytes immediately after
  the `SIZ` marker segment are rejected unless they start the next marker.
- Normalized malformed JP2 `XLBox` overflow handling to deterministic
  `InvalidBox` diagnostics.
- Added JP2 `ihdr` fail-closed regressions for unknown colorspace and
  intellectual-property flags in the narrow RGB profile.
- Tightened JP2 `ftyp` validation so nonzero minor versions fail closed for the
  current basic `jp2 ` profile.
- Added a lightweight JP2 codestream main-header walk so duplicate `SIZ`,
  premature `SOD`, malformed marker lengths, or non-marker bytes before the
  first tile-part are rejected before container metadata is trusted.
- Extended that JP2 main-header sanity gate to require `COD` and `QCD` before
  the first `SOT` in real tile-part codestreams.
- Tightened the same JP2 main-header gate to reject duplicate `COD` or `QCD`
  marker segments in the narrow single-profile codestream.
- Kept per-component `COC`/`QCC` main-header marker segments fail-closed in the
  JP2 wrapper/parser until their payload behavior is wired end-to-end.
- Kept additional profile-changing main-header markers (`CAP`, `RGN`, `POC`,
  `PPM`, `PPT`, and `CRG`) fail-closed at the JP2 wrapper/parser boundary.
- Changed the JP2 main-header sanity walk to a narrow whitelist: only `COD`,
  `QCD`, `TLM`, and `COM` are accepted before the first `SOT`; unknown
  length-segment markers now fail closed.
- Added a first-`SOT` sanity check in the JP2 wrapper/parser so malformed
  `Lsot` values are rejected before container metadata is trusted.
- Extended first-`SOT` sanity validation for the narrow single-tile profile:
  nonzero tile indexes, nonzero first tile-part indexes, unknown tile-part
  counts, zero `Psot`, and out-of-range `Psot` are rejected at the JP2 boundary.
- Added a lightweight first tile-part header sanity pass so JP2 wrapping/parsing
  requires a `SOD` delimiter after optional `PLT`/`COM` marker segments.
- Added JP2 boundary checks for minimum marker segment lengths on whitelisted
  `COD`, `QCD`, `TLM`, `PLT`, and `COM` segments.
- Tightened JP2 `TLM` sanity for the narrow single-tile profile: unsupported
  `Stlm`, nonzero tile indexes, malformed entry byte counts, and zero `Psot`
  entries fail closed.
- Tightened JP2 `PLT` sanity in the first tile-part header: empty length
  payloads and non-sequential `Zplt` indexes now fail closed.
- Added JP2 `COD` profile sanity for the current public path: reserved `Scod`,
  unsupported progression orders, zero layers, unsupported MCT flags,
  unsupported code-block style bits, malformed precinct payload lengths, and
  unknown transform bytes fail closed before container metadata is trusted.
- Extended JP2 `COD` sanity to reject oversized code-block exponents and
  code-block areas above the Part 1 limit used by the strict reader.
- Tightened JP2 `COD` MCT sanity so RGB codestreams with MCT disabled fail
  closed until `--mct none` has real payload behavior.
- Added JP2 `QCD` profile sanity so unsupported guard bits, scalar-derived
  quantization, invalid qstyle values, and band-count length mismatches fail
  closed at the wrapper/parser boundary.
- Added positive JP2 wrapper coverage for the public 9/7 ICT scalar-expounded
  codestream path so profile hardening keeps the irreversible RGB path green.
- Tightened JP2 codestream tile-part sanity so real z2000 codestream payloads
  audit every sequential `SOT` through `EOC`, reject hidden multi-tile indexes,
  skipped `TPsot` values, inconsistent `TNsot` counts, and missing final
  tile-parts while preserving the current resolution tile-part profile.
- Connected JP2-boundary `TLM` sanity to the audited tile-part sequence: `Ptlm`
  entries are now collected from the main header and checked against each
  corresponding `SOT/Psot` value in the current narrow profile.
- Tightened JP2-boundary `PLT` sanity for the same profile: tile-part `PLT`
  segments now parse JPEG2000 variable-length packet spans, reject unterminated
  length values, and require the summed packet spans to match the actual `SOD`
  payload byte count.
- Extended the same JP2-boundary packet audit to `COD/Scod` packet-marker
  policy: `SOP` and `EPH` framing must match the advertised flags across
  `PLT` packet spans, and `SOP` sequence numbers are checked before the
  codestream is trusted.
- Tightened JP2-boundary `QCD` sanity for the reversible 5/3 path: no-quant
  exponent bytes must now match the `SIZ` component bit depth and expected
  LL/HL/LH/HH subband gains before the codestream is trusted.
- Tightened JP2-boundary `QCD` sanity for the public irreversible 9/7 path as
  well: scalar-expounded step-size values must match the encoder's
  OpenJPEG-style 9/7 norm table and LL/HL/LH/HH band ordering.
- Tightened JP2-boundary `COD` sanity so real z2000 codestreams must carry
  explicit precinct size bytes in `Scod`; implicit/default precinct geometry
  remains fail-closed until it is wired through the RPCL/T2 profile.
- Tightened JP2-boundary `COD` layer-count sanity so quality-layer counts above
  the current rate-allocation/T2 fixed metadata limit fail closed at the
  wrapper/parser boundary.
- Reconciled the ISO coverage scorecard totals with the current row-level
  estimates: narrow RGB lossless JP2 is 86/100 and the broader Part 1 family is
  44/100; the TIFF reader hardening is robustness work rather than a new ISO
  coverage point.
- Tightened the JP2 wrapper writer to reject unsupported bit depths and RGB
  sample buffers that do not match `width * height * 3`.
- Tightened strict codestream metadata parsing for the supported packet path:
  SIZ component precision/sign/subsampling, single-tile geometry, COD layer
  count/segment length, and QCD ordering are now validated before T2 audit.
- Locked strict COD code-block style policy to fail-closed for every nonzero
  style byte; standalone EBCOT style tests remain internal until their payload
  behavior is wired through strict codestream decode.
- Defaulted normal encode to SOP-on and EPH-off for the current independent
  decoder interop path; explicit `--eph` remains available for packet-boundary
  diagnostics while EPH sequencing is hardened.
- Added the first ICC preservation slice: TIFF tag 34675 is carried as owned RGB
  image metadata, JP2 wrapping writes a restricted ICC `colr` box, `jp2-info`
  reports ICC presence/size, and `decode-temp-jp2` writes the profile back to
  TIFF without transforming pixel values.
- Added malformed ICC coverage for zero-length/truncated TIFF profile tags and
  unsupported restricted-ICC JP2 `colr` box variants.
- Added an ICC-absent TIFF-to-JP2 fixture test to keep no-profile RGB input
  explicit and valid without inventing a JP2 ICC profile.
- Recorded the current interop gate: no-sidecar/no-EPH output strict-decodes in
  z2000 and is accepted losslessly by OpenJPEG and Grok; Grok no longer reports
  PL marker length warnings after RPCL subband precinct projection was fixed.
- Added the first public irreversible profile path: ICT, ISO-scaled 9/7,
  scalar-expounded QCD, deadzone quantization, and inverse quantization for the
  narrow single-tile RPCL profile.

### Temporary JP2 Payload

- Advanced the private payload through BP5, BP6, BP7, and BP8 style metadata.
- BP5 records quality-layer allocation metadata.
- BP6 records EBCOT/MQ segment metadata for stats and future packetization.
- BP7 additionally carries actual EBCOT/MQ bytes while the temporary decoder
  still consumes the legacy bitplane payload.
- BP8 adds a shadow RPCL packet stream built from normalized packet-local
  code-block leaf locations.
- `jp2-stats` reports block, pass-stream, quality-layer, and EBCOT/MQ segment
  statistics plus shadow RPCL packet counts/bytes.
- For normal no-sidecar codestreams, `jp2-stats` now relies on strict SOD packet
  audit data instead of private BP metadata.

### T1 And MQ

- Added a standalone JPEG2000-style binary MQ coder module with context state
  table and marker-stuffing aware byte output.
- Added roundtrip tests for short, all-zero, all-one, alternating, and context
  reset symbol streams.
- Added EBCOT coding pass metadata and MQ-backed code-block segment assembly.
- Added direct MQ emission for code-block segments to avoid a separate symbol
  oracle on the hot path.
- Added scratch-buffer reuse for EBCOT direct encoding.
- Added cleanup pass run-mode symbols for full four-row clean stripes in both
  the symbol oracle and direct MQ T1 paths, with matching coefficient decode.
- Split EBCOT sign coding into JPEG2000-style horizontal and vertical sign
  contributions, including sign prediction and mixed-neighbor context tests.
- Added magnitude-refinement context selection for first refinement with and
  without significant neighbors, plus later refinement passes.
- Added standalone EBCOT segmentation-symbol cleanup trailers behind an
  internal code-block style flag, with direct MQ roundtrip and corruption tests.
- Added standalone EBCOT reset-context style support for continuous MQ segments,
  resetting probability states at coding-pass boundaries while preserving the
  continuous payload stream.
- Extended inferred continuous MQ/T1 payload decoding to honor the same
  internal reset-context and segmentation-symbol style state.
- Added standalone EBCOT vertical-causal context handling, ignoring south
  neighbors across stripe boundaries in the symbol oracle, direct MQ path, and
  coefficient decoder.
- Added style-aware partial coefficient decode helpers for direct and continuous
  EBCOT segments so quality-layer pass prefixes can be validated with the same
  internal code-block style state.
- Added standalone EBCOT terminate-all style support, writing pass-terminated
  MQ segments and decoding them through the continuous API when the internal
  style is supplied.
- Added explicit `CodeBlockStyle` metadata for all six COD code-block style
  bits. BYPASS is now wired through public codestream payloads for the ISO-MQ
  backend; the other style bits remain fail-closed until their payload behavior
  is implemented end to end.
- Tightened strict COD parsing so every nonzero code-block style byte remains
  `UnsupportedPayload` until that exact style is wired end-to-end through the
  writer, reader, tests, and interop gates.

### Quality Layers And Rate Allocation

- Added `rate_alloc.zig`.
- Added even layer allocation.
- Added compression-ratio target mapping.
- Stored per-code-block cumulative pass and byte truncation points.
- Connected layer truncation metadata to T2 packet delta helpers.
- Connected `--rates` to public quality-layer counts. Current allocation is
  byte-target based, so access-profile output can be larger and higher-PSNR
  than Grok/OpenJPEG for the same nominal compression-ratio ladder.

### T2 Packet Work

- Added packet-header bit writer/reader with JPEG2000 marker-safe stuffing.
- Added tag-tree encoder/decoder.
- Added tag-tree known-node state and rollback so continued packets do not
  re-consume already proven inclusion/zero-bitplane tag-tree bits after a
  successful threshold decision.
- Added code-block packet state, `numlenbits`/segment length state, and zero
  bit-plane handling.
- Added precinct packet writer/reader tests for first inclusion, continued
  inclusion, payload deltas, and truncated-payload rollback.
- Added RPCL packet iterator and direct packet lookup.
- Added precinct rectangle helpers and edge clipping.
- Added code-block selection helpers for RPCL packets.
- Added encoded-block to `LayerPacketBlock` bridge helpers.
- Added writer-state initialization from encoded blocks, including delayed first
  inclusion tests.
- Added a strict SOD-backed packet block catalog that reconstructs per-component
  code-block metadata, cumulative pass/byte counts, and owned payload views
  without requiring the BP8 debug sidecar.
- Normal no-sidecar decode now validates the strict packet block catalog
  instead of treating SOD bytes as a temporary payload; current T1
  reconstruction uses that catalog for the RPCL/RCT/5-3 roundtrip.
- BP8 debug validation now compares the public strict block catalog against the
  BP8 EBCOT catalog for geometry, cumulative pass/byte deltas, and payload bytes.
- ISO-MQ BP8 debug validation now uses the same strict SOD packet block catalog
  as normal no-sidecar decode for image reconstruction, while keeping byte-for-
  byte BP8 shadow-stream checks as the diagnostic oracle.
- Fixed RPCL code-block indexing so each block is assigned to one precinct cell
  instead of every intersecting precinct, avoiding duplicate first-inclusion
  state and reducing packet payload size on larger images.
- Fixed RPCL high-pass precinct projection so packet code-block selection uses
  subband-local low/high coordinates instead of transformed-plane offsets,
  aligning PLT packet lengths with Grok's packet parser.
- Fixed terminal `0xff` packet-header stuffing so PLT packet lengths also match
  independent decoder packet parsers when a packet header ends exactly on an
  all-ones byte.
- Strict main-header and tile-part readers now reject unsupported marker
  segments such as COC, QCC, POC, PPM/PPT, RGN, CRG, PLM, and CAP instead of
  silently skipping payload behavior that is not implemented.
- Tightened strict marker validation for the current no-sidecar path: SOT
  sequence/count, TLM tile indexes and Psot values, PLT packet spans, SOP/EPH
  policy and duplicate markers, and packet-header marker stuffing now have
  explicit regression coverage.
- Accepted ordered multi-segment TLM and PLT metadata in the strict reader while
  rejecting skipped marker indexes.
- Accepted tile-part COM marker segments as metadata before SOD.
- Added a metadata-inferred continuous MQ code-block decoder and wired complete
  single-layer strict RPCL reconstruction to use SOD payload bytes without
  relying on BP8 per-pass payload tables.
- Normal no-sidecar strict decode now reconstructs the current single-layer
  RPCL/RCT/5-3 path from the strict T2 block catalog, including zero-block
  geometry derived from codestream subband layout.
- Multi-layer lossless encode now uses continuous MQ code-block segments too,
  with quality-layer byte ranges snapped to actual coding-pass truncation
  points and mirrored consistently in BP8 debug metadata.

### Parallelism And Performance

- Added deterministic component-level encode/decode parallelism.
- Added encode-side code-block range scheduling for high thread counts.
- Reused scratch buffers in bitplane, entropy, and EBCOT paths.
- Added timing output for TIFF read, RCT, DWT, payload generation, JP2 wrapping,
  and disk write.
- Ran comparative local benchmarks against Grok, OpenJPEG, and Kakadu where
  available.
- Added `tools/bench_compare.sh` and `tools/compare_tiff.py` for local macOS
  benchmark and pixel-check workflows.
- Started the MQ fast-path optimization: direct ISO-MQ block encoding now
  finalizes codeword segments into the reusable per-worker payload buffer
  instead of returning a temporary owned slice. Raw BYPASS segments now use
  the same direct payload sink, MQ BYTEOUT keeps that active sink local through
  carry/marker handling, and the common MPS/no-renorm branch is split out in
  the ISO MQ encoder/decoder.
- Tightened continuous ISO/NBF decode state updates so inferred and BYPASS
  decode paths stop writing legacy per-sample `u8` flags when the packed
  neighborhood flags already carry the required significance/refinement state.
- Replaced generic scan-iterator use in raw BYPASS significance/refinement
  decode with direct stripe/x/dy loops matching the inferred ISO/NBF pass
  walkers, advancing packed-flag and coefficient indices incrementally inside
  each stripe column.
- Vectorized packed-neighborhood visit-bit clearing with the portable SIMD
  lane policy already used elsewhere in T1 scratch cleanup.
- Added word-granular T1 range skipping inside active 4-row stripes: inferred
  ISO-MQ and raw BYPASS significance/refinement passes now skip 64-column
  chunks whose row-significance window proves they cannot emit symbols.
- Added a guarded packed-column T1 cleanup-run cache prototype and measured the
  isolated RLC-only version as a regression on the local 2048 RGB lossless
  profile.
- Removed the measured-slower RLC-only packed cleanup-run cache and its scratch
  storage after the full OpenJPEG-style packed T1 context-word scaffold gained
  equivalent cleanup-run parity coverage.
- Added an OpenJPEG-style packed sigma/sign-window scaffold using the `3 * ci`
  shift layout, plus unit tests that prove zero-coding and sign-coding context
  parity with the current u16 neighborhood flags.
- Added PI/MU packed-bit parity tests for significance-pass membership,
  refinement-pass membership, and refinement context selection.
- Added an incremental OpenJPEG-style packed-word updater test that matches
  full rebuilds across block edges and 4-row stripe boundaries, covering sigma,
  CHI, PI, and MU state before the packed T1 hot path is enabled.
- Added packed ZC, SC, significance, and refinement helper parity tests against
  the current `u16` flag path for every subband and vertical-causal rows.
- Added a disabled packed T1 context-word scratch buffer/guard so the ZC/SC
  packed migration can be staged around the full OpenJPEG-style layout.
- Centralized packed T1 decision parity in helper functions and added a dense
  edge/stripe-boundary stress test covering all subbands and vertical-causal
  rows.
- Wired the disabled packed T1 context buffer into guarded visit, refine,
  significance, and per-bitplane visit-clear updates, with PI clear parity
  coverage against full rebuilds.
- Routed NBF/ISO significance, refinement, and cleanup context selection
  through shared T1 decision helpers, preserving the `u16` path while giving
  the packed guard a debug-checked loop boundary.
- Enabled Debug/ReleaseSafe packed T1 shadow maintenance with loop-boundary
  parity assertions, while keeping ReleaseFast free of shadow work unless the
  packed guard is explicitly enabled.
- Added a `-Dpacked-t1-context-flags=true` build option so the experimental
  packed T1 hot path can be tested and benchmarked without editing source.
- Added a cleanup-run eligibility helper over the full OpenJPEG-style packed
  T1 words, with parity coverage for PI blocking and vertical-causal
  stripe-boundary masking. The active cleanup-run hot path remains on the
  existing `u16` flags until the packed path is benchmarked as a shared
  ZC/SC/RLC replacement.
- Routed encode/decode cleanup-run candidate selection through scratch-aware
  helpers so a future packed T1 guard flip uses the shared packed context-word
  buffer.
- Routed decode cleanup-run sign-context selection through the shared T1
  decision helper after runlength decoding, extending packed shadow parity to
  the RLC decode corner and removing a local `u16`-only calculation.
- Added Debug/ReleaseSafe packed T1 shadow assertions for cleanup-run
  eligibility inside the real encode/decode RLC loops, while keeping ReleaseFast
  on the existing `u16` hot path unless the packed T1 guard is enabled.
- Removed the obsolete cleanup-sample `causal_row` plumbing now that
  vertical-causal handling is centralized in the shared T1 decision helpers.
- Removed the now-obsolete RLC-only cleanup-run cache test coverage; cleanup-run
  parity now lives on the full packed T1 context-word helper.
- Extended `tools/bench_compare.sh` with `ZIG_BUILD_FLAGS` so experimental
  build options can be benchmarked without editing source.
- Re-ran the local macOS 2048x2048 archival benchmark (`RUNS=3`, ten threads):
  z2000 encode 169.3 ms, decode 185.5 ms; Grok encode 109.9 ms, decode 78.0 ms;
  OpenJPEG encode 419.8 ms, decode 442.6 ms. `tiffcmp` confirmed pixel-lossless
  z2000 single-thread/ten-thread decode and Grok/OpenJPEG decodes of z2000
  output; the optional Python pixel checker was skipped because Pillow was not
  installed.
- Benchmarked the experimental packed T1 hot path with
  `ZIG_BUILD_FLAGS="-Dpacked-t1-context-flags=true"`: output remained
  lossless, but encode/decode regressed to 241.9 ms / 226.3 ms at ten threads
  and 918.1 ms / 837.2 ms single-thread, so the guard stays disabled by
  default.
- Updated the optimization roadmap to prioritize decode-side T1/MQ
  instrumentation, MQ decoder fast paths, block-level decode scheduling, and
  lower-maintenance packed T1 experiments before any packed hot-path default.
- Removed per-sample parity branches from integer inverse 5/3 unpacking by
  splitting low/high samples into separate even/odd loops for rows and columns.
- Added block-level strict decode workers for `--threads > 3`: each component
  validates block coverage first, then partitions code-block decoding across
  worker-local `DecodeBlockScratch` instances and scatters into disjoint rects.
- Changed the parallel strict decode coverage audit from a full per-pixel bool
  map to row-granular `u64` bitsets, reducing temporary RAM and validation
  memory traffic before worker scatter.
- Tightened RPCL packet assembly by preparing packet blocks directly from the
  cached encoded block table instead of allocating an intermediate
  `LayerPacketBlock` slice for every packet group/layer.
- Kept the small per-packet prepared group table on the stack for RPCL packet
  assembly, avoiding another heap allocation in the T2 hot path.
- Removed the now-redundant identity index table from encode-side RPCL band
  groups; encoded blocks are already stored in local tag-tree order.
- Removed the per-packet-group payload-slice array from RPCL assembly; payload
  slices are derived directly from encoded layer truncation points when needed.
- Applied the same payload-slice elision to the shared T2
  `appendPrecinctLayerPacket` helper, keeping only the packet-block array
  needed by the header writer.
- Removed the generic `appendRpclPacketForIndexes` `LayerPacketBlock` staging
  allocation; indexed RPCL helpers now prepare packet blocks directly from
  encoded layer blocks before writing payload bytes.
- Centralized T2 `LayerPacketBlock` to `PacketBlock` preparation so segment
  length validation is shared by precinct and indexed RPCL packet writers.
- Removed the extra worker-owned plane allocation/copy from the
  component-parallel strict decode path; workers now fill preallocated final
  Y/Cb/Cr planes while keeping temporary scratch state local.
- Changed strict decode scatter/coverage updates to operate row-by-row with
  slice copies and row coverage fills instead of per-sample destination writes.
- Tightened strict PLT parsing so a PLT marker segment that carries only an
  index byte and no packet lengths is rejected, with a malformed-codestream
  regression test that keeps SOT/TLM framing internally consistent.
- Added matching strict TLM malformed coverage for a TLM segment with `Ztlm`
  and `Stlm` but no tile-part entry payload.

### Documentation

- Added `docs/architecture.md`.
- Added `docs/changelog.md`.
- Added `docs/roadmap.md`.
- Added `docs/api.md`.
- Added `docs/iso_coverage.md` to track estimated progress toward the narrow
  RGB lossless JP2 target and the broader JPEG2000 Part 1 codec family.

## Initial Milestone

- Added grayscale PGM encode/decode for a custom `.z2000` codestream.
- Added reversible 5/3 and irreversible 9/7 wavelet experiments.
- Added multi-level decomposition and scalar quantization experiments.
- Added a narrow TIFF reader and JP2 box scaffold.
- Added reversible RCT for RGB.
- Added temporary RGB JP2 roundtrip back to TIFF.
