# Оптимизация Feature Workflow — продуктовые требования

- Status: Approved
- Date: 2026-08-12
- Feature: TF-0009
- Approval source: явное согласие пользователя со всеми выводами аудита и последующий запрос на реализацию

## 1. Цель

Сделать операции `Continue` и `Pause` дешёвыми, предсказуемыми и строго
ограниченными своим lifecycle-назначением. Возобновление должно только вернуть
приостановленную фичу в активное состояние и дать агенту краткое общее
представление о ней. Контекст для последующей разработки, проверки или другого
процесса загружает уже тот процесс, который пользователь вызовет отдельно.

## 2. Пользовательский результат

После отдельного вызова `$feature-continue` пользователь получает активную
фичу, восстановленный writer lease и короткий отчёт: что это за фича, что в
общих чертах уже сделано, какие есть блокеры и какой следующий шаг был записан
при паузе. Агент не начинает этот шаг и завершает текущий turn.

После отдельного вызова `$feature-pause` пользователь получает только
фактический checkpoint уже выполненной работы. Pause не создаёт новую работу,
не добывает новое verification evidence и не делегируется сабагенту.

## 3. Область изменений

В scope входят:

- контракт lifecycle-команд и skills `Continue` и `Pause`;
- правила минимального контекста при восстановлении;
- нормализация однозначного числового суффикса feature ID;
- agent rules, пользовательская документация, ADR и enforcement-проверки,
  необходимые для закрепления этих контрактов;
- существующие manifest, lease, namespace и dashboard-механизмы только в той
  мере, в которой нужно сохранить их текущее поведение.

## 4. Вне области изменений

Вне scope находятся:

- реализация продуктовых или игровых фич;
- изменение содержимого PRD, specification, полного worklog, controller state
  или исходного кода возобновляемой фичи во время Continue-only turn;
- запуск GameDev/implementation pipeline, review или аудита из Continue;
- создание нового verification evidence во время Continue или Pause;
- изменение user-only authority над lifecycle-переходами;
- изменение владельческих границ template/project namespace, branch
  reservation, writer lease или generated dashboard;
- автоматическое исправление неоднозначного имени или ID фичи.

## 5. Функциональные требования

### FR-1. Граница Continue

`Continue` разрешён только для `in_progress/paused` после явной текущей команды
пользователя. Успешный Continue обязан:

1. проверить recorded branch, `baseCommit`, namespace ownership, branch
   reservation и отсутствие конфликтующего lease;
2. приобрести feature-scoped writer lease;
3. перевести activity из `paused` в `active`;
4. записать обновлённый manifest и синхронизировать owning dashboard;
5. сформировать базовый обзор только из `feature.json` и `handoff.md`;
6. вывести краткий результат и завершить turn.

### FR-2. Минимальный контекст Continue

Во время Continue-only turn feature-контекст ограничен полным чтением только:

- `feature.json`;
- `handoff.md`.

Краткий отчёт должен содержать доступные из этих артефактов:

- namespace, feature ID, status/activity, recorded branch и `baseCommit`;
- общий результат и текущее состояние;
- важные ранее записанные решения;
- блокеры;
- записанный следующий шаг.

Continue-only turn не должен читать для восстановления:

- product requirements или technical specification;
- полный `worklog.md`;
- Git diff, историю commit, перечень staged/unstaged/untracked изменений или
  иное исследование изменений от `baseCommit`;
- subsystem rules, system documentation или Accepted ADR;
- GameDev/controller state;
- исходный код фичи или тестов.

Обязательные repository control files, уже требуемые средой для безопасного
исполнения самого lifecycle transition, не становятся контекстом
возобновляемой работы и не разрешают расширять перечисленный feature-контекст.

### FR-3. Terminal fence Continue

Записанный в handoff следующий шаг является только информацией для пользователя
и будущего процесса. Он не является разрешением выполнить этот шаг.

После краткого recovery-отчёта агент обязан завершить turn. В Continue-only
turn запрещены:

- implementation, исправления, review или аудит;
- запуск любого production/GameDev pipeline;
- source edits;
- тесты и validators;
- Rojo preflight или Rojo build;
- Roblox Studio операции;
- создание или запуск сабагентов.

### FR-4. Ленивая загрузка рабочего контекста

После Continue пользователь отдельным сообщением явно выбирает следующий
процесс. Только этот процесс загружает необходимый ему контекст — PRD,
specification, development plan, controller state, worklog, Git, исходники,
subsystem rules, документацию, ADR и verification evidence — причём лишь в
объёме, требуемом его собственным контрактом.

Continue не предугадывает будущий процесс и не выполняет его preflight.

### FR-5. Граница Pause

`Pause` разрешён только для `in_progress/active` после явной текущей команды
пользователя. Он обязан записать в handoff и append-only worklog фактический
checkpoint, перевести activity в `paused`, освободить writer lease,
синхронизировать owning dashboard и сохранить branch reservation.

Checkpoint содержит только уже известные факты:

- результат и текущее состояние;
- важные решения и обсуждения;
- фактическое состояние уже выполненных проверок;
- блокеры;
- один следующий шаг.

Pause не запускает реализацию, исследование, тесты, validators, Rojo, Studio,
pipeline или иные проверки для дополнения checkpoint. Обычный Pause выполняет
текущий агент без создания или привлечения сабагента.

### FR-6. Нормализация числового суффикса

Ввод, состоящий только из числового суффикса, например `0009`, может быть
нормализован в полный feature ID только тогда, когда среди всех видимых
namespace существует ровно одно совпадение по этому суффиксу.

- Одно совпадение: использовать найденный канонический `TF-####` или `F-####`.
- Нет совпадений: завершить без lifecycle mutation и запросить полный ID или
  корректное имя.
- Несколько совпадений: завершить без lifecycle mutation, перечислить
  кандидатов и запросить полный ID.

Агент и lifecycle command не выбирают namespace по текущей ветке, repository
role, порядку поиска или предположению о намерении пользователя.

### FR-7. Сохранение lifecycle authority

Только явная команда пользователя в текущем сообщении разрешает Start,
Continue, Pause, Reopen или Finish. Реализация, успешная проверка, результат
сабагента, окончание turn или распознанный numeric suffix не являются
источником lifecycle authorization.

### FR-8. Сохранение архитектурных инвариантов

Оптимизация обязана сохранить:

- раздельную ownership-модель template и project feature namespace;
- запрет мутации foreign namespace;
- одну `in_progress` feature на recorded branch;
- schema-v2 feature-scoped writer lease без chat/session/agent identity;
- fail-closed branch, `baseCommit`, lease и initialization gates;
- owning-only dashboard synchronization и byte-identical сохранение foreign
  dashboard;
- append-only семантику `worklog.md`;
- отсутствие raw transcripts и product-specific identity в durable artifacts.

## 6. Нефункциональные требования

### NFR-1. Ограниченность контекста

Стоимость Continue не должна расти вместе с размером PRD, specification,
worklog, Git history, исходников или controller state. Базовое восстановление
зависит только от размера manifest и handoff.

### NFR-2. Детерминированность

При одинаковом repository state lifecycle command должен одинаково разрешать
или отклонять transition и numeric-suffix resolution независимо от агента,
чата, локали и порядка файловой системы.

### NFR-3. Fail-closed поведение

Отсутствующий или неоднозначный feature, неверное состояние, branch mismatch,
невалидный `baseCommit`, foreign namespace или conflicting lease должны
останавливать операцию до lifecycle mutation.

### NFR-4. Проверяемость контракта

Validator и deterministic contract tests должны защищать минимальный контекст,
terminal fence Continue, factual-only Pause, запрет Pause-subagent и правила
unique-only numeric normalization.

### NFR-5. Совместимость

Публичные канонические ID, branch formats, manifest schema, dashboard format и
существующие корректные полные ID/имена должны продолжить работать без
миграции.

## 7. Критерии приёмки

1. Continue корректной paused feature переводит её в `in_progress/active`,
   приобретает lease и синхронизирует только owning dashboard.
2. Recovery-отчёт Continue строится только из `feature.json` и `handoff.md` и
   содержит краткое состояние, решения, блокеры и информационный next step.
3. Continue contract явно завершает turn после отчёта и не запускает работу,
   проверки, Rojo, Studio, pipeline или сабагентов.
4. Contract tests отклоняют Continue skill, если из него удалены minimal-context
   boundary или terminal fence.
5. Lifecycle CLI больше не направляет агента к обязательному чтению полного
   worklog или Git range в Continue-only flow.
6. Следующий явно вызванный процесс самостоятельно и лениво загружает свой
   task-specific контекст.
7. Pause записывает factual checkpoint из существующих данных, не создаёт
   verification evidence и не запускает сабагента.
8. Однозначный numeric suffix разрешается в единственный полный ID; ноль или
   несколько совпадений fail closed до любой mutation.
9. Полные ID и существующие однозначные имена сохраняют прежнее корректное
   разрешение.
10. User-only lifecycle authority, namespace isolation, branch reservation,
    lease contract, append-only worklog и dashboard invariants проходят
    существующие и новые regression checks.

## 8. Риски и меры снижения

### Риск: handoff недостаточен для общего обзора

Некачественный Pause может оставить слишком общий handoff. Мера снижения:
сохранить обязательную структуру factual checkpoint и считать её качество
ответственностью Pause, не компенсируя пробел полной загрузкой контекста на
Continue.

### Риск: агент воспримет next step как команду

Мера снижения: закрепить informational-only семантику и обязательный end-turn
fence одновременно в high-precedence rules, skill, validator и tests.

### Риск: запрет проверок будет ошибочно распространён на последующую работу

Мера снижения: явно ограничить запрет Continue-only и Pause-only turn. Позже
явно вызванный implementation или verification process выполняет собственные
обязательные проверки.

### Риск: одинаковый номер существует в template и project namespace

Мера снижения: unique-only resolution по всем видимым namespace и fail-closed
ответ с кандидатами при неоднозначности.

### Риск: оптимизация ослабит существующие ownership gates

Мера снижения: не менять порядок state/branch/base/lease/namespace проверок и
добавить regression coverage сохранённых инвариантов.

## 9. Подтверждённые решения

- Полное восстановление рабочего контекста на Continue признано избыточным.
- `feature.json` и `handoff.md` являются достаточным базовым контекстом для
  общего понимания фичи после активации.
- Дальнейший фронт работ выбирает пользователь отдельным процессом; этот
  процесс сам отвечает за необходимый контекст и verification.
- Continue и Pause не выполняют новую проверочную или производственную работу.
- Неоднозначная сокращённая ссылка на feature никогда не разрешается
  предположением агента.
