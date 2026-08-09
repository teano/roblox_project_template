# Communication rules

## Scope

Apply to client/server communication modules, protocols, serializers, remotes, batching, priorities, sequencing, epochs, rate limits, client patches, and resync.

Required context: `docs/InitializationAndSaveSystem.md`.

## Mandatory rules

- Ordinary runtime messages MUST use `CommunicationServer`/`CommunicationClient`, not direct gameplay RemoteEvents.
- The shared `Signal` contract is side-local and MUST NOT be described or used
  as client/server transport; Roblox `RemoteEvent` and `RemoteFunction`
  instances remain the network boundary.
- RemoteEvents are batched once per Heartbeat and preserve queue order.
- The initial full snapshot and explicit resync use the dedicated snapshot RemoteFunction.
- Message handlers MUST be registered before the client requests its first snapshot.
- Every client-originated message type MUST have server validation before domain mutation.
- Server-bound validators are mandatory and MUST execute behind a protected
  boundary. A validator or handler exception MUST be contained and force
  snapshot recovery before further domain mutation.
- Batch message collections MUST be dense arrays and MUST NOT rely on `#` until
  their shape has been validated.
- Messages MUST be bounded by count and estimated bytes.
- Server inbound rate limiting MUST account for both message count and bytes.
- Server inbound invocation budgets MUST be charged before deep validation, so
  malformed envelopes and payloads cannot bypass rate limiting.
- Sustained inbound and outbound rates MUST use continuously refilled budgets,
  not fixed time windows that permit a double burst at a boundary.
- The client MUST pace legitimate outgoing batches within the corresponding
  authoritative server invocation, message-count, and estimated-byte budgets.
- The server MUST pace outgoing batches and estimated bytes independently per
  player without removing unsent messages or advancing sequence numbers.
- Repeated invalid-input and rate-limit diagnostics MUST be bounded per player
  and diagnostic cooldown.
- Request IDs MUST be bounded and treated as untrusted.
- Communication serialization MUST be separate from DataStore serialization.
- Safe value types such as `Vector3` and `CFrame` MAY cross the network only
  when all numeric components are finite; `Instance`, cycles, mixed or sparse
  tables, unsupported types, and non-finite numbers MUST be rejected.
- Communication inspection MUST bound depth, visited nodes, reported issues,
  and estimated bytes.
- Synchronous server-read startup requests MUST use the bounded request API
  owned by `CommunicationServer`/`CommunicationClient`, with a registered
  validator and response-size enforcement.
- The synchronous request API MUST NOT replace batched messages for ordinary
  gameplay mutations or notifications.

## Runtime synchronization

- Normal state changes MUST use compact semantic messages.
- A message SHOULD describe the operation/change needed by the client instead of replacing a full provider table.
- Client handlers MUST verify expected old state when order matters.
- A handler mismatch or failure MUST trigger full resync.
- Server batches MUST carry a snapshot epoch and sequence.
- Stale older-epoch packets MUST be ignored.
- Current-epoch sequence gaps MUST trigger resync.
- A failed client resync handler MUST retry with bounded exponential backoff while the client remains paused; it MUST NOT leave recovery permanently dormant after one transient failure.
- In-flight resync completions and delayed retry callbacks MUST be scoped to
  their recovery generation; stale work after snapshot resume, `Stop`, or a
  newer recovery MUST NOT mutate or block the active recovery state.
- While paused for resync, the client MUST neither accept nor flush ordinary
  outbound messages derived from the stale baseline.
- `ClientReady` MUST acknowledge the exact active snapshot epoch before the
  server resumes buffered delivery.
- Snapshot handling MUST allow at most one in-flight request per player,
  enforce a retry cooldown, and bound the complete response envelope with a
  network-specific estimated-byte limit that is independent of DataStore
  serialization limits.
- A snapshot MUST pass network validation before `BeginSnapshot` changes the
  epoch or clears the outgoing queue, and every request exit MUST release its
  in-flight guard.
- Replacing a snapshot MUST retire pending correlated work from the previous
  epoch, including an unacknowledged client-authority patch.

## Backpressure

- Every queued message MUST declare or inherit `Critical`, `State`, or `Presentation` priority.
- Presentation messages are the first eviction candidates.
- Critical or State overflow MUST collapse the queue to one `ResyncRequired` message.
- Once resync is required, additional state messages MUST be refused until `BeginSnapshot`.
- A single message MUST fit below the configured single-message limit.

## Authority

- Wallet mutations and every provider declared with server authority are
  server-authoritative.
- The client sends intentions or explicitly client-authority mementos, never
  authoritative Wallet values.
- The server MUST ignore and log unexpected providers or message types.

## Forbidden patterns

- MUST NOT use `FireClient`/`FireServer` directly from domain modules.
- MUST NOT send ModuleScripts, functions, metatables, Instances, or cyclic tables.
- MUST NOT send an entire provider table for a small runtime change.
- MUST NOT use batched RemoteEvents where a synchronous RemoteFunction result is required.
- MUST NOT create a domain-owned RemoteFunction when the bounded communication
  request API can represent the synchronous read.
- MUST NOT reuse `SaveSerialize` for runtime communication.
- MUST NOT drop state silently when resync can restore consistency.

## Positive example

```lua
communication:Queue(player, WalletConfig.MessageTypes.Changed, change, nil, {
	Priority = CommunicationProtocol.Priorities.State,
})
```

## Negative example

```lua
walletRemote:FireClient(player, walletModule:GetMemento(player))
```

This bypasses ordering/backpressure and replaces client runtime identity.

## Audio hybrid boundary

Audio hybrid uses only exact versioned Intent and Presentation entries in the
existing registry. Both remain installed before `ClientReady` even when audio
startup is disabled; disabled handlers exact-decode then return
`AudioDisabled` without playback, fanout, retry, replay, or resync state.
Client Queue rejection preserves predicted local playback, logs
`HybridQueueRejected`, and does not retry. See ADR-0041 and
`.agents/rules/audio.md`.

## Verification

- `ProductionIntegrationTestRunner`.
- Test Vector3 through queue and batch flush, not only serializer validation.
- Clean Play test for real client/server resync or protocol changes.
