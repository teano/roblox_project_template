# ADR-0018: Identify Studio targets without comparing mutable names

- Status: Superseded
- Date: 2026-07-30
- Deciders: Project maintainers
- Supersedes: ADR-0016
- Superseded by: ADR-0022

## Context

ADR-0016 correctly establishes one verified Rojo server on the default
endpoint, but it also requires the selected Studio DataModel name to match the
Rojo project name. Those names have different responsibilities.

`default.project.json` `name` identifies the Rojo project and names built root
objects. `game.Name` is the mutable name of the current Roblox DataModel/place.
It is not a stable place or experience identifier and does not need to match
the repository-derived Rojo connection name. Requiring equality rejects valid
published projects and does not reliably prevent synchronization to the wrong
place.

Rojo provides `servePlaceIds` for live-sync destination protection. Roblox
also provides stable `game.PlaceId` and `game.GameId` values for published
places and experiences.

## Decision

Repositories continue to use the single default-port Rojo server selection and
verification workflow established by ADR-0016. The Rojo project name reported
by `/api/rojo` identifies the repository-owned server only.

Agents explicitly select the Studio instance opened from the current
repository's canonical `place.rbxl`. They never compare `game.Name` with
`default.project.json` `name` as a project identity check.

For published projects, stable Roblox identity is verified against
project-recorded `game.PlaceId` and `game.GameId` values when those values are
available. A configured `servePlaceIds` allowlist is the preferred Rojo-level
guard against live-syncing to an unintended published place. Reusable template
places and unpublished local places are not required to invent cloud IDs.

## Alternatives considered

### Keep comparing the DataModel and Rojo project names

Rejected because the values have different meanings, are independently
mutable, and can legitimately differ.

### Require fixed place and experience IDs in the reusable template

Rejected because every repository derived from the template owns a different
Roblox experience, and an unpublished local place has no stable cloud IDs.

### Remove target verification entirely

Rejected because agents still need to select the canonical Studio instance,
and published projects benefit from stable ID checks and `servePlaceIds`.

## Consequences

### Positive

- Human-readable place and experience names can differ from repository names.
- Studio target checks use stable Roblox identifiers when available.
- The Rojo server identity check remains deterministic and repository-owned.
- Derived projects can use `servePlaceIds` without imposing cloud IDs on the
  reusable template.

### Negative

- An unpublished template place cannot prove a cloud identity that does not
  exist.
- Derived projects must record stable IDs or configure `servePlaceIds` to gain
  automatic published-place protection.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/rojo-project.md`
- Current documentation: `docs/adr/template/README.md`
- Code boundaries: `default.project.json`,
  `scripts/ensure-rojo-server.ps1`
- Tests: `scripts/validate-repository-layout.ps1`, two consecutive Rojo
  preflight runs
