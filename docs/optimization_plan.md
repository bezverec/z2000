# Optimization Plan — Beat Grok, Then Kakadu

Companion to the "Performance" section of `docs/roadmap.md` and the
"Performance Notes" in `README.md`. This file defines the measured baseline,
the benchmark methodology every change must pass, and the prioritized backlog.
The SIMD-specific campaign (remaining scalar loops, lane-width audit, ISA
policy) lives in `docs/simd_plan.md` and inherits this file's keep rule.
The campaign goal, in order: (1) beat Grok at equal thread counts on the
archival profile, (2) beat Kakadu once it is installed on the benchmark
machine.

## Checkpoint #3 (2026-07-13) — Direct PCRD Metadata

The maintained Windows and POSIX harnesses now include an optional 9/7 ICT,
scalar-expounded, two-layer rate-target profile. On the Ryzen 7 5700X,
profiling showed that rate allocation encoded every block twice: direct MQ
produced the payload, then the symbol reference coder repeated all coding
passes solely to collect distortion deltas. Distortion accounting now happens
inside the real direct-MQ significance, refinement, and cleanup passes and is
checked exactly against the symbol oracle.

On the 2048x2048 corpus (warmup 2, 8 runs), lossy encode improved from
2256 to 809 ms t1 (-64.1%) and 367 to 159 ms t16 (-56.6%). The JP2 remained
byte-identical, lossless metrics were unchanged, and all four decoders accepted
the output. z2000 is now only 1.06x behind Grok t1 and 1.07x ahead of Grok t16
for this lossy profile; Kakadu remains 1.82x/2.56x faster. The next high-value
work is decode T1 and the S3 AVX2 lane audit, not another PCRD traversal.

## Baseline #2 (2026-07-07) — Windows/Ryzen, vs Kakadu (M4 opened)

Machine: AMD Ryzen 7 5700X (8C/16T), Windows 11, x86_64. Kakadu **8.4.1**
demo apps installed (`kdu_compress`/`kdu_expand`, outside PATH — see
`KDU_COMPRESS`/`KDU_EXPAND` in `tools/bench_compare.sh`). Grok/OpenJPEG are
not installed on this machine, so this box benches the Kakadu column and the
Mac benches the Grok column. Input: 2048x2048 RGB **pure random noise**
(PowerShell-generated — harsher than the Mac's generator; z2000 output
13.568 MB vs Kakadu 13.537 MB, +0.23% — sizes tracked but the 0.1% fairness
gate needs same-generator inputs before cross-machine comparisons).
Profile: archival parity (RPCL, 6 res, 256/128 precincts, 64x64 blocks,
SOP+EPH+TLM, BYPASS, lossless 5/3). Kakadu flags:
`Creversible=yes Clevels=5 Cblk={64,64} Cprecincts={256,256},{256,256},{128,128}
Corder=RPCL Cuse_sop=yes Cuse_eph=yes Cmodes=BYPASS ORGgen_plt=yes
ORGtparts=R ORGgen_tlm=6` (`ORGgen_tlm` needs the tile-part count — 6 for
the R-division profile; Part 1 MQ path only, no HT). hyperfine, warmup 2,
8 runs, `-N`.

| metric | z2000 | Kakadu 8.4.1 | gap |
| --- | ---: | ---: | ---: |
| encode t1 | 1486 ms ± 10 | 771 ms ± 4 | **1.93x** |
| encode t16 | 228 ms ± 21 | 100 ms ± 6 | **2.29x** |
| decode t1 | 1622 ms ± 15 | 854 ms ± 6 | **1.90x** |
| decode t16 | 214 ms ± 1 | 104 ms ± 6 | **2.05x** |

Scaling on 16 threads: z2000 6.5x encode / 7.6x decode; Kakadu 7.7x / 8.2x.
`--timings` decode split on this input: block payload 95.4% (MQ cleanup/RLC
489 ms, MQ significance 446 ms, RAW refinement 288 ms, MQ refinement
187 ms, RAW significance 158 ms).

**Interop found while baselining:** `kdu_expand` decodes the z2000 archival
stream **pixel-exactly** (the previously open Kakadu leg of the interop
matrix — see `next_steps.md`). The reverse direction fails on Kakadu's
reversible QCD profile (guard bits = 1, non-z2000 exponents) — a scoped
foreign-QCD work item, recorded in `next_steps.md`.

The Kakadu gap (~2x) is larger than the Grok gap (~1.3–1.4x): Kakadu's
Part 1 MQ path is the harder target, consistent with the plan's ordering
(beat Grok first, then chase Kakadu). All backlog items and the keep rule
apply unchanged on this machine; primary metrics here are the four rows
above.

## Baseline (2026-07-07)

Machine: Apple Silicon arm64, 10 logical cores, macOS (Darwin 25.5.0).
Input: `bench-rgb-2048.tif` (2048x2048 RGB noise via `tools/make_bench_tiff.py`
— worst-case T1 load). Profile: archival parity (RPCL, 6 resolutions,
256/128 precincts, 64x64 blocks, SOP+EPH+TLM, BYPASS, lossless 5/3).
Versions: z2000 @ `61a0ebd`, Grok 20.3.6, OpenJPEG 2.5.4.
hyperfine, warmup 2, 8 runs.

### Encode

| tool | 1 thread | 10 threads |
| --- | ---: | ---: |
| z2000 | 543.5 ± 15.0 ms | 150.6 ± 4.3 ms |
| Grok | 417.1 ± 0.7 ms | 107.2 ± 7.4 ms |
| OpenJPEG (1t only) | ~417 ms | — |
| **gap to Grok** | **1.30x** | **1.40x** |

### Decode (each decodes its own archival-profile file)

| tool | 1 thread | 10 threads |
| --- | ---: | ---: |
| z2000 | 492.5 ± 3.0 ms | 123.4 ± 3.6 ms |
| Grok | 360.0 ± 1.7 ms | 78.7 ± 1.9 ms |
| OpenJPEG (1t only) | ~443 ms | — |
| **gap to Grok** | **1.37x** | **1.57x** |

Output sizes are within 0.02% of each other (6.636 vs 6.635 MB), so the
comparison is compression-neutral. Kakadu is **not installed** on this
machine; the Kakadu columns get added the moment `kdu_compress`/`kdu_expand`
are available (`brew` does not ship it — needs the Kakadu SDK download).

### Where the time goes (1 thread, `--timings`)

Encode 549 ms: **block payload (T1) 477.6 ms = 85.4%**, DWT 5/3 67.0 ms =
12.0%, RCT 4.2 ms, everything else < 2%.

Decode 496 ms: **block payload (T1) 450.8 ms = 90.8%**, inverse DWT 30.3 ms =
6.1%, packet catalog 5.1 ms = 1.0%, inverse MCT 3.0 ms.

Decode T1 pass split (CPU-sum, ns/symbol in parentheses):

| pass | time | symbols | ns/sym |
| --- | ---: | ---: | ---: |
| MQ significance | 146.8 ms | 19.80 M | 7.4 |
| MQ refinement | 113.0 ms | 21.09 M | 5.4 |
| MQ cleanup/RLC | 129.7 ms | 14.96 M | 8.7 |
| RAW significance | 18.5 ms | 1.55 M | 11.9 |
| RAW refinement | 28.9 ms | 19.29 M | 1.5 |

The branch counters (fast/lps/renorm-mps/shifts/byte-in) are printed by
`--timings` and give a per-change diff of *why* a pass got faster.

### Gap math

To beat Grok 1-thread we need **encode −24%** (543.5 → <417) and **decode
−27%** (492.5 → <360). With T1 at 85–91% of wall time, that means the T1
kernels must lose ~28–30% — no single micro-optimization does that; this is
a campaign of stacked 3–10% wins, each gated by the benchmark. The
10-thread gap is larger (1.40x/1.57x) because z2000 scales worse (3.6x/4.0x
on 10 cores vs Grok's 3.9x/4.6x), so parallel efficiency is its own lever.

## Methodology — every change passes this gate or is reverted

1. **Benchmark command:** `sh tools/bench_compare.sh` (hyperfine, warmup 2,
   RUNS=8) on the quiesced benchmark machine, plus the focused
   `--timings` phase profile for the touched phase. Primary metrics:
   encode t1, encode t10, decode t1, decode t10 on the 2048 noise input.
   Content-sensitivity check on a natural-statistics image (sinusoid +
   noise, `tools/` generator) before merging anything that exploits
   sparsity (stripe skipping, RLC).
2. **Keep rule:** a change stays only if (a) at least one primary metric
   improves by **≥ 3% of mean** with non-overlapping ±σ intervals, (b) no
   primary metric regresses by more than 1.5%, and (c) the full test suite
   is green in Debug and ReleaseFast, including the byte-exactness
   invariants (direct-vs-symbol coder equality, cross-thread determinism,
   OpenJPEG/Grok lossless interop smoke). Anything else is reverted —
   history (README Performance Notes) shows "obviously good" T1 layout
   changes regressing on this codebase.
3. **One optimization per commit**, with before/after numbers in the commit
   message. The plan tables below get updated as items land or die.
4. **Fairness:** Grok pinned with `-H <threads>`; identical profile flags;
   same input file; sizes checked to stay within 0.1% so we never trade
   compression for speed silently.

## Backlog — ordered by expected win per effort

Grounded in the current profile and in what previous passes already tried
(see README "Performance Notes": the packed OpenJPEG-style T1 context-word
path exists behind `-Dpacked-t1-context-flags` but measured *slower*; the
RLC packed-column cache regressed and was removed; LPT decode scheduling was
slower).

### O1. RAW significance membership scan — S effort, ~3% decode+encode

11.9 ns/symbol against 1.5 ns for RAW refinement says the significance
membership test (who becomes significant this pass) dominates, not the raw
bit I/O. The nbf flag words already encode "has significant neighbor" —
walk stripe columns via the existing word-granular skip masks instead of
per-sample membership recomputation in the BYPASS significance passes.
Target: 18.5 ms → < 8 ms per side.

### O2. MQ cleanup/RLC pass — M effort, ~4–6%

8.7 ns/symbol is the worst MQ pass. The run-length aggregation decision
(`agg = all four rows insignificant`) re-derives neighborhood state that the
nbf words already hold. Narrow, benchmark-gated attempts only (the wholesale
packed-word flip is known-slower): (a) RLC aggregation decision read
directly from the stripe word-mask, (b) fewer flag reloads in the
post-aggregation coding of the run-break position, (c) fused
sign-coding-after-cleanup path reusing the just-computed context.

### O3. MQ significance/refinement per-symbol cost — L effort, 8–15%

The core 260 ms (decode) across the two passes. Candidates, each measured
separately against the branch counters:
- **Branch layout per pass:** `@branchHint(.likely)` on the fast paths the
  counters prove dominant (fast 11.6M vs lps 4.0M on significance);
  restructure so MPS-no-renorm falls through straight-line.
- **Context-row locality:** the cached transition rows exist; check the
  generated code for redundant reloads of the context struct between the
  ZC lookup and the MQ dispatch (keep the row in registers across the
  stripe column).
- **Column pipeline:** decode the four stripe rows of one column with the
  neighbor updates folded into one register word (nbf already gives the
  `3*ci` shift layout scaffold and parity tests) — but *only* as narrow
  subpaths with byte-equality gates, per the failed wholesale attempt.
- **byte-in batching:** 1.4M byte-ins per 20M symbols is already amortized;
  low priority.
- **✅ Index strength-reduction (2026-07-08, kept):** the MQ significance and
  refinement *plain* decode inner loops recomputed `nbfIndex(nbs, x, y)` (and
  `localIndex(width, x, y)` for refinement) per sample down the stripe column,
  while `decodeRefinementPassRaw` already advanced `p += nbs` / `coeff_index +=
  width`. Applying the same hoist (proven by the earlier cleanup branch-layout
  work) to `decodeSignificancePassInferredPlain` and
  `decodeRefinementPassInferredPlain` measured MQ-significance -3.2%
  (432→418 ms) and MQ-refinement -5.5% (182→172 ms), decode t1 total -2.1%
  (1433→1403 ms), σ ≈ 2 ms non-overlapping, on `bench-rgb-2048` (noise, archival
  BYPASS profile). Lossless self-decode + t1==t16 determinism + full test suite
  green in Debug and ReleaseFast; z2000-decoder-only change, so encode bytes and
  external interop are unaffected.
- **✗ Same index hoist on the *encode* emit paths (2026-07-08, reverted):**
  applying the identical strength-reduction to `emitDirectIsoSignificancePassPlain`
  and `emitDirectIsoRefinementPassPlain` (nbf index + plane index) produced
  byte-identical output and all-green tests, but a clean A/B (6 runs each) put
  encode block-payload at 1330 vs 1335 ms — ~0.4%, overlapping intervals, below
  the 3% gate. Encode T1 is dominated by the MQ-*encode* inner cost and the
  block extraction, not the significance/refinement index arithmetic, so the
  hoist that mattered on decode is noise here. Reverted per the keep rule.
- **DWT is no longer a lever (2026-07-08):** re-profiled, inverse DWT is 38 ms
  = 2.7% of decode and the horizontal lifting is already `@Vector`-ized
  (`forward53Line`/`HorizontalPairVector`), so O4 as written is spent. T1 is
  92–95% of both encode and decode; all remaining headroom is in the MQ passes.

### O4. Horizontal 5/3 DWT SIMD — spent (single-thread); ✅ parallel win landed

Single-thread: horizontal lifting is already `@Vector`-ized
(`forward53Line`/`HorizontalPairVector`) and the inverse DWT is 2.7% of a
1-thread decode, so there is no single-thread lever here (see the 2026-07-08
note under O3).

**Multi-thread (2026-07-08, kept):** the `--timings` phase split at t10 told
a different story than the 1-thread profile — the forward DWT was **30% of
encode t10** (45 ms) and the inverse DWT **12.6% of decode t10** (14.7 ms),
because both were capped at 3 component threads (`componentThreadCount` →
min(threads,3)) while the M4 has 10 logical cores. `wavelet_int.forward53Parallel`
/ `inverse53Parallel` keep the sequential per-level cascade but distribute the
three components' column bands (split at `vertical_lanes` boundaries, final
band takes the scalar tail) and row bands across all requested workers, each
with private scratch. Byte-identical to the serial workspace transform (unit
test across 6 dims x 5 worker counts). Measured on `bench-rgb-2048` (M4,
4P+6E): **encode t10 143 -> 121 ms (-15.4%)**, **decode t10 115.2 -> 110.4 ms
(-4.2%)**, both with non-overlapping sigma and reduced variance; encode/decode
t1 unchanged (serial path untouched); t1==t16 determinism, full suite green,
Grok still decodes the output. This closes most of the parallel-scaling gap
the O5 note flagged for the DWT.

### O5. Parallel efficiency at high thread counts — M effort, tN metrics only

z2000 scales 3.6x/4.0x where Grok gets 3.9x/4.6x. Known-not-it: LPT
ordering (tried, slower), scheduler tail (balanced per counters).
**✅ The biggest item — parallel inverse/forward DWT beyond the 3-way
component cap — landed (see O4, 2026-07-08): encode t10 -15.4%, decode t10
-4.2%.** Note the M4 topology (4 performance + 6 efficiency cores):
block-payload scaling flattens past 4 threads because the E-cores are ~half
speed, and the low-thread anomaly (t2 = 1.31x) is the component-parallel
2:1 imbalance at threads <= 3. Remaining probes: route threads <= 3 through
block/DWT-band parallelism too (fixes the t2/t3 imbalance; not a primary
metric), a persistent worker pool across phases (threads still spawn per
phase), and overlapping the serial packet catalog + TIFF write tail (~8 ms at
t10) with T1 workers. **Fundamental limit:** even ideal scaling cannot beat
Grok because the single-thread MQ floor (decode t1 ~1.26x Grok) caps t10 at
~98 ms > Grok's 78.7 ms — the remaining decisive lever is the single-thread
MQ column-pipeline reformulation (O3), not more parallelism.

### O6. Encode-side bitplane extraction — S–M effort, up to ~5% encode

Encode block payload is 477 ms vs decode's 451 ms for the same MQ work;
the ~27 ms delta plus the sig/ref/cleanup encode overhead hides in bitplane
extraction and pass buffering. Profile first (`--timings` breaks down the
encode passes the same way); candidates: SIMD magnitude/bitplane extraction
(partially exists), skipping all-zero bitplanes earlier.

### Parked (previously tried, needs a new angle before retry)

- Wholesale packed T1 context words (`-Dpacked-t1-context-flags`): correct
  but slower; keep for unit-test parity only.
- RLC-only packed-column cleanup cache: regressed, removed.
- LPT-by-payload decode scheduling: slower.
- **All-significant window skip in significance passes (2026-07-07):**
  skipping 64x4 windows whose samples are all already significant looked
  like the obvious complement to the has-significance skip, but measured
  decode t1 +2.9% (492.5 → 506.6 ms). RAW significance improved only 6%
  (18.5 → 17.3 ms — fully-significant 256-sample windows are rare even on
  noise) while the extra per-window check taxed the MQ significance passes,
  which run at the top bitplanes where such windows never occur. A retry
  would need the check to be near-free (e.g., folded into the existing
  range read) or gated to raw passes at deep bitplanes only.
- **O1 per-column neighbor mask in RAW significance (2026-07-07, Windows
  x86_64 directional):** computing a 64-bit "column can have a significant
  neighbor" mask per stripe window (rows ±1 OR'd with their ±1 shifts,
  in-pass significance extending the mask) and skipping zero columns,
  applied to `decodeSignificancePassRaw` and the raw branch of
  `emitDirectIsoSignificancePassPlain`. Bytes identical, tests green, but
  measured decode RAW significance **+2.2%** (153.1 → 156.5 ms avg of 5)
  and decode total +1.7% on the 2048 noise input. Root cause: the raw
  passes run at deep bitplanes where, on noise, significance is dense — the
  mask is essentially all-ones, so the mask build + per-column test is pure
  tax and the membership cost is the per-*sample* candidate check, which
  the mask cannot amortize when no column is skippable. O1's premise
  (membership recomputation dominates) holds, but the win requires either
  sparse content (would fail the noise gate) or folding the membership test
  itself into word-parallel form (process 4-row columns from the nbf words
  directly instead of gating them) — that reformulation belongs to O3's
  column-pipeline item. Reverted.
- **MQ branch hints in `mq_iso.zig` (2026-07-07, Windows x86_64,
  `0004.tif`):** annotating the fast MPS paths as likely and the LPS paths as
  unlikely compiled and passed EBCOT tests, but measured slightly slower on
  the large TIFF gate: encode t16 529.8 → 546.6 ms and decode t16 567.5 →
  581.7 ms. Reverted; future O3 work should use structural fallthrough or
  generated-code inspection instead of generic branch hints.
- **O3 plain significance candidate branch merge (2026-07-07, Windows
  x86_64, `0004.tif`):** merging the `significant/visited` reject and
  `pattern == 0` reject into one boolean expression passed EBCOT/strict tests
  but regressed the full gate: encode t1 3.274 → 3.381 s, encode t16
  506.8 → 555.3 ms, decode t16 512.9 → 532.3 ms. A follow-up that kept only
  the `band_index` hoist still failed the keep rule for encode t16
  (506.8 → 530.3 ms). Reverted both; future O3 work should avoid making the
  candidate reject path less predictable unless generated-code inspection
  shows a real fallthrough win.

## Campaign checkpoint (2026-07-08, post-parallel-DWT)

After the full-core DWT landed, the Mac/M4 t10 profile is:

| phase | encode t10 (~116 ms) | decode t10 (~108 ms) |
| --- | ---: | ---: |
| block payload (T1/MQ) | 88.5 ms (76%) | 85.0 ms (78%) |
| DWT 5/3 | 18.1 ms (16%) | 10.2 ms (9%) |
| RCT / inverse MCT | 4.7 ms | 3.4 ms |
| packet catalog | — | 3.9 ms |
| TIFF read/write | 3.0 ms | 3.9 ms |

**The parallel side is spent.** Block-payload scales ~4.9x on the M4's
4P+6E (≈7 P-equivalent cores → ~70% efficiency, near the practical ceiling);
the DWT is parallel; the remaining serial phases (RCT/MCT ~3–5 ms, catalog
~4 ms, TIFF ~4 ms) are each individually below the 3% t10 gate, so
parallelizing any one of them in isolation would be reverted by the keep
rule. Thread-spawn overhead was estimated and dismissed (~1 ms total across
all phases; a persistent pool would save < 1%).

**The single-thread MQ is at a local optimum for the u16 nbf structure.**
Verified this pass: all three MQ decode passes are index-strength-reduced,
use `Known`-flag/stride helpers, and the packed-flag marking
(`decodeMarkPackedT1Significant`) is `comptime`-gated to nothing when the
packed path is off. The `markDecodedSignificantNbfKnown` reload-elimination
in the plain significance decode was tried and reverted (A/B 462.1 vs
466.3 ms — the compiler already hoists the `nb_flags.items` slice load).

**Why micro-opts have run out and what the decisive lever now is.** MQ
arithmetic decode is inherently sequential — each symbol depends on the
running (a, c) decoder registers, so it cannot be vectorized or reordered;
only the *surrounding* per-symbol work (flag load, context lookup, neighbor
update) is improvable, and those wins are individually small (3–5%) with a
~50% gate-failure rate observed. The one structural single-thread lever left
is the O3 packed-column reformulation (process a stripe column's four rows
from packed flag words), but the incremental neighbor updates between
adjacent columns carry a real data dependency, which is exactly why the
prior wholesale packed-word path (`-Dpacked-t1-context-flags`) measured
*slower*. Making it faster than the current tight u16 loop is a research
effort (new context-modeling layout, careful byte-exact gating over multiple
iterations), not a one-shot gated change.

**Recommendation for the next iteration.** Either (a) commit to the O3
packed-column research as a dedicated multi-step effort with the byte-equality
harness, accepting it may not beat the u16 loop; or (b) accept the current
Grok t10 gap (encode ~1.13x, decode ~1.40x after the DWT win; t1 ~1.29x/1.30x)
as the practical floor for this algorithm/data-structure and redirect effort
to feature/scorecard work in `next_steps.md`. The parallel and micro-opt
levers this plan enumerated are now spent; do not re-attempt the reverted
items above (Known swap, all-significant skip, RCT/MCT-only parallelization,
DWT spawn-gating, generic MQ branch hints) without a new angle.

## Milestones

- **M1 — decode t1 beats Grok** (< 360 ms): O1 + O2 + O3 stacked.
- **M2 — encode t1 beats Grok** (< 417 ms): O1 + O3 + O4 + O6.
- **M3 — t10 parity with Grok** (encode < 107 ms, decode < 79 ms): M1/M2
  wins compound with O5.
- **M4 — Kakadu columns**: ✅ opened 2026-07-07 — Kakadu 8.4.1 demo apps
  installed on the Windows/Ryzen box, `tools/bench_compare.sh` extended with
  optional `kdu_compress`/`kdu_expand` rows (each reference codec is now
  optional; set `KDU_COMPRESS`/`KDU_EXPAND` when outside PATH), and the
  Kakadu baseline measured (see Baseline #2: ~1.9–2.3x across the four
  primary metrics). Note Kakadu's headline speed on Part 15 (HTJ2K) is out
  of scope; the target is its Part 1 MQ path.

## Progress log

| date | change | encode t1 | encode t10 | decode t1 | decode t10 | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 2026-07-07 | baseline @ 61a0ebd | 543.5 | 150.6 | 492.5 | 123.4 | — |

Windows/Ryzen vs Kakadu (Baseline #2; t16 columns):

| date | change | encode t1 | encode t16 | decode t1 | decode t16 | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 2026-07-07 | baseline #2 (Kakadu 771/100/854/104) | 1486 | 228 | 1622 | 214 | — |
| 2026-07-07 | O1 column-mask (RAW sig) | — | — | +1.7% | — | reverted |
| 2026-07-07 | O2 cleanup-run plain 4-row OR (`0004.tif`) | +0.5% | -1.4% | -1.3% | -4.2% | kept |
| 2026-07-07 | O2 decode cleanup known flags/stride (`0004.tif`) | — | — | -7.6% | -3.2% | kept; t16 noisy |
| 2026-07-07 | O2 encode cleanup known flags/stride (`0004.tif`) | -1.5% | -0.7% | -2.1% | -3.4% | kept; decode rechecked |
| 2026-07-07 | cleanup range refactors + full gate (`0004.tif`) | 3274 ms | 507 ms | 3308 ms | 513 ms | kept; lossless interop |
| 2026-07-07 | O3 significance branch merge (`0004.tif`) | +3.3% | +9.6% | +0.3% | +3.8% | reverted |
| 2026-07-08 | O3 MQ sig/ref decode index strength-reduction (`bench-rgb-2048`) | — | — | -2.1% | noisy | kept; MQ-sig -3.2%, MQ-ref -5.5% |
| 2026-07-08 | O3 markDecodedSignificantNbfKnown swap in plain sig decode (Mac M4) | — | — | +0.9% | — | reverted; reload already hoisted, A/B 462.1 vs 466.3 |
| 2026-07-08 | O4/O5 full-core parallel forward+inverse DWT (Mac M4) | 539 | **-15.4%** | 469 | **-4.2%** | kept; t1 unchanged, byte-exact, Grok decodes |
| 2026-07-08 | O5 parallel forward RCT (encode only) (Mac M4) | unchanged | **-3.5%** | — | — | kept; reproducible across 2 A/Bs, variance ±4.5→±1.7, sigma marginally overlaps (base noise); t1 unchanged, byte-exact |
| 2026-07-08 | O5 parallel inverse RCT (decode) (Mac M4) | — | — | — | +1.2% | reverted; 3.4 ms phase too small, spawn+error-check cancels the gain |
| 2026-07-08 | O5 block-level decode for 2-3 threads (t2/t3 imbalance) (Mac M4) | — | — | t2 -19.5%, t3 +7% | unchanged | kept; monotone scaling, t1/t10 unchanged, removes nested-parallel special case |
