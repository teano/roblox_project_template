# ADR-0002: Keep SaveModule independent of save-layer meaning

- Status: Accepted
- Date: 2026-07-28
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

The project currently needs a global player save, but future games may need
multiple save layers with different lifetimes: global settings, session data,
or independently loaded save slots. Adding layer-specific behavior directly to
the common save module would make that module depend on every game's save
model and make later extraction expensive.

## Decision

`SaveModule` is only a controller registry and construction entry point. It
does not know what `global`, `session`, or `slot` means.

A project-specific initialization command or builder selects the controller ID,
lifetime, storage, key resolver, serialized-size limit, and ordered providers.
The same `SaveModule` can register and later remove multiple independently
constructed controllers.

The current `global_save` controller, including its Version and Wallet
providers, is composed explicitly by `GlobalSaveInitializationCommand`; that
name and provider set do not belong in the generic save module.

## Alternatives considered

### One concrete global profile manager

Rejected because it couples persistence infrastructure to the first game's
profile shape and cannot naturally represent independently loaded layers.

### SaveModule creates every known layer internally

Rejected because the generic module would need project-specific branches and
would own lifecycles that only composition roots understand.

### Postpone multiple-controller support

Rejected because separating the registry/builder boundary now is inexpensive,
while extracting layer assumptions after domain modules depend on them would
be costly.

## Consequences

### Positive

- New save-layer lifecycles can be added without changing `SaveModule`.
- Composition clearly exposes provider order and storage policy.
- Controllers can be created and removed independently.
- Save infrastructure remains reusable across Roblox projects.

### Negative

- Commands and builders contain more explicit wiring.
- Controller identity and disposal must be managed by the layer owner.
- A generic API exists before the project has several production layers.

## Enforcement

- Agent rules: `.agents/rules/save-system.md`,
  `.agents/rules/architecture.md`.
- Current documentation: `docs/InitializationAndSaveSystem.md`.
- Code boundaries: server/client `SaveModule`, both
  `SaveControllerBuilder` implementations, and
  `GlobalSaveInitializationCommand`.
- Tests: controller registration/removal and save integration coverage in
  `SystemTestRunner` and `ProductionIntegrationTestRunner`.
