# ADR-0031: Disable the teleport validation pad by default

- Status: Accepted
- Date: 2026-08-03
- Deciders: Project maintainers
- Supersedes: ADR-0029
- Superseded by: None

## Context

ADR-0029 introduced a runtime-only physical surface for published two-place
validation. Its exact GameId, PlaceId, and UserId gates prevent use in unrelated
Experiences, but the reusable template still shipped a maintainer-specific
operator capability in its unconditional startup composition. A developer
copying the template should receive no physical test object, player observer,
or personal cloud identity merely by starting a server.

The validation surface remains useful because Studio Play cannot prove a real
cross-place teleport, rapid return, or save-session-lock handoff. Removing the
controller would make every project rebuild the same risky test trigger.

## Decision

Keep `TeleportValidationPad` as an optional server runtime controller, but
inject a dedicated server-only `TeleportValidationConfig`. The reusable
default has `Enabled=false`, `GameId=0`, and empty route and tester maps.

The controller performs no player observation and creates no runtime object
unless the complete configuration is enabled and valid, the current DataModel
matches the configured GameId and a configured source PlaceId, and an
allowlisted tester is present. Routes are directed positive PlaceId pairs,
self-routes are rejected, and tester entries are positive UserIds set to
`true`. Invalid, incomplete, inherited, or mismatched configuration fails
closed before scene mutation or a Teleport call.

The validation configuration does not modify `TeleportPolicy`. The test route
must independently pass the production destination policy so the harness
cannot widen the gameplay trust boundary.

Maintain one repository operator guide for template and derived-project use.
It covers verified cloud identity, explicit policy composition, temporary
enablement, Rojo synchronization, ordinary publishing, forward/return and
rapid-repeat Roblox-client checks, evidence capture, and restoration to the
disabled state. A secondary repository or place used only as the destination
endpoint is not a separate release-readiness target.

## Alternatives considered

### Remove the validation controller after the first successful E2E

Rejected because future template updates and derived games still need a safe,
repeatable published teleport test.

### Keep identity gates as the only activation mechanism

Rejected because a reusable default should express operator intent explicitly
and should not subscribe or create scene content solely because one maintainer
joined the template validation Experience.

### Let validation configuration expand TeleportPolicy automatically

Rejected because an operator test surface must not become a second destination
authority or silently widen production routes.

### Store the enable flag in the scene

Rejected because the pad is source-controlled runtime tooling and must not
require edits to the Studio-owned canonical `place.rbxl`.

## Consequences

### Positive

- A copied template is inert until a developer explicitly configures testing.
- Personal tester and cloud identities are absent from the active default.
- Published E2E remains reproducible without a canonical scene edit or a new
  remote.
- Destination policy and validation tooling remain independent fail-closed
  boundaries.

### Negative

- Operators must configure, publish, and later disable both test endpoints.
- Derived projects must record intentional project composition and cloud
  identity before enabling the harness.
- A stale published server can retain the previously enabled configuration
  until it shuts down, so teardown evidence requires a fresh server.

## Enforcement

- Agent rules: `.agents/rules/teleport.md`, `.agents/rules/initialization.md`,
  `.agents/rules/testing.md`, `.agents/rules/rojo-project.md`.
- Current documentation: `docs/Teleport.md`, `docs/TeleportTesting.md`,
  `docs/InitializationAndSaveSystem.md`, `docs/TestCoverage.md`, and
  `docs/Features/template/TeleportModule/technical-specification.md`.
- Code boundaries:
  `src/ServerScriptService/Modules/Teleport/TeleportValidationConfig.luau`,
  `src/ServerScriptService/Modules/Teleport/TeleportValidationPad.luau`, and
  `src/ServerScriptService/Initialization/ServerManifest.luau`.
- Static enforcement: `scripts/validate-repository-layout.ps1`.
- Tests: `src/ServerScriptService/Tests/TeleportModuleTestRunner.luau`, clean
  default-disabled bootstrap, and the published operator checklist.
