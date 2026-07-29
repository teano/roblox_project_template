# ADR-0012: Assign and preserve project-specific Rojo server ports

- Status: Superseded
- Date: 2026-07-29
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: ADR-0015

## Context

Every `rojo serve` process needs its own TCP port. A connection name makes
projects recognizable in Studio, but does not prevent two concurrently running
servers from attempting to bind Rojo's default port. Projects derived from the
same template otherwise inherit the same port and require repeated manual
switching or command-line overrides.

`default.project.json` remains a template-owned path that derived games
intentionally modify during initialization. A later upstream change to that
file could replace a project's locally selected port unless the project records
the ownership invariant and future merge policy explicitly.

## Decision

The reusable template defines an explicit `servePort`. During mandatory
derived-project initialization, assign each game a separate fixed port by
checking both ports configured by other discoverable local Rojo projects and
ports owned by active TCP listeners. Select the first unused port in the
inclusive range `34872` through `34999` and store it in
`default.project.json`. Do not depend on a transient `--port` override.

Project ADR-0001 records the selected `servePort`, the Rojo connection name,
and `default.project.json` as a template divergence. Its project invariant
states that the connection name matches the repository directory and the
fixed port remains dedicated to that project. Its upstream merge policy
reconciles other compatible changes to `default.project.json` while preserving
the project's current `name` and `servePort`.

Template merges never replace or remove those two project-owned fields, even
when Git reports no textual conflict. A missing, stale, or contradictory
project ADR blocks automatic resolution rather than allowing the agent to
guess. A deliberate later port-policy change is a project decision and follows
the project ADR lifecycle.

## Alternatives considered

### Use Rojo's default port for every project

Rejected because only one server can bind the port at a time.

### Pass a different `--port` on every launch

Rejected because the choice is easy to forget, is not visible in repository
configuration, and cannot guide a future template merge.

### Choose an arbitrary free port for each session

Rejected because Studio connections, local commands, and agent behavior become
non-deterministic.

### Always accept the upstream `default.project.json`

Rejected because it silently discards the derived project's connection
identity and port reservation.

## Consequences

### Positive

- Multiple local Rojo servers can remain active concurrently.
- Normal `rojo serve default.project.json` needs no manual port override.
- The selected port is reviewable and reproducible.
- Project ADR-0001 gives future template merges an explicit field-level
  resolution policy.

### Negative

- Initialization must inspect local configuration and active listeners.
- Port availability is machine-local and must be rechecked before the first
  server start.
- Exhaustion or unreliable inspection of the reserved range requires user
  direction.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/project-initialization.md`,
  `.agents/rules/template-updates.md`
- Current documentation: `README.md`, `docs/adr/README.md`,
  `docs/adr/template/README.md`
- Code boundaries: `default.project.json`, `docs/adr/project/`
- Tests: `scripts/validate-repository-layout.ps1`, Rojo validation build,
  first-start `rojo serve default.project.json` bind check
