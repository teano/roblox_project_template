---
document_type: development-plan
status: approved
revision: 2
feature: tracked-only-repository-validation
mode: single_owner
writer_strategy: sequential
planning_analyst_id: tf0011-kiss-planning-analyst-20260826-b
source_prd_path: docs/Features/template/tracked-only-repository-validation/product-requirements.md
source_prd_revision: 2
source_prd_sha256: 4a376538389407b8672b14582deb201a0cbdd7c72cab71eef4db79146fae037c
source_spec_path: docs/Features/template/tracked-only-repository-validation/technical-specification.md
source_spec_revision: 3
source_spec_sha256: 1eb316155e39ee1a65e0d5c5448bba8932acb58bdbf2f3bd67c54339bf639fa2
decision_ledger_path: docs/Features/template/tracked-only-repository-validation/decision-ledger.jsonl
slice_count: 1
approved_by: tf0011-kiss-plan-director-20260826-a
approved_at: 2026-08-26T19:14:12+00:00
---
# Development Plan

## Decision

Writer sequencing: one-at-a-time
Ownership meaning: phase-scoped write lease

Use `single_owner` with exactly one vertical slice. The validator simplification,
its bounded regressions, and coverage documentation are one atomic outcome across
three editable files. Splitting implementation from tests or by Audio owner class
would create layer-only slices without an independently acceptable result.

## Planning Analysis

This is a localized KISS/YAGNI correction. Net code deletion is expected: remove
the historical root `/tests` dependency and replace the overbuilt Luau scanner and
graph proof with the current specification's small canonical-owner map and literal
anchors. The working set is exactly three editable files, at most twelve evidence
files, and approximately 12-20 reusable table-driven regression cases.

The current SFX specification remains the required-identity authority. Existing
ordinal case-sensitive set reconciliation, current static evidence producers,
ordinary working-tree visibility, and unrelated repository checks remain intact.
Luau execution semantics remain owned by the existing Studio runners and suites.

Rejected decompositions and designs:

- Validator, tests, and documentation as separate slices: layer-only ownership.
- Per-owner, static/runner/manual-QA, release, `/tests` invariance, or derived-initialization slices: all contribute to the same small end-to-end acceptance result.
- Luau lexer/parser, escape decoding, balanced block depth, control/data-flow, reachability, comment/inert-string/unreachable decoy graph, or deep `TestHarness`/`AllTestsRunner`/Plan callback proof.
- A declarative evidence registry without demonstrated need, an exhaustive mutation matrix, or recursive full-repository fixture copying.

Primary risks are registration-format drift, accidental weakening of unrelated
validator checks, fixture construction that hides project-owned uncommitted files,
and PowerShell 5.1/7 diagnostic drift. Canonical-owner diagnostics, one reusable
tracked baseline, small mutation tables, and dual-host execution bound these risks.

## Scope Boundaries

In scope:

- Remove all reads and requirements for historical TF-0005 evidence under root `/tests`.
- Reconcile required identities against current tracked canonical owners using only the two approved literal registration shapes and existing static evidence producers.
- Preserve derived pre-commit initialization visibility, missing/rename failures, stale-extra behavior, and every adjacent repository-layout check.
- Replace broad scanner/decoy fixtures with small table-driven regressions and update `docs/TestCoverage.md`.

Out of scope:

- Any write under `src/**` or `tests/**`.
- Runtime Audio, gameplay, public API, bootstrap, manifest, Rojo mapping, DataModel, lifecycle, ADR, agent-rule, feature-state, or pipeline-bundle changes.
- A production Git snapshot/filter/staging/history layer or copying, generating, or restoring historical evidence.
- Parser, reachability, decoy-graph, deep runner/Plan graph proof, registry subsystem, exhaustive mutations, recursive fixture copy, and unrelated cleanup.

No material lifecycle, ownership, or public-contract permission is planned.

## Decision Ledger

- ledger_path: docs/Features/template/tracked-only-repository-validation/decision-ledger.jsonl
- active_decision_ids: none
- new_decision_route: explicit authority -> planning controller internal append validation

The ledger is absent because there are no active accepted `DEC-*` inputs. Engineer
assumptions cannot create decision authority.

## Coverage Strategy

- automated_identity_namespace: AUTO-TF0011-*
- manual_identity_namespace: MANUAL-TF0011-*
- mandatory_rule: AUTO-TF0011-REPOSITORY-001,AUTO-TF0011-REPOSITORY-002,AUTO-TF0011-REPOSITORY-003,AUTO-TF0011-REPOSITORY-004,AUTO-TF0011-REPOSITORY-005,AUTO-TF0011-REPOSITORY-006,MANUAL-TF0011-SCOPE-001 are mandatory and each maps to approved PRD-AC IDs
- automation_feasibility: all six PRD acceptance criteria are deterministic and automated; final unchanged runtime, mapping, and DataModel scope inspection is manual
- capability_prerequisites: windows-11,windows-powershell-5-1,powershell-7,git,rojo
- gates: plan-before-engineering,finalize-after-code-freeze,qa-updated

## Documentation Strategy

- normative_pre_review: docs/TestCoverage.md
- derived_post_qa: not_required | policy=AGENTS.md:Feature-work-lifecycle
- source_rule: PRD r2, specification r3, active DEC IDs, and exact verified controller, Review, and QA evidence only

## Context Budget

- max_authority_files: 3
- max_evidence_files: 12
- max_total_files: 15
- max_payload_bytes: 500000
- max_estimated_tokens: 125000
- metric_scope: capsule_plus_referenced_files
- estimation_recipe: deduplicate canonical project-relative paths, sort ordinal, serialize the capsule as canonical UTF-8 JSON, add exact UTF-8 byte lengths of referenced regular files, and calculate ceil(total_payload_bytes / 4)

## Integration Milestones

- MILESTONE-001: Remove the historical `/tests/.../coverage-manifest.json` dependency and replace parser/graph logic with the narrow owner map and current literal anchors.
- MILESTONE-002: Install a small reusable table-driven matrix for `/tests` invariance, representative runner/manual/static missing or rename failures, stale extras, derived positive/missing/invalid initialization, and one adjacent negative.
- MILESTONE-003: Update `docs/TestCoverage.md` and complete dual-host, repository, build, cleanup, and Studio-exemption gates.

## Slice SLICE-001

### Vertical Outcome

End-to-end: yes
Observable result: A fresh tracked template or derived checkout validates without
root `/tests`; current required Audio identities still fail on representative
missing or rename cases; derived uncommitted initialization files remain visible;
and adjacent repository checks remain mandatory.

### Requirements

- PRD-REQ-001
- PRD-REQ-002
- PRD-REQ-003
- PRD-REQ-004
- PRD-REQ-005
- PRD-NFR-001
- PRD-NFR-002
- PRD-NFR-003
- PRD-AC-001
- PRD-AC-002
- PRD-AC-003
- PRD-AC-004
- PRD-AC-005
- PRD-AC-006

### Dependencies

- none

### Base Contract

- Controller-bound PRD r2 SHA-256 `4a376538389407b8672b14582deb201a0cbdd7c72cab71eef4db79146fae037c`.
- Controller-bound SPEC_READY specification r3 SHA-256 `1eb316155e39ee1a65e0d5c5448bba8932acb58bdbf2f3bd67c54339bf639fa2`.
- Controller-generated technical baseline receipts for every editable and expected path.
- Current required-subset, ordinal case-sensitive set, repeated-reference deduplication, static evidence, stale-extra, working-tree visibility, and unrelated-check semantics remain unchanged.

### Handoff Contract

- Controller-generated schema-2 handoff with exact baseline and change evidence.
- decision_ids: none
- coverage_state: exact results for six mandatory automated identities and MANUAL-TF0011-SCOPE-001
- documentation_state: docs/TestCoverage.md updated and validated before Review
- open_assumptions: none on successful exit
- Handoff evidence includes changed-file receipts, dual-host results, tracked baseline and `/tests` variants, representative identity failures, derived initialization cases, tracked-tests query, repository gates, temporary Rojo build/removal, and final scope inspection.

### Owned Paths

- scripts/validate-repository-layout.ps1
- scripts/tests/feature-workflow.tests.ps1
- docs/TestCoverage.md

### Expected Paths

- docs/Features/template/sfx-system/technical-specification.md
- src/ReplicatedStorage/Shared/Tests/AudioManualQaPlan.luau
- src/ServerScriptService/Tests/AudioManualQaTestRunner.luau
- src/ServerScriptService/Tests/AudioCatalogTestRunner.luau
- src/ServerScriptService/Tests/ContentPreloaderTestRunner.luau
- src/ServerScriptService/Tests/AudioPlaybackTestRunner.luau
- src/ServerScriptService/Tests/AudioIntegrationTestRunner.luau
- .gitignore
- default.project.json

### Forbidden Scope

- No writes under `tests/**`, `src/**`, `.agents/**`, `.agentic-pipeline-v2/**`, or the pipeline bundle.
- No runtime, gameplay, public Audio API, bootstrap, manifest, lifecycle, ownership, ADR, feature-state, Rojo mapping, `default.project.json`, `place.rbxl`, or DataModel changes.
- No production Git input abstraction, snapshot, staging, archive, history recovery, evidence copy/generation/restoration, or general ignored-file isolation.
- No lexer/parser, escape decoder, block-depth logic, control/data-flow, reachability, decoy graph, deep `TestHarness`/`AllTestsRunner`/Plan callback proof, declarative registry, exhaustive matrix, recursive fixture copy, or drive-by cleanup.
- No weakening unrelated repository checks or existing lifecycle assertions.

### Scope Contract

- acceptance_ids: PRD-AC-001,PRD-AC-002,PRD-AC-003,PRD-AC-004,PRD-AC-005,PRD-AC-006
- editable_paths: scripts/validate-repository-layout.ps1,scripts/tests/feature-workflow.tests.ps1,docs/TestCoverage.md
- shared_touchpoints: TP-001,TP-002,TP-003
- shared_touchpoint: TP-001 | path=scripts/validate-repository-layout.ps1 | symbols=TF-0005 evidence block,current-source reconciliation helpers,Add-AudioEvidenceRecord | allowed_change=remove historical root tests dependency and use canonical-owner literal anchors while preserving existing static and adjacent checks | forbidden_change=unrelated repository checks,public command parameters,production Git layer,parser or reachability proof
- shared_touchpoint: TP-002 | path=scripts/tests/feature-workflow.tests.ps1 | symbols=repository validation fixture helpers,TF-0011 regression rows,TF-0011 completion gate | allowed_change=replace broad scanner and decoy matrices with one tracked baseline and small table-driven regressions using the current host | forbidden_change=weaken existing lifecycle assertions,recursive full-repository copy,child-host substitution
- shared_touchpoint: TP-003 | path=docs/TestCoverage.md | symbols=tracked-only repository validation coverage | allowed_change=document the narrow owner contract,tests invariance,derived pre-commit visibility,representative regressions,dual-host gates,and Studio exemption | forbidden_change=alter unrelated subsystem release requirements or claim parser and reachability guarantees
- excluded_components: Roblox runtime,Audio implementation and public APIs,project initialization behavior,feature lifecycle,Rojo and DataModel,production Git layer,historical pipeline evidence,pipeline bundle
- excluded_paths: tests/**,src/**,default.project.json,place.rbxl,.agents/**,.agentic-pipeline-v2/**,docs/Features/template/sfx-system/**,docs/AudioSystem.md,docs/AudioManualQA.md,.gitignore
- max_product_files: 3
- max_product_lines_changed: 1200
- verification_scope: dual-host feature-workflow suite,direct repository validator,tracked baseline without tests,absent and malformed tests invariance,representative runner owner manual Plan and static missing or rename cases,stale extra,derived pre-commit positive missing and invalid cases,adjacent negative,tracked-tests query,feature-workflow validator,all-namespace index check,diff check,temporary Rojo build and cleanup,final runtime mapping and DataModel scope inspection

### Research Briefs

- research_not_required | reason=Approved PRD r2, SPEC_READY specification r3, current owned files, and the listed canonical owner files fully define the small implementation seam, exclusions, and verification contract.

### Coverage Contract

- acceptance_ids: PRD-AC-001,PRD-AC-002,PRD-AC-003,PRD-AC-004,PRD-AC-005,PRD-AC-006
- automated_identity_namespace: AUTO-TF0011-*
- manual_identity_namespace: MANUAL-TF0011-*
- mandatory_identity_ids: AUTO-TF0011-REPOSITORY-001,AUTO-TF0011-REPOSITORY-002,AUTO-TF0011-REPOSITORY-003,AUTO-TF0011-REPOSITORY-004,AUTO-TF0011-REPOSITORY-005,AUTO-TF0011-REPOSITORY-006,MANUAL-TF0011-SCOPE-001
- automation_feasibility: all six PRD acceptance criteria are deterministic and automated; only final unchanged runtime, mapping, DataModel, and Studio-exemption inspection is manual
- capability_prerequisites: windows-11,windows-powershell-5-1,powershell-7,git,rojo
- amendment_authorities: approved plan revision for identity changes; Requirements reconvergence for PRD acceptance changes; Specification reconvergence for owner or literal-anchor changes

### Documentation Contract

- normative_pre_review_paths: docs/TestCoverage.md
- derived_post_qa_paths: not_required | policy=AGENTS.md:Feature-work-lifecycle
- decision_ids: none
- evidence_sources: dual-host feature-workflow outputs,repository mutation diagnostics,tracked-tests query,repository validators,diff check,temporary Rojo build and cleanup,Review and QA controller artifacts

### Context Capsule Budget

- max_authority_files: 3
- max_evidence_files: 12
- max_total_files: 15
- max_payload_bytes: 500000
- max_estimated_tokens: 125000
- metric_scope: capsule_plus_referenced_files
- authority_paths: docs/Features/template/tracked-only-repository-validation/product-requirements.md,docs/Features/template/tracked-only-repository-validation/technical-specification.md,docs/Features/template/tracked-only-repository-validation/development-plan.md
- evidence_paths: .agents/rules/index.md,.agents/rules/feature-workflow.md,.agents/rules/testing.md,.gitignore,default.project.json,docs/Features/template/sfx-system/technical-specification.md,src/ReplicatedStorage/Shared/Tests/AudioManualQaPlan.luau,src/ServerScriptService/Tests/AudioManualQaTestRunner.luau,src/ServerScriptService/Tests/AudioCatalogTestRunner.luau,src/ServerScriptService/Tests/ContentPreloaderTestRunner.luau,src/ServerScriptService/Tests/AudioPlaybackTestRunner.luau,src/ServerScriptService/Tests/AudioIntegrationTestRunner.luau

### Verification and Exit Criteria

- Immediately before the first source-code edit, `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ensure-rojo-server.ps1` succeeds.
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/tests/feature-workflow.tests.ps1` exits 0.
- `pwsh.exe -NoProfile -File scripts/tests/feature-workflow.tests.ps1` exits 0.
- Every child PowerShell command uses the current process executable.
- A reusable tracked baseline without root `/tests` passes; adding malformed historical evidence and an unrelated nested `/tests` file leaves exit result and normalized diagnostics unchanged.
- Representative missing or rename cases for each runner owner class, manual Plan, and an existing static producer fail with identity and expected owner diagnostics; a stale extra passes.
- A derived fixture with correct uncommitted `DerivedWindowConfig.luau` passes; missing and invalid variants retain existing initialization failures.
- One adjacent non-TF-0005 mutation still fails, and all existing suite cases remain mandatory.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-feature-workflow.ps1` exits 0.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/sync-feature-index.ps1 -Check -Scope All` exits 0.
- `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-repository-layout.ps1` exits 0.
- `git ls-files -- tests` returns no tracked files, and `git diff --check` exits 0.
- `rojo build default.project.json --output <temporary-path-outside-repository>` succeeds, produces a non-empty file, and the contained output is removed after evidence capture.
- Final diff proves no `src/**`, Rojo mapping, runtime, or DataModel changes, so Studio Play is exempt; otherwise the slice cannot exit without the matched Studio gates.
- `docs/TestCoverage.md` reflects the exact narrow identity and verification contract without stale parser, reachability, deep-graph, or exhaustive-decoy claims.

### Rollback and Recovery

- Controller rollback restores only the three owned paths from their exact pre-edit receipts and CAS baseline.
- Temporary fixture roots and Rojo outputs are removed only after containment is proven under the system temporary directory.
- No migration, persistent evidence, Git index manipulation, runtime state, or DataModel rollback exists.
- Missing mandatory evidence or an out-of-scope diff blocks handoff; resume from the same controller-owned slice baseline.

### Downstream Consumers

- Implementation Review: three-file scope, simplification, literal-owner correctness, diagnostic precision, and no unrelated weakening.
- QA: mandatory identities, dual-host evidence, derived visibility, adjacent negative, capability prerequisites, and cleanup.
- Documentation verification: exact `docs/TestCoverage.md` contract.
- Feature lifecycle owner: completed evidence only after a separate explicit user-authorized lifecycle transition.
