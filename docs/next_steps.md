# ISO Coverage — Gap Analysis & Prioritized Next Steps

Companion to `docs/iso_coverage.md` and `docs/roadmap.md`. This file turns the
scorecard gaps into concrete, testable work items: for each gap it names the
ISO/IEC 15444-1 clause, the current code location, exactly what is missing, a
test plan, and an estimated score delta. Ordered by *value per unit risk*.

Originally re-verified at commit `d664306` (scorecard **86/100 narrow,
44/100 full**, `iso_coverage.md` dated 2026-07-05). Current scorecard after
the subsequent JP2/T2/T1/profile work is **100/100 narrow, 100/100 full** as of
2026-07-13. First drafted at `ba66799`.

## Reached 100/100 (2026-07-13 assessment)

The final scorecard point landed as a genuine component-layout vertical, not an
incremental parser gate: bounded Part 1 palette encode/decode with checked RGB
expansion and live OpenJPEG/Grok pixel agreement.

| Row | Gap | Size | Risk | Verifiable here? |
| --- | --- | --- | --- | --- |
| Containers 9→10 | **N6 palette vertical:** one index component, unsigned uniform RGB `pclr`, identity `cmap`, checked expansion | LANDED | Bounded semantics keep the codestream core one-component and fail closed elsewhere | Yes: local malformed matrix plus OpenJPEG/Grok live decode |

The engineering scorecard is complete, but this is not a formal ISO
certification or a claim of arbitrary JP2/JPX support. Mixed precision, alpha,
general N-component layouts, and broader palette mappings remain explicit
breadth work. PCRD quality research also continues independently.

Performance checkpoint (2026-07-13): rate-targeted direct-MQ encode now
captures exact per-pass distortion during the real T1 traversal. Removing the
duplicate symbol-coder pass cut the maintained Ryzen lossy encode gate by
64.1% t1 and 56.6% t16 with byte-identical output. Remaining performance work
is concentrated in decode T1, lane-width validation, and parallel efficiency;
this changes no ISO score.

## Next Working Sequence (2026-07-12)

Scorecard now **100/100 narrow, 100/100 full**. Packed PPM/PPT headers support
all SOP/EPH combinations with ISO marker placement and checked length
accounting; the 16-tile/48-part two-layer PPM smoke is pixel-exact through
z2000, OpenJPEG, and Grok. The bounded multi-tile path has
all five progression orders, quality layers including the first tile-local
rate-target slice, and the implemented resilience matrix. CAUSAL+SEGMARK,
RESET+TERMALL, ERTERM+TERMALL, and BYPASS+TERMALL all
roundtrip through strict decode and decode pixel-exactly with OpenJPEG/Grok/Kakadu;
T1 BYPASS mode is preserved explicitly into T2 readback. Uniform Kakadu
COC/QCC style and QCD overrides now decode through z2000 when all RGB
components agree; partial/divergent overrides fail closed. Standalone ERTERM
(COD `0x10`, plus `0x12` with RESET) is public with bidirectional Kakadu
interop, and the multi-tile gate admits standalone RESET/ERTERM as well
(strict roundtrip plus pixel-exact kdu_expand decode of genuine multi-tile
output). **All six code-block style bits are now public in every
combination (2026-07-12, T1 completeness 14->15, full estimate 89->90):**
BYPASS carries RESET (context restarts at MQ pass boundaries) and ERTERM
(predictable alternating-bit raw termination, ER-TERM MQ flush) in both the
non-TERMALL and per-pass TERMALL segment models, encode-leg verified through
kdu_expand/opj_decompress/grk_decompress and decode-leg verified against
seven kdu Cmodes combinations up to the full six-bit style, all pixel-exact.
The malformed-input sweep now includes multi-tile BYPASS+TERMALL as its seventh
profile, and PLT-less multi-tile streams now strict-decode by deriving
tile-local packet spans from T2 packet headers. The foreign OpenJPEG/Grok/Kakadu
PLT-less multi-tile smoke is green for explicit and COD-default precincts,
including Kakadu's reordered `0,1,3,2` tile-part sequence. Global cross-tile
PCRD `--rates` is wired for reversible and irreversible multi-tile paths with
z2000/OpenJPEG/Grok/Kakadu smoke gates. Reference-grid precinct/code-block/
tag-tree anchoring and odd-
origin reversible 5/3 lifting are now bidirectionally interop-green for
PLT-less OpenJPEG, Grok, and Kakadu inputs and z2000 output. The strict T2
reader also accepts present geometry-empty edge packets while still requiring
zero contributions and zero payload. PLT-backed RPCL `R` divisions emit and
decode one part per resolution per tile, with z2000/OpenJPEG/Grok/Kakadu
pixel-exact interop on the 17x17 odd-origin gate. PLT-backed `L`/LRCP,
`C`/CPRL, and `P`/PCRL divisions are likewise pixel-exact through all four
decoders; all direct tile-part division modes are now implemented on matching
orders. **Foreign multi-part tile
sequences now decode (2026-07-11, full lossless-decode row 14->15, estimate
88->89):** per-part PLT packet accounting joins each tile's parts in TPsot
order whether grouped or interleaved across tiles, TNsot 0 "count not
signalled" (A.4.2) completes via packet accounting at EOC, empty SOT+SOD
padding parts need no PLT, joined non-RPCL tiles reorder once assembled, and
the JP2 TLM capacity is tile-part sized (4096). Two embedded Kakadu fixtures
(ORGtparts=L interleaved TNsot-0 layer parts; TNsot=8 empty padding + 32-entry
TLM) decode the 64x64 gradient exactly with fail-closed accounting negatives,
and the live kdu matrix (16/32-part tiles, LRCP/RPCL/CPRL-3layers/ERTERM on
2048x2048 noise) is pixel-exact. This closes the historical kdu-multitile
interop GAP. **Global cross-tile PCRD rate targets landed 2026-07-12
(lossless-encode row 15/15, estimate 91->92):** one slope threshold over
every tile's blocks with whole-image byte targets, a heterogeneous-grid
regression pinning the budget and per-tile deviation from proportional
splits, and a pixel-exact z2000/kdu/opj/grok rate-targeted multi-tile smoke.
The next structural gates are non-empty PLT-less cross-part packet-state
decode and tile-level scheduling.

The remaining levers are larger and structural. Ordered by *value per unit
risk*; each names the ISO clause, the current code state, exactly what is
missing, a test plan, and a score delta. Detailed tier notes for already-landed
items are preserved further below as implementation history.

Separate from the ISO scorecard, keep a post-Part 1 conversion backlog: JPEG,
PNG, and BMP input first; later RAW/DNG and OpenEXR; richer palette mappings,
YCC, extended YCC, CIELab, and CMYK color handling; EXIF/IPTC/XMP metadata
preservation; and higher-than-16-bit component precision only when the source
format, codestream profile, and container semantics are explicit.

### N0. Narrow 100 stabilization — first T2 slice — ✅ LANDED

- **Scope:** no-sidecar strict T2 audit for rate-targeted multi-layer RPCL and
  deterministic packet-header corruption rejection without the BP8 oracle.
- **Coverage:** the new regression decodes a rate-targeted three-layer stream
  from SOD packet state, verifies repeated block inclusions across layers via
  `auditStrictPacketHeaders`, then flips the first real SOD packet-header byte
  and requires both audit and decode to fail as `InvalidCodestream`.
- **Score policy:** no score bump yet; this is the first slice toward raising
  narrow T2/strict-decode rows after a broader packet-state corruption matrix
  and interop pass.

### N0b. Narrow TIFF fail-closed matrix — ✅ LANDED

- **Scope:** pin the supported TIFF 6.0 input boundary for the narrow RGB path.
- **Coverage:** uncompressed chunky RGB strips remain the accepted path;
  compressed TIFF, palette/unsupported photometric data, planar RGB, extra
  samples/alpha, mixed bit depth, signed sample format, and tile-only TIFFs
  without strip tags now have explicit parser rejection tests.
- **Score policy:** narrow TIFF input/output 6->7, moving the narrow target
  92->93. Real tiled TIFF input is now a later broadening feature, not an
  ambiguity in the narrow target.

### N0c. Narrow core marker fail-closed matrix — ✅ LANDED

- **Scope:** raw strict codestream rejection for unsupported Part 1 marker
  segments that are known but outside the narrow profile.
- **Coverage:** CAP, PLM, RGN, POC, PPM, and CRG in the main header now have
  explicit strict-reader fail-closed tests, and tile-part RGN/POC join the
  existing PPT/COC/QCC override rejection coverage.
- **Score policy:** narrow core main markers 8->9, moving the narrow target
  93->94. This set the stage for the final duplicate/order hardening pass.

### N0d. Narrow core marker duplicate/order hardening — ✅ LANDED

- **Scope:** finish the narrow core-marker score by rejecting structurally
  supported markers when their placement or repetition is invalid.
- **Coverage:** the raw strict reader now rejects duplicate `SIZ`, `COD`,
  `QCD`, and same-index `TLM` marker segments. `TLM` is accepted only after
  `COD` and `QCD` have established the packet/tile-part context; the same
  ordering rule is mirrored at the JP2 wrapper boundary.
- **Score policy:** narrow core main markers 9->10, moving the narrow target
  94->95. Future marker work should broaden supported profiles, not reopen
  the narrow marker boundary.

### N0e. Narrow tile-part marker phase hardening — ✅ LANDED

- **Scope:** close the final narrow tile-part marker gap by proving that a
  syntactically valid tile-part header marker is rejected when it appears in
  the packet payload phase instead of before `SOD`.
- **Coverage:** the regression moves the first `PLT` segment from the
  tile-part header to immediately after `SOD`; both strict packet-catalog read
  and normal strict decode fail deterministically as `InvalidCodestream`.
- **Score policy:** narrow tile-part markers 9->10, moving the narrow target
  95->96. Future tile-part work should focus on broader tile-part divisions and
  external streams, not the current narrow marker boundary.

### N0f. Narrow T2 consistent-truncation gate — ✅ LANDED

- **Scope:** strengthen the no-sidecar multi-layer RPCL path against packet
  truncation that keeps marker accounting internally consistent.
- **Coverage:** the regression removes the final SOD payload byte and shortens
  the final `PLT` packet length plus `SOT/Psot` and `TLM/Ptlm` by the same
  amount. The marker span check passes far enough to enter strict T2 packet
  reading, where `readStrictPacketBlockCatalog` and normal strict decode fail
  deterministically as `TruncatedData`.
- **Score policy:** narrow T2 RPCL packetization 13->14, moving the narrow
  target 96->97. The final T2 point should stay reserved for broader
  progression-order and interop discipline.

### N0g. Narrow strict decode sidecar-retirement proof — ✅ LANDED

- **Scope:** close the strict-decode narrow row by proving the normal no-sidecar
  path carries style-aware T2/T1 metadata for BYPASS without relying on BP8.
- **Coverage:** the existing BYPASS strict SOD roundtrip now also asserts that
  the codestream contains no `ZJ2K-CBLK-BP8` sidecar, that
  `readStrictPacketBlockCatalog` yields metadata-ready BYPASS blocks, that
  multi-segment block lengths are present, and that payload views are non-empty
  before normal strict decode reconstructs the original pixels.
- **Score policy:** narrow strict decode 9->10, moving the narrow target
  97->98. Future strict-decode work should protect this guarantee while adding
  broader packet orders and style combinations.

### N0h. Narrow T2 later-layer state corruption gate — ✅ LANDED

- **Scope:** close the narrow RPCL/T2 packetization row by proving packet-header
  corruption is rejected after the reader has already carried RPCL packet state
  across earlier layer packets.
- **Coverage:** the regression encodes a no-sidecar, rate-targeted, three-layer
  RPCL stream, verifies the clean audit has repeated block inclusions across
  layers, then flips the header byte of packet index 1 using PLT-derived packet
  boundaries. Both `auditStrictPacketHeaders` and normal strict decode reject
  the stream as `InvalidCodestream`.
- **Score policy:** narrow T2 RPCL packetization 14->15, moving the narrow
  target 98->99. The remaining narrow point is T1/EBCOT/MQ.

### N0i. Narrow T1 corpus closure — ✅ LANDED

- **Scope:** close the final narrow point by proving the no-sidecar strict path
  carries real T1/EBCOT payloads across representative sparse, dense/sign-heavy,
  and refinement-heavy RGB inputs.
- **Coverage:** the regression encodes three 32x32 RGB patterns with the narrow
  RCT/5-3/RPCL profile, asserts no BP8 sidecar is present, reads the strict
  packet block catalog, verifies metadata-ready blocks with non-empty payloads,
  multi-pass and multi-bitplane T1 content, and then strict-decodes each image
  byte-exactly.
- **Score policy:** narrow T1/EBCOT/MQ 19->20, moving the narrow RGB lossless
  JP2 target to 100/100. This is a narrow target claim only; the full Part 1
  codec score remains separate.

### F1. PLT-less multi-tile strict decode and interop — ✅ LANDED

- **Scope:** move the lossless decode row one step beyond the single-tile
  PLT-less foreign matrix by allowing aligned z2000 multi-tile streams to omit
  `PLT` while still decoding through the public strict path.
- **Coverage:** the new regression strips every `PLT` segment from a 3x3
  z2000 multi-tile codestream, adjusts `SOT/Psot` and 0x60 `TLM/Ptlm`
  accounting, verifies the stream remains PLT-less, strict-decodes it
  byte-exactly, and runs the strict packet-header audit. The multi-tile SOT
  walk now records PLT-less tile spans, and the per-tile catalog derives
  packet boundaries from tile-local T2 packet headers. A second regression
  covers no-TLM/no-SOP/no-EPH framing, and a third accepts a unique reordered
  tile-part sequence. `tools/interop_pltless_multitile.ps1` generates
  explicit- and default-precinct PLT-less multi-tile JP2s with OpenJPEG, Grok,
  and Kakadu; z2000 strict-decodes every case pixel-exactly. Reference-grid-
  aware tile packet plans provide the default-precinct geometry without
  relaxing encoder policy.
- **Score policy:** full lossless decode profiles 10->13 across the two landed
  slices. The default-precinct foreign matrix moves the reconciled full estimate
  86->87;
  broader component/layout coverage and more marker combinations remain.

### N1. Core codestream syntax — redundant COC/QCC — ✅ LANDED

- **ISO clause:** A.6.2 (COC), A.6.5 (QCC) — component-specific coding/
  quantization markers.
- **State:** the strict main-header walk and JP2 wrapper accept COC/QCC only
  when they byte-replicate the main COD/QCD for a valid RGB component, or when
  they provide a uniform override across all three RGB components for an
  otherwise supported COD/QCD payload model. Partial or divergent
  per-component overrides fail closed because z2000 still has no independent
  per-component coding path.
- **Coverage:** splice oracle inserts redundant COC/QCC into a valid z2000
  codestream and asserts byte-exact strict decode plus JP2 acceptance.
  Mismatched COC and QCC rewrites fail closed in both strict decode and JP2
  wrapper validation. Malformed COC `Scoc`/SPcoc coding bytes and malformed QCC
  qstyle cases are rejected as invalid codestream data by both paths. Shortened
  COC/QCC lengths are bounded as truncation in the raw reader plus invalid at
  the JP2 boundary. Tile-part COD/QCD and COC/QCC markers are explicitly
  rejected as unsupported until per-tile/per-component overrides exist.
- **Coverage:** real Kakadu style/QCD files now exercise this path through
  `tools/interop_kakadu_styles.ps1`; the reverse matrix is pixel-exact for
  RESTART, RESET+RESTART, ERTERM+RESTART, BYPASS+RESTART, CAUSAL+SEGMARK, and
  a uniform QCD guard-bit override.

### N2. Multi-tile v2 — one axis at a time — L · High

- **Impact:** full "Lossless encode" 10→11, "Lossless decode" 12→13, "Core
  syntax" +1. (+3 from the current score, still one of the biggest full-target
  levers)
- **ISO clause:** B.3–B.12 (tile grid, per-tile SOT/SOD, tile-part order).
- **State:** multi-tile v1/v2 is interop-proven for aligned RPCL and multi-layer
  LRCP/RLCP/PCRL/CPRL grids. The envelope is RCT/5-3, untargeted quality layers
  across all five progression orders, the complete resilience style matrix,
  global cross-tile PCRD, and one tile-part per tile plus PLT-backed `R`/RPCL,
  `L`/LRCP, `C`/CPRL, and `P`/PCRL divisions. Gates:
  `validateMultiTileCodingPath` / `validateMultiTileGeometry` in `codestream.zig`.
- **What to add (staged, each its own PR, single-tile byte-identical at every
  step):**
  - **v2a — non-RPCL progressions in multi-tile.** All five orders are wired
    through per-tile packet build and strict per-tile slot walk. OpenJPEG and
    Grok decode three-layer LRCP/RLCP/PCRL/CPRL smokes losslessly. Remaining:
    Kakadu across the matrix.
  - **v2b — quality layers per tile.** Untargeted quality layers are wired for
    all five progression orders. Global cross-tile PCRD is wired for the
    reversible and irreversible profiles with strict roundtrip, deterministic
    threaded encode, and z2000/OpenJPEG/Grok/Kakadu smokes. Remaining:
    broader style/progression matrix coverage.
  - **v2c — reference-grid partition anchoring.** Packet plans retain
    per-resolution reference bounds and first precinct indexes; code-block
    partitions and tag-tree leaves use global subband origins. Foreign default-
    precinct streams strict-decode, and z2000 17x17 tiles with odd lifting
    parity decode pixel-exactly through OpenJPEG/Grok/Kakadu. Both the old
    `2^levels * precinct` guard and the later `2^levels` parity guard are gone;
    only tile-components that cannot carry the signalled global `NL` fail
    closed (ISO B.6/B.7 and Annex F).
  - **v2d — RPCL resolution tile-parts.** ✅ PLT-backed `R` divisions emit
    `NL+1` parts per tile, strict decode joins all parts before T2/T1, and the
    17x17 odd-origin output is pixel-exact through z2000, OpenJPEG, Grok, and
    Kakadu. Remaining: PLT-less cross-part span derivation and non-RPCL
    progression/division combinations.
  - **v2d — resilience styles.** LANDED: CAUSAL, SEGMARK,
    RESET+TERMALL, ERTERM+TERMALL, and BYPASS+TERMALL have deterministic strict
    roundtrips; representative combined/terminated files are pixel-exact in
    OpenJPEG, Grok, and Kakadu. Remaining: unsupported combinations.
- **Test plan:** per-stage public encode→decode byte-exact on 2×2 and 3×3
  edge-tile grids; `tile == image` byte-identical to the single-tile path;
  OpenJPEG/Grok/Kakadu decode of each genuinely multi-tile file.
- **Risk:** High (per-tile T2/T1 scheduling); keep the single-tile path a
  passing special case at every step.

### N3. T1 completeness — standalone ERTERM — ✅ LANDED (2026-07-11)

- **Impact:** full "T1 completeness" 13->14, moving the full estimate 82->83.
- **ISO clause:** D.4.5 (per-pass termination), D.4.2 (predictable
  termination), D.7 (bypass).
- **Landed:** standalone ERTERM (COD `0x10` without TERMALL) is public
  single-tile. The only termination point in a continuous MQ code-block is
  the final flush, so the continuous ISO-MQ encoders (both the symbol-based
  and the hot direct-scratch path, kept byte-identical by the extended
  direct/symbols equality matrix) now flush with the interop-verified
  `finishErterm` when the style requests it. The strict continuous decoders
  accept the style because MQ decode is flush-independent (the ER-TERM tail
  decodes with standard byte-in padding); `parseCodeBlockStyleByte` and the
  JP2 wrapper accept `0x10` standalone, including `0x12` with standalone
  RESET. The legacy backend and BYPASS combinations stay fail-closed
  (`hasUnsupportedPayloadMode` is now ERTERM+BYPASS). **Follow-up
  (2026-07-11): the multi-tile gate now admits standalone RESET/ERTERM/
  ERTERM+RESET too** — the tile pipeline routes non-TERMALL styles through
  the same direct ISO-MQ block encoder, so `validateMultiTileCodingPath`
  no longer repeats the standalone guards; a 2x2 LRCP 3-layer multi-tile
  roundtrip matrix (COD `0x02`/`0x10`/`0x12`, byte determinism at 1 and 3
  threads, JP2 acceptance) plus pixel-exact kdu_expand decode of genuine
  512x512-tile multi-tile output cover it.
- **Interop (Kakadu 8.4.1, this machine, 2048² RGB noise):** kdu_expand
  decodes z2000 `--predictable-termination` and
  `--predictable-termination --reset-context` output pixel-exactly — both
  single-tile and `--tile 512,512` multi-tile (plus multi-tile standalone
  `--reset-context`); z2000 strict decode reconstructs kdu `Cmodes=ERTERM`,
  `Cmodes={ERTERM|RESET}`, and `Cmodes={ERTERM|CAUSAL|SEGMARK}` files
  pixel-exactly.
- **Follow-up (2026-07-12): BYPASS+RESET and BYPASS+ERTERM landed**, closing
  the T1 completeness row at 15/15. The raw segments gained the predictable
  alternating-bit termination (ported from opj_mqc_bypass_flush_enc with
  erterm: the post-0xff empty byte is emitted as 0x2a instead of dropping
  the 0xff), RESET restarts MQ contexts at coding-pass boundaries in the
  BYPASS and BYPASS+TERMALL segment models, and every one of the 64 style
  combinations (0x00..0x3f) now has an implemented payload model. Interop:
  encode leg pixel-exact through kdu_expand, opj_decompress, and
  grk_decompress (including the full 0x3f style); decode leg pixel-exact for
  seven kdu Cmodes combinations up to {BYPASS|RESET|RESTART|ERTERM|CAUSAL|
  SEGMARK}. `tools/interop_kakadu_styles.ps1` carries the new forward and
  reverse cases and the old BYPASS+ERTERM fail-closed assertion is gone.
- **Remaining in this area:** nothing for the T1 completeness row; the
  legacy MQ backend keeps its own fail-closed gates by design.

#### Original N3 scoping (implementation history)

- **ISO clause:** D.4.5 (per-pass termination), D.7 (bypass), the ER-TERM annex.
- **State:** BYPASS (raw segments) and TERMALL (per-pass ISO-MQ termination)
  are each public and interop-proven. **BYPASS+TERMALL is now locally public**:
  the encoder emits one terminated segment per pass, raw for D.6 bypass
  significance/refinement passes and MQ for cleanup/non-bypass passes; the
  strict decoder consumes the same per-pass segment table and the JP2 wrapper
  accepts COD style `0x05`. OpenJPEG 2.5.4, Grok 20.3.6, and Kakadu 8.4.1
  decode the current single-tile and 2x2 multi-tile smokes losslessly.
  **Standalone RESET (COD `0x02`) landed**: per-pass MQ context
  restarts to the JPEG2000 initial states inside the continuous stream, with
  the direct/symbols byte-equality matrix extended and bidirectional
  OpenJPEG/Grok `-M 2` lossless interop. Standalone ERTERM and BYPASS
  combined with RESET or ERTERM stay fail-closed (multi-tile standalone
  RESET too).
- **What to add:** standalone ERTERM with a writer + strict reader + interop
  gate before opening its public profile. Keep BYPASS+RESET and BYPASS+ERTERM
  fail-closed until their segment models are implemented.
- **Test plan:** local byte-exact roundtrip + fail-closed corruption cases per
  remaining combination (extend the styled-T1 matrix), then OpenJPEG/Grok/Kakadu
  interop before lifting any gate.

### N4. Lossy breadth — foreign-9/7 decode validation — ✅ DECODE SIDE CLOSED (2026-07-11)

- **Impact:** full "Lossy encode/decode" now 12/15. 2026-07-11 landed, in
  order: the Kakadu 8.4.1 fixture plus the Kakadu reference-relative ladder
  (11/15, full estimate 83->84), then the **CI reference-relative decode
  matrix** (12/15, 84->85): six embedded foreign 9/7 JP2s — OpenJPEG `-r
  4/16`, Grok `-r 4/16`, Kakadu `-rate 4/1` — each paired with the reference
  decoder's own decoded raster; the test recomputes z2000-vs-reference
  agreement on every run (max byte diff <= 3, PSNR >= 50 dB when not
  byte-identical, cross-thread determinism; measured max 0-2 / 55 dB-exact).
  Remaining +1-3 in this row is encoder-side: shrinking the newly pinned PCRD
  PSNR deficit at matched byte ladders, then global/interoperable multi-tile
  rate targets.
- **ISO clause:** E (quantization), G (9/7), J.14 (rate-distortion).
- **State:** ICT/9-7 encode/decode locally; **foreign OpenJPEG 9/7 lossy now
  decodes byte-identically across `-r 1..8` / `-q`** (embedded-fixture
  regression gate). The heavy-truncation OpenJPEG 2.5.4 `-I -r 10` corner also
  decodes through the strict ISO-MQ path and is pinned by an embedded fixture
  with deterministic FNV output plus an explicit reconstruction-error bound.
  Grok 20.3.6 `-I -r 8` also decodes through the JP2 wrapper and strict ISO-MQ
  path with a deterministic hash plus source-error bound. Two broader gaps
  remain:
  - **(a) Truncated-plane midpoint reconstruction — ✅ LANDED (2026-07-10).**
    Root cause of the truncation divergence was the reconstruction rule:
    OpenJPEG embeds the uncertainty midpoint during T1 decode (significance
    at plane p reconstructs 1.5*2^p, refinements re-center the half), while
    z2000 decoded exact floors. T1 decode now carries the in-loop midpoint
    (`refineMagnitude` updates on both bit values; exact at plane 0, so all
    lossless invariants held, 303/303). Reference-relative agreement moved
    from ~34-38 dB / max byte diff 13-20 to **~50-55 dB / max 1-3** across
    the OpenJPEG and Grok `-r 2..24` ladders; the two embedded truncated
    fixtures were re-pinned with tightened bounds (opj `-r 10`: 7.93M vs old
    8.5M; Grok `-r 8`: 2.21M vs old 3M). **The Kakadu ladder is now measured
    (2026-07-11):** kdu `Creversible=no -rate 1..8` on the 2048² noise smoke
    decodes through z2000 within max byte diff 2-3 / 51-55 dB of kdu_expand's
    own output. **The CI fixture gate landed the same day** — see the Impact
    note above; the out-of-process ladders remain the broader diagnostic, the
    embedded matrix is the always-on regression floor.
  - **(b) Foreign 9/7 QCD step tables.** **Progress:** the strict irreversible
    QCD parser and JP2 wrapper now accept signalled scalar-expounded/scalar-
    derived `(exponent, mantissa)` pairs, accept irreversible guard bits 1..7,
    derive `Mb` from the signalled guard bits plus exponents (E-2), and use the
    signalled mantissas for 9/7 dequantization. A synthetic mantissa-rewrite
    regression, scalar-expounded/scalar-derived guard-bit-one roundtrips, and
    real embedded Grok 20.3.6 **and Kakadu 8.4.1 fixtures** pin this path.
    **The Kakadu fixture landed 2026-07-11** (`Creversible=no -rate 3`,
    494 bytes): it signals scalar-expounded QCD with one guard bit and
    Kakadu's own mantissas, LRCP, no PLT, plus `res `/`resc` wrapper boxes —
    deterministic FNV hash, source-error bound, and out-of-process
    kdu_expand agreement max byte diff 1 / 56.4 dB. **The CI
    reference-relative matrix landed the same day** (see Impact note above),
    closing this sub-gap.
- **Encoder quality gate closed:** the PCRD PSNR ladder is pinned on a shared
  256x256 mixed corpus (`tools/pcrd_psnr_ladder.ps1`, mirrored by an in-tree
  byte-accounting/quality regression). Gain-normalized synthesis weights and
  matching reference precincts reduce the OpenJPEG deficit from
  1.78/0.69/1.21/1.78 to 1.60/0.31/0.65/0.15 dB. The exact truncations remain
  cross-thread deterministic; extreme-low-rate tuning is now optional.

### N5. Perf — single-thread MQ column-pipeline (decisive Grok lever) — L · High

- **Impact:** the only remaining lever that beats Grok single-thread (decode t1
  ~1.26× Grok is the floor; parallelism is spent — see `optimization_plan.md`).
- **State:** all three MQ decode passes are at a local optimum for the u16 nbf
  structure; the packed-column path (`-Dpacked-t1-context-flags`) is correct
  but slower. This is a research effort (new context-modeling layout, byte-exact
  gated over many iterations), not a one-shot change; a prior wholesale attempt
  regressed.
- **Test plan:** the byte-equality harness (direct-vs-symbol coder) plus the
  benchmark keep rule from `optimization_plan.md` on every sub-step.

### N6. Arbitrary component layouts (grayscale / >3 components) — L · High

- **Impact:** full "Core syntax" +1, "Lossless encode/decode" +1 each. (+3)
- **State:** owned `GrayImage`, shared RGB/grayscale TIFF parsing and writing,
  BlackIsZero/WhiteIsZero polarity, ICC preservation, and tagged CLI inspection
  are in place. The JP2 boundary now wraps and audits unsigned 8/16-bit
  one-component SIZ/COD/QCD metadata with enumerated grayscale `colr` (17),
  optional restricted ICC, identity grayscale `cdef`, component-bounded
  COC/QCC, and mandatory no-MCT. Packet scaffolds/catalogs/order are checked for
  one or three components, and the public single-tile grayscale encoder emits
  reversible 5/3 ISO-MQ RPCL packets with PLT, optional TLM/SOP/EPH, and `R`
  tile-parts. The CLI normalizes WhiteIsZero and OpenJPEG/Grok decode 8/16-bit
  output pixel-exactly. Strict SIZ/T2 catalogs carry one active assembly and
  `decodeLosslessGray*` reconstructs 8/16-bit output through T1 and inverse 5/3;
  z2000 also decodes OpenJPEG/Grok grayscale output pixel-exactly. The follow-up
  palette vertical emits/parses bounded `pclr`/`cmap`, expands checked indices
  to RGB, and agrees pixel-exactly with OpenJPEG/Grok after normalization.
- **What to add beyond the scorecard:** a checked-in independent palette corpus,
  then general N-component and multi-tile grayscale, mixed-depth/BPCC, alpha,
  and richer palette mappings.

## Current Working Sequence (2026-07-07 docs sync)

The old tier list below is intentionally preserved as implementation history,
but many of its "next" items have since landed. The current high-signal order
for more ISO coverage is:

1. **Malformed corpus / fuzzing gate.** ✅ First gate landed (2026-07-08): the
   test "malformed codestream corruption sweep never panics or reads out of
   bounds" builds a valid archival codestream (SOP+EPH+TLM, two resolutions,
   8x8 blocks) and its JP2 wrapper, then sweeps truncation at every length plus
   single-byte corruption across every parse surface (SIZ/COD/QCD/TLM/SOT/SOD/
   PLT/SOP/EPH/packet-header/tag-tree/T1), asserting bounded handling with no
   panic or OOB under Debug, ReleaseSafe, and ReleaseFast. An out-of-process
   ReleaseSafe sweep (byte-flip, truncation, multi-value over the full 32 KB
   smoke JP2) also found zero crashes. Scorecard: full interop/conformance row
   4→5 (66→67). Broadened (2026-07-08) to six profiles in one test —
   single-tile archival RCT/5-3, multi-tile RCT/5-3 (per-tile SOT/PLT walk),
   irreversible ICT/9-7 (QCD step-size parse + float inverse DWT/ICT),
   terminate-all (per-pass terminated-segment T1 decoder), BYPASS+TERMALL
   (mixed raw/MQ per-pass segments), multi-tile TERMALL, and multi-tile
   BYPASS+TERMALL (per-tile packet walks plus raw/MQ terminated segment
   lengths) —
   all green in Debug/ReleaseSafe/ReleaseFast; out-of-process ReleaseSafe
   sweeps of the multi-tile and 9/7 smoke JP2s also found zero crashes.
   Remaining: treating jpylyzer/valid2000 findings as diagnostics and adding
   broader external-corpus fuzz fixtures.
2. **Styled T1/T2 corruption matrix.** ✅ First slice landed: the test
   "terminated styled T1 streams fail closed on corruption" runs, for each of
   TERMALL / RESET+TERMALL / ERTERM / BYPASS+TERMALL, a clean roundtrip plus three corruptions —
   a flipped per-pass PLT length byte → deterministic `InvalidCodestream`
   (segment-span accounting), a truncated final tile-part → `TruncatedData`,
   and a payload byte-flip walk requiring at least one bounded rejection with
   no panic/OOB (green in Debug and ReleaseFast). The T2 unit gate also rejects
   over-capacity terminated packet-header segment counts before segment lengths
   are read. Multi-tile TERMALL and BYPASS+TERMALL have strict roundtrip and
   malformed-input coverage; the terminated multi-tile matrix also rejects a
   damaged second-tile PLT length. Remaining: broader external corpus and
   Kakadu coverage.
3. **Multi-tile v2.** Progression, untargeted-layer, resilience, and global
   cross-tile PCRD rate breadth is now landed. Continue with broader
   rate-targeted matrix coverage, non-empty PLT-less multi-part decode,
   broader progression/division combinations, and then tile-level scheduling.
4. **Lossy breadth.** ✅ COMPLETE. ICT/9-7 (scalar-expounded and scalar-derived QCD) is
   public single-tile and reference-grid-aware multi-tile, including
   odd-origin tiles and rate-targeted 9/7
   multi-tile with gain-normalized 9/7-weighted global cross-tile PCRD. The
   profile-matched ladder averages 0.68 dB behind OpenJPEG; further work is
   quality tuning, not missing payload behavior.
5. **T1 style policy.** ✅ COMPLETE (2026-07-12): all 64 combinations of the
   six Part 1 style bits have implemented payload models with roundtrip
   tests and three-decoder interop (BYPASS+RESET/ERTERM landed last, with
   predictable raw-segment termination). The single-tile style matrix is
   closed; only the legacy MQ backend keeps its own fail-closed gates by
   design. Future T1 work is performance (N5), not coverage.

## Status 2026-07-07 (ERTERM OpenJPEG/Grok interop) — PASSED

`tools/interop_erterm.ps1` now provides a repeatable Windows smoke for the
TERMALL-scoped predictable-termination path. On
`C:\temp\tools\images\0002.tif` and `0004.tif`, z2000 produced no-sidecar
single-tile RPCL/RCT/5-3 JP2 files with `--terminate-all
--predictable-termination`; OpenJPEG 2.5.4, Grok 20.3.6, and Kakadu 8.4.1 all
decoded those files pixel-identically to the source TIFFs. Output sizes were
24,278,954 bytes (`0002`) and 20,108,619 bytes (`0004`).

The z2000 block-parallel strict decoder now routes TERMALL/ERTERM blocks
through the terminated-segment T1 path instead of the continuous MQ path. With
that fix, the same files also decode pixel-identically through z2000 strict
decode at 16 threads. This moves the scorecard to 90/66. Standalone ERTERM
remains fail-closed.

## Status 2026-07-07 (PLT-less foreign decode matrix) — PASSED

Real PLT-less files from independent encoders were generated on the Windows
benchmark box from `C:\temp\tools\images\0004.tif` and decoded through z2000's
strict path. A marker-aware JP2/codestream parser confirmed `PLT=0`, `TLM=0`,
`SOP=0`, `EPH=0`, one `SOT`, and one `SOD` in every file. z2000's decoded TIFF
matched both the source TIFF and the reference decoder output byte-for-byte:

- OpenJPEG 2.5.4 default lossless LRCP/no-precinct JP2.
- OpenJPEG 2.5.4 multi-layer `-r 20,10,1` lossless-final JP2.
- Grok 20.3.6 default lossless JP2.
- Grok 20.3.6 multi-layer `-r 20,10,1` lossless-final JP2.
- Kakadu 8.4.1 default-style reversible LRCP/no-PLT JP2.

This closes the previously open PLT-less OpenJPEG/Grok/Kakadu lossless decode gate for
the current single-tile profile and raises the full-codec lossless decode row
from 8 to 10, moving the full scorecard estimate from 63 to 65. Remaining
PLT-less breadth is now about multi-tile, more marker combinations, arbitrary
component layouts, and lossy/error-bound coverage rather than the default
foreign lossless path.

## Status 2026-07-07 (evening) — Kakadu installed: leg PASSED + new gap found

Kakadu 8.4.1 demo apps are now on the Windows/Ryzen benchmark box (see
`optimization_plan.md` Baseline #2 for the performance columns). Interop:

- **Kakadu leg of the interop matrix: PASSED (forward direction).**
  `kdu_expand` decodes the z2000 archival-profile stream (RPCL, R-parts,
  SOP+EPH+TLM+PLT, BYPASS, lossless 5/3, 2048² noise) **pixel-exactly**,
  consuming all 6 tile-parts. This closes the "Kakadu leg remains open"
  item from the earlier interop pass for the encode direction.
- **Foreign reversible QCD profiles (kdu → z2000): ✅ LANDED.** Implemented
  exactly as scoped: `validateStrictQcdSegment` now parses the reversible
  per-band epsilon_b list and guard bits (1..7 accepted; low SPqcd bits must
  be zero; Mb bounds 1..31), `TemporaryHeader` carries them, and
  `bandNominalBitplanesForHeader` derives each band's `Mb = G + epsilon_b - 1`
  from the *signalled* values (E-2) in both Mb consumers
  (`initializeStrictAssemblyGeometry`, the band-group `max_zero_bitplanes`).
  The QCD-order → band mapping keys on the signalled NL (`header.levels`),
  not the band-derived level count — empty subbands skipped by the band
  builder would otherwise shift the mapping. The JP2 wrapper follows suit
  (guard 1..7 + bounds-only exponent check for the reversible path) and no
  longer requires PLT in tile-parts (packet spans come from the Stage B
  stream-order header decode; PLT frame validation still runs when PLT is
  present). Irreversible QCD stays pinned to z2000's OpenJPEG-compatible
  step tables.

  **Verified against real Kakadu 8.4.1 files on this machine:** the archival
  RPCL/R-parts/PLT stream *and* the default profile (LRCP, no precincts,
  **no PLT**, 1 guard bit, RCT-widened exponents) both decode
  **pixel-exactly** — the default-profile case exercises foreign Stage B and
  the QCD tolerance together. Local oracle in-tree: the equivalent-Mb QCD
  rewrite (guard 2→1 with exponents+1, and 2→3 with exponents−1) decodes
  byte-exactly, proving Mb follows the signalled values. Bidirectional
  Kakadu interop is now closed for these profiles (forward leg passed
  earlier the same day).

## Status 2026-07-07 (later) — foreign stream decode, Stage A

The reverse direction opened up far more cheaply than scoped: probing real
OpenJPEG/Grok output showed the strict reader already handled everything in
their PLT-carrying streams except COD without precinct bytes. After mapping
Scod bit 0 = 0 to the ISO B.6 "no precinct partition" geometry (maximal 2^15
precinct per resolution) in both the strict reader and the JP2 wrapper,
**z2000 decodes OpenJPEG 2.5.4 and Grok 20.3.6 output pixel-identically to
their own decoders whenever the file carries PLT** — verified for the
default profiles (LRCP, no precincts), RPCL, explicit precincts, 32x32
blocks with 4 levels, multi-layer rate-truncated ladders, and OpenJPEG 9/7
lossy (max-diff 1, same as the z2000-encoded baseline). The earlier
progression work is what made the default-LRCP case possible.

**Stage B — PLT-less foreign streams: ✅ LANDED + foreign interop passed.**
Implemented exactly as scoped: (a) the catalog
reader (`readStrictSodPacketCatalog`) gained a PLT-less branch that decodes
each packet header in stream order to learn its span
(`readStrictPacketHeaderSpan`, an open-ended variant of the audit reader),
fused with cataloging; (b) `StrictStatefulPrecinctGroups` keeps per-precinct
tag-tree/lblock/inclusion states alive across the whole stream (slot layout
mirrors `RpclBlockIndex`), so non-RPCL progressions that revisit precincts
across layers decode correctly; the cataloged entries then reorder to RPCL
for the unchanged downstream assembler, exactly like the PLT path. Metadata
skips the R-division plan validation when any part lacks PLT (the catalog
stage validates the total against the plan). Tile-part boundaries fall on
packet boundaries, so the walk continues seamlessly across R-parts.
At the time this stage landed, multi-tile PLT-less stayed fail-closed; the
2026-07-10 local z2000-generated multi-tile gate later removed that local
limitation, while foreign multi-tile PLT-less interop remains open.

*Local oracle:* strip-PLT surgery on z2000 output (Psot + TLM adjusted) —
RPCL with R tile-parts, **multi-layer LRCP** (the stateful case), PCRL,
BYPASS (multi-segment header lengths), and EPH/no-TLM all decode
byte-exactly without PLT; corrupted PLT-less headers fail bounded. The real
foreign matrix now also passes for OpenJPEG/Grok/Kakadu default lossless
PLT-less output and OpenJPEG/Grok multi-layer lossless-final ladders.

## Status 2026-07-07 — external interop gates PASSED

All staged interop gates were run on the user's Mac against **OpenJPEG 2.5.4**
(`opj_decompress`) and **Grok 20.3.6** (`grk_decompress`), decoding z2000
`tiff-to-jp2` output of a 1024x1024 RGB TIFF pixel-exactly (LOSSLESS OK) and
validated by **jpylyzer** (`isValid=True`) for every case:

- **2.1 `--vertical-causal`** — PASSED (opj + grk lossless).
- **2.2 `--segmentation-symbols`** — PASSED (opj + grk lossless).
- **2.3 `--terminate-all`** — PASSED (opj + grk lossless).
- **3.3 `--mct none`** — PASSED (opj + grk lossless).
- **3.1 multi-tile** — PASSED on a genuine 2x2 grid
  (`--tile 512,512 --levels 2 --precincts "[128,128]"`) and a 3x3 edge-tile
  grid (`--tile 384,384 --levels 1 --precincts "[64,64]" --block 32`); both
  decode losslessly in opj + grk. Note the v1 geometry guard: XTSiz/YTSiz must
  be multiples of 2^levels x the largest precinct, so the default
  levels-5/256-precinct profile rejects `--tile` without explicit
  levels/precincts (fail-closed, by design).

Unblocking fix at that milestone: the JP2 wrapper's COD validation
(`jp2.zig:validateCodSegment`) still allowed only BYPASS and MCT=1, so the
public CLI rejected wired features with `UnsupportedProfile` even though the
codestream layer coded them correctly — the local oracles ran below the JP2
layer and missed it. The wrapper opened the then-supported style bits and MCT
0/1. Since then, RESET+TERMALL (`0x06`) and TERMALL-scoped ERTERM (`0x14`)
were also wired through their implemented segment models; Kakadu is installed
on this Windows/Ryzen box; and the broader scorecard now stands at 90/66.

**Remaining top levers after the later passes:** add a malformed-corpus/fuzzing
gate, expand styled T1/T2 corruption coverage, expand the multi-tile v1 matrix,
and continue T1/T2 performance work without relaxing fail-closed policy for
unsupported style combinations.

## Status since first draft (`ba66799` → `d664306`)

Two Tier-1 items already landed — the fast, low-risk wins are largely spent:

- **✅ 1.1 JP2 XL box + `LBox==0` (to-EOF)** — implemented in `d664306`
  ("Harden JP2 codestream profile validation"). `jp2.zig:nextBox` now takes
  `allow_length_to_eof`, handles `length==0` (last box → EOF), `length==1`
  (8-byte `XLBox` via `readU64Be`, payload at `start+16`), rejects `2..7`, and
  uses checked adds throughout. Scorecard: narrow "JP2 boxes" 7→8, full
  "Containers/metadata" 6→7. **Done.**
- **✅ 1.3 Bounds-checked low-level readers** — `jp2.zig` `readU16Be`/
  `readU32Be` (plus new `readU64Be`) and `tiff.zig` `readU16`/`readU32` now
  return `!uN` with `std.math.add` + length guards, so the parsers stay safe
  under `ReleaseFast` regardless of caller validation. **Done** (audit `dng.zig`
  for the same pattern to fully close it).
- **Historical 3.1 multi-tile staging note — superseded.** At `77b26d1` the
  scaffold had tile-part length handling but public encode/decode still
  fail-closed multi-tile. That is no longer the current state: the v1 aligned
  lossless multi-tile envelope has since landed with strict decode and
  OpenJPEG/Grok interop.

The full-target total moved 40→44 partly from 1.1 and partly from an internal
scorecard reconciliation (the earlier rows summed to 43 against a stated 40).

**Historical update (post-`d664306` working tree):** Tier 1 is fully closed — the
DNG/`tiff_ifd.zig` reader-hardening sliver (1.3) and the ICC fixture matrix
(1.2) both landed. **2.1 (vertical_causal)**, **2.2 (segmentation_symbols)**,
**2.3 `terminate_all`**, **2.3 TERMALL-scoped `reset_context`**, **2.3
TERMALL-scoped `predictable_termination`**, and **3.3 `--mct none`
(reversible)** are all wired end-to-end with local byte-exact oracles. The
resilience bits (2.1/2.2/2.3) need broader external interop before all scores
are claimed; `--mct none` is fully local (coding path unchanged, only the color
transform is skipped). RESET+TERMALL is reference-checked with Kakadu,
OpenJPEG, and Grok on the larger no-sidecar smoke; ERTERM is reference-checked
with z2000 strict decode, OpenJPEG, Grok, and Kakadu. This snapshot is
superseded by later work: scalar-derived QCD, all
progression orders, and multi-tile v1 have since landed. The remaining
unclaimed levers are the current working-sequence items at the top of this
file.

## How to read the priority tags

- **Impact**: scorecard points the item can unlock (narrow + full).
- **Effort**: rough size (S / M / L).
- **Risk**: blast radius on the byte-exact strict-decode/interop gates
  (Low = isolated & fail-closed, High = touches T1/T2/MQ hot path).

The ordering deliberately front-loads Low-risk, already-half-built items so the
scorecard moves without destabilizing the green narrow path.

---

## Tier 1 — Low risk, mostly-built, do first

### 1.1 JP2 reader: XL box + length-to-EOF — ✅ DONE (`d664306`)

Implemented; see "Status since first draft" above. Remaining follow-up folds
into 1.2 (fixtures) and malformed-box diagnostics.

### 1.2 JP2/ICC interop fixture matrix — ✅ DONE

- **Impact:** narrow "JP2 boxes" +1 evidence, "interop" hardening. (+1)
- **Effort:** S · **Risk:** Low (test-only)
- **Roadmap:** "Next Implementation Slice" item 1.
- **Current state:** the four-case matrix is committed. (a) ICC-absent RGB TIFF
  → JP2 stays ICC-absent ("TIFF to JP2 fixture keeps ICC absence explicit"),
  (c) malformed `colr` method 2 payload ≤ 3 → `UnsupportedProfile` ("JP2 reader
  rejects malformed restricted ICC color boxes"), and (d) malformed `ftyp`
  brand → `UnsupportedProfile` ("JP2 reader rejects unsupported file type
  brand") were already present. The one gap — a genuine end-to-end (b) — is now
  closed by "TIFF to JP2 fixture roundtrips embedded ICC profile bytes": it
  writes an RGB TIFF *with* tag 34675, reads it back from disk (proving the
  profile survives TIFF I/O), wraps to JP2, and asserts the bytes land
  verbatim in the `colr` method-2 payload and roundtrip via
  `extractIccProfile`. All fixtures use tiny generated buffers. **Done.**

### 1.3 Harden low-level `readU16/readU32` — ✅ DONE (`jp2.zig`, `tiff.zig`, `tiff_ifd.zig`)

`jp2.zig` (`readU16Be`/`readU32Be`/`readU64Be`) and `tiff.zig`
(`readU16`/`readU32`) return `!uN` with `std.math.add` + length guards. The
DNG sliver is now closed: `formats/tiff_ifd.zig` (the reader backing
`formats/dng.zig`) had the last raw-index `readU16`/`readU32`; both now return
`Error!uN` with the same guard and every call site threads `try`. Added a
truncated-DNG test ("DNG info parser rejects truncated buffers without
out-of-bounds reads") that asserts every strict prefix of a valid DNG fails
gracefully (no OOB) under `Debug` and `ReleaseFast`. **Done.**

---

## Tier 2 — Medium risk, high scorecard leverage

### 2.1 Wire `vertical_causal` (COD style bit 0x08) end-to-end — ✅ DONE + interop passed

**Landed:** both fail-closed gates are removed for `vertical_causal` only.
Encoder gate `codestream.zig:validateCodingPath` no longer rejects it (the
other four resilience bits stay gated); decoder gate
`parseCodeBlockStyleByte` now accepts `0x01 | 0x08`. The style flag was already
plumbed through encode (`encodeCodeBlockSegment*WithStyle`) and strict decode
(`decodeCodeBlock*WithStyle`), and the T1 kernels already form stripe-causal
contexts, so no kernel changes were needed. It stays **opt-in behind
`--vertical-causal`**; the default profile never sets it, so the narrow path is
unaffected (verified: full `zig build test` green in `Debug` + `ReleaseFast`).

**Test plan step 1 (internal byte-exact oracle) — done:** new test "vertical
causal code-block style roundtrips losslessly and changes the payload" encodes
a varied 16×16 image with and without the flag, asserts (a) both reconstruct
byte-exactly via `decodeLosslessTemporary`, (b) the payloads differ, and (c)
the COD code-block-style byte carries `0x08` only when set. The two prior tests
that asserted CAUSAL was fail-closed were updated to reflect the new behavior.

**Test plan step 2 (external interop) — passed for the staged gate:**
OpenJPEG 2.5.4 and Grok 20.3.6 decode the causal-enabled smoke JP2
pixel-losslessly; Kakadu is part of the broader no-sidecar smoke matrix.
The flag stays opt-in/off-by-default.

- **Impact:** narrow "T1/EBCOT" 14→15/16; full "T1 completeness" 5→6/7. (+2–3)
- **Effort:** M · **Risk:** Medium (touches COD write + strict decode, but the
  T1 math already exists)
- **ISO clause:** 15444-1 D.7 (vertically-causal context formation: stripe
  causal — neighbors in the next stripe are treated as insignificant).
- **Current state — favorable (re-verified `d664306`):** the coding kernels
  *already* implement it (`ebcot.zig` uses `style.vertical_causal and ci == 3`
  in ~18 sites; standalone test at `ebcot.zig:1404`), and the flag is already
  plumbed into `codeBlockStyle` (`codestream.zig:7591`). What blocks it is one
  explicit fail-closed gate: `codestream.zig:7536-7543` returns
  `UnsupportedPayload` if any of reset_context / terminate_all /
  **vertical_causal** / predictable_termination / segmentation_symbols is set.
  So the encoder never actually emits causal segments in the public RPCL payload
  and the strict decoder never consumes them.
- **What to add:**
  - Remove `vertical_causal` from the fail-closed gate at
    `codestream.zig:7536-7543` (leave the other four bits gated).
  - Encoder: confirm the segment coder used by the RPCL payload builder honours
    the already-plumbed style flag (`codestream.zig:7591`,
    `CodeBlockStyle.toCodByte`).
  - Decoder: in `codestream.zig` strict block decode, pass the parsed
    `code_block_style.vertical_causal` into the T1 kernel selection (it already
    branches on `ci == 3`).
  - Keep it opt-in behind the existing CLI flag (`--vertical-causal`).
- **Test plan:** (1) internal byte-exact oracle: encode a block with/without
  causal, decode, assert identical reconstruction and *different* payload bytes;
  (2) OpenJPEG/Grok/Kakadu interop on a causal-enabled smoke JP2 — this is the
  gate that turns 75%→100% for the bit. Until interop passes, keep it
  fail-closed in the default profile.
- **Why first among style bits:** the coding math is done and tested, so this is
  the lowest-risk way to convert an internal capability into a scored feature.

### 2.2 Segmentation symbols (COD style bit 0x20) — ✅ DONE + interop passed

- **Impact:** full "T1 completeness" +1. (+1)
- **Effort:** M · **Risk:** Medium
- **ISO clause:** 15444-1 D.5 (a `0xA` segmentation symbol coded with the
  UNIFORM context at the end of each bit-plane's cleanup pass; decoder checks it
  for error resilience).
- **Landed:** the segment coder already emitted/validated the four
  UNIFORM-context bits (`emitSegmentationSymbols` / `writeSegmentationSymbols` /
  `readSegmentationSymbols`, all keyed on the UNIFORM context, `ebcot.zig`) and
  an ebcot-level roundtrip test existed ("EBCOT ISO MQ coefficient decode
  honors vertical causal and segmentation symbols"). The remaining blockers were
  the two fail-closed gates, now removed for `segmentation_symbols` (encoder
  `validateCodingPath`; decoder `parseCodeBlockStyleByte` accepts `0x20`). It
  stays **opt-in behind `--segmentation-symbols`**, default off, so the narrow
  path is unaffected (full `zig build test` green in `Debug` + `ReleaseFast`).
- **Tests added:** "segmentation symbols code-block style roundtrips losslessly
  and changes the payload" (codestream-level: lossless reconstruction, payload
  differs from plain, COD byte carries `0x20`) and "corrupted segmentation
  symbol is caught as a bounded decode error" (flips every payload byte; each
  attempt terminates with a bounded error or safe wrong-decode — never a panic —
  and at least one corruption is actively rejected, proving the symbol is
  validated). The two tests that asserted SEGMARK was fail-closed were updated.
- **Interop gate:** OpenJPEG 2.5.4 and Grok 20.3.6 decode the
  segmentation-symbol smoke losslessly; the flag stays opt-in/off-by-default.

### 2.3 `terminate_all` (0x04), RESET (0x02), and `predictable_termination` (0x10) — ✅ TERMALL-scoped

- **Impact:** full "T1 completeness" +1–2. (+1–2)
- **Effort:** M–L · **Risk:** Medium–High (termination changes byte layout of
  every pass; predictable termination is currently the sole
  `hasUnsupportedPayloadMode`)
- **ISO clause:** D.4.5 (termination on each coding pass) and the predictable
  (error-resilient) MQ termination annex.

**terminate_all landed and has interop coverage.** This was more than a
gate flip: the pre-existing `encodeBlockSymbolsSegmentTerminated` used the
*internal* arithmetic coder (`mq.zig`), which is byte-incompatible with the ISO
MQ coder (`mq_iso.zig`) the public codestream requires — fine as an internal
oracle, wrong for a real stream. What was added:

  - **Encoder:** new `encodeBlockSymbolsSegmentIsoMqTerminated` /
    `encodeCodeBlockSegmentIsoMqTerminatedWithStyle` (`ebcot.zig`) — an ISO MQ
    per-pass terminated encoder modelled on the BYPASS one: `finish()` flushes
    each pass into its own codeword segment, `resetStream()` restarts the coder
    register while the adaptive contexts persist. Emits a per-pass `SegmentSpan`
    table so the packet writer records one length per pass. `buildRpclShadowBlock`
    routes `iso_mq` + terminate_all here.
  - **Packet header (`t2.zig`):** threaded `terminate_all` through
    `readCodeBlockPacketHeader` / `readPrecinctPacketHeaderBody` /
    `readPrecinctPacketHeader` / `readPrecinctLayerPacket` /
    `PrecinctPacketReaderState`; for terminate_all each pass is one segment
    (mirrors the BYPASS `bypassSegmentPassCounts` branch). The single-segment
    edge case stays byte-compatible with the existing `write`/`readSegments`
    path (BYPASS already relies on this).
  - **Decoder:** new inferred `decodeCodeBlockPayloadTerminatedIsoMqScratchWithStyleProfiledBorrowed`
    (`ebcot.zig`), structurally the BYPASS decoder with all-MQ, one-pass-per
    segment (`reinitStream` per segment, contexts carried). Wired into the
    strict block-catalog decode (`reconstructStrictComponentCoefficientsFromBlockCatalog`).
  - **Gates:** removed from `validateCodingPath` / accepted (`0x04`) in
    `parseCodeBlockStyleByte`; kept fail-closed for the legacy backend and for
    `layers != 1` (multi-layer per-pass segmentation not yet wired).

- **Tests added:** "terminate-all code-block style roundtrips losslessly and is
  deterministic" (lossless reconstruction, payload differs from plain, COD byte
  carries `0x04`, re-encode is byte-identical) plus fail-closed cases
  `TERMALL+legacy` and `TERMALL+layers`. Full `zig build test` green in `Debug`
  + `ReleaseFast` (248/248).
- **Interop gate:** OpenJPEG/Grok lossless interop passed for TERMALL; Kakadu
  has also accepted the current no-sidecar style smoke set. It stays opt-in
  behind `--terminate-all`, default off.

**`reset_context` (0x02) — wired for the TERMALL path.** Public encode accepts
`--reset-context` only together with `--terminate-all`, where every coding pass
has an explicit T2 segment length and MQ byte boundary. The ISO-MQ encoder and
strict decoder reset JPEG2000 MQ context states between pass-terminated
segments. Standalone RESET, multi-layer TERMALL, and multi-tile style
combinations remain fail-closed. BYPASS+TERMALL has since moved to a local
strict path and still needs external decoder interop. A larger no-sidecar
`0002.tif` smoke roundtrips pixel-exactly through z2000 strict decode, Kakadu,
OpenJPEG, and Grok.

**`predictable_termination` (0x10) — wired for the TERMALL path.** `mq_iso`
now has an OpenJPEG/Grok-style `finishErterm` path that treats the final
`byteout` as guard/advance state rather than payload, including the case where
the current byte is a trailing non-payload `0xff`. Short MQ ER-TERM streams,
larger EBCOT blocks, and a 257x383 debug-sidecar codestream roundtrip locally.
The public profile accepts ERTERM only together with `terminate_all` and the
ISO MQ backend (`--terminate-all --predictable-termination`); standalone
ERTERM remains fail-closed because the encoder has no non-terminated ER-TERM
segment model. z2000 strict decode, OpenJPEG, Grok, and Kakadu reconstruct the
larger no-sidecar `C:\temp\tools\images\0002.tif` and `0004.tif` smokes
pixel-exactly. The block-parallel strict decode regression is covered by the
predictable-termination unit test.

---

## Tier 3 — Larger structural work (unlocks the biggest full-codec gaps)

### 3.1 Multi-tile encode/decode — ✅ LANDED (v1 envelope; OpenJPEG/Grok interop passed)

**All four stages of `docs/multi_tile_plan.md` are implemented.** Multi-tile
codestreams encode and decode byte-exactly through the public path (2×2 and
3×3 edge-tile grid oracles, real codestream bytes), the CLI roundtrips a
genuine 4-tile JP2 to a byte-identical TIFF, `jp2 stats`/packet audit
aggregate per tile, and the JP2 wrapper validates the multi-tile profile.
current bounded envelope: lossless RCT/5-3, untargeted quality layers across all
five progression orders, one tile-part per tile (row-major), plain or
TERMALL code-block style, ISO B.6/B.7-aligned geometry (enforced fail-closed on both
encode and decode). The full-target scorecard points
(+4–5) stay **staged, not claimed**, until OpenJPEG/Grok/Kakadu decode a
genuinely multi-tile z2000 file (verification protocol). Original scoping
notes follow.

- **Impact:** full "lossless encode" 7→9, "lossless decode" 4→6,
  "core codestream syntax" +1. (+4–5, the single biggest full-target lever)
- **Effort:** L · **Risk:** High
- **ISO clause:** B.3–B.6 (tile grid, `SOT`/`SOD` per tile, tile-component
  geometry).
- **Current state (re-scoped post-`f61f199`, superseding the `d664306` note):**
  the `77b26d1` scaffold is *much* further along than previously recorded —
  `tile_pipeline.zig` already does per-tile RCT/DWT/T1, per-tile RPCL packet
  streams, parallel grid encode with a byte-exact artifact-level
  reconstruction test (3×3 edge-tile grid), and full tile-part assembly
  (SOT/SOD layout, TLM, PLT, codestream-fragment build + parse). `appendSiz`
  already writes real XTSiz/YTSiz and the CLI has `--tile W,H`. What is
  genuinely missing: (a) the public encode branch wiring the fragment into
  `encodeLosslessWithOptions`; (b) an **artifact-free per-tile decode** — the
  fragment "readback" validates against encode artifacts, and the real strict
  T2+T1 reader is per-image/single-tile; (c) opening four gates
  (`codestream.zig:7533`, `:1781`, `:4860`, and `jp2.zig:378`). Scoping also
  found a conformance trap: per-tile DWT level *clamping* on tiny tiles vs.
  the global COD `NL` — v1 fails closed when any tile would clamp.
- **Plan:** four staged PRs (A encode integration → B SOT walk / per-tile
  spans → C per-tile strict decode refactor, the big one → D hardening +
  docs), v1 constraints (layers==1, RCT 5/3 only, one part per tile,
  row-major, no rates/style-bits), single-tile byte-identical at every stage.
  Full details, seams, risks and test plans: **`docs/multi_tile_plan.md`**.
- **Test plan (summary):** public encode→decode byte-exact roundtrip on 2×2 and
  3×3 edge-tile grids; `tile == image` byte-identical to the current path;
  malformed SOT/TLM matrix; cross-thread determinism; OpenJPEG/Grok/Kakadu
  decode of a genuinely multi-tile file and the Phase-4 memory benchmark
  remain the external gates before the score is raised.

### 3.2 Additional progression orders — ✅ ALL FIVE DONE (interop passed)

**PCRL + CPRL landed (2026-07-07), completing the Part 1 progression matrix.**
The position-major orders sort packets by the precinct's reference-grid
upper-left corner (`(px * pw_r, py * ph_r) << (levels - r)`), PCRL as
(y, x, c, r, l) and CPRL as (c, y, x, r, l) — implemented as
`packet_plan.positionOrderedPackets`, a sorted sequence builder that now
backs every non-RPCL order on both the encoder reorder and the strict
decoder slot walk (`buildStreamPacketSequence`). PCRL/CPRL always emit one
tile-part. Interop: OpenJPEG 2.5.4 + Grok 20.3.6 lossless at 1 and 4 layers
with default precincts and with dense `[64,64]`-precinct/32-block
configurations; jpylyzer valid with the signalled `<order>`. Scorecard:
full "T2 completeness" 7→8 — claimed. Note discovered in passing: the
single-tile encoder does not fail-close the B.7 precinct≥block constraint
(pre-existing, order-independent — `--precincts "[64,64]"` with the default
64px block emits a stream that no decoder accepts, including RPCL).

**RLCP landed (2026-07-07), same day as LRCP,** using the shared permutation
machinery: `packet_plan.RlcpIterator` plugs into the progression-aware
`StreamPacketIterator` that now drives both the encoder stream reorder and
the strict decoder slot walk. Resolution stays outermost, so R tile-part
divisions remain valid for every layer count (unlike multi-layer LRCP).
Interop: OpenJPEG 2.5.4 + Grok 20.3.6 lossless at 1, 4, and 4+BYPASS layers;
jpylyzer valid with `<order>RLCP</order>`. Scorecard: full "T2 completeness"
6→7 — claimed. PCRL/CPRL are position-major and need the precinct-geometry
cache before the same approach applies.

**LRCP landed (2026-07-07) with the interop gate already passed.** Key insight
that kept the change small: packet bodies do not depend on the progression
order — T2 coder state is per-precinct and each precinct's layers stay in
increasing order in both RPCL and LRCP — so an LRCP stream is a
byte-preserving permutation of the RPCL packets. Implementation:
`packet_plan.LrcpIterator` + `rpclSequenceForPacket` (identity↔slot mapping);
the encoder reorders the RPCL-built stream (`reorderPacketStreamRpclToLrcp`);
the strict decoder walks slots with the progression's iterator and permutes
the catalog entries back to RPCL grouping (`reorderStrictEntriesToRpcl`) so
the downstream audit/assembly chain is untouched. Multi-layer LRCP encodes a
single tile-part (per-resolution R-divisions are impossible when layer is
outermost); single-layer LRCP keeps R-divisions. Tests: iterator bijection
oracle, lossless roundtrip at 1 and 3 layers with genuinely permuted streams, COD
byte checks, fail-closed matrix updates. Interop: OpenJPEG 2.5.4 + Grok
20.3.6 decode 1024x1024 LRCP output pixel-losslessly at 1, 4, and 4+BYPASS
layers; jpylyzer valid with `<order>LRCP</order>`. Scorecard: full
"T2 completeness" 5→6, "core codestream syntax" +1 — claimed.

Historical note: the original staged order was LRCP first, then RLCP, then
PCRL/CPRL. That plan has completed for the documented single-tile profiles;
future work is about broadening progression/tile-part/profile combinations,
not adding the base iterators.

- **Impact:** full "T2 completeness" 5→6/7, "core codestream syntax" +1. (+2)
- **Effort:** M–L · **Risk:** Medium (new packet iterators; RPCL discipline is
  the template)
- **ISO clause:** B.12 (progression orders) + Figure B.11–B.15 iteration order.
- **Current state:** only RPCL is wired (`codestream.zig:1794`, `7524` reject
  anything else). The RPCL path already tracks layer bounds, precinct coords,
  tag-tree known-state, and whole-packet rollback — the reusable scaffolding
  roadmap Phase 3 calls for.
- **What to add:** an LRCP packet-sequence iterator mirroring the RPCL one, plus
  matching writer/reader/tests; then PCRL, then CPRL. Cache the progression
  geometry (roadmap "durable packet/progression cache") before adding the third.
- **Test plan:** per-order writer↔reader packet-length/slice agreement;
  corrupted-header bounded-error tests; interop for at least LRCP.

### 3.3 `--mct none` ✅ DONE (reversible) + `--qstyle scalar-derived` ✅ DONE (interop passed)

**`--qstyle scalar-derived` landed (2026-07-07) with the interop gate
passed.** QCD signals one (epsilon, mantissa) for the NL LL band; both sides
derive the other subbands via E-5 (`derivedBandStepSize`). The subtle bug the
interop run caught immediately: Mb (E-2) must derive from the *signalled*
epsilon table, not the expounded norm table — `bandNominalBitplanesForTransform`
now takes the quantization style, otherwise the zero-bitplane interpretation
shifts and external decoders misreconstruct (max-diff 41 before the fix).
After the fix OpenJPEG 2.5.4 agrees with z2000's decode at max-diff 1
(identical to the expounded baseline agreement); Grok shows its usual
max-diff 2–3 reconstruction bias against both z2000 and OpenJPEG. jpylyzer:
valid, `<qStyle>scalar derived</qStyle>`. Reversible + derived stays
fail-closed. Scorecard: full "lossy" 4→5 — claimed. Original notes follow.

- **Impact:** full "lossy" +1, "core syntax" +1. (+2)
- **Effort:** M · **Risk:** Medium
- **ISO clause:** A.3.1 (MCT signalling), A.6.4 / E.1 (scalar-derived
  quantization: derive all subband step sizes from the `NL` LL step).

**`--mct none` landed for the reversible (lossless) path.** No inter-component
decorrelation — each component is coded independently through the 5/3 DWT + T1
and carries only the B.1.1 DC level shift. Changes:

  - **`color.zig`:** new `forwardNoTransform` / `inverseNoTransform` (each of the
    three planes gets the level shift directly; inverse adds it back and clamps
    to `[0, 2^Ssiz − 1]`, reusing the generic `RctPlanes` carrier).
  - **`codestream.zig`:** encode routes `mct == .none` to `forwardNoTransform`;
    the COD MCT byte already wrote `0`. Decode parses the MCT byte into
    `TemporaryHeader.mct` and all three inverse-transform sites switch on it.
  - **Gates:** `validateCodingPath` accepts `mct none` for the reversible path;
    the decode COD reader accepts MCT `0`. `mct none` is fail-closed with the
    debug temporary-payload sidecar (its header does not carry the MCT choice)
    and stays reversible-only (the 9/7 ICT path is untouched).
- **Test added:** "mct none codes components independently and roundtrips
  losslessly" — COD MCT byte is `0` vs `1`, payload differs from RCT, and the
  stream reconstructs byte-exactly. Full `zig build test` green in `Debug` +
  `ReleaseFast` (249/249). Verifiable entirely locally (no interop dependency,
  since the coding path is unchanged — only the color transform is skipped).

Historical note: the original scalar-derived TODO paragraph is
superseded. Scalar-derived QCD is implemented and interop-passed for the narrow
irreversible path; broader lossy decode/error-bound fixtures remain open.

### 3.4 PCRD-style rate allocation — ✅ DONE

**Landed (2026-07-07).** `ebcot.passDistortions` extracts exact per-pass
squared-error reductions from the symbol-based reference coder (each sample's
`sign` symbol marks its significance event, `magnitude_refinement` symbols
mark refinements; midpoint reconstruction error model), weighted per band by
(synthesis norm x step)^2 (new 5/3 norm table for the reversible path).
`rate_alloc.allocatePcrdPasses` builds per-block convex hulls over
(cumulative bytes, cumulative distortion) and bisects a global slope
threshold per layer byte target; `applyPcrdLayerAllocation` rewrites the
catalog layer truncations after the parallel block encode (single-threaded →
thread-count independent, covered by a determinism test). Measured on a
1024x1024 natural-statistics image at rates 100/50/20/8: layer payloads land
on target (old split overshot layer 1 by ~10x), first-layer PSNR 32.2 dB vs
13.8 dB for the old allocator. The newer 256x256 mixed-corpus ladder now pins
the former quality gap explicitly. Gain-normalized synthesis weights now put
z2000 1.60/0.31/0.65/0.15 dB behind profile-matched OpenJPEG for layers 1-4;
full stream reconstruction remains reference-relative (opj/grk/jpylyzer).
Both follow-ups landed the same day: layer targets now charge measured
packet-header overhead (probe assembly + one refinement round; assembled
layer sizes land under the ladder headers-included), and the distortion
extraction parallelizes across blocks with per-worker scratch while staying
byte-identical across thread counts.

- **Impact:** full "lossy" +2, fairer benchmarks. (+2)
- **Effort:** L · **Risk:** Medium (encoder-only, but needs trustworthy T1
  distortion metadata first)
- **ISO reference:** Annex J.14 (post-compression rate-distortion optimization).
- **Current state:** `--rates` is byte-target based (README + `rate_alloc.zig`),
  producing larger/higher-PSNR access files than Grok/OpenJPEG.
- **What to add:** per-pass distortion (squared-error reduction) metadata in the
  T1 catalog, then a slope-threshold (Lagrangian) truncation across blocks.
- **Test plan:** compare output bytes AND decoded PSNR against Grok/OpenJPEG on
  a shared corpus at matched rate ladders; assert deterministic truncation
  across thread counts.

---

## Suggested sequencing

Use the "Current Working Sequence" near the top of this file for active work.
The older tier notes are retained as evidence for how the current score was
earned, not as the next implementation order.

## Verification protocol (unchanged from roadmap)

Every item above must, before its score is raised: pass local `zig build test`
(byte-exact oracle where applicable), stay fail-closed in the default profile
until an independent decoder accepts it, and add at least one malformed-input
test. External validators (jpylyzer/valid2000) remain diagnostic, not
authoritative — reduce any disagreement to a minimal packet/marker case first.

## Scoreboard

- **Current (`2026-07-10`):** narrow **100**, full **80** — matches
  `docs/iso_coverage.md`.
- **Recent claimed movement:** T1/EBCOT grew through BYPASS, TERMALL,
  vertical-causal, segmentation-symbols, TERMALL-scoped RESET, and
  TERMALL-scoped ERTERM, standalone RESET, and the Kakadu style matrix;
  broad-codec score also moved through multi-tile v1, additional progression
  orders, foreign PLT/PLT-less decode, ICT/9-7, scalar-derived/scalar-expounded
  quantization, PCRD-style rate allocation, and uniform COC/QCC overrides.
- **Next score levers:** add more malformed-corpus/fuzzing coverage, expand
  styled T1/T2 corruption fixtures, expand multi-tile/profile fixtures, and
  keep pushing arbitrary external decode breadth.
