# Side-local signal rules

## Scope

Apply to `Shared/Util/Signal.luau`, module-owned local events, connection
lifecycle, `Connect`, `Once`, `Fire`, `Wait`, and `Destroy`.

Required context: `docs/Signal.md`.

## Mandatory rules

- `Signal` MUST remain side-local and MUST NOT replace client/server remotes.
- A yielding listener MUST NOT suspend `Fire` or prevent later listeners from
  starting.
- Listener failures MUST remain isolated and produce a traceback.
- `Connected` MUST reflect the real subscription state and remain read-only.
- `Disconnect` MUST be idempotent, immediately remove the subscription, and
  release its callback reference.
- `Once` MUST disconnect before its callback starts.
- `Destroy` MUST be idempotent, disconnect all active connections, release
  their callbacks, and stop listeners not yet dispatched.
- An owner that destroys a completion signal with active `Wait` consumers MUST
  fire the terminal completion first or provide another explicit cancellation
  contract.

## Forbidden patterns

- MUST NOT invoke listeners inline in the publisher coroutine when they may
  yield.
- MUST NOT retain disconnected callback closures until a later `Fire`.
- MUST NOT maintain separate public and private connection-state flags that can
  disagree.
- MUST NOT use a local signal to cross the server/client boundary.

## Verification

- `SystemTestRunner` contract coverage.
- Run every focused suite for a subsystem whose signal usage changes.
- Run a clean server/client Play session when initialization or player
  lifecycle delivery changes.
