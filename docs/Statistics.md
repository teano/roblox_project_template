# Statistics

`StatisticsModule` is the template's server-authoritative statistic collection
domain. It stores numeric facts in bounded snapshots, persists them as the
`Statistics` save provider, and exposes only code-approved read projections to
clients. Clients cannot mutate Statistics directly.

## Snapshot lifecycles

Every loaded player owns three built-in active snapshots:

- `Global` spans the persisted profile;
- `Session` spans one server-owned Teleport session across places;
- `Place` spans one visit to the current place.

Projects may declare additional snapshot types, such as `Round`, in
`statistics_config`. Custom types use explicit `StartNewSnapshot`,
`ContinueSnapshot`, and `CloseSnapshot` calls. Built-in lifecycles cannot be
controlled by those project APIs.

Snapshots have monotonically increasing per-type IDs, immutable creation
metadata and filters, finite numeric values, and creation-ordered bounded
history. Missing values read as `0` without changing persistent state. Every
returned snapshot, history array, and metadata table is a defensive copy.
When a new server generation lowers retention, provider reconciliation keeps
the newest allowed closed records in their existing order and preserves all
active/pending state, counters, values, metadata, filters, and deduplication
state. Every removed closed record path emits the same bounded payload-free
retention diagnostic. Reconciliation validates every older record before it
may be pruned; malformed records, duplicate IDs, and invalid counters remain
unmodified so normal provider validation fails closed instead of hiding
corruption.

On normal profile close, `Place` is closed into history and `Session` is moved
to the private `PendingSession` slot. A target server continues that Session
only when its trusted `TeleportModule:GetSession()` ID matches. External entry
or a mismatched Teleport session starts a new Session. `Global` remains active.
Close preparation runs inside the Global save controller's terminal lifecycle
reservation. An invalid close candidate leaves the current provider memento
unchanged, keeps Statistics in its mutation-rejecting closing state, and
returns a retryable `ClosePreparationFailed` result instead of memoizing that
failure forever. The session-lock owner performs bounded retries; a persistent
preparation failure uses the controller's explicit fail-closed finalization to
save the still-valid current memento before Stop and lock Release. Player
removal, shutdown, and same-key rejoin therefore share one terminal handoff and
cannot leave a departed gameplay-ready Statistics runtime heartbeating forever.
Shutdown includes already-departed retained owners in the same pre-stop target
snapshot as live players, and preparation retry/finalization shares the
coordinator's absolute deadline and bounded worker ownership. Statistics stays
mutation-rejecting throughout this retained interval; other Global providers
remain capturable but their public mutation gates are also closed.

## Applying facts

Server code applies one operation through:

```lua
statistics:ApplyOperation(player, {
	Operation = "Inc",
	StatisticId = "Enemies.Defeated",
	Operand = 1,
})
```

Supported operations are `Set`, `Inc`, `Dec`, `Min`, and `Max`. Negative
results normalize to zero. The module computes one complete candidate across
all active snapshots whose frozen filters accept the statistic, validates
every affected snapshot and the complete provider budget, and commits only on
total success.

Facts may include a deduplication identity:

```lua
FactIdentity = {
	Mode = "Ordered",
	SourceId = "Rewards",
	Sequence = rewardSequence,
	EventId = rewardId,
}
```

`Ordered` identities reject an already-consumed sequence. `EventId` identities
reject a retained event ID. Deduplication state and value changes commit in the
same candidate, so a rejected candidate consumes neither.

Wallet integration registers a synchronous committed-change handler before
player runtime starts. Each positive Wallet delta becomes
`Wallet.<CurrencyId>.Earned` with the persisted Wallet transaction sequence as
its ordered identity. Startup balances and spending are ignored. Wallet
provider version 3 persists `LastTransactionSequence`; older providers
reconcile it to zero without changing balances.

Derived projects add reviewed client fact message definitions only in
`StatisticsClientFactManifest.luau`. Each definition owns its exact validator
and maps the sanitized domain payload to server-authored operations. The
manifest is empty by default, and there is no generic client operation remote.

## Persistence and explicit saves

`Statistics` is provider version 1 with server authority and
`ClientSnapshotPolicy = "Omit"`. Its private provider memento never appears in
the global client snapshot. The server save controller still persists it and
performs a full provider capture at close, including changes that occur just
before shutdown.

`SaveSnapshot` asks `AutoSaveModule` for a bounded `ForceSave`. Requests during
the configured cooldown coalesce into at most one pending worker for that
controller/player. Removing a save controller synchronously unregisters its
autosave entry, invalidates pending requested-save generations, disconnects
its close listener, and clears controller/player bookkeeping before the
controller is destroyed. Repeated unregistration is a safe no-op. This API
does not close an active statistic snapshot. The configuration codec accepts a
cooldown only from `1` through `3600` seconds, so no production-valid policy
can disable this common anti-spam window.

## Client reads

The client bootstrap exposes a read-only `Services.Statistics` facade:

```lua
local snapshotResult = services.Statistics:GetCurrentSnapshot("Global")
local valueResult = services.Statistics:GetCurrentValue("Place", "Enemies.Defeated")

if snapshotResult.Ok then
	print(snapshotResult.Snapshot.Values)
end
if valueResult.Ok then
	print(valueResult.Value.Value)
end
```

Only `Global`, `Session`, and `Place` are remotely readable. Server policy in
`statistics_config.publicProjection` allowlists statistic IDs and top-level
metadata keys independently for each built-in type. Responses omit filters,
Session IDs, deduplication state, closed history, and unapproved values. Each
response is validated and measured against the configured client response cap.

## Configuration and limits

The required native-JSON Experience Config key is `statistics_config`. Its
complete production schema and default value are documented in
[ExperienceConfiguration.md](ExperienceConfiguration.md). The codec rejects
unknown fields, invalid UTF-8 identifiers, unsafe integers, sparse or duplicate
lists, missing built-in types, public project types, and a retention plan whose
theoretical capacity exceeds the provider budget. Accepted identifier limits
must represent the mandatory 36-byte Wallet transaction GUID. The aggregate
capacity check includes exact EventId ledgers for every configured dedupe
source, their bounded identifiers and JSON overhead, retained snapshots,
metadata, and provider indexes.

Configuration is frozen at startup. A new published generation does not alter
active snapshot filters or retention until a later server bootstrap. Provider
`Run` also distinguishes a lifecycle-ready transaction restart from a cold or
handoff load. Snapshot application and rollback pass explicit restart context
and resume the exact active runtime without creating another Session/Place
visit or emitting lifecycle dirty work. A cold load receives no such context,
so superficially matching active IDs cannot suppress normal visit resolution.

## Verification

Run the focused deterministic suite in a fresh Studio Play session:

```lua
require(game.ServerScriptService.Tests.StatisticsTestRunner).runAll()
```

The suite covers built-in and custom lifecycles, Teleport continuation,
operation formulas, atomic rejection, deduplication, metadata and byte limits,
Wallet integration, generic close capture, save coalescing, client projection,
and the read-only facade. Run `AllTestsRunner` before release.
