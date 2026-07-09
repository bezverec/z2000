# ISO Coverage Scorecard

This document tracks how close z2000 is to ISO/IEC 15444-style JPEG2000
compatibility. The percentages are engineering estimates, not formal
conformance claims. A point is counted only when the feature is implemented,
fail-closed where unsupported, covered by local tests, and has at least one
interop or strict-reader check when the feature is externally visible.

## Current Snapshot

Last updated: 2026-07-09.

| Target | Score | Meaning |
| --- | ---: | --- |
| Narrow RGB lossless JP2 target | 91 / 100 | Single-tile RGB TIFF 6.0 to JP2, RCT, reversible 5/3, RPCL, BYPASS, one or more quality layers, PLT/TLM, strict z2000 decode, and OpenJPEG/Grok/Kakadu/jpylyzer smoke acceptance. |
| Full JPEG2000 Part 1 codec family | 72 / 100 | Broad Part 1 encode/decode coverage across tiles, progressions, quantization, irreversible profiles, code-block styles, rate allocation, and robust interop. |

The narrow target is intentionally much closer than the full-codec target. It
measures the practical archival path we are building first. The full-codec
target counts breadth across Part 1 features and should move slowly until
multi-tile, lossy profiles, more progression orders, and more decoder coverage
exist.

## Narrow RGB Lossless Target

| Area | Weight | Current | Evidence | Next gate |
| --- | ---: | ---: | --- | --- |
| JP2 boxes and RGB metadata | 8 | 8 | Signature, `ftyp`, `jp2h`, `ihdr`, `colr`, contiguous `jp2c`, sRGB and restricted ICC preservation, plus `LBox == 0` and `XLBox` codestream box lengths. | Build a JP2/ICC interop fixture matrix and continue hardening malformed box diagnostics. |
| TIFF 6.0 RGB input/output | 7 | 6 | Uncompressed chunky RGB strips, 8/16-bit samples (16-bit now has a full-pipeline archival encode->strict-decode roundtrip plus confirmed OpenJPEG 2.5.4 / Grok 20.3.6 lossless interop and jpylyzer-valid output), ICC tag preservation. | Add tiled TIFF or explicit fail-closed docs for every skipped TIFF feature. |
| Core main markers | 10 | 8 | `SIZ`, `COD` including layer-count and explicit precinct-byte policy, reversible `QCD` style/count/exponent validation, irreversible scalar-expounded `QCD` step-size validation for the public 9/7 path, and single-tile profile validation. | Keep marker validation synced with every newly accepted profile option. |
| Tile-part markers | 10 | 9 | `SOT`, `SOD`, `EOC`, `TLM`, `PLT`, optional `SOP`/`EPH`, resolution tile-parts, JP2-boundary sequential `SOT` audit through `EOC`, `TLM/Psot` length matching, `PLT` packet-span matching against `SOD` payload bytes, and packet-marker policy checks from `COD/Scod`. Grok no longer reports PL marker length warnings, Kakadu decodes the current no-sidecar smoke file losslessly, and jpylyzer accepts the JP2. | Keep a non-authoritative validator gate and investigate any future PLT/TLM warnings against independent decoders and the strict reader. |
| RCT and reversible 5/3 DWT | 10 | 10 | Lossless RCT and integer 5/3 encode/decode paths with strict roundtrip checks, including an odd/thin/minimal-dimension matrix (1x1, 5x5, 17x13, 3x100, 100x3, 255x1, 33x31, 63x65, 127x129, 2x2) that stresses the odd 5/3 DWT edge lifting, sub-band/precinct/code-block edge derivation, and the resolution clamp — each byte-exact through z2000 strict decode and confirmed lossless through OpenJPEG 2.5.4 and Grok 20.3.6. | Expand edge-tile coverage as multi-tile v2 lands. |
| T1/EBCOT/MQ for this profile | 20 | 18 | Continuous MQ-backed code-block payloads, ISO MQ default backend, direct MQ hot path, cleanup run mode, sign/refinement contexts, partial-prefix decode helpers, and BYPASS raw/MQ segments. Vertical-causal, segmentation-symbols, terminate-all, BYPASS+TERMALL, TERMALL-scoped reset-context, and TERMALL-scoped predictable termination are public opt-in profiles with focused local coverage; the established BYPASS/CAUSAL/SEGMARK/TERMALL smoke files are decoded losslessly by OpenJPEG 2.5.4 and Grok 20.3.6 (jpylyzer-valid), RESET+TERMALL is pixel-exact through z2000/OpenJPEG/Grok/Kakadu, and the larger ERTERM smoke is pixel-exact through z2000 strict decode, OpenJPEG, Grok, and Kakadu. TERMALL/RESET+TERMALL/ERTERM/BYPASS+TERMALL also have a fail-closed corruption matrix (PLT segment-length flip, truncation, payload byte-flip walk, and an explicit over-capacity packet-header segment-count check); multi-tile TERMALL has a strict roundtrip, malformed-input fuzz gate, and targeted packet-corruption matrix. | Keep unsupported style combinations fail-closed, extend multi-tile coverage beyond TERMALL, and reduce decode hot-path cost. |
| T2 RPCL packetization | 15 | 13 | Packet headers, tag-trees, `numlenbits`, layer deltas, RPCL indexing, strict SOD block catalog, packet rollback tests, and subband-local precinct projection. | Keep multi-layer packet truncation interop stable and extend the same discipline to future progression orders. |
| z2000 strict decode | 10 | 9 | No-sidecar strict RPCL/RCT/5-3 decode reconstructs z2000-produced ISO-MQ smoke files; ISO-MQ BP8 debug sidecar validation now reuses the same strict SOD packet block catalog after byte-for-byte shadow-stream checks. | Retire more debug-only assumptions and expand strict decode coverage for truncation/style combinations. |
| Independent decoder interop | 10 | 10 | OpenJPEG, Grok, and Kakadu decode current no-sidecar output losslessly in local smoke tests; jpylyzer 2.2.1 reports the JP2 as valid with no warnings; pixels match the source TIFF. Output byte size is within about 0.06% of Grok/OpenJPEG/Kakadu on the local 3520x5115 smoke profile. | Keep commands/results reproducible and add a small fixture matrix for ICC-present and ICC-absent source TIFFs. |
| **Total** | **100** | **91** |  |  |

## Full Part 1 Codec Family

| Area | Weight | Current | Missing breadth |
| --- | ---: | ---: | --- |
| Containers and metadata | 10 | 7 | Basic JP2 boxes are accepted by jpylyzer for the current no-sidecar smoke file, restricted ICC preservation exists, standard `LBox == 0`/`XLBox` lengths parse for codestream boxes, and uniform unsigned RGB `BPCC` precision boxes parse when `ihdr` uses BPC=255. Broader color/profile handling, mixed per-component precision, and JPX remain missing or unsupported by design. |
| Core codestream syntax | 15 | 12 | Multi-tile SIZ/SOT layouts, disabled MCT, LRCP progression, and redundant COC/QCC component markers (main-header COC/QCC accepted only when they byte-replicate the main COD/QCD; genuine per-component overrides plus tile-part COD/QCD and COC/QCC fail closed; malformed COC `Scoc`/SPcoc coding bytes and QCC qstyle fail as invalid in both paths, with shortened COC/QCC length bounded as truncation in the raw reader and invalid at the JP2 boundary) are public profiles with strict-reader coverage. More marker variants (POC/RGN/CRG), arbitrary component layouts, and remaining style combinations remain. |
| Lossless encode profiles | 15 | 10 | Multi-tile v1 (aligned grids, one tile-part per tile) encodes streams OpenJPEG/Grok decode losslessly, and the aligned multi-tile envelope now accepts TERMALL with deterministic strict roundtrip coverage. More progressions, remaining multi-tile code-block style bits, and stronger rate/layer allocation remain. |
| Lossless decode profiles | 15 | 10 | Multi-tile z2000 streams decode per tile through the public strict path. Foreign OpenJPEG, Grok, and Kakadu lossless JP2s decode pixel-identically to the encoders' own decoders for PLT-backed streams and the current PLT-less matrix: default LRCP/no-precinct files plus OpenJPEG/Grok multi-layer lossless ladders. Arbitrary component layouts, PLT-less multi-tile, and more marker combinations remain. |
| Lossy encode/decode | 15 | 9 | ICT/9-7 with scalar-expounded and scalar-derived quantization exists for the narrow single-tile path with OpenJPEG-matching reconstruction; z2000 also decodes foreign OpenJPEG 2.5.4 9/7 lossy JP2s byte-identically to OpenJPEG across a moderate rate ladder (-r 1..8, pinned by an embedded-fixture regression test), covers a heavily truncated OpenJPEG `-r 10` ISO-MQ fixture with deterministic decode plus an explicit error bound, and now decodes an embedded Grok 20.3.6 `-I -r 8` JP2 whose scalar-expounded QCD mantissas differ from z2000's generated table. Strict irreversible QCD decode accepts signalled scalar-expounded/scalar-derived step sizes, guard bits 1..7, and uses their mantissas for dequantization. Rate-driven layers use global PCRD allocation (J.14) that lands on byte targets within 0.2-0.4 dB of OpenJPEG's allocator at matched sizes. Arbitrary decode, Kakadu 9/7 step-table fixtures, and broader reference-relative error-bound validation remain missing. |
| T1 completeness | 15 | 11 | BYPASS, terminate-all, BYPASS+TERMALL, vertical-causal, segmentation symbols, TERMALL-scoped reset-context, and TERMALL-scoped predictable termination are public opt-in profiles with focused local coverage; BYPASS/terminate-all/vertical-causal/segmentation-symbols have OpenJPEG/Grok lossless interop, BYPASS+TERMALL has z2000/OpenJPEG/Grok lossless smoke coverage plus JP2 wrapper coverage, RESET+TERMALL has z2000/OpenJPEG/Grok/Kakadu pixel-exact smoke coverage, and ERTERM is pixel-exact through z2000 strict decode, OpenJPEG, Grok, and Kakadu on the current larger smoke. Standalone RESET, standalone ERTERM, BYPASS+TERMALL Kakadu coverage, and more termination rules still need public profile coverage. |
| T2 completeness | 10 | 8 | All five Part 1 progression orders are public with OpenJPEG/Grok lossless interop (single- and multi-layer); packet parser breadth and tile-part divisions beyond none/R remain. |
| Interop and conformance gates | 5 | 5 | Reproducible OpenJPEG/Grok/Kakadu/jpylyzer matrix exists locally for the narrow smoke file, and a CI-enforced corruption-sweep gate fuzzes every parse surface (raw codestream and JP2-wrapped) across six profiles — single-tile archival RCT/5-3, multi-tile RCT/5-3, irreversible ICT/9-7, terminate-all, BYPASS+TERMALL, and multi-tile TERMALL: truncation at every length plus single-byte corruption across SIZ/COD/QCD/TLM/SOT/SOD/PLT/SOP/EPH/packet-header/tag-tree/T1 regions, asserting bounded handling with no panic or out-of-bounds read under Debug, ReleaseSafe, and ReleaseFast. Broader corpus fuzzing can still expand. |
| **Total** | **100** | **72** |  |

This full-codec score is intentionally strict. z2000 has useful pieces of a
Part 1 encoder already, but a general-purpose codec must handle many more
profiles and arbitrary external inputs before the percentage should climb fast.

## Counting Rules

- `0%`: no implementation, or only a parser flag that is not connected to
  payload behavior.
- `25%`: implemented internally with focused tests, but not exposed in the
  public codestream profile.
- `50%`: exposed fail-closed or supported for one narrow path with local tests.
- `75%`: supported in the narrow path and accepted by at least one independent
  implementation or strict z2000 decode.
- `100%`: covered by local tests, strict validation, malformed-input tests, and
  OpenJPEG/Grok/Kakadu-style interop for the supported profile.

When a feature becomes broader but less stable, prefer lowering the score until
the new surface is tested. The score should reward boring reliability, not just
more accepted command-line options.

## Update Checklist

Update this file whenever a PR changes one of these gates:

- A new JPEG2000 marker, box, progression order, transform, quantization style,
  code-block style, or tile-part mode becomes supported instead of fail-closed.
- OpenJPEG, Grok, Kakadu, or an external validator accepts or rejects the
  current output in a new way.
- z2000 can decode a broader class of external codestreams.
- Benchmarks become fairer because the output is accepted by independent
  decoders without warnings.
- A debug-only oracle path becomes unnecessary for normal encode/decode.

Keep a one-line note in `docs/changelog.md` for score changes that move either
top-level number by at least two points.

Validator notes:

- External validators are diagnostic gates, not absolute sources of truth.
  Treat any warning as a hypothesis to check against the strict reader, the
  Part 1 text, and independent decoders.
- ICC metadata is required only when the source TIFF contains an ICC profile.
  ICC-absent TIFF input should produce ICC-absent JP2 output without counting
  that absence as a failure.
