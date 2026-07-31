# User data migrations

## Purpose

`MigrationModule` transforms a locked raw save document before save providers
reconcile or install runtime state. Use it for released game-version changes
that must coordinate several provider envelopes. Keep a provider-local schema
change in that provider's `ReconcileMemento`.

The pipeline is intentionally different from a local Unity migration:
Roblox servers may load many players concurrently and two servers may contend
for one profile. The existing `SessionLockingStorage` therefore acquires the
profile lock first, and one singleton migration controller may execute for
several different players at the same time.

## Controller contract

Register controllers explicitly in
`ServerScriptService/Modules/Migration/MigrationManifest.luau`:

```lua
local SplitWalletCurrency = {
	Id = "SplitWalletCurrency",
	TargetVersion = "2.0.0",
	Order = 10,
}

function SplitWalletCurrency:Migrate(document, context)
	local wallet = document.Providers.Wallet.Data
	wallet.Premium = wallet.Coins
	wallet.Coins = nil

	-- Returning nil keeps the mutated isolated document. A controller may
	-- instead return a complete replacement document table.
	return nil
end

return table.freeze({
	Controllers = table.freeze({
		SplitWalletCurrency,
	}),
	LegacyBaselineVersion = nil :: string?,
})
```

The scheduler snapshots `Id`, `TargetVersion`, `Order`, and the migration
callable when the controller is registered. IDs are stable and unique.
Versions use canonical `MAJOR.MINOR.PATCH`: `1.2.3` is valid, while `1.2`,
`01.2.3`, prerelease suffixes, and components above the safe-integer limit are
rejected. `Order` is also a non-negative safe integer.

Controllers must be:

- deterministic and safe to retry from the same stored input;
- stateless and reentrant across concurrent players;
- bounded in CPU, memory, and output size;
- free of irreversible external side effects;
- independent of table iteration order unless they sort the keys first.

Dependencies may be supplied when constructing a controller, but per-player or
per-run mutable state belongs in local variables. `context` includes `Player`,
`ControllerId`, `IsNewProfile`, `SourceVersion`, `TargetVersion`,
`CurrentVersion`, and `MigrationId`.

Controllers may transform any provider envelope, metadata, or document format
field required by the transition. They must not change the storage-owned
`Session` lock or create, remove, or update the Version provider's
`PreviousVersion` checkpoint. The pipeline validates these boundaries after
every controller. The complete result must be DataStore-safe and fit the
configured serialized save limit.

A non-`nil` return is a complete replacement document. The pipeline validates
that table as DataStore-safe before copying it into the isolated migration
state. Cyclic, metatable-backed, mixed/sparse, or otherwise unsafe replacement
tables therefore fail with the owning migration ID instead of reaching a
recursive deep copy. A controller that mutates the supplied isolated document
and returns `nil` is still validated at the normal per-controller ownership
boundary and final serialization gate.

The size gate also applies when an older checkpoint advances through a release
that has no raw controllers. Such an empty transition still has to persist the
new Version checkpoint atomically, so an unsaveable document fails before
provider runtime starts.

## Iterative version behavior

For stored checkpoint `S` and current version `C`, the pipeline executes every
controller whose target is in `(S, C]`. Target versions are ascending.
Controllers sharing a target execute by `Order`, then `Id`, and receive the
same preceding `SourceVersion`.

Example:

```text
stored 1.0.0
  → 2.0.0 / order 10 / AddInventoryIds
  → 2.0.0 / order 20 / RewriteEquippedItem
  → 3.0.0 / order 0  / SplitWalletCurrency
current 3.0.0
```

Never remove or materially rewrite a migration that may still be needed by a
retained production profile. Add a later corrective controller instead.
Before raising `VersionConfig.CurrentVersion`, ensure the manifest contains
the complete chain needed by the oldest supported production checkpoint.

## Profiles without a checkpoint

A brand-new document with an empty `Providers` dictionary starts at the
current version and runs no speculative legacy migration. Newness comes from
the successful lock-storage load result (`Created=true`), not from inspecting
the document shape. Lock acquisition records this classification in the owned
`Session` document so a retry of the complete `UpdateAsync` operation preserves
it even when an earlier attempt committed but its response was lost. Lock
refresh preserves that marker. Releasing before the first save removes active
ownership but leaves a marker that another server may acquire immediately.
Only the first successful profile save removes the classification atomically
with the provider data. If the creating server crashes after one or more
refreshes, a later stale-lock takeover also carries the marker forward and
safely completes first-profile initialization. An
existing document with an empty `Providers` dictionary and no such marker is
still a pre-checkpoint profile and fails closed without an explicit legacy
baseline; this prevents old root fields from being silently replaced by
provider defaults.

A non-empty document without the Version provider fails closed by default.
If the project has a real released schema that predates the Version provider,
set `LegacyBaselineVersion` to that known version in `MigrationManifest`.
The pipeline then applies the normal iterative chain from that baseline.
Do not guess a baseline from test data or from the current release.

The legacy document does not need to have the current `Providers` root.
Several same-version controllers may first normalize legacy root fields and
then build the provider dictionary. The final controller chain must produce a
string-keyed `Providers` dictionary; an array-shaped or otherwise invalid root
fails before provider defaults can hide or overwrite unconverted legacy data.

The migration controllers still leave the Version provider absent. Provider
application creates it only after the whole raw chain succeeds.

## Failure and persistence behavior

Migration runs after lock acquisition and before provider runtime mutation.
An invalid checkpoint, downgrade, controller exception, owned-field mutation,
unsafe shape, or oversized output aborts the load. The controller attempts to
release the session lock and reports a release failure separately if the
storage backend also fails. Failed load results expose `LockReleaseOk`; when
false, `LockReleaseCode` and the appended error identify the storage failure
without hiding the original migration/apply error.

When the stored checkpoint is older than the current version, the save
controller refreshes the session lock after the complete raw chain and before
provider application. Losing ownership during a yielding or expensive
transform therefore fails closed instead of creating runtime state on a stale
server.

After a successful chain, providers reconcile and apply atomically.
`VersionModule` advances `PreviousVersion` to the current version in the
applied runtime. Before load success is published, the integration queues
Version synchronously for dirty capture. Every subsequent save therefore
captures the new checkpoint before it can persist transformed provider data,
and writes both in one document. If the server stops before that write
succeeds, the stored checkpoint remains old and the deterministic chain runs
again on the next load.

## Release checklist

1. Identify the oldest production checkpoint and every intermediate schema.
2. Add focused controllers; use distinct orders for dependencies at one target.
3. Add unit cases for old input, already-migrated input, boundaries, and
   malformed data.
4. Add or update the end-to-end load/save/reload case when provider behavior
   changes.
5. Run `AllTestsRunner`, then a clean server/client bootstrap.
6. Exercise a copy of real representative data only in the dedicated
   integration Experience, never against the production DataStore.
7. Deploy the migration manifest and `VersionConfig.CurrentVersion` together.
8. Monitor load failures and lock-release diagnostics before removing support
   for any retained checkpoint.
