# Разработка игровой фичи: пошаговая инструкция

Эта инструкция предназначена для пользователя, который не умеет
программировать и не знаком с разработкой игр. Пользователь управляет
жизненным циклом фичи и принимает продуктовые решения. Агенты и skills ведут
требования, спецификацию, планирование, реализацию, проверки и документацию.

Инструкция рассчитана на:

- repository feature workflow этого проекта;
- Agentic GameDev Pipeline версии `0.5.0`;
- Specification Pipeline, который вызывается из GameDev-пайплайна;
- отдельные явные вызовы каждого lifecycle и GameDev skill.

## Где взять и как установить пайплайны

До начала первой фичи установите **оба** пакета:

1. [Agentic GameDev Pipeline версии 0.5.0](https://github.com/teano/agentic_game_development_pipeline_codex/) —
   Codex plugin с командами `$gamedev-*`;
2. [Specification Pipeline](https://github.com/teano/specification-pipeline-codex) —
   глобальный skill `$skill-specification-pipeline`, который при необходимости
   запускает `$gamedev-specification`.

Одного GameDev plugin недостаточно: стадия Specification использует второй
репозиторий как зависимость.

### Установка Agentic GameDev Pipeline 0.5.0

Самый простой способ — поручить установку отдельной задаче Codex.

1. Нажмите кнопку создания новой задачи (`+` или `New task`) в боковой панели
   Codex.
2. Откройте в этой задаче любой локальный репозиторий. Это только установочная
   задача; агент не должен менять файлы открытого проекта.
3. Отправьте одним сообщением следующий текст:

```text
Используй $plugin-creator и установи персональный Codex plugin из репозитория:
https://github.com/teano/agentic_game_development_pipeline_codex/

Нужна версия из Git tag v0.5.0.
Корень устанавливаемого plugin внутри репозитория:
agentic-gamedev-pipeline/
Имя plugin: agentic-gamedev-pipeline.

Зарегистрируй plugin в стандартном personal marketplace Codex.
Не перезаписывай и не удаляй существующие marketplace entries.
После регистрации верни кликабельную ссылку
View agentic-gamedev-pipeline на страницу plugin в Codex.
Если тебе доступен Codex CLI, можешь установить plugin командой
codex plugin add agentic-gamedev-pipeline@personal.

После регистрации или установки проверь, что пакет содержит файлы:
skills/gamedev-requirements/SKILL.md
skills/gamedev-specification/SKILL.md
skills/gamedev-development-plan/SKILL.md
skills/gamedev-pipeline/SKILL.md

Не изменяй файлы текущего проекта.
Если имя уже существующего personal marketplace отличается от personal,
сначала прочитай фактическое имя и используй его после символа @.
```

4. Дождитесь сообщения, что plugin зарегистрирован. Если агент вернул ссылку
   `View agentic-gamedev-pipeline`, нажмите её. Откроется страница plugin в
   Codex.
5. На странице plugin нажмите `Install` (`Установить`). Если агент уже успешно
   выполнил `codex plugin add`, кнопка должна показывать, что plugin установлен.
   Если агент сообщает об ошибке, не переходите к следующему этапу: попросите
   его исправить именно установку, не меняя игровой проект.
6. Закройте установочную задачу или оставьте её как есть. Для проверки
   обязательно создайте ещё одну **новую** задачу: уже открытая задача не
   получает новые skills задним числом.
7. В новой задаче отправьте:

```text
Проверь, что доступны следующие skills, но не запускай их:

$gamedev-requirements
$gamedev-specification
$gamedev-development-plan
$gamedev-pipeline

Ничего не изменяй.
```

Установка GameDev plugin завершена только тогда, когда Codex подтвердил
доступность всех четырёх skills в новой задаче.

### Установка Specification Pipeline

Рекомендуемый способ также использует отдельную установочную задачу Codex.

1. Нажмите кнопку создания новой задачи (`+` или `New task`).
2. Отправьте одним сообщением:

```text
$skill-installer

Установи Codex skill из GitHub-репозитория:
https://github.com/teano/specification-pipeline-codex

Skill находится в корне репозитория: path .
Установи его под именем: skill-specification-pipeline
Ожидаемый конечный файл:
<CODEX_HOME>/skills/skill-specification-pipeline/SKILL.md

После установки проверь наличие SKILL.md.
Не запускай $skill-specification-pipeline и не изменяй файлы текущего проекта.
```

3. Дождитесь подтверждения установки.
4. Создайте новую задачу Codex и отправьте:

```text
Проверь, что skill $skill-specification-pipeline доступен.
Не запускай его и ничего не изменяй.
```

Если `$skill-installer` недоступен, выполните ручную установку в PowerShell.
Эти команды предназначены для **первой** установки и специально прекращают
работу, если папка skill уже существует:

```powershell
$codexHome = if ($env:CODEX_HOME) {
    $env:CODEX_HOME
} else {
    Join-Path $env:USERPROFILE ".codex"
}

$skillDir = Join-Path $codexHome "skills\skill-specification-pipeline"

if (Test-Path $skillDir) {
    throw "Skill уже существует: $skillDir. Не перезаписывайте его вслепую."
}

git clone --depth 1 `
    https://github.com/teano/specification-pipeline-codex.git `
    $skillDir

if (-not (Test-Path (Join-Path $skillDir "SKILL.md"))) {
    throw "Установка не завершена: SKILL.md не найден."
}

Write-Host "Specification Pipeline установлен: $skillDir"
```

После ручной установки тоже создайте новую задачу Codex и выполните проверку
доступности skill из шага 4.

Важно: во время обычной работы над фичей пользователь не вызывает
`$skill-specification-pipeline` напрямую. Его установка обязательна, но
запускает его при необходимости `$gamedev-specification`.

## Главное правило

Каждый skill вызывается отдельным пользовательским сообщением. Не объединяйте
два lifecycle-перехода или две GameDev-стадии в одном сообщении.

Обычные фразы вроде «продолжай», «реализуй», «проверь» или «всё готово» не
запускают explicit-only skills. В сообщении нужно явно написать имя skill.

Полный штатный маршрут:

```text
$feature-start
    -> $gamedev-requirements
    -> $gamedev-specification
    -> $gamedev-development-plan
    -> $gamedev-pipeline
    -> $feature-finish
```

Пауза и восстановление:

```text
$feature-pause
    -> закрытие или смена задачи
    -> $feature-continue
    -> повторный явный вызов нужной $gamedev-* стадии
```

`$skill-specification-pipeline` пользователь не вызывает. При необходимости
его вызывает `$gamedev-specification` как внутреннего помощника.

## Актуальные команды

Feature lifecycle:

```text
$feature-start
$feature-continue
$feature-pause
$feature-finish
```

Подготовка и производство игровой фичи:

```text
$gamedev-requirements
$gamedev-specification
$gamedev-development-plan
$gamedev-pipeline
```

Реализация, Review, QA и доведение до production-ready candidate запускаются
через `$gamedev-pipeline`.

## 0. Подготовка Codex

После установки или обновления Agentic GameDev Pipeline откройте новую задачу
Codex. Уже открытая задача может хранить старый снимок доступных skills.

В новой задаче отправьте:

```text
Проверь доступность следующих skills, но не запускай их:

$feature-start
$feature-continue
$feature-pause
$feature-finish
$gamedev-requirements
$gamedev-specification
$gamedev-development-plan
$gamedev-pipeline

Ничего не изменяй.
```

Если хотя бы один skill недоступен, не начинайте фичу. Сначала установите или
обновите нужный пакет и снова откройте новую задачу Codex.

Для игровой фичи откройте derived-репозиторий конкретной игры. Не используйте
репозиторий `roblox_project_template`, если не изменяете сам reusable template.

## 1. Начало новой фичи

### Когда вызывать Start

Вызывайте `$feature-start`, когда:

- открыт правильный репозиторий игры;
- project initialization завершён;
- идея фичи уже сформулирована хотя бы одним абзацем;
- рабочая ветка и Git-состояние позволяют начать новую фичу;
- текущая ветка не зарезервирована другой `in_progress` фичей.

### Команда Start

Отправьте отдельным сообщением:

```text
$feature-start "<НАЗВАНИЕ ФИЧИ>"
```

Пример:

```text
$feature-start "Double Jump"
```

Не добавляйте в это сообщение просьбу сразу написать код или запустить
GameDev-пайплайн.

### Ожидаемый результат

Для derived-игры агент должен вернуть примерно следующее:

```text
Feature ID: F-0004
State: in_progress/active
Branch: feature/t-0004-double-jump
Namespace: project
```

Запомните стабильный ID, например `F-0004`. Во всех дальнейших командах
используйте именно ID, а не только название фичи.

Если Start отказался работать, не просите обойти проверку. Отправьте:

```text
Объясни причину отказа $feature-start простыми словами.
Не обходи feature workflow и не меняй состояние вручную.
```

## 2. Продуктовые требования

### Точка запуска

Запускайте Requirements, когда:

```text
Feature state: in_progress/active
PRD_READY: no
```

### Первая команда Requirements

```text
$gamedev-requirements F-0004

Подготовь продуктовые требования для этой фичи.

Идея:
<ОПИСАНИЕ ФИЧИ>

Объясняй решения через поведение игрока.
Задавай по одному самому важному вопросу.
Не переходи к specification, development plan или реализации.
```

Пример:

```text
$gamedev-requirements F-0004

Подготовь требования для двойного прыжка.

После первого прыжка игрок может ещё один раз прыгнуть в воздухе.
После приземления дополнительный прыжок восстанавливается.
Нужны мобильное управление, анимация и звук.

Объясняй решения через поведение игрока.
Задавай по одному вопросу.
Не переходи к следующим стадиям.
```

### Ответы на вопросы Requirements

Каждый ответ снова начинайте с имени skill:

```text
$gamedev-requirements F-0004

Мой ответ: дополнительный прыжок должен быть доступен всем игрокам сразу.
Продолжи ту же requirements-стадию.
```

Если вы не знаете ответ:

```text
$gamedev-requirements F-0004

Я не знаю ответа. Предложи рекомендуемый вариант для MVP и объясни его через
поведение игрока. Не переходи к следующей стадии.
```

### Утверждение PRD

Когда PRD готова, агент должен показать путь, revision, SHA-256 и ожидание
пользовательского approval.

Отправьте:

```text
$gamedev-requirements F-0004

Явно утверждаю текущий product-requirements.md:

Revision: <НОМЕР>
SHA-256: <ХЕШ>

Зафиксируй approval, проверь документ и верни точный PRD_READY.
Не запускай следующую стадию.
```

Успешный результат:

```text
PRD_READY: yes
NEXT_ACTION: $gamedev-specification
```

Только после `PRD_READY: yes` переходите к спецификации.

## 3. Техническая спецификация

### Точка запуска

Запускайте Specification, когда:

```text
PRD_READY: yes
SPEC_READY: no
NEXT_ACTION: $gamedev-specification
```

### Команда Specification

```text
$gamedev-specification F-0004

Запусти полную стадию технической спецификации для утверждённой PRD.

Внутри этой стадии при необходимости используй
$skill-specification-pipeline как внутреннего помощника.

Самостоятельно не запускай requirements, development plan или implementation.
Доведи стадию до SPEC_READY либо верни конкретный пользовательский вопрос.
```

Пользователь не вызывает `$skill-specification-pipeline` напрямую.

### Ответ на вопрос Specification

```text
$gamedev-specification F-0004

Моё решение по вопросу <ID ВОПРОСА>:

<РЕШЕНИЕ>

Продолжи эту же specification-стадию.
Не запускай development plan или implementation.
```

Если вопрос непонятен:

```text
$gamedev-specification F-0004

Я не понимаю вопрос <ID ВОПРОСА>.

Объясни варианты через конкретное поведение игрока, риски и стоимость.
Пока не изменяй спецификацию и не переходи дальше.
```

### Ожидаемый результат

```text
SPEC_READY: yes
PRD path/hash: ...
Specification path/hash: ...
NEXT_ACTION: $gamedev-development-plan
```

Отдельное пользовательское утверждение всей технической спецификации не
требуется, если Specification Director сам довёл её до `SPEC_READY`.
Пользователь принимает только те продуктовые, scope или архитектурно-граничные
решения, которые Director не имеет права принимать самостоятельно.

## 4. План разработки

### Точка запуска

Запускайте Development Plan, когда:

```text
PRD_READY: yes
SPEC_READY: yes
PLAN_READY: no
NEXT_ACTION: $gamedev-development-plan
```

### Команда Development Plan

```text
$gamedev-development-plan F-0004

Создай development plan на основании точных PRD_READY и SPEC_READY.

Для новичка:
- предпочитай single_owner или последовательные вертикальные slices;
- не разделяй работу на server/client/tests/docs;
- каждый slice должен давать проверяемый игровой результат;
- явно укажи проверки в Roblox Studio;
- явно укажи действия, которые потребуют моего участия.

Подготовь draft и остановись на пользовательском approval.
Не запускай implementation.
```

Агент должен показать:

```text
Plan path: ...
Mode: single_owner или sequential_slices
Submitted SHA-256: ...
PLAN_READY: no
NEXT_ACTION: user-decision
```

### Утверждение плана

```text
$gamedev-development-plan F-0004

Явно утверждаю текущий development-plan.md:

Submitted SHA-256: <ХЕШ>

Зафиксируй approval и верни точный PLAN_READY.
Не запускай runtime pipeline.
```

Успешный результат:

```text
PLAN_READY: yes
NEXT_ACTION: $gamedev-pipeline
```

Если план изменился после показа, старый SHA утверждать нельзя. Запросите новый
`Submitted SHA-256`.

## 5. Реализация, Review и QA

### Точка запуска

Запускайте Production Pipeline только когда одновременно получены:

```text
Feature state: in_progress/active
PRD_READY: yes
SPEC_READY: yes
PLAN_READY: yes
```

### Команда Production Pipeline

```text
$gamedev-pipeline F-0004

Запусти Agentic GameDev Production Pipeline по утверждённым PRD,
technical specification и development plan.

Доведи работу через:
- preflight;
- bounded research;
- coverage planning;
- engineering;
- automated verification;
- documentation;
- independent review;
- Roblox Studio QA;
- readiness.

Не вызывай $feature-pause или $feature-finish.
Останавливайся только на реальном пользовательском решении, пользовательском
действии, внешнем blocker или terminal PRODUCTION_READY_CANDIDATE.
```

### Ответ на запрос Production Pipeline

```text
$gamedev-pipeline F-0004

Моё решение по запросу <ID>:

<РЕШЕНИЕ>

Продолжи текущий pipeline с сохранённого controller state.
Не перезапускай завершённые стадии.
```

Если агент попросил вручную запустить Play после того, как подтвердил Rojo
preflight и правильный Studio instance:

```text
$gamedev-pipeline F-0004

Ручное действие выполнено: Play запущен в уже выбранном canonical Studio
instance.

Продолжи текущую QA-стадию с сохранённого controller state.
```

### Терминальный результат

Для завершения GameDev-пайплайна необходим именно такой итог:

```text
PRODUCTION_READY_CANDIDATE
NEXT_ACTION: terminal-production-ready-candidate
```

`ENGINEERING_PASS` недостаточно. Он означает только завершение инженерной
стадии; Review, QA и документация могут оставаться незавершёнными.

## 6. Пауза фичи

### Безопасные точки Pause

Пауза разрешена после того, как текущий skill завершил свой ответ и сохранил
состояние. Типичные безопасные точки:

- Requirements вернул вопрос или результат;
- получен `PRD_READY`;
- Specification вернул вопрос, hold или `SPEC_READY`;
- Development Plan вернул draft или `PLAN_READY`;
- Production Pipeline закончил текущий turn;
- Production Pipeline вернул `blocked_user`, `blocked_environment`, hold или
  пользовательский вопрос;
- закончен milestone или slice и controller state уже записан.

Не ставьте фичу на паузу посреди tool call или записи файлов.

Если пришлось аварийно остановить текущий ответ кнопкой Stop, сначала
отправьте:

```text
Проверь целостность feature и gamedev controller state после прерывания.

Ничего не продолжай и не изменяй автоматически.
Сообщи, безопасно ли вызывать $feature-pause F-0004.
```

### Команда Pause

Отправьте отдельным сообщением:

```text
$feature-pause F-0004

Зафиксируй в checkpoint:
- текущую gamedev-стадию;
- последние READY-токены;
- controller state;
- последний NEXT_ACTION;
- выполненные проверки;
- blockers;
- точный следующий skill-вызов.
```

Ожидаемый результат:

```text
Feature state: in_progress/paused
Writer lease: released
Branch: reserved
Handoff: updated
Worklog: updated
```

После этого задачу Codex можно закрыть.

У GameDev-пайплайна нет отдельной пользовательской команды Pause. Его
controller state сохраняется стадиями, а lifecycle-паузой управляет
`$feature-pause`.

## 7. Продолжение фичи

Продолжение всегда состоит из двух отдельных сообщений.

### Сообщение 1: Feature Continue

```text
$feature-continue F-0004
```

Дождитесь:

```text
Feature state: in_progress/active
Writer lease: acquired
Context: reconstructed
```

`$feature-continue` не продолжает GameDev-пайплайн. Он восстанавливает feature
state, ветку, lease и переносимый контекст.

### Сообщение 2: нужная GameDev-стадия

Выберите команду по восстановленному состоянию.

| Состояние | Команда после `$feature-continue` |
|---|---|
| `PRD_READY: no` | `$gamedev-requirements F-####` |
| `PRD_READY: yes`, `SPEC_READY: no` | `$gamedev-specification F-####` |
| `SPEC_READY: yes`, `PLAN_READY: no` | `$gamedev-development-plan F-####` |
| `PLAN_READY: yes`, pipeline не завершён | `$gamedev-pipeline F-####` |
| `PRODUCTION_READY_CANDIDATE` | `$feature-finish F-####` отдельным сообщением |

Продолжение Requirements:

```text
$gamedev-requirements F-0004

Продолжи requirements-стадию с восстановленного состояния.
Используй последний вопрос и NEXT_ACTION из handoff.
```

Продолжение Specification:

```text
$gamedev-specification F-0004

Продолжи specification-стадию с существующего specification controller state.
Не повторяй уже принятые циклы.
```

Продолжение Development Plan:

```text
$gamedev-development-plan F-0004

Продолжи development-plan стадию с существующего controller state.
Не создавай второй план и не меняй канонический путь.
```

Продолжение Production Pipeline:

```text
$gamedev-pipeline F-0004

Возобнови Agentic GameDev Production Pipeline с существующего
.agentic-pipeline/state.json.

Не переинициализируй завершённые стадии и не повторяй уже принятые результаты.
```

## 8. Завершение фичи

### Точка Finish

Вызывайте Finish только когда одновременно выполнено:

```text
Feature state: in_progress/active
PRD_READY: yes
SPEC_READY: yes
PLAN_READY: yes
Gamedev result: PRODUCTION_READY_CANDIDATE
Gamedev NEXT_ACTION: terminal-production-ready-candidate
Required repository checks: passed
Feature blockers: empty
```

Если фича находится в `in_progress/paused`, сначала отдельным сообщением
вызовите:

```text
$feature-continue F-0004
```

Дождитесь `in_progress/active`. После этого отправьте новое сообщение.

### Команда Finish

```text
$feature-finish F-0004
```

Не добавляйте `$gamedev-pipeline` в то же сообщение.

`$feature-finish`:

- не запускает тесты;
- не запускает Rojo build;
- не запускает Studio;
- проверяет уже собранные evidence;
- обновляет feature handoff и worklog;
- освобождает feature lease;
- переводит фичу в `ready`.

Успешный результат:

```text
Feature state: ready/none
Writer lease: released
Dashboard: synchronized
Blockers: none
```

### Если Finish отказался

Фича остаётся `in_progress/active`. Не повторяйте Finish вслепую.

Если не завершён GameDev runtime, отправьте:

```text
$gamedev-pipeline F-0004

Устрани gate, из-за которого $feature-finish отказался.
Доведи pipeline до PRODUCTION_READY_CANDIDATE.
Не вызывай $feature-finish автоматически.
```

После устранения blockers снова отдельным сообщением:

```text
$feature-finish F-0004
```

## 9. Переоткрытие завершённой фичи

Для фичи со статусом `ready` нельзя использовать `$feature-continue`.

Явный Reopen выполняется через `$feature-start`:

```text
$feature-start F-0004

Явно переоткрой готовую фичу.

Причина:
<ДЕФЕКТ ИЛИ НОВОЕ ТРЕБОВАНИЕ>
```

После Reopen агент должен вернуть:

```text
Feature state: in_progress/active
Branch: существующая записанная ветка
```

Следующая стадия зависит от причины:

- изменилось продуктовое поведение — `$gamedev-requirements`;
- PRD прежняя, но техническое решение изменилось — `$gamedev-specification`;
- PRD и specification готовы, но нужен новый план —
  `$gamedev-development-plan`;
- утверждённые документы и план остаются актуальными — `$gamedev-pipeline`.

## Короткая шпаргалка

Новая фича:

```text
$feature-start "Double Jump"
```

Требования:

```text
$gamedev-requirements F-0004
```

Спецификация:

```text
$gamedev-specification F-0004
```

План:

```text
$gamedev-development-plan F-0004
```

Реализация, Review и QA:

```text
$gamedev-pipeline F-0004
```

Пауза:

```text
$feature-pause F-0004
```

Возобновление, сообщение 1:

```text
$feature-continue F-0004
```

Возобновление, сообщение 2:

```text
$gamedev-requirements F-0004
```

или:

```text
$gamedev-specification F-0004
```

или:

```text
$gamedev-development-plan F-0004
```

или:

```text
$gamedev-pipeline F-0004
```

Завершение после `PRODUCTION_READY_CANDIDATE`:

```text
$feature-finish F-0004
```

## Связанные контракты

- [Feature workflow](../.agents/rules/feature-workflow.md)
- [Feature Start skill](../.agents/skills/feature-start/SKILL.md)
- [Feature Continue skill](../.agents/skills/feature-continue/SKILL.md)
- [Feature Pause skill](../.agents/skills/feature-pause/SKILL.md)
- [Feature Finish skill](../.agents/skills/feature-finish/SKILL.md)
- [ADR-0037: Reserve feature state transitions for users](adr/template/0037-reserve-feature-state-transitions-for-users.md)
- [Agentic Game Development Pipeline 0.5.0](https://github.com/teano/agentic_game_development_pipeline_codex/)
- [Specification Pipeline](https://github.com/teano/specification-pipeline-codex)
