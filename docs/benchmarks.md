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
