# ADR-0045: Keep client UI ownership behind one manifest-composed root

- Status: Accepted
- Date: 2026-08-22
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Gameplay presentation needs persistent HUD, toast, and window layers plus a
single semantic event surface. Directly authored startup scripts, per-element
signals, or a universal HUD/toast lifecycle would distribute ownership and
make respawn, cleanup, identity, and future analytics behavior ambiguous.

## Decision

Use one client `UiSystem`, constructed by `ClientManifest` and initialized by
the `UI` command. It owns one safe-area `UiRoot`, the ordered host containers,
window presentation, one identity registry, and one private side-local root
signal. Project systems receive the narrow HUD/toast hosts and element context
through explicit composition and retain their own content lifecycle.

Window authoring uses one repository data-only template and one canonical
typed definition table per concrete window. The reusable template owns no
derived config. Project initialization creates the exact project-owned
`DerivedWindowConfig.luau`, and repository validation plus upstream merge
policy preserve that namespace boundary without adding runtime repository
detection.

UI controllers form an explicit ownership tree. Their globally unique final
`UIElementId` values are claimed atomically; events bubble synchronously to the
root, and `BaseWindowView` alone enriches window events with `WindowId`. The
root validates serializable envelopes before asynchronous `Signal` delivery.
Respawn and Character replacement do not own the UI lifetime.

## Alternatives considered

### Independent startup LocalScripts

Rejected because initialization order and failure propagation would leave the
client manifest.

### Universal HUD and toast registries

Rejected because they would take lifecycle ownership from the project systems
that create the content.

### A signal at every controller level

Rejected because ownership order would become asynchronous and every element
would add separate subscription lifetime.

## Consequences

The root, identities, cleanup, and semantic stream have one inspectable owner,
and later window slices can extend the same context. Integrators must use the
injected hosts/context and explicitly own their presentation cleanup.
Concrete project windows additionally require a permitted cloud GUI asset and
repo-owned definition/view code; the cloud asset never carries executable
source.

## Enforcement

- Agent rules: `.agents/rules/ui.md`, `.agents/rules/initialization.md`,
  `.agents/rules/signals.md`, `.agents/rules/players.md`,
  `.agents/rules/project-initialization.md`, and
  `.agents/rules/template-updates.md`.
- Current documentation: `docs/UiSystem.md` and
  `docs/InitializationAndSaveSystem.md`.
- Code boundaries: `ReplicatedStorage/Client/UI/**`,
  `ClientManifest`, and `UiInitializationCommand`.
- Tests: `UiSystemTestRunner`, `SystemTestRunner`, aggregate tests, the
  repository-layout validator, and the clean client Play checklist.
