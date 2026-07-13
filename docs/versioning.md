# Versioning

z2000 uses Semantic Versioning for the application, CLI, and future public
library API. It begins conservatively at **0.1.0**. The project reaching its
internal ISO engineering scorecard does not by itself make the external API,
CLI, supported-profile envelope, or compatibility policy stable enough for
1.0.0.

Application versions are independent of:

- the private educational `.z2000` payload version;
- JPEG2000 marker values, profiles, capabilities, or Part numbers;
- TIFF, DNG, JP2, and other input-format version fields.

## Version Forms

The root `VERSION` file contains the manually selected base release line, now
`0.1.0`.

A normal build reports:

```text
0.1.0-dev.BUILD+gCOMMIT
```

A release-mode build (`-Drelease=true`) reports:

```text
0.1.0+build.BUILD.gCOMMIT
```

Where:

- `BUILD` is `git rev-list --count HEAD`, the number of commits reachable from
  the built revision;
- `COMMIT` is `git rev-parse --short=8 HEAD`;
- `.dirty` is appended to the build metadata when tracked files differ from
  `HEAD`.

For example:

```text
z2000 0.1.0-dev.382+ge93a31e0.dirty
z2000 0.1.0+build.382.ge93a31e0
```

The numeric build identifier participates in development-version ordering.
The Git revision disambiguates builds and makes bug reports traceable. Commit
counts are stable only while published history is not rewritten; official
builds therefore come from `main` or a signed release tag with full Git
history.

## Builds Without Git

An exported source tree without `.git` builds as:

```text
0.1.0-dev.0+gunknown
```

Package and CI systems should inject known provenance explicitly:

```sh
zig build \
  -Dbuild-number=382 \
  -Dgit-sha=e93a31e0 \
  -Dgit-dirty=false
```

These overrides also make builds deterministic in shallow clones. Official CI
should prefer a full clone so the default commit count remains meaningful.

## Increment Policy Before 1.0

- Increment `PATCH` for compatible bug fixes, security fixes, and performance
  work that does not intentionally broaden or break the public surface.
- Increment `MINOR` for meaningful new codec profiles, formats, CLI/API
  capability, or intentional pre-1.0 compatibility changes.
- Keep release tags in the form `vMAJOR.MINOR.PATCH`, beginning with `v0.1.0`.
- Do not reset or hand-edit `BUILD`; it is derived from repository history.

The `VERSION` file names the next release line during development. After a
release, advance it to the next planned pre-1.0 line in a normal commit.

## Release Procedure

1. Work from a clean, full-history checkout of `main`.
2. Set `VERSION` to the intended release and commit that change.
3. Run the full test and interoperability gates.
4. Build with `zig build -Drelease=true -Doptimize=ReleaseFast -Dtarget=native`.
5. Confirm `zig-out/bin/z2000 --version` has no `.dirty` suffix.
6. Create and push the matching annotated tag, for example `v0.1.0`.

## Gate For 1.0.0

Version 1.0.0 should wait until the supported JP2/J2K profile envelope, CLI
flags, public Zig API, error behavior, malformed-input policy, and backwards
compatibility expectations are documented and have remained stable across at
least two pre-1.0 minor releases. Formal external conformance evidence should
also be clearly separated from the project's internal coverage scorecard.
