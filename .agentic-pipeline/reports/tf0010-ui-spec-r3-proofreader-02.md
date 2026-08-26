PROOFREADER_ID: tf0010-ui-spec-proofreader-r3-02
PRD_SHA256: 31f00b75820a2a917ea55c1f486a3846b7e273eb689f563601ec2093269c0995
SPEC_SHA256: 9802b1595fe7d74a4b4295385c4283997712f9e2db10df8ef00812e8fa96d1f0
COVERAGE_COMPLETE: no

FINDINGS:
F-R3-02-001 | Major | boundary | PRD-REQ-027, PRD-REQ-035, PRD-REQ-039, PRD-REQ-040, PRD-REQ-081, PRD-REQ-103, PRD-REQ-104, PRD-REQ-105, PRD-REQ-204, PRD-NFR-002, PRD-NFR-006, PRD-AC-009, PRD-AC-022, PRD-AC-030, PRD-AC-104 | Section 4.6 gives every reusable BaseUiElement only its represented root, identity/navigation flags, and a UiElementContext whose complete callback surface is ClaimSubtree, ReleaseSubtree, and DeliverToRoot; nevertheless EmitAction is said to validate base action authority. No specified source supplies a nested action handler with its containing window's Active/Paused authority and optional BlockObjectRef effective state. Parent bubbling cannot provide the guard because the child has already emitted and every parent must forward exactly once. The same boundary permits runtime AddNestedUiElement/RemoveNestedUiElement, while Section 4.5 configures WindowNavigationRegistry only once during BaseWindowView initialization and specifies no attach/detach synchronization for the membership, authored baselines, automatic/override links, default validity, or last-selected state of dynamically added/removed UINavigationEnabled descendants. Consequently the mandatory per-handler rejection path and navigation behavior of a supported dynamic descendant are not implementable or verifiable from the specified contracts. TS-TEST-006, TS-TEST-007, and TS-TEST-013 exercise the constituent owners separately but do not close this cross-boundary lifecycle path. | Define one minimal UI-internal per-window element binding contract at the BaseWindowView boundary, bound and unbound atomically with subtree attach/detach. It must give reusable action handlers a narrow read-only authorization decision derived from navigator Active/Paused state plus blocker effective state without exposing WindowId or a concrete window, and register/unregister dynamic navigation members with WindowNavigationRegistry. Specify failure atomicity and default, override, and last-focus behavior when eligible descendants appear or disappear, then extend only representative TS-TEST-006/007/013 cases for dynamic attach/remove, action rejection, and navigation restoration. Preserve the existing blocker/navigation/navigator ownership split and the HUD/toast contract; no neighboring subsystem change is required.

UNRESOLVED:
product | 0 | none
scope | 0 | none
boundary | 0 | none
ownership | 0 | none
public-contract | 0 | none

MINORS_ENGINEER_RESOLVABLE: yes
VERDICT: revise
