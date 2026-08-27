# Feature handoff

- Feature: TF-0011 Tracked-Only Repository Validation
- Status: accepted / awaiting bookkeeping close
- Head: fbc34584f1495d388bce2159e9a45c9c57fd9abc
- Updated: 2026-08-26T22:09:02.6652601Z

## Final independent acceptance (current)

- Independent review: PASS with no blocking findings.
- Windows PowerShell 5.1 and PowerShell 7 focused tooling suites: 51/51 PASS
  on both hosts; the previously completed extended 103/103 evidence remains
  valid for the unchanged covered behavior.
- Standalone repository wrapper: PASS on both PowerShell hosts; current scripts
  also passed parser checks.
- Temporary Rojo build: PASS at 1,679,039 bytes; the output was removed.
- `git diff --check`, active links, and active-reference scans: PASS.
- Process cutover: 114 tracked pipeline artifacts deleted and all 45 ignored
  local history/output artifacts preserved.
- Runtime invariants remain byte/tree-identical: `src`, `configs`,
  `place.rbxl`, and `default.project.json` are unchanged.

Studio was not run because the accepted refactor changes repository tooling,
rules, and documentation, not Roblox runtime source or DataModel behavior. This
checkpoint authorizes only the new minimal feature bookkeeping close; it is not
a release claim.

## Previous migration checkpoint (historical)

The parser-heavy candidate and its pipeline recovery loop are retired. The
root-cause KISS/YAGNI refactor now replaces them with direct template tooling,
bounded structural validation, focused tool tests, and an optional `open|done`
feature record. The exact pre-migration inventories and hashes are recorded in
[migration-receipt.md](migration-receipt.md).

TF-0011 is deliberately not complete yet. Its legacy schema-v2 manifest remains
`in_progress` until the integrated refactor passes final verification. After
that verification, the owning feature tool must preserve the exact legacy
manifest as `feature.legacy.json`, migrate the current record to schema v3,
close it as `done`, and write the final evidence here.

Everything below this checkpoint is the preserved historical handoff from the
superseded workflow. It records what happened, but is not an active instruction.

## Historical result and state

TF-0011 remains unfinished. Approved PRD revision 2, technical specification revision 2, and development plan revision 1 exist. The production pipeline was stopped in Engineering at generation 75 after repeated recovery cycles. The candidate changes scripts/validate-repository-layout.ps1, scripts/tests/feature-workflow.tests.ps1, and docs/TestCoverage.md. The latest known late test failure was patched but the resulting candidate was not verified. Review, QA, documentation phase, and Ready were not reached. The manifest still contains stale missing-PRD and missing-specification blockers even though those artifacts now exist.

## Important decisions and discussions

The approved direction removed repository-validator dependence on historical ignored evidence under root tests while preserving visibility of ordinary project-owned working-tree files. Implementation showed that the specification requirement for a PowerShell Luau lexer and execution/data-flow proof is disproportionate to that outcome, so the patch loop was stopped. The recommended KISS/YAGNI direction is to keep repository invariance and canonical contract-anchor checks in the repository validator while existing Luau runners own execution semantics. Declarative tracked registry and minimal canonical-file checks remain alternatives. No simplification option has been approved, so approved specification and plan authority must be reconverged before replacing the current implementation.

## Verification state

The mandatory Rojo preflight succeeded before source edits. git diff --check for the three implementation files completed without errors. Multiple Windows PowerShell 5.1 suite attempts exposed sequential late failures; the last known duplicate-static-producer fixture failure was patched without a post-edit run. A complete green Windows PowerShell 5.1 suite, PowerShell 7 suite, direct repository validator, feature-workflow validator, feature-index check, temporary Rojo build, Review, QA, documentation phase, and Ready verification are not complete. No Studio operations were performed.

## Blockers

- Product requirements are missing.
- Technical specification is missing.

## Historical next step

After an explicit Continue-only transition, use a separate authorized specification and pipeline request to select a KISS alternative, reconverge the approved specification and plan, reconfigure controller authority through its public command, replace the parser-heavy candidate, and rerun the required validation from a clean Engineering assignment.
