---
document_type: product-requirements
status: approved
revision: 2
language: Russian
approved_at: 2026-08-04T09:45:04Z
---

# Product Requirements

## Product Outcome

Доказать, что серверный и клиентский `PlayersModule` как единая тестируемая граница Roblox Players production ready, стабилен и надежен во всех поддерживаемых lifecycle-сценариях. Канонические требования из обсуждения Codex task `019fa4c9-60ea-71c3-bff7-17927510b1b6`, текущие accepted rules и template ADR являются нормативной основой; замечания ревьюеров служат первыми сигналами для проверки, но не разрешением переписать модуль или автоматически признать дефект. Сначала завершается findings-first аудит всей системы и фиксируется полный inventory, затем допускается только минимальная evidence-backed ремедиация подтвержденных нарушений с полным impact analysis и регрессией всех связанных consumers.

## Target Audience

- Сопровождающие reusable Roblox template, которые отвечают за надежность player/character lifecycle.
- Разработчики производных игр, которым нужен понятный публичный контракт и одна точка интеграции с Roblox `Players`.
- Авторы тестов и систем-потребителей, которым нужны инъецируемые зависимости и детерминированные lifecycle-сценарии.

## Core Gameplay Loop

Это не игроко-ориентированная механика. Рабочий цикл сопровождающего имеет абсолютный порядок: восстановить канонический контракт и провести полный read-only аудит всех server/client implementations, consumers, manifests и tests → заморозить complete impact/finding inventory до любой source-правки, включая characterization или regression tests → добавить необходимое positive/negative/corner-case покрытие → оставить корректное production behavior без изменений либо минимально исправить подтвержденный дефект → повторно проаудировать весь исходный scope → проверить прямые и косвенные integrations → пройти production-readiness regression gates.

## Release Target

Production-readiness проход для reusable template с доказательствами реальной работоспособности, стабильности и надежности, а не локальной «чистоты» реализации. Gate включает полный findings-first аудит, необходимое positive/negative/corner-case покрытие, clean server/client runtime checks и регрессию initialization, Save, Teleport и других выявленных lifecycle consumers. Эти системы входят только как impact/regression scope: их редизайн, аудит несвязанных обязанностей или расширение feature scope запрещены. Engineer может минимально исправить evidence-backed in-scope дефекты после утверждения PRD и traced technical specification; если дефектов нет, исходный модуль не меняется.

## Scope

### In Scope

- Серверный `ServerScriptService.Modules.Players.PlayersModule` и клиентский `ReplicatedStorage.Client.Players.PlayersModule`.
- Публичные lifecycle-сигналы, lookup/observation helpers, composition в server/client manifests и связанные контрактные тесты.
- Existing-player delivery, join, leave, character add/remove, повторные `Initialize`/`Stop`, observer cleanup и consumer cleanup.
- Terminal lifecycle после `Stop` или неуспешного `Initialize`, включая детерминированный отказ public APIs завершенного instance и полноценный lifetime нового instance.
- Поддерживаемый client `WaitForCharacter` contract и явное исключение direct `Wait()` на публичных lifecycle signals из public contract `PlayersModule`.
- Точность публичных Luau-типов, включая типы сигналов и инъецируемого Players service double.
- Изоляция ошибок и yielding callback-ов согласно общему side-local `Signal` contract.
- Измеряемая стоимость delivery path и объяснимость абстракции для нового разработчика.
- Проверка, что production composition создает по одному владельцу платформенных подписок на каждой стороне, не запрещая fresh injected instances в тестах.
- Полный inventory прямых и косвенных consumers, initialization commands/manifests, test doubles и integration paths, на которые может повлиять изменение lifecycle contract.
- Регрессионная проверка Save, Teleport, initialization/bootstrap, shutdown и других найденных consumers только в части их взаимодействия с `PlayersModule`.

### Out of Scope

- Аудит `TeleportModule`, `TeleportService`, teleport data/session continuity и стратегии повторной загрузки данных.
- Редизайн Save, Teleport, initialization, communication или gameplay systems под видом регрессии их Players integration.
- Создание gameplay-oriented `PlayerService` или перенос save/gameplay/domain behavior в `PlayersModule`.
- Очередь или последовательный dispatcher между lifecycle-событиями, пока конкретный consumer contract и воспроизводимое нарушение не докажут такую необходимость.
- Изменение общей архитектуры initialization manifests, save system, communication transport или shared `Signal` без отдельного подтвержденного требования и архитектурного решения.
- Изменение общего `Shared/Util/Signal` только ради добавления Players-specific cancellation semantics или поддержки direct signal `Wait()`.
- Оптимизация по предположению без профиля, счетчиков вызовов или воспроизводимого сценария.

## Functional Requirements

- **PRD-REQ-001:** До любой source-правки, включая добавление либо изменение characterization/regression tests, должен завершиться полный read-only аудит публичного контракта, server/client implementations, manifests, lifecycle consumers, существующих tests и integration paths, после чего полный impact/finding inventory замораживается одним checkpoint; проход не завершается после первого дефекта и не начинает тестовую или production ремедиацию до этого checkpoint.
- **PRD-REQ-002:** Каждое исходное замечание — `any` в signal/service contracts, возможность нескольких экземпляров, `Stop` вместе с `ObservePlayers`, накладные расходы delivery path, ошибки callback-ов, отсутствие очередности, отсутствие отдельного `PlayerService` и сложность абстракции — является гипотезой и должно получить одну evidence-backed классификацию: подтвержденный дефект, подтвержденный риск/пробел тестов, допустимое архитектурное решение или out of scope. Для классификации требуется ссылка на канонический контракт, код и наблюдаемую проверку; мнение ревьюера или внешней модели само по себе доказательством не является.
- **PRD-REQ-003:** Production runtime должен иметь ровно одну side-specific границу, напрямую подписанную на Roblox player/character lifecycle, а consumers должны получать этот экземпляр через manifest composition. Конструкторные fresh instances с injected fakes должны оставаться доступными для изолированных тестов.
- **PRD-REQ-004:** Серверная подписка через `ObservePlayers` должна без дублей доставлять уже присутствующих и позднее присоединившихся игроков, перепроверять присутствие перед `onAdded`, очищать membership при удалении независимо от наличия `onRemoving` и предоставлять идемпотентное consumer-owned отключение.
- **PRD-REQ-005:** Серверный и клиентский lifecycle должны корректно доставлять character add/remove и освобождать character-bound platform connections, public-signal `Connect`/`Once` listeners, observer callbacks и dedicated waiters при удалении игрока, terminal `Stop`, initialize failure и повторной очистке.
- **PRD-REQ-006:** `Stop` является terminal finalizer, а не runtime pause: первый вызов полностью прекращает callbacks, завершает dedicated waits и освобождает все owner- и observer-resources; повторный `Stop` идемпотентен. Тот же stopped instance должен детерминированно отклонять `Initialize`, getters, observer registration и wait helpers с terminal lifecycle error; только fresh instance может полноценно начать новый lifetime.
- **PRD-REQ-007:** Future lifecycle callbacks, доставляемые через shared `Signal`, сохраняют non-blocking dispatch: ошибка или yield одного `Connect`/`Once` listener либо future observer callback не должны блокировать publisher или подавлять другие callbacks, а ошибка должна оставлять диагностируемый traceback. Initial existing-player phase `ObservePlayers` намеренно выполняется синхронно и последовательно в coroutine вызывающей стороны для совместимости с `TeleportValidationPad`: ошибка каждого initial `onAdded` изолируется и диагностируется, не препятствуя доставке следующих existing players; finite yield может задержать возврат `ObservePlayers` и более поздние initial callbacks, но не блокирует Roblox/Signal publisher, потому что эта фаза не выполняется внутри platform signal dispatch. Direct `Wait()` на публичных `PlayerAdded`, `PlayerRemoving`, `CharacterAdded` и `CharacterRemoving` не является поддерживаемым public contract `PlayersModule`.
- **PRD-REQ-008:** Публичные signal и service dependency contracts должны выражать поддерживаемые методы и payload-типы без необоснованной потери статической проверки. Любое оставшееся широкое типовое допущение требует зафиксированного ограничения Luau или test-double boundary.
- **PRD-REQ-009:** Любая ремедиация подтвержденных дефектов должна быть минимальной и адресной, сохранять централизованную lifecycle boundary и не добавлять save, teleport, gameplay или domain orchestration в `PlayersModule`; корректный код не переписывается ради стиля, упрощения или предпочтений ревьюера.
- **PRD-REQ-010:** Аудит и ремедиация должны сохранять согласованный ранее контракт: одна точка прямого использования Roblox `Players` на сторону, production instance через composition root, `GetPlayers`, `GetPlayerByUserId`, `ObservePlayers(onAdded, onRemoving)`, `PlayerAdded`/`PlayerRemoving`, немедленная доставка уже присутствующих и последующая доставка новых игроков, а также закрепленные rules/docs server character и client local-player/character возможности.
- **PRD-REQ-011:** Перед любой source-правкой должен быть определен полный impact set из manifests, initialization commands, direct/indirect consumers и tests; после правки их взаимодействие проверяется как единая система, а не только isolated unit path.
- **PRD-REQ-012:** Любой сбой `Initialize` должен откатить все частично приобретенные platform connections, signals/listeners, observers и другое module-owned state, после чего тот же instance переходит в terminal failed state и детерминированно отклоняет дальнейшие public operations; повторное начало lifetime возможно только через fresh instance.
- **PRD-REQ-013:** Client `WaitForCharacter` является единственным поддерживаемым Players-specific wait helper и должен либо вернуть character текущего active lifetime, либо завершиться на `Stop`/initialize failure с terminal lifecycle error; он не должен зависать после завершения lifetime.
- **PRD-REQ-014:** После заморозки audit inventory работа выполняется только в порядке: необходимое test coverage → минимальная production remediation подтвержденных findings → полный read-only resweep исходного scope → все focused и integration regressions.

## Quality Requirements

- **PRD-NFR-001:** Все lifecycle и observer операции должны быть идемпотентны там, где возможны повторные вызовы, и не удерживать platform connections либо consumer callback references после завершения соответствующего ownership lifetime.
- **PRD-NFR-002:** Контракт должен проверяться fresh instances и injected fakes без зависимости от реальных игроков, сетевых сервисов или случайного timing.
- **PRD-NFR-003:** Для одного lifecycle-события число consumer deliveries должно быть не больше одного на активного observer, а измеренный рост работы должен быть линейным по числу реально уведомляемых observers. Дополнительные platform lookups и scheduled tasks должны быть подсчитаны и обоснованы race-safety либо Signal semantics; произвольный численный performance threshold не вводится.
- **PRD-NFR-004:** Новый разработчик должен по публичному API, manifest composition, правилам и focused tests определить: кто владеет Roblox subscriptions, кто отключает observer connection и где должна жить последовательная domain-операция — без необходимости изучать Teleport или Save internals.
- **PRD-NFR-005:** Неожиданные warnings/errors в server/client Play считаются провалом release gate; ожидаемые listener-failure diagnostics должны быть явно проверены.
- **PRD-NFR-006:** Production-readiness вывод должен опираться на воспроизводимые automated и runtime доказательства для positive, negative и corner cases; отсутствие теста не считается доказательством корректности.
- **PRD-NFR-007:** Минимальная ремедиация не должна менять наблюдаемое поведение ни одного связанного consumer вне явно подтвержденного defective contract; любое намеренное изменение поведения требует отдельной трассировки к finding и regression assertion.

## Acceptance Criteria

- **PRD-AC-001:** До любой source edit, включая test/characterization edit, сформирована и заморожена полная evidence matrix всей Players system; runtime audit findings используют стабильный namespace `F-*` и получают classification, authority source, точную ссылку на код и ожидаемую positive/negative/corner-case проверку. Specification-review clarifications используют отдельный namespace `SRF-*`, становятся source clarifications и не подлежат повторной классификации runtime audit как дефекты или гипотезы.
- **PRD-AC-002:** Focused tests доказывают для server module: existing player при поздней подписке, обычный join, leave, character spawn/respawn/removal, игрок, ушедший во время enumeration, отсутствие duplicate delivery и membership cleanup без `onRemoving`.
- **PRD-AC-003:** Focused tests доказывают для client module: existing local character, последующий respawn/removal, недоступный `LocalPlayer`, terminal `Stop`, идемпотентный повторный `Stop`, детерминированный отказ `Initialize`/getters/waits после stop и полноценный `Initialize` fresh instance.
- **PRD-AC-004:** Cleanup tests удерживают счетчики platform и public-signal `Connect`/`Once` connections, observer callbacks и dedicated waiters и подтверждают их освобождение после consumer disconnect, player removal, terminal `Stop` и initialize failure; после завершения lifetime ни один старый callback не вызывается.
- **PRD-AC-005:** Type check или эквивалентная strict-source проверка подтверждает payload-типы `PlayerAdded`, `PlayerRemoving`, `CharacterAdded`, `CharacterRemoving`, client character signals и injected Players service contract; несовместимый callback либо payload дает статически обнаружимую ошибку там, где это поддерживает Luau.
- **PRD-AC-006:** Listener isolation tests различают две observable фазы. Для future lifecycle dispatch throwing `Connect`/`Once` listener или observer callback дает traceback, yielding callback не задерживает Roblox/Signal publisher, а оба не подавляют последующий callback. Для initial existing-player enumeration `ObservePlayers` вызывает `onAdded` синхронно и последовательно: throwing initial callback диагностируется и не мешает доставке следующего existing player; finite-yielding initial callback задерживает возврат функции и следующий initial callback, но параллельный platform/Signal publisher остается незаблокированным. Аудит не меняет общий `Signal` ради этой caller-owned enumeration semantics и не заявляет direct public-signal `Wait()` поддерживаемой Players API.
- **PRD-AC-007:** Composition audit подтверждает по одному production `PlayersModule` instance на server и client, переданному consumers через manifests, и отсутствие дополнительных прямых platform lifecycle subscriptions вне разрешенных wrappers.
- **PRD-AC-008:** Инструментированный benchmark/fake фиксирует для join/existing/leave количество platform lookups, Signal dispatches, scheduled callbacks и конечных consumer calls при 0, 1 и нескольких observers; результаты доказывают отсутствие duplicate delivery и линейный measured growth без произвольного численного threshold. Оптимизация требуется только для доказанной избыточной работы и не ухудшает race-safety либо semantics.
- **PRD-AC-009:** После любой source remediation проходят Rojo build, `System`, `ProductionReadiness`, все focused Players regressions и suites всех затронутых consumers, а clean server/client Play подтверждает join/leave/respawn, initialization/bootstrap, Save close/load и Teleport lifecycle integration в применимой части без неожиданных warnings/errors; непройденные проверки перечислены с конкретной причиной и не позволяют заявить production ready.
- **PRD-AC-010:** Итоговая документация кратко объясняет стоимость абстракции: централизованный platform adapter, existing-player semantics, test injection и consumer-owned domain workflows; очередь и gameplay `PlayerService` не преподносятся как отсутствующие дефекты без evidence-backed requirement.
- **PRD-AC-011:** Impact report перечисляет каждый production constructor site, server/client manifest entry, initialization command, direct/indirect consumer, test double и regression suite; для каждого указано, изменен ли его контракт и какой проверкой подтверждена совместимость.
- **PRD-AC-012:** Если подтвержденных дефектов нет, Engineer pass завершается без source rewrite. Если дефекты есть, diff ограничен строками, необходимыми для их устранения, regression tests и обязательной согласованной документации; каждая измененная production path трассируется к конкретному finding.
- **PRD-AC-013:** Финальный production-readiness verdict выдается только после двух независимых read-only reviews без незакрытых blocking findings и feature-focused runtime QA реальных lifecycle flows; audit-only утверждений без executable evidence недостаточно.
- **PRD-AC-014:** Server и client initialize-failure tests инъецируют сбой после каждого частично приобретенного ресурса и подтверждают полный rollback, нулевые оставшиеся callbacks/connections, terminal failed error на всех последующих public operations того же instance и успешный independent lifetime fresh instance.
- **PRD-AC-015:** Stop-lifecycle tests подтверждают terminal finalizer semantics: active `Connect`/`Once` listeners и observer callbacks уничтожены, повторный `Stop` безопасен, а `Initialize`, все getters, observer registration и wait helpers stopped instance детерминированно отклоняются одним документированным terminal error contract.
- **PRD-AC-016:** Client waiter tests подтверждают, что `WaitForCharacter` возвращает existing/new character в active lifetime и завершается terminal lifecycle error при `Stop` или initialize failure; ни один test или consumer не зависит от direct `Wait()` публичных lifecycle signals как от поддерживаемого Players contract.
- **PRD-AC-017:** История изменений и pipeline evidence подтверждают обязательный phase order: read-only audit и frozen complete inventory предшествуют любым test edits; test coverage предшествует production remediation; после remediation выполнены полный resweep исходного scope и все обязательные regressions.

## Assumptions

- Репозиторий является reusable template и не содержит project-owned ADR namespace.
- Нормативный приоритет для feature: текущие явные указания пользователя и согласованные требования из Codex task `019fa4c9-60ea-71c3-bff7-17927510b1b6`, затем текущие `.agents/rules/players.md`, `.agents/rules/signals.md`, `.agents/rules/architecture.md`, `.agents/rules/testing.md`, template/ADR-0005, template/ADR-0019 и согласованная runtime documentation. Замечания ревьюеров не переопределяют эти источники без доказанного конфликта.
- template/ADR-0005 и template/ADR-0019 остаются действующими архитектурными решениями на время аудита.
- Shared `Signal` уже является владельцем политики callback scheduling, error isolation и traceback; аудит проверяет интеграцию, а не автоматически переносит эту ответственность в `PlayersModule`.
- Несколько экземпляров класса сами по себе не являются production-ошибкой: tests требуют fresh instances, а production singleton-by-composition должен быть доказан отдельно.
- Ремедиация исходников не входит в текущий requirements checkpoint, но разрешена в последующей Engineer-фазе для evidence-backed in-scope дефектов после утверждения обязательных документов.

## Open Questions

Открытых продуктовых вопросов нет. Конкретный terminal error shape и internal state representation определяются в technical specification без расширения публичного контракта.

## Risks

- Попытка «исправить» возможность создания нескольких instances может разрушить обязательную testability и explicit dependency injection, не изменив production ownership.
- Автоматическое добавление очереди может противоречить non-blocking Signal semantics и скрыть domain-specific ordering, который должен жить в одном последовательном consumer workflow.
- Удаление membership recheck или existing-player duplication safeguards ради микрооптимизации может вернуть join/enumeration race.
- Несогласованное внедрение terminal lifecycle может оставить callbacks после `Stop`, подвесить client waiter или позволить частично failed instance повторно войти в работу.
- Расширение `PlayersModule` до `PlayerService` с gameplay/save/teleport logic превратит boundary wrapper в god module и нарушит template/ADR-0005.
- Широкий рефакторинг под видом аудита может уничтожить ранее согласованный контракт, увеличить integration risk и скрыть исходный дефект в большом diff.
- Изолированная правка без inventory consumers может пройти focused test, но нарушить Save, Teleport, initialization или shutdown integration и создать ложный production-readiness verdict.
