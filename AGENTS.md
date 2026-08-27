# Project agent instructions

These instructions apply to the reusable template and repositories derived
from it.

## Start here

1. Read `.agents/rules/index.md`.
2. Select rules by the paths and public contracts the requested change really
   affects. Read only those matched rules and their required documentation.
3. Preserve unrelated user changes.
4. Make the requested change directly. Feature tracking, a specification
   pipeline, an ADR, CodeGraph, Rojo, and Studio are not prerequisites unless
   the request or a matched rule specifically needs them.

For a cross-system or public-contract change, include every affected subsystem
rule. For a local edit that preserves architecture, do not load unrelated
rules or historical ADRs.

## Template projects

The repository is the reusable template unless an `upstream` remote points to
`roblox_project_template`. A repository with that upstream is a derived game.

Use `.agents/rules/template-workflow.md` and the repository-owned
`scripts/template-project.ps1` command for creating, repairing, validating, or
updating a derived project. The command owns the mechanical Git transaction and
protected project paths. Do not reproduce that merge workflow by hand unless
the command reports a condition that needs an explicit user decision.

A local client that intentionally has no Git repository may be created from an
exact local template checkout and full template commit ID. This originless
route exports only that tracked snapshot, creates no `.git` or remotes, and
still supports the optional project feature records. It does not add an
originless update or repair workflow.

Routine project changes do not require a project ADR or feature record.
Architecture decisions are for durable ownership or public-contract choices;
feature records are optional lightweight bookkeeping described in
`.agents/rules/feature-workflow.md`.

User-facing feature intents are routed through the repository skills
`$feature-start`, `$feature-pause`, `$feature-continue`, and
`$feature-finish`. Natural requests such as “начни фичу”, “поставь на паузу”,
“продолжи TF-0012”, and “заверши фичу” invoke the same thin workflows. The
agent calls `scripts/feature.ps1` internally; never require the user to run its
PowerShell commands. Start and Continue may proceed with requested work in the
same turn. Pause checkpoints an `open` record without introducing a paused
state. Finish verifies the scoped result before closing the record as `done`.

## Roblox Studio safety

Run this immediately before the first Studio tool or UI operation in a task:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ensure-rojo-server.ps1
```

The preflight is not required before ordinary filesystem edits. Rerun it after
changing repositories, restarting Studio, or replacing the Rojo process.

Before inspecting or mutating a running DataModel, enumerate Studio instances
and explicitly select the current project:

- for an unpublished project, use the canonical local `place.rbxl`;
- for a published project, use the stable recorded `game.PlaceId` and
  `game.GameId`.

Reuse an already-open matching Studio session. Never inspect another project,
open a duplicate session, replace a matching session, or attach its place to a
different Experience. An empty or disconnected connector result while Studio
is running is not proof that no matching session exists; stop and ask the user
to restore the connector. Do not use `Start-Process`, shell association, or UI
fallbacks to bypass that uncertainty. A fresh Play session means stop/start
inside the selected Studio instance.

`default.project.json` `name` identifies the Rojo project, not the Roblox
place. A published repository records exact nonzero top-level `placeId` and
`gameId` plus a `servePlaceIds` allowlist containing every approved sync
target. A derived project must never inherit the template validation IDs.

After a user-authorized first publish or attachment, read the actual resulting
DataModel IDs and record those exact values before Play, DataStore, Experience
Config, another publish, or another cloud-dependent operation. Never infer IDs
from a name, URL, requested destination, process command, or another project.
Stop when the IDs are zero, unreadable, or do not identify the authorized
destination. Never use `Publish to Roblox As` as automatic identity recovery.

The Rojo preflight uses a configured project `servePort` when present and the
default endpoint otherwise. It may stop a listener only after proving that the
owner is Rojo; it must never terminate an unrelated process.

## Source ownership

- `src/` and `default.project.json` own Rojo-managed Instances and properties.
- `place.rbxl` owns Studio-authored scene data outside Rojo mappings.
- Never patch or merge `place.rbxl` programmatically. Make authorized scene
  changes in Studio and commit the complete canonical file.
- Generated `.rbxlx` builds, `sourcemap.json`, Studio lock files, test output,
  and agent/pipeline runtime state are not source.
- The template must not add files under `src/ReplicatedStorage/Project/`.
  Derived games own that namespace.

## Runtime architecture

- Keep one bootstrap per side:
  `ServerScriptService/Bootstrap.server.luau` and
  `StarterPlayerScripts/Bootstrap.client.luau`.
- Declare startup order only in the server and client manifests.
- Prefer explicit constructor dependencies and manifest composition over
  hidden service lookup.
- Keep server-authoritative providers server-authoritative. Domain modules own
  runtime state; save controllers capture, apply, validate, and persist
  mementos.
- Use the communication module for gameplay transport and compact explicit
  messages for normal synchronization.
- Consume Roblox player lifecycle through `PlayersModule`.
- Preserve `--!strict` in Luau modules and do not add dependencies without
  explicit user approval.

If the request intentionally changes one of these boundaries, explain the
change and update its current rule, documentation, and executable tests. Add
an ADR only when the durable decision will help future maintainers.

## Verification

Use `.agents/rules/testing.md` and the matched subsystem rules. Verification is
proportional to the actual change:

- documentation or rules: link/reference checks, the relevant tool test, and
  `git diff --check`;
- Luau source or Rojo mappings: temporary Rojo build plus focused suites;
- bootstrap, networking, save, player lifecycle, executable placement, or
  scene behavior: matching Studio session, focused/full suites as routed, and
  clean server/client output.

Report checks not run and the concrete reason. Do not claim runtime behavior
from static inspection.

## Decision and rule precedence

1. System, developer, and explicit user instructions.
2. This file.
3. Matched files under `.agents/rules/`.
4. Relevant current project and template ADRs.
5. Descriptive documentation.

Accepted ADR bodies are historical. Supersede an active decision with a new
ADR instead of rewriting its body. A derived project never edits template ADRs
or their index.
