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
  tile-parts, scalar-derived quantization, invalid ICT/9-7 combinations, and
  multi-tile requests.
- Tightened the basic JP2 box reader for the supported `.jp2` profile:
  signature and `ftyp` ordering, `jp2 ` compatibility, RGB `ihdr`, sRGB `colr`,
  and one contiguous codestream are now validated fail-closed.
- Tightened the JP2 wrapper writer to reject unsupported bit depths and RGB
  sample buffers that do not match `width * height * 3`.
- Tightened strict codestream metadata parsing for the supported packet path:
  SIZ component precision/sign/subsampling, single-tile geometry, COD layer
  count/segment length, and QCD ordering are now validated before T2 audit.
- Locked strict COD code-block style policy to fail-closed for every nonzero
  style byte; standalone EBCOT style tests remain internal until their payload
  behavior is wired through strict codestream decode.
- Defaulted normal encode to SOP-on and EPH-off for the current independent
  decoder interop path; explicit `--eph` remains available for packet-boundary
  diagnostics while EPH sequencing is hardened.
- Added the first ICC preservation slice: TIFF tag 34675 is carried as owned RGB
  image metadata, JP2 wrapping writes a restricted ICC `colr` box, `jp2-info`
  reports ICC presence/size, and `decode-temp-jp2` writes the profile back to
  TIFF without transforming pixel values.
- Added malformed ICC coverage for zero-length/truncated TIFF profile tags and
  unsupported restricted-ICC JP2 `colr` box variants.
- Recorded the current interop gate: no-sidecar/no-EPH output strict-decodes in
  z2000 and is accepted losslessly by OpenJPEG and Grok; Grok no longer reports
  PL marker length warnings after RPCL subband precinct projection was fixed.
- Added the first public irreversible profile path: ICT, ISO-scaled 9/7,
  scalar-expounded QCD, deadzone quantization, and inverse quantization for the
  narrow single-tile RPCL profile.

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
- Added cleanup pass run-mode symbols for full four-row clean stripes in both
  the symbol oracle and direct MQ T1 paths, with matching coefficient decode.
- Split EBCOT sign coding into JPEG2000-style horizontal and vertical sign
  contributions, including sign prediction and mixed-neighbor context tests.
- Added magnitude-refinement context selection for first refinement with and
  without significant neighbors, plus later refinement passes.
- Added standalone EBCOT segmentation-symbol cleanup trailers behind an
  internal code-block style flag, with direct MQ roundtrip and corruption tests.
- Added standalone EBCOT reset-context style support for continuous MQ segments,
  resetting probability states at coding-pass boundaries while preserving the
  continuous payload stream.
- Extended inferred continuous MQ/T1 payload decoding to honor the same
  internal reset-context and segmentation-symbol style state.
- Added standalone EBCOT vertical-causal context handling, ignoring south
  neighbors across stripe boundaries in the symbol oracle, direct MQ path, and
  coefficient decoder.
- Added style-aware partial coefficient decode helpers for direct and continuous
  EBCOT segments so quality-layer pass prefixes can be validated with the same
  internal code-block style state.
- Added standalone EBCOT terminate-all style support, writing pass-terminated
  MQ segments and decoding them through the continuous API when the internal
  style is supplied.
- Added explicit `CodeBlockStyle` metadata for all six COD code-block style
  bits. BYPASS is now wired through public codestream payloads for the ISO-MQ
  backend; the other style bits remain fail-closed until their payload behavior
  is implemented end to end.
- Tightened strict COD parsing so every nonzero code-block style byte remains
  `UnsupportedPayload` until that exact style is wired end-to-end through the
  writer, reader, tests, and interop gates.

### Quality Layers And Rate Allocation

- Added `rate_alloc.zig`.
- Added even layer allocation.
- Added compression-ratio target mapping.
- Stored per-code-block cumulative pass and byte truncation points.
- Connected layer truncation metadata to T2 packet delta helpers.
- Connected `--rates` to public quality-layer counts. Current allocation is
  byte-target based, so access-profile output can be larger and higher-PSNR
  than Grok/OpenJPEG for the same nominal compression-ratio ladder.

### T2 Packet Work

- Added packet-header bit writer/reader with JPEG2000 marker-safe stuffing.
- Added tag-tree encoder/decoder.
- Added tag-tree known-node state and rollback so continued packets do not
  re-consume already proven inclusion/zero-bitplane tag-tree bits after a
  successful threshold decision.
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
- Normal no-sidecar decode now validates the strict packet block catalog
  instead of treating SOD bytes as a temporary payload; current T1
  reconstruction uses that catalog for the RPCL/RCT/5-3 roundtrip.
- BP8 debug validation now compares the public strict block catalog against the
  BP8 EBCOT catalog for geometry, cumulative pass/byte deltas, and payload bytes.
- ISO-MQ BP8 debug validation now uses the same strict SOD packet block catalog
  as normal no-sidecar decode for image reconstruction, while keeping byte-for-
  byte BP8 shadow-stream checks as the diagnostic oracle.
- Fixed RPCL code-block indexing so each block is assigned to one precinct cell
  instead of every intersecting precinct, avoiding duplicate first-inclusion
  state and reducing packet payload size on larger images.
- Fixed RPCL high-pass precinct projection so packet code-block selection uses
  subband-local low/high coordinates instead of transformed-plane offsets,
  aligning PLT packet lengths with Grok's packet parser.
- Strict main-header and tile-part readers now reject unsupported marker
  segments such as COC, QCC, POC, PPM/PPT, RGN, CRG, PLM, and CAP instead of
  silently skipping payload behavior that is not implemented.
- Tightened strict marker validation for the current no-sidecar path: SOT
  sequence/count, TLM tile indexes and Psot values, PLT packet spans, SOP/EPH
  policy and duplicate markers, and packet-header marker stuffing now have
  explicit regression coverage.
- Accepted ordered multi-segment TLM and PLT metadata in the strict reader while
  rejecting skipped marker indexes.
- Accepted tile-part COM marker segments as metadata before SOD.
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
- Added `tools/bench_compare.sh` and `tools/compare_tiff.py` for local macOS
  benchmark and pixel-check workflows.
- Updated the ISO scorecard after local OpenJPEG/Grok/valid2000 checks: narrow
  RGB lossless JP2 target is now estimated at 83/100 and the broader Part 1
  codec family at 37/100. valid2000 still reports ICC/PLT and access-profile
  policy failures, so it remains a gate rather than a pass.
- Started the MQ fast-path optimization: direct ISO-MQ block encoding now
  finalizes codeword segments into the reusable per-worker payload buffer
  instead of returning a temporary owned slice. Raw BYPASS segments now use
  the same direct payload sink, MQ BYTEOUT keeps that active sink local through
  carry/marker handling, and the common MPS/no-renorm branch is split out in
  the ISO MQ encoder/decoder.
- Tightened continuous ISO/NBF decode state updates so inferred and BYPASS
  decode paths stop writing legacy per-sample `u8` flags when the packed
  neighborhood flags already carry the required significance/refinement state.
- Replaced generic scan-iterator use in raw BYPASS significance/refinement
  decode with direct stripe/x/dy loops matching the inferred ISO/NBF pass
  walkers, advancing packed-flag and coefficient indices incrementally inside
  each stripe column.
- Vectorized packed-neighborhood visit-bit clearing with the portable SIMD
  lane policy already used elsewhere in T1 scratch cleanup.
- Removed per-sample parity branches from integer inverse 5/3 unpacking by
  splitting low/high samples into separate even/odd loops for rows and columns.

### Documentation

- Added `docs/architecture.md`.
- Added `docs/changelog.md`.
- Added `docs/roadmap.md`.
- Added `docs/api.md`.
- Added `docs/iso_coverage.md` to track estimated progress toward the narrow
  RGB lossless JP2 target and the broader JPEG2000 Part 1 codec family.

## Initial Milestone

- Added grayscale PGM encode/decode for a custom `.z2000` codestream.
- Added reversible 5/3 and irreversible 9/7 wavelet experiments.
- Added multi-level decomposition and scalar quantization experiments.
- Added a narrow TIFF reader and JP2 box scaffold.
- Added reversible RCT for RGB.
- Added temporary RGB JP2 roundtrip back to TIFF.
