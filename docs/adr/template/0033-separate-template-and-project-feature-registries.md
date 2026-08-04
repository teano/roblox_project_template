# ADR-0033: Separate template and project feature registries

- Status: Accepted
- Date: 2026-08-04
- Deciders: Project maintainers
- Supersedes: ADR-0032
- Superseded by: ADR-0034

## Context

ADR-0032 gives template and derived-game features independent ID prefixes, but
stores every manifest under `docs/Features/<feature>/` and renders every row
into one `docs/Features/README.md`. A derived game therefore changes the same
dashboard that the reusable template continues to generate. Project feature
artifacts also share the template-owned directory surface, so later upstream
updates can conflict with or accidentally rewrite project feature state.

The lifecycle engine, schema, commands, branch exclusion, and writer lease are
reusable template infrastructure. The actual template history and one game's
feature history have different owners and must merge independently, matching
the already established ADR namespace boundary.

## Decision

Keep one template-owned feature-workflow system and split canonical feature
state into two path-owned namespaces:

- `docs/Features/template/` contains immutable `TF-####` manifests, artifacts,
  and its generated `README.md` dashboard. The reusable template owns this
  complete namespace.
- `docs/Features/project/` contains independently allocated `PF-####`
  manifests, artifacts, and its generated `README.md` dashboard. A derived
  repository creates and owns this complete namespace during initialization.
- `docs/Features/README.md` is a stable template-owned router and contains no
  generated feature rows.
- `docs/Features/_schema/`, lifecycle skills, scripts, hooks, rules, and
  validators remain shared template infrastructure.

The template repository never tracks `docs/Features/project/`. A derived
repository may read template feature history but lifecycle mutations can write
only its project namespace. Each dashboard is rendered exclusively from its
own manifests. Validation sees both namespaces so one `in_progress` feature
still reserves a branch repository-wide, duplicate IDs remain invalid, and a
foreign dashboard drift fails closed without granting permission to rewrite
it.

Existing template manifests and their artifacts move from
`docs/Features/<feature>/` into `docs/Features/template/<feature>/` without
changing their IDs or lifecycle history. Derived-project initialization
creates the empty project dashboard before the first game feature starts.
Template-update divergence detection excludes `docs/Features/project/` just as
it excludes `docs/adr/project/`.

## Alternatives considered

### Keep one dashboard with separate TF and PF sections

Rejected because both owners would still edit and regenerate the same file.
The sections reduce visual mixing but do not remove the Git merge surface.

### Store project manifests beside template manifests but ignore them upstream

Rejected because path ownership remains implicit, slug collisions are harder
to reason about, and generic dashboard generation can still absorb both sets.

### Duplicate the workflow scripts inside each namespace

Rejected because lifecycle behavior and validation would drift. Only durable
feature data needs separate ownership; the operating system remains shared.

## Consequences

### Positive

- Template updates can add or revise template feature history without touching
  a derived game's feature table or artifacts.
- Derived games allocate and evolve their feature set without creating
  template-path divergence ADRs.
- Ownership is visible from the path and matches the ADR namespace model.
- Cross-namespace branch and writer exclusion remains enforced by one engine.

### Negative

- Existing links to feature artifacts require a one-time path migration.
- Tools must distinguish the writable namespace from all visible namespaces.
- Derived-project initialization must create and validate a second dashboard.
- A slug or title used in both namespaces may require the stable ID for
  unambiguous command resolution.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/feature-workflow.md`,
  `.agents/rules/project-initialization.md`,
  `.agents/rules/template-updates.md`
- Current documentation: `README.md`, `docs/Features/README.md`,
  `docs/Features/template/README.md`,
  `docs/Features/template/feature-workflow/product-requirements.md`,
  `docs/Features/template/feature-workflow/technical-specification.md`
- Code boundaries: `docs/Features/template/`, `docs/Features/project/`,
  `scripts/FeatureWorkflow.psm1`, `scripts/feature-workflow.ps1`
- Tests: `scripts/tests/feature-workflow.tests.ps1`,
  `scripts/validate-feature-workflow.ps1`,
  `scripts/validate-repository-layout.ps1`
