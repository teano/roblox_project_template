PROOFREADER_ID: tf0010-ui-spec-proofreader-r3-01
PRD_SHA256: 31f00b75820a2a917ea55c1f486a3846b7e273eb689f563601ec2093269c0995
SPEC_SHA256: f65af520d93816306d0d4b55ba2c04de47729beb5b77ffe55d2691f0bd4d550d
COVERAGE_COMPLETE: no

FINDINGS:
F-R3-001 | Major | public-contract | PRD-REQ-013, PRD-REQ-140, PRD-AC-003, PRD-AC-049 | `technical-specification.md` §4.4 admission step 1 requires every same-window in-flight Open/Close request to return typed `NoOp`, but §4.6 declares parameterless `CloseWindowAsync` as `UiVoidResult`, and §5.1 explicitly limits that union to `Success | Error` while assigning `NoOp` only to `UiValueResult`; the required Close no-op cannot be represented by the published signature. | Add a distinct no-op branch to the parameterless Close result contract (or introduce one exact close result union that contains it), then align §4.6, §5.1, error/result wording, TS-TEST-003, and TS-TEST-010 without treating no-op as success or error.
F-R3-002 | Major | lifecycle-boundary | PRD-REQ-006, PRD-REQ-151, PRD-REQ-152, PRD-REQ-165, PRD-AC-056, PRD-AC-058, PRD-AC-060 | `technical-specification.md` §4.3 says pooled adapter `Acquire` parents the root into `WindowHost`; current `Pool.Acquire` invokes adapter `Acquire` before returning the lease (`src/ReplicatedStorage/Shared/Pooling/Pool.luau:187-204`). Yet §§4.4/5.2 require a Prepared Window to complete `Initialize` before stack insertion, and replacement may hold that prepared view while the current window's Close hook yields. The candidate can therefore enter the rendered host before initialization/stack authority and remain there during replacement preparation. | Keep every new/acquired candidate off-tree or in a non-rendering staging owner through factory/acquire and `Initialize`; parent it into `WindowHost` only in the same current-generation commit that adds it to the stack and marks it Active. Preserve synchronous pool adapters and the existing lease API.
F-R3-003 | Major | ownership | PRD-REQ-024, PRD-REQ-069, PRD-REQ-070, PRD-REQ-071, PRD-REQ-073, PRD-REQ-103, PRD-REQ-104, PRD-REQ-105, PRD-REQ-197, PRD-NFR-002 | `technical-specification.md` §4.5 assigns the per-generation token set, handles, sink binding, and effective-blocking state to `WindowInputBlocker`, assigns navigation baselines/links/last selection to `WindowNavigationRegistry`, and §4.6 says `BaseWindowView` owns both controllers; §9 instead says tokens and focus have one owner, `WindowNavigator`. These are incompatible central ownership contracts. | State one explicit split: `WindowInputBlocker` owns per-view token registry/handles/sink/effective state; `WindowNavigationRegistry` owns per-view navigation/focus bookkeeping; `WindowNavigator` alone orchestrates stack state and holds/releases its system pause/transition handles. Update §4.4, §4.5, §4.6, §9, cleanup, and tests to use the same verbs and owner boundaries.
F-R3-004 | Major | verification | PRD-AC-002, PRD-AC-016, PRD-AC-022, PRD-AC-023 | §12.2 maps AC-002 to TS-TEST-002 although that row verifies config compilation rather than an empty-host clone/lease opening; maps AC-016 to TS-TEST-007 although that row does not cover config/asset/prefab/preload/cast/Initialize pre-stack failures with unchanged stack; and maps navigation AC-022 plus lifecycle-event AC-023 to TS-TEST-013 although its observable contract is controller hierarchy/events, while the relevant navigation and navigator lifecycle partitions are TS-TEST-006 and TS-TEST-004/008/009. Exact ID set equality in §12.5 therefore overstates semantic acceptance coverage. | Reassign these AC IDs to the representative partitions that actually exercise their observable behavior and expand only those row descriptions/fixtures enough to cover the missing boundary; keep one focused runner and avoid a Cartesian test matrix.

UNRESOLVED:
product | 0 | none
scope | 0 | none
boundary | 0 | none
ownership | 0 | none
public-contract | 0 | none

MINORS_ENGINEER_RESOLVABLE: yes
VERDICT: revise
