# Changelog

This file tracks notable project changes. The repository is still pre-release;
entries are grouped by development milestone rather than semantic version.

## Unreleased

### JPEG2000 Profile Handling

- Added fail-closed profile option handling for unsupported marker/payload
  combinations.
- Allowed only RPCL progression for now.
- Allowed only no tile-part division or resolution tile-part division (`R`).
- Rejected tile sizes smaller than the image until real multi-tile encoding
  exists.
- Distinguished RCT and ICT instead of mapping `ict` to generic MCT enabled.
- Added tests that reject unsupported LRCP/PCRL/CPRL progression, L/C/P
  tile-parts, ICT, 9-7 JP2, scalar quantization, and multi-tile requests.
- Tightened the basic JP2 box reader for the supported `.jp2` profile:
  signature and `ftyp` ordering, `jp2 ` compatibility, RGB `ihdr`, sRGB `colr`,
  and one contiguous codestream are now validated fail-closed.
- Tightened strict codestream metadata parsing for the supported packet path:
  SIZ component precision/sign/subsampling, single-tile geometry, COD layer
  count/segment length, and QCD ordering are now validated before T2 audit.

### Temporary JP2 Payload

- Advanced the private payload through BP5, BP6, BP7, and BP8 style metadata.
- BP5 records quality-layer allocation metadata.
- BP6 records EBCOT/MQ segment metadata for stats and future packetization.
- BP7 additionally carries actual EBCOT/MQ bytes while the temporary decoder
  still consumes the legacy bitplane payload.
- BP8 adds a shadow RPCL packet stream built from normalized packet-local
  code-block leaf locations.
- `jp2-stats` reports block, pass-stream, quality-layer, and EBCOT/MQ segment
  statistics plus shadow RPCL packet counts/bytes.
- For normal no-sidecar codestreams, `jp2-stats` now relies on strict SOD packet
  audit data instead of private BP metadata.

### T1 And MQ

- Added a standalone JPEG2000-style binary MQ coder module with context state
  table and marker-stuffing aware byte output.
- Added roundtrip tests for short, all-zero, all-one, alternating, and context
  reset symbol streams.
- Added EBCOT coding pass metadata and MQ-backed code-block segment assembly.
- Added direct MQ emission for code-block segments to avoid a separate symbol
  oracle on the hot path.
- Added scratch-buffer reuse for EBCOT direct encoding.

### Quality Layers And Rate Allocation

- Added `rate_alloc.zig`.
- Added even layer allocation.
- Added compression-ratio target mapping.
- Stored per-code-block cumulative pass and byte truncation points.
- Connected layer truncation metadata to T2 packet delta helpers.

### T2 Packet Work

- Added packet-header bit writer/reader with JPEG2000 marker-safe stuffing.
- Added tag-tree encoder/decoder.
- Added code-block packet state, `numlenbits`/segment length state, and zero
  bit-plane handling.
- Added precinct packet writer/reader tests for first inclusion, continued
  inclusion, payload deltas, and truncated-payload rollback.
- Added RPCL packet iterator and direct packet lookup.
- Added precinct rectangle helpers and edge clipping.
- Added code-block selection helpers for RPCL packets.
- Added encoded-block to `LayerPacketBlock` bridge helpers.
- Added writer-state initialization from encoded blocks, including delayed first
  inclusion tests.
- Added a strict SOD-backed packet block catalog that reconstructs per-component
  code-block metadata, cumulative pass/byte counts, and owned payload views
  without requiring the BP8 debug sidecar.
- Normal no-sidecar decode now validates the strict packet block catalog and
  fails as `UnsupportedPayload` until standalone T1 image reconstruction is
  available, instead of treating SOD bytes as a temporary payload.
- BP8 debug validation now compares the public strict block catalog against the
  BP8 EBCOT catalog for geometry, cumulative pass/byte deltas, and payload bytes.
- Fixed RPCL code-block indexing so each block is assigned to one precinct cell
  instead of every intersecting precinct, avoiding duplicate first-inclusion
  state and reducing packet payload size on larger images.
- Strict main-header and tile-part readers now reject unsupported marker
  segments such as COC, QCC, POC, PPM/PPT, RGN, CRG, PLM, and CAP instead of
  silently skipping payload behavior that is not implemented.
- Added a metadata-inferred continuous MQ code-block decoder and wired complete
  single-layer strict RPCL reconstruction to use SOD payload bytes without
  relying on BP8 per-pass payload tables.
- Normal no-sidecar strict decode now reconstructs the current single-layer
  RPCL/RCT/5-3 path from the strict T2 block catalog, including zero-block
  geometry derived from codestream subband layout.
- Multi-layer lossless encode now uses continuous MQ code-block segments too,
  with quality-layer byte ranges snapped to actual coding-pass truncation
  points and mirrored consistently in BP8 debug metadata.

### Parallelism And Performance

- Added deterministic component-level encode/decode parallelism.
- Added encode-side code-block range scheduling for high thread counts.
- Reused scratch buffers in bitplane, entropy, and EBCOT paths.
- Added timing output for TIFF read, RCT, DWT, payload generation, JP2 wrapping,
  and disk write.
- Ran comparative local benchmarks against Grok, OpenJPEG, and Kakadu where
  available.

### Documentation

- Added `docs/architecture.md`.
- Added `docs/changelog.md`.
- Added `docs/roadmap.md`.
- Added `docs/api.md`.

## Initial Milestone

- Added grayscale PGM encode/decode for a custom `.z2000` codestream.
- Added reversible 5/3 and irreversible 9/7 wavelet experiments.
- Added multi-level decomposition and scalar quantization experiments.
- Added a narrow TIFF reader and JP2 box scaffold.
- Added reversible RCT for RGB.
- Added temporary RGB JP2 roundtrip back to TIFF.
