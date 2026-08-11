---
document_type: development-plan
status: approved
revision: 1
feature: sfx-system
mode: single_owner
writer_strategy: sequential
planning_analyst_id: sfx-planning-analyst-01
source_prd_path: docs/Features/template/sfx-system/product-requirements.md
source_prd_revision: 4
source_prd_sha256: 9b46904c64242100c6aa61377cf5b9d0d79720a1a30865ffec13b2965c9c3dde
source_spec_path: docs/Features/template/sfx-system/technical-specification.md
source_spec_revision: 12
source_spec_sha256: 88d83641dae9b45ac06ef266ce635b2d374218d5a639d25c2454abc66076d459
slice_count: 1
approved_by: user
approved_at: 2026-08-10T20:44:29+00:00
---
# План разработки: SFX System

## Decision

- Режим исполнения: `single_owner`.
- Стратегия автора: `sequential`.
Writer sequencing: one-at-a-time
- Один постоянный Integration Engineer владеет всей вертикалью `SLICE-001` от ADR до итогового Studio/E2E-доказательства. Пространственная композиция одновременно затрагивает общий wrapper/core, side-owned реестр, обе Ordinary-композиции, manifests, детерминированные проверки, ручной QA и уже существующий грязный слой; разрыв этой связки создаст неоднозначное владение контрактами и cleanup.
- Не допускаются разделения по server/client, code/tests/docs, deterministic/manual, ADR/code, dirty-layer/spatial либо по отдельным слоям композиции. Дополнительные slices и параллельные инженеры не создаются.
- Статус этого документа — `draft`; переход в approved выполняется только контроллером после явного одобрения пользователем точного SHA-256 этого файла.

## Planning Analysis

- Сложность высокая, но вертикаль одна: заменить прежнюю переменную spatial-топологию фиксированным `SpatialAnchor` с прямыми детьми `AudioPlayer`, `AudioEmitter`, `Wire`, сохранить Point без кадрового драйвера и реализовать Attached через один generation-safe side-owned binding registry.
- Архитектурное решение обязательно закрепляется новым Accepted ADR-0043 до первой правки исходного кода. Одобренные PRD rev4 и specification rev12 остаются неизменной продуктовой и технической властью.
- Текущий worktree уже содержит незавершённый слой реальных assets/settings/preload/QA и ADR-0042. Он является входом для reconciliation, а не разрешением переписать или потерять существующие изменения.
- Новая runtime-поверхность ограничена одним модулем `SpatialAnchorBindingRegistry.luau` и точечными изменениями существующих Ordinary-компонентов и composition roots. Новые transport, bootstrap, strategy, probe, fallback, proxy, mirror либо per-wrapper connections запрещены.
- Проверки должны сохранить точные evidence identities rev12. Исторические проверки нельзя переименовывать, ослаблять или выдавать за новое доказательство.
- PF-002 и PF-003 являются предупреждениями повторного входа: если исследование обнаружит противоречие одобренной спецификации фактической платформе или репозиторию, Engineer останавливает source work и возвращает вопрос на reconvergence; исправлять approved specification во время реализации запрещено.
- Доступность безопасного persistence backend, соответствующего Studio-сеанса и своевременного operator statement остаётся внешней зависимостью доказательств, но не создаёт отдельный slice.

## Scope Boundaries

- В scope входит только завершение одобренной SFX-вертикали с фиксированной spatial-композицией, одним side-owned registry на сторону, generation-safe cleanup, документально-тестовым каскадом и сохранением уже существующего dirty layer.
- Public SFX API, server authority, client-local playback, pooling leases, real catalog/settings/preload и manual-QA контракты сохраняются в пределах PRD rev4 и specification rev12.
- Generic pooling, asset registry, content preloading, communication, save, GameData, players, Music, hybrid one-shot, catalog/configuration и AudioGraph не перерабатываются. Их проверки запускаются как regression evidence; изменение возможно только после воспроизводимого блокирующего дефекта и повторного согласования scope.
- `place.rbxl` является только ожидаемой уже грязной поверхностью: новая бинарная мутация, публикация, attachment или программное исправление place не разрешены этим планом.
- `.agentic-pipeline/**`, approved PRD/specification и feature lifecycle artifacts не являются product scope и не редактируются Engineer-ом.

## Context Budget

- Базовая ревизия для scope и бюджета: `8fd6bc621dd278e51086f00903a14151320b4169`.
- Жёсткий предел: не более `42` product files и не более `8500` изменённых product lines относительно базовой ревизии, включая сохранённый dirty layer.
- Оставшийся runtime/composition sub-budget: не более `10` runtime/composition files и примерно `900` production lines. Тесты, документация и already-dirty reconciliation не превращают этот sub-budget в разрешение расширить общий лимит.
- Постоянный Engineer держит в контексте approved PRD/spec hashes, обязательные audio/architecture/testing/init/assets/preload/resource/communication/save/domain/players/Rojo rules, ADR-0039..0042, текущий dirty inventory, Ordinary composition и точные evidence identities.
- Перед каждой правкой Engineer сверяет путь с `editable_paths`; неизвестный путь или превышение бюджета требует остановки и перепланирования, а не молчаливого расширения.

## Integration Milestones

- MILESTONE-001: Архитектурная граница принята.
  - Создан и переведён в Accepted ADR-0043 о fixed `SpatialAnchor` composition; template ADR index обновлён только добавлением ADR-0043.
  - `.agents/rules/audio.md` и документальная формулировка не противоречат новому ADR.
  - До достижения milestone не выполняется ни одной правки source code.
- MILESTONE-002: Пространственная композиция детерминирована.
  - Реализован один `SpatialAnchorBindingRegistry` на server side и один на каждом client side, каждый с единственной side-owned frame subscription.
  - Point один раз получает `CFrame.new(position)` и не регистрируется на frame updates; Attached получает полный transform из `Attachment.WorldCFrame`, `Camera.CFrame` или `PVInstance:GetPivot()`.
  - Release сначала снимает регистрацию, затем очищает graph; stale generation callbacks становятся no-op. Один server lease реплицируется нативно без mirror/fanout.
- MILESTONE-003: Точные evidence identities rev12 проходят.
  - Новые и сохранённые детерминированные проверки проходят под точными именами specification rev12, включая `AudioStatic/FixedSpatialCompositionOnly`, `AudioPlayback/SpatialAnchorFixedComposition`, `AudioPlayback/SpatialAnchorPointStatic`, `AudioPlayback/SpatialAnchorAttachedFullTransformGenerationCleanup`, `AudioPlayback/SpatialPublicSurface` и `AudioConfig/FixedSpatialCompositionObjectCeiling`.
  - Старые identities и unrelated regression coverage не переименованы и не ослаблены.
- MILESTONE-004: Предсуществующий dirty layer согласован.
  - Реальные assets, settings, startup preload, ADR-0042, QA bridge/contracts/drivers и текущие bootstrap/test-runner изменения сохранены и согласованы с fixed-spatial topology.
  - QA больше не наблюдает или не требует старую playback-emitter topology через `PositionType`/`PositionInstance`; listener-owned AudioGraph topology остаётся вне scope.
- MILESTONE-005: Полная верификация запечатана.
  - Пройдены repository validators, layout/diff/build gates, focused и regression suites, clean Play и `Studio-E2E-AUDIO-01..05`.
  - Записаны безопасный persistence rejoin, своевременное `IndependentFaders` operator statement и новое Parent-mode spatial evidence либо конкретные внешние blockers без подмены результата.

## Slice SLICE-001

Fixed spatial SFX vertical и reconciliation.

### Vertical Outcome

End-to-end: yes

Observable result: в чистом Play server-authoritative и client-local Ordinary SFX используют один фиксированный anchored `SpatialAnchor` на lease с непосредственными детьми `AudioPlayer`, `AudioEmitter`, `Wire`; playback emitter остаётся в default Parent mode без чтения/записи `PositionType` или `PositionInstance`; Point неподвижен без frame binding, Attached повторяет полный transform через единственный side-owned generation-safe registry, release не оставляет callbacks/connections/instances, а все точные deterministic и Studio-E2E evidence rev12 проходят вместе с сохранённым assets/settings/preload/QA слоем.

### Requirements

- Функциональные требования вертикали: `PRD-REQ-001`, `PRD-REQ-002`, `PRD-REQ-003`, `PRD-REQ-004`, `PRD-REQ-005`, `PRD-REQ-006`, `PRD-REQ-007`, `PRD-REQ-008`, `PRD-REQ-009`, `PRD-REQ-010`.
- Функциональные требования вертикали: `PRD-REQ-011`, `PRD-REQ-012`, `PRD-REQ-013`, `PRD-REQ-014`, `PRD-REQ-015`, `PRD-REQ-016`, `PRD-REQ-017`, `PRD-REQ-018`, `PRD-REQ-019`, `PRD-REQ-020`.
- Функциональные требования вертикали: `PRD-REQ-021`, `PRD-REQ-022`, `PRD-REQ-023`, `PRD-REQ-024`, `PRD-REQ-025`, `PRD-REQ-026`, `PRD-REQ-027`, `PRD-REQ-028`, `PRD-REQ-029`, `PRD-REQ-030`.
- Функциональные требования вертикали: `PRD-REQ-031`, `PRD-REQ-032`, `PRD-REQ-033`, `PRD-REQ-034`, `PRD-REQ-035`, `PRD-REQ-036`, `PRD-REQ-037`, `PRD-REQ-038`, `PRD-REQ-039`, `PRD-REQ-040`.
- Функциональные требования вертикали: `PRD-REQ-041`, `PRD-REQ-042`, `PRD-REQ-043`, `PRD-REQ-044`, `PRD-REQ-045`, `PRD-REQ-046`, `PRD-REQ-047`, `PRD-REQ-048`, `PRD-REQ-049`, `PRD-REQ-050`.
- Нефункциональные требования вертикали: `PRD-NFR-001`, `PRD-NFR-002`, `PRD-NFR-003`, `PRD-NFR-004`, `PRD-NFR-005`, `PRD-NFR-006`, `PRD-NFR-007`, `PRD-NFR-008`, `PRD-NFR-009`.
- Критерии приёмки вертикали: `PRD-AC-001`, `PRD-AC-002`, `PRD-AC-003`, `PRD-AC-004`, `PRD-AC-005`, `PRD-AC-006`, `PRD-AC-007`, `PRD-AC-008`, `PRD-AC-009`, `PRD-AC-010`.
- Критерии приёмки вертикали: `PRD-AC-011`, `PRD-AC-012`, `PRD-AC-013`, `PRD-AC-014`, `PRD-AC-015`, `PRD-AC-016`, `PRD-AC-017`, `PRD-AC-018`, `PRD-AC-019`, `PRD-AC-020`.
- Критерии приёмки вертикали: `PRD-AC-021`, `PRD-AC-022`, `PRD-AC-023`, `PRD-AC-024`, `PRD-AC-025`, `PRD-AC-026`, `PRD-AC-027`, `PRD-AC-028`, `PRD-AC-029`, `PRD-AC-030`.
- Критерии приёмки вертикали: `PRD-AC-031`, `PRD-AC-032`, `PRD-AC-033`, `PRD-AC-034`, `PRD-AC-035`, `PRD-AC-036`, `PRD-AC-037`, `PRD-AC-038`, `PRD-AC-039`, `PRD-AC-040`.
- Критерии приёмки вертикали: `PRD-AC-041`, `PRD-AC-042`, `PRD-AC-043`, `PRD-AC-044`, `PRD-AC-045`, `PRD-AC-046`, `PRD-AC-047`, `PRD-AC-048`, `PRD-AC-049`, `PRD-AC-050`.
- Критерии приёмки вертикали: `PRD-AC-051`, `PRD-AC-052`, `PRD-AC-053`, `PRD-AC-054`, `PRD-AC-055`, `PRD-AC-056`, `PRD-AC-057`, `PRD-AC-058`, `PRD-AC-059`, `PRD-AC-060`.
- Критерии приёмки вертикали: `PRD-AC-061`, `PRD-AC-062`, `PRD-AC-063`, `PRD-AC-064`, `PRD-AC-065`, `PRD-AC-066`, `PRD-AC-067`, `PRD-AC-068`, `PRD-AC-069`, `PRD-AC-070`.
- Критерии приёмки вертикали: `PRD-AC-071`, `PRD-AC-072`, `PRD-AC-073`, `PRD-AC-074`, `PRD-AC-075`, `PRD-AC-076`, `PRD-AC-077`, `PRD-AC-078`, `PRD-AC-079`.

### Dependencies

- none

### Base Contract

- Base revision: `8fd6bc621dd278e51086f00903a14151320b4169`.
- Product authority: approved PRD rev4, SHA-256 `9b46904c64242100c6aa61377cf5b9d0d79720a1a30865ffec13b2965c9c3dde`.
- Technical authority: approved specification rev12, SHA-256 `88d83641dae9b45ac06ef266ce635b2d374218d5a639d25c2454abc66076d459`.
- Перед работой Engineer фиксирует полный tracked/untracked dirty inventory и сохраняет его как вход. Предсуществующие изменения нельзя удалять, сбрасывать, перезаписывать или приписывать этому slice без доказательства.
- Source edit разрешён только после Accepted ADR-0043 и успешного обязательного Rojo preflight непосредственно перед первой source-правкой.
- Точные evidence identities являются частью base contract; их historical meaning не меняется.

### Handoff Contract

- Engineer передаёт один интегрированный diff: Accepted ADR-0043 и индекс, fixed-spatial runtime/composition, точные deterministic/QA updates, reconciled dirty layer и документационный каскад.
- Handoff перечисляет итоговые изменённые product paths, diff/stat относительно base revision, результат budget check и отсутствие правок approved PRD/specification/lifecycle/controller state.
- Для каждого `PRD-AC-001..079` передаётся точное evidence identity и результат; пропуски, external blockers и не выполненные Studio/manual checks называются явно.
- Handoff фиксирует отсутствие playback-emitter чтения/записи `PositionType`/`PositionInstance`, число side-owned subscriptions, generation cleanup evidence и Parent-mode spatial evidence.
- Неустранённое противоречие платформы, превышение бюджета, отсутствие подходящего Studio-сеанса либо внешнего persistence/operator evidence останавливает завершение slice и возвращается контроллеру без создания fallback topology.

### Owned Paths

- `.agents/rules/audio.md`
- `docs/adr/template/0043-fixed-spatial-anchor-composition.md`
- `docs/adr/template/README.md`
- `docs/AudioSystem.md`
- `docs/AudioManualQA.md`
- `docs/TestCoverage.md`
- `scripts/validate-repository-layout.ps1`
- `src/ReplicatedStorage/Shared/Audio/SpatialAnchorBindingRegistry.luau`
- `src/ReplicatedStorage/Shared/Audio/AudioPlaybackWrapper.luau`
- `src/ReplicatedStorage/Shared/Audio/OrdinaryPlaybackCore.luau`
- `src/ReplicatedStorage/Client/Audio/OrdinarySoundClient.luau`
- `src/ServerScriptService/Modules/Audio/OrdinarySoundServer.luau`
- `src/ReplicatedStorage/Client/Initialization/Commands/OrdinarySoundInitializationCommand.luau`
- `src/ServerScriptService/Initialization/Commands/OrdinarySoundInitializationCommand.luau`
- `src/ReplicatedStorage/Client/Initialization/ClientManifest.luau`
- `src/ServerScriptService/Initialization/ServerManifest.luau`
- `src/ServerScriptService/Tests/AudioCatalogTestRunner.luau`
- `src/ServerScriptService/Tests/AudioPlaybackTestRunner.luau`
- `src/ServerScriptService/Tests/AudioIntegrationTestRunner.luau`
- `src/ReplicatedStorage/Shared/Tests/AudioManualQaContracts.luau`
- `src/ReplicatedStorage/Shared/Tests/AudioManualQaPlan.luau`
- `src/ReplicatedStorage/Shared/Tests/AudioManualQaClient.luau`
- `src/ServerScriptService/Tests/AudioManualQaServer.luau`
- `src/ServerScriptService/Tests/AudioManualQaTestRunner.luau`

### Expected Paths

- `README.md`
- `configs/audio/Sounds.csv`
- `src/ReplicatedStorage/Shared/Configs/Audio/SoundCatalog.luau`
- `docs/ContentPreloading.md`
- `place.rbxl`
- `src/ReplicatedStorage/Client/Audio/AudioSettingsClient.luau`
- `src/ReplicatedStorage/Client/Initialization/Commands/StartupContentPreloadCommand.luau`
- `src/ServerScriptService/Bootstrap.server.luau`
- `src/StarterPlayerScripts/Bootstrap.client.luau`
- `src/ServerScriptService/Tests/AllTestsRunner.luau`
- `src/ServerScriptService/Tests/ContentPreloaderTestRunner.luau`
- `src/ReplicatedStorage/Shared/Tests/AudioManualQaBridge.luau`
- `docs/adr/template/0042-bind-studio-audio-qa-through-existing-bootstraps.md`
- `docs/adr/template/0039-adopt-graph-audio-runtime.md`
- `docs/adr/template/0040-complete-ordinary-and-music-graph-audio.md`
- `docs/adr/template/0041-validate-audio-with-real-assets-and-studio-e2e.md`
- `docs/Features/template/sfx-system/product-requirements.md`
- `docs/Features/template/sfx-system/technical-specification.md`

### Forbidden Scope

- Нельзя менять `.agentic-pipeline/**`, approved PRD/specification bytes, `feature.json`, `handoff.md`, `worklog.md` или generated feature indexes; feature transitions выполняет только явно авторизованный workflow/controller.
- Нельзя создавать новый RemoteEvent/RemoteFunction/communication path, bootstrap/standalone Script/LocalScript, strategy/probe/fallback/proxy/mirror/fanout, per-wrapper frame connection или external dependency.
- Нельзя расширять изменение на generic pooling, asset registry, content preloading, communication, save, GameData, players, Music, hybrid one-shot, catalog/configuration либо AudioGraph без воспроизводимого необходимого regression blocker и controller re-entry.
- Нельзя читать или записывать playback-emitter `PositionType`/`PositionInstance`; listener-owned `AudioGraphClient` не является основанием менять его отдельный listener contract.
- Нельзя мутировать `place.rbxl`, публиковать/attach Experience, создавать generated `.rbxlx`/`sourcemap.json` как source или обходить обязательный Rojo/Studio instance selection.
- Нельзя ослаблять validators, object ceilings, exact evidence identities, cleanup assertions или acceptance semantics.

### Scope Contract

- acceptance_ids: PRD-AC-001, PRD-AC-002, PRD-AC-003, PRD-AC-004, PRD-AC-005, PRD-AC-006, PRD-AC-007, PRD-AC-008, PRD-AC-009, PRD-AC-010, PRD-AC-011, PRD-AC-012, PRD-AC-013, PRD-AC-014, PRD-AC-015, PRD-AC-016, PRD-AC-017, PRD-AC-018, PRD-AC-019, PRD-AC-020, PRD-AC-021, PRD-AC-022, PRD-AC-023, PRD-AC-024, PRD-AC-025, PRD-AC-026, PRD-AC-027, PRD-AC-028, PRD-AC-029, PRD-AC-030, PRD-AC-031, PRD-AC-032, PRD-AC-033, PRD-AC-034, PRD-AC-035, PRD-AC-036, PRD-AC-037, PRD-AC-038, PRD-AC-039, PRD-AC-040, PRD-AC-041, PRD-AC-042, PRD-AC-043, PRD-AC-044, PRD-AC-045, PRD-AC-046, PRD-AC-047, PRD-AC-048, PRD-AC-049, PRD-AC-050, PRD-AC-051, PRD-AC-052, PRD-AC-053, PRD-AC-054, PRD-AC-055, PRD-AC-056, PRD-AC-057, PRD-AC-058, PRD-AC-059, PRD-AC-060, PRD-AC-061, PRD-AC-062, PRD-AC-063, PRD-AC-064, PRD-AC-065, PRD-AC-066, PRD-AC-067, PRD-AC-068, PRD-AC-069, PRD-AC-070, PRD-AC-071, PRD-AC-072, PRD-AC-073, PRD-AC-074, PRD-AC-075, PRD-AC-076, PRD-AC-077, PRD-AC-078, PRD-AC-079
- editable_paths: .agents/rules/audio.md, docs/adr/template/0043-fixed-spatial-anchor-composition.md, docs/adr/template/README.md, docs/AudioSystem.md, docs/AudioManualQA.md, docs/TestCoverage.md, scripts/validate-repository-layout.ps1, src/ReplicatedStorage/Shared/Audio/SpatialAnchorBindingRegistry.luau, src/ReplicatedStorage/Shared/Audio/AudioPlaybackWrapper.luau, src/ReplicatedStorage/Shared/Audio/OrdinaryPlaybackCore.luau, src/ReplicatedStorage/Client/Audio/OrdinarySoundClient.luau, src/ServerScriptService/Modules/Audio/OrdinarySoundServer.luau, src/ReplicatedStorage/Client/Initialization/Commands/OrdinarySoundInitializationCommand.luau, src/ServerScriptService/Initialization/Commands/OrdinarySoundInitializationCommand.luau, src/ReplicatedStorage/Client/Initialization/ClientManifest.luau, src/ServerScriptService/Initialization/ServerManifest.luau, src/ServerScriptService/Tests/AudioCatalogTestRunner.luau, src/ServerScriptService/Tests/AudioPlaybackTestRunner.luau, src/ServerScriptService/Tests/AudioIntegrationTestRunner.luau, src/ReplicatedStorage/Shared/Tests/AudioManualQaContracts.luau, src/ReplicatedStorage/Shared/Tests/AudioManualQaPlan.luau, src/ReplicatedStorage/Shared/Tests/AudioManualQaClient.luau, src/ServerScriptService/Tests/AudioManualQaServer.luau, src/ServerScriptService/Tests/AudioManualQaTestRunner.luau
- shared_touchpoints: see structured rows below
- shared_touchpoint: TP-001 | path=src/ReplicatedStorage/Client/Initialization/ClientManifest.luau | symbols=OrdinarySoundInitializationCommand composition | allowed_change=inject Workspace and the one client-side frame driver into the existing Ordinary initialization path | forbidden_change=manifest order, unrelated command dependencies, bootstrap creation
- shared_touchpoint: TP-002 | path=src/ServerScriptService/Initialization/ServerManifest.luau | symbols=OrdinarySoundInitializationCommand composition | allowed_change=inject Workspace and the one server-side frame driver into the existing Ordinary initialization path | forbidden_change=manifest order, unrelated command dependencies, bootstrap creation
- shared_touchpoint: TP-003 | path=scripts/validate-repository-layout.ps1 | symbols=fixed-spatial audio assertions | allowed_change=additive exact assertions for SpatialAnchor direct-child composition, forbidden Position properties, one side subscription and required identities | forbidden_change=weakening or removing existing repository, Rojo, audio, QA or lifecycle assertions
- shared_touchpoint: TP-004 | path=src/ServerScriptService/Tests/AudioCatalogTestRunner.luau | symbols=AudioConfig/FixedSpatialCompositionObjectCeiling and retained catalog identities | allowed_change=add exact rev12 fixed-spatial ceiling evidence while preserving retained identities | forbidden_change=relabeling historical evidence or weakening real-asset/catalog checks
- shared_touchpoint: TP-005 | path=src/ServerScriptService/Tests/AudioPlaybackTestRunner.luau | symbols=AudioPlayback spatial identities | allowed_change=replace old topology assertions with exact fixed-anchor, Point, Attached, cleanup and public-surface evidence | forbidden_change=weakened cleanup, synthetic pass, changed unrelated identities
- shared_touchpoint: TP-006 | path=src/ServerScriptService/Tests/AudioIntegrationTestRunner.luau | symbols=AudioStatic/FixedSpatialCompositionOnly and retained integration identities | allowed_change=add exact static/composition evidence and necessary end-to-end assertions | forbidden_change=weakened server-authority, preload, settings or isolation evidence
- shared_touchpoint: TP-007 | path=src/ReplicatedStorage/Shared/Tests/AudioManualQaContracts.luau | symbols=Studio audio QA schemas | allowed_change=replace old playback topology observations with fixed Parent-mode SpatialAnchor fields | forbidden_change=new remote, changed authorization boundary, unrelated schema expansion
- shared_touchpoint: TP-008 | path=src/ReplicatedStorage/Shared/Tests/AudioManualQaPlan.luau | symbols=Studio-E2E-AUDIO-01..05 plan | allowed_change=replace old spatial observation instructions with exact fixed-anchor Parent-mode evidence | forbidden_change=removed gates, changed scenario identities, automatic publish or mutation
- shared_touchpoint: TP-009 | path=src/ReplicatedStorage/Shared/Tests/AudioManualQaClient.luau | symbols=client QA driver spatial observation | allowed_change=observe direct anchor children, transform behavior and cleanup without Position properties | forbidden_change=gameplay behavior, new transport, per-frame probe connection
- shared_touchpoint: TP-010 | path=src/ServerScriptService/Tests/AudioManualQaServer.luau | symbols=server QA driver spatial observation | allowed_change=observe native single-lease fixed-anchor behavior and cleanup | forbidden_change=mirror or fanout creation, new transport, gameplay authority change
- shared_touchpoint: TP-011 | path=src/ServerScriptService/Tests/AudioManualQaTestRunner.luau | symbols=manual QA contract and identity assertions | allowed_change=validate revised fixed-spatial schemas and exact scenario identities | forbidden_change=bypassing bridge authorization or accepting missing evidence
- shared_touchpoint: TP-012 | path=docs/adr/template/README.md | symbols=template ADR index | allowed_change=add ADR-0043 entry only after ADR-0043 is Accepted | forbidden_change=rewriting existing ADR entries or project namespace
- excluded_components: controller-state, approved-authority-documents, feature-lifecycle, generic-pooling, asset-registry, content-preloading, communication, save, GameData, players, Music, hybrid-one-shot, catalog, configuration, AudioGraph, bootstraps, canonical-binary-scene, generated-builds, external-dependencies
- excluded_paths: .agentic-pipeline/**, docs/Features/template/sfx-system/product-requirements.md, docs/Features/template/sfx-system/technical-specification.md, docs/Features/template/sfx-system/feature.json, docs/Features/template/sfx-system/handoff.md, docs/Features/template/sfx-system/worklog.md, docs/Features/template/README.md, src/ReplicatedStorage/Shared/Pooling/**, src/ReplicatedStorage/Shared/Assets/**, src/ReplicatedStorage/Shared/ContentPreloading/**, src/ReplicatedStorage/Shared/Communication/**, src/ReplicatedStorage/Client/Communication/**, src/ServerScriptService/Modules/Communication/**, src/ReplicatedStorage/Shared/Save/**, src/ReplicatedStorage/Client/Save/**, src/ServerScriptService/Modules/Save/**, src/ReplicatedStorage/Shared/GameData/**, src/ReplicatedStorage/Client/GameData/**, src/ReplicatedStorage/Client/Players/**, src/ServerScriptService/Modules/Players/**, src/ReplicatedStorage/Client/Audio/MusicClient.luau, src/ReplicatedStorage/Client/Audio/HybridOneShotClientController.luau, src/ServerScriptService/Modules/Audio/HybridOneShotServerController.luau, src/ReplicatedStorage/Shared/Audio/AudioHybridCodec.luau, src/ReplicatedStorage/Client/Audio/AudioGraphClient.luau, src/ServerScriptService/Modules/Audio/AudioGraphServer.luau, src/ReplicatedStorage/Shared/Configs/Audio/SoundCatalog.luau, configs/audio/Sounds.csv, src/ReplicatedStorage/Client/Audio/AudioSettingsClient.luau, src/ReplicatedStorage/Client/Initialization/Commands/StartupContentPreloadCommand.luau, src/ServerScriptService/Bootstrap.server.luau, src/StarterPlayerScripts/Bootstrap.client.luau, src/ReplicatedStorage/Shared/Tests/AudioManualQaBridge.luau, place.rbxl, build.rbxlx, sourcemap.json
- max_product_files: 42
- max_product_lines_changed: 8500
- verification_scope: Rojo preflight immediately before first source edit, ADR-0043 Accepted gate, catalog freshness preview/apply/re-preview if retained catalog inputs require generation, feature workflow and generated index validation, repository layout validation, diff and budget audit, temporary Rojo build, AudioCatalogTestRunner, AudioPlaybackTestRunner, AudioIntegrationTestRunner, AudioManualQaTestRunner, AssetRegistryTestRunner, ContentPreloaderTestRunner, ResourceManagementTestRunner, SystemTestRunner, ProductionIntegrationTestRunner, ProductionReadinessTestRunner, AllTestsRunner, clean Studio Play server/client output, Studio-E2E-AUDIO-01, Studio-E2E-AUDIO-02, Studio-E2E-AUDIO-03, Studio-E2E-AUDIO-04, Studio-E2E-AUDIO-05, safe persistence rejoin, timely IndependentFaders operator statement, Parent-mode fixed-spatial evidence
- scope_baseline_revision: 8fd6bc621dd278e51086f00903a14151320b4169

### Research Briefs

- RESEARCH-001 | question=Подтвердить только платформенную семантику default Parent positioning для AudioEmitter как прямого ребёнка anchored Part и отсутствие необходимости PositionType или PositionInstance | paths=docs/Features/template/sfx-system/technical-specification.md, src/ReplicatedStorage/Shared/Audio/AudioPlaybackWrapper.luau, Roblox Creator Hub AudioEmitter API | exclusions=Listener topology, alternate emitters, attenuation redesign, gameplay API | evidence=краткая ссылка на authoritative API и сопоставление с TS-DEC-008 без изменения approved spec | stop=default Parent semantics и direct-Part composition подтверждены либо найдено конкретное противоречие и запущен PF-002/PF-003 re-entry
- RESEARCH-002 | question=Найти минимальный существующий composition route для внедрения Workspace и ровно одной side-owned frame subscription на сторону | paths=src/ReplicatedStorage/Client/Initialization/ClientManifest.luau, src/ServerScriptService/Initialization/ServerManifest.luau, src/ReplicatedStorage/Client/Initialization/Commands/OrdinarySoundInitializationCommand.luau, src/ServerScriptService/Initialization/Commands/OrdinarySoundInitializationCommand.luau, src/ReplicatedStorage/Client/Audio/OrdinarySoundClient.luau, src/ServerScriptService/Modules/Audio/OrdinarySoundServer.luau | exclusions=новый bootstrap, service lookup, per-wrapper connection, remote, AudioGraph | evidence=точная карта constructor dependencies, owner lifecycle и cleanup с одним registry на сторону | stop=найден наименьший injection route без изменения manifest order и без второго subscription owner
- RESEARCH-003 | question=Заморозить полный предсуществующий tracked и untracked dirty inventory относительно baseline до реализации | paths=README.md, configs/audio/Sounds.csv, docs/AudioSystem.md, docs/ContentPreloading.md, docs/AudioManualQA.md, docs/TestCoverage.md, docs/adr/template/0042-bind-studio-audio-qa-through-existing-bootstraps.md, place.rbxl, scripts/validate-repository-layout.ps1, src/ReplicatedStorage/Client/Audio/AudioSettingsClient.luau, src/ReplicatedStorage/Client/Initialization/Commands/StartupContentPreloadCommand.luau, src/ReplicatedStorage/Shared/Configs/Audio/SoundCatalog.luau, src/ServerScriptService/Bootstrap.server.luau, src/StarterPlayerScripts/Bootstrap.client.luau, src/ServerScriptService/Tests/AllTestsRunner.luau, src/ServerScriptService/Tests/ContentPreloaderTestRunner.luau, src/ReplicatedStorage/Shared/Tests/AudioManualQaBridge.luau | exclusions=сброс, checkout, stash, удаление, авторство текущих изменений | evidence=полные git status, name-status и numstat snapshots с отдельной отметкой tracked/untracked | stop=каждый исходный dirty path классифицирован как owned, expected-read-only или controller/lifecycle excluded и snapshot приложен к handoff
- RESEARCH-004 | question=Проверить доступность правильного Studio instance, безопасного persistence backend и operator topology для будущих evidence gates без запуска или мутации | paths=scripts/ensure-rojo-server.ps1, default.project.json, docs/AudioManualQA.md, docs/IntegrationTesting.md, place.rbxl | exclusions=запуск нового Studio, Play, publish, attachment, place mutation, DataStore write, UI fallback | evidence=preflight checklist с canonical place identity, connector/session state и доступностью внешних операторов; недоступность записана как blocker | stop=topology однозначно определена для будущего исполнения либо каждый внешний gate помечен конкретной причиной not run без попытки обойти запрет

### Verification and Exit Criteria

1. До первой source-правки подтвердить Accepted ADR-0043, затем выполнить `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ensure-rojo-server.ps1`; при ошибке source edit не начинать.
2. Сверить approved PRD/spec SHA-256, frozen dirty inventory, `editable_paths`, file/line budget и отсутствие изменения controller/lifecycle artifacts.
3. Если сохранённые CSV/catalog inputs требуют генерации, выполнить обязательный catalog freshness preview; apply допускается только штатным генератором и только для уже авторизованной retained surface, после чего повторить preview до clean. Не редактировать generated catalog вручную.
4. Выполнить feature-workflow/index, repository-layout и diff checks, затем Rojo build во временный output path вне source tree.
5. Запустить focused runners: `AudioCatalogTestRunner`, `AudioPlaybackTestRunner`, `AudioIntegrationTestRunner`, `AudioManualQaTestRunner`; проверить точные rev12 identities и отсутствие weakened/renamed assertions.
6. Запустить regression runners: `AssetRegistryTestRunner`, `ContentPreloaderTestRunner`, `ResourceManagementTestRunner`, `SystemTestRunner`, `ProductionIntegrationTestRunner`, `ProductionReadinessTestRunner`, затем `AllTestsRunner`.
7. В уже открытом и явно выбранном canonical Studio instance выполнить fresh clean Play внутри этого же instance; проверить server и client output, отсутствие unexpected errors, leaks и duplicate connections.
8. Выполнить `Studio-E2E-AUDIO-01..05`, включая новый fixed-anchor Parent-mode spatial evidence, Point static evidence, Attached full-transform и generation cleanup, native single server lease, settings/preload/real asset/manual-QA observations.
9. Выполнить безопасный persistence rejoin только с разрешённым backend и получить своевременное `IndependentFaders` operator statement; недоступные внешние доказательства не заменять предположением.
10. Сопоставить `PRD-AC-001..079` с фактическими exact identities/results, повторно проверить пределы `42` files и `8500` lines, runtime sub-budget и отсутствие forbidden topology.

#### Exit Criteria

- Все milestones `MILESTONE-001`, `MILESTONE-002`, `MILESTONE-003`, `MILESTONE-004`, `MILESTONE-005` выполнены в порядке, а ADR-0043 был Accepted до первого source edit.
- Каждый `PRD-REQ-001..050`, `PRD-NFR-001..009` и `PRD-AC-001..079` покрыт итоговой реализацией и точным проверяемым evidence без shorthand в handoff.
- Fixed `SpatialAnchor` topology, default Parent mode, Point/Attached behavior, one-subscription-per-side и generation-safe cleanup доказаны deterministic и Studio evidence.
- Все обязательные validators, build, focused/regression suites, clean Play и доступные внешние gates прошли; любое недоступное доказательство оставляет slice незавершённым.
- Предсуществующий dirty layer сохранён, reconciled и отделён от новых slice-изменений; approved PRD/spec, lifecycle/controller state и `place.rbxl` не менялись.
- Итоговый diff находится в scope contract и budget; нет новых remotes, bootstraps, fallbacks, mirrors, proxies, per-wrapper connections или dependencies.

### Rollback and Recovery

- Перед реализацией сохранить frozen dirty inventory. При неудаче откатывать только точно идентифицированные изменения `SLICE-001`; не использовать destructive reset/checkout и не затрагивать пользовательский dirty layer.
- Если ADR-0043 не принят, source work не начинается. Если official Parent semantics противоречат approved spec, остановиться, сохранить evidence и вернуть PF-002/PF-003 на upstream reconvergence без правки specification.
- Изменения registry, Ordinary factories и manifest injection восстанавливать как одну атомарную композицию; не оставлять половинчатый registry и не вводить временный fallback/per-wrapper connection.
- При stale callback, cleanup leak или object-ceiling regression сохранить минимальный воспроизводимый тест, исправить в той же вертикали и повторить focused/full verification.
- При недоступном Studio connector, неправильном instance, persistence backend или operator evidence остановиться без открытия дубликата Studio, publish/attachment, UI fallback или фальсификации результата.
- `place.rbxl` и generated outputs не используются как rollback target; новая binary mutation данным планом не разрешена.

### Downstream Consumers

- Реализацию потребляет `$agentic-gamedev-pipeline:gamedev-implementation`, назначающий одного постоянного Integration Engineer на весь `SLICE-001`.
- Контроллер планирования потребляет точный SHA-256 этого draft для пользовательского approval; writer не выполняет state transition.
- Feature workflow потребляет итоговый handoff/evidence только после реализации; Pause/Finish/Reopen разрешены исключительно явным запросом пользователя.
- Audio rules, ADR index, `AudioSystem.md`, `AudioManualQA.md`, `TestCoverage.md`, validators и точные test identities становятся поддерживаемыми downstream contracts после принятия и реализации плана.
