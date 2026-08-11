# Changelog

Все заметные изменения Roblox Project Template документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
а номера версий следуют [Semantic Versioning](https://semver.org/lang/ru/).
До версии `1.0.0` шаблон находится в активной разработке: его публичные
контракты и структура могут меняться между minor-версиями.

Git-теги описывают версии самого шаблона. Они не связаны с
`VersionConfig.CurrentVersion`, который является checkpoint версии
пользовательских данных и миграций. Исторические теги `v0.1.0`–`v0.14.1`
добавлены ретроспективно без изменения существующих коммитов; сам этот файл
впервые входит в `v0.15.0`.

## [Unreleased]

## [0.18.0] - 2026-08-11

### Added

- Добавлена production-ready Audio/SFX вертикаль с локальным, серверным и
  hybrid one-shot playback, нативной серверной репликацией и раздельными
  однородными пулами на сервере и каждом клиенте.
- Добавлены валидируемые локальные Luau-конфиги `AudioRuntimeConfig`,
  `RoutingConfig` и `SpatialProfiles`, а также генерируемый из
  `configs/audio/Sounds.csv` каталог с вариантами, весами, preload-флагами и
  стабильными `CueId`/`VariantId`.
- Добавлены `AudioGraph`, иерархия фейдеров Master/UI/SFX/World/Music,
  клиентский LIFO-стек Music с transitions и сохраняемые пользовательские
  уровни и enabled-флаги AudioSettings.
- Добавлен фиксированный пространственный контракт: один невидимый anchored
  `SpatialAnchor` с прямыми `AudioPlayer`, `AudioEmitter` и `Wire`, статическая
  Point-позиция и generation-safe Attached tracking полного transform.
- Добавлены совместный Studio QA-контур, руководство по слуховой проверке,
  точная трассировка 79 acceptance criteria и расширенные Audio suites.

### Changed

- `AssetRegistry` и `ContentPreloader` интегрированы с физическими Sound-
  дескрипторами и детерминированной audio-only first-wins политикой; startup
  fail-closed отключает Audio-сторону до создания graph и pools при невалидной
  конфигурации или превышении лимитов.
- Каноническая сцена теперь владеет `SoundService.AcousticSimulationEnabled`
  и listener anchor; runtime не меняет глобальное acoustic-состояние.
- Клиентский и серверный manifests явно собирают Audio dependencies и frame
  drivers без новых bootstrap-скриптов или обходных transport remotes.

### Fixed

- Запрещённые catalog-owned overrides и значения вне настроенного диапазона
  отклоняются как `TypeMismatch` до acquire/mutation и с одним клиентским
  diagnostic; прочие malformed option keys сохраняют `InvalidRequest`.
- Spatial playback больше не зависит от недоступных
  `PositionType`/`PositionInstance`: default Parent topology единообразно
  работает для Point и Attached источников и безопасно очищает stale callbacks.

### Verification

- Пройдены AudioCatalog `39/39`, AudioPlayback `61/61`, AudioIntegration
  `39/39`, AudioManualQa `22/22` и aggregate `380/380` в 14 suites, Rojo build,
  clean Studio Play и двухклиентские слуховые проверки replication,
  attenuation, независимых фейдеров и Music LIFO.
- Breaking migration отсутствует. Для использования системы нужно заполнить
  `configs/audio/Sounds.csv`, сгенерировать каталог штатным конвертером и
  разместить соответствующие Sound-дескрипторы под approved assets root.

## [0.17.0] - 2026-08-06

### Added

- Добавлены переносимые между агентами и чатами checkpoints: `worklog.md`
  хранит результат, важные решения и обсуждения, verification evidence,
  блокеры и следующий шаг без ссылок на transcript или task/session IDs.
- Lifecycle сам создаёт канонические ветки: template-фичи используют
  `TF-####` и `template-feature/tf-####-<slug>`, а фичи derived-проектов —
  `F-####` и `feature/t-####-<slug>`.

### Changed

- Только явная текущая команда пользователя теперь разрешает `Start`,
  `Continue`, `Pause`, `Reopen` или `Finish`; завершение реализации, проверки,
  аудит, результат сабагента и конец хода не меняют состояние фичи.
- Feature manifests и локальные writer leases переведены на agent-neutral
  schema v2. Derived-проектам с legacy `PF-####` или schema-v1 manifests нужна
  явная миграция собственного feature namespace при принятии нового контракта.
- `$feature-finish` стал чистым documentation/state-finalization шагом: он
  записывает уже полученные evidence и обновляет PRD/spec, system docs, rules
  и ADR, но не запускает tests, validators, Rojo или Studio.

### Fixed

- Derived-project lifecycle теперь fail-closed проверяет URL template
  `upstream` и завершённую project initialization, а не доверяет одному имени
  remote и не создаёт владельческие namespace неявно.
- `Pause` и `Finish` отклоняют wrong-branch, отсутствующий или legacy lease до
  первой мутации; `Reopen` сохраняет историческую recorded branch и обновляет
  переносимые handoff/worklog context.

### Removed

- Удалена зависимость lifecycle от `CODEX_THREAD_ID`, Codex task/session
  ownership, session history в manifests и ссылок на сессии в dashboards.

## [0.16.0] - 2026-08-06

### Added

- Добавлен явно вызываемый repository-local skill `$csv-to-luau` для
  детерминированного создания и полной синхронизации чистых Luau data-модулей
  из UTF-8 CSV внутри разрешённых Rojo roots.
- Добавлены строгий CSV-парсер, определение разделителя и типов, режимы array и
  dictionary, typed key column, bounded preview с diff, schema, samples и
  SHA-256 hashes, а также безопасный разбор существующего data-модуля.
- Ячейки с comma-separated значениями автоматически преобразуются в
  `array<string>` и рендерятся как Luau-массивы. Возможные массивы с
  разделителями semicolon, pipe, tab или newline выводятся как ограниченные
  кандидаты и требуют явного решения для каждой колонки; колонку можно оставить
  строкой.

### Security

- Запись ограничена текущим Git/Rojo repository, отклоняет executable targets,
  path traversal, symlink/reparse redirects и подмену source/target/parent,
  проверяет три preview hash и выполняет same-directory atomic replace.
- Добавлены лимиты размера, структуры, памяти, diagnostics и JSON-ответа;
  конвертер использует только Python standard library и не требует сети или
  внешних runtime-зависимостей.

## [0.15.0] - 2026-08-05

### Added

- Добавлена серверная система числовой статистики с глобальными,
  сессионными, плейсовыми и проектными снимками.
- Добавлены атомарные операции `Set`, `Inc`, `Dec`, `Min` и `Max`,
  фильтрация показателей, ограниченная история и расширяемые метаданные.
- Добавлена дедупликация фактов по последовательности источника и `EventId`.
- Добавлено продолжение сессионного снимка через доверенную Teleport-сессию
  с отдельным снимком для каждого посещения плейса.
- Добавлены безопасные read-only проекции текущей статистики для клиента и
  фиксированный контракт проектных клиентских фактов.
- Добавлена интеграция с Wallet для учёта полученной валюты без стартового
  баланса и трат.
- Добавлены `statistics_config`, документация, ADR и полный набор регрессий.

### Changed

- Save-контур получил приватные клиентские проекции провайдеров, полный
  финальный capture и объединение частых запросов сохранения.
- Общий набор расширен до 206 проходящих тестов в 10 suites.

## [0.14.1] - 2026-08-04

### Fixed

- Удалена зависимость feature workflow от Codex hook и перенесено безопасное
  определение task identity непосредственно в workflow-команды.

## [0.14.0] - 2026-08-04

### Changed

- Реестры фич разделены на независимые пространства `template` и `project`.
- Добавлены раздельные dashboards, правила владения и merge-политика для
  обновлений производных проектов.

## [0.13.0] - 2026-08-04

### Added

- Добавлен формальный жизненный цикл разработки фич: start, continue, pause и
  finish.
- Добавлены feature manifests, handoff, worklog, PRD/specification artifacts,
  writer lease и автоматическая проверка dashboards.

## [0.12.0] - 2026-08-04

### Changed

- PlayersModule доведён до production-ready состояния.
- Усилены контракты подключения, удаления, персонажей и взаимодействия с
  Teleport, Communication и сохранением.
- Добавлены pipeline evidence и проверки критических lifecycle-сценариев.

## [0.11.0] - 2026-08-04

### Added

- Добавлен серверно-авторитетный TeleportModule с безопасными destination
  policy, per-player попытками и доверенной session continuity.
- Добавлен клиентский Teleport facade и синхронизация состояния через общий
  Communication snapshot.
- Добавлен повтор захвата session lock на целевом сервере без создания пустого
  профиля.
- Добавлен отключённый по умолчанию двухплейсовый validation pad и процедура
  опубликованного runtime-тестирования.

## [0.10.0] - 2026-07-31

### Added

- Добавлены итеративные миграции заблокированных пользовательских документов
  с детерминированным порядком и checkpoint версии.
- Добавлена стабильная cloud identity шаблона и правила безопасной публикации
  и подключения плейсов.
- Добавлены aggregate test runner, production-readiness suite и матрица
  release-покрытия.

### Changed

- Усилена проверка репозиторной структуры, Rojo-проекта, session locking и
  атомарного применения save providers.

## [0.9.1] - 2026-07-30

### Fixed

- Усилен lifecycle сохранения и восстановления после ошибок.
- Исправлены граничные случаи session locks, сериализации, Wallet и
  согласованности runtime после неуспешной загрузки или сохранения.

## [0.9.0] - 2026-07-30

### Changed

- Communication transport получил строгую сериализацию, ограниченные очереди,
  sequencing, epochs и восстановление через resync.
- Добавлены приоритеты сообщений и token-bucket pacing для ограничения
  входящего и исходящего трафика.

## [0.8.1] - 2026-07-30

### Fixed

- Signal получил изолированную side-local диспетчеризацию, безопасный lifecycle
  подключений и устойчивость к yielding/error callbacks.
- Logger получил структурированные уровни, безопасное форматирование и
  production-поведение.

## [0.8.0] - 2026-07-30

### Added

- Добавлен серверный каталог Roblox Experience Config с валидируемыми codecs,
  атомарными generations и клиентскими bundles.
- Wallet и global save переведены на обязательные конфигурации из Experience
  Config.
- Добавлена интеграционная документация для опубликованных конфигураций и
  стабильной идентификации Studio DataModel.

## [0.7.0] - 2026-07-30

### Added

- Добавлен Rojo preflight, который проверяет владельца стандартного endpoint и
  безопасно переключает активный проект.
- Добавлены правила явного выбора правильного Studio instance перед Play и
  cloud-зависимыми операциями.

## [0.6.0] - 2026-07-29

### Added

- Добавлен единый ContentPreloader поверх AssetRegistry и Roblox
  ContentProvider.
- Добавлены именованные single-flight запросы, прогресс, failure policy и
  startup-preload до завершения клиентской инициализации.

## [0.5.0] - 2026-07-29

### Added

- Добавлены раздельные серверный и клиентский каталоги статических assets с
  путями, стабильными `AssetKey`, tags и metadata queries.
- Добавлены явные Rojo roots для Shared, Client и Server assets.

### Changed

- Сам template переведён на стандартный Rojo port; производные проекты на этом
  этапе сохраняли собственные port overrides.

## [0.4.0] - 2026-07-29

### Added

- Добавлена ADR-управляемая политика обновления производных проектов из
  template upstream.
- Добавлен пользовательский выбор ветки обновления, защита от дублирующих ADR
  расхождений и правила сохранения проектного `place.rbxl`.
- Добавлена первоначальная политика идентификации Rojo-проектов и портов,
  позднее заменённая единым стандартным endpoint.

## [0.3.0] - 2026-07-29

### Added

- Добавлен workflow инициализации производного проекта.
- Разделены template-owned и project-owned ADR namespaces.
- Канонический Studio-файл переименован в `place.rbxl`, добавлен validator
  структуры репозитория.
- Добавлена документация bootstrap из отдельного Git-репозитория.

## [0.2.0] - 2026-07-29

### Added

- Добавлены раздельные серверный и клиентский PoolModule.
- Добавлены homogeneous pools, generation leases, lifecycle adapters,
  ограничение active/retained объектов и безопасная очистка.
- Добавлены CodeGraph setup и расширенная русская документация шаблона.

## [0.1.0] - 2026-07-28

### Added

- Создан репозиторий Roblox Project Template с лицензией и базовой
  документацией.
- Добавлена модульная серверная и клиентская инициализация через явные
  manifests и единственные bootstraps.
- Добавлены базовые Players, Communication, Save, Storage, Wallet, Version и
  Migration boundaries.
- Добавлены Rojo project mapping, канонические agent rules, ADR и первые
  системные и production integration tests.

[Unreleased]: https://github.com/teano/roblox_project_template/compare/v0.18.0...HEAD
[0.18.0]: https://github.com/teano/roblox_project_template/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/teano/roblox_project_template/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/teano/roblox_project_template/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/teano/roblox_project_template/compare/v0.14.1...v0.15.0
[0.14.1]: https://github.com/teano/roblox_project_template/compare/v0.14.0...v0.14.1
[0.14.0]: https://github.com/teano/roblox_project_template/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/teano/roblox_project_template/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/teano/roblox_project_template/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/teano/roblox_project_template/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/teano/roblox_project_template/compare/v0.9.1...v0.10.0
[0.9.1]: https://github.com/teano/roblox_project_template/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/teano/roblox_project_template/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/teano/roblox_project_template/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/teano/roblox_project_template/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/teano/roblox_project_template/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/teano/roblox_project_template/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/teano/roblox_project_template/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/teano/roblox_project_template/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/teano/roblox_project_template/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/teano/roblox_project_template/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/teano/roblox_project_template/tree/v0.1.0
