# ISO Coverage — Gap Analysis & Prioritized Next Steps

Companion to `docs/iso_coverage.md` and `docs/roadmap.md`. This file turns the
scorecard gaps into concrete, testable work items: for each gap it names the
ISO/IEC 15444-1 clause, the current code location, exactly what is missing, a
test plan, and an estimated score delta. Ordered by *value per unit risk*.

State re-verified at commit `d664306` (scorecard **86/100 narrow, 44/100 full**,
`iso_coverage.md` dated 2026-07-05). First drafted at `ba66799`.

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
- **◐ 3.1 Multi-tile scaffold advanced** — `77b26d1` ("Advance multi-tile RPCL
  scaffold"); `jp2.zig` gained tile-part length handling. Encode/decode still
  fail-close multi-tile (`codestream.zig:1774` `!grid.isSingleTile()`,
  `4817` `sot.tile_index != 0`), so the scored feature is still open — see 3.1.

The full-target total moved 40→44 partly from 1.1 and partly from an internal
scorecard reconciliation (the earlier rows summed to 43 against a stated 40).

**Update (post-`d664306` working tree):** Tier 1 is fully closed — the
DNG/`tiff_ifd.zig` reader-hardening sliver (1.3) and the ICC fixture matrix
(1.2) both landed. **2.1 (vertical_causal)**, **2.2 (segmentation_symbols)**,
**2.3 `terminate_all`**, and **3.3 `--mct none` (reversible)** are all wired
end-to-end with local byte-exact oracles. The resilience bits (2.1/2.2/2.3)
await external interop before their scores are claimed; `--mct none` is fully
local (coding path unchanged, only the color transform is skipped). **2.3's
`predictable_termination` half was attempted and deferred** — it needs a
reference decoder to validate the ER-TERM flush, so a local oracle would give
false confidence (see 2.3). Remaining unclaimed levers: the interop passes;
`--qstyle scalar-derived` (3.3); LRCP progression (3.2); and Tier 3 multi-tile
(3.1, the biggest lever).

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

### 2.1 Wire `vertical_causal` (COD style bit 0x08) end-to-end — ✅ DONE (local oracle); interop gate pending

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

**Test plan step 2 (external interop) — pending:** OpenJPEG/Grok/Kakadu must
accept a causal-enabled smoke JP2 before the scorecard point is claimed. Until
then the bit is proven internally but not counted; the default profile keeps it
off, so this is safe to ship.

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

### 2.2 Segmentation symbols (COD style bit 0x20) — ✅ DONE (local oracle); interop gate pending

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
- **Interop gate — pending:** OpenJPEG `-M` segmentation-symbol interop must
  pass before the scorecard point is claimed; until then it is proven
  internally but not counted, and stays off by default.

### 2.3 `terminate_all` (0x04) ✅ DONE (local oracle) + `predictable_termination` (0x10) — still open

- **Impact:** full "T1 completeness" +1–2. (+1–2)
- **Effort:** M–L · **Risk:** Medium–High (termination changes byte layout of
  every pass; predictable termination is currently the sole
  `hasUnsupportedPayloadMode`)
- **ISO clause:** D.4.5 (termination on each coding pass) and the predictable
  (error-resilient) MQ termination annex.

**terminate_all landed (local oracle; interop pending).** This was more than a
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
- **Interop gate — pending:** OpenJPEG `-M` terminate-all interop; and cross
  thread-count determinism is only checked via same-config re-encode so far.
  Stays opt-in behind `--terminate-all`, default off.

**`predictable_termination` (0x10) — attempted, deferred (needs a reference
decoder).** The ISO MQ terminated-segment machinery makes the wiring easy, but
predictable termination is fundamentally an *interop* feature: its value is that
an external decoder can verify the exact ER-TERM flush bytes for error
detection. A first pass implementing `opj_mqc_erterm_enc` as `mq_iso`'s
`finishErterm` did not even round-trip through our own decoder (the flush is
subtle and byte-exact), and — critically — a self-consistent-but-non-normative
flush would *pass* a local oracle while still failing real interop, i.e. false
confidence about the one thing that matters here. Unlike terminate_all (which
uses the standard MQ flush the narrow path already exercises), this needs
validation against OpenJPEG/Kakadu to be trustworthy. **Deferred until a
reference decoder is available in the loop.** Left fail-closed.

---

## Tier 3 — Larger structural work (unlocks the biggest full-codec gaps)

### 3.1 Multi-tile encode/decode

- **Impact:** full "lossless encode" 7→9, "lossless decode" 4→6,
  "core codestream syntax" +1. (+4–5, the single biggest full-target lever)
- **Effort:** L · **Risk:** High
- **ISO clause:** B.3–B.6 (tile grid, `SOT`/`SOD` per tile, tile-component
  geometry).
- **Current state (re-verified `d664306`):** the RPCL scaffold advanced in
  `77b26d1` and `jp2.zig` now handles tile-part lengths, but multi-tile is still
  *enforced closed* — `codestream.zig` returns `UnsupportedPayload` when
  `!grid.isSingleTile()` (line 1774) and when `sot.tile_index != 0` (line 4817).
  The shared tile-grid geometry helper and edge-tile geometry tests already
  exist (roadmap Phase 4). So the scaffolding is in place; the scored work is
  turning the fail-closed checks into real per-tile encode/decode.
- **What to add (in order):** per-tile image extraction → per-tile DWT
  (reuse `wavelet_int.Workspace`) → per-tile T1 → per-tile packet state and
  `SOT` scheduling → multi-`SOT` decode loop. Keep tile == image as a passing
  special case throughout so the narrow path never regresses.
- **Test plan:** 2×2 tiles on the smoke image, byte-exact vs. single-tile where
  geometry coincides; OpenJPEG/Grok/Kakadu decode of a genuinely multi-tile
  file; memory-usage benchmark (Phase 4 exit criterion).

### 3.2 Additional progression orders (LRCP first)

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

### 3.3 `--mct none` ✅ DONE (reversible) + `--qstyle scalar-derived` — still open

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

**`--qstyle scalar-derived` — still open.** `codestream.zig` still fail-closes
`quantization != .scalar_expounded` on the irreversible path. Needs the
scalar-derived QCD write + E.1 derived inverse-quant read; keep scalar-expounded
as the reference to diff derived step sizes against.

### 3.4 PCRD-style rate allocation

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

## Suggested sequencing (updated for `d664306`)

1. **Tier 1 is done.** 1.1, 1.3 (incl. the `tiff_ifd.zig`/DNG sliver), and 1.2
   (ICC fixture matrix) have all landed.
2. **2.1 (vertical-causal):** the gates are removed and the local byte-exact
   oracle passes. Remaining work is the **external interop gate** — feed a
   causal-enabled smoke JP2 to OpenJPEG/Grok/Kakadu; once one accepts it, claim
   the T1/EBCOT point. It stays opt-in/off-by-default until then.
3. **2.2 (segmentation-symbols):** gates removed; local oracle + bounded-error
   corruption test pass. Remaining work is the OpenJPEG `-M` interop gate.
4. **2.3 (`terminate_all`):** now wired end-to-end with a dedicated ISO MQ
   per-pass terminated encoder + inferred decoder (not just a gate flip). Local
   oracle + determinism pass; remaining work is the OpenJPEG `-M` terminate-all
   interop gate. Its `predictable_termination` half was attempted and **deferred
   pending a reference decoder** (the ER-TERM flush cannot be validated locally).
5. **3.3 `--mct none` (reversible):** landed and fully local — component-
   independent coding, no interop dependency. `--qstyle scalar-derived` is the
   remaining half of 3.3.
6. **Next best local, interop-independent levers:** LRCP progression (3.2) and
   Tier 3 multi-tile (3.1) — both verifiable against the existing RPCL /
   single-tile paths without an external decoder.
7. **Tier 3:** the multi-tile scaffold (3.1) already advanced; converting the
   `isSingleTile`/`tile_index != 0` fail-closed checks into real per-tile
   encode/decode is the highest full-target lever but also the largest. Keep
   `tile == image` a passing special case at every step so the narrow path never
   regresses.

## Verification protocol (unchanged from roadmap)

Every item above must, before its score is raised: pass local `zig build test`
(byte-exact oracle where applicable), stay fail-closed in the default profile
until an independent decoder accepts it, and add at least one malformed-input
test. External validators (jpylyzer/valid2000) remain diagnostic, not
authoritative — reduce any disagreement to a minimal packet/marker case first.

## Scoreboard

- **Baseline now (`d664306`):** narrow **86**, full **44** — already includes
  1.1 (containers +1) and 1.3.
- **Working tree (post-`d664306`):** 1.2 and the 1.3 DNG sliver landed (test-only
  hardening; interop-evidence +1 pending external confirmation). 2.1
  (vertical_causal), 2.2 (segmentation_symbols), and 2.3 (`terminate_all`) all
  have green local oracles — their narrow "T1/EBCOT" +2 and full "T1" +2/+3
  (2.1), full "T1 completeness" +1 (2.2), and full "T1 completeness" +1–2 (2.3
  terminate_all) are **staged, not yet claimed**, gated on the
  OpenJPEG/Grok/Kakadu interop passes. **`--mct none` (3.3, reversible) landed
  and is fully local** — full "core syntax" +1 is claimable now (no interop
  dependency). `predictable_termination` and `--qstyle scalar-derived` remain
  open.
- **If remaining Tier 1–2 land (2.1 / 2.2 / 2.3 interop):** narrow 86 → ~89
  (T1/EBCOT +2, interop-evidence +1), full 44 → ~48+ (T1 +3/+4, core syntax +1
  from `--mct none`, containers +1).
- **If Tier 3 (multi-tile 3.1 + LRCP 3.2) then lands:** full ~47 → ~53, the
  first real jump on the broad-codec axis.
