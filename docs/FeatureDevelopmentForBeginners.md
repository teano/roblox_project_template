# Разработка фич без лишнего процесса

Этот шаблон даёт готовые runtime-системы, но обычная задача выполняется
напрямую. Не нужно запускать feature lifecycle, requirements/specification
pipeline, ADR workflow или Rojo перед каждой правкой.

## Обычная задача

1. Прочитайте [AGENTS.md](../AGENTS.md).
2. Через [.agents/rules/index.md](../.agents/rules/index.md) откройте только
   правила затронутых путей и runtime concerns.
3. Внесите небольшую законченную правку.
4. Выполните focused проверки из
   [.agents/rules/testing.md](../.agents/rules/testing.md).
5. Сообщите, что проверено и что не запускалось.

Если меняются только rules или Markdown, обычно достаточно проверить ссылки и
`git diff --check`. Если меняется Luau, нужен focused runner и временный Rojo
build. Studio нужен только для поведения, которое нельзя доказать статически.

## Необязательный feature record

Для долгой или распределённой работы просто скажите агенту «начни фичу ...».
Он автоматически применит `$feature-start`, создаст короткую repository-owned
запись и продолжит запрошенную работу в том же сообщении. Дальше можно сказать
«поставь на паузу», «продолжи TF-0001» или «заверши TF-0001»; соответствующие
skills сохранят handoff, восстановят контекст или проверят и закроют работу.
PowerShell вручную запускать не требуется.

Внутренний backend агента:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 new `
  -RepositoryPath $PWD.Path -Title "Feature name"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 status `
  -RepositoryPath $PWD.Path
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/feature.ps1 close `
  -RepositoryPath $PWD.Path -Feature TF-0001
```

Состояний только два: `open` и `done`; Pause не добавляет третье состояние.
Record не создаёт ветку, lease, pipeline, разрешение на работу или
обязательный набор документов. Его можно не создавать вовсе.

## Новый или обновляемый derived project

Создание, проверка, legacy bootstrap и атомарное обновление описаны в
[TemplateWorkflow.md](TemplateWorkflow.md). Единственный интерфейс —
`scripts/template-project.ps1 init|update|validate`. Primary init принимает
target URL и explicit destination; update требует exact repository root и
already-fetched target ref. Никакой implicit push, force-push, publish или
автоматической смены update-ветки нет.

## Studio

Перед Studio/live-sync запустите `scripts/ensure-rojo-server.ps1` и выберите
правильный уже открытый instance по canonical place/cloud identity. Не
открывайте duplicate Studio session при недоступном connector. Перед обычным
редактированием файлов этот preflight не требуется.

## Когда нужен ADR

ADR полезен для долговечного решения, которое меняет несколько систем или
будущую совместимость template/derived projects. Он не нужен для каждой фичи,
локального конфликта или изменения template-owned path. Правила находятся в
[docs/adr/README.md](adr/README.md).
