# Side-local Signal

## Purpose and boundary

`ReplicatedStorage/Shared/Util/Signal.luau` provides the common event contract
for communication between modules running on the same server or the same
client. It is used for initialization completion, player and character
lifecycle, save-provider dirty notifications, domain changes, configuration
updates, and content-preloading progress.

`Signal` is not a client/server transport and does not replace `RemoteEvent`
or `RemoteFunction`. Cross-boundary messages continue to use
`CommunicationServer` and `CommunicationClient`.

## Dispatch contract

`Fire(...)` takes a snapshot of the connections that are active when dispatch
begins and visits them in registration order.

- Every listener runs in an independent scheduled task.
- A listener that yields does not suspend `Fire` or prevent later listeners
  from starting.
- An error in one listener is reported with a traceback and does not suppress
  other listeners.
- A connection removed before its turn is skipped.
- A connection added during dispatch begins observing with the next `Fire`.
- `Once` disconnects before its callback starts, including during nested
  `Fire` calls.

Listeners must not depend on another listener completing first. When strict
ordering between operations is required, compose those operations in one
listener or use an explicit sequential domain workflow.

## Connection lifecycle

`Connect` and `Once` return a connection with a read-only `Connected` state.
`Disconnect` is idempotent, immediately removes the connection from the
signal, and releases its callback reference.

`Destroy` is idempotent. It marks every active connection disconnected,
releases every callback, and prevents listeners not yet dispatched from
starting. `Fire` after destruction is a no-op; new connections after
destruction are rejected.

`Wait` observes the next dispatch through a one-shot connection. Destroying a
signal does not resume a coroutine that is already waiting. An owner with a
terminal completion event must call `Fire` before `Destroy`, as
`ContentPreloader` does for an in-flight request completion signal.

## Usage

```lua
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local changed = Signal.new()
local connection = changed:Connect(function(oldValue, newValue)
	print(oldValue, newValue)
end)

changed:Fire(10, 20)
connection:Disconnect()
changed:Destroy()
```

Keep callbacks bounded and give their owner an explicit cleanup path. A module
that owns a signal also owns when that signal is destroyed. Consumers own and
disconnect the connections they create.

## Verification

The public lifecycle and dispatch contracts are covered by
`SystemTestRunner`, including:

- accurate read-only connection state;
- idempotent disconnect and destroy;
- one-shot behavior during nested dispatch;
- isolation from yielding listeners;
- isolation from throwing listeners and preservation of nil arguments in
  `Wait`;
- destruction during dispatch.

Run in a fresh Studio Play session:

```lua
require(game.ServerScriptService.Tests.SystemTestRunner).runAll()
```
