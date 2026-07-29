# ADR-0009: Separate template and project ADR namespaces

- Status: Accepted
- Date: 2026-07-29
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Repositories derived from the template need to record game-specific decisions
without editing the template's architectural history. A single ADR directory
and index makes both upstream and a derived project allocate numbers and edit
the same index, creating avoidable merge conflicts. It can also make a
project-specific decision appear to be part of the reusable template.

Template ADRs must continue to reach derived repositories through upstream
updates, while project ADRs must remain owned entirely by the derived game.

## Decision

Use two path-scoped ADR namespaces with independent numbering:

- `docs/adr/template/` contains decisions owned by the reusable template and a
  template-owned `README.md` index.
- `docs/adr/project/` contains decisions owned by a derived game and its
  project-owned `README.md` index.

`docs/adr/README.md` is a template-owned router and never indexes individual
decisions. The template tracks no files under `docs/adr/project/`. During
mandatory derived-project initialization, the agent creates
`docs/adr/project/README.md` and an initial numbered project ADR. The derived
repository then owns that entire namespace.

Both namespaces start at `0001`. References include the namespace or full path
when an ID could be ambiguous. Template changes update only the template
index. Game changes update only the project index.

A project-specific decision may locally supersede a template decision only
through a new project ADR and corresponding updates to higher-precedence
project rules, documentation, and tests. The historical template ADR and its
index remain untouched.

## Alternatives considered

### One shared index with reserved number ranges

Rejected because both upstream and derived projects would still edit the same
file and conflict during merges.

### One global sequence allocated by the template

Rejected because derived projects would need coordination with upstream to
reserve IDs.

### Copy template ADRs into a new project namespace

Rejected because copied records would drift and upstream decisions would no
longer have a single historical source.

## Consequences

### Positive

- Template updates never need to edit the project ADR index.
- Games can allocate ADR numbers independently.
- Decision ownership is visible from the path.
- Template history continues to update normally through `upstream`.

### Negative

- ADR references must include their namespace when ambiguous.
- Existing repositories need a one-time move of template ADR files.
- Derived-project initialization must create the namespace and its first ADR.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/index.md`,
  `.agents/rules/architecture.md`,
  `.agents/rules/architecture-decisions.md`,
  `.agents/rules/project-initialization.md`
- Current documentation: `docs/adr/README.md`,
  `docs/adr/template/README.md`,
  `.agents/rules/project-initialization.md`
- Code boundaries: `docs/adr/template/`, `docs/adr/project/`
- Tests: `scripts/validate-repository-layout.ps1`
