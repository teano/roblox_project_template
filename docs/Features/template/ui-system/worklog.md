# Feature worklog

## 2026-08-18T20:46:16.0225611+00:00 — paused

- Feature: TF-0010
- Head: e98557f334625e70e6984f2cde85eb3c9c3c3708

### Result and current state

Requirements gathering for TF-0010 UI System is checkpointed. The draft product-requirements.md was reduced to confirmed UI-system decisions and currently contains no open-question section. No Roblox source implementation has started. Feature workflow artifacts and the requirements document remain uncommitted. Blockers/current state: the requirements document is still draft and has not been formally approved; technical specification, architecture work, implementation, and implementation verification remain pending.

### Important decisions and discussions

Confirmed decisions: one client UiRoot implemented as one ScreenGui containing HudHost, ToastHost, and WindowHost in that visual order; ReplicatedFirst loading UI remains separate. UiSystem coordinates HUD, window, and toast subsystems, each owning its host content; only windows use a stack. WindowHost starts empty and windows are created dynamically from a central typed config registry and one canonical starter; one repo-local skill documents authoring. WindowId is the single canonical window/template identity; only one active instance is allowed, duplicate open is a developer error, and only the top stack window can close. Each window explicitly selects Destroy or Pool lifecycle, HideBelow or KeepBelow visibility, Background behavior, and independent Back behavior. Stack visibility is recomputed from current state, using the highest HideBelow as the visible suffix boundary. Window open is atomic and returns a typed error on failure. Windows have mandatory BlockObject and optional Background; block state uses independent tokens, all user input including Back is ignored while blocked, and Clear/close invalidates tokens safely. Recursive synchronous idempotent Clear owns view cleanup and is the sole pooled-view reset contract; WindowSubsystem owns destroy/pool release. All UI controllers inherit BaseUiElement; BaseWindowView enriches bubbled events with WindowId. NestedUiElements support initialization-time and runtime add/remove, recursive Clear, and event bubbling to UiRoot. WindowId and globally unique UIElementId remain distinct; runtime repeated elements use one stable composite UIElementId; duplicate final IDs fail initialization atomically. UINavigationEnabled separately opts into navigation; default links are automatic with explicit window overrides, and focus restores to the last available element or a required default. The initial controller set covers Frame, text, image, buttons, TextBox, forms, and scrolling containers. The shared UIActionId catalog uses ui.* for template IDs and game.* for project IDs and also identifies window lifecycle events published by WindowSubsystem into the same UiRoot stream. Base actions are pointer enter/exit, button activation, TextBox focus/unfocus/confirm, and form submit/cancel; high-frequency raw signals and TextBox contents do not bubble. Event delivery is synchronous, ordered, non-yielding, subscriber-error isolated, and FIFO for nested emissions, with a project-configurable chain limit and template default. Payload is one generic serializable mutable table interpreted by UIActionId; handlers may update declared values or fill declared optional fields for downstream handlers but may not change the declared field/type structure. Toasts continue their timers while windows are open but accept no input while the window stack is nonempty. Future analytics implementation remains out of scope and can subscribe once at UiRoot.

### Verification state

Known verification before Pause: documentation formatting was checked repeatedly with git diff --check and the latest run passed; requirement, acceptance-criterion, and open-question identifier uniqueness/count checks passed after the latest edits. No source code was changed. Rojo preflight/build, Studio operations, automated test suites, feature-workflow validators, repository-layout validation, and dashboard check were not run because this checkpoint covers unfinished documentation-only requirements work. No additional verification was performed as part of Pause.

### Blockers

- Product requirements are missing.
- Technical specification is missing.

### Next step

After an explicit $feature-continue request, review and formally approve the draft product requirements, then derive the technical specification and architecture plan before beginning source implementation.

## 2026-08-21T07:20:10.5823946+00:00 — paused

- Feature: TF-0010
- Head: e98557f334625e70e6984f2cde85eb3c9c3c3708

### Result and current state

TF-0010 UI System requirements work is complete and paused before technical specification. Product requirements revision 2 are explicitly approved at SHA-256 00cb15f2555555bc37ecf7e4406576faee5ddb84c9cd74567b02a70be78b076a. No technical specification or Roblox source implementation exists. Five completed TF-0008 controller-state artifacts were recoverably moved from the live .agentic-pipeline namespace into .agentic-pipeline/archive/tf0008-completed-ready-a7e7cc20 without changing pipeline code or skills.

### Important decisions and discussions

UiRoot is one player-lifecycle ScreenGui with ResetOnSpawn false and HudHost, ToastHost, WindowHost; respawn does not reset UI. Derived systems own HUD and toast content; no universal HUD registry or toast queue. WindowNavigator owns one Active top window, Paused lower windows, explicit Add/Close/replacement stack operations, no Back history, final-only visibility recalculation, optional per-window Open/Close hooks, and a three-second operation deadline. Timed-out pooled views retain their active generation lease in quarantine until the hook finishes, then use UI Clear and normal Release; a never-ending hook keeps the lease unavailable. BlockObjectRef never affects initialization and tokens are inert without a suitable referenced input sink. TemplateWindowConfig and project-initialization-created project-owned DerivedWindowConfig merge into one frozen WindowConfig. Definitions bind allowlisted data-only cloud prefab AssetIds, repo-owned Rojo-synchronized view factories and runtime type witnesses; AllowInsertFreeAssets remains false and runtime owner verification is not claimed. Pooled definitions provide existing MaxActive and MaxRetained PoolOptions with no PoolModule, pool API, adapter, or pool-Clear changes. Preload true performs a bounded eager attempt whose failure does not fail UiSystem initialization; later Open retries. UI events bubble child-to-parent and publish through the repository Signal contract. Rejected alternatives include universal HUD lifecycle, toast FIFO, Back history, cloud executable code, global window animation policy, generic side-effect rollback, and new pool discard behavior.

### Verification state

Approved requirements validator passed with valid=true, revision 2, zero errors and warnings, exact SHA-256 00cb15f2555555bc37ecf7e4406576faee5ddb84c9cd74567b02a70be78b076a. Feature workflow validation, synchronized dashboard check, repository layout validation, and git diff --check passed after approval. Independent requirements and Roblox feasibility audits found no product-decision blocker and no required PoolModule change. No source code changed, so Rojo preflight/build, Studio operations, and Roblox test suites were not run.

### Blockers

- Technical specification is missing.

### Next step

Invoke $gamedev-specification using approved PRD revision 2 and its exact SHA. The specification must define module and API layout, quarantine presentation and cleanup ownership, destroy-policy timeout behavior, UI Clear failure containment, ContentPreloader retry identities and late-result disposal, DerivedWindowConfig exact path and merge enforcement, BlockObjectRef value tracking, AllowInsertFreeAssets deployment verification, and the complete test matrix.

## 2026-08-21T17:09:59.6521174+00:00 — paused

- Feature: TF-0010
- Head: e98557f334625e70e6984f2cde85eb3c9c3c3708

### Result and current state

Approved PRD revision 3 and approved UI System technical specification revision 8 are bound in SPEC_READY with exact trace coverage of 175/175 requirements, 6/6 non-functional requirements, and 91/91 acceptance criteria. A fresh independent proofread passed with zero Critical, Major, or Minor findings and zero questions. Specification work is complete; source implementation, runtime pipeline, Roblox Studio, and Development Plan have not started. The feature remains unfinished at the specification checkpoint. Blockers: none for specification readiness.

### Important decisions and discussions

PRD revision 3 is the sole authority; the previous unfinished wave and its findings are superseded. Keep the design minimal, reuse existing APIs, do not change neighboring systems, and do not expand scope. Typed callers and config require the same canonical per-window definition table; no second registry, config, wrapper, or copy is allowed. Static type evidence uses available project or Studio Script Analysis without new dependencies. Synchronous hooks use one private stateless non-yield guard with a single resume and coroutine.close, without a scheduler, service, or timeout API. No runtime repository-kind detector or config mutation API is introduced.

### Verification state

PRD validator passed for approved revision 3 with zero errors and warnings. Exact trace set equality passed: 175/175 PRD-REQ, 6/6 PRD-NFR, 91/91 PRD-AC; inventory is 20 TS-REQ, 16 TS-TEST, and 1 TS-STATIC. Fresh independent proofread passed with coverage complete, 0/0/0 findings, and zero questions. The specification controller reached SPEC_READY. Source tests, Rojo preflight and build, Roblox Studio, runtime or deployment checks, and Development Plan were not run because implementation has not begun and they were outside the authorized scope.

### Blockers

- Technical specification is missing.

### Next step

After an explicit feature-continue, start the GameDev Development Plan from approved PRD revision 3 and technical specification revision 8. Do not implement source or use Roblox Studio without separate authorization.

## 2026-08-21T19:50:21.4544216+00:00 — paused

- Feature: TF-0010
- Head: e98557f334625e70e6984f2cde85eb3c9c3c3708

### Result and current state

PRD revision 3 and technical specification revision 8 are approved. Development plan revision 1 was created, controller-validated, submitted, and explicitly approved. PLAN_READY is yes with approved SHA e0f2995673eb2e34a4696d16eb24cd7ba15712efd6d2f33ff363007c1a62c317. The plan defines four sequential end-to-end slices with exact 91 of 91 acceptance coverage. Source implementation, runtime pipeline initialization, and Studio work have not started. Known uncommitted state includes the created and approved docs/Features/template/ui-system/development-plan.md, the created or updated .agentic-pipeline/development-plan-state.json, and the earlier Continue lifecycle and dashboard updates; the full Git inventory was not inspected for Pause. The recorded manifest blocker Technical specification is missing is stale and conflicts with the approved specification and PLAN_READY state.

### Important decisions and discussions

Use sequential_slices with one writer at a time and phase-scoped write leases. Order is persistent root and semantic events, one safe configured window, multi-window deterministic recovery, then authoring and exact release evidence. Layer-only and parallel component decompositions were rejected because runtime, tests, navigation, view, manifest, and documentation touchpoints are inseparable. Existing Pool, ContentPreloader, Players, Signal, serializer, AssetRegistry, Audio, Teleport, save, domain, place, and cloud identity boundaries remain unchanged. Active planning decision IDs are none. The exact approved plan SHA is e0f2995673eb2e34a4696d16eb24cd7ba15712efd6d2f33ff363007c1a62c317. No other important decisions remain unrecorded.

### Verification state

The complete approved Requirements validator and schema-2 SPEC_READY authority gate passed during planning initialization. The development-plan controller validate-plan command passed with four ordered slices and exact 91 of 91 acceptance coverage. Submit and approve revalidated current PRD, specification, and plan bytes. Feature implementation tests, repository-layout and feature validators, git diff check, Rojo preflight or build, Studio Script Analysis or Play, and cloud checks were not run because implementation has not started. No new checks were performed for Pause.

### Blockers

- Technical specification is missing.

### Next step

After a separate explicit feature-continue, invoke $gamedev-pipeline against the approved PLAN_READY UI System plan; reconcile the stale manifest blocker before the first engineering lease if the owning workflow requires it.

## 2026-08-24T18:23:09.9311996+00:00 — implementation and documentation checkpoint

- Feature: TF-0010
- Head: e98557f334625e70e6984f2cde85eb3c9c3c3708
- Lifecycle transition: none; remains in_progress / active

### Result and current state

The approved four-slice UI System candidate is implemented and synchronized with its supporting documentation. It provides the persistent client UI root and semantic event foundation, configured window loading and lifecycle reuse, deterministic multi-window navigation and recovery, and data-only authoring plus exact derived-project ownership enforcement. All four slices completed independent Review and QA with PASS. The feature is not marked ready or finished by this checkpoint because the user has not invoked `$feature-finish`.

### Important decisions and discussions

The final candidate retains the approved ownership boundaries in ADR-0045 and introduces no new product decision. `WindowNavigator` exclusively owns applied window lifecycle confirmations; reusable element controllers remain independent of `WindowId`; HUD and toast content remain project-owned. The existing PoolModule, ContentPreloader, PlayersModule, Signal, serializer, initialization, save, communication, place, and cloud-identity contracts were preserved. DEC-001 remains the accepted authorization for one minimal data-only cloud asset, but no cloud asset creation, upload, publish, deployment, attachment, or Experience-setting mutation occurred in this run.

### Verification state

Final Review and QA passed independently for SLICE-001, SLICE-002, SLICE-003, and SLICE-004. The latest focused `UiSystemTestRunner` completed with 15 passed and 0 failed in a fresh Play session; its only listener error was the expected and asserted isolation fixture. The selected Studio session reported canonical PlaceId `91045933836846` and GameId `10596427617`, matched `default.project.json`, exposed exactly one persistent root with all three hosts, and returned to Edit mode. Controller-owned repository-layout validation, feature-workflow validation, and temporary Rojo build passed. This documentation checkpoint ran no new test or verification command.

### Blockers

None.

### Next step

Complete the pipeline's documentation artifact and fresh post-documentation Review/QA. A later explicit `$feature-finish` request owns the feature state transition.

## 2026-08-25T05:33:26.033Z — SLICE-004 local release-evidence Engineering checkpoint

- Feature: TF-0010
- Head: e98557f334625e70e6984f2cde85eb3c9c3c3708
- Lifecycle transition: none; remains in_progress / active

### Result and current state

Specification revision 9 and Development Plan revision 3 replace the mandatory cloud-positive release fixture with one deterministic repository-owned data-only fixture while retaining the production cloud/AssetId capability. Engineering added the exact checked-in model, fixed definition, test-only Play setup, and executable TS-TEST-016 coverage through production `WindowConfigCompiler` and `WindowAssetLoader`. No production manifest/config/loader/bootstrap, remote, LocalScript, bridge, place, or setting was changed.

### Verification state

In the exact canonical Studio place (PlaceId `91045933836846`, GameId `10596427617`), the focused UI suite passed 17/17 and the aggregate passed 397/397 across 15 suites. One final fresh Xbox One Play observed one persistent safe-area root, empty ordered production hosts, one load/preload, blocked then released pointer input, background activation, actual keyboard navigation/activation, a connected Studio Virtual Controller gamepad focus route, character-replacement persistence, and complete mandatory `Finish()` teardown with no fixture UI or selection residue. Raw TS-STATIC-001 partitions produced zero positive diagnostics and one expected mismatch per negative; all three temporary fixtures were deleted before ordinary-tree reanalysis. Read-only Experience Settings inspection at this entry's UTC showed “Allow Loading Third Party Assets” disabled. No approved external fixture/AssetId exists, so cloud smoke was not run and is not a failure. Controller-owned layout/feature validators and Rojo build were not run by Engineering.

### Corrections to earlier evidence

Earlier 15/15 and mandatory cloud-smoke statements describe superseded pre-revision-9 evidence and must not be used as current release proof. Current focused count is 17/17; TS-TEST-016 is the local fixture proof; exact-place `AllowInsertFreeAssets=false` is separate read-only evidence; cloud smoke remains conditional.

### Blockers

None observed in the assigned Engineering scope.

### Next step

Execute the exact controller completion action, then fresh independent Review/QA. TF-0010 remains `in_progress / active`; only an explicit later `$feature-finish` request owns that lifecycle transition.

## 2026-08-25T05:52:15.633Z — TS-STATIC-001 raw-evidence remediation

- Feature: TF-0010
- Head: e98557f334625e70e6984f2cde85eb3c9c3c3708
- Lifecycle transition: none; remains in_progress / active

### Result and current state

The direct Review requirement gap for `TS-STATIC-001` was corrected without changing product code or prior executable evidence. The approved three temporary strict fixtures were reproduced only to recapture mandatory analyzer version, exact paths/full hashes, marked lines, and raw diagnostics, then deleted again.

### Verification state

Roblox Studio/analyzer version `0.735.0.7351131` was used through the `Script Analysis` panel with `Display only current script` in the selected canonical instance `5777309d-8ba5-4e8b-810a-01792378d73c` (PlaceId `91045933836846`, GameId `10596427617`). `TypedNavigationPositiveFixture.luau` SHA-256 `7a29b2dad69540bf00a6246bb1f1bd247ca7c7a70e86d954c2342f5e5a853a0d`, marked lines 7/8, produced zero diagnostics. `TypedNavigationAddNegativeFixture.luau` SHA-256 `a072327e7ffb7905d783d6fa4c0b2f606c67e36f070700077eee28179eb345ca`, marked line 6, produced exactly `Type Error: (6,54) Expected this to be 'nil', but got 'string'`. `TypedNavigationReplacementNegativeFixture.luau` SHA-256 `9eef92c3578ecca0514550acae19ebd99ef7f92394f1adcf8493e65d2e47f26d`, marked line 6, produced exactly `Type Error: (6,62) Expected this to be 'nil', but got '{ TS_STATIC_001_REPLACEMENT_MISMATCH: boolean }'`.

All three temporary filesystem paths and synchronized DataModel instances were confirmed absent after deletion. Ordinary-tree reanalysis opened `ReplicatedStorage.Client.UI.Config.WindowTypes` and showed zero current-script diagnostics; the overall warning counter decreased from fixture-inclusive 10493 to 10491, exactly removing the two intentional negatives. The remaining 10491 warnings are unrelated pre-existing diagnostics, so the ordinary tree contains zero diagnostics introduced by the fixtures or current UI evidence remediation. No Play/device suite, controller-owned layout/feature validator, or controller-owned Rojo build was rerun because this correction was documentation/static-evidence only.

### Blockers

None observed in the assigned remediation scope.

### Next step

Execute the exact controller completion action, then fresh independent Review and QA. This entry does not authorize or perform `$feature-finish`.

## 2026-08-25T06:06:40.059Z — final candidate documentation synchronization

- Feature: TF-0010
- Head: e98557f334625e70e6984f2cde85eb3c9c3c3708
- Lifecycle transition: none; remains in_progress / active

### Result and current state

Supporting UI System documentation is synchronized with the accepted four-slice candidate. Fresh independent Review and QA passed after the last candidate-changing remediation. This checkpoint records completed implementation and verification without changing feature lifecycle state; only a later explicit `$feature-finish` request may move TF-0010 to ready.

### Important decisions and discussions

No product or architecture decision changed. The deterministic repository-owned data-only fixture remains the required automated TS-TEST-016 route through production `WindowConfigCompiler` and `WindowAssetLoader`; the production cloud/AssetId capability remains available, while cloud smoke is conditional on an already-approved external fixture. Review and QA findings remain limited to reproducible failures or direct mandatory acceptance-contract violations.

### Verification state

All four slices completed independent Review and QA with PASS. The latest fresh canonical Studio Play passed `UiSystemTestRunner` 17/17, including executable `TS-TEST-009` post-yield Open/Close owner, generation, deadline, and destroyed-navigator regression coverage plus local-fixture `TS-TEST-016`; `AllTestsRunner` passed 397/397 across 15 suites. The complete Xbox One TS-TEST-012 checklist covered pointer, keyboard, connected Studio Virtual Controller gamepad, safe-area projection, character-replacement persistence, and mandatory `Finish()` cleanup.

TS-STATIC-001 records Studio/analyzer version `0.735.0.7351131`, exact paths, full SHA-256 values, marked lines, raw zero-positive and exact negative diagnostics, deletion of all three temporary fixtures, and ordinary-tree zero introduced diagnostics. Separate exact-place read-only evidence at `2026-08-25T05:33:26.033Z` records `AllowInsertFreeAssets=false` for PlaceId `91045933836846` and GameId `10596427617`. No approved external fixture/AssetId exists, so cloud smoke was not run and is not a failure. Controller-owned repository-layout validation, feature-workflow validation, and the temporary Rojo build passed at the latest candidate completes. No check, Studio operation, Rojo operation, publish, deployment, cloud load, or settings mutation was performed by this documentation assignment.

### Blockers

None.

### Next step

Complete the documentation assignment and follow the controller through fresh post-documentation Review and QA. Keep TF-0010 `in_progress / active` until the user explicitly invokes `$feature-finish`.

## 2026-08-26T04:52:42.8766975+00:00 — finished

- Feature: TF-0010
- Head: e98557f334625e70e6984f2cde85eb3c9c3c3708

### Result and current state

TF-0010 UI System полностью реализована и документирована: один persistent UiRoot с HudHost, ToastHost и WindowHost; типизированные UI actions, identity и bubbling; конфигурируемые data-only окна с pooling/preload; deterministic multi-window navigation, lifecycle, recovery and post-yield protection; window-authoring/project-initialize contracts; repository-owned local release fixture. Все четыре slice приняты, финальные Review/QA прошли, controller достиг production_ready_candidate. Блокеров нет. Следующего implementation step нет.

### Important decisions and discussions

Сохранены утверждённые границы: один manifest-composed client owner; HUD/toast content остаётся project-owned; WindowNavigator единолично владеет window lifecycle; один canonical frozen definition/config/loader route; существующие PoolModule, ContentPreloader, Signal, PlayersModule и initialization APIs не расширялись. Обязательный automated release fixture является deterministic repository-owned data-only fixture через production WindowConfigCompiler и WindowAssetLoader; cloud capability сохранена, но cloud smoke условен наличием отдельно одобренного external fixture. Отклонены second config/loader/bootstrap, Remote/LocalScript test bridge, универсальные HUD/toast lifecycle systems, аналитика и теоретическое hardening. Publish, deploy, AssetId request, cloud load и settings mutation не выполнялись.

### Verification state

До Finish фактически выполнено: runtime controller ready generation 228, terminal result production_ready_candidate, open gates/questions отсутствуют, exact ready replay byte-noop; final independent Review и QA PASS. Fresh canonical Studio Play: UiSystemTestRunner 17/17 PASS, включая executable post-yield Open/Close regression и local TS-TEST-016; AllTestsRunner 397/397 PASS across 15 suites. Xbox One checklist подтвердил pointer blocking/activation, keyboard and connected virtual-controller gamepad navigation, safe-area behavior, respawn persistence и mandatory Finish cleanup. TS-STATIC-001 зафиксировал expected positive/negative diagnostics, затем все три temporary fixtures удалены и ordinary-tree reanalysis показал zero introduced diagnostics. Read-only exact-place observation подтвердила AllowInsertFreeAssets=false. Controller-owned repository-layout validation, feature-workflow validation и temporary Rojo build PASS. Cloud smoke не запускался из-за отсутствия approved external fixture/AssetId и по утверждённому контракту не является failure. Сам feature-finish не запускал тесты, validators, build или Studio.

### Blockers

None.

### Next step

None; feature is ready.
