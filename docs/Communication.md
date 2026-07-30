# Client/server communication

## Boundary and transport

`CommunicationServer` and `CommunicationClient` are the only transport for
ordinary runtime messages. They use Roblox networking primitives directly:

- `ClientToServer` and `ServerToClient` are `RemoteEvent` instances used for
  ordered batches;
- `Request` is a bounded `RemoteFunction` used only for synchronous server-read
  startup requests;
- `RequestGlobalSnapshot` is a separate `RemoteFunction` owned by the global
  save initialization boundary.

The shared `Signal` module is not a network transport. It dispatches callbacks
inside one Luau VM after a network message has already arrived or when local
module state changes. It never replaces `RemoteEvent` or `RemoteFunction`.

Domain modules register message or request handlers with the communication
service instead of creating their own remotes. This keeps validation, ordering,
rate limiting, backpressure, recovery, and lifecycle cleanup at one boundary.

## Runtime message flow

```text
domain module
  → CommunicationClient/CommunicationServer queue
  → bounded batch on Heartbeat
  → Roblox RemoteEvent
  → envelope and payload validation
  → registered domain handler
```

Each server-bound message type has a mandatory validator. Validators and
handlers execute behind a protected boundary. An exception or invalid payload
does not escape through a Roblox remote callback and does not mutate domain
state; the affected client is moved to snapshot recovery.

Every batch carries an epoch and sequence number. Older epochs are ignored. A
gap in the current epoch, an invalid server batch, or a handler failure pauses
normal client delivery and requests a fresh snapshot.

## Serialization contract

Communication serialization is separate from DataStore serialization. Payloads
may contain:

- booleans, strings, and finite numbers;
- dense arrays with keys `1..n`;
- dictionaries with string keys;
- supported Roblox value types such as `Vector2`, `Vector3`, `CFrame`,
  `Color3`, `UDim`, `UDim2`, `Rect`, `NumberRange`, `BrickColor`, and
  `EnumItem`.

All numeric components of supported Roblox value types must be finite.
`Instance`, functions, threads, userdata outside the allowlist, metatables,
cycles, mixed tables, sparse arrays, and unsupported key types are rejected.
Inspection itself is bounded by depth, visited nodes, reported issues, and
estimated bytes, so an invalid payload cannot force unlimited diagnostic work.

Batch `Messages` must be a dense array. Its length is validated without relying
on Lua's `#` operator, which is undefined for sparse or dictionary-shaped
tables.

## Limits and abuse resistance

Server inbound invocation budgets are charged before deep envelope or payload
inspection. Malformed calls therefore consume the same per-player window as
valid calls and cannot bypass rate limiting by failing validation early.
Separate limits cover:

- RemoteEvent invocations, message count, and payload bytes;
- synchronous request count and combined response bytes;
- batch size, single-message size, queued count, and queued bytes;
- message type and request identifier lengths.

Repeated invalid-input and rate-limit warnings are deduplicated per player and
window. The exact production defaults live in
`CommunicationConfig.luau`.

## Backpressure and recovery

Outgoing messages declare `Critical`, `State`, or `Presentation` priority.
When a queue is under pressure, presentation messages are discarded first.
If state can no longer fit, the queue collapses to one `ResyncRequired`
message and refuses more state until snapshot recovery starts.

Initial state and resync use this handshake:

```text
client registers handlers
  → client invokes RequestGlobalSnapshot
  → server begins a new communication epoch and buffers output
  → client atomically applies the snapshot
  → client sends ClientReady with that exact epoch
  → server resumes and flushes buffered messages in order
```

The server permits only one snapshot request per player at a time, applies a
cooldown between attempts, and validates the complete response envelope against
an explicit node and estimated-byte budget. `ClientReady` is accepted only for
the current outgoing epoch, so a delayed acknowledgement cannot unpause another
snapshot generation.

Applying a replacement snapshot retires any pending client-authority patch and
marks the new snapshot as the synchronization baseline. Later local changes can
then create a new patch instead of waiting forever for an acknowledgement that
belonged to the old epoch.

## Lifecycle

`Stop` disconnects Roblox callbacks and clears queues, sequences, epochs,
recovery state, rate windows, and snapshot guards. `PlayerRemoving` performs
the same per-player server cleanup. A resync handler installed after the client
has already paused starts the pending recovery instead of leaving the client
stuck.

## Verification

Run a clean Studio Play session and execute:

```lua
require(game.ServerScriptService.Tests.ProductionIntegrationTestRunner).runAll()
require(game.ServerScriptService.Tests.SystemTestRunner).runAll()
```

The production integration suite covers supported Roblox values, malformed and
oversized payloads, bounded inspection, invalid batch shapes, rate-limit
evasion, validator and handler failures, queue pressure, stale epochs, snapshot
guards, late resync registration, and client-authority patch recovery.
