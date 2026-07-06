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

Supported: reversible 5/3 + RCT, `layers == 1`, default/explicit precincts,
plain code-block style (no bypass/style bits), one tile-part per tile in
row-major order (`TPsot=0`, `TNsot=1`), TLM on, SOP/EPH as today, PLT per
tile-part as the scaffold builds it.

Fail-closed in multi-tile mode (each lifted later, separately): `--rates`
(byte targets are image-global), `layers > 1`, `--tile-parts R` (R-divisions
compose with multi-tile later), bypass + resilience style bits, `--mct none`,
9/7/lossy, tiles that clamp DWT levels (§2.3). Single-tile behavior stays
**byte-identical** — every increment keeps `tile == image` on the exact
current code path.

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
wrap acceptance, and decode still failing closed pending Stages B/C);
"multi-tile encode fails closed outside the v1 envelope" (layers, mct none,
bypass, style bits, sidecar, 9/7, misaligned tile size); "multi-tile encode
rejects tiles that clamp the global DWT level count" (18×18 with 16×16 tiles).
Single-tile output is byte-identical (branch only taken when multi-tile; full
suite green in Debug + ReleaseFast).

### Stage B — Decode: SOT walk + per-tile packet spans (~1 session)
Accept multi-tile SIZ (gate 2) and `Isot != 0` (gate 3) behind the grid
check; v1 SOT discipline: each tile exactly once, row-major, `TPsot=0`,
`TNsot=1`; validate `Psot` chaining and TLM (`Ttlm`/`Ptlm`) against the walk
(scaffold's `validateSinglePartTileAuditOrder` is the template). Output:
per-tile packet-byte spans. *Tests:* malformed-input set — out-of-order
`Isot`, duplicate tile, missing tile, truncated part, TLM mismatch → bounded
errors; single-tile regression.

### Stage C — Decode: per-tile strict T2+T1 (~1–2 sessions, the big one)
Refactor the strict reader chain to take tile geometry (`width`, `height`,
per-tile `makePacketPlan`) instead of reading them from the whole-image
header; loop tiles → per-tile block catalog → T1 → `inverse53TileInPlace` →
`inverseRctTileInto` → `copyRgbTileInto` + full-coverage check. *Tests:* the
payoff oracle — public `encode → decode` byte-exact roundtrip on 2×2 and 3×3
edge-tile grids (mirroring the existing artifact-level test, now through real
codestream bytes); `tile == image` equals the single-tile decode result;
cross-thread determinism; corrupted per-tile packet → bounded error naming
the tile.

### Stage D — Hardening + docs (~½ session)
Memory note (grid encode currently holds *all* tile artifacts before
assembly — fine for v1, streaming assembly is v2 with the Phase-4 memory
benchmark); `jp2 stats`/`tiff-info` surfacing of tile grid; update
`iso_coverage.md`, `next_steps.md`, README `--tile` docs; only then raise the
score per the verification protocol (external OpenJPEG/Grok decode of a
genuinely multi-tile file remains the interop gate before full points).

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
`--mct none`/style-bits/bypass in multi-tile, quality layers > 1, lossy 9/7
tiles, streaming (bounded-memory) assembly, PPM/PPT. Each is a separate,
later increment on top of the v1 skeleton.
