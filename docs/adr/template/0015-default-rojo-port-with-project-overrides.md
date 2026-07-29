# ADR-0015: Use Rojo's default port with optional project overrides

- Status: Superseded
- Date: 2026-07-29
- Deciders: Project maintainers
- Supersedes: ADR-0012
- Superseded by: ADR-0016

## Context

Rojo Studio restores saved endpoints by Roblox `PlaceId`. A local unpublished
`place.rbxl` has `PlaceId` zero, so the plugin intentionally returns to Rojo's
default port when Studio restarts instead of retaining a template-specific
port. Giving the reusable template a non-default `servePort` therefore makes
its server configuration disagree with the endpoint shown by a freshly opened
local place.

Some derived projects still need stable non-default ports when multiple Rojo
servers run concurrently. That is a project-local operational requirement,
not a universal template requirement.

## Decision

The reusable template omits `servePort` from `default.project.json` and uses
Rojo's default port.

A derived project also keeps `servePort` absent unless it intentionally needs
a stable override. When an override is required, the project selects an
available port, stores it in `default.project.json`, and records the value and
merge policy in project ADR-0001 or a superseding project decision.

The project-specific Rojo connection `name` remains mandatory. Template
updates always preserve that name and preserve `servePort` only when the
project documents an intentional override. Repository validation accepts an
absent `servePort` and validates the type and reserved range when the property
is present.

## Alternatives considered

### Keep a fixed non-default port in the template

Rejected because the Rojo plugin returns unpublished local places to its
default endpoint after Studio restarts.

### Assign a dedicated port to every derived project

Rejected because it creates configuration divergence even for projects that
never run concurrently and do not need an override.

### Pass `--port` only on the command line

Rejected for projects that require a stable override because the setting is
not visible in repository configuration and cannot be preserved by template
merge policy.

## Consequences

### Positive

- A freshly opened local template place and its Rojo server use the same
  default endpoint.
- Derived projects incur a port override only when they need one.
- Intentional project overrides remain reviewable and merge-safe.

### Negative

- Two projects using the default cannot serve concurrently.
- A project that adopts an override must still select, document, and preserve
  it explicitly.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/project-initialization.md`,
  `.agents/rules/template-updates.md`
- Current documentation: `README.md`, `docs/adr/README.md`,
  `docs/adr/template/README.md`
- Code boundaries: `default.project.json`, `docs/adr/project/`
- Tests: `scripts/validate-repository-layout.ps1`, Rojo validation build
