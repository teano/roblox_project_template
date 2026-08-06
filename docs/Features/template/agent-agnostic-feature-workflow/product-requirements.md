# Agent-Agnostic Feature Workflow — Product Requirements

- Status: Approved
- Date: 2026-08-06
- Feature: TF-0007
- Approval source: explicit user request

## Outcome

Сделать repository feature workflow переносимым между Codex и другими
агентами: любой новый чат должен восстанавливать рабочий контекст из
репозиторных артефактов без session/task IDs и доступа к предыдущей переписке.

## Requirements

- Manifest, handoff, worklog, recovery history и локальный writer lease не
  хранят Codex session/thread IDs, host IDs или идентификаторы другого агента.
- `Start`, `Continue`, `Pause` и `Finish` не требуют `CODEX_THREAD_ID` или иной
  product-specific environment variable.
- `Pause` и `Finish` записывают в `worklog.md` самостоятельный summary с
  результатом, важными решениями и обсуждениями, состоянием проверок,
  блокерами и следующим шагом.
- `Continue` восстанавливает контекст из manifest, handoff, approved PRD/spec,
  worklog, Git, правил, system docs и ADR без обращения к chat history.
- Generated dashboard всё так же ссылается на `worklog.md`, но не показывает
  количество или ссылки сессий.
- `$feature-finish` не запускает тесты, validators, Rojo build или Studio. Все
  проверки выполнены до него; finish подтверждает завершённость, обновляет
  worklog и полный documentation/ADR cascade и переводит feature в `ready`.
- `Finish` отклоняет feature с blockers или без factual summary существующего
  verification evidence.
- Новая template feature получает `TF-####` и автоматически создаётся на
  `template-feature/tf-####-<feature-slug>`.
- Новая derived-project feature получает `F-####` и автоматически создаётся на
  `feature/t-####-<feature-slug>`.
- Existing ready branch names остаются историческими; новый формат обязателен
  для веток, создаваемых обновлённым `Start`. Reopen переключается на
  существующую recorded branch и не переименовывает её; отсутствующая ветка
  или branch/base metadata требует явной миграции. Reopen обновляет handoff и
  добавляет в worklog причину, новое active-состояние и следующий шаг.
- Template/project namespace isolation и repository-wide branch reservation
  сохраняются.
- Derived-project lifecycle разрешён только после обязательной project
  initialization. Remote `upstream` обязан указывать на
  `roblox_project_template`; одно имя remote не определяет роль репозитория.
- `Pause` и `Finish` до первой мутации требуют текущую recorded branch и
  точную schema-v2 feature lease без agent/session полей.
- Только явная текущая команда пользователя на конкретный lifecycle transition
  разрешает `Start`, `Continue`, `Pause`, `Reopen` или `Finish`. Агент,
  сабагент, automation, завершение реализации/аудита, успешные проверки и конец
  хода не меняют feature state.
- Неоднозначная команда сохраняет текущее состояние. Запрос на реализацию,
  исправление, аудит, проверку или остановку текущего ответа не считается
  неявным `Pause` либо `Finish`.

## Acceptance

- Из текущих template feature manifests, handoffs и worklogs удалены
  session/task identifiers без потери содержательных summary.
- Feature workflow tests проходят без установки `CODEX_THREAD_ID`.
- Tests подтверждают `TF-0001` +
  `template-feature/tf-0001-<slug>` и `F-0001` +
  `feature/t-0001-<slug>`.
- Derived-project scenarios подтверждают fail-closed role/initialization,
  create/pause/continue/finish/reopen, historical branch preservation,
  writer-lease gates и byte-identical inherited template dashboard.
- Worklog/handoff fixtures содержат обязательный блок важных решений и не
  содержат `Session`, `threadId`, `activeSessionId` или Codex task links.
- Finish contract tests подтверждают blocker gate и отсутствие вызовов внешних
  проверок.
- Validator и contract tests подтверждают обязательный user-authorization gate
  во всех lifecycle skills и `allow_implicit_invocation: false`.
- Skills, feature validators, dashboard sync, repository layout, Git
  whitespace и temporary Rojo build проходят до финального lifecycle action.
