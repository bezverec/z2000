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
malformed-input behavior.

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
  (2026-07-15 record in `benchmarks.md`). The remaining DWT idea is to give the
  5/3 driver the 9/7 driver's persistent barrier pool so it stops re-spawning
  per phase; measure before assuming a win.
- Portable `@Vector` kernels have scalar-oracle coverage on x86, ARM, and the
  RISC-V/RVV functional gate. ISA-specific intrinsics remain a last resort.

## Candidate Queue

### P1. Decode Pipeline Efficiency

Measure packet catalog, T1 readiness, inverse DWT, colour conversion, and TIFF
write as separate stages at t1/t8/t16. Prototype overlap only where ownership
is clear: ready-block queues into the persistent T1 pool, or tile/plane output
work that cannot race packet state. Keep worker-count and tiny-image thresholds
explicit.

### P2. Output And I/O Locality

Profile TIFF row assembly, planar-to-interleaved conversion, file writes, and
large-image allocations. Prefer row/block writes and reusable scratch over
additional copies. The sampled nearest-neighbour path already builds one
horizontal index map per component and selects one source row per output row.

### P3. T1/MQ Research

Use pass counters to target the actual worst pass separately for lossless and
lossy inputs. Candidates must reduce per-symbol context/neighbor work or expose
independent symbols without changing MQ state order. Preserve byte/symbol
oracles and benchmark sparse, dense/sign-heavy, and refinement-heavy blocks.

### P4. Fused Lossy Reconstruction

Experiment with dequantize-to-inverse-9/7 fusion only behind reference-relative
pixel/hash gates. Keep it only if allocation and cache savings exceed added
complexity and OpenJPEG/Grok/Kakadu agreement remains within the pinned bounds.

### P5. Encode-Side Locality

Revisit bitplane extraction, scratch clears, and catalog materialization using
profiles from both 5/3 and 9/7. Avoid rebuilding block metadata or scanning all
blocks per packet. Maintain deterministic packet order independently of worker
completion order.

## Benchmark Command

```powershell
.\tools\bench_compare.ps1 -InputPath .\zig-out\bench-rgb-2048.tif `
  -Runs 8 -Warmup 2 -Threads all -IncludeLossy
```

Use explicit `-Threads 1` and `-Threads all` runs for release checkpoints.
Kakadu, Grok, and OpenJPEG must decode their documented comparison streams;
never compare one codec's decode of an easier profile to another codec's
decode of a harder one without labelling that difference.

