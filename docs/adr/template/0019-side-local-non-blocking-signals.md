# ADR-0019: Use one side-local non-blocking Signal contract

- Status: Accepted
- Date: 2026-07-30
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Initialization, player lifecycle, save providers, domain models,
configuration, and content preloading need module-owned notifications on both
the server and client. Separate event implementations would duplicate
connection cleanup and dispatch semantics. A synchronous callback loop also
allows one yielding listener to suspend its publisher and every later
listener, which can block shared lifecycle infrastructure.

The event primitive is local to one Luau runtime. Client/server communication
has separate validation, authority, sequencing, and recovery requirements and
continues to use the communication module over Roblox remotes.

## Decision

Use `Shared/Util/Signal` as the common side-neutral contract for side-local
module notifications.

`Fire` snapshots active connections and schedules each listener independently
in registration order. Listener yields and failures do not suspend the
publisher or suppress later listeners. Connections added during dispatch
observe the next dispatch; connections removed before their turn are skipped.

One connection node owns callback and state. `Connected` is read-only,
`Disconnect` immediately unlinks and releases the callback, and `Once`
disconnects before execution. `Destroy` disconnects every active node,
releases callbacks, and prevents listeners not yet dispatched from starting.

`Signal` is not a network transport. Domain modules continue to use
`CommunicationServer` and `CommunicationClient` for client/server messages.

## Alternatives considered

### Invoke listeners synchronously

Rejected because a listener that yields can block initialization, player
lifecycle, persistence notifications, and unrelated listeners.

### Create a BindableEvent for every module event

Not selected as the template contract because it introduces Instance lifetime
and parenting for events that are already owned by Luau objects, and it does
not expose the template's typed generic signal interface. Roblox engine events
remain appropriate when an event is naturally owned by an Instance.

### Let every subsystem implement its own event helper

Rejected because connection state, cleanup, one-shot behavior, errors, and
yielding semantics would drift between systems.

## Consequences

### Positive

- Local event semantics and cleanup are consistent across server and client.
- A yielding or failing listener does not block shared lifecycle delivery.
- Disconnected callbacks are released immediately.
- Modules and tests use ordinary Luau-owned event objects without creating
  Instances.

### Negative

- The template owns and must test a custom event primitive.
- Every dispatch schedules one task per invoked listener.
- Completion owners must fire before destroying a signal when coroutines are
  waiting for the terminal event.

## Enforcement

- Agent rules: `.agents/rules/signals.md`, `.agents/rules/architecture.md`,
  `.agents/rules/testing.md`.
- Current documentation: `docs/Signal.md`,
  `docs/InitializationAndSaveSystem.md`.
- Code boundaries: `src/ReplicatedStorage/Shared/Util/Signal.luau` and
  module-owned signals.
- Tests: Signal contract cases in
  `src/ServerScriptService/Tests/SystemTestRunner.luau`.
