# ADR-0008: Use one project-neutral canonical place filename

- Status: Accepted
- Date: 2026-07-29
- Deciders: Project maintainers
- Supersedes: ADR-0006
- Superseded by: None

## Context

ADR-0006 established that the repository tracks one canonical binary Studio
place alongside partial Rojo source. It named that file
`template_place.rbxl`. Repositories derived from the template are real game
projects rather than templates, so that name forces each project either to
carry template terminology permanently or to perform a rename that creates
unnecessary divergence from upstream.

The ownership and binary-merge constraints of ADR-0006 remain necessary; only
the canonical filename needs to become neutral to both the template and
derived games.

## Decision

Track `place.rbxl` as the single canonical Studio-authored place file.

Keep the hybrid ownership boundary from ADR-0006: `src/` and
`default.project.json` own Rojo-managed content, while `place.rbxl` owns scene
data outside those mappings. Scene edits remain serialized and must be made
through Roblox Studio. Generated Rojo builds never replace `place.rbxl`.

Derived repositories keep the same filename, avoiding a project-specific
rename and reducing conflicts when they receive template updates.

## Alternatives considered

### Keep `template_place.rbxl`

Rejected because every derived game would inherit a misleading filename or
need to rename an upstream-owned path.

### Give every derived project a unique place filename

Rejected because upstream documentation, ignore rules, validation, and merge
handling would need per-project customization.

### Stop tracking the place

Rejected for the ownership and reproducibility reasons recorded in ADR-0006.

## Consequences

### Positive

- Template and derived games share one neutral canonical filename.
- New projects do not need a place-file rename.
- Ignore rules, documentation, and verification stay identical downstream.

### Negative

- Existing repositories must process a one-time upstream rename.
- A derived repository that already renamed or changed its binary place may
  require manual conflict resolution during this migration.

## Enforcement

- Agent rules: `.agents/rules/rojo-project.md`
- Current documentation: `README.md`
- Code boundaries: `default.project.json`, `src/`, `place.rbxl`
- Tests: `scripts/validate-repository-layout.ps1`, Rojo validation build, clean
  Studio Play
