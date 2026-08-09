# Experience configuration

## Ownership

Roblox Experience Configs are the only source of tunable configuration values.
`ConfigService` is server-only, so the server-owned
`ExperienceConfigCatalog` obtains one `ConfigSnapshot` and reads every
explicitly declared key from it.

Configuration contracts remain reviewed code:

- stable logical IDs and Experience Config keys;
- required versus optional presence;
- pure decode and validation functions;
- client disclosure and projections;
- client-side decode contracts;
- domain-specific live reload policy.

This separation is equivalent to a serialized class plus serialized values:
the contract is code, while the changing data is an Experience Config.

### Audio startup exception

TF-0005 is the narrow exception defined by ADR-0041. Its generated
`SoundCatalog` and static `AudioRuntimeConfig`, `RoutingConfig`, and
`SpatialProfiles` are Git-reviewed, startup-only Luau modules under
`ReplicatedStorage.Shared.Configs.Audio`. Server and client independently load
them inside protected `AudioStartup.Initialize`, exact-validate and deep-freeze
the complete state, and never use ConfigService, client projection, live
refresh, Attributes, or ValueObjects. Code-owned `AudioSafetyLimits` remains
outside `Configs` and cannot be raised by authored tables. All other tunable
configuration continues to follow this document's Experience Config boundary.
See [AudioSystem.md](AudioSystem.md).

## Server definitions

Projects extend
`ServerScriptService/Modules/Config/ServerConfigManifest.luau`:

```lua
{
	Id = "Equipment",
	Key = "equip_config",
	Decode = EquipmentConfigCodec.decode,
	ToClient = EquipmentConfigCodec.toClient,
}
```

`Decode` returns `(true, immutableCandidate, nil)` or
`(false, nil, "path.to.field: expected finite number")`.

The catalog reads and decodes all required definitions into temporary models.
It publishes generation `N` only when the complete candidate and every client
projection are valid. Consumers call `Services.Config:GetRequired("Equipment")`
and never read `ConfigService` directly.

The template manifest declares its required models explicitly, so bootstrap
fails before domain initialization when any source value is absent or invalid.

## Required template configs

The template currently consumes three required Experience Configs. Every value
must use the native Experience Config type `JSON`; a `String` containing
serialized JSON does not satisfy these contracts.

`wallet_config`:

```json
{
  "startingBalances": {
    "Coins": 0,
    "Gems": 0
  }
}
```

Every code-owned currency ID must be present exactly once with a non-negative
safe-integer amount no greater than `WalletConfig.MaxBalance` (`2^53 - 1`).
Unknown currency names and unknown object fields reject the complete config
generation. The template's published starting balances are zero; a derived
game may replace them with its reviewed launch values.

`global_save_config`:

```json
{
  "autoSaveIntervalSeconds": 60,
  "snapshotLoadTimeoutSeconds": 15,
  "snapshotRequestAttempts": 20,
  "snapshotRetryDelaySeconds": 0.5
}
```

The server consumes all four fields. The client bundle contains only
`SnapshotRequestAttempts` and `SnapshotRetryDelaySeconds`; storage names,
locks, shutdown policy, and other persistence/security boundaries remain
code-owned.

The codec accepts only finite values within these bounds:

| Field | Accepted value |
|---|---|
| `autoSaveIntervalSeconds` | number from 5 through 3600 |
| `snapshotLoadTimeoutSeconds` | number from 1 through 120 |
| `snapshotRequestAttempts` | integer from 1 through 100 |
| `snapshotRetryDelaySeconds` | number from 0.05 through 10 |

`statistics_config`:

```json
{
  "snapshotTypes": {
    "Global": { "retention": 0, "filter": { "mode": "AllowAllExcept", "statisticIds": [] } },
    "Session": { "retention": 4, "filter": { "mode": "AllowAllExcept", "statisticIds": [] } },
    "Place": { "retention": 8, "filter": { "mode": "AllowAllExcept", "statisticIds": [] } }
  },
  "publicProjection": {
    "Global": { "statisticIds": [], "metadataKeys": [] },
    "Session": { "statisticIds": [], "metadataKeys": [] },
    "Place": { "statisticIds": [], "metadataKeys": [] }
  },
  "limits": {
    "maxSnapshotTypes": 16,
    "maxRetentionPerType": 32,
    "maxStatisticIdsPerSnapshot": 256,
    "maxStatisticIdLength": 64,
    "maxSnapshotTypeLength": 48,
    "maxSnapshotEncodedBytes": 24576,
    "maxMetadataDepth": 6,
    "maxMetadataNodes": 128,
    "maxMetadataEncodedBytes": 4096,
    "maxMetadataKeyLength": 64,
    "maxMetadataStringLength": 256,
    "maxDedupSources": 16,
    "maxEventIdsPerSource": 64,
    "maxProviderEncodedBytes": 524288,
    "maxClientResponseEstimatedBytes": 49152,
    "maxHistoryReadCount": 32
  },
  "saveRequestCooldownSeconds": 30
}
```

The three built-in types are required. Projects add stable custom type IDs in
`snapshotTypes`, but only built-ins may appear in `publicProjection`.
`AllowOnly` and `AllowAllExcept` filters are copied into each new snapshot.
The codec applies field/count/string/metadata/record/provider/response caps.
`maxStatisticIdLength` must be at least 36 so every accepted configuration can
represent the mandatory Wallet transaction GUID and the adapter's code-owned
source/statistic IDs. Aggregate provider budgeting reserves every retained
snapshot plus the larger of a maximum ordered cursor or a maximum exact
EventId ledger for each dedupe source, including bounded identifier and JSON
encoding overhead. The practical `16 × 64` dedupe defaults fit the 512 KiB
provider budget alongside the configured snapshot maxima; larger values remain
within the code hard caps only when the complete theoretical budget fits.
The default public projection is empty. See
[Statistics.md](Statistics.md) for lifecycle and API semantics.

`saveRequestCooldownSeconds` accepts finite values from `1` through `3600`.
The positive lower bound is code-owned safety policy: every accepted
Statistics configuration retains the shared requested-save coalescing window.

All three models are startup-only for a server generation. Publishing a newer
Experience Config makes `UpdateAvailable` fire, but it does not change active
wallet grants, autosave scheduling, snapshot retry policy, or active statistic
filters/retention. Those values apply after the next server/client bootstrap
unless a future domain-safe coordinator explicitly adopts a refreshed catalog
generation.

When a later generation reduces snapshot retention, Statistics reconciliation
deterministically removes only the oldest excess closed records before
validation and preserves the newest records plus active/pending snapshots,
counters, values, metadata, filters, and deduplication state. Other persisted
limit reductions remain fail-closed and may require an explicit migration.
Retention pruning itself also validates every old record and its ID/counter
relationship first, so it cannot trim away malformed or conflicting data and
make a corrupt profile appear valid.

## Client disclosure

Client access is deny-by-default. The server manifest maps a public bundle ID
to logical config IDs:

```lua
ClientBundles = {
	Bootstrap = {
		"GlobalSave",
	},
}
```

The allowlist is server code, not an Experience Config. A newly created key
therefore remains server-only until code review explicitly exposes it.
The template exposes only the client-safe GlobalSave retry policy; Wallet and
Statistics configuration remain server-only. Statistics current-state reads
use their own bounded, server-projected domain DTO rather than disclosing this
configuration. A project that adds another client config must add its logical
ID, explicit projection, and matching client decoder in reviewed code.

Every exposed definition requires `ToClient`. This function creates a DTO and
is the only place where server data crosses the disclosure boundary. Fields
such as drop weights, server authority rules, anti-cheat tolerances, unreleased
content, and secrets stay out of that DTO.

The client asks for a named bundle, never an Experience Config key. The
server returns a cached, prevalidated bundle:

```text
Experience Config snapshot
  -> server codecs
  -> immutable server generation
  -> explicit client projections
  -> named bundle
  -> communication request
  -> client codecs
  -> immutable client generation
```

`ClientConfigCatalog` loads its bootstrap bundle after communication and
before save/domain initialization. Project client modules add matching
definitions to `ClientConfigManifest` and read the result through
`Services.Config`.

## Transport

Config bootstrap happens before the normal `ClientReady` state. Batched
server-to-client messages intentionally wait for `ClientReady`, so using them
for this request would deadlock initialization.

The communication module therefore owns one bounded `Request` RemoteFunction.
Request types must be registered with validators. Both request and response
use `CommunicationSerialize`, per-player request/byte rate limits, and the
single-message size limit. The API is for synchronous server-read boundaries;
ordinary runtime changes remain compact batched messages.

A client bundle is capped at 56 KiB estimated size, below the communication
single-message limit. An Experience Config may be larger, so client
projections must be split or reduced when necessary.

## Refresh

`ConfigSnapshot.UpdateAvailable` only reports that a newer source exists. It
does not mutate the published catalog. A domain coordinator may call
`ExperienceConfigCatalog:Refresh()` at a safe boundary.

Catalog update and generation-change notifications use the shared side-local
contract documented in [Signal.md](Signal.md).

Refresh follows:

```text
refresh source snapshot
  -> decode all definitions
  -> validate all projections and bundle sizes
  -> publish generation N+1 on complete success
```

Any failure preserves generation `N`. Client refresh similarly constructs a
complete temporary generation and rejects stale or invalid results. The
template deliberately does not automatically reinitialize domain providers:
each project must choose whether a config applies immediately, between
rounds, on the next session, or only after server restart.

## Wallet initialization

Wallet provider version 3 persists flat currency balances,
`IsInitialized`, and server-only `LastTransactionSequence`. A missing Wallet
provider is a new wallet:

```text
CreateDefault with IsInitialized=false
  -> install memento
  -> Run applies wallet_config.startingBalances
  -> set IsInitialized=true
  -> mark Wallet dirty
  -> persist provider version 3
```

Repeated `Run` and later loads see `IsInitialized=true` and never apply the
startup grant again. Version 1 wallets did not have the flag; reconciliation
preserves their balances and sets the flag to `true`, preventing an upgrade
from granting existing players a second starting balance. Version 2 wallets
gain sequence zero without changing balances. Both fields remain server-only
and are removed by `ToClientMemento`.

## Failure policy

- Missing or invalid required data during initial server bootstrap is fatal.
- A failed live refresh preserves the last valid generation.
- An unknown client bundle is reported only as unavailable.
- Client startup retries temporary `NotReady`, rate-limit, and transport
  failures for a bounded interval.
- No partial server or client model becomes visible.

## Tests

Run in Studio Play:

```lua
require(game.ServerScriptService.Tests.ConfigCatalogTestRunner).runAll()
require(game.ServerScriptService.Tests.SystemTestRunner).runAll()
require(game.ServerScriptService.Tests.ProductionIntegrationTestRunner).runAll()
```

The focused suite uses injected ConfigService and communication fakes. It does
not depend on live Experience Configs.

TF-0005 local-config tests belong to `AudioCatalogTestRunner` and
`AudioIntegrationTestRunner`, not `ConfigCatalogTestRunner`; a regression test
must also prove that non-audio configuration still uses Experience Config.

For the required order of preparing a dedicated real-API environment, see
[IntegrationTesting.md](IntegrationTesting.md).
