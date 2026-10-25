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
5. measure enough warm runs to separate signal from noise: `hyperfine` on a
   quiet host, or interleaved A/B rounds (every candidate in turn, median and
   minimum) when other work shares the machine, because sequential runs then
   differ by more than the effect under test;
6. keep only a repeatable improvement on the target profile without a material
   regression on the other maintained profiles; otherwise revert the candidate
   and record the result in `benchmarks.md`.

Output bytes, pixel hashes, strict status, encode time, and decode time are all
required. Lossless 5/3 and lossy 9/7 are reported separately at t1 and at the
all-thread setting.

## Current Evidence

- 2026-10-25 (`benchmarks.md`): folded MQ contexts and four-lane neighbor
  updates cut common-stream t1 decode from 781.6 to 691.9 ms; the cleanup
  column screen and a 64-bit MQ register then took it to 636.5 ms (Grok
  20.4.19 617.4 ms, 1.03x). At t20 z2000 decodes in 109.4 ms and encodes in
  119.8 ms, both ahead of Grok 20.4.19 (117.2 and 137.4 ms); t1 encode
  remains 1.04x behind it. Five scan-side candidates were rejected; see P2.
- 2026-10-24 interleaved A/B on the same i5-14500 (`benchmarks.md`): Grok
  20.4.19 decodes the common lossless stream in 123.7/634.1 ms at t20/t1
  against z2000 127.2/814.9 ms, but Grok 20.4.14 and 20.4.12 decode it in
  about 95 ms at t20, so the t20 gate below stays at the faster Grok, not
  the newest one. z2000 encodes faster than both Grok versions at t20 and
  remains about 1.1x slower at t1. The wide (above 29-bit) path is now
  block-parallel with threaded 5/3; Grok cannot be compared there
  (it stops at 16 bits).
- The 2026-07-16 Intel Core i5-14500 checkpoint is the active Windows/x86
  optimization baseline. On the common z2000 lossless stream, z2000 decoded in
  831.5/135.3 ms at t1/t20 versus Grok 636.8/99.1 ms, OpenJPEG
  680.9/123.9 ms, and Kakadu 619.6/94.5 ms. The 1.31x t1 gap to Grok proves
  that serial decode work remains material; the 1.37x t20 gap also leaves a
  parallel-efficiency problem.
- The newer 2026-07-17 Apple M4 run is the latest native four-codec
  cross-platform checkpoint and includes Kakadu on macOS. It confirms the same
  ordering, but battery power and a different architecture/thread count make
  it trend evidence rather than a replacement for the Windows P1 thresholds.
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
  measurement in July; on 2026-10-25, with heaviest-first atomic block
  scheduling inside it, one pool over all components' blocks was kept
  (block phase 58.7 -> 52.4 ms at t20 on the i5-14500).
- The 5/3 DWT phase is now capped at eight workers to match the 9/7 driver: the
  memory-bound bands stop scaling past the eight physical cores on the x86 host,
  so the uncapped 32-worker setting let lossless inverse DWT regress at t16
  (17.3 ms vs 12.8 ms at t8). Capping restored t16 to t8 and improved lossless
  decode t16 by 7.8% and encode t16 by 6.1% with byte-identical output
  (2026-07-15 record in `benchmarks.md`).
- 2026-10-25 t20 budget against Kakadu 8.4.1 (64.3 ms vs z2000 100.1 ms on
  the common stream; t1 583.9 vs 607.0 ms): about 25 ms of z2000's t20
  decode is serial (packet catalog 9.9, TIFF write 7.1, file and box
  handling 3.9, setup 3.3, ICC 0.9), while the T1 phase scales. P1/P3 work
  should now shrink those serial stages, in that order, before more T1
  tuning. The serial block decode's per-sample coverage bytes were the
  first casualty (t1 decode 621.8 -> 599.0 ms); reserved payload buffers,
  a single JP2 parse, and clearing only empty blocks then took t20 decode
  to 97.6 ms (Kakadu 67.5 ms). Still serial: TIFF write (7 ms, half of it
  the file write), JP2 read (2.2 ms), packet headers (4.2 ms), and the
  packet scan (0.8 ms).
- 2026-10-25: the integer 5/3 column passes lift 32-column strips (then 8,
  then scalar), using whole cache lines per row; the inverse DWT stage went
  from 32.1 to 23.3 ms at t1, decode t20 to 104.2 ms.
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

`tools/win_sample_profile.zig` samples a t1 run without administrator rights
and attributes it to inlined functions and source lines. Kept so far: folded
MQ contexts and four-lane neighbor-row updates. Rejected on 2026-10-25: a
per-pass local copy of the MQ registers (no change), branch-free sign
handling in refinement (+1.2%), per-column candidate masks (+3.7%), and
16-column vector screening of significance propagation (+7.1%): the
per-sample branches predict well, so the remaining cost is the MQ decisions
themselves and the flag and coefficient updates. Also kept: the cleanup
column screen (run mode and all-known columns from one look at four flag
words) and a 64-bit MQ C register with buffered bytes (one-shift RENORMD);
a buffered raw bit reader was neutral. On the encoder, a contiguous block
copy and multi-bit RENORME were both slower: the `isMagnitudeBitSet`
samples are the data-dependent branch on the coded bit, not memory.
Remaining idea: decoding straight into the coefficient plane instead of
scattering each block (a few percent at most).

### P2b. Tier-1 Throughput On Shared And Efficiency Cores

Closed 2026-10-25. The apparent hyper-threading and E-core deficit (1.37x
and 1.46x behind Kakadu) came from Kakadu escaping a plain process
affinity mask; confined by a job object (`tools/win_affinity_run.zig`),
z2000 is 1.01x Kakadu on one P-core, 1.06x on one E-core, 1.13x on six
P-cores, 1.18x with their hyper-threads, and 1.14x on the eight E-cores.
Hardware counters (`tools/win_pmc_record.ps1`) give z2000 45% more
instructions at a higher IPC (2.28 against 1.63 on a P-core), half the
mispredictions per instruction, and rare LLC misses, with the same growth
in cycles as Kakadu from one to six cores. What remains is the serial and
overlap budget around Tier-1 (P3): at six threads the pool is balanced but
15-20 ms of the decode runs outside it. Earlier probes that found nothing
(i16 block coefficients, a 16 KB hot pass, out-of-line MQ renormalization)
stay recorded in `benchmarks.md`.

### P3. Decode Pipeline Overlap

First slice done 2026-10-25: the reversible full-resolution inverse 5/3 of
planes 0 and 1 runs inside the block pool as each plane completes (t20
decode 91.3 -> 86.9 ms); the irreversible path followed (lossy t20 108.9
-> 104.4 ms), where plane 1's serial 9/7 still overruns the pool. Next
candidates in the same direction: splitting a finished plane's 9/7 into
level or band tasks the idle workers can pick up at the end of the pool;
fusing inverse MCT/ICT with TIFF serialization (no 16-bit interleaved
intermediate; ICT is 5.4 ms at t20 on the lossy profile); a persistent
worker pool shared by Tier-1, DWT, MCT, and output (done 2026-10-25 for
everything but the barrier-synchronized DWT pools: `worker_pool.zig`,
lossy t20 91.7 -> 88.8 ms). Releasing the coefficient planes and the 9/7
reconstruction on a background thread (2026-10-25) took 3-4 ms off the
serial tail at t20 (lossless 84.5 -> 81.1 ms), and the JP2 wrapper's
tile-part walk now runs beside the decode (0.9 ms). What stays serial at
t20 outside the Tier-1 pool, about 15 ms: input read 2.2-2.6 ms, packet
catalog 3.0-3.6 ms, inverse DWT tail 3.0-3.8 ms, inverse RCT 1.1-1.3 ms,
TIFF write 4.3-4.9 ms (`benchmarks.md`). The read and write are copy-bound
(parallel reads saved 0.2 ms, parallel writes were slower), and the tail
DWT is memory-bound (moving its phases to the shared pool or adding workers
was within noise). What is left needs real overlap: streaming the last
plane's final DWT level, the colour transform, and the write row band by
row band behind Tier-1 (which needs a failure policy for the output file:
the strict checks in the DWT and RCT can still reject the stream after
writing has begun), or starting Tier-1 on blocks while later packet
headers are still being walked.

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

