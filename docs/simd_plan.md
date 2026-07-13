# SIMD Optimization Plan

Companion to `docs/optimization_plan.md` (which governs the thread-level and
MQ micro-optimization campaign) and `docs/benchmarks.md` (the comparative
ledger). This plan covers one specific lever: **replacing the remaining scalar
inner loops with SIMD vector code where a measured, gated win exists.** It
reuses the established methodology: hyperfine A/B per change, one change per
commit with numbers, and the keep rule below. Nothing lands on vibes.

## Ground rules (inherited keep rule)

A SIMD change is kept only when **all** hold:

1. The touched metric improves by **>= 3% of mean** with non-overlapping
   mean +/- sd intervals (hyperfine, warmup 2, runs >= 8, same host, AC power).
2. No other primary metric regresses by more than 1.5%.
3. The full test suite is green in Debug **and** ReleaseFast.
4. Byte-exactness holds: lossless encodes stay byte-identical to the current
   encoder; lossy (9/7) streams must also stay **bit-identical**, because every
   candidate below only re-arranges IEEE-754 elementwise arithmetic — it never
   reassociates sums or changes precision. A candidate that would require
   reassociation (e.g. horizontal reductions in a different order) must instead
   prove pixel-exact decode and be flagged in the commit message.
5. Reverted attempts are recorded in the progress log with their numbers, same
   as `optimization_plan.md`.

## Where the time actually is (honesty first)

From the 2026-07-08 campaign checkpoint (M4, t10, archival 5/3 profile):

| phase | encode share | decode share | SIMD-able? |
| --- | ---: | ---: | --- |
| T1 block payload (MQ) | ~76% | ~78% | **No** — the MQ coder is serially dependent per symbol; only SWAR-style flag handling around it is research (O3) |
| DWT 5/3 int | ~16% | ~9% | Already `@Vector`-ized (horizontal + vertical) |
| RCT / inverse MCT | ~4% | ~3% | Already `@Vector`-ized |
| packet catalog | — | ~4% | Pointer/branch bound, not data-parallel |
| TIFF read/write | ~3% | ~4% | Partially vectorized; residual scalar interleave |

**Conclusion:** on the archival 5/3 lossless profile, the classic SIMD targets
are already vectorized (`src/simd.zig` picks lanes per ISA; the 5/3 lifting,
RCT, and parts of bitplane/TIFF use `@Vector`). The remaining *large* scalar
loops live on the **irreversible 9/7 lossy path**, which the comparative
benchmark currently does not measure at all. That is where this plan aims
first, plus a lane-width audit of the code that is already vectorized.

## ISA policy

- **Source form:** portable Zig `@Vector` only, sized via `src/simd.zig`.
  No intrinsics, no inline asm. LLVM lowers the same code to NEON on aarch64,
  SSE4/AVX2/AVX-512 on x86-64 (per `-Dcpu`/native features), and RVV on
  riscv64 when the `v` extension is enabled.
- **NEON (M4, 128-bit):** primary gating host. Every candidate is measured
  here first.
- **AVX2 (Windows/Ryzen box):** second gate for kept candidates. The
  benchmark machine is a Ryzen 7 5700X (Zen 3) — **AVX2 only, no AVX-512** —
  so the 8-lane i32 path in `src/simd.zig` is what actually gets measured.
- **AVX-512:** `src/simd.zig` already selects 16 i32 lanes when `avx512f` is
  in the target features, but **no available machine can run it**, so that
  path is compile-tested only (`-Dcpu=x86_64_v4` build). Make no performance
  claims for it; note that 512-bit lowering is not automatically faster
  (shuffle-port pressure and downclocking are real on some cores), so if
  AVX-512 hardware ever joins the bench pool, A/B 8 vs 16 lanes first.
- **RISC-V (RVV):** no hardware available, so **functional gate only, no
  performance claims**. One-time deliverable: cross-compile
  (`-Dtarget=riscv64-linux-musl -Dcpu=baseline_rv64+v`) and run the test suite
  under `qemu-riscv64` to prove the portable vectors are correct there. Revisit
  perf only if real RVV hardware becomes available.
- **No runtime dispatch.** Zig builds are statically targeted; release
  artifacts document their `-Dcpu` baseline (suggested: `x86_64_v3` for the
  generic x86-64 binary, plus native builds for benchmarking). A multi-slice
  fat binary is out of scope.

## Candidates, ranked by expected value per risk

### S0. Prerequisite: add a lossy 9/7 scenario to the benchmark harness — S

`tools/bench_compare.sh` only measures the lossless archival profile, so S1/S2/
S4 would currently be invisible to the gate. Add a second profile pair (encode:
`--transform 9-7 --mct ict --qstyle scalar-expounded --rates ...`; decode of
that stream; opj/grk `-I -r` equivalents) exporting to
`BENCH_RESULTS_DIR/{encode,decode}-lossy.json`. Extend `docs/benchmarks.md`
with the lossy table on the next ledger entry. Without S0, none of the lossy
candidates can be honestly kept.

### S1. 9/7 float lifting re-layout — M, the main event

`src/wavelet.zig` lifts with `F32PairVector = @Vector(2, f32)` over an
*interleaved* even/odd layout: each iteration gathers
`{data[i], data[i+2]}` / `{data[i-1], data[i+1]}` element-by-element. That is
scalar-speed code wearing a 2-lane costume — on NEON it wastes 2 of 4 f32
lanes, on AVX2 6 of 8.

Plan: split the line into separate even/odd scratch halves once per lift chain
(the buffer already exists for `packEvenOdd`), run all four lifting steps and
the K-scaling as contiguous wide vectors (a new `simd.f32_lanes` mirroring
the existing `i32_lanes` policy: 4 NEON / 8 AVX2 / 16 AVX-512
compile-only), then interleave back on the final pack. The lifting
arithmetic per element is unchanged (same operands, same order, same f32
precision), so streams stay bit-identical; assert that with the existing
9/7 fixture hashes.

Gate metrics: lossy encode t1/t10 and lossy decode t1/t10 from S0. Expected:
the DWT share of the lossy profile is larger than 5/3's (float math, six
passes), so a 2-4x lifting speedup should clear the 3% gate; if it does not,
revert and record.

### S2. Vectorize `quantizeBandRegion` / `dequantizeBandRegion` — S

`src/codestream.zig:761` runs scalar f64 per coefficient:
`floor(abs(x)/delta)` + sign restore, and the mirror multiply on decode.
Both are branch-light elementwise maps — ideal `@Vector(N, f64)` candidates
(`@abs`, `@floor`, division, and `@select` all vectorize). Keep f64: identical
IEEE elementwise results, so quantized coefficients are bit-identical by
construction. The zero-shortcut branch in dequantize becomes a vector select.

Gate metrics: same lossy scenario as S1. Risk: low; the loops may be a small
share — if under the 3% gate even combined with S1's measurement run, record
and move on.

### S3. Lane-width audit of existing vector code — S, measurement-only first

Audit pass on the Ryzen box (and M4 where applicable):

- A/B `i32_lanes` 4 (SSE-width) vs 8 (AVX2) on the Ryzen 5700X for the 5/3
  DWT and RCT paths (one-line override in `src/simd.zig`); keep whichever
  measures faster. The AVX-512 16-lane default stays compile-tested only.
- Check `ict_lanes` (`src/color.zig`) and `f32_pair_lanes` widths against the
  same test.
- Confirm LLVM actually emits the expected instructions for the hot loops
  (`zig build-obj -O ReleaseFast -femit-asm` spot checks) — a silent fallback
  to scalar lowering is a bug worth knowing about.

Output: numbers in the progress log; code changes only where the A/B clears
the gate.

### S4. PCRD distortion accumulation — S, encode-only

The per-pass distortion estimation walks coefficients in f64. The sums are
reductions, so a vectorized version reassociates — **not** bit-exactness-safe
by construction. Only attempt if S0's encode-with-rates scenario shows the
phase is >= 5% of encode wall time; gate additionally on byte-identical
output streams (PCRD decisions may not flip). If streams differ, revert
regardless of speed.

### S5. T1 SWAR/packed-column research — L, research-grade (unchanged from O3)

The only SIMD-adjacent idea that touches the 76-78% T1 share: process a
stripe column's four rows from packed flag words (SWAR in u64, or 4-lane
vectors for context formation) while the MQ coder itself stays serial. The
prior wholesale packed-word path (`-Dpacked-t1-context-flags`) measured
*slower*, and `optimization_plan.md` already classifies this as a
multi-iteration research effort with the byte-equality harness — not a
one-shot gated change. Do not start it as part of this plan's routine
execution; it needs its own dedicated campaign decision.

### S6. RISC-V functional gate — S, one-time

As stated in the ISA policy: cross-compile with RVV enabled, run the suite
under qemu, record pass/fail in this file. Zero performance claims. This
protects the portable-`@Vector` invariant (no ISA-conditional code paths that
silently break elsewhere).

## Execution order

1. **S0** (harness) → unlocks measurement.
2. **S1** (9/7 lifting) — the biggest expected win.
3. **S2** (quant/dequant) — same measurement scenario, cheap to try.
4. **S3** (lane audit) — Ryzen session; pairs naturally with the next Kakadu
   benchmark visit.
5. **S6** (RISC-V gate) — any idle slot.
6. **S4** only if S0's numbers justify it; **S5** only as a deliberate
   campaign decision.

## Do-not-do list

- Do not attempt to vectorize MQ symbol decode/encode — the (a, c) register
  dependency makes it impossible; this is documented and measured territory.
- Do not re-attempt the reverted items from `optimization_plan.md` (Known
  swap, all-significant skip, RCT/MCT-only parallelization, DWT spawn-gating,
  generic MQ branch hints) under a SIMD label.
- Do not introduce intrinsics or per-ISA source branches; if portable
  `@Vector` cannot express a candidate, the candidate is out of scope.
- Do not keep any change whose only evidence is a microbenchmark; the gate is
  end-to-end hyperfine on the profiles above.

## Progress log

| date | candidate | host | metric before | metric after | verdict |
| --- | --- | --- | ---: | ---: | --- |
| — | (none yet) | | | | |
