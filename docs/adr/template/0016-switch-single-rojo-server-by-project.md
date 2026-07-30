# ADR-0016: Switch one default-port Rojo server to the active project

- Status: Superseded
- Date: 2026-07-30
- Deciders: Project maintainers
- Supersedes: ADR-0015
- Superseded by: ADR-0018

## Context

Rojo's Studio plugin returns unpublished local places to the default endpoint
after Studio restarts. Project-specific ports therefore require agents to edit
the plugin UI or repeatedly coordinate a separate endpoint, which is
unreliable.

Using the default port alone is also insufficient when a Rojo process from a
different repository is still running. Studio can connect successfully to
that stale server and synchronize the wrong project unless the server identity
is verified, not merely its availability.

Rojo exposes the active `projectName` through its `/api/rojo` metadata
endpoint. The process owning the default endpoint can therefore be checked
against the current repository before source or Studio work begins.

## Decision

All template-derived repositories omit `servePort` and share Rojo's default
endpoint at `127.0.0.1:34872`. Only one local Rojo project server is active on
that endpoint at a time.

Before the first source-code edit and again before the first Roblox Studio
operation in a task, agents run `scripts/ensure-rojo-server.ps1`. The script:

1. derives the expected project identity from the current repository and
   `default.project.json`;
2. reads `/api/rojo` and succeeds without a restart when `projectName`
   already matches;
3. when another project is active, verifies that the listener owner is Rojo,
   stops that Rojo process tree, and starts
   `rojo serve default.project.json` from the current repository;
4. refuses to terminate a non-Rojo process that owns the port;
5. waits until `/api/rojo` reports the expected project before succeeding.

Agents do not edit the endpoint field in Studio and do not pass or configure
custom ports. Before Studio mutation they also select the canonical place
instance explicitly and verify that its Edit DataModel name matches the Rojo
project identity.

## Alternatives considered

### Keep optional project-specific ports

Rejected because the local-place Studio plugin does not persist them reliably
and agent-driven UI replacement is fragile.

### Check only whether the default port is listening

Rejected because a healthy listener may belong to a different Rojo project.

### Terminate any process occupying the default port

Rejected because an unrelated application must not be killed merely to make
Rojo available.

### Run multiple project servers concurrently

Rejected for the default workflow. A single active server matches the Studio
plugin's stable default endpoint and removes endpoint selection from the
agent-Studio interaction.

## Consequences

### Positive

- Studio always uses its stable default endpoint.
- Project identity is verified through Rojo metadata before synchronization.
- Repeated preflight calls are idempotent for the already-active project.
- A non-Rojo listener is protected from automatic termination.

### Negative

- Switching repositories stops the previously active Rojo server.
- Multiple local Rojo projects cannot remain served concurrently under this
  workflow.
- Restarting a mismatched server may require process-inspection permission.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/index.md`,
  `.agents/rules/rojo-project.md`, `.agents/rules/project-initialization.md`,
  `.agents/rules/template-updates.md`
- Current documentation: `README.md`, `docs/adr/template/README.md`
- Code boundaries: `default.project.json`,
  `scripts/ensure-rojo-server.ps1`
- Tests: `scripts/validate-repository-layout.ps1`, two consecutive Rojo
  preflight runs, Rojo validation build
