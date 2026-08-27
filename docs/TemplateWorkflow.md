# Работа с Roblox-шаблоном

Шаблон ускоряет разработку за счёт готовых runtime-систем и небольшого набора
прямых инструментов. Обычная правка не требует запуска feature lifecycle,
specification pipeline, ADR workflow или Studio.

## Обычная правка

1. Прочитайте `AGENTS.md` и выберите только затронутые правила через
   `.agents/rules/index.md`.
2. Внесите правку напрямую.
3. Выполните минимальную проверку из `.agents/rules/testing.md`.

Rojo server нужен перед Studio/live-sync, но не перед редактированием файлов.
Feature record и ADR создаются только когда они действительно полезны.

## Новый проект

Для пустого target repository используйте один bootstrap command. `-Check`
проверяет URL и explicit destination без записи; `-Apply` создаёт checkout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 init `
  -OriginUrl https://github.com/OWNER/PROJECT.git `
  -Destination D:\Projects\PROJECT -Check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 init `
  -OriginUrl https://github.com/OWNER/PROJECT.git `
  -Destination D:\Projects\PROJECT -Apply
```

Команда клонирует общую template history, переименовывает template remote в
`upstream`, добавляет target как `origin`, удаляет непринадлежащие игре cloud
IDs шаблона, создаёт required project-owned UI config и выполняет локальную
проверку. Она не публикует Roblox place, не включает production DataStore и
не commit/push без отдельного `-Push`.

Непустой unrelated repository не импортируется автоматически.
Default template URL — `https://github.com/teano/roblox_project_template.git`;
при необходимости передайте `-TemplateUrl` и exact `-TargetRef`. Уже
подготовленный shared-history checkout можно инициализировать advanced mode:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 init `
  -RepositoryPath D:\Projects\PROJECT -TargetRef refs/remotes/upstream/main -Check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 init `
  -RepositoryPath D:\Projects\PROJECT -TargetRef refs/remotes/upstream/main -Apply
```

### Локальный клиент без Git

Если клиентскому проекту намеренно не нужен repository, используйте local
template checkout и полный commit ID. Destination должен отсутствовать или
быть пустым и находиться вне любого Git worktree:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 init `
  -TemplateUrl D:\Projects\roblox_project_template `
  -Destination D:\Projects\LocalGame `
  -TargetRef 0123456789abcdef0123456789abcdef01234567 -Check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 init `
  -TemplateUrl D:\Projects\roblox_project_template `
  -Destination D:\Projects\LocalGame `
  -TargetRef 0123456789abcdef0123456789abcdef01234567 -Apply
```

`-Check` ничего не создаёт. `-Apply` берёт только tracked snapshot exact commit
через `git archive`, выполняет обычные init transforms в sibling staging,
проверяет структуру и temporary Rojo build, затем атомарно публикует папку.
Working-tree, ignored и untracked файлы template не копируются; `.git`, remote,
commit и push не создаются. При ошибке absent/empty состояние destination
восстанавливается. Для такого клиента предусмотрены feature records, но не
originless update, repair или validate.

## Repair legacy checkout

Если derived project уже имеет project-owned non-template Rojo `name`, но ещё
не содержит
`src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau`, используйте
явный compatibility repair. Cloud identity tuple может полностью отсутствовать
у unpublished project либо быть полной valid project-owned tuple. Partial
tuple и template validation identity блокируют repair.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 repair `
  -RepositoryPath D:\Projects\PROJECT -TargetRef refs/remotes/upstream/main -Check
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 repair `
  -RepositoryPath D:\Projects\PROJECT -TargetRef refs/remotes/upstream/main -Apply
```

`-Check` только показывает single-file plan. `-Apply` создаёт exact strict
frozen-empty config, выполняет structural validation и temporary Rojo build.
Repair требует clean tracked worktree/index и отсутствие non-ignored untracked
paths. Команда не перезаписывает существующий config и byte-preserves
`default.project.json` вместе с name, отсутствующей или полной cloud identity
tuple и `servePort`, а также README, `place.rbxl` и существующие project
namespaces. При ошибке новый файл удаляется и exact pre-state проверяется;
commit/push не выполняется.

## Проверка обновления

В derived project:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 update `
  -RepositoryPath D:\Projects\PROJECT -TargetRef refs/remotes/upstream/main -Check
```

Инструмент не fetch-ит ref: fetch выполняется отдельно до команды. Проверка
показывает exact target commit и не меняет checkout. Если target уже содержится
в `HEAD`, результат — no-op.

## Применение обновления

Выберите нужную ветку сами, убедитесь, что tracked worktree и index чисты, и
выполните:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 update `
  -RepositoryPath D:\Projects\PROJECT -TargetRef refs/remotes/upstream/main -Apply
```

Команда выполняет один атомарный no-commit merge, проверяет staged tree и только
после успеха завершает merge. При конфликте или ошибке она возвращает checkout
к записанному pre-update состоянию и выводит rollback receipt.

Автоматически сохраняются:

- полный project `place.rbxl`;
- project `README.md`;
- `src/ReplicatedStorage/Project/**`;
- `docs/adr/project/**` и `docs/Features/project/**`, если они существуют;
- project-owned `default.project.json` name, cloud identity и существующий
  custom `servePort`.

Другие непересекающиеся изменения объединяет Git. Настоящий конфликт требует
решения пользователя, а не обязательного ADR на каждый изменённый путь.
Non-ignored untracked files блокируют update. Ignored legacy artifacts команда
не удаляет, но incoming path не должен с ними пересекаться.

После успешного обновления повторный `update -Check` с теми же
`-RepositoryPath` и `-TargetRef` должен вернуть no-op.

## Переход старого derived project

Старый checkout может использовать инструмент прямо из целевой версии, не
исполняя старые rules, skills или pipeline state:

```powershell
git fetch upstream
$RepositoryPath = (Resolve-Path -LiteralPath .).Path
$TargetRef = "refs/remotes/upstream/main"
$BootstrapPath = Join-Path ([IO.Path]::GetTempPath()) "template-project-bootstrap.ps1"
$Source = @(git show "${TargetRef}:scripts/template-project.ps1") -join "`n"
[IO.File]::WriteAllText($BootstrapPath, $Source, (New-Object Text.UTF8Encoding($false)))
powershell -NoProfile -ExecutionPolicy Bypass -File $BootstrapPath update `
  -RepositoryPath $RepositoryPath -TargetRef $TargetRef -Check
powershell -NoProfile -ExecutionPolicy Bypass -File $BootstrapPath update `
  -RepositoryPath $RepositoryPath -TargetRef $TargetRef -Apply
Remove-Item -LiteralPath $BootstrapPath -Force
```

Задайте `$TargetRef` как конкретный tag или commit, если проект должен принять
зафиксированную версию.

Если этот старый checkout уже имеет project-owned identity, но в нём нет exact
derived UI config, тем же временным `$BootstrapPath` сначала выполните
`repair -Check`, затем `repair -Apply`. Старые rules, skills и pipeline state
для этого не запускаются.

## Опциональный feature record

Для долгой работы попросите агента естественным языком: «начни фичу»,
«поставь на паузу», «продолжи F-0001» или «заверши фичу». Явные формы —
`$feature-start`, `$feature-pause`, `$feature-continue`, `$feature-finish`.
Skills выбираются автоматически при однозначном намерении и сами используют
backend; пользователю не нужно запускать PowerShell.

Backend остаётся доступен агенту и CLI-пользователю:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 new -RepositoryPath $PWD.Path -Title "Feature name"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 status -RepositoryPath $PWD.Path
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 close -RepositoryPath $PWD.Path -Feature F-0001
```

Состояний только два: `open` и `done`. Pause сохраняет текущий handoff без
третьего состояния; Continue читает его и работает в том же сообщении; Finish
выполняет пропорциональные проверки до `done`. Инструмент не владеет ветками,
lease, pipeline, релизом или контекстом Codex. Старые manifests можно
мигрировать отдельно; исходный manifest сохраняется как history, а inherited
template records в derived project остаются read-only.

## Проверки

Generic validation всегда read-only:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/template-project.ps1 validate `
  -RepositoryPath $PWD.Path -RepositoryRole Auto
```

`Auto` определяет template/project по canonical remotes. Явный `Project`
требует template `upstream`. Явный `Template` — fail-closed escape hatch только
для проверенного template checkout без `upstream`, когда canonical origin
недоступен; он не превращает derived project в template.

- Rules/docs: ссылки и `git diff --check`.
- Template tooling: PowerShell tool suite и bounded structural validation.
- Luau: временный Rojo build и focused runner.
- Studio: только когда нужно проверить реальное runtime/DataModel поведение, с
  обязательным выбором правильного уже открытого instance.

Полная маршрутизация находится в `.agents/rules/testing.md`.
