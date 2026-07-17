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

The 2026-07-17 gate contains 27 entries: 11 committed entries plus all 16
optional T.803 profile-0 inputs. All 16 original inputs and their 18 class-0
PGX references are independently checksummed. `p0_01`, `p0_12`, and `p0_16`
decode exactly against their reduction-0 samples. The `p0_01` result also pins
the legal main-header ordering where QCD precedes COD. The other 13 profiles
return their manifested `UnsupportedPayload` boundary for syntax or sample
semantics that are not public yet. `p0_10` additionally pins legal zero guard
bits in QCD: the stream reaches the deliberate subsampled-MCT boundary rather
than being misclassified as malformed. The complete result is therefore ten
decode passes, 17 expected fail-closed cases, zero mismatches, and zero skips
when the optional root is present.

The first reduced-resolution production slice now reconstructs bounded
single-tile reversible 5/3 no-MCT streams directly from the requested DWT
level, with precision saturation and checked reduced dimensions. The runner
passes each reference's reduction selector to the production decoder. The
non-zero-reduction T.803 inputs remain fail-closed because they also require
irreversible transform, MCT, signedness, RGN, or divergent coding styles.
Class-1 all-component comparison can reuse the reference-list oracle as G1 and
G2 remove those boundaries.

## Manifest Policy

Each entry records its producer, version, origin, licence, redistribution
status, optional reproduction command, expected-result oracle, input checksum,
capability rows, input format, strict decoder, and expected result. A decode
pass may pin either the canonical native hash or a list of PGX `references`,
each with its own checksum, component index, resolution reduction, peak-error
limit, and MSE limit. The PGX reader accepts big- or little-endian signed and
unsigned integer samples from 1 through 16 bits, and evaluates peak error and
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

This version deliberately describes the current bounded native carrier. G1
must introduce a new hash version when signed samples, precision above 16 bits,
or a wider carrier land; it must not reinterpret existing v1 hashes.

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
