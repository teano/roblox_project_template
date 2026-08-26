---
document_type: development-plan
status: approved
revision: 3
feature: ui-system
mode: sequential_slices
writer_strategy: sequential
planning_analyst_id: tf0010-ui-plan-local-fixture-analyst-20260825
source_prd_path: docs/Features/template/ui-system/product-requirements.md
source_prd_revision: 3
source_prd_sha256: 31f00b75820a2a917ea55c1f486a3846b7e273eb689f563601ec2093269c0995
source_spec_path: docs/Features/template/ui-system/technical-specification.md
source_spec_revision: 9
source_spec_sha256: e644d22ca63856f2ef361252a53edee5f80999f2637b65a04663ff3e667d84cf
decision_ledger_path: docs/Features/template/ui-system/decision-ledger.jsonl
slice_count: 4
approved_by: tf0010-ui-plan-local-fixture-director-20260825
approved_at: 2026-08-25T03:31:24+00:00
---
# UI System Development Plan

## Decision

Writer sequencing: one-at-a-time
Ownership meaning: phase-scoped write lease

Mode: sequential_slices.

Four sequential end-to-end outcomes bound a new 20-owner client UI context while preserving one writer and sealed shared-touchpoint handoffs. The approved scope contains 175 functional requirements, 6 non-functional requirements, 91 acceptance criteria, 16 runtime test partitions, one static-type gate, a manual Studio/device gate, and separate read-only Experience-setting evidence. A single-owner execution would require unsafe context compression across runtime state machines, authoring tooling, repository policy, tests, and release evidence.

Rejected decompositions:

- Backend/UI/tests layers are not independent outcomes: there is no server backend, and each state-machine increment must ship with deterministic contract coverage.
- Parallel component writers are rejected because UiSystem, BaseUiElement, BaseWindowView, WindowNavigator, ClientManifest, UiSystemTestRunner, and docs/UiSystem.md are repeated shared touchpoints.
- Config, loader, pool, and navigator module slices are implementation layers rather than observable user or developer outcomes.
- Detached documentation/tooling cleanup is rejected; authoring support remains an end-to-end developer workflow with repository validation, deterministic local release evidence, and truthful evidence documentation.

## Planning Analysis

The expected working set is approximately 44 to 48 unique files and 10,000 to 16,000 changed lines. It includes about 27 new production Luau modules under src/ReplicatedStorage/Client/UI/**, one initialization command, two existing source integration touchpoints, one focused test runner, one aggregate-suite row, and roughly 15 rule, ADR, skill, template, validator, and documentation paths.

The client manifest is the composition seam. The UI command follows StartupContentPreload, Pooling, and Players and precedes downstream consumers without changing Audio, Communication, save, or bootstrap ownership. PoolModule, ContentPreloader, PlayersModule, Signal, and CommunicationSerialize are injected or consumed through their existing contracts and remain protected from implementation changes.

Primary risks are generation/deadline/quarantine recovery, exact lifecycle-event ordering, repeated sequential writes to the navigation/view/test surfaces, the Script Analysis-only generic type gate, non-cancellable Roblox asset operations, deterministic local fixture cleanup, and exact read-only selected-place setting evidence. External platform assumptions remain constraints rather than permission to add fallback APIs.

## Scope Boundaries

In scope:

- The complete client UI bounded context: persistent root/hosts, semantic hierarchy/events, controllers, IDs, configuration, cloud loading, pooling, navigation, focus, transitions, handles, cleanup, and failure recovery.
- Explicit client-manifest composition through one UI initialization command.
- UI authoring template and skills, derived-project ownership enforcement, repository validation, one template ADR, focused tests, current system documentation, and exact deterministic local/read-only release evidence.

Out of scope and protected:

- Analytics implementation, server gameplay, remotes, persistence, HUD/toast lifecycle facade, Back/history, global animation, arbitrary rollback, external dependencies, and drive-by cleanup.
- Changes to shared Pool, ContentPreloader, Signal, serializer, PlayersModule, AssetRegistry, Audio, Teleport, Experience Config, save, or domain implementations.
- Creation of src/ReplicatedStorage/Project/** in the reusable template or an unused DerivedUiActionIds module.
- AssetId requests, cloud asset creation/load evidence without an already approved external fixture, publish/deploy, place.rbxl changes, Experience attachment, setting or cloud identity mutation, and default.project.json identity edits.
- Hand editing .agentic-pipeline/**, approved PRD/spec bytes, feature manifests/generated indexes/controller handoffs/coverage state, or any feature lifecycle transition; factual corrections to the existing handoff/worklog evidence are allowed without changing lifecycle state.

## Decision Ledger

- ledger_path: docs/Features/template/ui-system/decision-ledger.jsonl
- active_decision_ids: none
- current_state: accepted DEC-001 exists in the append-only ledger but is not active or consumed by this plan revision
- new_decision_route: explicit authority -> planning controller internal append validation

No Engineer assumption becomes a DEC entry. The planned template ADR at docs/adr/template/0045-client-ui-system-boundaries.md records repository architecture and does not substitute for a planning-ledger decision.

## Coverage Strategy

- manifest_path: tests/ui-system/verification/coverage-schema-2.json
- automated_identity_namespace: AUTO-TF0010-*
- manual_identity_namespace: MANUAL-TF0010-*
- mandatory_rule: every approved PRD-AC ID is assigned to at least one slice and every evidence identity is registered against its specification derivation ID
- automation_feasibility: injected fakes and the repository-owned local data-only fixture cover deterministic state, cleanup, retry, identity, configuration, serializer, pool, bootstrap, canonical compile, production loader, preload, and cache partitions; Script Analysis covers the static generic mismatch; device presentation and the separate read-only AllowInsertFreeAssets observation remain manual; cloud smoke is conditional and non-gating without an already approved external fixture
- capability_prerequisites: experience-settings-access,gamepad-input,powershell-5-1,published-template-validation-place,roblox-studio-canonical-session,rojo-build,rojo-server-preflight,studio-device-emulation,studio-play-mode,studio-script-analysis,studio-server-test-runner
- gates: plan-before-engineering,finalize-after-code-freeze,qa-updated

## Documentation Strategy

- normative_pre_review: .agents/rules/ui.md,.agents/rules/index.md,.agents/rules/project-initialization.md,.agents/rules/template-updates.md,.agents/skills/window-authoring/SKILL.md,.agents/skills/project-initialize/SKILL.md,.agents/skills/project-initialize/agents/openai.yaml,.agents/templates/window-authoring/WindowTemplate.model.json,docs/adr/template/0045-client-ui-system-boundaries.md,docs/adr/template/README.md,docs/UiSystem.md,docs/InitializationAndSaveSystem.md,docs/TestCoverage.md,docs/Features/template/ui-system/handoff.md,docs/Features/template/ui-system/worklog.md,README.md
- derived_post_qa: not_required | policy=docs/Features/template/ui-system/technical-specification.md:4.7
- source_rule: active DEC IDs, approved PRD/spec IDs, the accepted template ADR, and exact verified evidence only

## Context Budget

- max_authority_files: 30
- max_evidence_files: 40
- max_total_files: 70
- max_payload_bytes: 650000
- max_estimated_tokens: 162500
- metric_scope: capsule_plus_referenced_files
- estimation_recipe: ceil((canonical capsule UTF-8 bytes + exact referenced authority/evidence bytes) / 4)

## Integration Milestones

- MILESTONE-001: Client bootstrap publishes one persistent UiRoot with three hosts and a usable semantic controller/event surface.
- MILESTONE-002: One configured window completes load, preload, initialization, open, and close through destroy or a generation-safe pool lifecycle.
- MILESTONE-003: Multi-window stack, focus, blocking, transitions, recovery, handles, and lifecycle ordering satisfy deterministic partitions.
- MILESTONE-004: Authoring/derived-project workflow, repository enforcement, static analysis with cleaned fixtures, full suites, the complete local-fixture Studio checklist, automated local loader evidence, and separate exact-place read-only AllowInsertFreeAssets evidence are sealed; cloud smoke remains conditional on an already approved external fixture.

## Slice SLICE-001

### Vertical Outcome

End-to-end: yes
Observable result: Client bootstrap atomically publishes one persistent safe-area UiRoot, ordered HUD/toast/window hosts, explicit host/context injection, a dynamic controller hierarchy, semantic base actions, collision-safe IDs, and one non-blocking root event stream; no window is created automatically.

### Requirements

- PRD-REQ-001, PRD-REQ-002, PRD-REQ-003, PRD-REQ-004, PRD-REQ-005, PRD-REQ-006, PRD-REQ-007, PRD-REQ-008, PRD-REQ-031, PRD-REQ-032, PRD-REQ-033, PRD-REQ-036, PRD-REQ-038, PRD-REQ-039, PRD-REQ-040, PRD-REQ-041, PRD-REQ-042, PRD-REQ-043, PRD-REQ-044, PRD-REQ-045, PRD-REQ-046, PRD-REQ-047, PRD-REQ-048, PRD-REQ-049, PRD-REQ-051, PRD-REQ-053, PRD-REQ-054, PRD-REQ-055, PRD-REQ-056, PRD-REQ-057, PRD-REQ-058, PRD-REQ-059, PRD-REQ-060, PRD-REQ-078, PRD-REQ-079, PRD-REQ-080, PRD-REQ-087, PRD-REQ-088, PRD-REQ-089, PRD-REQ-090, PRD-REQ-091, PRD-REQ-092, PRD-REQ-093, PRD-REQ-096, PRD-REQ-097, PRD-REQ-109, PRD-REQ-110, PRD-REQ-111, PRD-REQ-112, PRD-REQ-113, PRD-REQ-114, PRD-REQ-115, PRD-REQ-116, PRD-REQ-117, PRD-REQ-125, PRD-REQ-128, PRD-REQ-129, PRD-REQ-130, PRD-REQ-131, PRD-REQ-138, PRD-REQ-141, PRD-REQ-142
- PRD-AC-001
- PRD-AC-009
- PRD-AC-010
- PRD-AC-011
- PRD-AC-012
- PRD-AC-021
- PRD-AC-024
- PRD-AC-025
- PRD-AC-032
- PRD-AC-033
- PRD-AC-034
- PRD-AC-038
- PRD-AC-040
- PRD-AC-041
- PRD-AC-042
- PRD-AC-048
- PRD-AC-050

### Dependencies

- none

### Base Contract

Pinned PRD revision 3 and specification revision 8; active decision set none; current branch contains no UI runtime/rule/doc/test. The Engineer receives current ClientManifest, AllTestsRunner, Players/Signal/serializer APIs, a controller-owned pre-edit snapshot/CAS, and the exact unrelated-change inventory. The mandatory Rojo preflight runs immediately before the first source edit.

### Handoff Contract

The controller-generated schema-2 handoff seals the root/event public surface, exact result revision, changed paths/symbols, AUTO-TF0010-TS-TEST-001/013/015 and MANUAL-TF0010-TS-TEST-012 state, normative documentation state, and the fields decision_ids, coverage_state, documentation_state, and open_assumptions. Empty sets remain explicit; workers do not hand-author revisions, diffs, or handoff mechanics.

### Owned Paths

- src/ReplicatedStorage/Client/UI/UiSystem.luau
- src/ReplicatedStorage/Client/UI/UiRootController.luau
- src/ReplicatedStorage/Client/UI/UiElementIdentityRegistry.luau
- src/ReplicatedStorage/Client/UI/UiRootEventStream.luau
- src/ReplicatedStorage/Client/UI/Elements/BaseUiElement.luau
- src/ReplicatedStorage/Client/UI/Elements/Controllers/FrameController.luau
- src/ReplicatedStorage/Client/UI/Elements/Controllers/TextController.luau
- src/ReplicatedStorage/Client/UI/Elements/Controllers/ImageController.luau
- src/ReplicatedStorage/Client/UI/Elements/Controllers/ButtonController.luau
- src/ReplicatedStorage/Client/UI/Elements/Controllers/TextBoxController.luau
- src/ReplicatedStorage/Client/UI/Elements/Controllers/FormController.luau
- src/ReplicatedStorage/Client/UI/Elements/Controllers/ScrollingFrameController.luau
- src/ReplicatedStorage/Client/UI/Windows/BaseWindowView.luau
- src/ReplicatedStorage/Client/UI/Actions/UiActionIds.luau
- src/ReplicatedStorage/Client/UI/Actions/UiActionCatalog.luau
- src/ReplicatedStorage/Client/Initialization/Commands/UiInitializationCommand.luau
- src/ServerScriptService/Tests/UiSystemTestRunner.luau
- .agents/rules/ui.md
- docs/adr/template/0045-client-ui-system-boundaries.md
- docs/UiSystem.md

### Expected Paths

- src/ReplicatedStorage/Client/Initialization/ClientManifest.luau
- src/StarterPlayerScripts/Bootstrap.client.luau
- src/ReplicatedStorage/Shared/Initialization/InitializationRunner.luau
- src/ServerScriptService/Tests/AllTestsRunner.luau
- src/ReplicatedStorage/Client/Players/PlayersModule.luau
- src/ReplicatedStorage/Shared/Util/Signal.luau
- src/ReplicatedStorage/Shared/Communication/CommunicationSerialize.luau
- .agents/rules/index.md
- docs/adr/template/README.md
- docs/InitializationAndSaveSystem.md
- docs/TestCoverage.md

### Forbidden Scope

Window asset loading, pools, multi-window stack/focus/transitions, authoring skills/derived enforcement, external subsystem API changes, server/remotes/save/analytics, HUD/toast lifecycle facade, bootstrap mutation, place.rbxl, and unrelated cleanup.

### Scope Contract

- acceptance_ids: PRD-AC-001,PRD-AC-009,PRD-AC-010,PRD-AC-011,PRD-AC-012,PRD-AC-021,PRD-AC-024,PRD-AC-025,PRD-AC-032,PRD-AC-033,PRD-AC-034,PRD-AC-038,PRD-AC-040,PRD-AC-041,PRD-AC-042,PRD-AC-048,PRD-AC-050
- editable_paths: src/ReplicatedStorage/Client/UI/UiSystem.luau,src/ReplicatedStorage/Client/UI/UiRootController.luau,src/ReplicatedStorage/Client/UI/UiElementIdentityRegistry.luau,src/ReplicatedStorage/Client/UI/UiRootEventStream.luau,src/ReplicatedStorage/Client/UI/Elements/BaseUiElement.luau,src/ReplicatedStorage/Client/UI/Elements/Controllers/FrameController.luau,src/ReplicatedStorage/Client/UI/Elements/Controllers/TextController.luau,src/ReplicatedStorage/Client/UI/Elements/Controllers/ImageController.luau,src/ReplicatedStorage/Client/UI/Elements/Controllers/ButtonController.luau,src/ReplicatedStorage/Client/UI/Elements/Controllers/TextBoxController.luau,src/ReplicatedStorage/Client/UI/Elements/Controllers/FormController.luau,src/ReplicatedStorage/Client/UI/Elements/Controllers/ScrollingFrameController.luau,src/ReplicatedStorage/Client/UI/Windows/BaseWindowView.luau,src/ReplicatedStorage/Client/UI/Actions/UiActionIds.luau,src/ReplicatedStorage/Client/UI/Actions/UiActionCatalog.luau,src/ReplicatedStorage/Client/Initialization/Commands/UiInitializationCommand.luau,src/ReplicatedStorage/Client/Initialization/ClientManifest.luau,src/ServerScriptService/Tests/UiSystemTestRunner.luau,src/ServerScriptService/Tests/AllTestsRunner.luau,.agents/rules/ui.md,.agents/rules/index.md,docs/adr/template/0045-client-ui-system-boundaries.md,docs/adr/template/README.md,docs/UiSystem.md,docs/InitializationAndSaveSystem.md,docs/TestCoverage.md
- shared_touchpoints: TP-001,TP-002,TP-003,TP-004,TP-005,TP-006
- shared_touchpoint: TP-001 | path=src/ReplicatedStorage/Client/Initialization/ClientManifest.luau | symbols=UiSystem,UiInitializationCommand,services.UI,Commands | allowed_change=additive explicit UI construction/service/command after declared dependencies | forbidden_change=unrelated service ownership,Audio/Communication/save ordering,bootstrap
- shared_touchpoint: TP-002 | path=src/ServerScriptService/Tests/AllTestsRunner.luau | symbols=suites | allowed_change=add one UiSystemTestRunner row | forbidden_change=reorder,removal,runner semantics
- shared_touchpoint: TP-003 | path=.agents/rules/index.md | symbols=Path and concern mapping,Available rule files | allowed_change=add UI routes and ui.md entry | forbidden_change=unrelated routing
- shared_touchpoint: TP-004 | path=docs/adr/template/README.md | symbols=Decision index | allowed_change=add ADR-0045 row | forbidden_change=existing ADR status/history
- shared_touchpoint: TP-005 | path=docs/InitializationAndSaveSystem.md | symbols=client initialization order,UI subsection | allowed_change=add UI command/order/ownership contract | forbidden_change=save,Audio,Teleport,communication semantics
- shared_touchpoint: TP-006 | path=docs/TestCoverage.md | symbols=Contract-to-suite matrix,Deterministic Studio gate | allowed_change=add UI root/event coverage and runner | forbidden_change=existing suite contracts
- excluded_components: pool-core,content-preloader,asset-registry,players-wrapper,communication,replicatedfirst-loading,server-runtime,audio,save-domain,canonical-scene
- excluded_paths: src/ReplicatedStorage/Shared/Pooling/**,src/ReplicatedStorage/Shared/ContentPreloading/**,src/ReplicatedStorage/Shared/Assets/**,src/ReplicatedStorage/Shared/Communication/**,src/ReplicatedStorage/Shared/Util/Signal.luau,src/ReplicatedStorage/Client/Players/**,src/ReplicatedStorage/Client/Audio/**,src/ReplicatedFirst/**,src/ServerScriptService/Modules/**,place.rbxl,default.project.json
- max_product_files: 28
- max_product_lines_changed: 4200
- verification_scope: AUTO-TF0010-TS-TEST-001,AUTO-TF0010-TS-TEST-013,AUTO-TF0010-TS-TEST-015,MANUAL-TF0010-TS-TEST-012; UiSystemTestRunner; SystemTestRunner; AllTestsRunner; repository validator; temporary Rojo build; clean client bootstrap and respawn/safe-area observation

### Research Briefs

- research_not_required | reason=Approved specification §§4.2, 4.6, 7.1 and TS-TEST-001/012/013/015 fully define root, controller, event, bootstrap and failure boundaries; CodeGraph and direct inspection confirmed all existing integration seams.

### Coverage Contract

- acceptance_ids: PRD-AC-001,PRD-AC-009,PRD-AC-010,PRD-AC-011,PRD-AC-012,PRD-AC-021,PRD-AC-024,PRD-AC-025,PRD-AC-032,PRD-AC-033,PRD-AC-034,PRD-AC-038,PRD-AC-040,PRD-AC-041,PRD-AC-042,PRD-AC-048,PRD-AC-050
- automated_identity_namespace: AUTO-TF0010-SLICE-001-*
- manual_identity_namespace: MANUAL-TF0010-SLICE-001-*
- mandatory_identity_ids: AUTO-TF0010-TS-TEST-001,AUTO-TF0010-TS-TEST-013,AUTO-TF0010-TS-TEST-015,MANUAL-TF0010-TS-TEST-012
- automation_feasibility: deterministic root/controller/event/bootstrap partitions are automated; engine safe-area/respawn presentation is observed in the canonical Studio session
- capability_prerequisites: powershell-5-1,roblox-studio-canonical-session,rojo-build,rojo-server-preflight,studio-device-emulation,studio-play-mode,studio-server-test-runner
- planned_manifest: tests/ui-system/verification/SLICE-001-coverage-planned.json
- finalized_manifest: tests/ui-system/verification/SLICE-001-coverage-finalized.json
- amendment_authorities: active DEC-*,normalized finding IDs,controller-approved scope rebaseline only

### Documentation Contract

- normative_pre_review_paths: .agents/rules/ui.md,.agents/rules/index.md,docs/adr/template/0045-client-ui-system-boundaries.md,docs/adr/template/README.md,docs/UiSystem.md,docs/InitializationAndSaveSystem.md,docs/TestCoverage.md
- derived_post_qa_paths: not_required | policy=docs/Features/template/ui-system/technical-specification.md:4.7
- decision_ids: none
- evidence_sources: PRD revision 3,specification revision 8,AUTO-TF0010-TS-TEST-001,AUTO-TF0010-TS-TEST-013,AUTO-TF0010-TS-TEST-015,MANUAL-TF0010-TS-TEST-012,Review finding IDs,QA evidence IDs

### Context Capsule Budget

- max_authority_files: 18
- max_evidence_files: 20
- max_total_files: 38
- max_payload_bytes: 340000
- max_estimated_tokens: 85000
- metric_scope: capsule_plus_referenced_files
- authority_paths: docs/Features/template/ui-system/product-requirements.md,docs/Features/template/ui-system/technical-specification.md,AGENTS.md,.agents/rules/architecture.md,.agents/rules/architecture-decisions.md,.agents/rules/initialization.md,.agents/rules/testing.md,.agents/rules/players.md,.agents/rules/signals.md,.agents/rules/communication.md,.agents/rules/rojo-project.md,docs/adr/README.md,docs/adr/template/README.md
- evidence_paths: src/ReplicatedStorage/Client/UI/**,src/ReplicatedStorage/Client/Initialization/ClientManifest.luau,src/StarterPlayerScripts/Bootstrap.client.luau,src/ReplicatedStorage/Shared/Initialization/InitializationRunner.luau,src/ServerScriptService/Tests/UiSystemTestRunner.luau,src/ServerScriptService/Tests/AllTestsRunner.luau,src/ServerScriptService/Tests/TestHarness.luau,docs/UiSystem.md,docs/InitializationAndSaveSystem.md,docs/TestCoverage.md

### Verification and Exit Criteria

- Run the mandatory Rojo preflight before source edits and again before the first Studio operation.
- Focused UiSystemTestRunner, SystemTestRunner, and AllTestsRunner report failed = 0.
- Repository-layout and feature-workflow validators, git diff --check, and a temporary Rojo build pass.
- A clean selected canonical Studio Play session proves one root, three ordered empty hosts, failure-atomic malformed-root handling, persistence across respawn, safe-area update, and clean server/client output.
- ADR, rule, and current documentation are updated; the controller seals coverage and the slice handoff.

### Rollback and Recovery

Revert only SLICE-001-owned additions and additive touchpoint hunks to the controller pre-slice snapshot. Do not reset or stash unrelated work. Root construction remains off-tree until atomic commit; failed initialization destroys candidates and exposes no partial service. No persistence or scene rollback exists.

### Downstream Consumers

- SLICE-002
- Project HUD/toast controllers through host/context injection
- Future analytics through the root event source
- Review and Coverage Steward

## Slice SLICE-002

### Vertical Outcome

End-to-end: yes
Observable result: An empty-stack caller can use universal or typed APIs to resolve one canonical definition, load/validate/preload/cache a cloud GUI template, initialize an off-tree concrete view, open it, acquire and release blocking handles, receive a generation-safe window handle, and close through destruction or the existing homogeneous pool contract with deterministic timeout/failure cleanup.

### Requirements

- PRD-REQ-009, PRD-REQ-010, PRD-REQ-011, PRD-REQ-012, PRD-REQ-013, PRD-REQ-014, PRD-REQ-015, PRD-REQ-016, PRD-REQ-023, PRD-REQ-024, PRD-REQ-025, PRD-REQ-026, PRD-REQ-037, PRD-REQ-067, PRD-REQ-068, PRD-REQ-069, PRD-REQ-070, PRD-REQ-071, PRD-REQ-072, PRD-REQ-073, PRD-REQ-074, PRD-REQ-075, PRD-REQ-076, PRD-REQ-077, PRD-REQ-127, PRD-REQ-139, PRD-REQ-140, PRD-REQ-143, PRD-REQ-144, PRD-REQ-145, PRD-REQ-146, PRD-REQ-147, PRD-REQ-148, PRD-REQ-149, PRD-REQ-150, PRD-REQ-151, PRD-REQ-152, PRD-REQ-153, PRD-REQ-154, PRD-REQ-158, PRD-REQ-159, PRD-REQ-160, PRD-REQ-161, PRD-REQ-162, PRD-REQ-166, PRD-REQ-168, PRD-REQ-169, PRD-REQ-178, PRD-REQ-179, PRD-REQ-196, PRD-REQ-201, PRD-REQ-202
- PRD-AC-002
- PRD-AC-003
- PRD-AC-006
- PRD-AC-007
- PRD-AC-008
- PRD-AC-013
- PRD-AC-016
- PRD-AC-017
- PRD-AC-018
- PRD-AC-019
- PRD-AC-020
- PRD-AC-039
- PRD-AC-049
- PRD-AC-051
- PRD-AC-053
- PRD-AC-054
- PRD-AC-056
- PRD-AC-057
- PRD-AC-058
- PRD-AC-059
- PRD-AC-061
- PRD-AC-062
- PRD-AC-063
- PRD-AC-064
- PRD-AC-067
- PRD-AC-075
- PRD-AC-076
- PRD-AC-077
- PRD-AC-084
- PRD-AC-094
- PRD-AC-100
- PRD-AC-101
- PRD-AC-103

### Dependencies

- SLICE-001

### Base Contract

The slice receives the sealed SLICE-001 root/event API and exact coverage/documentation state, pinned source authorities, active decisions none, and the controller result revision. It must not reinterpret the sealed root/event contract.

### Handoff Contract

The controller-generated schema-2 handoff seals canonical definition identity, public result unions, first-window lifecycle, loader single-flight/cache behavior, pool adapter/use-token behavior, handle generation, blocker behavior, static-type evidence, exact changes, and the fields decision_ids, coverage_state, documentation_state, and open_assumptions.

### Owned Paths

- src/ReplicatedStorage/Client/UI/Config/**
- src/ReplicatedStorage/Client/UI/Internal/UiSyncHookGuard.luau
- src/ReplicatedStorage/Client/UI/WindowAssetLoader.luau
- src/ReplicatedStorage/Client/UI/WindowPoolOwner.luau
- src/ReplicatedStorage/Client/UI/WindowNavigator.luau
- src/ReplicatedStorage/Client/UI/WindowHandle.luau
- src/ReplicatedStorage/Client/UI/WindowInputBlocker.luau
- src/ReplicatedStorage/Client/UI/Elements/Controllers/BackgroundController.luau
- src/ReplicatedStorage/Client/UI/Windows/BaseWindowView.luau
- src/ReplicatedStorage/Client/UI/UiSystem.luau
- src/ServerScriptService/Tests/UiSystemTestRunner.luau
- docs/UiSystem.md

### Expected Paths

- src/ReplicatedStorage/Client/UI/**
- src/ReplicatedStorage/Client/Initialization/ClientManifest.luau
- src/ReplicatedStorage/Shared/Pooling/**
- src/ReplicatedStorage/Shared/ContentPreloading/**
- src/ReplicatedStorage/Shared/Communication/CommunicationSerialize.luau
- docs/ResourceManagement.md
- docs/ContentPreloading.md
- docs/TestCoverage.md

### Forbidden Scope

Multi-window visibility/focus/replacement beyond the exact first-window contract, pool/preloader/serializer core changes, AssetRegistry integration, arbitrary AssetIds, owner-verification claims, Back/history, global animation, authoring/derived workflow, real cloud smoke, and unrelated cleanup.

### Scope Contract

- acceptance_ids: PRD-AC-002,PRD-AC-003,PRD-AC-006,PRD-AC-007,PRD-AC-008,PRD-AC-013,PRD-AC-016,PRD-AC-017,PRD-AC-018,PRD-AC-019,PRD-AC-020,PRD-AC-039,PRD-AC-049,PRD-AC-051,PRD-AC-053,PRD-AC-054,PRD-AC-056,PRD-AC-057,PRD-AC-058,PRD-AC-059,PRD-AC-061,PRD-AC-062,PRD-AC-063,PRD-AC-064,PRD-AC-067,PRD-AC-075,PRD-AC-076,PRD-AC-077,PRD-AC-084,PRD-AC-094,PRD-AC-100,PRD-AC-101,PRD-AC-103
- editable_paths: src/ReplicatedStorage/Client/UI/**,src/ReplicatedStorage/Client/Initialization/ClientManifest.luau,src/ServerScriptService/Tests/UiSystemTestRunner.luau,docs/UiSystem.md,docs/TestCoverage.md
- shared_touchpoints: TP-007,TP-008
- shared_touchpoint: TP-007 | path=src/ReplicatedStorage/Client/Initialization/ClientManifest.luau | symbols=UiSystem construction block,services.UI | allowed_change=inject AssetService,ContentPreloader,Pooling,Players,GuiService,clock/scheduler/logger dependencies required by the frozen specification | forbidden_change=external subsystem APIs,unrelated command order,service locator
- shared_touchpoint: TP-008 | path=docs/TestCoverage.md | symbols=UI System matrix rows | allowed_change=add first-window and static-type coverage | forbidden_change=existing suite semantics
- excluded_components: pool-core,content-preloader-core,asset-registry,players-wrapper,communication-transport,multi-window-navigation,authoring-workflow,canonical-scene
- excluded_paths: src/ReplicatedStorage/Shared/Pooling/**,src/ReplicatedStorage/Shared/ContentPreloading/**,src/ReplicatedStorage/Shared/Assets/**,src/ReplicatedStorage/Client/Players/**,src/ReplicatedStorage/Client/Communication/**,src/ReplicatedStorage/Project/**,src/ReplicatedFirst/**,src/ServerScriptService/Modules/**,place.rbxl,default.project.json
- max_product_files: 20
- max_product_lines_changed: 5200
- verification_scope: TS-STATIC-001; TS-TEST-002,TS-TEST-003,TS-TEST-006,TS-TEST-007,TS-TEST-009,TS-TEST-010,TS-TEST-011; focused UI plus unchanged Pool,Preloader,Asset,System suites and aggregate

### Research Briefs

- research_not_required | reason=Approved specification §§4.3–4.5, 5, 7.3–7.4, 8.1 and TS-TEST-002/003/006/007/009/010/011 fully define exact APIs, state, deadlines, retry, cleanup, and protected external contracts; repository APIs were inspected directly.

### Coverage Contract

- acceptance_ids: PRD-AC-002,PRD-AC-003,PRD-AC-006,PRD-AC-007,PRD-AC-008,PRD-AC-013,PRD-AC-016,PRD-AC-017,PRD-AC-018,PRD-AC-019,PRD-AC-020,PRD-AC-039,PRD-AC-049,PRD-AC-051,PRD-AC-053,PRD-AC-054,PRD-AC-056,PRD-AC-057,PRD-AC-058,PRD-AC-059,PRD-AC-061,PRD-AC-062,PRD-AC-063,PRD-AC-064,PRD-AC-067,PRD-AC-075,PRD-AC-076,PRD-AC-077,PRD-AC-084,PRD-AC-094,PRD-AC-100,PRD-AC-101,PRD-AC-103
- automated_identity_namespace: AUTO-TF0010-SLICE-002-*
- manual_identity_namespace: MANUAL-TF0010-SLICE-002-*
- mandatory_identity_ids: AUTO-TF0010-TS-STATIC-001,AUTO-TF0010-TS-TEST-002,AUTO-TF0010-TS-TEST-003,AUTO-TF0010-TS-TEST-006,AUTO-TF0010-TS-TEST-007,AUTO-TF0010-TS-TEST-009,AUTO-TF0010-TS-TEST-010,AUTO-TF0010-TS-TEST-011
- automation_feasibility: deterministic with injected asset/preloader/clock/scheduler/GuiService fakes; real cloud is excluded; typed negative fixtures require Script Analysis
- capability_prerequisites: powershell-5-1,rojo-build,rojo-server-preflight,studio-script-analysis,studio-server-test-runner
- planned_manifest: tests/ui-system/verification/SLICE-002-coverage-planned.json
- finalized_manifest: tests/ui-system/verification/SLICE-002-coverage-finalized.json
- amendment_authorities: active DEC-*,normalized finding IDs,controller-approved scope rebaseline only

### Documentation Contract

- normative_pre_review_paths: docs/UiSystem.md,docs/TestCoverage.md
- derived_post_qa_paths: not_required | policy=docs/Features/template/ui-system/technical-specification.md:4.7
- decision_ids: none
- evidence_sources: sealed SLICE-001 handoff,TS-STATIC-001 raw diagnostics,TS-TEST-002,TS-TEST-003,TS-TEST-006,TS-TEST-007,TS-TEST-009,TS-TEST-010,TS-TEST-011,Review finding IDs,QA evidence IDs

### Context Capsule Budget

- max_authority_files: 20
- max_evidence_files: 24
- max_total_files: 44
- max_payload_bytes: 430000
- max_estimated_tokens: 107500
- metric_scope: capsule_plus_referenced_files
- authority_paths: docs/Features/template/ui-system/product-requirements.md,docs/Features/template/ui-system/technical-specification.md,.agents/rules/architecture.md,.agents/rules/initialization.md,.agents/rules/testing.md,.agents/rules/assets.md,.agents/rules/content-preloading.md,.agents/rules/resource-management.md,.agents/rules/rojo-project.md,docs/AssetRegistry.md,docs/ContentPreloading.md,docs/ResourceManagement.md
- evidence_paths: src/ReplicatedStorage/Client/UI/**,src/ReplicatedStorage/Client/Initialization/ClientManifest.luau,src/ReplicatedStorage/Shared/Pooling/**,src/ReplicatedStorage/Shared/ContentPreloading/**,src/ReplicatedStorage/Shared/Communication/CommunicationSerialize.luau,src/ServerScriptService/Tests/UiSystemTestRunner.luau,src/ServerScriptService/Tests/TestHarness.luau,docs/UiSystem.md,docs/TestCoverage.md

### Verification and Exit Criteria

- Run preflight and focused UI tests.
- ResourceManagementTestRunner, ContentPreloaderTestRunner, AssetRegistryTestRunner, SystemTestRunner, and AllTestsRunner report failed = 0.
- TS-STATIC-001 produces zero positive-fixture diagnostics and exactly one argument-2 mismatch per negative fixture; all fixtures are removed and the ordinary tree has zero introduced diagnostics.
- Repository-layout and feature validators, git diff --check, and a temporary Rojo build pass.
- Shared Pool, ContentPreloader, and serializer implementations have no diff; the controller seals first-window coverage and the handoff.

### Rollback and Recovery

Restore the sealed SLICE-001 revision and remove only SLICE-002 additions/hunks. UiSystem destruction and pool removal invalidate active leases and cache; no persistence migration exists. Do not add discard APIs or recover through raw object references. Preserve unrelated changes.

### Downstream Consumers

- SLICE-003
- Concrete window authors and callers
- Existing PoolModule and ContentPreloader as unchanged dependencies
- Review and Coverage Steward

## Slice SLICE-003

### Vertical Outcome

End-to-end: yes
Observable result: Active Windows causally own add, close, and replacement; the stack applies HideBelow/KeepBelow, Pause/Resume, focus, tokens, lifecycle events, handles, one absolute deadline, failure recovery, and pooled quarantine with exact ordering and no intermediate lower-prefix mutations.

### Requirements

- PRD-REQ-017, PRD-REQ-018, PRD-REQ-019, PRD-REQ-020, PRD-REQ-021, PRD-REQ-022, PRD-REQ-027, PRD-REQ-034, PRD-REQ-035, PRD-REQ-064, PRD-REQ-065, PRD-REQ-066, PRD-REQ-081, PRD-REQ-082, PRD-REQ-083, PRD-REQ-084, PRD-REQ-085, PRD-REQ-086, PRD-REQ-103, PRD-REQ-104, PRD-REQ-105, PRD-REQ-106, PRD-REQ-156, PRD-REQ-163, PRD-REQ-164, PRD-REQ-165, PRD-REQ-167, PRD-REQ-172, PRD-REQ-173, PRD-REQ-174, PRD-REQ-175, PRD-REQ-176, PRD-REQ-177, PRD-REQ-180, PRD-REQ-181, PRD-REQ-182, PRD-REQ-183, PRD-REQ-184, PRD-REQ-185, PRD-REQ-186, PRD-REQ-187, PRD-REQ-188, PRD-REQ-189, PRD-REQ-190, PRD-REQ-191, PRD-REQ-192, PRD-REQ-193, PRD-REQ-194, PRD-REQ-195, PRD-REQ-197, PRD-REQ-198, PRD-REQ-199, PRD-REQ-200, PRD-REQ-203, PRD-REQ-204
- PRD-AC-004
- PRD-AC-005
- PRD-AC-015
- PRD-AC-022
- PRD-AC-023
- PRD-AC-030
- PRD-AC-060
- PRD-AC-065
- PRD-AC-066
- PRD-AC-069
- PRD-AC-070
- PRD-AC-071
- PRD-AC-072
- PRD-AC-073
- PRD-AC-074
- PRD-AC-078
- PRD-AC-079
- PRD-AC-080
- PRD-AC-081
- PRD-AC-082
- PRD-AC-083
- PRD-AC-085
- PRD-AC-086
- PRD-AC-087
- PRD-AC-088
- PRD-AC-089
- PRD-AC-090
- PRD-AC-091
- PRD-AC-092
- PRD-AC-093
- PRD-AC-095
- PRD-AC-096
- PRD-AC-097
- PRD-AC-098
- PRD-AC-099
- PRD-AC-102
- PRD-AC-104

### Dependencies

- SLICE-001
- SLICE-002

### Base Contract

The slice receives sealed root/event and first-window public contracts, static-type evidence, exact test/documentation/coverage state, active decisions none, and the controller result revision. Existing result, handle, and definition identities are immutable inputs.

### Handoff Contract

The controller-generated schema-2 handoff seals the complete runtime UI API/state machine, exact lifecycle order, final runtime test identities, changed paths/symbols, and the fields decision_ids, coverage_state, documentation_state, and open_assumptions. It is the sole runtime baseline for authoring and release work.

### Owned Paths

- src/ReplicatedStorage/Client/UI/WindowNavigator.luau
- src/ReplicatedStorage/Client/UI/WindowHandle.luau
- src/ReplicatedStorage/Client/UI/WindowInputBlocker.luau
- src/ReplicatedStorage/Client/UI/WindowNavigationRegistry.luau
- src/ReplicatedStorage/Client/UI/Elements/BaseUiElement.luau
- src/ReplicatedStorage/Client/UI/Windows/BaseWindowView.luau
- src/ReplicatedStorage/Client/UI/UiSystem.luau
- src/ServerScriptService/Tests/UiSystemTestRunner.luau
- docs/UiSystem.md

### Expected Paths

- src/ReplicatedStorage/Client/UI/**
- src/ReplicatedStorage/Shared/Pooling/**
- src/ReplicatedStorage/Shared/ContentPreloading/**
- src/ReplicatedStorage/Shared/Util/Signal.luau
- src/ServerScriptService/Tests/TestHarness.luau
- docs/TestCoverage.md

### Forbidden Scope

External subsystem changes, a global input interceptor, navigation fallback search, operation queues, Back/history, generic rollback, pool discard/new APIs, detached-hook mutation support, HUD/toast lifecycle, authoring/validator/cloud work, and unrelated refactors.

### Scope Contract

- acceptance_ids: PRD-AC-004,PRD-AC-005,PRD-AC-015,PRD-AC-022,PRD-AC-023,PRD-AC-030,PRD-AC-060,PRD-AC-065,PRD-AC-066,PRD-AC-069,PRD-AC-070,PRD-AC-071,PRD-AC-072,PRD-AC-073,PRD-AC-074,PRD-AC-078,PRD-AC-079,PRD-AC-080,PRD-AC-081,PRD-AC-082,PRD-AC-083,PRD-AC-085,PRD-AC-086,PRD-AC-087,PRD-AC-088,PRD-AC-089,PRD-AC-090,PRD-AC-091,PRD-AC-092,PRD-AC-093,PRD-AC-095,PRD-AC-096,PRD-AC-097,PRD-AC-098,PRD-AC-099,PRD-AC-102,PRD-AC-104
- editable_paths: src/ReplicatedStorage/Client/UI/WindowNavigator.luau,src/ReplicatedStorage/Client/UI/WindowHandle.luau,src/ReplicatedStorage/Client/UI/WindowInputBlocker.luau,src/ReplicatedStorage/Client/UI/WindowNavigationRegistry.luau,src/ReplicatedStorage/Client/UI/Elements/BaseUiElement.luau,src/ReplicatedStorage/Client/UI/Windows/BaseWindowView.luau,src/ReplicatedStorage/Client/UI/UiSystem.luau,src/ServerScriptService/Tests/UiSystemTestRunner.luau,docs/UiSystem.md,docs/TestCoverage.md
- shared_touchpoints: TP-009
- shared_touchpoint: TP-009 | path=docs/TestCoverage.md | symbols=UI System matrix rows,UI Studio/static release gate | allowed_change=complete multi-window and recovery coverage | forbidden_change=existing subsystem gates
- excluded_components: pool-core,content-preloader,signal,players,communication,asset-registry,authoring-workflow,server-runtime,canonical-scene
- excluded_paths: src/ReplicatedStorage/Shared/Pooling/**,src/ReplicatedStorage/Shared/ContentPreloading/**,src/ReplicatedStorage/Shared/Util/Signal.luau,src/ReplicatedStorage/Client/Players/**,src/ReplicatedStorage/Shared/Communication/**,src/ReplicatedStorage/Shared/Assets/**,src/ReplicatedStorage/Project/**,src/ReplicatedFirst/**,src/ServerScriptService/Modules/**,place.rbxl,default.project.json
- max_product_files: 10
- max_product_lines_changed: 5600
- verification_scope: TS-TEST-004,TS-TEST-005,TS-TEST-006,TS-TEST-007,TS-TEST-008,TS-TEST-009,TS-TEST-010,TS-TEST-011,TS-TEST-013; complete focused state-machine suite; aggregate regression

### Research Briefs

- research_not_required | reason=Approved specification §§4.4–4.6, 5.2, 7.2–7.4 and TS-TEST-004–011/013 define every authority, ordering, focus, deadline, quarantine, and recovery branch; the sealed SLICE-002 handoff supplies exact implementation identities.

### Coverage Contract

- acceptance_ids: PRD-AC-004,PRD-AC-005,PRD-AC-015,PRD-AC-022,PRD-AC-023,PRD-AC-030,PRD-AC-060,PRD-AC-065,PRD-AC-066,PRD-AC-069,PRD-AC-070,PRD-AC-071,PRD-AC-072,PRD-AC-073,PRD-AC-074,PRD-AC-078,PRD-AC-079,PRD-AC-080,PRD-AC-081,PRD-AC-082,PRD-AC-083,PRD-AC-085,PRD-AC-086,PRD-AC-087,PRD-AC-088,PRD-AC-089,PRD-AC-090,PRD-AC-091,PRD-AC-092,PRD-AC-093,PRD-AC-095,PRD-AC-096,PRD-AC-097,PRD-AC-098,PRD-AC-099,PRD-AC-102,PRD-AC-104
- automated_identity_namespace: AUTO-TF0010-SLICE-003-*
- manual_identity_namespace: MANUAL-TF0010-SLICE-003-*
- mandatory_identity_ids: AUTO-TF0010-TS-TEST-004,AUTO-TF0010-TS-TEST-005,AUTO-TF0010-TS-TEST-006,AUTO-TF0010-TS-TEST-007,AUTO-TF0010-TS-TEST-008,AUTO-TF0010-TS-TEST-009,AUTO-TF0010-TS-TEST-010,AUTO-TF0010-TS-TEST-011,AUTO-TF0010-TS-TEST-013
- automation_feasibility: all assigned acceptance is deterministic with injected clocks, schedulers, services, and representative partitions
- capability_prerequisites: powershell-5-1,rojo-build,rojo-server-preflight,studio-server-test-runner
- planned_manifest: tests/ui-system/verification/SLICE-003-coverage-planned.json
- finalized_manifest: tests/ui-system/verification/SLICE-003-coverage-finalized.json
- amendment_authorities: active DEC-*,normalized finding IDs,controller-approved scope rebaseline only

### Documentation Contract

- normative_pre_review_paths: docs/UiSystem.md,docs/TestCoverage.md
- derived_post_qa_paths: not_required | policy=docs/Features/template/ui-system/technical-specification.md:4.7
- decision_ids: none
- evidence_sources: sealed SLICE-001 and SLICE-002 handoffs,TS-TEST-004,TS-TEST-005,TS-TEST-006,TS-TEST-007,TS-TEST-008,TS-TEST-009,TS-TEST-010,TS-TEST-011,TS-TEST-013,Review finding IDs,QA evidence IDs

### Context Capsule Budget

- max_authority_files: 20
- max_evidence_files: 24
- max_total_files: 44
- max_payload_bytes: 450000
- max_estimated_tokens: 112500
- metric_scope: capsule_plus_referenced_files
- authority_paths: docs/Features/template/ui-system/product-requirements.md,docs/Features/template/ui-system/technical-specification.md,.agents/rules/architecture.md,.agents/rules/testing.md,.agents/rules/resource-management.md,.agents/rules/signals.md,.agents/rules/rojo-project.md,docs/ResourceManagement.md,docs/Signal.md
- evidence_paths: src/ReplicatedStorage/Client/UI/**,src/ReplicatedStorage/Shared/Pooling/**,src/ReplicatedStorage/Shared/ContentPreloading/**,src/ReplicatedStorage/Shared/Util/Signal.luau,src/ServerScriptService/Tests/UiSystemTestRunner.luau,src/ServerScriptService/Tests/TestHarness.luau,docs/UiSystem.md,docs/TestCoverage.md

### Verification and Exit Criteria

- Run preflight and the complete UiSystemTestRunner.
- ResourceManagementTestRunner, ContentPreloaderTestRunner, AssetRegistryTestRunner, SystemTestRunner, and AllTestsRunner report failed = 0.
- Deterministic assertions cover exact order, stale continuations, never-ending leases, active/paused authority, dynamic navigation transactions, and lifecycle identity diagnostics.
- Repository-layout and feature validators, git diff --check, and a temporary Rojo build pass.
- Protected external subsystems have no diff; coverage and the runtime handoff are sealed.

### Rollback and Recovery

Restore the sealed SLICE-002 first-window baseline. Runtime recovery follows the specified generation invalidation, reverse cleanup, quarantine, and existing lease destruction paths. Source rollback never invents a compatibility state and preserves unrelated changes.

### Downstream Consumers

- SLICE-004
- Active Window/domain callers
- Gamepad and pointer presentation
- Review, Documentation Finisher, Coverage Steward, and QA

## Slice SLICE-004

### Vertical Outcome

End-to-end: yes
Observable result: A template or initialized derived project can author one unambiguous data-only cloud window through the exact canonical definition/config paths, repository validation enforces derived ownership and merge preservation, and the completed UI system passes cleaned static analysis, deterministic production compiler/loader checks with a repository-owned local data-only fixture, the full Studio/device checklist, and a separate exact-place read-only AllowInsertFreeAssets gate; cloud smoke is conditional and non-gating without an already approved external fixture.

### Requirements

- PRD-REQ-009, PRD-REQ-037, PRD-REQ-061, PRD-REQ-062, PRD-REQ-063, PRD-REQ-099, PRD-REQ-100, PRD-REQ-123, PRD-REQ-146, PRD-REQ-147, PRD-REQ-148, PRD-REQ-149, PRD-REQ-158
- PRD-AC-014
- PRD-AC-028
- PRD-AC-036
- PRD-AC-055

### Dependencies

- SLICE-001
- SLICE-002
- SLICE-003

### Base Contract

The slice receives the sealed complete runtime API/state machine, static and focused coverage, accepted ADR/rule baseline, exact source authorities, active decisions none, and the controller result revision. It may document and validate only the already approved authoring boundary.

### Handoff Contract

The controller-generated schema-2 final handoff includes exact implementation/documentation revisions, raw static diagnostics and cleanup, repository/suite/local-fixture/Studio/device/read-only setting evidence, the truthful conditional cloud-smoke disposition, decision_ids, complete coverage_state, documentation_state, and open_assumptions. It is consumable by Review, QA, and feature completion; workers do not hand-author controller mechanics.

### Owned Paths

- .agents/templates/window-authoring/WindowTemplate.model.json
- .agents/skills/window-authoring/SKILL.md
- .agents/skills/project-initialize/SKILL.md
- .agents/skills/project-initialize/agents/openai.yaml
- .agents/rules/project-initialization.md
- .agents/rules/template-updates.md
- scripts/validate-repository-layout.ps1
- src/ReplicatedStorage/Client/UI/TestFixtures/WindowAssetFixture.model.json
- src/ReplicatedStorage/Client/UI/Config/Definitions/WindowAssetFixtureDefinition.luau
- src/ReplicatedStorage/Client/UI/TestFixtures/WindowAssetFixturePlaySetup.luau
- src/ReplicatedStorage/Client/UI/TestFixtures/StaticAnalysis/TypedNavigationPositiveFixture.luau
- src/ReplicatedStorage/Client/UI/TestFixtures/StaticAnalysis/TypedNavigationAddNegativeFixture.luau
- src/ReplicatedStorage/Client/UI/TestFixtures/StaticAnalysis/TypedNavigationReplacementNegativeFixture.luau
- src/ServerScriptService/Tests/UiSystemTestRunner.luau
- docs/UiSystem.md
- docs/TestCoverage.md
- docs/Features/template/ui-system/handoff.md
- docs/Features/template/ui-system/worklog.md
- README.md

### Expected Paths

- .agents/rules/ui.md
- .agents/rules/index.md
- src/ReplicatedStorage/Client/UI/Config/TemplateWindowConfig.luau
- src/ReplicatedStorage/Client/UI/Config/Definitions/**
- src/ReplicatedStorage/Client/UI/Config/WindowConfigCompiler.luau
- src/ReplicatedStorage/Client/UI/WindowAssetLoader.luau
- src/ReplicatedStorage/Client/UI/**
- src/StarterPlayerScripts/Bootstrap.client.luau
- src/ReplicatedStorage/Shared/Initialization/InitializationRunner.luau
- src/ServerScriptService/Tests/TestHarness.luau
- src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau
- docs/adr/template/0045-client-ui-system-boundaries.md
- docs/InitializationAndSaveSystem.md
- docs/TestCoverage.md
- default.project.json
- selected canonical Studio identity and read-only Experience-setting evidence

### Forbidden Scope

Creating src/ReplicatedStorage/Project/** in the template, creating empty optional action configuration, alternate registries/manifests/loaders/bridges, production config/compiler/loader/manifest/bootstrap/InitializationRunner changes, runtime semantic changes after code freeze, AssetId requests, cloud asset creation or unapproved load evidence, publish/deploy, place-identity or Experience-setting mutation, attaching elsewhere, place.rbxl changes, enabling third-party assets, cloud owner-verification claims, feature lifecycle transitions, unrelated skills/rules/ADRs, and destructive external cleanup.

### Scope Contract

- acceptance_ids: PRD-AC-014,PRD-AC-028,PRD-AC-036,PRD-AC-055
- editable_paths: .agents/templates/window-authoring/WindowTemplate.model.json,.agents/skills/window-authoring/SKILL.md,.agents/skills/project-initialize/SKILL.md,.agents/skills/project-initialize/agents/openai.yaml,.agents/rules/ui.md,.agents/rules/index.md,.agents/rules/project-initialization.md,.agents/rules/template-updates.md,scripts/validate-repository-layout.ps1,src/ReplicatedStorage/Client/UI/TestFixtures/WindowAssetFixture.model.json,src/ReplicatedStorage/Client/UI/Config/Definitions/WindowAssetFixtureDefinition.luau,src/ReplicatedStorage/Client/UI/TestFixtures/WindowAssetFixturePlaySetup.luau,src/ReplicatedStorage/Client/UI/TestFixtures/StaticAnalysis/TypedNavigationPositiveFixture.luau,src/ReplicatedStorage/Client/UI/TestFixtures/StaticAnalysis/TypedNavigationAddNegativeFixture.luau,src/ReplicatedStorage/Client/UI/TestFixtures/StaticAnalysis/TypedNavigationReplacementNegativeFixture.luau,src/ServerScriptService/Tests/UiSystemTestRunner.luau,docs/adr/template/0045-client-ui-system-boundaries.md,docs/adr/template/README.md,docs/UiSystem.md,docs/InitializationAndSaveSystem.md,docs/TestCoverage.md,docs/Features/template/ui-system/handoff.md,docs/Features/template/ui-system/worklog.md,README.md
- shared_touchpoints: TP-010,TP-011,TP-012,TP-013,TP-014,TP-015,TP-016,TP-017,TP-018
- shared_touchpoint: TP-010 | path=scripts/validate-repository-layout.ps1 | symbols=repository-role branch,derived UI config validation | allowed_change=add exact UTF-8 strict DerivedWindowConfig presence/absence and reserved namespace checks | forbidden_change=runtime marker,alternate path,unrelated validator behavior
- shared_touchpoint: TP-011 | path=.agents/rules/project-initialization.md | symbols=Mandatory initialization,Required verification | allowed_change=add exact derived UI config creation,validation,and evidence step | forbidden_change=cloud identity,save,Wallet,feature namespace semantics
- shared_touchpoint: TP-012 | path=.agents/rules/template-updates.md | symbols=Merge policy text source/scripts/rules | allowed_change=preserve exact project-owned DerivedWindowConfig and stop on reserved upstream namespace | forbidden_change=place,default.project,ADR ownership semantics
- shared_touchpoint: TP-013 | path=.agents/rules/index.md | symbols=UI trigger route | allowed_change=final exact UI routing | forbidden_change=unrelated subsystem routes
- shared_touchpoint: TP-014 | path=docs/adr/template/README.md | symbols=ADR-0045 row | allowed_change=finalize exact decision title,link,and status | forbidden_change=other ADR history
- shared_touchpoint: TP-015 | path=README.md | symbols=Included systems,Out of scope,Architecture,Repository structure,Tests | allowed_change=replace obsolete no-UI statement and link exact UI authoring and test workflow | forbidden_change=unrelated product claims
- shared_touchpoint: TP-016 | path=docs/TestCoverage.md | symbols=UI System matrix,AllTestsRunner order,static and Studio/local-fixture/read-only setting release gates | allowed_change=replace overstated cloud claims with exact raw static cleanup,full TS-TEST-012,local TS-TEST-016,and conditional cloud-smoke evidence | forbidden_change=existing subsystem gates,unverified success claims
- shared_touchpoint: TP-017 | path=docs/Features/template/ui-system/handoff.md | symbols=verification summary,current state,next step | allowed_change=correct only overstated release-evidence claims from exact observed results | forbidden_change=feature lifecycle state,controller authority,unverified success claims
- shared_touchpoint: TP-018 | path=docs/Features/template/ui-system/worklog.md | symbols=existing UI System evidence entries | allowed_change=correct only overstated release-evidence claims and append exact in-scope factual evidence | forbidden_change=feature lifecycle transition,history deletion,controller authority,unverified success claims
- excluded_components: project-runtime-namespace,optional-derived-actions,cloud-identity,canonical-scene,external-subsystem-rules,unrelated-skills
- excluded_paths: src/ReplicatedStorage/Project/**,src/ReplicatedStorage/Shared/Pooling/**,src/ReplicatedStorage/Shared/ContentPreloading/**,src/ReplicatedStorage/Shared/Assets/**,src/ReplicatedStorage/Shared/Communication/**,src/ReplicatedStorage/Client/Players/**,src/ReplicatedStorage/Client/Audio/**,src/ServerScriptService/Modules/**,place.rbxl,default.project.json
- max_product_files: 18
- max_product_lines_changed: 2600
- verification_scope: TS-TEST-001,TS-TEST-011,TS-TEST-012,TS-TEST-014,TS-TEST-015,TS-TEST-016; TS-STATIC-001 raw diagnostics plus deletion of all three exact temporary fixtures and zero-diagnostic ordinary-tree reanalysis; full suites; repository,feature,and Rojo gates; mandatory exact selected-place read-only AllowInsertFreeAssets=false evidence; conditional non-gating cloud smoke only with an already approved external fixture

### Research Briefs

- research_not_required | reason=Approved specification revision 9 §§4.7, 8.2, 8.3, 10, 12.1 and TS-STATIC-001/TS-TEST-012/014/016 define the exact local fixture model,definition,Play setup,temporary static fixtures,production compiler/loader route,cleanup,read-only setting gate,and conditional cloud smoke; the accepted Analyst packet fixes the write and read-only paths without a new product decision.

### Coverage Contract

- acceptance_ids: PRD-AC-014,PRD-AC-028,PRD-AC-036,PRD-AC-055
- automated_identity_namespace: AUTO-TF0010-SLICE-004-*
- manual_identity_namespace: MANUAL-TF0010-SLICE-004-*
- mandatory_identity_ids: AUTO-TF0010-TS-TEST-001,AUTO-TF0010-TS-TEST-011,AUTO-TF0010-TS-TEST-014,AUTO-TF0010-TS-TEST-015,AUTO-TF0010-TS-TEST-016,MANUAL-TF0010-TS-TEST-012,MANUAL-TF0010-TS-EVIDENCE-ALLOWINSERT-001
- automation_feasibility: template/derived validation, source scanning, static fixtures, checked-in data-only local fixture, exact definition identity, canonical compile, production WindowAssetLoader behavior, preload, cache, clone separation, rejection, and cleanup are automated; the full local Play/device checklist and exact-place AllowInsertFreeAssets=false observation are manual; cloud smoke is optional and non-gating unless an external fixture was already approved
- capability_prerequisites: experience-settings-access,gamepad-input,powershell-5-1,published-template-validation-place,roblox-studio-canonical-session,rojo-build,rojo-server-preflight,studio-device-emulation,studio-play-mode,studio-script-analysis,studio-server-test-runner
- planned_manifest: tests/ui-system/verification/SLICE-004-coverage-planned.json
- finalized_manifest: tests/ui-system/verification/SLICE-004-coverage-finalized.json
- amendment_authorities: active DEC-*,normalized finding IDs,controller-approved scope rebaseline only

### Documentation Contract

- normative_pre_review_paths: .agents/templates/window-authoring/WindowTemplate.model.json,.agents/skills/window-authoring/SKILL.md,.agents/skills/project-initialize/SKILL.md,.agents/skills/project-initialize/agents/openai.yaml,.agents/rules/ui.md,.agents/rules/index.md,.agents/rules/project-initialization.md,.agents/rules/template-updates.md,docs/adr/template/0045-client-ui-system-boundaries.md,docs/adr/template/README.md,docs/UiSystem.md,docs/InitializationAndSaveSystem.md,docs/TestCoverage.md,docs/Features/template/ui-system/handoff.md,docs/Features/template/ui-system/worklog.md,README.md
- derived_post_qa_paths: not_required | policy=docs/Features/template/ui-system/technical-specification.md:4.7
- decision_ids: none
- evidence_sources: sealed SLICE-001,SLICE-002,and SLICE-003 handoffs,docs/Features/template/ui-system/handoff.md,docs/Features/template/ui-system/worklog.md,docs/TestCoverage.md,TS-STATIC-001 raw diagnostics and three-fixture cleanup proof,TS-TEST-001,TS-TEST-011,full TS-TEST-012,TS-TEST-014,TS-TEST-015,local-fixture TS-TEST-016,selected PlaceId and GameId,TS-EVIDENCE-ALLOWINSERT-001,conditional TS-SMOKE-CLOUD-001 disposition,Review finding IDs,QA evidence IDs

### Context Capsule Budget

- max_authority_files: 22
- max_evidence_files: 24
- max_total_files: 46
- max_payload_bytes: 460000
- max_estimated_tokens: 115000
- metric_scope: capsule_plus_referenced_files
- authority_paths: docs/Features/template/ui-system/product-requirements.md,docs/Features/template/ui-system/technical-specification.md,.agents/rules/architecture.md,.agents/rules/architecture-decisions.md,.agents/rules/testing.md,.agents/rules/rojo-project.md,.agents/rules/project-initialization.md,.agents/rules/template-updates.md,.agents/rules/feature-workflow.md,docs/adr/README.md,docs/adr/template/README.md
- evidence_paths: .agents/templates/window-authoring/**,.agents/skills/window-authoring/**,.agents/skills/project-initialize/**,.agents/rules/ui.md,.agents/rules/index.md,scripts/validate-repository-layout.ps1,src/ReplicatedStorage/Client/UI/**,src/StarterPlayerScripts/Bootstrap.client.luau,src/ReplicatedStorage/Shared/Initialization/InitializationRunner.luau,src/ServerScriptService/Tests/UiSystemTestRunner.luau,src/ServerScriptService/Tests/TestHarness.luau,docs/UiSystem.md,docs/InitializationAndSaveSystem.md,docs/TestCoverage.md,docs/Features/template/ui-system/handoff.md,docs/Features/template/ui-system/worklog.md,README.md,default.project.json

### Verification and Exit Criteria

- Run the mandatory preflight before source edits and again before Studio.
- Exact template and derived-layout fixtures pass scripts/validate-repository-layout.ps1; feature validators, dashboard checks, and git diff --check pass.
- TS-STATIC-001 records analyzer/version, each exact fixture path/hash/marked line and raw diagnostics; all three temporary fixtures are deleted even on failure, ordinary-tree reanalysis has zero introduced diagnostics, and git status/diff proves cleanup.
- Focused UI, ResourceManagement, AssetRegistry, ContentPreloader, System, and AllTestsRunner report failed = 0; the temporary Rojo build succeeds.
- Reuse and explicitly select the matching canonical Studio instance. Full TS-TEST-012 invokes `WindowAssetFixturePlaySetup.start()` only through the existing client-execution boundary and records ordinary bootstrap/root/hosts/respawn, exact local definition/compiler/production-loader counters and distinct clones, isolated open/close/background/blocker/pointer/gamepad/safe-area behavior, mandatory `Finish()` cleanup, and clean server/client output without replacing production services.
- Local-fixture TS-TEST-016 direct-requires the exact checked-in definition, compiles its sole TemplateWindowConfig-shaped sequence, passes the exact frozen definition to production WindowAssetLoader through the injected clone-only backend, and verifies data-only rejection, preload, cache, clone separation, and cleanup without network or an external asset.
- The exact selected published template place records nonzero matching PlaceId/GameId plus mandatory read-only `AllowInsertFreeAssets=false`, UTC and reviewer without AssetId/load/save/publish/setting mutation. Cloud smoke is run only with a separately already approved external fixture; otherwise exact `not run: no approved external fixture/AssetId` is truthful and non-gating.
- No temporary Script Analysis fixture, fixture descendant/focus state, project namespace, scene, identity, controller, or lifecycle drift remains. Handoff, worklog, normative documentation and final TestCoverage contain only verified claims before Review.

### Rollback and Recovery

Source rollback removes only authoring, rule, validator, local-fixture/test, and documentation additions and restores the sealed SLICE-003 runtime. The three exact Script Analysis fixtures are temporary and must be removed even on failure; the checked-in local fixture model/definition/Play setup are persistent release inputs. Do not request/delete cloud assets, run unapproved cloud loads, publish, deploy, attach, alter identity or settings, or transition feature lifecycle. Preserve unrelated work and correct evidence records truthfully rather than deleting history.

### Downstream Consumers

- Final Review and QA
- Feature completion workflow
- Template window authors
- Derived-project initialization and future upstream merges
- Future project HUD/toast owners and analytics subscribers

## Acceptance Set Audit

- SLICE-001: 17 acceptance IDs
- SLICE-002: 33 acceptance IDs
- SLICE-003: 37 acceptance IDs
- SLICE-004: 4 acceptance IDs
- total_memberships: 91
- unique_approved_ids: 91
- missing_ids: none
- extra_ids: none
- overlap: none

The PRD requirement membership union covers all 175 approved functional IDs. Intentional requirement overlap is limited to PRD-REQ-009, PRD-REQ-037, PRD-REQ-146, PRD-REQ-147, PRD-REQ-148, PRD-REQ-149, and PRD-REQ-158; acceptance sets do not overlap.
