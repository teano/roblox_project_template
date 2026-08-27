---
document_type: technical-specification
status: approved
revision: 3
language: Russian
source_prd_path: docs/Features/template/tracked-only-repository-validation/product-requirements.md
source_prd_revision: 2
source_prd_sha256: 4a376538389407b8672b14582deb201a0cbdd7c72cab71eef4db79146fae037c
---
# Tracked-Only Repository Validation

## 1. Цель

Устранить единственный дефект: `scripts/validate-repository-layout.ps1` не должен читать или требовать ignored historical evidence
`tests/sfx-system/verification/rem-tf0005-support-evidence-01/coverage-manifest.json`.

Валидатор продолжает проверять актуальный SFX/Audio acceptance contract по tracked-файлам текущего checkout. Корневой `/tests/` не является входом этой проверки: его отсутствие, наличие или malformed содержимое не меняет результат при неизменных остальных файлах. Обычные project-owned working-tree и initialization-файлы остаются видимыми валидатору до commit.

Это validator-only изменение. Оно не меняет Roblox runtime, gameplay, Audio behavior, public API, Rojo DataModel или feature lifecycle.

## 2. KISS/YAGNI-граница

### 2.1. Разрешённые implementation paths

- `scripts/validate-repository-layout.ps1`
- `scripts/tests/feature-workflow.tests.ps1`
- `docs/TestCoverage.md`

### 2.2. Запрещённые изменения и обязанности

- любые `src/**`, включая Audio runners, `TestHarness`, `AllTestsRunner` и manual-QA Plan;
- runtime Audio/gameplay/public API, bootstraps, manifests, Rojo mappings, `default.project.json`, `place.rbxl` и DataModel;
- feature manifests, dashboards, lifecycle state, lifecycle scripts/rules или controller state;
- ADR и agent-rule changes;
- tracked artifacts под корневым `/tests/` или шаги их copy/generate/restore в derived initialization;
- production Git filter, index, archive, snapshot, staging или history-recovery layer;
- новый declarative evidence registry, Luau lexer/parser, escape decoder, balanced token/block scanner, control/data-flow или reachability analyzer;
- повторная структурная валидация внутренних contracts `TestHarness`, `AllTestsRunner`, callback graph, полного manual-QA Plan/scenario graph;
- decoy-proof guarantees для comments, inert strings, unreachable helpers или иных Luau-конструкций;
- exhaustive mutation matrix и full-repository recursive fixture copy.

Luau execution semantics остаются ответственностью существующих Studio runners/suites. Repository validator проверяет только наличие текущих tracked contract anchors у известных владельцев; он не доказывает выполнение Luau.

## 3. Текущая authority

| Contract | Tracked owner |
|---|---|
| Required acceptance identities | `docs/Features/template/sfx-system/technical-specification.md`, текущая §9.11 |
| Catalog/config/Audio-specific AssetRegistry identities и `AudioStatic/CanonicalAcousticProperty` | `src/ServerScriptService/Tests/AudioCatalogTestRunner.luau` |
| `AudioCatalog/StartupPreloadSet` | `src/ServerScriptService/Tests/ContentPreloaderTestRunner.luau` |
| `AudioPlayback/*` | `src/ServerScriptService/Tests/AudioPlaybackTestRunner.luau` |
| `AudioIntegration/*` | `src/ServerScriptService/Tests/AudioIntegrationTestRunner.luau` |
| `Studio-E2E-AUDIO-*` inventory/anchors | `src/ReplicatedStorage/Shared/Tests/AudioManualQaPlan.luau` |
| Manual-runner anchors `PlanValidates`, `MandatoryStudioObservationsPresent`, `Plan.Validate()` и `TestHarness.runAll("AudioManualQaTestRunner", tests, 5)` | `src/ServerScriptService/Tests/AudioManualQaTestRunner.luau`; scenario graph, callback flow, `TestHarness` internals и `AllTestsRunner` остаются вне scope |
| Static identities | успешные существующие `Add-AudioEvidenceRecord` checks в `scripts/validate-repository-layout.ps1` |

Этот небольшой owner map фиксирует уже существующее размещение и не создаёт новый runtime или public contract. `AudioStatic/CanonicalAcousticProperty` остаётся runner-owned; остальные `AudioStatic/*` и `AudioCsv/*` остаются результатами существующих PowerShell checks.

## 4. Минимальный design

### 4.1. Удаление historical dependency

Из TF-0005/SFX evidence-блока удаляются:

- путь к `coverage-manifest.json` под корневым `/tests/`;
- проверка существования, JSON parsing и сравнение historical manifest;
- условие, при котором current tracked evidence проверяется только при наличии historical manifest.

В replacement block нет чтения, перечисления или обхода корневого `/tests/`. Никакие другие ignored/untracked paths не скрываются.

### 4.2. Required identities

Validator читает текущую §9.11 SFX specification и существующим простым Markdown-row extraction получает required identity set для `PRD-AC-001..079`. Сохраняются текущие совместимые правила:

- сравнение ordinal и case-sensitive;
- repeated identity references схлопываются как set;
- missing/renamed required identity является ошибкой;
- stale actual identity, не требуемая текущей specification, разрешена.

Общий Markdown parser или новый registry не создаётся.

### 4.3. Current tracked anchors

Для runner-backed identity validator читает только owner path из таблицы §3 и принимает только две текущие registration shapes:

1. exact quoted identity в существующей direct форме `test("<identity>", ...`;
2. exact quoted identity в существующем owner-local table-driven identity list, для которого в том же owner сохраняется текущий literal loop/call anchor `for _, identity in <list> do` и `test(identity, ...`.

Реализация использует короткие literal/regex checks, достаточные для этих известных форм. Она не tokenizes Luau, не декодирует Luau escapes, не вычисляет block depth и не доказывает reachability. Identity, найденная только в другом owner path, не удовлетворяет required owner mapping.

Для `Studio-E2E-AUDIO-*` достаточно exact literal anchor в canonical `AudioManualQaPlan.luau` и сохранения небольшого набора существующих manual-runner anchors: `PlanValidates`, `MandatoryStudioObservationsPresent`, `Plan.Validate()` и `TestHarness.runAll("AudioManualQaTestRunner", tests, 5)`. Сценарии, acceptance arrays, callback order и data flow повторно не анализируются.

Static identity получает credit только из уже выполненного текущего `Add-AudioEvidenceRecord` path. Если required static assertion не выполнился или его identity была удалена/переименована, required-subset reconciliation завершается ошибкой.

`AudioStatic/AllAcceptanceEvidenceMapped` добавляется существующим evidence recorder только после того, как найдены все остальные required identities; затем выполняется финальная required-subset check. Это не отдельный parser или registry subsystem.

### 4.4. Failure behavior

- отсутствующий canonical owner file или current SFX specification даёт failure с exact path;
- отсутствующая/переименованная required identity даёт deterministic failure с exact identity и expected owner class/path;
- отсутствие current registration anchor для table-driven owner даёт failure с owner path;
- existing static assertion failures сохраняют свои diagnostics;
- root `/tests/` никогда не упоминается как required input или recovery action;
- соседние repository-layout checks выполняются прежним порядком и остаются обязательными;
- validator остаётся read-only относительно repository files.

## 5. Technical requirements

- `TS-REQ-001`: TF-0005/SFX evidence validation не читает и не требует корневой `/tests/`; absent и malformed variants имеют одинаковый exit result и normalized diagnostics при неизменных остальных inputs. Трассирует `PRD-REQ-001`, `PRD-REQ-002`, `PRD-NFR-001`, `PRD-NFR-002`, `PRD-AC-001`, `PRD-AC-002`.
- `TS-REQ-002`: production validator продолжает читать полный current filesystem вне корневого `/tests/`, поэтому project-owned uncommitted initialization files остаются видимыми existing checks. Трассирует `PRD-REQ-002`, `PRD-AC-003`.
- `TS-REQ-003`: required SFX/Audio identities берутся из current tracked SFX specification и сверяются с simple literal registration/identity anchors только в canonical owners §3 и с фактически выполненными static checks. Трассирует `PRD-REQ-003`, `PRD-REQ-005`, `PRD-AC-004`.
- `TS-REQ-004`: reconciliation использует required-subset semantics: missing/renamed required identity падает, stale extras разрешены, repeated references схлопываются. Трассирует `PRD-REQ-005`, `PRD-AC-004`.
- `TS-REQ-005`: ни implementation, ни derived initialization не копируют, не создают и не восстанавливают historical template evidence; `git ls-files -- tests` остаётся пустым. Трассирует `PRD-REQ-004`, `PRD-NFR-002`, `PRD-AC-003`, `PRD-AC-005`.
- `TS-REQ-006`: все existing repository-layout checks остаются активными; scoped regression suite проходит отдельно под Windows PowerShell 5.1 и PowerShell 7.x на обязательном Windows 11 host. Трассирует `PRD-NFR-003`, `PRD-AC-006`.
- `TS-REQ-007`: решение не добавляет parser/registry/snapshot subsystem и не меняет paths или responsibilities вне §2.1. Трассирует product scope и `PRD-NFR-002`.
- `TS-REQ-008`: temporary Rojo build подтверждает неизменную repository buildability; Studio Play не требуется только при подтверждённо неизменных `src/**`, Rojo mappings и DataModel. Трассирует `PRD-NFR-003`, `PRD-AC-006`.

## 6. Deterministic verification

| ID | Проверка | Pass condition |
|---|---|---|
| `TS-TEST-001` | Current candidate fixture без root `/tests/` | `validate-repository-layout.ps1` завершён с exit code 0 и не сообщает missing historical manifest. |
| `TS-TEST-002` | Тот же fixture с malformed historical manifest и unrelated nested file под root `/tests/` | Exit code и normalized diagnostics exact-equal результату `TS-TEST-001`. |
| `TS-TEST-003` | По одному representative required anchor удаляется/переименовывается в каждом canonical runner owner class, manual Plan и существующем static producer | Каждый case завершается exit code 1 и diagnostic содержит missing identity/owner; stale extra case проходит. Comments/unreachable/graph mutations не входят в contract. |
| `TS-TEST-004` | Initialized-derived fixture без root `/tests/`, где correct `DerivedWindowConfig.luau` добавлен как обычный uncommitted project-owned file; затем missing и invalid variants | Positive проходит; оба negative cases сохраняют existing initialization failures. |
| `TS-TEST-005` | Одна существующая соседняя non-TF-0005 mutation и полный `feature-workflow.tests.ps1` | Соседняя mutation падает; suite проходит отдельно в обеих host-средах и child commands используют current host executable. |
| `TS-TEST-006` | Scope/repository gate | Final diff ограничен §2.1; `git ls-files -- tests` пуст; feature validator, all-namespace index check, direct layout validator, `git diff --check` и temporary Rojo build успешны. |

Test fixtures не должны рекурсивно копировать весь working tree. Для isolated tracked baseline допустим test-only local `git archive`/equivalent tracked fixture с overlay только scoped candidate files; это не production input layer. Derived positive добавляет project-owned initialization file после baseline materialization, чтобы доказать pre-commit visibility. Release evidence после commit повторяет fresh clone или `git archive` pass без `/tests/`.

Обязательные top-level host invocations:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/tests/feature-workflow.tests.ps1
pwsh.exe -NoProfile -File scripts/tests/feature-workflow.tests.ps1
```

Repository gate:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-feature-workflow.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sync-feature-index.ps1 -Check -Scope All
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-repository-layout.ps1
git diff --check
rojo build default.project.json --output <temporary-path-outside-repository>
```

Temporary build должен существовать и быть non-empty после успешной команды, затем удаляется. Невыполненная проверка не считается pass и записывается с точной причиной.

## 7. Traceability

| PRD ID | Technical coverage | Verification |
|---|---|---|
| `PRD-REQ-001` | `TS-REQ-001` | `TS-TEST-001`, `TS-TEST-002` |
| `PRD-REQ-002` | `TS-REQ-001`, `TS-REQ-002` | `TS-TEST-002`, `TS-TEST-004` |
| `PRD-REQ-003` | `TS-REQ-003` | `TS-TEST-003` |
| `PRD-REQ-004` | `TS-REQ-005` | `TS-TEST-004`, `TS-TEST-006` |
| `PRD-REQ-005` | `TS-REQ-003`, `TS-REQ-004` | `TS-TEST-003` |
| `PRD-NFR-001` | `TS-REQ-001` | `TS-TEST-001`, `TS-TEST-002` |
| `PRD-NFR-002` | `TS-REQ-001`, `TS-REQ-005`, `TS-REQ-007` | `TS-TEST-002`, `TS-TEST-006` |
| `PRD-NFR-003` | `TS-REQ-006`, `TS-REQ-008` | `TS-TEST-005`, `TS-TEST-006` |
| `PRD-AC-001` | `TS-REQ-001` | `TS-TEST-001` |
| `PRD-AC-002` | `TS-REQ-001` | `TS-TEST-002` |
| `PRD-AC-003` | `TS-REQ-002`, `TS-REQ-005` | `TS-TEST-004` |
| `PRD-AC-004` | `TS-REQ-003`, `TS-REQ-004` | `TS-TEST-003` |
| `PRD-AC-005` | `TS-REQ-005` | `TS-TEST-006` |
| `PRD-AC-006` | `TS-REQ-006`, `TS-REQ-008` | `TS-TEST-005`, `TS-TEST-006` |

## 8. Assumptions, risks и open questions

- Assumption: current SFX §9.11 и перечисленные canonical owner paths существуют на implementation baseline; их drift должен проявиться deterministic validator failure.
- Risk: literal-anchor validation намеренно не доказывает Luau reachability. Mitigation: existing Studio runners/suites остаются владельцами execution semantics; feature не меняет `src/**`.
- Risk: test-only tracked fixture может потребовать local Git tooling. Mitigation: Git уже обязателен для repository workflow; production validator от Git не зависит.
- Open product questions: нет.
- Unresolved scope/architecture escalations: нет.

Документ остаётся `draft` до controller-owned acceptance/readiness transitions. Явный approval пользователя относится к точному submitted SHA, который должен записать controller.
