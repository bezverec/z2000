# Multi-Tile Encode/Decode — Scoping & Staged Plan (roadmap item 3.1)

Scoped against `main` at `f61f199` (post `--mct none`). This expands
`next_steps.md` §3.1 into PR-sized increments with the real integration seams
named. Impact: full "lossless encode" 7→9, "lossless decode" 4→6, "core
codestream syntax" +1 — **+4–5 full-target points, the single biggest lever.**

## 1. Verified current state — the scaffold is much further along than "advanced"

The `77b26d1` scaffold (`tile_grid.zig`, 230 lines; `tile_pipeline.zig`, 3031
lines; ~2200 lines of tests) already implements, with passing tests:

| Capability | Where | Evidence |
|---|---|---|
| Tile grid geometry incl. edge tiles, ISO B.3 offsets | `tile_grid.zig` (`Grid`, `Tile.isEdge`, `tileRect`) | "tile grid computes edge tiles…" tests |
| Per-tile RCT + 5/3 DWT (in place, workspace reuse) | `forwardRctTile`, `forward53TileInPlace` | roundtrip tests over edge tiles |
| Per-tile T1 (ISO MQ) block catalog + coverage check | `buildEncodedBlockCatalogIsoMq`, `validateEncodedBlockCatalogCoversTile` | per-tile catalog tests |
| Per-tile RPCL packet stream (tag trees, layers ≥ 1) | `buildTileRpclPacketStream`, `RpclPacketIndex` | "emits standalone RPCL packet stream" |
| Whole-grid encode, serial + parallel, deterministic | `buildTileGridRpclEncodeArtifactsIsoMq[Parallel]` | "parallel … matches serial artifacts" |
| **Byte-exact grid reconstruction (from artifacts)** | `reconstructTileGridRpclEncodeArtifactsIsoMqInto` | "reconstructs tile-grid encode artifacts to RGB image" (3×3 grid, 11×9 image, edge tiles) |
| Tile-part layout, TLM plan, PLT plan, SOT/SOD bytes | `buildTilePartLayout…`, `buildTilePartTlmPlan`, `buildTilePartSequence` | layout/TLM/PLT tests |
| Tile-part codestream fragment build + parse | `buildTilePartCodestreamFragment`, `parseTilePartCodestreamFragment` | fragment tests + T2 readback |

Also already in place on the public path:

- `LosslessOptions.tile_width/tile_height` (default 4096) and CLI `--tile W,H`.
- `appendSiz` (`codestream.zig:5551`) already writes the **real**
  XTSiz/YTSiz from options — the SIZ marker is multi-tile-ready today.

## 2. The actual gaps

### 2.1 Three fail-closed gates

1. **Encode:** `validateTileSize` (`codestream.zig:7533`) rejects
   `!grid.isSingleTile()`.
2. **Decode (SIZ):** `readStrictCodestreamMetadata` rejects
   `!grid.isSingleTile()` (`codestream.zig:1781`).
3. **Decode (SOT):** `sot.tile_index != 0` rejected (`codestream.zig:4860`).
4. **JP2 wrapper:** `jp2.zig:378` rejects `xtsiz < width` — `tiff-to-jp2`
   output would fail its own JP2 validation. Must be relaxed to grid-valid.

### 2.2 The one genuinely new piece: decode-from-bytes per tile

The fragment "T2 readback" (`validateTilePartCodestreamFragmentT2Readback`)
validates **against the encode artifacts** (it needs
`expected_header_lengths` and compares streams). It is *not* an independent
decoder. The strict, artifact-free T2→T1 decoder lives in `codestream.zig`
(`readStrictPacketBlockCatalogWithHeaderProfiled` →
`assembleStrictPacketCatalogHeaders` → block catalog → T1 → DWT⁻¹ → RCT⁻¹) and
is **per-image, single-tile**: all geometry flows from `TemporaryHeader`
(width/height/levels/`packet_plan` via `makePacketPlan`), and the SOT walker
(`readStrictPacketCatalogWithHeader`) assumes tile 0.

**The core decode work is therefore a refactor, not new algorithm code:**
parameterize the existing strict reader by *tile geometry* (tile w/h → per-tile
`makePacketPlan`) and *per-tile packet-byte spans* (from the SOT walk), loop
over tiles, then per-tile DWT⁻¹/RCT⁻¹ (already exist:
`inverse53TileInPlace`, `inverseRctTileInto`) and blit via
`tile_grid.copyRgbTileInto` with a whole-image coverage check.

### 2.3 Conformance trap found while scoping: per-tile DWT level clamping

`forward53TileInPlace` returns the *achieved* level count and small tiles
clamp (`wavelet_int.forward53WithWorkspace` stops when both dims hit 1). But
COD's `NL` is global — a decoder must use the same `NL` for every tile.
`TileRpclEncodeArtifacts` currently stores per-tile `levels`, which would emit
a codestream whose COD lies about edge tiles.

**v1 rule:** encode fails closed unless
`actualDwtLevels(tile_w, tile_h, levels) == levels` for **every** tile
(equivalently: check the smallest edge tile). Practical tiles (≥ 2^NL in each
dimension) never hit this; degenerate-resolution tiles are a v2 concern.

## 3. v1 scope (what multi-tile means in the first shipped slice)

Supported: reversible 5/3 + RCT, one or more untargeted quality layers across
all five progression orders, default/explicit precincts, plain, CAUSAL,
SEGMARK, CAUSAL+SEGMARK, TERMALL, RESET+TERMALL, ERTERM+TERMALL, and
BYPASS+TERMALL code-block styles, one tile-part per tile in row-major order
(`TPsot=0`, `TNsot=1`), TLM on, SOP/EPH as today, PLT per tile-part as the
scaffold builds it.

Fail-closed in multi-tile mode (each lifted later, separately): `--rates`
(byte targets are image-global), `--tile-parts R` (R-divisions compose with
multi-tile later), BYPASS without TERMALL, standalone RESET/ERTERM, BYPASS
combined with RESET/ERTERM, untested resilience combinations, `--mct none`,
9/7/lossy, and tiles that clamp DWT levels (§2.3).
Single-tile behavior stays **byte-identical** — every increment keeps
`tile == image` on the exact current code path.

## 4. Staged plan (each stage = one PR, green tests, narrow path untouched)

### Stage A — Encode integration — ✅ DONE
Landed as implemented (with two deviations from the sketch, both noted below):
`encodeLosslessWithOptionsMeasured` branches on `!grid.isSingleTile()` into
`encodeLosslessMultiTileMeasured`, which routes through
`buildTileGridRpclEncodeArtifactsIsoMqParallel` → tile-part layout / TLM / PLT
plans → `buildTilePartSequence`, and emits SOC/SIZ/COD/QCD + sequence (TLM +
one SOT..SOD part per tile, row-major) + EOC. `validateTileSize` is gone
(grid computed at the entry); `validateMultiTileCodingPath` enforces the §3
envelope and `validateMultiTileGeometry` enforces §2.3 (no per-tile level
clamping) plus the anchoring guard below.

*Deviation 1 — alignment guard:* scoping's per-resolution origin check was
refined: the tile pipeline anchors precinct **and code-block** partitions at
the tile-local origin, so the v1 sufficient condition is "every precinct ≥
the code-block size, and XTSiz/YTSiz are multiples of 2^levels × the largest
precinct" — then every partition boundary aligns at every resolution.
*Deviation 2 — JP2 wrapper:* relaxing `jp2.zig:378` alone was not enough; the
wrapper's profile validator was single-tile throughout. It now understands
multi-tile: SIZ-derived tile count (≤ 256 for the wrapper profile), TLM Stlm
`0x60` (u16 Ttlm + u32 Ptlm) alongside the single-tile `0x50`, and a
`validateMultiTileTilePartSequence` walker (row-major Isot, TPsot=0, TNsot=1,
per-tile SOP restart, TLM cross-check).

*Tests:* "multi-tile encode emits row-major single-part tiles with TLM"
(SIZ/TLM/SOT structure, Psot chaining to EOC, thread-count determinism, JP2
wrap acceptance, and strict decode); "multi-tile terminate-all roundtrips
losslessly" (COD style `0x04`, deterministic encode across worker counts,
strict single-threaded/threaded decode, JP2 wrapper acceptance);
"multi-tile terminate-all fails closed on packet corruption" (second-tile PLT
length mutation, final tile-part truncation, and second-tile SOD payload
byte-flip walk); "multi-tile encode fails closed outside the bounded envelope"
(rates, mct none, sidecar, 9/7,
misaligned tile size);
"multi-tile encode rejects tiles that clamp the global DWT level count" (18×18
with 16×16 tiles). Single-tile output is byte-identical (branch only taken when
multi-tile; full suite green in Debug + ReleaseFast).

### Stage B — Decode: SOT walk + per-tile packet spans — ✅ DONE
`readStrictCodestreamMetadata` accepts multi-tile SIZ (the `isSingleTile`
rejection is gone; the parsed grid is kept) and, for multi-tile grids, runs
`readStrictMultiTileTilePartSpans`: one tile-part per tile, row-major `Isot`,
`TPsot=0`/`TNsot=1`, `Psot` chaining ending exactly at EOC, PLT required,
per-tile packet counts validated against each tile's own packet plan
(`makePacketPlan` on the tile dims), and TLM `Ttlm`/`Ptlm` cross-checked per
tile. The decode side also enforces the same `validateMultiTileGeometry`
envelope as the encoder (level clamping + partition anchoring), so metadata
never accepts a stream Stage C cannot decode. `TemporaryHeader` gained
`tile_width`/`tile_height` (0 = single tile) and multi-tile `packet_count` is
the per-tile sum.

*Error taxonomy:* the TLM cross-check runs before the ordering check — a SOT
contradicting the stream's own TLM index is corruption (`InvalidCodestream`);
a self-consistent stream outside the v1 discipline (reordered tiles, multiple
parts per tile) fails closed as `UnsupportedPayload`; truncation surfaces as
`TruncatedData`. The intact multi-tile stream passes metadata and still fails
closed at the block-catalog stage (Stage C pending) — asserted by test.

*Tests:* "multi-tile decode SOT walk validates the v1 tile-part discipline"
(Isot-vs-TLM contradiction, self-consistent reordering, nonzero TPsot, TNsot
of 2, TLM length mismatch, truncated final tile-part); the full existing
suite covers the single-tile regression (253/253, Debug + ReleaseFast).

### Stage C — Decode: per-tile strict T2+T1 — ✅ DONE
Landed with a lighter refactor than sketched: instead of threading tile
geometry through every strict-reader function, each tile decodes as its own
single-tile image via a **per-tile `TemporaryHeader`** (tile dims + the
tile's own packet plan; precincts reconstructed from the whole-image plan's
per-resolution dims). `decodeStrictMultiTileImageMeasured` loops the Stage B
spans: `readStrictMultiTileTilePartPacketCatalog` (tile-local RPCL iterator
over the PLT lengths, SOP restarting per tile) → the *unchanged*
`assembleStrictPacketCatalogHeaders` → block catalog →
`decodeStrictRpclImageFromBlockCatalogMeasured` (T1 → DWT⁻¹ → MCT⁻¹, all
header-driven) → `tile_grid.copyRgbTileInto`. Tiles decode serially; the
existing per-block threading applies within each tile. Single-tile decode is
untouched (the branch keys on the header's SIZ tile dims).

*Conformance find:* the first roundtrip attempt exposed that 4×4 blocks with
4×4 precincts are **not ISO-legal** — B.7 bounds the effective code-block by
the precinct span in band coordinates (full precinct at r=0, half above), and
the two RPCL index builders disagree on such configs (a block spanning
precincts double-includes → `InvalidCodestream`). `validateMultiTileGeometry`
now enforces the exact B.7 bound (r=0: precinct ≥ block; r>0: precinct/2 ≥
block) on both encode and decode; the fixtures moved to 8×8 precincts with
32-wide tiles.

*Tests:* the payoff oracle — public `encode → decode` byte-exact roundtrip on
2×2 (48×48) and 3×3 (80×80) edge-tile grids through real codestream bytes;
`tile == image` vs 2×1 grid both reconstruct the source; decode determinism
across worker counts; corrupted second-tile payload → bounded error, never a
panic. 256/256 in Debug + ReleaseFast.

### Stage D — Hardening + docs — ✅ DONE

- **Real CLI verification:** `tiff-to-jp2 --tile 32,32 --levels 2 --block 4
  --precincts "[8,8]"` on a 48×48 TIFF produced a genuine 4-tile JP2 and
  `decode-temp-jp2` reconstructed a **byte-identical TIFF** — the first
  end-to-end confirmation through the shipped binary rather than unit tests.
- **`jp2 stats` / packet audit generalized:** the shared multi-tile setup was
  extracted into `StrictMultiTileContext` (grid + reconstructed plan options +
  main-header index + Stage B spans, with a `tileHeader` view helper); the
  decode loop, `auditStrictPacketHeaders`, and `analyzeLosslessTemporary` all
  ride it, so `jp2 stats` now reports aggregated per-tile T2 statistics for
  multi-tile streams instead of failing closed.
- **Docs:** README `--tile` / `--mct none` bullets updated; `next_steps.md`
  §3.1 marked landed-pending-interop.
- **Memory note:** the grid encoder holds *all* tile artifacts in memory
  before tile-part assembly, and the decoder holds one tile's catalogs at a
  time plus the full output image. Fine at v1 scale; streaming tile-part
  assembly (encode) and the Phase-4 peak-memory benchmark are the v2 follow-up.

**Interop gate passed:** OpenJPEG and Grok decode genuine aligned multi-tile
z2000 files losslessly across all five progression orders. The later
resilience expansion is also pixel-exact in both decoders for CAUSAL+SEGMARK,
RESET+TERMALL, ERTERM+TERMALL, and BYPASS+TERMALL. Kakadu remains the breadth
follow-up for this expanded matrix.

### Stage E — Progression, layer, and resilience breadth — ✅ DONE

The tile-local packet stream can now be permuted and read back in LRCP, RLCP,
RPCL, PCRL, or CPRL order. Stateful reader groups preserve tag-tree and length
state when multi-layer LRCP/RLCP revisit a precinct. T1 style metadata now
survives the component-block to T2-layer-block conversion, so the readback
validator uses the exact BYPASS/termination model rather than inferring it
from segment sizes. Focused 2x2 tests cover deterministic threaded encode,
strict single-/multi-thread decode, second-tile PLT corruption, and the
multi-tile BYPASS+TERMALL malformed-input sweep.

## 5. Risks, ranked

1. **Stage C refactor blast radius** — the strict reader is the green narrow
   path. Mitigation: extract-and-delegate (new tile-parameterized functions;
   single-tile calls them with image geometry), never fork the logic; the
   byte-identical single-tile regression test is the tripwire.
2. **Per-tile packet-plan mismatches** (precinct grids anchor to the
   reference grid, ISO B.6) — edge tiles have different precinct/resolution
   geometry than the image. The scaffold's `buildPacketScaffold` already
   computes per-tile plans and its tests cover edge tiles; decode must use the
   same derivation.
3. **§2.3 level clamping** — closed by the v1 fail-close rule.
4. **SOP numbering** — `Nsop` restarts per tile (scaffold already does this);
   the strict reader's sequential-SOP audit must become per-tile.

## 6. Explicit non-goals for v1

Tile-parts-within-tile (R divisions × tiles), per-tile COD/QCD overrides,
`--mct none`, unsupported style combinations, rate-targeted quality layers,
lossy 9/7 tiles,
streaming (bounded-memory) assembly, PPM/PPT. Each is a separate, later
increment on top of the v1 skeleton.
