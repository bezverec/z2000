# Part 1 Corpus Gate

The broad JPEG 2000 Part 1 readiness gate is driven by
[`src/testdata/part1-corpus.json`](../src/testdata/part1-corpus.json). It is
separate from the two completed bounded scorecards: a corpus pass proves only
the rows and profiles named by its entries.

Run the committed corpus with the production strict decoder:

```sh
zig build part1-corpus
```

The runner verifies the SHA-256 of every input before extraction or mutation.
JP2 entries first pass strict container metadata validation. Each manifest
entry then selects the production `planar` or `interleaved_rgb` strict decoder
and reports these outcomes separately:

- `decode-pass` — decode succeeded and the canonical native-plane hash or
  declared PGX reference/tolerance oracle matches;
- `expected-fail-closed` — the declared unsupported profile returned the exact
  expected error;
- `unexpected-acceptance` — an expected unsupported profile decoded;
- `mismatch` — input, error, or native samples differ from the manifest;
- `skipped` — an optional local corpus root is unavailable.

Any unexpected acceptance or mismatch fails the command. Add
`-- --require-optional` when a release or conformance run must also fail if an
optional local corpus is unavailable.

## Official T.803 Profile-0 Corpus

The optional Part 4 layer is pinned to the
[official WG1 corpus](https://gitlab.com/wg1/htj2k-codestreams/-/tree/master)
commit `f6b9ede094a0bd6e1e0427e12721e3f3ee1b704b`. Its files are not copied into
this repository: `COPYRIGHT.txt` grants their use for JPEG 2000 standards
conformance/testing and requires retention of its notice, so the checkout
stays local under the ignored `.zig-cache` tree.

Set up the pinned checkout and run every optional entry in PowerShell:

```powershell
.\tools\setup_part1_corpus.ps1
$env:Z2000_PART4_ROOT = (Resolve-Path .zig-cache\part4\htj2k-codestreams).Path
zig build part1-corpus -- --require-optional
```

The 2026-07-22 gate contains 51 entries: 35 committed entries plus all 16
optional T.803 profile-0 inputs. All 16 original inputs and their 18 class-0
PGX references are independently checksummed. `p0_01`, `p0_02`, `p0_11`,
`p0_12`, `p0_16`, `p0_04`, `p0_09`, `p0_10`, and `p0_14` now pass their declared
references. The first five are exact reduction-0 cases; `p0_02` additionally
covers a
uniform full COC override, six LRCP layers, no-PLT inline SOP/EPH packets,
TERMALL+ERTERM+SEGMARK, component sampling, and reserved segment-less `FF30`;
`p0_11` covers a 128x1 NL=0 edge-clipped block, LRCP, PLT-less EPH, and
SEGMARK;
`p0_04` covers reduced 20-layer RLCP ICT/9-7 with component-specific
scalar-expounded QCC steps in pre-ICT codestream-component space,
`p0_09` covers reduced irreversible 9/7,
`p0_10` covers uniform 4x4-sampled RCT across interleaved PLT-less tile-parts,
and `p0_14` covers exact reduced reversible saturation. The `p0_01` result
also pins legal QCD-before-COD ordering. The other seven optional profiles
return their manifested fail-closed boundary. The complete result is therefore
33 decode passes, 18 expected fail-closed cases, zero mismatches, and zero skips
when the optional root is present.

Two additional committed passes are Kakadu 8.4.1 single- and four-tile signed
8-bit reversible/no-MCT codestreams. The corpus selects the native `i64`
decoder and compares Kakadu's signed PGX output exactly at full and reduction-1
resolution. The multi-tile oracle deliberately differs at reduction 1 because
each tile synthesizes its own low-resolution grid. Unit tests also pin legacy
planar/gray fail-closed behavior, invalid excessive reduction, and 1/8-thread
determinism.

The third native signed entry is a Kakadu five-component, four-tile stream.
All five components compare exactly at full and reduction-1 output (ten PGX
references total), while a four-component caller limit and the unchanged legacy
planar API reject it before sample allocation/reinterpretation.

The fourth native signed entry is a Kakadu 20-bit stream. Full and reduction-1
output compare byte-exactly with Kakadu PGX, including the signed extrema and
zero; 1/8-thread decoding is deterministic. Legacy planar decode still rejects
the stream. The native boundary is now pinned separately at 29/30 bits.

The fifth native signed entry combines 8-, 16-, and 20-bit components in one
Kakadu stream. All three native planes compare byte-exactly at full and
reduction-1 resolution, including each precision's extrema, and remain
deterministic at one and eight threads. A two-component caller limit and the
legacy planar API reject the stream without reinterpretation.

The sixth native signed entry is a Kakadu 19-component, four-tile stream. All
nineteen native planes compare byte-exactly at full and reduction-1 resolution;
an 18-component caller limit and the unchanged legacy planar API reject it.

The seventh native signed entry combines 5-, 12-, and 19-bit components. All
six full/reduction-1 PGX references match Kakadu byte-exactly, including the
sub-byte plane and every component's extrema. Together with the existing
8/16/20-bit stream it pins representative storage widths across the continuous
lower and intermediate widths of the continuous native payload contract.

The eighth native signed entry is a Kakadu 29-bit, four-tile stream. Full and
reduction-1 output compare byte-exactly with Kakadu PGX, including both signed
extrema, and 1/8-thread output is deterministic. It reaches the 31-magnitude-
bitplane T1/HH limit of the current `i32` carrier. Checked `i64` inverse 5/3
lifting intermediates fail overflow closed, and a 30-bit SIZ mutation pins the
unsupported wider boundary.

The ninth native signed entry combines 7-, 13-, and 23-bit components on
independent 16x16, 8x16, and 8x8 grids across four reference-grid tiles. All
six full/reduction-1 PGX references match Kakadu byte-exactly, one- and
eight-thread reductions agree, and canonical ZRAW round-trips the divergent
component layouts and signed samples exactly. The unchanged legacy planar API
rejects the stream.

The first G2 entry is a Kakadu ICT/9-7 stream whose component 0 inherits QCD
while components 1 and 2 carry distinct scalar-expounded QCC step tables. All
six full/reduction-1 output-component PGX references stay within peak 2 and
MSE 0.098, and one/eight-thread output is identical. A paired mutation changes
the first `Sqcc` to reserved style 3 and must fail with `InvalidCodestream`
before reconstruction.

The second G2 entry is a reversible single-tile no-MCT Kakadu stream with
effective component decomposition counts 3/2/1, component-sized precinct
lists, and matching QCD/QCC band tables. All six full/reduction-1 native PGX
references match exactly and one/eight-thread output is identical. Reduction
above the minimum component level, duplicate COC, and component-local transform
divergence fail closed; the latter is also a manifested mutation.

The third G2 entry keeps the same reversible single-tile no-MCT transform and
three decomposition levels while assigning component-local 4x4/default,
8x8/RESET, and 4x16/CAUSAL+SEGMARK code-block profiles. All six
full/reduction-1 PGX references match Kakadu exactly and one/eight-thread output
is identical. A reserved style bit is malformed; a manifested 64-wide local
block that would require general B.7 clamping remains fail-closed.

The fourth G2 entry is a four-tile reversible no-MCT Kakadu stream. Tile 1
replaces the main NL=2/4x4 COD and seven-band QCD with a first-tile-part
NL=1/8x8 COD plus its matching four-band QCD. Tile packet plans, component
coding/quantization tables, full synthesis, and reduced assembly consume the
effective state; all six PGX references are exact. A manifested mutation uses
the second COD occurrence to make the tile transform divergent and must fail
closed before packet reconstruction.

The fifth G2 entry keeps that four-tile main profile but changes only tile 1
component 1 through a first-tile-part NL=1/8x8 COC and matching four-band QCC.
The packet schedule, precinct state, T1 geometry, reduced catalog compaction,
and inverse 5/3 synthesis use the effective tile-by-component tables; all six
full/reduction-1 PGX references match Kakadu exactly. A manifested reserved-
Sqcc mutation is structurally invalid, while unit tests also pin excessive
reduction and component-local transform divergence.

The sixth G2 entry divides that profile into Kakadu RPCL resolution tile-parts.
Each tile has three non-empty PLT-backed parts followed by three empty padding
parts; the first-part COC/QCC state persists throughout the tile. Full and
reduction-1 output reuses and exactly matches the same six Kakadu PGX
references. The manifest's marker patch vocabulary now includes SOT, and a
paired mutation duplicates the fifth part's `TPsot` to pin checked per-tile
continuation ordering.

The seventh G2 decode gate deliberately remains a unit-test structural gate
rather than a new manifest entry. Kakadu supplies separate PLT-less one-part
and resolution-part COC/QCC codestreams; the test repacker moves only their T2
packet headers into one-part-per-tile PPM or multipart PPT+PLT. The unchanged
foreign T1 bodies match the same six full/reduction-1 PGX references exactly,
one/eight-thread output agrees, and shortened PPT/PPM segments fail closed.
Because Kakadu did not emit the packed framing, it is not counted among the
manifest's independent packed-header streams or the 51-entry corpus totals.
Both sources use Kakadu 8.4.1 with `Creversible=yes`, `Cycc=no`,
`Stiles={16,16}`, `Clevels=2`, `Corder=RPCL`, three 16x16 precinct levels,
4x4 main code blocks, `Clevels:T1C1=1`, `Cblk:T1C1={8,8}`, and one layer;
the multipart source adds `ORGtparts=R`. Neither source requests PLT or TLM.

The eighth G2 entry is independently emitted by Kakadu rather than structurally
repacked. Its four-tile no-MCT 9/7 stream starts with main Qstep 1/256, replaces
tile 1 with Qstep 0.01 through QCD, and replaces component 1 in that tile with
Qstep 0.02 through QCC. Six full/reduction-1 PGX references pin effective
tile-by-component dequantization with peak error at most one and measured MSE
at most 0.125. A paired manifest mutation changes the tile QCC from scalar-
expounded style two to reserved style three and fails before packet decode.

The first reduced-resolution production slice now reconstructs bounded
single-tile reversible 5/3 no-MCT streams directly from the requested DWT
level, with precision saturation and checked reduced dimensions. The runner
passes each reference's reduction selector to the production decoder. The
bounded reduction path now also covers sampled reversible 5/3 across
single- and multi-tile streams plus native-planar no-MCT 9/7 for bounded
single- and sampled multi-tile streams. The committed Kakadu four-tile 9/7
entry compares every component at full and reduction-1 output against six PGX
references with peak <= 1 and MSE <= 0.12. T.803 `p0_04`, `p0_09`, and
`p0_14` exercise those reduced paths;
the remaining reduced references still require signedness, RGN, or divergent
component coding styles.
Class-1 all-component comparison can reuse the reference-list oracle as G1 and
G2 remove those boundaries.

## Manifest Policy

Each entry records its producer, version, origin, licence, redistribution
status, optional reproduction command, expected-result oracle, input checksum,
capability rows, input format, strict decoder, and expected result. A decode
pass may pin either the canonical native hash or a list of PGX `references`,
each with its own checksum, component index, resolution reduction, peak-error
limit, MSE limit, and explicit `space`: normal output components after MCT or
codestream components before inverse MCT. The PGX reader accepts big- or little-endian signed and
unsigned integer samples from 1 through 31 bits, and evaluates peak error and
MSE independently. Multiple component and reduction records are represented
without ambiguity. The runner decodes each reference at its declared
reduction; non-zero-reduction references whose inputs remain expected
fail-closed are still fetched and checksum-verified, never silently compared
to full-resolution samples.
Committed assets must be redistributable. A corpus whose binary files cannot
be committed may still have an `optional` manifest entry with a relative
`path` and a `root_env` such as `Z2000_PART4_ROOT`; the runner joins the path
under that environment-provided root without copying the asset into the
repository. Absolute paths and parent traversal are rejected.

Part 4 or independent sample values take priority over agreement between
decoders. OpenJPEG, Grok, and Kakadu disagreements must be recorded rather
than resolved by selecting one convenient raster.

## Native Hash Version 1

`expected_native_sha256` hashes the exact component planes, not a converted
RGB/TIFF raster. The byte sequence begins with
`z2000-part1-native-v1\0`, followed by big-endian reference width, reference
height, and component count. Each component then contributes its bit depth,
big-endian width, height and sample count, followed by its unsigned `u16`
samples in big-endian order.

The interleaved RGB decoder is canonicalized into the same component-major
sequence before hashing. It therefore produces the same hash as an equivalent
three-plane decode; TIFF layout, metadata, and row serialization never enter
the digest.

This hash version deliberately remains the unsigned `u16` canonical form used
by legacy planar/interleaved entries. Signed or wider native entries use exact
PGX references instead, so adding the 20-bit slice does not reinterpret v1. A
future native hash format must use a new version tag.

`zig build part1-corpus -- --bless` only prints observed hashes. It does not
edit the manifest. Before copying a hash into the manifest, compare the samples
with the source planes, a Part 4 expected result, or an explicitly documented
independent oracle.

## Adding A Case

1. Add or reuse a capability row in the manifest.
2. Record exact provenance and redistribution status; keep unclear binaries
   local.
3. Pin the unmodified input SHA-256 and the expected error, native hash, or
   PGX reference list with checksums, component/reduction selectors, and exact
   or tolerance-based limits.
4. Add a malformed or expected-unsupported counterpart where applicable.
5. Run the corpus gate in Debug and ReleaseFast and update
   `iso_coverage.md`, `next_steps.md`, and `changelog.md` when the public
   boundary changes.
