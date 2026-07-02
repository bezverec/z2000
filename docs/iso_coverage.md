# ISO Coverage Scorecard

This document tracks how close z2000 is to ISO/IEC 15444-style JPEG2000
compatibility. The percentages are engineering estimates, not formal
conformance claims. A point is counted only when the feature is implemented,
fail-closed where unsupported, covered by local tests, and has at least one
interop or strict-reader check when the feature is externally visible.

## Current Snapshot

Last updated: 2026-07-02.

| Target | Score | Meaning |
| --- | ---: | --- |
| Narrow RGB lossless JP2 target | 83 / 100 | Single-tile RGB TIFF 6.0 to JP2, RCT, reversible 5/3, RPCL, BYPASS, one or more quality layers, PLT/TLM, strict z2000 decode, and independent decoder smoke acceptance. |
| Full JPEG2000 Part 1 codec family | 37 / 100 | Broad Part 1 encode/decode coverage across tiles, progressions, quantization, irreversible profiles, code-block styles, rate allocation, and robust interop. |

The narrow target is intentionally much closer than the full-codec target. It
measures the practical archival path we are building first. The full-codec
target counts breadth across Part 1 features and should move slowly until
multi-tile, lossy profiles, more progression orders, and more decoder coverage
exist.

## Narrow RGB Lossless Target

| Area | Weight | Current | Evidence | Next gate |
| --- | ---: | ---: | --- | --- |
| JP2 boxes and RGB metadata | 8 | 7 | Signature, `ftyp`, `jp2h`, `ihdr`, `colr`, contiguous `jp2c`, sRGB and restricted ICC preservation. | Harden malformed box coverage and basic reader diagnostics. |
| TIFF 6.0 RGB input/output | 7 | 6 | Uncompressed chunky RGB strips, 8/16-bit samples, ICC tag preservation. | Add tiled TIFF or explicit fail-closed docs for every skipped TIFF feature. |
| Core main markers | 10 | 8 | `SIZ`, `COD`, per-subband reversible `QCD`, single-tile profile validation. | Keep marker validation synced with every newly accepted profile option. |
| Tile-part markers | 10 | 8 | `SOT`, `SOD`, `EOC`, `TLM`, `PLT`, optional `SOP`/`EPH`, resolution tile-parts. Grok no longer reports PL marker length warnings on the current no-sidecar smoke file. | Add Kakadu PLT/TLM gate and resolve valid2000 PLT count warnings. |
| RCT and reversible 5/3 DWT | 10 | 9 | Lossless RCT and integer 5/3 encode/decode paths with strict roundtrip checks. | Expand odd-size and edge-tile coverage when multi-tile starts. |
| T1/EBCOT/MQ for this profile | 20 | 14 | Continuous MQ-backed code-block payloads, ISO MQ default backend, direct MQ hot path, cleanup run mode, sign/refinement contexts, partial-prefix decode helpers, and BYPASS raw/MQ segments. | Close remaining style-bit gaps and reduce decode hot-path cost. |
| T2 RPCL packetization | 15 | 13 | Packet headers, tag-trees, `numlenbits`, layer deltas, RPCL indexing, strict SOD block catalog, packet rollback tests, and subband-local precinct projection. | Keep multi-layer packet truncation interop stable and extend the same discipline to future progression orders. |
| z2000 strict decode | 10 | 9 | No-sidecar strict RPCL/RCT/5-3 decode reconstructs z2000-produced ISO-MQ smoke files; ISO-MQ BP8 debug sidecar validation now reuses the same strict SOD packet block catalog after byte-for-byte shadow-stream checks. | Retire more debug-only assumptions and expand strict decode coverage for truncation/style combinations. |
| Independent decoder interop | 10 | 9 | OpenJPEG and Grok decode current no-sidecar output losslessly in local smoke tests; `tiffcmp` matches pixels and Grok emits no PL marker length warnings. Output byte size is within about 0.02% of Grok/OpenJPEG on the local 2048x2048 archival profile. | Add Kakadu and valid2000 gates and record reproducible commands/results. |
| **Total** | **100** | **83** |  |  |

## Full Part 1 Codec Family

| Area | Weight | Current | Missing breadth |
| --- | ---: | ---: | --- |
| Containers and metadata | 10 | 5 | More JP2 reader diagnostics, broader color/profile handling, JPX remains unsupported by design. |
| Core codestream syntax | 15 | 8 | More marker variants, component/tile layouts, progression and style combinations. |
| Lossless encode profiles | 15 | 7 | Multi-tile images, more progressions, remaining code-block style bits, stronger rate/layer allocation. |
| Lossless decode profiles | 15 | 4 | Independent arbitrary JP2/J2K input, multi-tile decode, more progression orders, more marker combinations. |
| Lossy encode/decode | 15 | 3 | ICT/9-7/scalar-expounded exists for the narrow single-tile path, but rate allocation, scalar-derived, arbitrary decode, and broader error-bound validation remain missing. |
| T1 completeness | 15 | 5 | BYPASS is public; reset-context, terminate-all, vertical-causal, predictable termination, segmentation symbols, and more termination rules still need public profile coverage. |
| T2 completeness | 10 | 5 | LRCP/PCRL/CPRL/CPRL ordering, packet parser breadth, tile-part divisions beyond none/R. |
| Interop and conformance gates | 5 | 3 | Reproducible OpenJPEG/Grok matrix exists locally; Kakadu, valid2000 pass criteria, malformed corpus, and fuzzing remain incomplete. |
| **Total** | **100** | **37** |  |

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
- OpenJPEG, Grok, Kakadu, or valid2000 accepts or rejects the current output in
  a new way.
- z2000 can decode a broader class of external codestreams.
- Benchmarks become fairer because the output is accepted by independent
  decoders without warnings.
- A debug-only oracle path becomes unnecessary for normal encode/decode.

Keep a one-line note in `docs/changelog.md` for score changes that move either
top-level number by at least two points.
