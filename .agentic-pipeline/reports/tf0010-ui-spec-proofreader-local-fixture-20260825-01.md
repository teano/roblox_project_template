# UI System Specification Revision 9 — Proofreader Wave 1

- PROOFREADER_ID: `tf0010-ui-spec-proofreader-local-fixture-20260825-01`
- PRD_SHA256: `31f00b75820a2a917ea55c1f486a3846b7e273eb689f563601ec2093269c0995`
- SPEC_SHA256: `797047127715f57bdd5b4bb67e78ecdba2448f858193fdf710099c8d92e1eca0`
- COVERAGE_COMPLETE: yes
- MINORS_ENGINEER_RESOLVABLE: yes
- VERDICT: revise

## Findings

- F-001 | Major | verification | TS-TEST-012 still requires configured sample-window Play behavior without defining the repository-owned no-cloud setup required by the revised authority. Resolve by using the same canonical local data-only fixture and injected production loader/config composition for the mandatory client/device checklist.
- F-002 | Major | verification | `AllowInsertFreeAssets=false` evidence became conditional with cloud smoke even though the setting remains a mandatory invariant. Resolve with a separate mandatory read-only exact-place setting observation that requires no AssetId.
- F-003 | Major | verification | TS-TEST-012 lacks exact fixture source, composition route, and observable results for window operations when production `TemplateWindowConfig` is empty. Resolve with the repository-owned fixture path and canonical `WindowConfigCompiler` / `WindowAssetLoader` setup; do not add a second production config or loader.

## Unresolved authority

- product: 0
- scope: 0
- boundary: 0
- ownership: 0
- public-contract: 0

The user-selected no-cloud repository-owned fixture route resolves the Proofreader's technical either/or question. No product or boundary decision remains for the user.
