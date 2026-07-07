# Optimization Plan — Beat Grok, Then Kakadu

Companion to the "Performance" section of `docs/roadmap.md` and the
"Performance Notes" in `README.md`. This file defines the measured baseline,
the benchmark methodology every change must pass, and the prioritized backlog.
The campaign goal, in order: (1) beat Grok at equal thread counts on the
archival profile, (2) beat Kakadu once it is installed on the benchmark
machine.

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

### O4. Horizontal 5/3 DWT SIMD — M effort, ~5% encode, ~3% decode

Encode DWT 67 ms, decode 30 ms; vertical passes are vectorized, horizontal
lifting is scalar (strided-by-2). Deinterleave via `@shuffle` into even/odd
lanes or process row pairs to fill lanes. Cache-block the column passes at
the same time.

### O5. Parallel efficiency at 10 threads — M effort, tN metrics only

z2000 scales 3.6x/4.0x where Grok gets 3.9x/4.6x. Known-not-it: LPT
ordering (tried, slower), scheduler tail (balanced per counters). Next
probes: persistent worker pool across phases (threads currently spawn per
encode/decode call), parallel inverse-DWT within a component (currently
3-way component cap bounds DWT at 30 ms serial-ish), and the serial packet
catalog + TIFF write tail (~10 ms) overlapping with T1 workers.

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

## Milestones

- **M1 — decode t1 beats Grok** (< 360 ms): O1 + O2 + O3 stacked.
- **M2 — encode t1 beats Grok** (< 417 ms): O1 + O3 + O4 + O6.
- **M3 — t10 parity with Grok** (encode < 107 ms, decode < 79 ms): M1/M2
  wins compound with O5.
- **M4 — Kakadu columns**: install Kakadu SDK on the benchmark machine,
  extend `tools/bench_compare.sh` with `kdu_compress`/`kdu_expand` rows
  (`Corder=RPCL Cprecincts=... ORGgen_plt=yes`), re-baseline, then chase.
  Note Kakadu's headline speed on Part 15 (HTJ2K) is out of scope; the
  target is its Part 1 MQ path.

## Progress log

| date | change | encode t1 | encode t10 | decode t1 | decode t10 | verdict |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 2026-07-07 | baseline @ 61a0ebd | 543.5 | 150.6 | 492.5 | 123.4 | — |
