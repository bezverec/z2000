# Optimization Plan

This document contains only the active performance policy and candidate queue.
Detailed checkpoints, rejected experiments, generated-code audits, and the
completed SIMD campaign are preserved in
[`archive/optimization-plan-2026-07-13.md`](archive/optimization-plan-2026-07-13.md)
and [`archive/simd-plan-2026-07-14.md`](archive/simd-plan-2026-07-14.md).
Measured results belong in [`benchmarks.md`](benchmarks.md).

## Goal

Beat Grok and then Kakadu in encode and decode while preserving pixel accuracy,
codestream semantics, deterministic threading, bounded memory use, and strict
malformed-input behavior. Optimize the common codestream path before
producer-specific shortcuts, and report lossless and quality-matched lossy
results separately.

## Keep Rule

Every candidate follows the same cycle:

1. state the profile and expected bottleneck;
2. record the baseline command, commit, CPU, thread count, and output hash;
3. implement one narrow change;
4. run correctness and interop gates;
5. measure enough warm runs with `hyperfine` to separate signal from noise;
6. keep only a repeatable improvement on the target profile without a material
   regression on the other maintained profiles; otherwise revert the candidate
   and record the result in `benchmarks.md`.

Output bytes, pixel hashes, strict status, encode time, and decode time are all
required. Lossless 5/3 and lossy 9/7 are reported separately at t1 and at the
all-thread setting.

## Current Evidence

- The 2026-07-16 Intel Core i5-14500 checkpoint is the active cross-codec
  baseline. On the common z2000 lossless stream, z2000 decoded in
  831.5/135.3 ms at t1/t20 versus Grok 636.8/99.1 ms, OpenJPEG
  680.9/123.9 ms, and Kakadu 619.6/94.5 ms. The 1.31x t1 gap to Grok proves
  that serial decode work remains material; the 1.37x t20 gap also leaves a
  parallel-efficiency problem.
- Lossless encode is no longer the first target. At t20, z2000 encoded in
  135.9 ms, 1.15x faster than Grok and only 3.6% behind OpenJPEG; Kakadu
  remained 1.75x faster. Preserve that result while decode work proceeds.
- The current lossy checkpoint is useful for implementation timing but is not
  a rate-distortion ranking: the four command lines did not produce
  quality-matched files. z2000 and OpenJPEG were closely matched near
  52.58 dB, while the recorded Grok output was larger and materially less
  accurate. Any lossy competitive claim needs a size- or quality-normalized
  sweep first.
- T1/MQ remains the dominant serial cost. Earlier wholesale packed-column/SWAR
  attempts were correct but slower; a retry needs a materially different data
  layout or branch hypothesis.
- High-thread decode scales less efficiently than Kakadu even though the t1
  gap is smaller. Scheduling and pipeline overlap therefore have better
  near-term value than another unbounded SIMD rewrite.
- Persistent parallel forward 9/7 DWT and parallel inverse RCT/ICT were kept.
  The symmetric inverse-DWT pool and cross-component T1 pool were rejected by
  measurement.
- The 5/3 DWT phase is now capped at eight workers to match the 9/7 driver: the
  memory-bound bands stop scaling past the eight physical cores on the x86 host,
  so the uncapped 32-worker setting let lossless inverse DWT regress at t16
  (17.3 ms vs 12.8 ms at t8). Capping restored t16 to t8 and improved lossless
  decode t16 by 7.8% and encode t16 by 6.1% with byte-identical output
  (2026-07-15 record in `benchmarks.md`).
- Both DWT drivers now share the 9/7 driver's persistent barrier pool: the 5/3
  driver stopped re-spawning threads for each of its ten phases per transform.
  Kept for a clean 2.8% lossless encode t16 improvement (inverse DWT stage
  ~27% faster) with no regression on decode or t1 and byte-identical output;
  the decode end-to-end signal was inside host noise on the day. Next DWT idea,
  if the transform ever grows its profile share again: cache-block the
  row+column passes per level so each plane streams once instead of twice.
- Portable `@Vector` kernels have scalar-oracle coverage on x86, ARM, and the
  RISC-V/RVV functional gate. ISA-specific intrinsics remain a last resort.

## Candidate Queue

### P1. Decode Stage Attribution — Next Active

Measure the same common lossless z2000 stream at t1 and t20 with container
parse, packet catalog, Tier-1, inverse DWT, component assembly/transform,
conversion, and TIFF output reported separately. Add wall-clock worker-busy,
queue-wait, and peak-ready-block counts where stage totals alone cannot explain
the critical path.

Run native-plane or checked raw output beside TIFF output so codec time is not
confused with serialization. Keep instrumentation off by default and verify
that disabled counters do not change output bytes or materially move the
baseline.

The first target is repeatable t20 common-stream decode below OpenJPEG's
123.9 ms without regressing t1. The next gates are below Grok's 99.1 ms and
then Kakadu's 94.5 ms on this host/profile. These are checkpoint targets, not
portable performance claims.

### P2. T1/MQ Decode Hot Path

Use pass counters and a native profiler to attribute symbol count, branch
behavior, context-neighbor updates, and memory traffic by cleanup,
significance-propagation, and refinement pass. Evaluate lossless and lossy
blocks separately; include sparse, dense/sign-heavy, and refinement-heavy
micro-corpora plus the end-to-end common stream.

Candidates must reduce actual per-symbol work or improve its data layout while
preserving MQ state order. Preserve byte/symbol oracles, corruption behavior,
and scalar comparisons. Do not reopen the rejected wholesale packed-column or
SWAR designs without a new measured hypothesis.

### P3. Decode Pipeline Overlap

After P1 identifies idle boundaries, prototype overlap only where ownership is
clear: packet parsing/catalog production feeding ready-block T1 work, inverse
DWT beginning for complete tile/component/resolution dependencies, or
tile/plane output that cannot race packet state. Reuse the normalized packet
index planned in `next_steps.md`; do not build a performance-only parser.

Measure t1/t8/t20, queue depth, utilization, tiny-image crossover, and memory
growth. Keep worker counts and thresholds explicit. Overlap must remain
deterministic and compatible with cancellation, resource limits, selective
decode, and malformed-stream fail-closed behavior.

### P4. Output And I/O Locality

Profile TIFF row assembly, planar-to-interleaved conversion, file writes, and
large-image allocations using the P1 raw-output control. Prefer row/block
writes, direct native-plane sinks, and reusable scratch over additional copies.
The sampled nearest-neighbour path already builds one horizontal index map per
component and selects one source row per output row.

Coordinate this work with the roadmap's selective and bounded-memory decode:
an optimization that requires materializing the complete display raster is not
acceptable for large-image or region-only requests.

### P5. Transform And Reconstruction Locality

Revisit DWT only when P1 shows it has regained a material critical-path share.
The next lossless hypothesis is cache-blocking row/column work per level so a
plane streams fewer times. For lossy decode, experiment with
dequantize-to-inverse-9/7 fusion only behind reference-relative pixel/hash
gates. Keep either only if cache/allocation savings exceed the added complexity
and all pinned accuracy bounds remain unchanged.

The native 1..29-bit diagnostic path deliberately uses scalar inverse 5/3 with
`i64` lifting sums and checked `i32` stores. Do not route it back through the
unchecked SIMD kernels. A future vectorized version must retain lane-wise
overflow detection and the 29-bit Kakadu plus synthetic-overflow gates; profile
this path separately from the ordinary unsigned 8/16-bit display decoder.

### P6. Encode-Side Follow-Up

Hold broad encode work until P1-P3 close at least the OpenJPEG common-decode
gap, unless profiling finds a shared T1/MQ change. Then revisit bitplane
extraction, scratch clears, catalog materialization, and rate allocation using
both 5/3 and quality-matched 9/7 profiles. Avoid rebuilding block metadata or
scanning all blocks per packet. Maintain deterministic packet order
independently of worker completion order.

The encode target sequence on the active host is below OpenJPEG's 131.2 ms,
then toward Kakadu's 77.6 ms for the pinned lossless profile. Re-measure
references after tool or host changes rather than treating these numbers as
permanent thresholds.

## Benchmark Command

```powershell
.\tools\bench_compare.ps1 -InputPath .\zig-out\bench-rgb-2048.tif `
  -Runs 8 -Warmup 2 -Threads all -IncludeLossy
```

Use explicit `-Threads 1` and `-Threads all` runs for release checkpoints.
Kakadu, Grok, and OpenJPEG must decode their documented comparison streams;
never compare one codec's decode of an easier profile to another codec's
decode of a harder one without labelling that difference. For decode
optimization, always include the common z2000 lossless stream. For lossy
ranking, add a rate sweep and compare interpolated time/quality or time/size
points instead of a single unmatched command.

Store raw Hyperfine JSON, exact commands, tool versions, input/output hashes,
stream sizes, and profiler configuration under the benchmark result directory.
Only the summarized evidence belongs in version control unless an artifact is
small, licensed, and intentionally promoted to the fixture corpus.

