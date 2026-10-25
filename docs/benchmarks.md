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

Kakadu stays outside the repository because the demo applications are licensed
for non-commercial use. Point the POSIX harness at a local installation or
extracted archive:

```sh
# Linux: KDU_HOME contains kdu_compress, kdu_expand, and libkdu_v84R.so.
KDU_HOME=/opt/kakadu-8.4.1 RUNS=8 WARMUP=2 \
  BENCH_RESULTS_DIR=.bench/kakadu-linux \
  sh tools/bench_compare.sh bench-rgb-2048.tif

# macOS package default: universal arm64+x86_64 command-line applications.
KDU_HOME=/Library/Kakadu/8.4.1 RUNS=8 WARMUP=2 \
  BENCH_RESULTS_DIR=.bench/kakadu-macos \
  sh tools/bench_compare.sh bench-rgb-2048.tif
```

Set `Z2000_BIN` to use a previously built executable. This is useful for
read-only checkouts and release-archive checks, but performance records must
state whether the binary is a native build or a portable release target.

`BENCH_RESULTS_DIR` retains Hyperfine JSON for encode, native round-trip decode,
and common-stream decode. The `.bench/` artifacts are local evidence and are not
committed. The summary tables below use wall-clock mean +/- sample standard
deviation; median is included because interactive systems can produce outliers.

On Windows, the equivalent harness can include the irreversible profile:

```powershell
.\tools\bench_compare.ps1 -InputPath .\zig-out\bench-rgb-2048.tif `
  -OutDir .\zig-out\bench-compare -Runs 8 -Warmup 2 -Threads 16 -IncludeLossy
```

## 2026-10-25: Intel Core i5-14500, multi-layer header walk in runs

Base `f548d81`, lossy profile (`lossy.jp2`: RPCL, two layers, SOP and PLT,
no EPH), t20. Its header walk was 1.4-1.6 ms on three workers (one per
component) after 0.2 ms of geometry and 0.35-0.47 ms of block-table setup.
A first version cut each component into runs but kept copying every
contribution into per-block lists, now in 20 per-run arenas: the walk got
slower (1.91 -> 2.41 ms). Recording the contributions as segments of the
packet bytes and gathering them only in the catalog fill:

| Stage (11 runs, t20, lossy) | Base | New |
| --- | ---: | ---: |
| header walk | 1.90 ms | 0.93 ms |
| finalize | 0.69 ms | 0.66 ms |
| packet catalog | 3.76 ms | 2.42 ms |
| total | 70.80 ms | 67.51 ms |

Wall time, 21 interleaved rounds: lossy t20 82.7 -> 81.9 ms, lossy t6 134.9
-> 133.0 ms, lossless t20 78.8 -> 79.0 ms (unchanged path). Output
byte-identical as before.

## 2026-10-25: Intel Core i5-14500, packet catalog on all workers

Base `58e16ac`, same host and method. A timeline of the stages before the
Tier-1 pool (temporary marks, t20, common lossless stream) showed 3.6-4.0
ms: scan 1.0, header walk 1.6-1.9 (one worker per component), finalize
0.3, coverage checks 0.4-0.6, pool setup 0.15 ms. The scan was almost all
the per-packet frame check (a search for 0xFF bytes through every packet
body); split into chunks it did not get faster at first because the shared
pool refused the task while its background start-up still held it. With
that fixed and the pool started before the input is read:

| Stage (11 runs, t20) | Base | New |
| --- | ---: | ---: |
| scan | 0.98 ms | 0.44 ms |
| header walk | 1.67 ms | 0.87 ms |
| finalize | 0.32 ms | 0.28 ms |
| packet catalog | 3.05 ms | 1.70 ms |
| total (lossless) | 66.43 ms | 63.81 ms |

Inside the header walk, runs of packets on 20 workers cost about 7 ms of
CPU while they copied the payloads into fresh per-component buffers (page
faults on 6.6 MB); borrowing the payloads from the input took the walk from
1.20 to 0.87 ms. Initializing the block tables (about 4 MB, one 112-entry
segment table per block) in parallel ranges took it from 1.41 to 1.20 ms.

Wall time, 21 interleaved rounds: lossless t20 80.7 -> 77.9 ms (-3.5%), t6
141.4 -> 141.6 ms, t1 604.3 -> 602.8 ms; lossy (multi-layer, no chunked
walk) t20 101.9 -> 100.7 ms. Decoded TIFFs byte-identical to the base for
both streams at t1/t2/t3/t20, region and `--layers 1` decodes, and the
34-bit wide stream.

## 2026-10-25: Intel Core i5-14500, streamed RGB tail with a replaced output file (rejected)

Base `9525104`, common lossless stream at t20 unless noted. Prototype: after
the Tier-1 pool, the unfinished plane's coarser 5/3 levels ran at once;
then 32-row bands, claimed in order on the shared pool, each repeated the
horizontal pass of its edge rows, applied the finest vertical lifting into
a private buffer, and ran the inverse RCT into the 8-bit raster. Whichever
thread finished the next band in row order wrote every finished band in
one call to a temporary file beside the output (`std.Io.Dir.createFileAtomic`,
preallocated to the final length), moved over the output path only after
the ICC trailer, with the replaced file held open across the move so that
freeing its data did not delay it. Output was byte-identical, and nothing
changed at the output path on failure.

| Stage (13 runs) | Base | Streamed |
| --- | ---: | ---: |
| inverse DWT | 3.08-3.41 ms | 1.54-1.59 ms (coarser levels only) |
| inverse RCT | 1.15-1.29 ms | in the stream |
| streamed output | - | 4.62 ms (first band ready after about 0.6 ms) |
| TIFF write | 4.31-4.49 ms | 0.96-1.13 ms (trailer, close, move) |

The tail went from about 8.6 to 7.2 ms, but the run outside the timed span
grew by 1.6 ms (21 interleaved rounds: 15.9 -> 17.5 ms), and wall time was
81.5 -> 83.1 ms at t20 (+1.9%) and 141.8 -> 140.4 ms at t6 (25 rounds);
with the output deleted before every run, 83.9 -> 85.5 ms. Writing is the
floor of the tail (one 12.6 MB write takes about 3.3 ms, in 32-row pieces
about 4.5 ms before coalescing), and a move over an existing file costs
about 1.1 ms more than overwriting it in place (standalone: 2.95 + 1.14 ms
against 3.43 ms). Two details on the way: a separate delivering thread
(one more than the cores) waited about 1 ms for a time slice after each
wake-up, hence delivery by the computing threads; and per-band writes cost
0.5 ms more than coalesced ones. Not merged.

## 2026-10-25: Intel Core i5-14500, JP2 tile-part audit beside the decode; DWT and read probes

Base `a425ecd`, same host and method. The whole 0.9 ms "codestream box"
stage was the JP2 wrapper's tile-part walk (stubbing it out left 0.01 ms).
Running it on a helper thread beside the decode, 11 `--timings` runs at
t20: JP2 parse 0.93 -> 0.04 ms, total 68.05 -> 66.22 ms. Wall time, 21
interleaved rounds (a noisy session): lossless t20 82.5 -> 80.9 ms, t6
145.8 -> 144.4 ms; lossy t20 103.7 -> 101.4 ms, t6 160.0 -> 162.6 ms. Output
byte-identical as in the record below.

Probes dropped on the way:

| Candidate | Result |
| --- | --- |
| Inverse 5/3 phases on the shared `worker_pool` instead of a per-transform pool (its spawn and join cost 0.2-0.4 ms each at t20) | tail DWT 3.03 -> 2.70 ms, with 4096 spin polls before the futex sleep 2.59 ms; wall within noise (t20 -1.1%, t12 +0.4%, lossy t4 +3.7%, 25 and 21 rounds): dropped |
| Same, 12 or 16 DWT workers | 2.42 / 2.31 / 2.41 ms at 8 / 12 / 16: the tail plane's transform is memory-bound |
| Input read with 2, 4, or 8 parallel positional reads (standalone, 40 rounds) | 1.67 ms single, 1.50 / 1.48 / 1.47 ms: about 0.2 ms, dropped |

## 2026-10-25: Intel Core i5-14500, decode intermediates released in the background

Base `b9a0c2a`, same host, ReleaseFast, interleaved A/B, 15 rounds, wall
time of `decode-temp-jp2` (process start included). A timeline of one t20
lossless decode (temporary marks, 6 runs) had placed 3.0-3.8 ms between the
end of the colour transform and the return from the decode: the free of the
three 2048x2048 i32 coefficient planes. Leaking them instead saved 0.8% of
wall time only, since the process exit then paid for the unmapping; handing
them to a detached thread overlaps it with the TIFF write.

| Stream | Threads | Base | Candidate | Change |
| --- | ---: | ---: | ---: | ---: |
| common lossless | 20 | 84.5 ms | 81.1 ms | -4.1% |
| common lossless | 6 (mask `555`) | 147.1 ms | 145.3 ms | -1.2% |
| lossy | 20 | 88.3 ms | 85.3 ms | -3.4% |
| lossy | 6 (mask `555`) | 141.1 ms | 141.1 ms | 0.0% |

The cost scales with the number of threads that touched the pages, hence
the smaller effect at six. Decoded TIFFs are byte-identical to the base for
both streams at t1/t2/t3/t20, region (`100,200,700,500`) and `--layers 1`
decodes, and the 34-bit wide stream (also at `--reduce 1` and `2`).

Same timeline, remaining serial time at t20 outside the Tier-1 pool (ms):
input read 2.2-2.6, JP2 parse and codestream extraction 1.0, packet catalog
3.0-3.6, inverse DWT tail 3.0-3.8, inverse RCT 1.1-1.3, catalog free 0.3,
TIFF write 4.3-4.9, input and raster free 0.6.

## 2026-10-25: Intel Core i5-14500, hardware counters; per-core-type study corrected

Source `fc00b6e` (ReleaseFast), Kakadu 8.4.1 `kdu_expand -num_threads N
-quiet`, common lossless stream (`z-t20.jp2`, 2048x2048 RGB). Counters came
from `tools/win_pmc_record.ps1` (xperf, read at every context switch, so
per-thread totals are exact; elevated session) and
`tools/win_pmc_summary.py`; 3 runs per trace, figures per decode. With
Hyper-V running the fixed counters are refused (0x54F), so instructions and
cycles come from the general-purpose `InstructionRetired` and
`UnhaltedCoreCycles`.

The counters show that the record below ("where Tier-1 loses past six
threads") measured Kakadu outside its mask: the launcher there only set the
process affinity, and Kakadu's multi-threaded decode sets its own thread
affinities. Share of Kakadu's cycles on processors outside the mask: 34% at
`555`, 30% at `FFF`, 86% at `FF000` (its "8 E-core" decode ran mostly on
P-cores). z2000 stayed inside every mask, and single-threaded Kakadu did
too. `tools/win_affinity_run.zig` now runs the child in a job object whose
affinity limit no thread can leave. Repeated with it (7 rounds, both codecs
carrying the launcher):

| Cores (mask) | Threads | z2000 | Kakadu | Ratio |
| --- | ---: | ---: | ---: | ---: |
| 1 P-core (`1`) | 1 | 645.6 ms | 638.5 ms | 1.01 |
| 1 E-core (`10000`) | 1 | 959.2 ms | 903.7 ms | 1.06 |
| 6 P-cores, one thread each (`555`) | 6 | 165.1 ms | 146.7 ms | 1.13 |
| 6 P-cores with hyper-threading (`FFF`) | 12 | 135.9 ms | 115.1 ms | 1.18 |
| 8 E-cores (`FF000`) | 8 | 183.5 ms | 161.2 ms | 1.14 |
| all (`FFFFF`) | 20 | 104.1 ms | 89.7 ms | 1.16 |

Hyper-threading gains z2000 1.21x and Kakadu 1.27x; there is no separate
E-core deficit. Counters per decode on one core:

| Core | Decoder | Instructions | Cycles | IPC | Mispredicts / 1k instr | LLC misses / 1k instr |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| P | z2000 | 6.39 G | 2.80 G | 2.28 | 6.3 | 0.81 |
| P | Kakadu | 4.41 G | 2.71 G | 1.63 | 12.2 | 0.51 |
| E | z2000 | 6.37 G | 3.35 G | 1.90 | 6.7 | 0.88 |
| E | Kakadu | 4.40 G | 3.11 G | 1.41 | 13.8 | 0.59 |

z2000 retires 45% more instructions at a higher IPC and has fewer branch
mispredictions in absolute terms (40 M against 54 M per decode on a
P-core); LLC misses are rare for both. On six P-cores both codecs spend
13-15% more cycles than on one (3.16 G z2000, 3.11 G Kakadu, the latter
measured unconfined), so the 1.13x at `555` is not extra work: z2000 keeps
the cores busy for less of the decode. Its `--timings` at `555` (3 runs)
put the Tier-1 pool at 112-127 ms with balanced workers (max/avg wall
within 1%), leaving 15-20 ms in stages around it (JP2 read 2.2 ms, packet
catalog 3.0-3.8 ms, inverse DWT 2.2-10.1 ms, TIFF write 3.9-4.3 ms) plus
about 10 ms of process start and exit outside the timed span. The gap
beyond one thread is therefore the serial and overlap budget around
Tier-1, not per-core Tier-1 throughput.

## 2026-10-25: Intel Core i5-14500, pre-Tier-1 stages by component

Header walk at t20 (lossless, current code): geometry 0.2, assemblies 0.6,
packet walk 1.8-2.4 ms; lossy (two layers, stateful precincts, walked
serially) 3.0 ms; catalog finalize 0.6 / 1.4 ms (it copies each block's
872-byte segment table). Splitting the single-layer walk, the finalize
fill, and the per-plane coverage checks by component, against `db938ca`:
header walk 2.58 -> 1.62 ms lossless, finalize 1.34 -> 0.74 ms lossy (9-11
`--timings` runs); decode 87.5 -> 85.0 ms lossless, 89.9 -> 89.4 ms lossy
(15 rounds). The multi-layer walk by component (shared precinct state,
per-component slots) then took the lossy header walk from 3.62 to 2.21 ms
and decode from 87.6 to 86.3 ms (15 rounds).

## 2026-10-25: Intel Core i5-14500, shared worker pool

Against `fd783db`, 11 rounds at t20: lossless 86.5 -> 84.9 ms, lossy 91.7
-> 88.8 ms. The pool's threads start on a helper thread when JP2-to-TIFF
begins and are reused by the Tier-1 pool, inverse colour conversion,
dequantization, and TIFF serialization.

## 2026-10-25: Intel Core i5-14500, where Tier-1 loses past six threads

Base is `fe7c8e5`, common lossless stream unless noted. A small launcher
that creates the process suspended and sets its affinity mask before
resuming it compared z2000 and Kakadu 8.4.1 per core type (5 rounds, both
codecs carrying the launcher's overhead):

| Cores (mask) | Threads | z2000 | Kakadu | Ratio |
| --- | ---: | ---: | ---: | ---: |
| 6 P-cores, one thread each (`555`) | 6 | 162.6 ms | 143.9 ms | 1.13 |
| 6 P-cores with hyper-threading (`FFF`) | 12 | 145.5 ms | 106.1 ms | 1.37 |
| 8 E-cores (`FF000`) | 8 | 194.3 ms | 133.1 ms | 1.46 |
| all (`FFFFF`) | 20 | 108.2 ms | 88.3 ms | 1.23 |

z2000 gains 1.12x from the second hyper-thread of each P-core where Kakadu
gains 1.36x, and runs relatively slower on the E-cores; on one thread per
P-core it is within 13%. Three hypotheses were tested and none moved this:

| Candidate | Result |
| --- | --- |
| i16 coefficients for blocks of at most 14 bitplanes (half the 16 KB block buffer) | t1 600.4 -> 604.4 ms, t20 87.4 -> 89.6 ms lossless and 93.8 -> 93.4 ms lossy (15 rounds): neutral, dropped |
| MQ exchange and renormalization out of line (call sites shrink; hot pass functions 20% smaller) | t1 +12.3%, P12-HT +5.8%, E8 +5.2%: rejected |
| Profiled and vertical-causal pass variants out of line (hot pass code from about 42 KB to 16 KB) | t1 -0.3%, P6 +1.1%, P12-HT +1.6%, E8 -1.0%, t20 +0.2% (11 rounds): neutral, dropped |

Instruction-cache size and the coefficient buffer are therefore not the
limit. A 32x32-block encoding of the same image decodes 18% faster at t1
(MQ about 6.9 against 9.3 ns per symbol with similar symbol counts and
more LPS decisions), but slower at t6 and t12; the per-symbol difference
shows in `readUnchecked` itself, so it is a property of the stream rather
than of a decoder path. Pinning the remaining SMT/E-core gap down needs
hardware counters, which this unelevated host cannot read.

## 2026-10-25: Intel Core i5-14500, t20 serial budget; serial coverage bits

Same host, method, profile, and stream as the record below; base is
`86cb099`. Kakadu 8.4.1 (`kdu_expand -num_threads N -quiet`) on the
common stream, 7 rounds: 583.9 ms at t1 against z2000 607.0 ms, but
64.3 ms at t20 against 100.1 ms. z2000's t20 `--timings` budget (90.7 ms
on that run) is about 25 ms of serial work: JP2 read 2.2, codestream box
1.7, packet catalog 9.9 (headers 8.3, of which about 5 ms only when
payloads are retained), unattributed codestream setup 3.3, ICC 0.9, and
TIFF write 7.1 (serialization 2.9, file write 4.5); T1 is 56.8 ms for 60
jobs that each take about 17 ms, so the block phase itself scales.

Sampling 40 t1 decodes showed the serial path's byte-per-sample coverage
bookkeeping at about 10 ms per decode (row checks and marks, the 12.6 MB
memset, the final scan), which the parallel path already replaced with a
bitmap checked from block rectangles.

| Candidate | Comparison | Result |
| --- | --- | --- |
| Serial decode checks coverage on the parallel path's bitmap | t1 decode 621.8 -> 599.0 ms (9 rounds) | -3.7%, kept |

Then, against `d2f9fa8` (stage medians of 11 interleaved `--timings` runs
at t20):

| Candidate | Comparison | Result |
| --- | --- | --- |
| Reserve single-layer component payload buffers up front | headers 8.03 -> 4.20 ms | kept |
| Parse the JP2 once (codestream and ICC from the accepted `Info`) | codestream box 1.66 -> 0.88 ms, ICC 0.95 -> 0.01 ms | kept |
| Clear only zero-length blocks' rectangles, not the whole plane | block payload 57.12 -> 56.36 ms, total 85.26 -> 83.41 ms | kept (the page faults move into the workers) |
| Write the TIFF in 256 KiB bands instead of one buffer | TIFF write 7.07 -> 5.56 ms | rejected: `writeRgb` would leave a partial file on a sample-range error, and checking first costs the gain |

End to end, 9 rounds: t20 decode 101.6 -> 97.6 ms (Kakadu 8.4.1 67.5 ms,
Grok 20.4.19 114.4 ms); t1 597.2 -> 603.4 ms, inside noise (Kakadu 579.7,
Grok 623.2 ms).

One pool over all three components' blocks instead of a pool per
component, against `61c690d`: block phase 58.71 -> 52.44 ms (11 `--timings`
runs), decode 97.9 -> 93.0 ms at t20 (15 rounds). A bare process start
(`--version`) takes 13.2 ms for z2000 and 12.4 ms for `kdu_expand
-version`, so about 12 ms of every end-to-end figure here is process
creation and teardown for both codecs; z2000's own `--timings` total is
80.9 ms.

After the single pool (t20 `--timings`, 80.0 ms): block phase 51.0 ms with
workers at 47.7 ms average (about 11.7x the t1 Tier-1 time, comparable to
Kakadu's overall 10.6x), so the remaining gap is outside Tier-1: TIFF write
7.3, inverse DWT 7.3 (eight workers, memory-bound), packet catalog 5.8,
pool preparation 3.3, JP2 read 2.2, inverse MCT 2.2, codestream box 0.9.
Threaded raster serialization then took TIFF write from 7.33 to 5.86 ms
(11 runs); the file write itself is about 4.5 ms.

Further t20 probes against `61a6fef`:

| Candidate | Comparison | Result |
| --- | --- | --- |
| 5/3 DWT worker cap 12 / 16 instead of 8 | inverse DWT 6.78 -> 6.14 / 5.86 ms; decode 93.4 -> 94.1 ms, encode 115.4 -> 116.1 ms (11 rounds, cap 16) | neutral end to end, cap kept at 8 |
| Packet headers read per component on separate threads | headers 4.34 -> 3.64 ms; decode 93.1 -> 93.0 ms | rejected: the header stage is mostly geometry setup (2.0 ms), assemblies (0.6 ms), and the packet walk (1.9 ms) |
| Linear RPCL block index (blocks grouped by resolution, rectangles computed once) | headers 4.30 -> 2.51 ms; decode 93.6 -> 91.4 ms, encode 113.5 -> 114.4 ms (11 rounds) | kept |

Thread start costs about 48 us per thread on this host (19 spawns 0.9 ms,
joins 0.1 ms), so a persistent pool would save roughly 1 ms per decode.

Inverse 5/3 overlapped with Tier-1 (planes 0 and 1 transformed by the
worker that completes them, plane 2 on all DWT workers afterwards), against
`821fcbf`: t20 decode 91.3 -> 86.9 ms (15 rounds); t2 335.4 -> 334.9,
t4 187.9 -> 191.9 (minimum 185.5 -> 183.0), t8 133.3 -> 123.7 ms (7 rounds).

Lossy profile (4,800,644-byte two-layer 9/7 ICT stream of the benchmark
image, written by z2000 with `--transform 9-7 --mct ict --qstyle
scalar-expounded --layers 2`), t20 `--timings` at `8288bd7`: block phase
50.5, inverse DWT 19.0 (one plane per thread), inverse MCT 5.4, packet
catalog 7.7, TIFF 5.9 ms; Kakadu 8.4.1 decodes it in 68.3 ms against
z2000 104.8 ms at t20 and 536.7 against 581.0 ms at t1.

| Candidate (lossy, t20 unless noted) | Comparison | Result |
| --- | --- | --- |
| 9/7 overlap: planes 0 and 1 finished in the pool, plane 2 on all DWT workers | 107.8 -> 103.7 ms (11 rounds); t8 145.1 -> 139.3, t4 196.7 -> 197.9, t2 334.9 -> 328.4 ms | kept; plane 1's 19 ms serial job still overruns the pool by a few ms |
| Vector dequantization | t20 102.7 -> 103.1 ms, t1 594.2 -> 582.4 ms (9 rounds) | kept (bit-identical) |
| In-pool 9/7 on 4 / 8 threads | 103.7 -> 105.0 / 105.6 ms | rejected |
| Finish only plane 0 in the pool | 104.4 -> 106.6 ms | rejected |

Inverse colour worker cap (was four), `--timings` at t20 against
`9062bc0`, 11 runs: lossless RCT 2.06 / 1.68 / 1.92 ms and lossy ICT
5.28 / 4.16 / 3.19 ms with caps 4 / 8 / 16. Kept eight for the RCT paths
and sixteen for the float paths; end to end (11 rounds) 90.3 -> 88.5 ms
lossless and 103.3 -> 100.1 ms lossy.

Arena-backed block payload lists (multi-layer streams), against `599a4ee`
on the lossy profile: headers 5.12 -> 3.54 ms, finalize 1.46 -> 1.33 ms
(11 `--timings` runs); decode 100.9 -> 97.5 ms at t20 (11 rounds).

The lossy tail (plane 2 after the pool) measured at t20: clear 2.5 ms,
dequantize 2.0 ms, midpoint fix-up under 0.1 ms, parallel inverse 9/7
4.0 ms. A 9/7 worker cap of 12 / 16 left the stage at 8.46 / 8.53 ms
(8.59 at 8). Splitting the clear and dequantization by rows over eight
workers: stage 8.51 -> 5.52 ms (11 `--timings` runs), decode 99.1 ->
94.2 ms (11 rounds). Skipping the clear when the bands provably tile the
plane (so the page faults fall in band order instead of one sweep) was
slower, 93.7 -> 99.4 ms at t20 (11 rounds), and was dropped.

8-bit RGB decoded straight into the TIFF file buffer (no 16-bit
intermediate, no separate serialization), against `34abe84`, 11 rounds at
t20: lossless 89.2 -> 85.2 ms, lossy 96.6 -> 90.9 ms.

Thread scaling on the common lossless stream against Kakadu 8.4.1 (5
rounds): z2000 591.3 / 139.9 / 104.3 ms at t1 / t6 / t12, Kakadu 577.9 /
130.9 / 83.3 ms. The gap opens past six threads, where hyper-threaded and
efficiency cores join (z2000 1.34x from t6 to t12, Kakadu 1.57x); t14 /
t16 / t20 z2000 99.7 / 92.1 / 87.1 ms, Kakadu 76.6 ms at t14 and 72.6 ms
at t20 (7 rounds). Parallel positional writes of a 12.6 MB file from 4 or
8 threads were slower than one WriteFile (about 2.7 ms) in a standalone
probe.

Plane 1 of the lossy profile, placed adaptively (in the pool only while
its job fits the estimated remaining Tier-1 time), against `53117f3`, 7
rounds: t4 184.8 -> 182.0, t8 123.4 -> 124.6, t20 92.7 -> 90.7 ms;
always deferring it to the tail: t4 +3.0%, t8 +3.2%, t20 -3.1%.

## 2026-10-25: Intel Core i5-14500, 5/3 column strips; encoder probes

Same host, method, profile, and stream as the record below; base is
`4575cb6`. Stage times come from interleaved `--timings` runs (median of
nine). Every candidate decoded to the identical TIFF and wrote the
identical stream.

| Candidate | Comparison | Result |
| --- | --- | --- |
| Encoder: block copied contiguously before its coding passes | t1 encode 820.8 -> 822.9 ms (9 rounds) | +0.3%, rejected (locality was not the cost of `isMagnitudeBitSet`) |
| Encoder: RENORME shifting several bits up to the BYTEOUT point | t1 encode 829.7 -> 840.4 ms (9 rounds) | +1.3%, rejected (most renormalizations are one bit) |
| 5/3 column strips 16 columns wide | inverse DWT 32.79 -> 26.45 ms | -19.3% |
| 5/3 column strips 32 columns wide, then 8, then scalar | inverse DWT 32.13 -> 23.30 ms | -27.5%, kept |

End to end, 9 rounds each:

| Run | `4575cb6` | Candidate |
| --- | ---: | ---: |
| Decode t1 | 630.9 ms | 612.7 ms (-2.9%) |
| Decode t20 | 111.6 ms | 104.2 ms (-6.7%) |
| Encode t1 | 802.9 ms | 790.0 ms (-1.6%) |
| Encode t20 | 120.0 ms | 115.8 ms (-3.5%) |

## 2026-10-25: Intel Core i5-14500, cleanup pass and MQ renormalization

Same host, method, profile, and stream as the record below; base is
`44e754f`. Every candidate decoded to the identical TIFF and wrote the
identical stream.

| Candidate | Comparison | Result |
| --- | --- | --- |
| Cleanup: four column flag words read once, all-known columns skipped, indexes from the column base | t1 decode 718.8 -> 692.5 ms (9 rounds) | -3.7%, kept |
| MQ decoder: 64-bit C register with buffered bytes, one-shift RENORMD | t1 decode 673.8 -> 637.9 ms (9 rounds, vs the cleanup build) | -5.3%, kept |
| Raw (BYPASS) bit reader with a 64-bit buffer | t1 decode -1.3% (9 rounds), then +1.8% (11 rounds) | neutral, rejected |
| Encoder cleanup: all-known columns skipped | t1 encode 863.1 -> 814.7 ms (9 rounds) | -5.6%, kept |

Cumulative (decode 9 rounds, encode 7 rounds):

| Run | `44e754f` | Candidate | Grok 20.4.19 |
| --- | ---: | ---: | ---: |
| Decode t1 | 694.9 ms | 636.5 ms (-8.4%) | 617.4 ms |
| Decode t20 | 112.6 ms | 109.4 ms (-2.9%) | 117.2 ms |
| Encode t1 | 847.7 ms | 821.6 ms (-3.1%) | 790.9 ms |
| Encode t20 | 121.7 ms | 119.8 ms (-1.6%) | 137.4 ms |

The t1 decode gap to Grok 20.4.19 is 1.03x on this day's medians (1.26x
at `8764a89`); z2000 is faster at t20 in both directions.

## 2026-10-25: Intel Core i5-14500, single-thread T1 decode

Same host, method, profile, and stream as the 2026-10-24 record below
(interleaved A/B, medians; the common 6,636,048-byte z2000 lossless JP2).
Base is `8764a89`. Every candidate decoded to the identical TIFF and wrote
the identical stream; kept candidates also left the 34-bit wide stream's
bytes and exact decode unchanged.

Attribution came from `tools/win_sample_profile.zig` (instruction-pointer
sampling, about 1 kHz, six t1 decodes): Tier-1 held 91% of the samples,
with `readUnchecked` 15%, the context `setState` 7%, `refineMagnitude` 6%,
and the per-word neighbor updates of a newly significant sample 3%.

| Candidate | Comparison | Result |
| --- | --- | --- |
| Codeword registers in a local decoder copy per pass | 810.4 -> 813.3 ms (7 rounds) | +0.4%, rejected (LLVM already keeps them in registers) |
| Folded MQ contexts (one 8-byte copy per transition) | 795.3 -> 747.5 ms (7 rounds) | -6.0%, kept |
| Branch-free sign handling in `refineMagnitude` | 749.7 -> 759.0 ms (9 rounds) | +1.2%, rejected |
| Branch-free candidate mask per stripe column, `ctz` walk | 748.5 -> 775.8 ms (7 rounds) | +3.7%, rejected |
| Vector screening of 16 columns x 4 rows in significance propagation | 750.5 -> 803.8 ms (7 rounds) | +7.1%, rejected |
| Four-lane neighbor-row ORs for a newly significant sample (decode) | 726.3 -> 690.5 ms (9 rounds, vs folded) | -4.9%, kept |
| The same in the encoder | t1 encode 863.6 -> 849.2 ms (7 rounds) | -1.7%, kept |

The rejected screening candidates show that the scalar per-sample branches
of the significance and refinement passes are well predicted; their cost
is the MQ decisions and the flag and coefficient updates, not the scan.

Cumulative, 7 rounds each:

| Run | `8764a89` | Candidate | Grok 20.4.19 |
| --- | ---: | ---: | ---: |
| Decode t1 | 781.6 ms | 691.9 ms (-11.5%) | 621.0 ms |
| Decode t20 | 114.2 ms | 111.1 ms (-2.7%) | 115.7 ms |
| Encode t1 | 886.4 ms | 849.2 ms (-4.2%) | — |

The t1 decode gap to Grok 20.4.19 narrows from 1.26x to 1.11x on this
day's medians.

## 2026-10-24: Intel Core i5-14500, wide-path threading; Grok 20.4.19

### Provenance And Method

| Item | Value |
| --- | --- |
| Host | Intel Core i5-14500, 14 cores / 20 logical processors, Windows 11 Pro 10.0.26300 |
| z2000 | base `e0c24b2`; candidate = the commit recording this entry; Zig 0.17.0, ReleaseFast native |
| Grok | 20.4.19 (official `grok-windows-latest.zip` of the v20.4.19 release), with 20.4.14 and 20.4.12 beside it |
| Measurement | interleaved A/B: one warm-up per command, then rounds that run every command in turn; median and minimum wall time |

The host had other work running, which moved sequential `hyperfine` runs by
up to 20% between otherwise identical binaries. Interleaving spreads that
load over every candidate alike, so only same-table comparisons are made
below; absolute numbers move with the host's load on the day.

### Wide Path (34-Bit, i64 T1 And 5/3)

Input: a 72,000,124-byte ZRAW, three signed 34-bit 2000x1500 components;
`zraw-to-j2k` defaults (five levels, 64x64 blocks, one layer), 17,990,803 B
lossless stream. The candidate's output is byte-identical to the base for
that stream and for `--rates 20,5` (two layers), and the decode is exact.

| Run | Base `e0c24b2` median | Candidate median | Change |
| --- | ---: | ---: | ---: |
| Lossless encode t20 (5 rounds) | 8814.6 ms | 566.3 ms | -93.6% |
| Lossless encode t1 (3 rounds) | 8280.3 ms | 4521.3 ms | -45.4% |
| `--rates 20,5` encode t20 (5 rounds) | 12360.0 ms | 638.1 ms | -94.8% |
| Decode t20 (5 rounds) | 414.7 ms | 365.9 ms | -11.8% |
| Decode t1 (3 rounds) | 2108.3 ms | 2096.4 ms | -0.6% |

Steps on the way (t20 lossless encode): block-parallel T1 took the base from
8.36 s to 1.75 s; the threaded wide 5/3 moved decode from 520 to 453 ms;
one reused `BlockScratch` per worker then halved the encode again, and with
rates removed the second symbol generation. The t1 encode gain is the
allocation removal alone. Grok accepts only precisions 1..16, so it has no
leg on this profile.

### Main Lossless Profile Against Grok 20.4.19

Established archival profile (`bench_compare.ps1` commands: one 8192x8192
tile, RPCL, six resolutions, 256/128 precincts, 64x64 blocks, BYPASS,
SOP/EPH, R tile-parts, TLM) on `bench-rgb-2048.tif`; 7 rounds, z2000 at the
candidate. Every decode named here was pixel-exact against the TIFF; z2000
wrote 6,636,048 B and both Grok versions 6,635,216 B.

| Run | z2000 | Grok 20.4.19 | Grok 20.4.12 |
| --- | ---: | ---: | ---: |
| Encode t20 | 140.9 ms | 143.6 ms | 145.8 ms |
| Encode t1 | 931.0 ms | 836.0 ms | 796.3 ms |
| Decode t20, common z2000 stream | 127.2 ms | 123.7 ms | 95.0 ms |
| Decode t1, common z2000 stream | 814.9 ms | 634.1 ms | 620.7 ms |

Grok 20.4.19 decoded its own stream in 120.8/632.8 ms at t20/t1. A separate
11-round t20 decode of the common stream confirmed the version gap: z2000
124.2 ms, Grok 20.4.19 120.7 ms, 20.4.14 97.0 ms, 20.4.12 93.9 ms. Grok
20.4.19 is thus about 25% slower at t20 than 20.4.14 on this host and
profile while its t1 decode is unchanged; z2000 encodes faster than either
Grok at t20 and is within 3% of 20.4.19's t20 decode, but still 1.29x
slower at t1 decode. The main-path code did not change in this candidate.

## 2026-07-17: Apple M4, first native four-codec run (Kakadu on macOS)

### Provenance

| Field | Value |
| --- | --- |
| Date | 2026-07-17, 08:35-08:47 CEST |
| z2000 source | `64fe0f59` (main), clean worktree |
| z2000 version | `0.2.0-dev.460+g64fe0f59` |
| Build | Zig 0.16.0, `ReleaseFast`, native `aarch64-macos` |
| Host | MacBook Air `Mac16,12`, Apple M4, 4P+6E cores, 16 GB RAM |
| OS | macOS 26.5.2 (25F84), Darwin 25.5.0 |
| Power | **Battery power, 98% (not AC)** — treat as trend, not a gating run |
| Harness | Hyperfine 1.20.0, warmup 2 + 8 measured runs, `Z2000_THREADS=10` |
| References | Kakadu **8.4.1** (native macOS install, `/usr/local/bin`), Grok 20.3.6, OpenJPEG 2.5.4 |
| Input | `bench-rgb-2048.tif`, 12,583,052 B, SHA-256 `d8e3038c...3234e139` (pinned generator) |

The harness needed one fix before Kakadu would run at all: hyperfine executes
command strings through a brace-expanding shell on macOS, which rewrote
`Cblk={64,64}` into `Cblk=64 Cblk=64`. The Kakadu parameter values are now
single-quoted inside the command strings (this commit).

### Lossless archival profile (RPCL, 6 res, precincts, 64x64, SOP+EPH+TLM, BYPASS)

| Codec | Enc t1 | Enc t10 | Dec t1 | Dec t10 |
| --- | ---: | ---: | ---: | ---: |
| z2000 | 533.0 +/- 7.2 ms | 134.8 +/- 8.5 ms | 451.3 +/- 4.0 ms | 108.3 +/- 2.3 ms |
| Grok | 415.5 +/- 5.5 ms | 107.3 +/- 7.0 ms | 358.9 +/- 0.7 ms | 79.5 +/- 8.1 ms |
| OpenJPEG | 426.9 +/- 1.6 ms | 106.3 +/- 4.0 ms | 451.9 +/- 6.1 ms | 116.0 +/- 2.6 ms |
| Kakadu | 277.3 +/- 1.1 ms | 57.1 +/- 1.5 ms | 329.5 +/- 6.6 ms | 64.9 +/- 2.8 ms |

Cross-decode of the common z2000 stream: Grok 364.8/75.6 ms, OpenJPEG
453.4/115.5 ms, Kakadu 330.2/64.8 ms, z2000 455.5/111.2 ms (t1/t10).

Output sizes within 0.17%: z2000 6,636,048 B, OpenJPEG 6,636,085 B, Grok
6,635,206 B, Kakadu 6,624,994 B. z2000 t1==t10 deterministic; z2000
self-decode and Grok/OpenJPEG/Kakadu decode of the z2000 stream all lossless
— the first full four-codec verification chain on this machine.

### Lossy 9/7 (ICT, scalar quantization, 2 layers, complete final layer)

| Codec | Enc t1 | Enc t10 | Dec t1 | Dec t10 |
| --- | ---: | ---: | ---: | ---: |
| z2000 | 520.7 +/- 6.1 ms | 140.3 +/- 9.4 ms | 458.3 +/- 7.0 ms | 117.0 +/- 2.6 ms |
| Grok | 472.9 +/- 5.2 ms | 121.8 +/- 8.1 ms | 392.5 +/- 5.4 ms | 80.9 +/- 7.8 ms |
| OpenJPEG | 421.1 +/- 5.6 ms | 109.6 +/- 6.9 ms | 414.8 +/- 5.0 ms | 107.4 +/- 2.7 ms |
| Kakadu | 380.5 +/- 4.6 ms | 65.0 +/- 4.2 ms | 434.2 +/- 6.5 ms | 72.7 +/- 8.2 ms |

Lossy sizes: z2000 4,798,568 B (smallest), OpenJPEG 4,804,266 B, Kakadu
4,826,200 B, Grok 5,326,180 B. z2000 lossy t1==t10 deterministic.

### Reading

- **vs Kakadu (the new column)**: encode t10 2.36x, decode t10 1.67x, encode
  t1 1.92x, decode t1 1.37x. Kakadu's native NEON Part 1 path on the M4 is
  markedly faster than either open-source reference; this baseline is the
  target for the next optimization campaign iteration.
- **vs OpenJPEG**: lossless decode is now at parity at t1 (451.3 vs 451.9 ms)
  and ahead at t10 (108.3 vs 116.0 ms); encode trails by ~1.25x.
- **vs Grok**: encode t10 1.26x, decode t10 1.36x — consistent with the
  campaign-checkpoint floor recorded in `optimization_plan.md`.
- Battery-power caveat: absolute numbers may sit slightly off the AC-powered
  2026-07-13 baseline (e.g. z2000 t1 encode 533 vs 620 ms there is dominated
  by codec improvements since, not power state, but do not gate keep-rule
  decisions on this record).

## 2026-07-16: Kakadu 8.4.1 on Debian/WSL2; macOS package inspection

This checkpoint answers whether the additional Kakadu demo packages can join
the POSIX benchmark. The Linux applications passed a real lossless encode,
own-file decode, and common-stream decode. The macOS package was inspected but
has not yet been executed on macOS, so no macOS Kakadu timing is claimed.

### Provenance And Method

| Item | Value |
| --- | --- |
| Host | Intel Core i5-14500, 20 logical processors, Windows 11 host |
| Linux environment | Debian 12 container, Linux 6.6.87.2-microsoft-standard-WSL2, Docker Desktop engine 29.6.1 |
| Container image | `debian@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb` |
| Timed filesystem | 1 GiB container `tmpfs`; bind-mounted NTFS timings were rejected |
| z2000 source | `815d173`; codec code matches `v0.2.0-rc.1` (`7b8c01c`) |
| z2000 build | Zig 0.16.0, `ReleaseFast`, `-Dtarget=native`, built inside Linux tmpfs |
| Kakadu | 8.4.1 Linux x86-64 demo apps, J2K1+HTOPT |
| Kakadu archive | `KDU841_Demo_Apps_for_Linux-x86-64_231117.zip`, SHA-256 `5a1afd4b24d211798215d90b194b80cc397c221e75919cc145a691026e5c748d` |
| Measurement | Hyperfine 1.15.0, two warmups, eight runs; t1 and t20 |
| Input | `bench-rgb-2048.tif`, 12,583,052 B, SHA-256 `d8e3038ca752fab381d167783b797ebd64250a3f51c852437771180f3234e139` |

The lossless profile matches the 2026-07-16 Windows checkpoint: one 8192x8192
tile, RPCL, six resolutions, 256/128 precinct ladder, 64x64 blocks, one layer,
reversible RCT/5-3, BYPASS, SOP/EPH, resolution tile-parts, PLT/TLM where the
producer supports them. These Linux/WSL2 numbers are comparable only within
this record, not directly with native Windows or macOS records.

### Lossless Encode

| Codec | t1 mean +/- sd | t20 mean +/- sd | t1 / t20 speedup |
| --- | ---: | ---: | ---: |
| z2000 | 882.8 +/- 7.6 ms | 136.9 +/- 7.7 ms | 6.45x |
| Kakadu | 508.5 +/- 6.0 ms | 57.8 +/- 2.2 ms | 8.80x |

Kakadu was 1.74x faster at t1 and 2.37x faster at t20.

### Lossless Decode: Own Files

| Codec | t1 mean +/- sd | t20 mean +/- sd | t1 / t20 speedup |
| --- | ---: | ---: | ---: |
| z2000 | 787.7 +/- 19.3 ms | 116.2 +/- 1.0 ms | 6.78x |
| Kakadu | 540.9 +/- 11.3 ms | 49.7 +/- 3.4 ms | 10.88x |

### Lossless Decode: Common z2000 Stream

Both decoders read the same 6,636,048-byte z2000 JP2.

| Codec | t1 mean +/- sd | t20 mean +/- sd | t1 / t20 speedup |
| --- | ---: | ---: | ---: |
| z2000 | 767.7 +/- 13.0 ms | 122.7 +/- 3.6 ms | 6.26x |
| Kakadu | 523.7 +/- 9.8 ms | 58.6 +/- 2.6 ms | 8.94x |

Kakadu was 1.47x faster at t1 and 2.09x faster at t20 on the common stream.
This independently reinforces both active optimization targets: serial T1/MQ
cost and high-thread decode pipeline efficiency.

The z2000 t1/t20 streams were byte-identical (SHA-256
`5ffe4c5ce5665d32dc2092e4bedc83261cdce723442d62d91568f1bd2bb10cb1`).
Kakadu output was 6,624,994 B, matching the Windows Kakadu checkpoint exactly.
`tiffcmp` returned 0 for z2000 own decode, Kakadu own decode, and Kakadu decode
of the z2000 stream; Kakadu's TIFF writer only added a `SampleFormat` tag.
Raw Hyperfine JSON remains local under
`zig-out/kakadu-linux-native-bench-2026-07-16-wsl2-tmpfs/`.

### macOS Package Status

`KDU841_Demo_Apps_for_MacOS_231117.dmg_.zip` has SHA-256
`512ba55104b75b22c0cd49ad9b5264d4ca2d639701d26da5ba488253aba5069c`.
The DMG/PKG payload contains universal `arm64` + `x86_64` Mach-O builds of
`kdu_compress`, `kdu_expand`, and `libkdu_v84R.dylib`, installed by default
under `/Library/Kakadu/8.4.1`. Architecture inspection passed, but only a real
macOS run can validate code signing, dynamic loading, correctness, and timing.
Until that run exists, the earlier Apple M4 record remains unchanged and its
Kakadu row remains unavailable.

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

## 2026-07-15: Ryzen 7 5700X, 5/3 DWT worker cap — KEPT

Same host, corpus, and archival profile as the records above. The 9/7 driver
(`wavelet.zig`) already caps its DWT phase at eight workers because the wide,
short-lived bands are memory-bound and oversubscribing the 8-core/16-thread
host adds phase-spawn and SMT contention. The 5/3 driver (`wavelet_int.zig`)
still allowed up to 32, so the lossless inverse DWT *regressed* from 12.8 ms at
t8 to 17.3 ms at t16. Lowering its `max_dwt_workers` from 32 to 8 restores
t16 to t8 behaviour. T1 keeps the full caller thread count; only the DWT phase
is capped. Lossless codestreams and decoded pixels are byte-identical to the
uncapped build (SHA-256 encode `5FFE4C5C…`, decode `D8E3038C…`); the lossy 9/7
path is untouched.

Per-stage `--timings` at t16 (lossless): inverse DWT 17.3 ms -> 12.1 ms;
forward DWT (encode) 20.1 ms -> 18.2 ms.

Hyperfine, two warmups, twelve runs, `--threads 16` unless noted:

| Metric | Baseline (`=32`) | Candidate (`=8`) | Ratio |
| --- | ---: | ---: | ---: |
| Lossless decode t16 | 144.3 +/- 5.6 ms | 133.1 +/- 4.7 ms | 1.08x faster |
| Lossless encode t16 | 144.4 +/- 7.2 ms | 135.6 +/- 2.4 ms | 1.06x faster |
| Lossless decode t1 | 768.1 +/- 12.5 ms | 779.3 +/- 11.6 ms | 1.01x (tie) |

The t1 pair is a statistical tie: with one worker both builds take the
`@max(1, @min(1, 8|32))` = 1 path, so the code is identical and the 1.5%
difference is inside the combined noise. Lossy encode/decode were not re-timed
because the change does not touch the 9/7 path; those bands were already capped
at eight.

## 2026-07-15: Ryzen 7 5700X, 5/3 DWT persistent pool — KEPT

Follow-up to the worker cap above. The 5/3 driver still spawned fresh threads
for each of the ten DWT phases (two per level); the 9/7 driver had already
moved to a persistent barrier pool that spawns `worker_count - 1` workers once
and releases them per phase through a generation counter. This ports that pool
to `wavelet_int.zig` so both drivers share one design. Band splits are
unchanged, so lossless codestreams and decoded pixels stay byte-identical at
t1 and t16 (SHA-256 encode `5FFE4C5C…`, decode `D8E3038C…`); the lossy path is
untouched.

Per-stage `--timings`, lossless decode t16: inverse DWT 12.97 ms -> 9.50 ms
(the stage itself is ~27% faster; end-to-end it is diluted because the DWT is
under a tenth of the decode).

Hyperfine, three warmups, 14–20 runs, `--threads 16` unless noted:

| Metric | Baseline (per-phase spawn) | Candidate (pool) | Ratio |
| --- | ---: | ---: | ---: |
| Lossless encode t16 | 133.8 +/- 1.2 ms | 130.1 +/- 2.2 ms | 1.03x faster |
| Lossless decode t16 | 139.4 +/- 9.1 ms | 136.9 +/- 12.3 ms | 1.02x (noisy) |
| Lossless decode t1 | 753.5 +/- 6.1 ms | 759.4 +/- 9.8 ms | 1.01x (tie) |

Kept as a repeatable encode improvement with no regression on the other
profiles: encode t16 is a clean 2.8% with non-overlapping mean±sd, decode t16
trends the same way but the host was too noisy on the day to separate the ~2.5
ms signal from variance, and the t1 pair is the identical single-worker path.
The maintainability win — one pool design across both DWT drivers — carried the
borderline decode number.

## 2026-07-16: Intel Core i5-14500, v0.2.0-rc.1 comparative checkpoint

This is a new-host checkpoint, not a direct regression comparison with the
Ryzen 7 5700X records above. The source was `b96a819a`
(`0.2.0-dev.457+gb96a819a`); its only change after the tagged release commit
`7b8c01c` was post-release documentation. The codec code is therefore the same
as `v0.2.0-rc.1`.

### Provenance And Method

| Item | Value |
| --- | --- |
| Host | Intel Core i5-14500, 14 cores / 20 logical processors, 34,028,830,720 B RAM |
| OS | Windows 11 Pro 10.0.26200, build 26200 |
| Input | `bench-rgb-2048.tif`, 12,583,052 B, SHA-256 `d8e3038ca752fab381d167783b797ebd64250a3f51c852437771180f3234e139` |
| z2000 | `b96a819a`, Zig 0.16.0, ReleaseFast native |
| Grok | 20.3.6 |
| OpenJPEG | 2.5.4 |
| Kakadu | 8.4.1 demo applications, J2K1+HTOPT |
| Measurement | hyperfine 1.20.0, two warmups, eight runs; t1 and t20 |

The lossless profile is the established single 8192x8192 tile, RPCL, six
resolutions, 256/128 precinct ladder, 64x64 blocks, one layer, reversible
RCT/5-3, BYPASS, SOP/EPH, resolution tile-parts, PLT/TLM where the producer
supports them. Every self-decode and Grok/OpenJPEG/Kakadu decode of z2000 output
was pixel-exact. z2000 t1 and t20 output was byte-identical.

### Lossless Encode

| Codec | t1 mean +/- sd | t20 mean +/- sd | t1 / t20 speedup |
| --- | ---: | ---: | ---: |
| z2000 | 912.6 +/- 8.8 ms | 135.9 +/- 2.7 ms | 6.71x |
| Grok | 825.8 +/- 9.8 ms | 156.7 +/- 2.0 ms | 5.27x |
| OpenJPEG | 782.6 +/- 10.9 ms | 131.2 +/- 2.5 ms | 5.97x |
| Kakadu | 537.0 +/- 10.2 ms | 77.6 +/- 10.7 ms | 6.92x |

At t20, z2000 was 1.15x faster than Grok, 3.6% slower than OpenJPEG, and
1.75x slower than Kakadu. At t1 it remained slower than all three references.

### Lossless Decode: Own Files

| Codec | t1 mean +/- sd | t20 mean +/- sd | t1 / t20 speedup |
| --- | ---: | ---: | ---: |
| z2000 | 814.4 +/- 11.2 ms | 138.0 +/- 9.7 ms | 5.90x |
| Grok | 626.2 +/- 7.9 ms | 98.5 +/- 3.4 ms | 6.36x |
| OpenJPEG | 684.1 +/- 9.5 ms | 119.5 +/- 5.3 ms | 5.73x |
| Kakadu | 624.8 +/- 11.4 ms | 95.7 +/- 16.7 ms | 6.53x |

### Lossless Decode: Common z2000 Stream

All decoders in this table read the same 6,636,048-byte z2000 JP2.

| Codec | t1 mean +/- sd | t20 mean +/- sd | t1 / t20 speedup |
| --- | ---: | ---: | ---: |
| z2000 | 831.5 +/- 10.1 ms | 135.3 +/- 2.9 ms | 6.15x |
| Grok | 636.8 +/- 10.4 ms | 99.1 +/- 5.4 ms | 6.43x |
| OpenJPEG | 680.9 +/- 8.6 ms | 123.9 +/- 7.5 ms | 5.50x |
| Kakadu | 619.6 +/- 6.0 ms | 94.5 +/- 5.2 ms | 6.56x |

On the common stream, z2000 t20 decode was 1.37x slower than Grok, 9.2% slower
than OpenJPEG, and 1.43x slower than Kakadu. The t1 gaps were 1.31x, 1.22x, and
1.34x respectively. This keeps decode T1 cost and parallel pipeline efficiency
as the clearest performance target.

### Lossless Sizes

| Encoder | JP2 size | Difference from smallest |
| --- | ---: | ---: |
| Kakadu | 6,624,994 B | 0 B |
| Grok | 6,635,206 B | +10,212 B (+0.154%) |
| z2000 | 6,636,048 B | +11,054 B (+0.167%) |
| OpenJPEG | 6,636,085 B | +11,091 B (+0.167%) |

### Lossy 9/7 Checkpoint

The harness requests each tool's established irreversible two-layer profile,
but the outputs are not rate-distortion matched. Treat the timings as own-file
implementation measurements, not as a quality-normalized codec ranking. In
particular, Grok produced a larger file with materially lower PSNR on this
invocation.

| Codec | Encode t1 | Encode t20 | Decode t1 | Decode t20 | Size | PSNR / max diff |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| z2000 | 909.4 ms | 159.6 ms | 806.9 ms | 151.9 ms | 4,798,568 B | 52.58 dB / 3 |
| Grok | 929.0 ms | 178.5 ms | 659.8 ms | 115.4 ms | 5,326,180 B | 38.75 dB / 17 |
| OpenJPEG | 749.2 ms | 140.4 ms | 656.3 ms | 132.3 ms | 4,805,522 B | 52.57 dB / 3 |
| Kakadu | 534.9 ms | 83.9 ms | 622.0 ms | 84.0 ms | 4,826,199 B | 52.03 dB / 3 |

The original z2000 t20 lossy-decode sample contained one 719 ms outlier and
reported `238.7 +/- 194.5 ms`. A focused rerun with four warmups and twelve
runs was stable at `151.9 +/- 4.1 ms` (144.9--160.4 ms); that rerun is used in
the table. z2000 lossy t1 and t20 codestreams were byte-identical.

Raw hyperfine JSON and generated files are under
`zig-out/bench-compare-2026-07-16-i5-14500/` in the benchmark workspace.
