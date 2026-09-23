# Reference Tool Behaviour

Empirical notes on the three reference implementations used as oracles for the
Part 1 corpus. Everything here was measured on this project's fixtures, not
taken from documentation, and each item names the version it was measured on.

Why a separate document: these observations decide which oracle a corpus entry
can use and which profiles can be evidenced at all, but they are scattered one
sentence at a time through [`changelog.md`](changelog.md), where they are hard
to find when a new sweep hits the same wall. The
[changelog](changelog.md) remains the chronological record; this file is the
lookup table.

Versions measured: **Kakadu 8.4.1**, **OpenJPEG 2.5.4**, **Grok 20.3.6**, and
where stated **Grok 20.4.12** (re-measured on the same files).

## What The Producers Cannot Emit

A missing writer is why several capabilities have no independently produced
fixture. These are tooling limits, not gaps in this project.

| Feature | Status |
| --- | --- |
| `PLM` | None of the three ships a writer. OpenJPEG and Grok offer only PLT and TLM. Independently emitted `PLM` evidence is blocked. |
| Position tile-parts (`P`) | `kdu_compress ORGtparts` accepts only `R`, `L`, `C` and `\|` combinations of them; passing `P` is a parse error. Position tile-parts are covered only by z2000's own writer. |
| Packed headers without SOP/EPH | `kdu_makeppm` refuses a source codestream that does not use SOP/EPH markers: it cannot recover packet boundaries otherwise. Any PPT/PPM fixture must be repacked from a SOP/EPH source. |

## Layouts The Producers Choose

Legal choices that differ between implementations. Each one was a narrow gate in
this decoder until an independently emitted stream exercised it.

- **PLT placement.** Kakadu and OpenJPEG write one PLT per tile-part covering
  only that part. Grok `-u R --plt` writes **one PLT in each tile's first
  tile-part listing the whole tile's packet lengths**, and none in the later
  parts. Both are accepted; see the tile-level PLT carry in `codestream.zig`.
- **PPT placement.** `kdu_makeppm -ppt` writes **one PPT per tile**, in the
  tile's first tile-part, holding that whole tile's packed headers — four PPT
  segments for thirty-six tile-parts in the reproduced case. Its PPM mode
  instead writes one `Nppm` group per tile-part.
- **Deferred tile-part counts.** `kdu_compress ORGtparts=R` on a single tile
  leaves `TNsot` zero until the last tile-part (ISO A.4.2's "not signalled in
  this part"). A decoder that demands a count in every part rejects every
  single-tile multipart Kakadu stream.

## Producer Defects And Self-Inconsistency

Recorded rather than worked around, so the behaviour stays pinned.

- **`kdu_makeppm` leaves stale `Psot`.** Given a source carrying PLT, Kakadu
  8.4.1's `kdu_makeppm` removes the PLT segments but does not shrink each
  tile-part's `Psot`, so every part overstates its length by exactly the bytes
  it dropped — 34 per part in the reproduced case. Rejecting that stream is
  correct; it is committed as the fail-closed entry
  `kakadu-makeppm-stale-psot`.
- **`kdu_expand` refuses `kdu_compress` output.** `kdu_compress ORGgen_plt=yes
  ORGtparts=R\|L\|C` on a single tile writes 27 tile-parts whose PLTs each sum
  exactly to their own SOD body. `kdu_expand` on that file exits `-1` with
  "Unexpectedly ran out of packet length information while processing
  tile-parts". OpenJPEG, Grok, and z2000 all reconstruct the raster. Committed
  as the decode entry `kakadu-singletile-rlc-tileparts-plt`.
- **`opj_compress` drops packets from an overlapping POC schedule.** Given
  `-POC T1=0,0,1,3,3,LRCP/T1=0,0,3,3,3,RPCL` (layer 0 of everything, then
  everything), OpenJPEG 2.5.4 writes 25 packets per tile instead of 27:
  re-encoding with `-SOP` shows 225 markers where 9 tiles x 27 need 243.
  ISO B.12 only skips packets an earlier volume already sent, so the tile
  bodies are short. `kdu_expand` and `opj_decompress` decode the file without
  a word; z2000 rejects each tile as incomplete. Committed as the fail-closed
  entry `openjpeg-poc-overlap-missing-packets`. The same command with
  non-overlapping volumes writes all 243 and decodes exactly everywhere.
- **`opj_compress` writes out-of-range POC records as given.** Asked for a
  resolution end of 6 on a three-resolution stream, it writes REpoc=6 rather
  than clamping or refusing. z2000 and the JP2 audit reject the record;
  `kdu_expand` tolerates it. (`-n` is the resolution count, not the layer
  count, which is how the request came about.)
- **`grk_compress` writes an ROI shift below the background's bit-planes.**
  `-R c=0,U=6` on 8-bit RGB produces a Maxshift stream whose shift is
  smaller than the background's magnitude bit-plane count, so ROI and
  background coefficients overlap and nothing can separate them (ISO E.3.3
  puts that requirement on the encoder; `kdu_compress` refuses the same
  request with "too small a value for the ROI up-shift"). Grok 20.4.12
  writes it anyway. The decoders then disagree with each other: Kakadu is
  40 percent of samples from the source, OpenJPEG and Grok 91 percent, and
  Kakadu differs from OpenJPEG on 64 percent. With RCT, z2000's complete
  decode meets samples outside the range in the inverse RCT and fails
  closed, committed as `grok-roi-shift-below-bitplanes`; without MCT, or
  in grayscale, z2000 equals Kakadu exactly on the same broken input. Shifts
  of 9 and 12 decode exactly through every decoder.
- **Grok misdecodes multi-tile PPM.** `grk_decompress` 20.3.6 and 20.4.12
  both return wrong pixels for every multi-tile stream with main-header
  packed packet headers that was tried: eight z2000 `--ppm --tile-parts R`
  layouts (2x2 and 3x3 grids, one to three layers, one to five levels, with
  and without TLM; 75 to 87 percent of samples wrong, or "Tile N is corrupt"
  with SOP/EPH or five levels on 3x3; on the 3x3 PPM with SOP/EPH, 20.4.12
  never finishes and has to be killed, where 20.3.6 exits 0 with wrong
  pixels) and three committed Kakadu
  `kdu_makeppm` fixtures (`kakadu-native-ppm-multitile`, `-tlm`, and
  `kakadu-poc-multipart-ppm`; half to all samples wrong, exit 0). Single-tile
  PPM is exact, as is every PPT layout. Kakadu and OpenJPEG decode all of
  them exactly. An earlier note in `iso_coverage.md` reported Grok 20.3.6
  exact on a 16-tile PPM smoke; that result was not reproduced here and
  should not be relied on.
- **Grok refuses JP2-wrapped subsampled sRGB.** Grok 20.3.6 rejects any
  JP2-wrapped subsampled stream whose `colr` box declares sRGB, on the grounds
  that sRGB mandates uniform sampling. Those fixtures are committed as raw
  codestreams so all three references can read them. Grok 20.4.12 refuses
  them as well, including a Kakadu-written JP2 whose `colr` says sRGB.
- **`kdu_expand` fails when reduction empties an edge tile.** On a stream
  whose tile grid leaves a one-sample edge column, `kdu_expand -reduce 2`
  (and `-reduce 3`) exits 127 without an error message and writes empty
  files. OpenJPEG 2.5.4 decodes the same stream at every reduction. Committed
  as `kakadu-reduced-edge-column` with OpenJPEG references. Check the exit
  status and output size: this failure is silent.
- **Multithreaded `kdu_expand` crashes intermittently on layer-limited decode.**
  On 48x40 RGBA streams over 19x23 tiles at image origin (5,3), `kdu_expand
  -layers 1` segfaulted in 4 of 20 runs of the same file (RLCP; CPRL also
  crashed once). With `-num_threads 0` it crashed in 0 of 20. Generate
  reference output single-threaded, and check the exit status.
- **Grok 20.3.6 misdecodes collapsed resolutions.** On a tile grid anchored
  away from the image origin that leaves an edge tile whose deepest resolution
  is empty in one axis (`kakadu-tile-origin-empty-resolution` and its 9/7
  twin), `grk_decompress` 20.3.6 exits 0 and writes wrong pixels: 510 and 700
  samples off by the full range. Kakadu and OpenJPEG decode them. Grok
  20.4.12 fixes it: the reversible file is exact and the 9/7 one is within one
  LSB. An earlier note here said 20.3.6 "does not decode" the stream; it
  decodes and is wrong, which is worse, so check pixels and not exit codes.

## Reconstruction Spread

Lossy 9/7 reconstruction differs between conforming decoders, so a lossy fixture
cannot be pinned against a reference hash. Measured on
`kakadu-bypass-lossy-truncated` (32x32, 3072 samples):

| Pair | Differing samples | Peak error |
| --- | --- | --- |
| z2000 vs Kakadu | 209 | 1 LSB |
| z2000 vs OpenJPEG | 3 | 1 LSB |
| Kakadu vs OpenJPEG | 211 | 1 LSB |

z2000 sits inside the spread the two references already show against each other.
Lossy corpus entries therefore pin z2000's own deterministic output and record
the measured spread in their oracle field.

Reversible streams have a spread of their own once they are truncated. A
one-sample 5/3 line at an odd origin is a lone high-pass coefficient,
reconstructed as Y/2. A complete stream always carries an even Y there; a
quality-layer prefix does not. Kakadu 8.4.1 floors the halving and OpenJPEG
2.5.4 truncates it toward zero. On `kakadu-odd-origin-layers` (48x40 on 19x23
tiles at image origin (5,3)) that is the *entire* difference between them: 24
samples at two layers and 94 at three. Swapping z2000 between the two roundings
moves it from exact-against-one to exact-against-the-other. z2000 floors, like
Kakadu.

## Sweeps Run And What They Found

Each sweep generated foreign streams over one axis of the format and put every
one through strict decode. The value is in the misses, so the misses are named.

| Sweep | Streams | Result |
| --- | --- | --- |
| Tile-part divisions: every `ORGtparts` value and combination x five progression orders x single-tile and 2x2 x with/without TLM, each combined-division stream then repacked as PPM, PPT, and TLM | 160 | 159 decoded. The miss was the single-tile PLT path accepting only one part or one part per resolution. |
| `Cmodes` bits x tile-part divisions | 24 | `BYPASS` failed at every division; `RESTART` masked it. Led to the two bypass defects below. |
| Arithmetic bypass: mode combinations x block sizes x 1..8 layers x reversible/irreversible x tiled/untiled, from all three producers | 40+ | Two defects: a terminated codeword segment spanning a quality layer, and blocks truncated by rate allocation. |
| Image origin x tile-grid origin x 0..2 decomposition levels | 15 | One miss, and only at two levels: an edge tile whose lowest resolution collapses. Tile-grid origins themselves were never the problem. |
| Collapsed geometry x reversible/irreversible x MCT/no MCT x 2..4 levels x subsampled | 14 | Reversible passed everywhere; irreversible 9/7 failed with `InvalidDimensions`. Fixing the descent alone made it decode at a peak error of 81 LSB — the second, larger defect was a one-sample odd-origin span left unhalved. |
| Tile width 2..32 x 1..3 decomposition levels, irreversible 9/7 at the reference-grid origin | 27 | All within one LSB after both float-synthesis fixes; before them, every width that puts a tile at an odd column was rejected at two or more levels. No tile-grid origin offset needed to reach the defect. |
| Tile shapes 1x1 .. 13x13 x image origin 0 and (3,7) x both transforms x 1..3 levels | 120 | All 120 decode. 107 are exact or within one LSB; the remaining 13 are the small-by-small 9/7 drift below. The twelve initial rejections were the 1x1 grid hitting the container's since-lifted 256-tile bound. |
| Bit depth 1..16 x signed/unsigned x reversible/irreversible, one component from Kakadu raw input, decoded through `j2k-to-pgx` | 48 | Reversible: all 24 lossless-exact. Irreversible: all 24 rejected, because the native decoder had no 9/7 path. After adding it, all 24 are within one LSB of `kdu_expand`. |
| Tile height 2..32 x width 2..32, irreversible 9/7, one level | 49 | Initially 2-3 LSB in the small-by-small corner. The cause was the midpoint offset being added twice at dequantization, not synthesis precision. After that fix every cell is within one LSB. |

The recurring pattern across all of them: **a gate is narrow only until something
other than our own encoder writes to it.** Of the boundaries probed, most opened
cleanly once an oracle confirmed the stream was sound.

## Known Divergences From The References

Measured gaps where z2000 is outside the reference-versus-reference spread, kept
here so they are not rediscovered as new.

- *(Resolved; diagnosis below was wrong.)* The drift was the midpoint offset
  being added twice for coefficients whose code block stopped before the end
  of bitplane zero, not boundary precision. Kept for the record:
- **Small-by-small tiles in irreversible 9/7.** When both tile dimensions are
  small the reconstruction drifts past the one-LSB band the references hold to
  each other: 2 LSB for tiles up to roughly 4x5, and 3 LSB at 2x3. The
  distribution is diffuse rather than structural — on a 2x3 tiling of the 32x32
  fixture, 5 samples of 3072 exceed one LSB (four at 2, one at 3), while 664
  differ by exactly one against Kakadu, where Kakadu and OpenJPEG differ from
  each other on 163. Both references stay at one LSB throughout, so this is
  z2000 losing more precision in the mirrored boundary terms, not reference
  spread. Long spans in either axis are unaffected.
- **`grk_decompress` misreconstructs tiled 9/7.** Irreversible JP2s from
  `grk_compress -I -r 20,10,1` (96x80 RGB, grayscale, RGBA, gray+alpha) and
  from `kdu_compress -rate 2` decode through Kakadu, OpenJPEG, and z2000 to
  within one LSB of each other (z2000 versus OpenJPEG: 3 to 28 samples).
  `grk_decompress` 20.3.6 on the same files lands 2 LSB away untiled and up
  to 29 LSB away on 32x32 tiles, whoever encoded them, and is further from
  the source (PSNR 29.8 dB against 33.9 dB for Kakadu and z2000 on Grok's own
  tiled RGB file). Reversible streams, tiled or not, are exact. Do not use
  `grk_decompress` 20.3.6 as a 9/7 oracle on tiled streams. Grok 20.4.12
  brings the same files to within one LSB untiled and two LSB on tiles, but
  still differs from Kakadu on 40 to 50 percent of samples (3642 of 7680 on
  the tiled RGB file) where z2000 differs from Kakadu on 30 percent and from
  OpenJPEG on 0.3 percent; a coarse oracle at best.
- *(Resolved in Grok 20.4.12; a Grok defect, not ours.)* A dense two-volume
  POC (layer 0 of everything in LRCP, then everything in RPCL) from z2000's
  `--poc`, tiled or not, and Kakadu's equivalent `Porder` file decode exactly
  through Kakadu and OpenJPEG. Grok 20.3.6 misdecoded all three (7441 to 7673
  of 7680 samples wrong); Grok 20.4.12 decodes all three exactly. The
  committed Kakadu POC fixtures (`kakadu-poc-sop-eph-multitile-inline`,
  `kakadu-poc-layer-tileparts`) were exact in both versions. Subsampled POC
  rasters (`kakadu-sampled-poc-*`) still disagree with Kakadu's in 20.4.12,
  as they did in 20.3.6, so that claim stands.
- *(Resolved.)* Irreversible ROI was 2 LSB out because ROI components skipped
  the per-block midpoint rule and took the offset twice. On the Kakadu ICT
  ROI stream (`Rshift=14 -rate 2`, 32x32 tiles) Kakadu and OpenJPEG differ on
  2497 of 7680 samples by one LSB; z2000 now differs from Kakadu on 2500 and
  from OpenJPEG on 144, all by one LSB.
- *(Resolved.)* The container audit's fixed 256-tile and 4096-`TLM`-entry
  bounds are gone; a Kakadu stream with 1024 tiles and 5120 TLM-listed
  tile-parts decodes. Kakadu's `ORGgen_tlm=N` caps tile-parts *per tile* at N
  and aborts when padding would exceed it.

## Methodological Cautions

- **Fuzz the fixtures, not just the profiles.** `tools/fuzz_fixtures.py`
  mutates every committed codestream and expects an error, never a panic or
  a hang. Its first run found a SIZ that walks a 2^53-tile grid for ever, a
  case no producer would write and no profile sweep would reach. Run a fresh
  seed after touching header parsing.
- **Container acceptance is not decode evidence.** `jp2-info` validating a
  file's boxes says nothing about whether the codestream decodes. Two multipart
  POC streams were reported as accepted on that basis and then turned out to be
  rejected by full decode.
- **A fixture covers a bit, not a behaviour.** The all-six-style-bits fixture
  sets `BYPASS`, but it also sets `RESTART` and is lossless — so it never
  produced a multi-pass codeword segment and never truncated a block, and both
  bypass defects survived it for months.
- **A relaxed gate is not a fix.** Opening the irreversible 9/7 descent made
  previously rejected streams decode at a peak error of 81 LSB, where the two
  references agree to within one. Committing that would have traded a clean
  rejection for silently wrong pixels. Measure against a reference before
  treating "it decodes now" as progress.
- **Verify a "precision" diagnosis before recording it.** The small-tile 9/7
  drift was first written up as boundary precision because the difference was
  diffuse. A direct comparison of the synthesis against an independent ISO
  implementation took minutes and ruled that out, which pointed the search at
  dequantization, where the real defect was.
- **Kakadu geometry parameters are `{y,x}`.** `Sorigin`, `Stile_origin`,
  `Stiles`, `Sdims`, and `Cblk` all list the vertical value first. Reading them
  as `{x,y}` put the one-sample edge column in the wrong axis and made a real
  failure look unreproducible.
- **Do not feed signed PGX into OpenJPEG.** OpenJPEG 2.5.4's PGX *reader*
  misparses signed headers: `PG ML -8` became signed 7-bit and `-4` became
  unsigned 13-bit, which surfaced as z2000 "defects" that were really
  mis-encoded sources. Use Kakadu's raw input (`Sdims`, `Sprecision`,
  `Nprecision`, `Ssigned`, `Nsigned`) for signed sweeps. OpenJPEG's PGX
  *output* is fine.
- **Check the tool's own reader.** Two of the findings above are a producer
  disagreeing with itself; neither would have surfaced from cross-checking
  different vendors alone.
