# Project agent instructions

These instructions apply to the entire repository.

## Mandatory preflight

Before editing, adding, moving, or deleting source code:

1. Read `.agents/rules/index.md` completely.
2. Determine whether this is the template repository or a derived game
   repository and whether derived-project initialization is complete.
3. Use both path triggers and architectural-concern triggers from the index.
4. Read every matched rule file completely before making source changes.
5. For a cross-system change, read the rules for every affected system.
6. Read the linked `docs/` pages when a rule identifies them as required context.
7. For an architectural change, read
   `.agents/rules/architecture-decisions.md`, `docs/adr/README.md`, then every
   relevant Accepted ADR from both indexes routed there before proposing or
   editing the design.

Do not begin source edits after reading only this file. Agent rule files are mandatory constraints, not optional documentation.

For a documentation-only change, read the rules for the system being documented. For an agent-rule-only change, read this file and `.agents/rules/index.md`.

## Derived-project initialization

The reusable template repository intentionally contains no
`docs/adr/project/` files. A repository derived from this template is
uninitialized when it has an `upstream` template remote but does not yet have
`docs/adr/project/README.md`.

Before the first derived-project source change, read and follow
`.agents/rules/project-initialization.md`. Initialization creates the
project-owned ADR namespace and initial ADR, assigns the Rojo connection name
from the repository root directory, and reviews every project-specific
configuration surface. This is mandatory setup work and does not require the
user to repeat these instructions.

When the user asks to create or initialize a project and supplies only the
target repository URL, treat that URL as the project `origin`, derive the local
directory name from it, and follow the URL bootstrap procedure in
`project-initialization.md`. Continue through clone, remote setup, project
initialization, verification, initialization commit, and push without asking
the user to restate each step. Never overwrite a non-empty unrelated repository
or force-push it under this implicit workflow.

## Template updates and project divergence

Before changing a template-owned file in a derived repository or merging
`upstream`, read `.agents/rules/template-updates.md`. Every intentional local
change to a path supplied by the template must be explained by a project ADR
with its exact paths, baseline, invariant, and future merge policy.

During the first import into an empty project, accept `place.rbxl` from the
template unchanged. After project initialization, the existing project
`place.rbxl` always wins over an incoming template version; preserve that whole
binary file and never auto-merge it. Clean upstream changes to text source,
scripts, services, rules, and documentation apply as delivered. When an
incoming change overlaps a locally modified template path, consult the project
ADR before resolving it. If the ADR and code do not make a safe durable merge
clear, stop and ask the user.

Every completed template merge must explicitly report the upstream range,
applied template changes, preserved project files, ADR-guided resolutions,
conflicts, and verification results.

## Code intelligence

CodeGraph is the preferred source-code exploration tool when its MCP tools are
available and the project has been initialized:

- Use CodeGraph for project structure, symbol lookup, context, call paths, and
  impact analysis before falling back to filesystem search.
- Treat CodeGraph as development tooling, not as a runtime dependency or a
  replacement for Rojo builds, tests, Studio Play checks, or direct inspection
  when a specific detail requires confirmation.
- If CodeGraph reports that the project is not initialized, follow
  `docs/CodeGraphSetup.md`. Do not edit files inside `.codegraph/` manually.
- Do not install, upgrade, or reconfigure global CodeGraph tooling without
  explicit user approval.
- If CodeGraph is unavailable, continue with the best available read-only
  exploration tools and report that limitation; do not claim graph-backed
  findings.

## Core architecture invariants

- The game has one system bootstrap per side: `ServerScriptService/Bootstrap.server.luau` and `StarterPlayerScripts/Bootstrap.client.luau`.
- Initialization order is declared only by the explicit server and client manifests.
- Modules expose initialization behavior but do not choose their global startup order.
- The server and every client own separate pooling registries; every concrete
  pool is homogeneous and returns generation leases instead of raw ownership.
- `SaveModule` is a controller registry/factory and must not know concrete save layers.
- Domain modules own runtime data; save controllers only capture, apply, validate, and persist mementos.
- Wallet and every provider declared with server authority are
  server-authoritative.
- Normal runtime synchronization uses compact explicit messages, not full provider-table replacement.
- Roblox `Players` lifecycle events are consumed through the project `PlayersModule`.
- Snapshot replacement follows validate/reconcile, capture, reverse Stop,
  forward SetMemento, forward Run, with complete rollback on failure.
- Critical architectural guarantees must be backed by tests, not prose alone.

## Change discipline

- Preserve `--!strict` in Luau modules.
- Prefer explicit constructor dependencies and manifest composition over hidden service lookup.
- Do not add external dependencies without explicit user approval.
- Do not create a second bootstrap, standalone startup Script, or LocalScript for a module.
- Do not add a monolithic mutable profile object that bypasses save providers.
- Do not add legacy direct gameplay remotes alongside the communication module.
- Do not programmatically patch binary place files or edit their lock files.
  Scene changes belong in the canonical `place.rbxl`, must be made
  through Roblox Studio when explicitly requested, and must be committed.
- Do not treat generated `.rbxlx` builds or `sourcemap.json` as source.
- Preserve the hybrid ownership boundary documented in
  `.agents/rules/rojo-project.md`.
- Keep template-owned ADRs and their index under `docs/adr/template/`.
  Repositories derived from this template record their own decisions only
  under a project-created `docs/adr/project/` namespace and maintain a separate
  project index. The template repository must not contain that namespace.
- In a derived repository, document every intentional modification to a
  template-owned path in a project ADR before or with the code change.
- Preserve unrelated user changes.

If an explicit request intentionally changes an invariant, do not silently work around this file. Explain the conflict, update the relevant agent rules and documentation as part of the authorized architectural change, and add or update enforcement tests.

Accepted ADRs are historical records. Do not materially rewrite one after its
decision changes; create a new ADR in the owning namespace that supersedes it
and update only that namespace's index. A derived project must not edit a
template ADR or the template ADR index.

## Rule precedence

1. System, developer, and explicit user instructions.
2. This `AGENTS.md`.
3. Matched files under `.agents/rules/`.
4. Accepted project decisions under `docs/adr/project/`, then Accepted template
   decisions under `docs/adr/template/`.
5. Descriptive documentation under `docs/`.

More specific matched rule files refine general rules. If rules, Accepted ADRs,
documentation, code, and tests disagree, treat that as architectural drift:
follow the higher-precedence current constraint and report the exact mismatch
before broadening the change.

## Minimum verification

After source changes:

1. Run a Rojo build to a temporary output path.
2. Run the test suites required by `.agents/rules/testing.md` and the matched subsystem rules.
3. For bootstrap, networking, save, or player-lifecycle changes, run a clean Studio Play session and inspect both server and client output.
4. Report every check that was not run and the concrete reason.
