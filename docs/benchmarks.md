# Comparative Benchmarks

This is the append-only ledger for reproducible z2000 performance comparisons.
New records go above older records and must identify the source revision, host,
tool versions, input, codec profile, thread count, run count, output sizes, and
correctness checks. Results from different records are not directly comparable
unless those fields match.

Run the maintained archival comparison with:

```sh
RUNS=8 Z2000_THREADS=10 \
  BENCH_RESULTS_DIR=.bench/comparative-YYYY-MM-DD-COMMIT \
  sh tools/bench_compare.sh bench-rgb-2048.tif
```

`BENCH_RESULTS_DIR` retains Hyperfine JSON for encode, native round-trip decode,
and common-stream decode. The `.bench/` artifacts are local evidence and are not
committed. The summary tables below use wall-clock mean +/- sample standard
deviation; median is included because interactive systems can produce outliers.

On Windows, the equivalent harness can include the irreversible profile:

```powershell
.\tools\bench_compare.ps1 -InputPath .\zig-out\bench-rgb-2048.tif `
  -OutDir .\zig-out\bench-compare -Runs 8 -Warmup 2 -Threads 16 -IncludeLossy
```

## 2026-07-13: Ryzen 7 5700X, parallel inverse RCT/ICT

| Field | Value |
| --- | --- |
| z2000 source | baseline `a58f1cf`, candidate = threaded inverse-color change |
| Build | Zig 0.16.0, `ReleaseFast`, native x86-64/AVX2 |
| Host | AMD Ryzen 7 5700X, 8 cores / 16 threads, Windows 11 |
| Harness | Hyperfine 1.20.0, 2 warmups + 30 measured runs, interleaved |
| Input | `bench-rgb-2048.tif`, 12,583,052 B |

The candidate uses SIMD-aligned bands and at most four workers for inverse RCT
and ICT. The lossy stream is ICT, irreversible 9/7, scalar-expounded QCD and
two layers at `--rates 8,1`; the lossless stream is RCT/reversible 5/3. Both
use the existing 8192 tile, RPCL, six-resolution, SOP/EPH/TLM profile.

| Metric | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| **Lossy decode t16** | **148.2 +/- 5.1 ms** | **136.5 +/- 4.1 ms** | **-7.9%, kept** |
| Lossless decode t16 | 143.9 +/- 5.5 ms | 139.2 +/- 4.0 ms | -3.3%, overlapping |
| Lossy decode t1 | 744.7 +/- 33.0 ms | 731.6 +/- 10.0 ms | neutral; serial path |
| Lossless decode t1 | 754.1 +/- 8.5 ms | 752.4 +/- 4.3 ms | neutral; serial path |

The inverse ICT timing row fell from 14.238 to 3.630 ms in representative
runs. The initial eight-worker candidate measured 151.4 +/- 4.4 to
143.1 +/- 4.4 ms (-5.5%, 30 runs); capping the memory-heavy tail at four
workers produced the stronger final result. Candidate and baseline decoded
TIFF SHA-256 hashes matched for both streams. The streams themselves were
unchanged: lossless 6,636,048 bytes and lossy 4,798,568 bytes.

## 2026-07-13: Ryzen 7 5700X, persistent 9/7 forward-DWT pool

| Field | Value |
| --- | --- |
| z2000 source | baseline `52d2645` (merged PR #141), candidate `f94b1d1` |
| Build | Zig 0.16.0, `ReleaseFast`, native x86-64/AVX2 |
| Host | AMD Ryzen 7 5700X, 8 cores / 16 threads, Windows 11 |
| Harness | Hyperfine 1.20.0, 2 warmups; 12 t1 and 16 t16 measured runs, interleaved |
| Input | `bench-rgb-2048.tif`, 12,583,052 B |

Profile: single 8192x8192 tile, RPCL, six resolutions, 256/128 precinct
ladder, 64x64 blocks, two layers at `--rates 8,1`, `R` tile-parts, SOP/EPH,
TLM, ICT, irreversible 9/7, and scalar-expounded QCD.

| Metric | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Encode t1 | 819.6 +/- 17.4 ms | 802.9 +/- 12.6 ms | -2.0%, overlapping |
| **Encode t16** | **161.1 +/- 4.5 ms** | **152.8 +/- 4.1 ms** | **-5.2%, kept** |
| Decode t1 | 722.6 +/- 3.0 ms | 726.8 +/- 6.4 ms | +0.6%, neutral |
| Decode t16 | 148.3 +/- 5.2 ms | 141.5 +/- 3.1 ms | -4.6%, not attributed; decode algorithm unchanged |

The candidate creates at most eight DWT workers once per transform and reuses
them across row/column phases and decomposition levels. Baseline/candidate and
t1/t16 produced the same 4,798,568-byte JP2, SHA-256
`7597eb209f70f3dc36717c08b4e0029f4c65895758f549a029a1f0612fd9c9ee`;
decoded TIFF hashes also matched. A measured inverse-DWT promotion was not
kept: even with the persistent pool it changed t16 decode from
146.7 +/- 6.0 to 153.9 +/- 5.1 ms (+4.9%, 12 runs), primarily because it
split the existing fused dequantize+inverse traversal.

## 2026-07-13: Ryzen 7 5700X, S3 close-out — 9/7 lifting block width 32

### Provenance And Profiles

| Field | Value |
| --- | --- |
| z2000 source | baseline `66807d7` (`0.1.0-dev.394+g66807d77`), candidate = baseline + `f32_block_lanes` 16 -> 32 |
| Build | Zig 0.16.0, `ReleaseFast`, native x86-64/AVX2 |
| Host | AMD Ryzen 7 5700X, 8 cores / 16 threads, Windows 11 |
| Harness | Hyperfine 1.20.0, 2 warmups + 8 measured runs (20-run confirmation for the borderline decode t1) |
| References | Grok 20.3.6, OpenJPEG 2.5.4, Kakadu 8.4.1 |
| Input | `bench-rgb-2048.tif`, 12,583,052 B, SHA-256 `d8e3038c...` |

Profiles identical to the record below (archival 5/3 lossless; ICT 9/7
scalar-expounded `--rates 8,1` lossy). The candidate run interleaved four
binaries in one hyperfine invocation: baseline (16 f32 block lanes),
8 lanes, 32 lanes, and `ict_lanes` forced to 4.

### Baseline At `66807d7` (Four Codecs)

Lossless:

| Codec | Encode t1 | Encode t16 | Decode t1 | Decode t16 |
| --- | ---: | ---: | ---: | ---: |
| z2000 | 802.0 +/- 7.0 ms | 137.0 +/- 10.5 ms | 743.8 +/- 8.0 ms | 147.1 +/- 10.6 ms |
| Grok | 714.7 +/- 45.2 ms | 163.2 +/- 11.5 ms | 540.0 +/- 5.5 ms | 98.1 +/- 8.9 ms |
| OpenJPEG | 688.0 +/- 10.2 ms | 124.1 +/- 2.9 ms | 573.4 +/- 1.9 ms | 138.4 +/- 10.0 ms |
| Kakadu | 425.2 +/- 7.4 ms | 65.5 +/- 1.6 ms | 491.6 +/- 15.0 ms | 70.2 +/- 3.8 ms |

Lossy 9/7:

| Codec | Encode t1 | Encode t16 | Decode t1 | Decode t16 |
| --- | ---: | ---: | ---: | ---: |
| z2000 | 829.5 +/- 3.6 ms | 159.5 +/- 1.6 ms | 745.3 +/- 3.5 ms | 147.1 +/- 2.3 ms |
| Grok | 773.1 +/- 4.7 ms | 177.4 +/- 5.7 ms | 659.1 +/- 55.8 ms | 119.2 +/- 10.0 ms |
| OpenJPEG | 632.3 +/- 2.2 ms | 127.1 +/- 1.7 ms | 533.1 +/- 4.0 ms | 137.0 +/- 6.0 ms |
| Kakadu | 449.3 +/- 3.9 ms | 62.0 +/- 0.5 ms | 508.5 +/- 4.6 ms | 70.8 +/- 8.1 ms |

Lossless sizes: z2000 6,636,048 B, Grok 6,635,206 B, OpenJPEG 6,636,085 B,
Kakadu 6,624,994 B. Lossy sizes: z2000 4,798,568 B, Grok 5,326,180 B,
OpenJPEG 4,805,522 B, Kakadu 4,826,199 B. z2000 t1 == t16 codestreams in
both profiles. Relative to the previous record, the `88b061b` T1 pass
profiling counters did not move lossless encode (802.0 vs 798.0, overlapping
sigma) and the MQ branch-layout candidate's lossy decode win held
(745.3/147.1 vs 758.8/152.6).

### Candidate: `f32_block_lanes` 16 -> 32 — KEPT

Interleaved z2000-only A/B on the lossy profile (all four variants produced
bit-identical lossy JP2s, SHA-256 `7597eb20...`, and the lossless stream was
unchanged):

| Variant | Lossy encode t1 | Lossy decode t1 |
| --- | ---: | ---: |
| 16 lanes (baseline) | 836.3 +/- 15.4 ms | 754.3 +/- 10.9 ms |
| 8 lanes | 879.1 +/- 13.5 ms | 806.8 +/- 7.8 ms |
| **32 lanes** | **786.5 +/- 3.6 ms (-6.0%)** | **730.9 +/- 9.4 ms (-3.1%)** |
| `ict_lanes` 4 | 817.0 +/- 2.4 ms (-2.3%) | 750.7 +/- 6.6 ms (-0.5%) |

No-regression checks for 32 lanes: lossless encode t1 797.4 -> 793.0 ms
(unchanged within sigma), lossy encode t16 158.0 -> 150.3 ms (-4.9%), lossy
decode t16 146.7 -> 139.2 ms (-5.1%). The borderline decode t1 delta was
confirmed on 20 runs: 758.8 +/- 8.5 -> 726.2 +/- 9.2 ms (-4.3%,
non-overlapping sigma). 8 lanes regressed both metrics and the narrower
`ict_lanes` stayed below the 3% gate; both were reverted.

### Generated-Code Spot Check (S3 close-out)

`zig build-obj -OReleaseFast -mcpu=native -femit-asm` on a probe root that
forces the 9/7 `forward2D` path: the lifting emits 72x `vmulps ymm` and 72x
`vaddps ymm` (the 32-lane block lowers to four 256-bit AVX2 registers per
lift step), with 77 scalar `mulss`/`addss` confined to boundary/tail
elements. No `vfmadd*` appears — intentionally: FMA contraction would change
f32 rounding and break the bit-identical-stream invariant the SIMD keep rule
mandates.

## 2026-07-13: Ryzen 7 5700X, 5/3 lossless focus

This follow-up uses the same host, tools, corpus, and archival profile as the
record below, after the MQ decoder branch-layout candidate based on `c64385f`.
Hyperfine used two warmups and eight measured runs. Output sizes stayed z2000
6,636,048 B, Grok 6,635,206 B, OpenJPEG 6,636,085 B, and Kakadu 6,624,994 B;
z2000 t1 and t16 codestreams were byte-identical.

| Codec | Encode t1 | Encode t16 | Decode t1 | Decode t16 |
| --- | ---: | ---: | ---: | ---: |
| z2000 | 798.0 +/- 7.5 ms | 134.8 +/- 3.1 ms | 740.6 +/- 6.4 ms | 137.8 +/- 2.4 ms |
| Grok | 701.4 +/- 8.7 ms | 152.0 +/- 3.2 ms | 535.4 +/- 3.3 ms | 91.0 +/- 3.0 ms |
| OpenJPEG | 673.6 +/- 2.1 ms | 126.1 +/- 2.4 ms | 573.3 +/- 8.5 ms | 127.9 +/- 7.5 ms |
| Kakadu | 417.9 +/- 3.0 ms | 65.1 +/- 2.3 ms | 481.4 +/- 1.8 ms | 71.3 +/- 3.3 ms |

z2000 now beats Grok's 5/3 encode at t16 by 11.3%, while remaining 13.8%
behind at t1. Decode remains the larger gap: 1.38x/1.51x behind Grok and
1.54x/1.93x behind Kakadu at t1/t16. A matching `--timings` encode reported
88.2% T1 block payload, 8.9% 5/3 DWT, and under 1% RCT; future 5/3 encode work
therefore stays focused on T1 rather than transform or container overhead.

## 2026-07-13: Ryzen 7 5700X, direct PCRD distortion candidate

### Provenance And Profiles

| Field | Value |
| --- | --- |
| z2000 source | candidate based on `4b479a91` (`0.1.0-dev.390+g4b479a91.dirty`) |
| Build | Zig 0.16.0, `ReleaseFast`, native x86-64/AVX2 |
| Host | AMD Ryzen 7 5700X, 8 cores / 16 threads, Windows 11 |
| Harness | Hyperfine 1.20.0, 2 warmups + 8 measured runs |
| References | Grok 20.3.6, OpenJPEG 2.5.4, Kakadu 8.4.1 |
| Input | `bench-rgb-2048.tif`, 12,583,052 B, SHA-256 `d8e3038ca752fab381d167783b797ebd64250a3f51c852437771180f3234e139` |

Both profiles use one 8192x8192 tile, RPCL, six resolutions, 64x64 blocks,
resolution tile-parts, PLT/TLM, SOP/EPH, and the documented 256/128 precinct
ladder. Lossless uses RCT, reversible 5/3, BYPASS, and one layer. Lossy uses
ICT, irreversible 9/7, scalar-expounded quantization, and two rate-targeted
layers (`8,1` for z2000/Grok/OpenJPEG; Kakadu's closest size-matched
`-rate -,3`). Each decoder reads its own encoder's 16-thread output.

### Lossless Results

| Codec | Encode t1 | Encode t16 | Decode t1 | Decode t16 |
| --- | ---: | ---: | ---: | ---: |
| z2000 | 788.6 +/- 5.1 ms | 136.6 +/- 6.4 ms | 753.8 +/- 3.8 ms | 136.5 +/- 4.0 ms |
| Grok | 691.0 +/- 4.3 ms | 148.8 +/- 2.7 ms | 532.6 +/- 2.7 ms | 90.6 +/- 3.5 ms |
| OpenJPEG | 671.1 +/- 1.0 ms | 124.2 +/- 3.1 ms | 571.2 +/- 1.4 ms | 133.7 +/- 6.6 ms |
| Kakadu | 416.4 +/- 1.2 ms | 63.6 +/- 2.0 ms | 479.4 +/- 0.8 ms | 70.2 +/- 3.1 ms |

Lossless output sizes were z2000 6,636,048 B, Grok 6,635,206 B, OpenJPEG
6,636,085 B, and Kakadu 6,624,994 B. This performance-only candidate did not
change the z2000 lossless stream or timing materially.

### Lossy Results

| Codec | Encode t1 | Encode t16 | Decode t1 | Decode t16 |
| --- | ---: | ---: | ---: | ---: |
| z2000 | 808.9 +/- 3.2 ms | 159.4 +/- 4.2 ms | 758.8 +/- 6.0 ms | 152.6 +/- 4.1 ms |
| Grok | 762.2 +/- 1.4 ms | 170.0 +/- 10.3 ms | 610.3 +/- 1.0 ms | 110.1 +/- 2.1 ms |
| OpenJPEG | 628.5 +/- 2.1 ms | 128.6 +/- 3.2 ms | 525.1 +/- 1.3 ms | 125.5 +/- 3.3 ms |
| Kakadu | 444.5 +/- 0.5 ms | 62.4 +/- 2.8 ms | 500.2 +/- 2.4 ms | 66.8 +/- 2.1 ms |

The direct-MQ PCRD distortion capture reduced z2000 lossy encode from
2,256 to 809 ms at t1 (-64.1%) and from 367 to 159 ms at t16 (-56.6%). It
removed a second symbol-coder traversal without changing pass distortions,
packet decisions, or output bytes. z2000 remains 1.06x behind Grok at t1 but
is 1.07x faster at t16; Kakadu remains 1.82x/2.56x faster at t1/t16.

Lossy output sizes were z2000 4,798,568 B, Grok 5,326,180 B, OpenJPEG
4,805,522 B, and Kakadu 4,826,199 B. z2000 t1 and t16 files were SHA-256
identical, and the candidate z2000 stream was byte-identical to the pre-change
baseline. z2000, Grok, OpenJPEG, and Kakadu all decoded that stream in the
interop smoke. The optional Python pixel comparator was unavailable in this
run; unchanged stream hashes plus the full codec tests provide the regression
gate, but this record does not claim a new lossy pixel-quality result.

## 2026-07-13: Apple M4, commit 506ebdc4

### Provenance

| Field | Value |
| --- | --- |
| Date | 2026-07-13, 12:52-12:54 CEST |
| z2000 source | `506ebdc4b226d35f4a94a98ef28f6b5cff0a5c61` |
| z2000 version | `0.1.0-dev.383+g506ebdc4.dirty` |
| Build | Zig 0.16.0, `ReleaseFast`, default host target (`aarch64-macos`) |
| Host | MacBook Air `Mac16,12`, Apple M4, 4 performance + 6 efficiency cores, 16 GB RAM |
| OS | macOS 26.5.2 (25F84), Darwin 25.5.0 |
| Power | AC power, battery charging |
| Harness | Hyperfine 1.20.0, 2 warmups + 8 measured runs |
| References | Grok 20.3.6, OpenJPEG 2.5.4 |
| Unavailable | Kakadu and the tif2jp2 wrapper were not installed locally |

Only the benchmark harness and this documentation differed from the recorded
source commit when the binary was built, hence the `.dirty` suffix. Codec source
and build configuration matched `506ebdc4`.

The machine was in a normal interactive macOS session, not a quiesced benchmark
environment. Hyperfine detected outliers in some multi-thread decode runs, so
these numbers establish a local trend rather than a laboratory ranking.

### Input And Profile

The input is the deterministic 2048x2048, chunky, uncompressed, 8-bit RGB TIFF
generated by `tools/make_bench_tiff.py`:

- Size: 12,583,052 bytes.
- SHA-256: `d8e3038ca752fab381d167783b797ebd64250a3f51c852437771180f3234e139`.
- Codec profile: lossless RCT + reversible 5/3, one 4096x4096 tile, RPCL,
  6 resolutions, precincts `[256,256],[256,256],[128,128]` repeated for the
  remaining levels, 64x64 code-blocks, one layer, resolution tile-parts,
  SOP, EPH, TLM, and BYPASS.
- Thread variants: one thread and ten threads for every codec. Grok was forced
  to CPU execution with `-G -2`; Grok `-H` and OpenJPEG `-threads` were set
  explicitly.

### Encode

Each codec reads the same TIFF and writes its own JP2.

| Codec | Threads | Mean +/- sd | Median | t1 / t10 speedup |
| --- | ---: | ---: | ---: | ---: |
| z2000 | 1 | 620.3 +/- 53.6 ms | 620.1 ms | - |
| z2000 | 10 | 163.9 +/- 22.8 ms | 162.1 ms | 3.78x |
| Grok | 1 | 489.2 +/- 38.6 ms | 484.7 ms | - |
| Grok | 10 | 145.1 +/- 28.7 ms | 138.5 ms | 3.37x |
| OpenJPEG | 1 | 505.4 +/- 7.6 ms | 504.4 ms | - |
| OpenJPEG | 10 | 141.3 +/- 31.3 ms | 128.7 ms | 3.58x |

At ten threads, OpenJPEG was 1.16x and Grok 1.13x faster than z2000 by mean
wall time. The small difference between the two references is below the noise
suggested by their standard deviations.

### Decode: Native Outputs

This end-user view lets each decoder read the JP2 produced by its matching
encoder. Payloads are similar in size but not byte-identical.

| Codec | Threads | Mean +/- sd | Median | t1 / t10 speedup |
| --- | ---: | ---: | ---: | ---: |
| z2000 | 1 | 523.9 +/- 36.0 ms | 518.5 ms | - |
| z2000 | 10 | 148.1 +/- 28.8 ms | 135.0 ms | 3.54x |
| Grok | 1 | 424.1 +/- 24.0 ms | 427.9 ms | - |
| Grok | 10 | 105.1 +/- 10.7 ms | 99.1 ms | 4.04x |
| OpenJPEG | 1 | 525.5 +/- 27.5 ms | 524.3 ms | - |
| OpenJPEG | 10 | 154.6 +/- 36.5 ms | 141.8 ms | 3.40x |

### Decode: Common z2000 Stream

This is the cleaner decoder comparison: all three decoders read the same
6,636,048-byte z2000 JP2.

| Codec | Threads | Mean +/- sd | Median | t1 / t10 speedup |
| --- | ---: | ---: | ---: | ---: |
| z2000 | 1 | 525.9 +/- 46.3 ms | 508.9 ms | - |
| z2000 | 10 | 138.4 +/- 10.3 ms | 138.3 ms | 3.80x |
| Grok | 1 | 397.9 +/- 18.5 ms | 394.0 ms | - |
| Grok | 10 | 100.2 +/- 14.3 ms | 99.3 ms | 3.97x |
| OpenJPEG | 1 | 547.3 +/- 76.9 ms | 517.7 ms | - |
| OpenJPEG | 10 | 151.6 +/- 30.4 ms | 141.1 ms | 3.61x |

On the common stream, Grok was 1.38x faster than z2000 at ten threads. z2000
was 1.10x faster than OpenJPEG, but OpenJPEG's variance was high. The z2000
single-thread gap to Grok was 1.32x, leaving both single-core Tier-1 work and
parallel efficiency as meaningful optimization targets.

### Sizes And Validation

| Encoder | JP2 size | Difference from smallest |
| --- | ---: | ---: |
| OpenJPEG | 6,635,203 B | 0 B |
| Grok | 6,635,206 B | +3 B |
| z2000 | 6,636,048 B | +845 B (+0.0127%) |

- jpylyzer 2.2.1 reported `<isValid format="jp2">True</isValid>` for all
  three files.
- `tiffcmp` returned 0 for z2000's self-decode and for Grok/OpenJPEG decoding
  the z2000 JP2. The reference TIFF writers added only an Orientation tag.
- z2000 one-thread and ten-thread decoded TIFF files were byte-identical.
- valid2000 at `c61de9faf3b02e55501c0570a0b522824a813795` rejected all three
  synthetic files as NDK Master copies because the generated TIFF intentionally
  has no ICC profile. This is a profile failure, not an ISO/JP2 validity failure.
  Its z2000 scan also warned that PLT was absent; this benchmark requests TLM,
  not PLT.
