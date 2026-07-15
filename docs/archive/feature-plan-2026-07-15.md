# Feature Plan — Components, Color Spaces, and Formats

> Archived on 2026-07-15 after PR #157. This is historical campaign context,
> not an active queue. Use [`../next_steps.md`](../next_steps.md) for current
> implementation order and [`../roadmap.md`](../roadmap.md) for strategy.

Companion to `docs/roadmap.md` (direction) and `docs/next_steps.md` (the only
ordered work queue). The completed multi-tile and SIMD campaign plans are
preserved under `docs/archive/`; this plan reuses their staged, gated style. It
turns the post-Part 1 conversion backlog into concrete stages with
dependencies, sizes, and verification requirements.

## Baseline (2026-07-13, scorecard 100/100)

Already public and interop-verified:

- RGB, 3 components, 8/16-bit: TIFF <-> JP2, RCT + reversible 5/3 and
  ICT + irreversible 9/7, single-tile and bounded multi-tile, rate targets,
  all code-block styles, POC/PPM/PPT, restricted ICC preservation.
- Grayscale, 1 component, 8/16-bit: no-MCT reversible path, enumerated
  `colr` 17, identity `cdef`, OpenJPEG/Grok pixel-exact both directions.
- Bounded palette: one 8/16-bit index component + three uniform sRGB `pclr`
  columns + identity `cmap`, checked expansion, OpenJPEG/Grok interop.
- Metadata containers: top-level `xml `/`uuid`/`uinf` pass-through,
  multiple `colr` selection, validated `res ` boxes.

## Ground rules (inherited)

1. Fail closed: an option whose payload/semantic behavior is not implemented
   is rejected, never silently approximated.
2. Every stage lands with a strict local roundtrip **and** at least one
   independent-decoder interop check (OpenJPEG/Grok/Kakadu are on the
   benchmark box).
3. The existing RGB and grayscale paths stay byte-identical at every stage
   (regression-gated in tests, like the multi-tile campaign kept the
   single-tile path byte-identical).
4. New input/output formats enter through explicit modules under
   `src/formats/` with their own fail-closed parsers and fuzz coverage —
   never through ad hoc branches inside T1/T2 (`docs/architecture.md` rule).
5. Color *management* (ICC-driven conversion between spaces) belongs to the
   conversion-tool layer, not the codec core. The codec stores and signals;
   the tool converts.

## Stage F1 — component-generic core (the enabling refactor)

**What:** replace the fixed 3-plane `color.RctPlanes` (y/cb/cr, ~87 call
sites) and `tile_pipeline.component_count = 3` with an N-plane
representation; generalize SIZ/COD/QCD/T2 component loops. Bound the public
surface to 1..4 components first (grayscale=1 and RGB=3 already exist as
special cases that must reduce to today's byte-identical output).

**Why first:** alpha (F2), mixed precision (F3), CMYK (F4), and most format
work (F5) all sit on top of it. The grayscale path proved the per-component
machinery works; F1 unifies instead of adding a third parallel pipeline.

**Size/risk:** LARGE / HIGH — this is the next multi-PR campaign, on par
with multi-tile. Stage internally: (a) representation swap with 3-component
behavior byte-identical — **landed 2026-07-14**: `color.RctPlanes`/`IctPlanes`
are now instances of the generic `ComponentPlanesOf(Sample)` N-plane carrier
(`planes: [][]Sample`, bounded by `color.max_components = 4`), all fixed
y/cb/cr field access is gone across color/codestream/tile_pipeline, the tile
decode scaffold sizes its carrier by the actual component count instead of
allocating empty cb/cr, and six encode profiles (lossless, 9/7 lossy,
multi-tile, layered LRCP, BYPASS+TERMALL, t10) plus lossy/lossless decode and
grayscale are byte-identical to the pre-change binary with t10 perf neutral;
(b) 1-component rides the same code — **first slice landed 2026-07-14**: the
duplicated single-tile codestream assembly (SIZ/COD/QCD/POC/TLM/PPM main
header, tile-part SOT/POC/PLT/PPT/SOD/packet loop, EOC) is now one
component-count-generic `assembleSingleTileCodestream`, used by both the RGB
and grayscale encoders with byte-identical output across ten profiles
(including PPM, PPT, CPRL, multi-tile, and layered grayscale); the tile
scaffold engine was already shared. **(b) completed 2026-07-14**: the grayscale
encoder, decoder, and tile builder are one-plane delegates of the planar
path — no parallel plumbing remains. **(c) landed 2026-07-14**: bounded 2-
and 4-component no-MCT layouts are public at the codestream API level
(`color.SamplePlanes`, `encodeLosslessPlanarWithOptions`,
`decodeLosslessPlanar`), with synthetic roundtrips, fail-closed envelope
tests, and OpenJPEG/Grok pixel-exact decode of both layouts (per-component
PGX comparison). Widening the gray/planar encode gate beyond RPCL/R-divisions
stays open as interop-gated breadth work. **F2 and F3a are complete for their
bounded profiles; F3b is active, with sampled packed headers and sampled encode
as the next component-layout gates.**

**Verify:** byte-identical RGB/gray regression corpus at every PR;
2-component (gray+alpha shaped) and 4-component synthetic roundtrips;
OpenJPEG/Grok decode of each new layout.

## Stage F2 — alpha channels (RGBA, gray+alpha)

**What:** 4-component RGB+alpha and 2-component gray+alpha: `cdef` with
Typ 1/2 and Asoc 0, TIFF extra-sample input (associated and unassociated
alpha kept distinct and signalled, never silently premultiplied), MCT
applied to the color triplet only.

**Depends on:** F1. **Size:** M.

**First container slice landed 2026-07-14:** `jp2.AlphaMode` and
`wrapPlanarAlphaCodestream` wrap the existing 2/4-component no-MCT planar
codestreams as gray+alpha or RGBA. The writer emits identity color-channel
definitions plus one final whole-image alpha channel (`cdef` Typ 1 for
unassociated, Typ 2 for associated, Asoc 0); the strict reader preserves the
mode and rejects missing, duplicate, mistyped, or reassociated definitions.

**Second TIFF/CLI slice landed 2026-07-14:** the strict TIFF reader/writer
accepts exactly one final `ExtraSamples` value 1 (associated) or 2
(unassociated) on gray/RGB chunky 8/16-bit strips. `tiff-to-jp2` and strict
JP2-to-TIFF decode preserve that mode, pixels, WhiteIsZero normalization, and
ICC bytes through the reversible no-MCT planar path. Unspecified/multiple
auxiliary samples remain fail-closed. A live no-MCT RGBA smoke is
pixel-exact through Grok and Kakadu with unassociated alpha preserved;
OpenJPEG accepts and decodes the JP2, although its TIFF writer omits tag 338.

**Third core slice landed 2026-07-14:** four-component MCT=1 now applies the
reversible color transform only to RGB planes 0..2. Alpha remains an
independent DC-shifted and 5/3-transformed component throughout T1/T2. The CLI
defaults RGBA to this profile, retains explicit no-MCT RGBA, and keeps ICT or
MCT on gray+alpha fail-closed. Local 8/16-bit strict roundtrips pin COD MCT,
alpha samples, `cdef`, and ICC preservation. A live RCT+alpha JP2 is accepted
by OpenJPEG, Grok, and Kakadu and is pixel-exact through Grok/Kakadu with
unassociated alpha preserved.

**Verify:** TIFF RGBA roundtrip; OpenJPEG/Grok decode with alpha preserved;
fail-closed for alpha definitions the codec cannot represent.

## Stage F3 — mixed precision and subsampling

- **F3a mixed per-component bit depth** (`BPCC`, per-component QCD
  exponents): decode-first with foreign fixtures, then encode. Size S-M.
- **F3b component subsampling** (`XRsiz`/`YRsiz` > 1, 4:2:x-style):
  decode-first — Kakadu can generate `Ssampling` fixtures on this box; the
  packet-plan grid math must become per-component. Size M-L, the harder half.

**Depends on:** F1 (F3a partially independent on the grayscale path).

**F3a bounded encode/decode slices landed 2026-07-14:** `jp2.Info` carries a bounded
per-component precision table, variable-BPC `ihdr`/`BPCC` accepts mixed
unsigned 8/16-bit descriptors, and the JP2 validator compares each descriptor
with its SIZ `Ssiz`. The strict planar path also carries per-component QCD/QCC
state through T2/T1 and reconstructs an embedded foreign Kakadu 8/16/8 fixture
pixel-exactly with per-plane DC shifts. The matching writer emits SIZ/QCC and
JP2 BPCC; live output decodes pixel-exactly through OpenJPEG, Grok, and Kakadu.
The bounded profile is single-tile RPCL, reversible 5/3, and no-MCT. Additional
API-generated OpenJPEG/Grok foreign encode fixtures remain useful matrix
breadth, but their CLIs expose only a common RAW precision.

**F3b slices 1-9 landed 2026-07-14:** JP2/SIZ parsing exposes nonzero
per-component `XRsiz/YRsiz`, `jp2-info` reports them, and an embedded Kakadu
4:2:0 fixture now reconstructs its 8x8/4x4/4x4 planes pixel-exactly through
strict T2/T1 and origin-aware 5/3. The strict catalog owns per-component
sampled bounds, bands, blocks, packet indexes, and output dimensions. Slice 3
adds reference-grid RPCL merging for unequal precinct grids, pinned by a second
Kakadu 32x32/16x16/16x16 fixture with 8x8 precincts and 30 audited packets.
Slice 4 makes strict open-ended T2 state component-local and proves the same
stream pixel-exact without PLT. Slice 5 retains matching nonzero image/tile
origins through packet planning and lifting, pinned by PLT and PLT-less Kakadu
fixtures with clipped 3x3/5x5 precinct grids. Slice 6 extends the same native
planar reconstruction across a zero-origin tile grid and fixes RPCL position
ordering where sampled precincts begin before a right or lower tile boundary.
Independent four-tile Kakadu fixtures with and without PLT audit 36 packets
and 86 blocks and reconstruct 32x32/16x16/16x16 planes exactly. Slice 7 carries
matching nonzero image/tile origins through the multi-tile context and local
plane assembly; PLT and PLT-less Kakadu variants at `XOsiz/YOsiz=5/3` audit
102 packets/198 blocks and remain pixel-exact. Packed headers, distinct
tile-partition origins, and writers remain fail-closed. Slice 8 admits explicit
main- or first-tile-header POC when its complete schedule preserves canonical
sampled RPCL order; Kakadu PLT/PLT-less single- and four-tile fixtures are
pixel-exact. Slice 9 adds explicit origin-anchored nearest-neighbour expansion
from native component planes to the full reference grid, plus checked sRGB
interleaving for JP2-to-TIFF conversion. It is pinned across zero/shifted
origins, single/multi-tile, PLT-less, and canonical-POC fixtures. Reordered
sampled POC, packed headers, and sampled encode remain fail-closed; packed
header state is the next strict-decode breadth gate.

## Stage F4 — colourspace breadth

**What:** enumerated `colr` values beyond sRGB(16)/grayscale(17): sYCC (18)
and, via 4-component F1 support, CMYK; e-sRGB/e-YCC and CIELab as
signalling-plus-ICC-preservation first. Policy: the codec signals and
round-trips these spaces losslessly; actual conversion to display RGB is
the conversion tool's job (optional LittleCMS-backed path per roadmap, only
after opaque ICC preservation is airtight).

**Depends on:** F1 (CMYK), F2 patterns for `cdef`. **Size:** M, mostly
container/marker semantics plus fixtures.

**Verify:** real sYCC/CMYK sample files, jpylyzer validity, pixel-exact
storage roundtrip (no conversion), fail-closed for spaces without an
implemented interpretation when conversion *is* requested.

## Stage F5 — input/output format front ends

Ordered by effort-to-value; each is a standalone `src/formats/` module with
golden fixtures and a corruption/fuzz gate like the TIFF reader has.

- **F5a BMP input** (S): trivial uncompressed 24/32-bit; good scaffolding
  test for the front-end API shape.
- **F5b PNG input** (M): `std.compress.flate` covers zlib; implement
  critical chunks (IHDR/PLTE/IDAT/IEND) + tRNS; maps onto gray/palette/
  RGB/alpha caps from F1/F2. No PNG output initially.
- **F5c JPEG input** (L): baseline sequential DCT first (progressive later,
  arithmetic never); own decoder, no external lib (license rule). This is
  the highest-value archive-migration format (JPEG -> JPEG2000).
- **F5d RAW/DNG** (L): `formats/dng.zig` already parses the IFD tree; stage
  as linear-DNG (LinearRaw, already demosaiced) first; CFA demosaic is its
  own research-grade decision, not part of this plan.
- **F5e OpenEXR** (L, last): needs half-float/float pipeline decisions
  (>16-bit precision policy per roadmap); defer until F3a establishes
  per-component depth handling.

**Verify per format:** reference images decoded pixel-exact against a
trusted decoder's output, malformed-input sweep (no panic/OOB in
ReleaseFast), then end-to-end format -> JP2 -> TIFF interop.

## Stage F6 — metadata preservation (EXIF/IPTC/XMP)

**What:** carry TIFF EXIF IFDs and XMP packets into the standard JP2
containers (EXIF `uuid` box `JpgTiffExif->JP2`, XMP `uuid` box, IPTC via
XMP) and back. The reader-side pass-through already exists; this stage adds
structured extraction, re-emission, and a preservation test matrix.

**Depends on:** nothing hard; pairs naturally with F5b/F5c inputs that
carry EXIF/XMP. **Size:** M.

## Dependency Order (Not The Active Queue)

This sequence describes technical dependencies only. The current implementation
order is maintained exclusively in `docs/next_steps.md`.

F1 (campaign) -> F2 -> F3a -> F5a+F5b (can interleave with F3/F4) -> F4 ->
F3b -> F5c -> F6 -> F5d -> F5e. BMP/PNG can start before F1 finishes if
they target only existing gray/RGB/palette caps.

## Explicit non-goals (for now)

- JPX/Part 2 containers and multiple codestreams.
- Automatic colour conversion inside the codec core.
- CFA demosaicing.
- Lossy formats as *output* (JPEG/PNG export) — z2000 converts *into*
  JPEG2000.
