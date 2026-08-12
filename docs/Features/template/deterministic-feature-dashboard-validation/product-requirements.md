---
document_type: product-requirements
status: approved
revision: 2
language: Russian
approved_at: 2026-08-11T19:54:07.1072922Z
---

# Product Requirements

## Product Outcome

Feature dashboard должен быть достоверной, воспроизводимой и удобной для
чтения сводкой состояния feature-манифестов. Одинаковое логическое состояние
репозитория должно давать одинаковый канонический dashboard и одинаковый
результат проверки на всех поддерживаемых Windows-конфигурациях независимо от
локали, версии PowerShell и настроек Git для переносов строк.

Проверка должна перестать выдавать ложный drift из-за представления текста,
но продолжать fail-closed обнаруживать реальные изменения содержимого,
повреждённые данные и нарушение ownership между template и derived-проектом.

## Target Audience

- Мейнтейнеры reusable Roblox template, выпускающие и проверяющие upstream-релизы.
- Разработчики derived-проектов, которые получают template feature history через upstream updates.
- Автоматизированные агенты и локальные проверки, использующие feature workflow как release gate.
- Ревьюеры, которым нужна единая человекочитаемая сводка feature status, blockers, branch и даты обновления.

## Core Gameplay Loop

1. Feature lifecycle изменяет канонический `feature.json` в принадлежащем репозиторию namespace.
2. Owning sync строит или обновляет dashboard этого namespace из всех его манифестов.
3. Пользователь или release gate запускает read-only проверку всех видимых dashboard.
4. При логическом совпадении проверка завершается успешно без изменения файлов.
5. При реальном drift проверка завершается ошибкой и сообщает владельцу допустимый способ восстановления.
6. Derived-проект обновляет собственный dashboard независимо и никогда не переписывает унаследованный template dashboard.

## Release Target

- Первый upstream-релиз reusable template после завершения TF-0008.
- Обязательная Windows-матрица: Windows 11, Windows PowerShell 5.1 и PowerShell 7.x.
- Windows 10 остаётся best-effort compatibility target: доступное evidence можно
  фиксировать дополнительно, но отсутствие отдельного Windows 10 runner не
  блокирует реализацию, проверку или релиз TF-0008.
- Обязательные локали проверки: `en-US` и `ru-RU`.
- Обязательные Git-конфигурации: checkout с LF и checkout с CRLF, включая `core.autocrlf=false` и `core.autocrlf=true`.
- Существующие non-Windows сценарии не должны намеренно ухудшаться, но расширение официальной платформенной поддержки не входит в этот релиз.

## Scope

### In Scope

- Содержимое и проверка `docs/Features/template/README.md` и `docs/Features/project/README.md`.
- Генерация dashboard из `feature.json` соответствующего namespace.
- Каноническое текстовое представление owning dashboard.
- Read-only проверка owning и foreign dashboard.
- Locale- и timezone-независимое отображение `updatedAt`.
- Ownership-aware сообщения об ошибках и восстановлении.
- Регрессии на обязательном Windows 11 host для Windows PowerShell 5.1,
  PowerShell 7.x, `en-US`, `ru-RU`, LF и CRLF.
- Сохранение существующих таблицы, namespace isolation и lifecycle contracts.

### Out of Scope

- Изменение schema version 2, feature ID, status, activity, branch reservation или writer lease.
- Изменение исключительного права пользователя на Start, Continue, Pause, Reopen и Finish.
- Визуальный редизайн dashboard, переименование колонок или добавление новой product-информации.
- Изменение Roblox runtime, Rojo mappings, `place.rbxl`, Studio DataModel или игровых систем.
- Автоматическая правка template namespace из derived-проекта.
- Отключение или ослабление feature, dashboard либо repository-layout validators.
- Дословное принятие внешнего patch как нормативного решения.
- Неявный отказ от Windows PowerShell 5.1 или принудительный переход всего репозитория на PowerShell 7.
- Создание, покупка или подключение отдельной Windows 10 машины, VM либо CI runner.

## Functional Requirements

- PRD-REQ-001: Каждый namespace должен иметь ровно один dashboard, полностью производный от видимых `feature.json` только этого namespace.
- PRD-REQ-002: Dashboard должен содержать ровно одну строку для каждого валидного манифеста и сохранять текущие значения и смысл колонок ID, feature, status, activity, branch, base commit, worklog, blockers и updated date.
- PRD-REQ-003: Одинаковый набор манифестов должен давать одинаковое логическое содержимое dashboard во всех поддерживаемых сочетаниях PowerShell, локали и Git line endings.
- PRD-REQ-004: State-changing sync должен иметь право записывать только dashboard writable namespace текущего repository role.
- PRD-REQ-005: Check mode должен проверять все видимые namespace без записи файлов, изменения feature state, Git configuration или working-tree metadata.
- PRD-REQ-006: Derived-проект должен проверять inherited template dashboard, но не должен получать возможность создавать, синхронизировать или исправлять его.
- PRD-REQ-007: Различие только между LF, CRLF или CR как разделителями строк не должно считаться dashboard drift.
- PRD-REQ-008: Любое различие в нормализованном текстовом содержимом, кроме представления переносов строк, должно считаться реальным drift и завершать проверку ошибкой.
- PRD-REQ-009: Owning sync должен записывать dashboard в каноническом UTF-8 без BOM, с LF и ровно одним завершающим LF.
- PRD-REQ-010: Повторный owning sync без изменения манифестов должен быть идемпотентным и не изменять байты dashboard.
- PRD-REQ-011: `updatedAt` должен интерпретироваться как RFC 3339 instant и отображаться как его UTC calendar date в точном формате `yyyy-MM-dd`.
- PRD-REQ-012: Отображение даты не должно зависеть от current culture, current UI culture, локального timezone или автоматического JSON date coercion конкретной версии PowerShell.
- PRD-REQ-013: Невалидный или неоднозначный обязательный timestamp должен приводить к явной validation error; система не должна угадывать, переставлять день и месяц либо молча подставлять другую дату.
- PRD-REQ-014: Ошибка owning dashboard должна предлагать owning sync; ошибка foreign template dashboard в derived-проекте должна предлагать восстановление или получение корректного upstream content и не должна советовать запрещённую запись.
- PRD-REQ-015: Отсутствующий owning dashboard или generated block должен восстанавливаться owning sync; соответствующее состояние foreign namespace должно fail-closed без мутации.
- PRD-REQ-016: Исправление не должно менять ordering, escaping, ссылки на worklog, namespace filtering и подсчёт status/blockers, кроме устранения подтверждённой недетерминированности.
- PRD-REQ-017: Repository-owned команды и регрессии должны оставаться запускаемыми через Windows PowerShell 5.1 и PowerShell 7.x без жёсткой привязки к несуществующему executable внутри `$PSHOME`.

## Quality Requirements

- PRD-NFR-001: Канонические dashboard, полученные из одной fixture, должны иметь одинаковый SHA-256 во всей обязательной Windows 11/PowerShell/locale матрице.
- PRD-NFR-002: Все проверки должны быть детерминированными, локальными и не зависеть от сети, Git remote availability, Roblox Studio или wall-clock timing.
- PRD-NFR-003: Русский текст, emoji, Markdown links, escaped table cells и ASCII identifiers должны сохраняться без повреждения кодировки на каждом поддерживаемом host.
- PRD-NFR-004: Check mode должен оставлять точный pre/post hash каждого проверенного dashboard неизменным как при успехе, так и при ошибке.
- PRD-NFR-005: Регрессионные тесты должны создавать изолированные временные fixtures, не использовать рабочие feature lease и гарантированно очищать собственные временные файлы.
- PRD-NFR-006: Диагностика должна называть namespace, тип расхождения и допустимое ownership-aware действие восстановления.
- PRD-NFR-007: Нормализация line endings не должна скрывать изменение символов, строк таблицы, Markdown markers, дат, counters или порядка записей.
- PRD-NFR-008: Исправление не должно добавлять внешнюю dependency и не должно изменять Roblox runtime artifact, bootstrap или Studio behavior.

## Acceptance Criteria

- PRD-AC-001: Одна и та же template fixture после owning sync на обязательном Windows 11 host под Windows PowerShell 5.1 и PowerShell 7.x в `en-US` и `ru-RU` даёт четыре побайтово одинаковых UTF-8/LF dashboard.
- PRD-AC-002: Валидный dashboard с LF проходит Check mode без изменения файла.
- PRD-AC-003: Логически идентичный dashboard с CRLF или CR проходит Check mode без изменения файла.
- PRD-AC-004: Owning sync преобразует логически корректный CRLF dashboard в канонический LF, а второй sync не создаёт diff.
- PRD-AC-005: Derived fixture с inherited CRLF template dashboard проходит all-namespace Check без изменения template file.
- PRD-AC-006: Project-only sync обновляет project dashboard и сохраняет точный pre/post SHA-256 inherited template dashboard.
- PRD-AC-007: Ручное изменение counter, строки feature, даты, generated marker или другого нормализованного содержимого приводит к ненулевому exit code.
- PRD-AC-008: Реальный foreign template drift в derived fixture приводит к ненулевому exit code, не изменяет файл и выдаёт инструкцию восстановления без предложения запустить запрещённый template sync.
- PRD-AC-009: Timestamp `2026-08-05T13:28:08Z` отображается как `2026-08-05` при `en-US` и `ru-RU` на обоих поддерживаемых PowerShell hosts.
- PRD-AC-010: Timestamp `2026-08-05T00:30:00+14:00` отображается как UTC date `2026-08-04`.
- PRD-AC-011: Timestamp `2026-08-05T23:30:00-12:00` отображается как UTC date `2026-08-06`.
- PRD-AC-012: Невалидный `updatedAt` отклоняется до записи dashboard и не изменяет существующий файл.
- PRD-AC-013: Отсутствующий owning dashboard создаётся с ожидаемым заголовком, generated markers, таблицей, UTF-8 без BOM, LF и завершающим LF.
- PRD-AC-014: Отсутствующий foreign template dashboard в derived fixture отклоняется без создания файла или каталога.
- PRD-AC-015: Исходная Windows 10 / PowerShell 7 / `ru-RU` fixture из отчёта воспроизводится как детерминированный regression input на обязательном Windows 11 host и завершает feature workflow и repository-layout validation без ложного dashboard drift; отдельное исполнение на Windows 10 является необязательным best-effort evidence.
- PRD-AC-016: Полный существующий feature-workflow contract suite проходит под Windows PowerShell 5.1 и PowerShell 7.x без ослабления прежних assertions.
- PRD-AC-017: Feature workflow validator, all-namespace dashboard check, repository-layout validator, `git diff --check` и временный Rojo build завершаются успешно; Studio Play не требуется, если Roblox runtime и DataModel не изменены, а отсутствие отдельного Windows 10 runner не блокирует gate.

## Assumptions

- Текущий repository contract фактически поддерживает Windows PowerShell 5.1 и PowerShell 7.x; TF-0008 сохраняет эту совместимость.
- `updatedAt` представляет instant, поэтому единым человекочитаемым календарным представлением является UTC date.
- Line ending является свойством текстового представления, а не логического содержимого dashboard.
- Generated block не редактируется вручную; ручная правка должна обнаруживаться или заменяться только owning sync.
- Manifest schema, namespace ownership и feature lifecycle являются стабильными внешними контрактами этой работы.
- Обязательная release-среда доступна на Windows 11 с Windows PowerShell 5.1 и PowerShell 7.x; отдельный Windows 10 runner недоступен и не требуется для завершения TF-0008.

## Open Questions

Нет открытых продуктовых вопросов. Revision 2 сохраняет UTC date, dual-host
PowerShell support и нормализацию line endings, делает Windows 11 обязательным
Windows host, а Windows 10 — необязательным best-effort compatibility target.

## Risks

- Чрезмерно широкая нормализация может скрыть реальный drift; сравнение должно игнорировать только представление line separators.
- Git attributes не изменяют автоматически все уже существующие working trees; Check mode обязан корректно работать с унаследованным CRLF без предварительной записи.
- Автоматическое JSON date coercion различается между версиями PowerShell и может повторно внести locale-dependent round trip.
- Наличие только одного PowerShell host на машине разработчика может оставить часть матрицы непроверенной без отдельного release environment.
- Явное UTC-представление может изменить дату для ранее вручную записанных timestamps с ненулевым offset; это ожидаемая и проверяемая унификация, которую следует отразить в release notes.
- Без отдельного Windows 10 runner возможна Windows-10-специфичная регрессия,
  которую обязательная Windows 11 matrix не обнаружит; этот остаточный риск
  принят как неблокирующий, а доступное позднее Windows 10 evidence остаётся
  желательным.
