# ADR-0023: Publish the template with non-inheritable cloud identity

- Status: Accepted
- Date: 2026-07-31
- Deciders: Project maintainers
- Supersedes: ADR-0022
- Superseded by: None

## Context

ADR-0022 rejects fixed cloud IDs in the reusable template because every
derived game and integration environment owns a different destination. The
template now has a maintainer-authorized published validation place, and its
actual post-attachment DataModel reports:

- Place ID `91045933836846`;
- Universe/Experience ID `10596427617`.

The template needs those IDs recorded to select the correct already-open
Studio session, restore identity when its canonical local `place.rbxl` is
opened, restrict Rojo live sync, and run identity-sensitive deterministic
tests without guessing.

Persisting template IDs in `default.project.json` creates a different risk:
a newly cloned derived project inherits the template destination. If it
connects Rojo before initialization removes or replaces that identity, it
could operate against the template's published place.

## Decision

The reusable template records its dedicated published validation identity at
the top level of `default.project.json`:

```json
"placeId": 91045933836846,
"gameId": 10596427617,
"servePlaceIds": [91045933836846]
```

These values identify only the template's own validation place. They are
template-owned defaults, not a cloud identity inherited by derived games.

Derived-project initialization removes all inherited `placeId`, `gameId`, and
`servePlaceIds` fields before the first Rojo or Studio connection. It then
either leaves cloud identity unresolved for an unpublished project or writes
the derived project's own exact verified post-attachment IDs. A derived
project never connects while the template IDs remain configured.

The same selected-DataModel capture rule applies to the template and derived
projects: newly assigned IDs are read from the actual post-attachment
DataModel, never inferred from names, URLs, requested destinations, process
arguments, or expectations.

Canonical `place.rbxl` remains the binary Git source for Studio-authored scene
state. The recorded cloud IDs remain a separate launch and service identity.

## Alternatives considered

### Keep the template unpublished

Rejected because the maintainer has assigned a real validation Experience and
needs repeatable identity-sensitive Studio testing.

### Keep template IDs outside the Rojo project

Rejected because that would not restore DataModel identity for a locally
opened canonical place and would not enforce the `servePlaceIds` live-sync
allowlist.

### Let derived projects retain template IDs until their first publish

Rejected because even one pre-initialization Rojo connection could target the
template's published place.

## Consequences

### Positive

- The template's Studio target is selected and verified by stable IDs.
- Rojo live sync is restricted to the template's approved validation place.
- Local canonical-file sessions can restore the template's cloud identity.
- Derived games still establish independent project-owned identities.

### Negative

- Derived initialization must remove or replace inherited template IDs before
  any Rojo or Studio connection.
- A clone that bypasses mandatory initialization is unsafe to connect.
- Template maintainers must preserve and verify the dedicated validation
  Experience.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/project-initialization.md`,
  `.agents/rules/rojo-project.md`, `.agents/rules/testing.md`.
- Current documentation: `README.md`, `docs/IntegrationTesting.md`.
- Code boundaries: `default.project.json`,
  `scripts/ensure-rojo-server.ps1`, canonical `place.rbxl`.
- Tests: `scripts/validate-repository-layout.ps1`, Rojo validation build, two
  consecutive Rojo preflights, exact Studio ID verification, and clean Play
  bootstrap.
