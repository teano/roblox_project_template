# Шаблонный проект Roblox

Production-oriented основа для модульных Roblox-игр на
[Rojo](https://rojo.space/). Шаблон даёт готовую инфраструктуру, тесты и
архитектурные границы, но не навязывает тяжёлый процесс разработки.

Обычные изменения выполняются напрямую. Краткий workflow создания и обновления
игр: [docs/TemplateWorkflow.md](docs/TemplateWorkflow.md).

## Включённые системы

- явные server/client initialization manifests и по одному bootstrap на сторону;
- immutable side-owned asset catalogs и catalog-backed content preloading;
- generation-safe object pools;
- централизованный player/character lifecycle и side-local `Signal`;
- bounded client/server communication, sequencing, backpressure и resync;
- server-owned Experience Config catalog с безопасными client projections;
- controller-based save system, DataStore storage, session locks, autosave,
  shutdown и migrations;
- server-authoritative Wallet и bounded Statistics snapshots;
- server-owned Teleport session continuity;
- локальная Audio configuration, playback/graph/Music/settings и QA tooling;
- client UI root, HUD/toast/window hosts, navigation и data-only authoring;
- deterministic Studio test runners и отдельный opt-in DataStore smoke test.

Конкретная игровая логика, карта, содержимое HUD/windows, экономика, покупки,
инвентарь и игровые ассеты остаются ответственностью derived project.

## Требования

- Roblox Studio;
- [Rokit](https://github.com/rojo-rbx/rokit) или Rojo 7.7;
- Roblox Studio Rojo plugin;
- CodeGraph — опционально для навигации по коду, не для runtime.

```powershell
rokit install
```

CodeGraph setup описан отдельно в
[docs/CodeGraphSetup.md](docs/CodeGraphSetup.md). Его отсутствие не блокирует
обычную работу.

## Прямой workflow

Правила для агента начинаются с [AGENTS.md](AGENTS.md), а
[.agents/rules/index.md](.agents/rules/index.md) направляет только к реально
затронутым subsystem rules.

Не требуется автоматически запускать feature lifecycle, requirements,
specification, planning pipeline, ADR workflow, Rojo или Studio перед каждой
правкой. Проверки выбираются по фактическому риску изменения.

Для долгой работы пользователь обращается к агенту обычным языком или через
явные skills:

```text
$feature-start Inventory system
$feature-pause TF-0012
$feature-continue TF-0012
$feature-finish TF-0012
```

Эквивалентны фразы «начни фичу Inventory», «поставь TF-0012 на паузу»,
«продолжи TF-0012» и «заверши TF-0012». Агент сам вызывает backend; вручную
запускать PowerShell не нужно. Записи имеют только состояния `open|done`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 new -RepositoryPath $PWD.Path -Title "Feature name"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 status -RepositoryPath $PWD.Path
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 close -RepositoryPath $PWD.Path -Feature TF-0001
```

Эти PowerShell-команды являются внутренним/CLI-интерфейсом, а не обязательным
пользовательским ритуалом. Pause сохраняет handoff при состоянии `open`,
Continue сразу возобновляет работу, Finish проверяет результат перед `done`.
Feature record не владеет веткой, lease, pipeline или релизом.

## Создание derived project

Для пустого target repository выполните check и apply. `-Check` не создаёт
checkout, `-Apply` создаёт shared-history project:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 init `
  -OriginUrl https://github.com/OWNER/PROJECT.git `
  -Destination D:\Projects\PROJECT -Check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 init `
  -OriginUrl https://github.com/OWNER/PROJECT.git `
  -Destination D:\Projects\PROJECT -Apply
```

Init клонирует template history, настраивает game `origin` и template
`upstream`, удаляет template cloud identity, создаёт required project-owned UI
config и выполняет локальную проверку. Она не публикует Roblox place, не
включает production DataStore и не commit/push без отдельного `-Push`.
`-TemplateUrl` и exact already-fetched `-TargetRef` можно переопределить;
prepared checkout остаётся advanced compatibility mode через
`-RepositoryPath`.

## Обновление из template upstream

В нужной ветке derived project:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 update `
  -RepositoryPath D:\Projects\PROJECT -TargetRef refs/remotes/upstream/main -Check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 update `
  -RepositoryPath D:\Projects\PROJECT -TargetRef refs/remotes/upstream/main -Apply
```

Update требует clean tracked state/index и отсутствия non-ignored untracked
files. Ignored legacy artifacts остаются на месте, пока incoming target не
пересекается с ними. Команда сохраняет project `place.rbxl`, README, project
namespaces и Rojo/cloud identity, а при конфликте атомарно возвращает
pre-update состояние. Непересекающиеся project изменения объединяет обычный
three-way merge; обязательный ADR на каждый template-owned path не нужен.

Legacy bootstrap и подробные protected-path правила находятся в
[docs/TemplateWorkflow.md](docs/TemplateWorkflow.md).

## Repair старого derived project

Если derived project уже имеет собственный non-template Rojo `name`, но был
создан до появления обязательного `DerivedWindowConfig.luau`, используйте
узкий compatibility repair. Cloud identity может полностью отсутствовать у
unpublished project либо быть полной valid project-owned tuple; partial tuple
и template validation identity отклоняются.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 repair `
  -RepositoryPath D:\Projects\PROJECT -TargetRef refs/remotes/upstream/main -Check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 repair `
  -RepositoryPath D:\Projects\PROJECT -TargetRef refs/remotes/upstream/main -Apply
```

Repair создаёт только отсутствующий empty config, byte-preserves project
config, отсутствие или полную cloud identity tuple, `servePort`, README и
`place.rbxl`, сохраняет project namespaces, проверяет Rojo build и откатывается
при ошибке. Существующий config он не перезаписывает, commit/push не выполняет.

Обычная read-only проверка использует `-RepositoryRole Auto`. Для проверенного
template checkout без доступного canonical origin разрешён явный fail-closed
режим `-RepositoryRole Template`; `Project` требует canonical `upstream`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 validate `
  -RepositoryPath $PWD.Path -RepositoryRole Auto
```

## Studio и cloud identity

Перед первой Studio/live-sync операцией выполните:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ensure-rojo-server.ps1
```

До обычного редактирования файлов preflight не нужен. Команда использует
configured `servePort`, а при его отсутствии — стандартный endpoint.

Переиспользуйте уже открытый matching Studio instance:

- unpublished project определяется каноническим `place.rbxl`;
- published project — точными записанными `game.PlaceId` и `game.GameId`.

Не открывайте duplicate session при недоступном connector. Published project
должен иметь top-level `placeId`, `gameId` и `servePlaceIds` в
`default.project.json`. После первого user-authorized publish/attachment
считайте источником ID только фактический resulting DataModel; не угадывайте их
из URL, имени или выбранного destination.

## Hybrid ownership

| Источник | Владеет |
|---|---|
| `src/`, `default.project.json` | Rojo-managed scripts, Instances, mappings и properties |
| `place.rbxl` | Studio-authored scene data вне Rojo mappings |

`place.rbxl` — бинарный канонический источник сцены. Не объединяйте и не
исправляйте его программно; при конфликте выберите одну полную версию и
повторите другую scene change в Studio. Generated `.rbxlx`, `sourcemap.json`,
Studio locks и pipeline/test output не являются source.

## Архитектура и расширение

Исполняемые точки bootstrap:

```text
ServerScriptService/Bootstrap.server.luau
StarterPlayerScripts/Bootstrap.client.luau
```

Новый модуль получает зависимости через constructor, добавляется отдельной
командой в правильный side manifest и не создаёт собственный startup Script.
Авторитетное состояние остаётся на сервере; save providers принадлежат доменным
модулям, а обычная синхронизация использует компактные communication messages.

Основная документация:

- [Initialization and save](docs/InitializationAndSaveSystem.md)
- [Communication](docs/Communication.md)
- [Experience configuration](docs/ExperienceConfiguration.md)
- [Assets](docs/AssetRegistry.md)
- [Content preloading](docs/ContentPreloading.md)
- [Resource management](docs/ResourceManagement.md)
- [Signals](docs/Signal.md)
- [Teleport](docs/Teleport.md)
- [Audio](docs/AudioSystem.md)
- [UI](docs/UiSystem.md)
- [Statistics](docs/Statistics.md)
- [Data migrations](docs/UserDataMigrations.md)

## Проверки

Rojo build:

```powershell
rojo build default.project.json --output $env:TEMP\roblox-template-validation.rbxlx
```

Aggregate Studio suite в Play mode:

```lua
require(game.ServerScriptService.Tests.AllTestsRunner).runAll()
```

Не каждая правка требует aggregate или Studio. Точная risk-based матрица — в
[.agents/rules/testing.md](.agents/rules/testing.md), runtime coverage — в
[docs/TestCoverage.md](docs/TestCoverage.md).

Real DataStore smoke запускается только в dedicated integration Experience и
должен завершиться с `Ok=true` и `CleanupOk=true`; подробности в
[docs/IntegrationTesting.md](docs/IntegrationTesting.md).

## Структура

```text
src/                              Roblox runtime source
configs/                          authoring inputs
default.project.json              Rojo mapping and optional cloud identity
place.rbxl                        canonical Studio scene
scripts/template-project.ps1      init/repair/update/validate tool
scripts/feature.ps1               optional feature records
.agents/rules/                    focused agent rules
docs/adr/template/                template architectural history
docs/Features/template/           historical and current template records
```

## Лицензия

Код и документация доступны по [MIT License](LICENSE). Добавляйте только
ресурсы, которыми вы владеете или которые разрешено распространять.
