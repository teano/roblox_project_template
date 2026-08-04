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
8. Immediately before the first source-code edit in a task, run:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ensure-rojo-server.ps1
   ```

   Do not edit source code unless the command succeeds.

Before the first Roblox Studio tool or UI operation against a running
DataModel in a task, run the same Rojo preflight again, then explicitly select
the Studio instance for the current project; do not inspect or mutate another
open project. For an unpublished project, identify that instance by the
canonical local `place.rbxl`. For a published project, identify it by the
project-recorded stable `game.PlaceId` and `game.GameId`; the canonical
`place.rbxl` remains the repository's binary scene source, not its cloud
identity. If reliable enumeration proves that no matching project session
exists and opening one is authorized, run the preflight before launch and
explicitly select the new canonical instance before any subsequent Studio
operation.
Studio and test workflows MUST reuse an already-open Studio session when that
session owns the canonical place of the project being tested. Never open a
duplicate session for the same project, replace the matching session, or
attach its place to another Experience. Sessions for other projects are out of
scope and must not be inspected or changed. A new canonical session may be
opened only after reliable instance enumeration proves that no matching
project session exists; an empty or disconnected MCP result while Studio is
running is not proof. In that ambiguous case, stop before any Studio or
fallback UI operation and ask the user to restore the connector in the
existing session. Never use `Start-Process`, shell association, Computer Use,
or another UI fallback to open a replacement merely because MCP is
unavailable. Starting a "fresh Play session" means stopping and starting Play
inside the matching selected Studio instance; it does not mean reopening
Studio or the place.
Treat `default.project.json` `name` only as the Rojo project/server identity,
not as the Roblox place identity, and never require it to match
`game.Name`. Every published repository MUST record its stable
`game.PlaceId`/`game.GameId`, configure matching top-level
`placeId`/`gameId`, and include every approved sync target in
`servePlaceIds`. Open it from Roblox cloud (`EditPlace`/My Experiences), or
open the canonical local file only when connecting the verified Rojo project
will restore those configured IDs before Play, Experience Config, DataStore,
publishing, or any other cloud-dependent operation. After connection, verify
the actual DataModel IDs exactly.

Immediately after a user-authorized first publish or attachment, treat the
selected post-attachment DataModel as the only authoritative source of cloud
identity. Read its exact nonzero `game.PlaceId` and `game.GameId`; do not infer,
derive, or copy them from a name, URL, requested destination, process command
line, or prior expectation. Before Play, Experience Config, DataStore, another
publish, or any other cloud-dependent operation, record those observed IDs in
the owning repository's `default.project.json` as top-level `placeId`/`gameId`,
add the attached place to the exact approved `servePlaceIds` allowlist, and
create the required ADR in that repository's owning namespace (`template` for
this reusable template, `project` for a derived game). Then rerun the Rojo
preflight, reconnect if needed, and re-read the DataModel IDs to prove they
match the recorded values. If the actual IDs cannot be read, are zero, or do
not identify the user-authorized destination, stop without guessing or
recording anything.

Never use `Publish to Roblox As` as an automatic identity-recovery step. Rerun
the preflight after changing repositories, restarting Studio, or any event
that may have replaced the Rojo process.

The preflight owns the single default Rojo endpoint. It may stop a process only
after confirming that the process owning port `34872` is Rojo, and it starts
`rojo serve default.project.json` from the current repository. Never change the
port field in the Studio plugin and never add a custom `servePort`.
If listener/process inspection is denied by the sandbox, rerun the preflight
with the platform-required approval; do not bypass or approximate the check.

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
from the repository root directory, enforces the shared default Rojo endpoint,
and reviews every project-specific configuration surface. Project ADR-0001
must record the connection name, absence of `servePort`, and merge policy that
preserves both during template updates. When a stable published place identity
is already known, it must also record and preserve `placeId`, `gameId`, and
`servePlaceIds`; otherwise it records cloud identity as unresolved and a later
project ADR owns the attachment decision. This is mandatory setup work and
does not require the user to repeat these instructions.

The reusable template's `placeId`, `gameId`, and `servePlaceIds` identify only
its two dedicated validation places in one Experience and are never inherited
as a derived game's
identity. Immediately after creating a derived checkout, remove those inherited
fields before the first Rojo preflight, Studio connection, or Studio operation.
Then either leave them absent while the derived cloud identity is unresolved or
write only the derived project's independently verified IDs.

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
Before creating a new ADR, search the active Accepted project ADRs. Reuse the
existing owning ADR when it already names the exact path and its invariant and
merge policy remain valid. A template update by itself is not a reason to
duplicate that decision. Create a new ADR only for a newly diverged path or a
changed durable decision; supersede the previous ADR when its invariant or
merge policy changes.

Before creating a branch or starting the merge, fetch `upstream` and determine
whether `upstream/main` is already contained in the current `HEAD`. If it is,
report that the project is current and make no merge change. Otherwise ask the
user whether to merge into the current branch or create the deterministic
`template-update/{commit_from}_{commit_to}` branch from the current `HEAD`.
Never choose an arbitrary update branch or force a dedicated branch when the
user wants to own the merge in their current branch.

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

## Feature work lifecycle

Feature implementation work is tracked through the repository feature
workflow documented in `.agents/rules/feature-workflow.md`. Before changing
source for a feature, explicitly invoke `$feature-start` for planned work or
`$feature-continue` for paused work. Use `$feature-pause` to checkpoint an
unfinished session and `$feature-finish` only after the complete feature audit,
documentation cascade, and verification gates pass.

`docs/Features/*/feature.json` files are the canonical durable feature state;
`docs/Features/README.md` is generated from them. One `in_progress` feature
reserves its named branch even while paused. Do not start or continue a
different feature on that branch, bypass a live writer lease, hand-edit the
generated feature-index block, invent Codex task identifiers, or mark a
feature ready while required evidence or blockers remain.

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
- The server and every client own separate immutable startup asset catalogs
  built only from explicit side-appropriate roots; `AssetKey` is unique within
  every catalog that can observe it.
- `SaveModule` is a controller registry/factory and must not know concrete save layers.
- Domain modules own runtime data; save controllers only capture, apply, validate, and persist mementos.
- Wallet and every provider declared with server authority are
  server-authoritative.
- Normal runtime synchronization uses compact explicit messages, not full provider-table replacement.
- Roblox `Players` lifecycle events are consumed through the project `PlayersModule`.
- Snapshot replacement follows validate/reconcile, capture, reverse Stop,
  forward SetMemento, forward Run, with complete rollback on failure.
- Teleport session continuity is server-owned; platform acceptance and source
  removal never prove target arrival, and shared presentation never exposes
  another player's session or attempt details.
- Critical architectural guarantees must be backed by tests, not prose alone.

## Change discipline

- Preserve `--!strict` in Luau modules.
- Prefer explicit constructor dependencies and manifest composition over hidden service lookup.
- Do not add external dependencies without explicit user approval.
- Do not create a second bootstrap, standalone startup Script, or LocalScript for a module.
- Do not add a monolithic mutable profile object that bypasses save providers.
- Do not add legacy direct gameplay remotes alongside the communication module.
- Do not turn `AssetRegistry` into a generic service locator, runtime-world
  tracker, ModuleScript resolver, remote registry, or live descendant watcher.
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
