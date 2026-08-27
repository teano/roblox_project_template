---
document_type: product-requirements
status: approved
revision: 2
language: Russian
approved_at: 2026-08-26T11:39:05Z
---

# Product Requirements

## Product Outcome

Новый derived-проект из `roblox_project_template` проходит обязательную проверку структуры репозитория из свежего клона без локальных артефактов шаблонных pipeline-запусков из корневого каталога `tests`. Специфичные для шаблонных pipeline артефакты и проверки не переносятся в конкретные проекты и не требуются для их инициализации. Обычные project-owned working-tree и initialization-файлы остаются видимыми обязательному валидатору.

## Target Audience

Пользователи и сопровождающие, создающие и проверяющие derived-проекты из `roblox_project_template`.

## Core Gameplay Loop

Изменение не затрагивает игровой цикл или runtime-поведение игры; оно исправляет обязательную репозиторную проверку при создании derived-проекта.

## Release Target

Исправленная версия `roblox_project_template` и создаваемые из неё derived-проекты.

## Scope

### In Scope

- Устранение обязательной зависимости репозиторного валидатора от локального ignored evidence-файла TF-0005.
- Проверка актуальных наследуемых контрактов шаблона без использования ignored template pipeline artifacts из корневого каталога `tests`.
- Одинаковый результат обязательной проверки в свежем клоне и в рабочем checkout шаблона независимо от наличия локальных template pipeline artifacts в корневом каталоге `tests`.
- Сохранение проверки обычных project-owned working-tree и initialization-файлов до их первого commit.

### Out of Scope

- Копирование или коммит локальных `tests/<feature>/...` артефактов шаблонных pipeline-запусков в derived-проекты.
- Добавление в инициализацию derived-проекта команды восстановления или самостоятельного изготовления исторического template evidence.
- Общая изоляция repository-layout validator от всех ignored или untracked файлов и создание отдельной Git snapshot или staging системы.
- Изменение SFX/Audio gameplay, runtime-поведения или публичных игровых контрактов.

## Functional Requirements

- PRD-REQ-001: Обязательный repository-layout validator должен работать на полном tracked-состоянии свежего клона без корневого каталога локальных pipeline artifacts tests.
- PRD-REQ-002: Наличие или отсутствие ignored template pipeline artifacts в корневом каталоге tests не должно менять результат repository-layout validation, а обычные project-owned working-tree и initialization-файлы должны оставаться видимыми валидатору.
- PRD-REQ-003: Проверка наследуемого SFX/Audio acceptance contract должна использовать актуальные tracked specification, test runners и static assertions, а не результаты отдельного исторического pipeline-run.
- PRD-REQ-004: Создание и обязательная проверка derived-проекта не должны копировать, генерировать или восстанавливать специфичные для template pipeline evidence artifacts.
- PRD-REQ-005: Исправление зависимости от historical evidence не должно отключать обнаружение отсутствующих или устаревших tracked evidence identities текущего SFX/Audio contract.

## Quality Requirements

- PRD-NFR-001: Результат repository-layout validation не должен зависеть от наличия ignored template pipeline artifacts в корневом каталоге tests при неизменных остальных входах проверки.
- PRD-NFR-002: Обязательная проверка должна выполняться без доступа к истории локального pipeline-run и без внешнего механизма восстановления evidence.
- PRD-NFR-003: Остальные существующие repository-layout проверки должны сохранять прежнюю обязательность.

## Acceptance Criteria

- PRD-AC-001: Полный tracked snapshot исправленного шаблона из свежего клона или git archive проходит scripts/validate-repository-layout.ps1 без ошибки о missing TF-0005 recovery coverage manifest.
- PRD-AC-002: Один и тот же checkout даёт одинаковый результат repository-layout validation при наличии и при отсутствии ignored template pipeline artifacts в корневом каталоге tests при неизменных остальных входах проверки.
- PRD-AC-003: Derived-проект проходит обязательную repository-layout validation без копирования, генерации или восстановления файлов из tests/sfx-system/verification/rem-tf0005-support-evidence-01, при этом отсутствующий или некорректный обязательный project-owned initialization-файл по-прежнему приводит к ошибке.
- PRD-AC-004: Намеренное удаление или переименование требуемой tracked evidence identity из актуального SFX/Audio test runner или static assertion по-прежнему приводит к ошибке repository-layout validation.
- PRD-AC-005: Исправленный шаблон не добавляет tracked template pipeline evidence в корневой каталог tests и не добавляет такую операцию в derived-project initialization.
- PRD-AC-006: Остальные проверки scripts/validate-repository-layout.ps1 продолжают выполняться и сообщать ошибки по своим существующим контрактам.

## Assumptions

## Open Questions

## Risks
