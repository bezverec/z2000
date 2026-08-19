# Documentation

The active documentation is intentionally split by purpose. Only
`next_steps.md` defines implementation order.

## Start Here

- [`roadmap.md`](roadmap.md) — strategic direction, supported baseline,
  promotion rules, and the current G0-G7 completion estimate.
- [`next_steps.md`](next_steps.md) — the current ordered work queue and gates.
- [`iso_coverage.md`](iso_coverage.md) — evidence-based coverage scorecard.
- [`part1_corpus.md`](part1_corpus.md) — broad Part 1 capability manifest and
  reproducible corpus gate.
- [`reference_tools.md`](reference_tools.md) — measured Kakadu/OpenJPEG/Grok
  behaviour: what they cannot emit, where they disagree, and what each sweep
  found.
- [`architecture.md`](architecture.md) — current design and data flow.
- [`api.md`](api.md) — CLI and library surfaces.

## Focused Active Documents

- [`optimization_plan.md`](optimization_plan.md) — benchmark keep rule and
  current performance candidates.
- [`benchmarks.md`](benchmarks.md) — reproducible benchmark results.
- [`versioning.md`](versioning.md) — version and release policy.
- [`changelog.md`](changelog.md) — chronological implementation record.

## Archive

Completed campaign plans and superseded snapshots live in
[`archive/`](archive/README.md). They are retained for design provenance, but
their status language must not be used to infer current support.

## Update Rule

When a feature lands:

1. update `changelog.md` with evidence;
2. record any new reference-tool observation in `reference_tools.md`, so it is
   findable the next time a sweep hits the same wall;
3. update `iso_coverage.md` only when the scored boundary changes;
4. remove or advance the item in `next_steps.md`;
5. update `roadmap.md` only when strategy or profile policy changes;
6. update API/architecture documentation when behavior or ownership changes.
