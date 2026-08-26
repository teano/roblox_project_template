PROOFREADER_ID: tf0010-ui-spec-proofreader-r3-07

PRD_SHA256: 31f00b75820a2a917ea55c1f486a3846b7e273eb689f563601ec2093269c0995

SPEC_SHA256: bee45379a63a1d3d262fd810866e69585e1000f32baffc4d8c1b4ea022a8d515

COVERAGE_COMPLETE: yes

FINDINGS:

- ID: F-R3-07-001
  severity: Major
  category: public_contract / type_api / implementability
  source: `technical-specification.md` lines 118, 152-160, 210, 337, 340, 387-391, 487-505
  evidence: Typed Add/replacement requires the caller to pass the exact canonical `WindowDefinition<TView, TViewModel>` table, and exact table identity is the runtime witness. The only specified authoring exports are heterogeneous dense sequences, while the compiled `WindowConfig` keeps those values behind private opaque `ErasedWindowDefinition = unknown` and exposes no typed lookup/export. The authoring skill is required to add a definition to a sequence, but the specification never defines how a domain caller imports the same canonical value with its concrete `TView`/`TViewModel` association intact. Indexing a heterogeneous sequence cannot serve as a stable named typed acquisition contract, and reconstructing/copying the record fails the required identity check. Thus the central typed API is declared but has no implementable caller-side acquisition path.
  minimal_recommendation: Define one canonical typed export convention, preferably a per-window definition ModuleScript that returns the single `WindowDefinition<TView, TViewModel>` table, is required by the duplicate-preserving authoring sequence, and is required directly by typed callers. State that this module is the record itself, not a second config/registry, and add one representative authoring/caller example and identity test.

- ID: F-R3-07-002
  severity: Major
  category: verification / public_contract / type_safety
  source: `technical-specification.md` lines 210, 652-663, 678; repository `rokit.toml`; existing `players-module/technical-specification.md` lines 639-652
  evidence: `TS-TEST-010` claims that a representative `--!strict` negative fixture proves both typed operations reject a definition/model mismatch before runtime, but every defined executable gate is a runtime ModuleScript suite, repository validators, Rojo build, or Studio Play checklist. None invokes Studio Script Analysis or a Luau analyzer, defines how an intentionally invalid fixture is introduced and removed, or records its expected diagnostic. The repository toolchain currently lists only Rojo, and Rojo build is not a type-check oracle. The repository's existing Players specification explicitly documents this exact limitation and requires Script Analysis plus temporary negative diagnostic evidence. Therefore the claimed compile-time acceptance result is not deterministically executable or auditable.
  minimal_recommendation: Add an explicit static-type evidence gate: run the available project/Studio Luau Script Analysis without adding a dependency, use temporary positive and per-operation negative fixtures with expected diagnostics, remove/revert the negative fixture before normal gates, and record exact evidence/limitations. Keep `TS-TEST-010` runtime assertions separate from this static oracle.

- ID: F-R3-07-003
  severity: Major
  category: lifecycle / async_failure / cleanup
  source: `technical-specification.md` lines 224, 320, 329-343, 519, 604-609, 675-679; PRD requirements 42, 74, 151, 152, 162, 181, 182
  evidence: The specification requires `Initialize`, `Clear`, `Pause`, and `Resume` to be synchronous/non-yielding and says a yield is a developer error, but the only required protection is `xpcall`. Luau's standard-library contract explicitly permits the function passed to `xpcall` to yield and makes the entire caller coroutine yield (`https://luau.org/library/`). No guard, suspended-coroutine handling, continuation invalidation, per-hook recovery mapping, or yield fixture is specified. A violating `Initialize`/`Pause`/`Resume` can therefore suspend the stack operation outside the declared async deadline path, and a yielding `Clear`/`OnClear` can prevent sibling/resource cleanup, contradicting the required lifecycle and aggregate-cleanup behavior.
  minimal_recommendation: Specify one protected non-yield invocation primitive that executes each synchronous hook in a separately inspectable coroutine, accepts only completion on the first resume, prevents a suspended continuation from later mutating state, and maps yield to the existing phase-appropriate typed error/diagnostic plus cleanup or quarantine policy. Apply it consistently to recursive cleanup and add deterministic one-yield/never-resume fixtures for all four hook classes.

UNRESOLVED_COUNTS:
  product: 0
  scope: 0
  boundary: 0
  ownership: 0
  public_contract: 0

QUESTION_IDS: none

MINORS_ENGINEER_RESOLVABLE: yes

COUNTS:
  critical: 0
  major: 3
  minor: 0
  findings_total: 3
  questions_total: 0
  prd_req_exact: 175/175
  prd_nfr_exact: 6/6
  prd_ac_exact: 91/91
  ts_req_unique: 20
  ts_test_unique: 16

VERDICT: revise
