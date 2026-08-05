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

`TeleportModule` uses this same boundary for compact own-player lifecycle
state and safe other-player presentation. `Teleport.Bootstrap` is a bounded
server-read startup request; attempts and appearances remain ordinary batched
messages. See [Teleport.md](Teleport.md).

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
inspection. Malformed calls therefore consume the same per-player budget as
valid calls and cannot bypass rate limiting by failing validation early.
Separate limits cover:

- RemoteEvent invocations, message count, and payload bytes;
- synchronous request count and combined response bytes;
- batch size, single-message size, queued count, and queued bytes;
- message type and request identifier lengths.

Repeated invalid-input and rate-limit warnings are deduplicated per player and
diagnostic cooldown. Continuously refilled token buckets avoid the double burst
of a fixed one-second window. The client uses matching batch, message, and byte
buckets as cooperative pacing; these are not a security boundary, so the server
still charges and enforces its own authoritative buckets.

The server separately shapes sustained server-to-client traffic per player by
batch invocations and estimated bytes. A temporarily exhausted budget leaves
the unsent queue and sequence unchanged until a later Heartbeat refill.
Queues remain bounded by the priority/backpressure policy below.

Roblox publicly documents an approximate client-to-server RemoteEvent
throttling rate, recommends avoiding frequent or large remote traffic, and
documents argument-shape limitations. Roblox does not publish an exact hard
payload-size limit for an ordinary reliable RemoteEvent. Consequently, the
exact production defaults live in `CommunicationConfig.luau`.

All configured byte limits are application-level estimates produced by
`CommunicationSerialize`. They bound inspection and traffic shaping, but they
are not the actual Roblox wire size and are not presented as engine hard
limits. Engine traffic also contains protocol and replication overhead. See
Roblox's [RemoteEvent reference](https://create.roblox.com/docs/reference/engine/classes/RemoteEvent),
[remote argument limitations](https://create.roblox.com/docs/scripting/events/remote),
and [network performance guidance](https://create.roblox.com/docs/performance-optimization/improve).

## Backpressure and recovery

Outgoing messages declare `Critical`, `State`, or `Presentation` priority.
When a queue is under pressure, presentation messages are discarded first.
If state can no longer fit, the queue collapses to one `ResyncRequired`
message and refuses more state until snapshot recovery starts.

Initial state and resync use this handshake:

```text
client registers handlers
  → client invokes RequestGlobalSnapshot
  → server captures save and Teleport state
  → server begins a new communication epoch and buffers output
  → client validates and atomically applies the complete baseline
  → client sends ClientReady with that exact epoch
  → server resumes and flushes buffered messages in order
```

The server permits only one snapshot request per player at a time, applies a
cooldown between attempts, and validates the complete response envelope against
an explicit node budget and the separate
`MaxSnapshotNetworkEstimatedBytes` network cap. The current 256 KiB estimate is
well above the template's Version-plus-Wallet snapshot (the private Statistics
provider is omitted) and ordinary 64 KiB
batch cap, while remaining independent of the much larger DataStore soft
serialization limit. An oversized response returns `SnapshotTooLarge` before
`BeginSnapshot`, so it does not change epoch, clear the queue, or strand the
in-flight guard. This is an application-level estimate, not a Roblox
RemoteFunction hard limit.

`ClientReady` is accepted only for the current outgoing epoch, so a delayed
acknowledgement cannot unpause another snapshot generation.

If the client resync handler fails transiently, the client remains paused and
retries the handler with exponential backoff from one to ten seconds. A
successful snapshot resets the retry state. This prevents a single request or
apply failure from leaving the client permanently frozen in resync mode.
Every in-flight attempt and delayed retry belongs to one recovery generation,
so a callback left over after snapshot resume, `Stop`, or a newer recovery
cannot clear or block the newer recovery state.

While recovery is paused, the client rejects and does not flush ordinary
outbound messages because they were derived from the stale snapshot baseline.
After the replacement snapshot resumes communication, current domain state may
produce new messages against that new baseline.

Applying a replacement snapshot retires any pending client-authority patch and
marks the new snapshot as the synchronization baseline. Later local changes can
then create a new patch instead of waiting forever for an acknowledgement that
belonged to the old epoch.

Teleport projection participates in the same initial and recovery generation.
Its complete local arrival, active attempt, and safe present-player view are
captured before `BeginSnapshot` and installed before `ResumeAfterSnapshot`.
After installation, `TeleportClient.ProjectionReconciled` tells subscribers to
re-read the complete projection; lost domain messages are not synthesized as
historical event callbacks. Present-player validation uses the configured
`Players.MaxPlayers` capacity rather than the separate 50-player teleport
request cap, while the complete response remains subject to the communication
snapshot byte and node limits.
Teleport State queue failure calls the communication recovery boundary
explicitly; backpressure collapse and client handler failure use the same
replacement path.

Statistics current-state reads use the same validated request transport but
are not part of the global save baseline. Only built-in snapshot types are
accepted, the server applies a code-reviewed statistic/metadata projection, and
each response is measured below the configured Statistics response cap. There
is no generic client Statistics mutation request.

## Lifecycle

`Stop` disconnects Roblox callbacks and clears queues, sequences, epochs,
recovery state, token-bucket state, diagnostic cooldowns, and snapshot guards.
`PlayerRemoving` performs the same per-player server cleanup. A resync handler
installed after the client has already paused starts the pending recovery
instead of leaving the client stuck.

## Verification

Run a clean Studio Play session and execute:

```lua
require(game.ServerScriptService.Tests.AllTestsRunner).runAll()
```

The production integration suite covers supported Roblox values, malformed and
oversized payloads, bounded inspection, invalid batch shapes, token-bucket
burst/refill and player isolation, malformed-call invocation charging,
client/server pacing, independent byte budgets, queue retention and sequence
preservation, validator and handler failures, priority pressure, stale epochs,
snapshot network caps and guard release, late resync registration, and
client-authority patch recovery. Transport-facing tests use the public
`ReceiveBatch`, `HandleRequest`, `Flush`, `ForgetPlayer`, and queue-stat
contracts with injected transport adapters; they do not inspect limiter maps
or sequence fields.
