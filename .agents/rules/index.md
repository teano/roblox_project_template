# Agent rules index

Use this file as a path-first router. Read the smallest set that covers the
requested change; do not load every rule by default.

## Selection

1. Identify the files that may change.
2. Match their subsystem or public contract in the table below.
3. Read every matched rule completely. For a real cross-system change, combine
   the affected rows.
4. Read `testing.md` when source, tests, mappings, Studio data, or repository
   tooling behavior changes.
5. Read `architecture-decisions.md` and relevant ADRs only when creating or
   superseding an ADR, or when a durable ownership/public-contract decision is
   actually changing.

Documentation-only edits use the rule for the behavior they describe. Local
implementation edits that preserve architecture do not require unrelated ADRs.

## Path and contract map

| Trigger | Rules |
|---|---|
| Create, initialize, validate, migrate, or update a derived project; remotes or upstream merge | `template-workflow.md`; add `rojo-project.md` when project or cloud identity is involved |
| Start, pause, continue, finish, inspect, or edit an optional feature record; `docs/Features/**`, `.agents/skills/feature-*`, or `scripts/feature.ps1` | `feature-workflow.md`; add `testing.md` when executable tooling behavior changes |
| ADR creation, supersession, indexes, or ownership | `architecture-decisions.md` |
| New module, startup command, subsystem, ownership boundary, or public API | `architecture.md`, `initialization.md`, `testing.md` |
| `default.project.json`, Rojo mappings, `.model.json`, executable placement, `place.rbxl`, Rojo server, Studio selection, publish/attach, PlaceId/GameId | `rojo-project.md`, `testing.md` |
| `AssetRegistry`, `AssetKey`, asset roots, paths, tags, or catalog queries | `assets.md`; add `initialization.md`, `rojo-project.md`, or `testing.md` only when affected |
| `ContentPreloader`, preload selection/progress/policy, or startup preload | `content-preloading.md`, `assets.md`, `initialization.md`, `testing.md` |
| Pools, adapters, generation leases, cleanup, or resource budgets | `resource-management.md`, `testing.md` |
| `Shared/Util/Signal.luau` or module-owned events | `signals.md`, `testing.md` |
| `src/**/Initialization/**`, either bootstrap, manifests, or loading completion | `initialization.md`, `architecture.md`, `testing.md` |
| Save controllers/providers, storage, locks, autosave, shutdown, migrations, snapshots | `save-system.md`, `domain-data.md`, `architecture.md`, `testing.md` |
| Communication, remotes, DTOs, serialization, rate limits, epochs, or resync | `communication.md`, `architecture.md`, `testing.md` |
| Experience Config catalog, codecs, bundles, projections, or refresh | `configuration.md`, `communication.md`, `testing.md` |
| Player or character lifecycle | `players.md`, `testing.md` |
| Слоты игроков, друзья, приглашения или составной допуск | `players.md`, `communication.md`, `configuration.md`, `initialization.md`, `testing.md`; для окон также `ui.md` |
| Межсерверный подбор, временный реестр и резервы владельцев слотов | `players.md`, `teleport.md`, `initialization.md`, `testing.md`; [системное руководство](../../docs/AdmissionRouting.md) |
| Происхождение перенесённых систем, журнал `docs/Migrations/**`, ссылки на исходные решения | `architecture-decisions.md`; [журнал миграций](../../docs/Migrations/README.md) |
| Wallet, Version, GameData, Statistics, another provider, or authority change | `domain-data.md`, `save-system.md`, `communication.md`, `testing.md` |
| Teleport session/attempt/envelope/destination or validation pad | `teleport.md`, `players.md`, `communication.md`, `testing.md` |
| Audio catalog/config, playback, graph, Music, settings, pools, preload, or QA | `audio.md` plus only the actually affected dependency rules, and `testing.md` |
| UI root/hosts, controllers, actions/events, windows, navigation, or authoring | `ui.md` plus only the actually affected dependency rules, and `testing.md` |
| Any test runner or test contract | `testing.md` and the tested subsystem rule |

## Rule catalog

- `template-workflow.md`: direct init/repair/update/validate behavior and
  protected derived-project paths.
- `feature-workflow.md`: user-facing feature skills, optional two-state records,
  checkpoints, and legacy history.
- `architecture-decisions.md`: optional durable decision records.
- `testing.md`: proportional verification and Studio session safety.
- `rojo-project.md`: hybrid source ownership, place identity, mappings, and
  Studio/Rojo operation.
- The remaining files are focused runtime subsystem contracts.

When no row fits, start with `architecture.md`. Add a new focused rule only
when the repository has gained a genuinely new architectural category.
