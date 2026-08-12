---
document_type: development-plan
status: approved
revision: 2
feature: deterministic-feature-dashboard-validation
mode: single_owner
writer_strategy: sequential
planning_analyst_id: tf-0008-planning-analyst-02
source_prd_path: docs/Features/template/deterministic-feature-dashboard-validation/product-requirements.md
source_prd_revision: 2
source_prd_sha256: ec6edd8462d5fed2c4f97909eb3bdcd20ce2ef99fe382e5f12d5d48b12b3258a
source_spec_path: docs/Features/template/deterministic-feature-dashboard-validation/technical-specification.md
source_spec_revision: 2
source_spec_sha256: ceececd9a8ba9c59949e3819641735852e6d383bd09ec12e4684f4e6cef0e1e2
decision_ledger_path: docs/Features/template/deterministic-feature-dashboard-validation/decision-ledger.jsonl
slice_count: 1
approved_by: user
approved_at: 2026-08-11T20:36:34+00:00
---
# План разработки: Deterministic Feature Dashboard Validation

## Decision

Writer sequencing: one-at-a-time
Ownership meaning: phase-scoped write lease

- Режим: `single_owner`; одна вертикаль `SLICE-001` принадлежит одному
  write-capable Integration Engineer на каждой фазе.
- Manifest decoding, UTC date semantics, full-file rendering, strict byte
  writing, ownership-aware Check/Sync и Windows regression matrix сходятся в
  одном модуле и одной связанной contract suite. Промежуточное разделение не
  даёт самостоятельно проверяемого результата.
- Отклонены разделения loader/date против renderer/writer, implementation
  против tests, template против derived ownership, PowerShell 5.1 против 7.x,
  mandatory Windows 11 verification против optional Windows 10 evidence и
  code против documentation/generated output. Они
  конкурируют за одни touchpoints или откладывают наблюдаемый результат до
  последней интеграции.
- `single_owner` означает только последовательную phase-scoped write lease, а
  не пожизненное закрепление одной Engineer identity.

## Planning Analysis

- Техническая сложность средне-высокая, архитектурная ширина узкая: ожидаются
  10–14 затронутых или новых внутренних PowerShell helpers, 18 обязательных
  automated identities и примерно 730–1280 изменённых строк с тестами и
  документацией.
- Основные production seams находятся в `scripts/FeatureWorkflow.psm1`:
  строгая загрузка manifest bytes, JSON-aware surrogate gate, invariant RFC
  3339/UTC date conversion, canonical full-file renderer, line-separator-only
  comparison, strict dashboard encoding и atomic byte sink.
- Основной evidence seam — `scripts/tests/feature-workflow.tests.ps1`; он
  обязан проверять тот же integrated path на обоих PowerShell hosts, обеих
  культурах, Git EOL режимах и ownership ролях без альтернативного тестового
  алгоритма.
- `.gitattributes`, нормативное правило, coverage documentation и generated
  template dashboard завершают один контракт, но не расширяют lifecycle,
  schema, lease, branch или namespace ownership.
- Внешний patch SHA-256
  `799af03b5e4d6f49aefe96d5c5beba9d9412c58d9382169cce5458607e4be0d6`
  остаётся недоверенным ненормативным evidence: его нельзя применять или
  исполнять как реализацию.
- Перед инженерной фазой фиксируется весь существующий dirty inventory.
  Несвязанные изменения пользователя не сбрасываются, не stash-ятся и не
  приписываются TF-0008.
- Нового ADR не требуется, пока реализация сохраняет утверждённые public,
  lifecycle и ownership boundaries. Любая необходимость их изменить
  останавливает slice и маршрутизируется как новое решение.

## Scope Boundaries

- В scope входят deterministic manifest decoding, invariant timestamp/date
  conversion, byte-canonical dashboard rendering/writing, representation-only
  EOL comparison, ownership-aware diagnostics, Windows source encoding,
  exact-path Git EOL policy, regression coverage и нормативная документация.
- Template owner может восстановить весь свой canonical dashboard; foreign
  template dashboard в derived repository остаётся immutable. Project sync не
  переписывает template namespace и не создаёт project namespace в template
  repository.
- Public entrypoint parameters, exported module signatures, feature manifest
  schema, lifecycle state machine, writer lease, branch reservation и
  namespace ownership не меняются.
- Roblox runtime, `src/**`, `place.rbxl`, Studio, Rojo mappings, networking,
  save, Players и gameplay systems исключены.
- Не разрешены новые зависимости, сеть, CI-provider configuration,
  drive-by cleanup или ручное редактирование generated dashboard.
- Approved PRD/specification, этот canonical plan, controller state,
  decision ledger и TF-0008 lifecycle artifacts не являются Engineer-owned
  product scope.

## Decision Ledger

- ledger_path: docs/Features/template/deterministic-feature-dashboard-validation/decision-ledger.jsonl
- active_decision_ids: none
- new_decision_route: explicit user authority -> Decision Recorder -> controller append validation
- План зависит только от active accepted `DEC-*`; Engineer assumptions не
  становятся решениями и не записываются в ledger вручную.

## Coverage Strategy

- manifest_path: tests/deterministic-feature-dashboard-validation/verification/coverage-schema-2.json
- automated_identity_namespace: AUTO-TF0008-*
- manual_identity_namespace: MANUAL-TF0008-*
- mandatory_rule: каждое PRD-AC-001..017 отображается на явно зарегистрированные AUTO-TF0008-SPEC-TEST-001..018; manual identities отсутствуют
- automation_feasibility: все acceptance criteria детерминированы и автоматизируются; Windows 11 является обязательным release-runner cell, а Windows 10 evidence остаётся необязательным best-effort дополнением и не влияет на pass/fail
- capability_prerequisites: git-local-autocrlf-matrix,powershell-7,rojo-build,windows-11-release-runner,windows-powershell-5-1
- gates: plan-before-engineering, finalize-after-code-freeze, qa-updated
- Studio capability не требуется по `SPEC-TEST-017`; отсутствие Studio не
  заменяет обязательные host/OS/Git cells.

## Documentation Strategy

- normative_pre_review: .agents/rules/feature-workflow.md, docs/TestCoverage.md
- derived_post_qa: not_required | policy=SPEC-TEST-017
- source_rule: только active DEC IDs, approved PRD/spec IDs и точное verified evidence
- `docs/Features/template/README.md` является generated product projection и
  обновляется только owning sync, а не Documentation Finisher вручную.

## Context Budget

- max_authority_files: 14
- max_evidence_files: 16
- max_total_files: 30
- max_payload_bytes: 420000
- max_estimated_tokens: 105000
- metric_scope: capsule_plus_referenced_files
- estimation_recipe: ceil((canonical capsule UTF-8 bytes + exact referenced authority/evidence bytes) / 4)

## Integration Milestones

- MILESTONE-001: authority, exact dirty inventory, baseline and scope are
  frozen; immediately before the first source edit the mandatory Rojo
  preflight succeeds.
- MILESTONE-002: strict UTF-8 manifest loader, JSON-aware surrogate validation
  and invariant RFC 3339/UTC date contract pass focused dual-host/culture
  tests.
- MILESTONE-003: full-file LF renderer, line-separator-only Check
  normalization, strict one-shot dashboard encoding, atomic byte writer,
  idempotence and ownership-aware diagnostics work through one integrated
  path.
- MILESTONE-004: template/derived, LF/CRLF/CR/mixed, `core.autocrlf`, outer
  scaffold, invalid-input and same-host process regressions pass; source BOM,
  exact dashboard attributes, normative docs and generated dashboard agree.
- MILESTONE-005: all 18 mandatory identities, both PowerShell hosts,
  `en-US`/`ru-RU`, Git/EOL cells, mandatory Windows 11 evidence, repository
  gates, scope ceilings and temporary Rojo build are sealed in finalized
  coverage; Windows 10 evidence is recorded separately only when available and
  remains nonblocking.

## Slice SLICE-001

### Vertical Outcome

End-to-end: yes
Observable result: owning sync produces one byte-canonical UTF-8-no-BOM/LF dashboard; Check accepts only line-separator representation differences, detects every other full-file drift without mutation, preserves foreign ownership, and behaves identically across the mandatory Windows 11, PowerShell, culture and Git matrix; optional Windows 10 evidence cannot change pass/fail.

### Requirements

- PRD-REQ-001, PRD-REQ-002, PRD-REQ-003, PRD-REQ-004, PRD-REQ-005,
  PRD-REQ-006, PRD-REQ-007, PRD-REQ-008, PRD-REQ-009, PRD-REQ-010,
  PRD-REQ-011, PRD-REQ-012, PRD-REQ-013, PRD-REQ-014, PRD-REQ-015,
  PRD-REQ-016, PRD-REQ-017
- PRD-NFR-001, PRD-NFR-002, PRD-NFR-003, PRD-NFR-004, PRD-NFR-005,
  PRD-NFR-006, PRD-NFR-007, PRD-NFR-008
- PRD-AC-001, PRD-AC-002, PRD-AC-003, PRD-AC-004, PRD-AC-005,
  PRD-AC-006, PRD-AC-007, PRD-AC-008, PRD-AC-009, PRD-AC-010,
  PRD-AC-011, PRD-AC-012, PRD-AC-013, PRD-AC-014, PRD-AC-015,
  PRD-AC-016, PRD-AC-017

### Dependencies

- none

### Base Contract

- Scope baseline revision:
  `765fd71b755f2f0878a0c9c8761b887600590cdf`.
- Approved PRD revision 2 SHA-256:
  `ec6edd8462d5fed2c4f97909eb3bdcd20ce2ef99fe382e5f12d5d48b12b3258a`.
- SPEC_READY specification revision 2 SHA-256:
  `ceececd9a8ba9c59949e3819641735852e6d383bd09ec12e4684f4e6cef0e1e2`.
- Active decision set: `none`.
- Перед source work Engineer фиксирует exact dirty inventory, сохраняет
  unrelated user changes и выполняет mandatory Rojo preflight.

### Handoff Contract

- Controller-generated schema-2 handoff содержит exact base/result revisions,
  changed paths/symbols и обязательные `decision_ids`, `coverage_state`,
  `documentation_state`, `open_assumptions`.
- Sealed evidence включает canonical dashboard SHA, mandatory Windows 11
  dual-host/locale/Git cells, foreign pre/post hashes, scope budget и все
  repository gates; optional Windows 10 evidence, если доступно, помечается
  отдельно и не влияет на sealing.
- Workers не создают revision/change/diff/handoff mechanics вручную.

### Owned Paths

- `scripts/FeatureWorkflow.psm1`
- `scripts/tests/feature-workflow.tests.ps1`
- `.gitattributes`
- `.agents/rules/feature-workflow.md`
- `docs/TestCoverage.md`
- `docs/Features/template/README.md` — только generated owning sync

### Expected Paths

- `scripts/sync-feature-index.ps1`
- `scripts/validate-feature-workflow.ps1`
- `scripts/validate-repository-layout.ps1`
- `scripts/feature-workflow.ps1`
- `scripts/ensure-rojo-server.ps1`
- `docs/Features/README.md`
- `docs/Features/_schema/feature-manifest.schema.json`
- `docs/Features/template/*/feature.json`
- `.agents/rules/index.md`, architecture/testing/ADR routing rules и Accepted
  template ADR-0037
- `default.project.json` — только build/preflight context

### Forbidden Scope

- `.agentic-pipeline/**`, approved PRD/spec/plan, decision ledger и TF-0008
  `feature.json`, `handoff.md`, `worklog.md`
- `docs/FeatureDevelopmentForBeginners.md` и `docs/Features/project/**`
- public entrypoint parameters/exports, manifest schema, lifecycle, lease,
  branch или namespace-ownership semantics
- `src/**`, `place.rbxl`, Studio/DataModel, Rojo mappings и Roblox runtime
- dependencies, network, CI-provider setup, unrelated cleanup и применение
  внешнего subscriber patch

### Scope Contract

- acceptance_ids: PRD-AC-001,PRD-AC-002,PRD-AC-003,PRD-AC-004,PRD-AC-005,PRD-AC-006,PRD-AC-007,PRD-AC-008,PRD-AC-009,PRD-AC-010,PRD-AC-011,PRD-AC-012,PRD-AC-013,PRD-AC-014,PRD-AC-015,PRD-AC-016,PRD-AC-017
- editable_paths: scripts/FeatureWorkflow.psm1,scripts/tests/feature-workflow.tests.ps1,.gitattributes,.agents/rules/feature-workflow.md,docs/TestCoverage.md,docs/Features/template/README.md
- shared_touchpoints: TP-001,TP-002,TP-003,TP-004,TP-005,TP-006
- shared_touchpoint: TP-001 | path=scripts/FeatureWorkflow.psm1 | symbols=Get-FeatureManifests,Test-FeatureManifestSet,Get-FeatureIndexBlock,Sync-FeatureIndex,Write-Utf8NoBom,new internal loader/date/renderer/normalizer/dashboard-byte helpers | allowed_change=strict input, invariant UTC date, canonical full-file render, line-separator-only Check, atomic dashboard bytes and ownership diagnostics | forbidden_change=exported signatures, schema, lifecycle, lease, branch, namespace ownership
- shared_touchpoint: TP-002 | path=scripts/tests/feature-workflow.tests.ps1 | symbols=current-host resolver,isolated fixture helpers,SPEC-TEST-001..018 | allowed_change=exact deterministic regressions while retaining all lifecycle assertions | forbidden_change=weakened assertions, working feature lease, network, Studio, alternate host fallback
- shared_touchpoint: TP-003 | path=.gitattributes | symbols=docs/Features/template/README.md,docs/Features/project/README.md | allowed_change=exact text eol=lf rules for the two dashboard paths | forbidden_change=global text policy or unrelated attributes
- shared_touchpoint: TP-004 | path=.agents/rules/feature-workflow.md | symbols=canonical dashboard and verification contract | allowed_change=document approved deterministic encoding,date,check behavior | forbidden_change=lifecycle authority, namespace ownership, completion gates
- shared_touchpoint: TP-005 | path=docs/TestCoverage.md | symbols=feature-workflow coverage section | allowed_change=document exact dual-host/dashboard regression coverage | forbidden_change=unrelated runtime release gates
- shared_touchpoint: TP-006 | path=docs/Features/template/README.md | symbols=entire generated dashboard | allowed_change=owning generator output only | forbidden_change=hand edit or foreign/project namespace creation
- excluded_components: agentic-pipeline-state,TF-0008-authority-and-lifecycle,project-feature-namespace,Roblox-runtime-and-scene,public-feature-entrypoints,unrelated-documentation
- excluded_paths: .agentic-pipeline/**,docs/Features/template/deterministic-feature-dashboard-validation/product-requirements.md,docs/Features/template/deterministic-feature-dashboard-validation/technical-specification.md,docs/Features/template/deterministic-feature-dashboard-validation/development-plan.md,docs/Features/template/deterministic-feature-dashboard-validation/decision-ledger.jsonl,docs/Features/template/deterministic-feature-dashboard-validation/feature.json,docs/Features/template/deterministic-feature-dashboard-validation/handoff.md,docs/Features/template/deterministic-feature-dashboard-validation/worklog.md,docs/FeatureDevelopmentForBeginners.md,docs/Features/project/**,src/**,place.rbxl
- max_product_files: 5
- max_product_lines_changed: 700
- verification_scope: dual-host feature-workflow suite; en-US/ru-RU and LF/CRLF/CR/mixed fixtures; core.autocrlf false/true; owning/foreign full-file checks; workflow/layout validators; git diff check; temporary Rojo build; mandatory Windows 11 release cell; optional nonblocking Windows 10 evidence when available
- scope_baseline_revision: 765fd71b755f2f0878a0c9c8761b887600590cdf

### Research Briefs

- research_not_required | reason=Approved specification sections 4.1–4.9 and 8.1–8.2 completely define loader, timestamp, renderer, normalization, byte-writer, diagnostics, mandatory Windows 11 host matrix, optional nonblocking Windows 10 evidence and SPEC-TEST-001..018 contracts; repository inspection confirms the exact edit seams and the external patch is explicitly non-authoritative.

### Coverage Contract

- acceptance_ids: PRD-AC-001,PRD-AC-002,PRD-AC-003,PRD-AC-004,PRD-AC-005,PRD-AC-006,PRD-AC-007,PRD-AC-008,PRD-AC-009,PRD-AC-010,PRD-AC-011,PRD-AC-012,PRD-AC-013,PRD-AC-014,PRD-AC-015,PRD-AC-016,PRD-AC-017
- automated_identity_namespace: AUTO-TF0008-*
- manual_identity_namespace: MANUAL-TF0008-*
- mandatory_identity_ids: AUTO-TF0008-SPEC-TEST-001,AUTO-TF0008-SPEC-TEST-002,AUTO-TF0008-SPEC-TEST-003,AUTO-TF0008-SPEC-TEST-004,AUTO-TF0008-SPEC-TEST-005,AUTO-TF0008-SPEC-TEST-006,AUTO-TF0008-SPEC-TEST-007,AUTO-TF0008-SPEC-TEST-008,AUTO-TF0008-SPEC-TEST-009,AUTO-TF0008-SPEC-TEST-010,AUTO-TF0008-SPEC-TEST-011,AUTO-TF0008-SPEC-TEST-012,AUTO-TF0008-SPEC-TEST-013,AUTO-TF0008-SPEC-TEST-014,AUTO-TF0008-SPEC-TEST-015,AUTO-TF0008-SPEC-TEST-016,AUTO-TF0008-SPEC-TEST-017,AUTO-TF0008-SPEC-TEST-018; mandatory manual identities=none
- automation_feasibility: all approved acceptance is deterministic and automated on mandatory Windows 11; the original Windows 10/PowerShell 7/ru-RU fixture runs on Windows 11 as SPEC-TEST-015, real Windows 10 evidence is optional and nonblocking, and Studio/manual sets remain empty
- capability_prerequisites: git-local-autocrlf-matrix,powershell-7,rojo-build,windows-11-release-runner,windows-powershell-5-1
- planned_manifest: tests/deterministic-feature-dashboard-validation/verification/SLICE-001-coverage-planned.json
- finalized_manifest: tests/deterministic-feature-dashboard-validation/verification/SLICE-001-coverage-finalized.json
- amendment_authorities: active DEC-*, normalized finding IDs, or controller-approved scope rebaseline only

Acceptance mapping:

- PRD-AC-001 -> AUTO-TF0008-SPEC-TEST-001, AUTO-TF0008-SPEC-TEST-018
- PRD-AC-002 -> AUTO-TF0008-SPEC-TEST-002
- PRD-AC-003 -> AUTO-TF0008-SPEC-TEST-003
- PRD-AC-004 -> AUTO-TF0008-SPEC-TEST-004
- PRD-AC-005 -> AUTO-TF0008-SPEC-TEST-005
- PRD-AC-006 -> AUTO-TF0008-SPEC-TEST-006
- PRD-AC-007 -> AUTO-TF0008-SPEC-TEST-007
- PRD-AC-008 -> AUTO-TF0008-SPEC-TEST-008, AUTO-TF0008-SPEC-TEST-018
- PRD-AC-009 -> AUTO-TF0008-SPEC-TEST-009
- PRD-AC-010 -> AUTO-TF0008-SPEC-TEST-010
- PRD-AC-011 -> AUTO-TF0008-SPEC-TEST-011
- PRD-AC-012 -> AUTO-TF0008-SPEC-TEST-012, AUTO-TF0008-SPEC-TEST-018
- PRD-AC-013 -> AUTO-TF0008-SPEC-TEST-007, AUTO-TF0008-SPEC-TEST-013
- PRD-AC-014 -> AUTO-TF0008-SPEC-TEST-014
- PRD-AC-015 -> AUTO-TF0008-SPEC-TEST-015
- PRD-AC-016 -> AUTO-TF0008-SPEC-TEST-016
- PRD-AC-017 -> AUTO-TF0008-SPEC-TEST-017

### Documentation Contract

- normative_pre_review_paths: .agents/rules/feature-workflow.md,docs/TestCoverage.md
- derived_post_qa_paths: not_required | policy=SPEC-TEST-017
- decision_ids: none
- evidence_sources: exact AUTO-TF0008-SPEC-TEST-001..018 results, controller coverage state, Review finding IDs, QA evidence IDs, host/OS/Git metadata and repository gate exit codes

### Context Capsule Budget

- max_authority_files: 12
- max_evidence_files: 13
- max_total_files: 25
- max_payload_bytes: 360000
- max_estimated_tokens: 90000
- metric_scope: capsule_plus_referenced_files
- authority_paths: exact PRD/spec, AGENTS.md, matched feature/architecture/testing/ADR rules, ADR router/index and Accepted template ADR-0037
- evidence_paths: scripts/FeatureWorkflow.psm1,scripts/tests/feature-workflow.tests.ps1,.gitattributes,.agents/rules/feature-workflow.md,docs/TestCoverage.md,docs/Features/template/README.md and exact read-only entrypoints/schema/dashboard inputs

### Verification and Exit Criteria

1. Немедленно перед первой source-code правкой выполнить
   `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ensure-rojo-server.ps1`;
   без успешного preflight source work не начинается.
2. Выполнить `scripts/tests/feature-workflow.tests.ps1` отдельно под Windows
   PowerShell 5.1 и PowerShell 7.x, используя тот же host family, который
   запустил suite.
3. Пройти `en-US`, `ru-RU`, LF/CRLF/CR/mixed и
   `core.autocrlf=false|true` cells с exact byte/hash immutability assertions,
   включая исходную Windows 10/PowerShell 7/ru-RU fixture как deterministic
   regression input, исполняемый на Windows 11.
4. Под обоими PowerShell hosts пройти
   `scripts/validate-feature-workflow.ps1`,
   `scripts/sync-feature-index.ps1 -Check -Scope All` и
   `scripts/validate-repository-layout.ps1`.
5. Пройти `git diff --check`; выполнить один Rojo build в уникальный temporary
   path вне repository и удалить только этот generated output после проверки.
6. Зафиксировать обязательное Windows 11 release evidence: OS/host versions,
   culture, `core.autocrlf`, canonical output SHA и exit codes. Реальное
   Windows 10 evidence записывается только если среда доступна; его отсутствие
   не создаёт blocker или `blocked_environment` и не меняет mandatory pass/fail.
7. Подтвердить exact pass всех 18 mandatory identities, отсутствие manual
   identities, public export/signature drift, неожиданных файлов и превышения
   лимитов 5 product files/700 product lines.
8. Coverage Steward финализирует schema-2 coverage только после code freeze;
   handoff остаётся незапечатанным при любом обязательном failure/blocker.
9. Studio Play не требуется: `SPEC-TEST-017` подтверждает отсутствие Roblox
   runtime, mapping и DataModel изменений.

### Rollback and Recovery

- Миграций schema/data нет; rollback ограничен точным Git revert путей TF-0008
  и сознательно возвращает известный Windows false-positive.
- Dashboard не откатывается и не исправляется вручную независимо от generator;
  owning sync восстанавливает его из валидных manifests.
- Invalid owning bytes исправляются только validated owning sync. Foreign
  template bytes остаются immutable.
- При противоречии source/spec, необходимости public-contract изменения,
  scope/budget breach или отсутствии mandatory host evidence работа
  останавливается и маршрутизируется на scope expansion либо specification
  reconvergence.
- Revert затрагивает только идентифицированные TF-0008 changes; запрещены
  reset, checkout, stash или удаление существующего unrelated dirty inventory.

### Downstream Consumers

- Runtime `$gamedev-pipeline` Director
- Coverage Steward planning/finalization
- Один phase-scoped Integration Engineer
- Normative Documentation Finisher, convergence reviewer и QA
- Feature workflow только после отдельной явной lifecycle-команды пользователя
- Template release maintainers и derived-project upstream-update consumers
