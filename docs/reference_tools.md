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

Versions measured: **Kakadu 8.4.1**, **OpenJPEG 2.5.4**, **Grok 20.3.6**.

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
- **Grok refuses JP2-wrapped subsampled sRGB.** Grok 20.3.6 rejects any
  JP2-wrapped subsampled stream whose `colr` box declares sRGB, on the grounds
  that sRGB mandates uniform sampling. Those fixtures are committed as raw
  codestreams so all three references can read them.
- **Grok fails on collapsed resolutions.** Grok 20.3.6 does not decode a tile
  grid anchored away from the image origin that leaves an edge tile whose
  deepest resolution is empty in one axis. Kakadu and OpenJPEG do.

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

## Sweeps Run And What They Found

Each sweep generated foreign streams over one axis of the format and put every
one through strict decode. The value is in the misses, so the misses are named.

| Sweep | Streams | Result |
| --- | --- | --- |
| Tile-part divisions: every `ORGtparts` value and combination x five progression orders x single-tile and 2x2 x with/without TLM, each combined-division stream then repacked as PPM, PPT, and TLM | 160 | 159 decoded. The miss was the single-tile PLT path accepting only one part or one part per resolution. |
| `Cmodes` bits x tile-part divisions | 24 | `BYPASS` failed at every division; `RESTART` masked it. Led to the two bypass defects below. |
| Arithmetic bypass: mode combinations x block sizes x 1..8 layers x reversible/irreversible x tiled/untiled, from all three producers | 40+ | Two defects: a terminated codeword segment spanning a quality layer, and blocks truncated by rate allocation. |
| Image origin x tile-grid origin x 0..2 decomposition levels | 15 | One miss, and only at two levels: an edge tile whose lowest resolution collapses. Tile-grid origins themselves were never the problem. |
| Collapsed geometry x reversible/irreversible x MCT/no MCT x 2..4 levels x subsampled | 14 | Reversible passes everywhere. Irreversible 9/7 fails with `InvalidDimensions` — the float synthesis still needs the descent change the 5/3 path received. |

The recurring pattern across all of them: **a gate is narrow only until something
other than our own encoder writes to it.** Of the boundaries probed, most opened
cleanly once an oracle confirmed the stream was sound.

## Methodological Cautions

- **Container acceptance is not decode evidence.** `jp2-info` validating a
  file's boxes says nothing about whether the codestream decodes. Two multipart
  POC streams were reported as accepted on that basis and then turned out to be
  rejected by full decode.
- **A fixture covers a bit, not a behaviour.** The all-six-style-bits fixture
  sets `BYPASS`, but it also sets `RESTART` and is lossless — so it never
  produced a multi-pass codeword segment and never truncated a block, and both
  bypass defects survived it for months.
- **Check the tool's own reader.** Two of the findings above are a producer
  disagreeing with itself; neither would have surfaced from cross-checking
  different vendors alone.
