# Domain data rules

## Scope

Apply to Wallet, Version, GameData, new save providers, provider authority,
runtime models, and domain change messages.

## Ownership and authority

- `WalletModule` owns server runtime currency models.
- `VersionModule` owns persisted installation/current-version metadata.
- `GameDataClient` is a read-only facade over client provider caches.
- Save controllers capture and apply mementos but MUST NOT implement domain operations.
- Wallet remains server-authoritative.
- Every new provider MUST declare its authority explicitly.

## Mandatory mutation rules

- Domain operations MUST validate identifiers, values, bounds, and finite/integer requirements.
- A successful mutation MUST update the server runtime model first.
- A real persisted change MUST fire `MementoChanged`.
- A client-visible change MUST enqueue a compact ordered communication message.
- Change payloads SHOULD include provider ID, path, old value, new value, reason, and transaction ID when applicable.
- Client handlers MUST validate payload shape and compare expected old state.
- Client state mismatch MUST fail the handler so Communication initiates resync.
- Returned snapshots and mementos MUST be copies.

## Wallet-specific rules

- Clients MUST NOT send Wallet balances or Wallet mementos.
- Purchase flows send intent to a dedicated server transaction module.
- Spending and granting occur atomically on the server through Wallet APIs.
- Insufficient funds return an explicit failure without mutation or dirty signaling.
- A newly created Wallet memento MUST apply the validated Experience Config
  starting balances exactly once and persist `IsInitialized=true`.
- Existing Wallet mementos that predate `IsInitialized` MUST reconcile as
  already initialized; an upgrade MUST NOT grant existing players a new
  starting balance.
- `IsInitialized` is server persistence state and MUST NOT be included in the
  client Wallet memento.

## Adding a provider

- Define a stable provider ID, provider version, defaults, reconciliation, and
  validation.
- Keep server and client implementations separate when their authority or
  runtime behavior differs.
- Register providers explicitly and in the same intentional order in the
  server and client global-save commands.
- Add the client provider to `GameDataClient` only when client code may read it.
- Create runtime controllers only in `Run`, after every memento in the
  controller has been installed.

## Forbidden patterns

- MUST NOT expose mutable internal domain tables.
- MUST NOT mutate provider data from presentation, save controller, or
  communication transport.
- MUST NOT fire dirty/change signals when the effective value did not change.
- MUST NOT trust client old/new values as authority.
- MUST NOT use full snapshot replacement for ordinary domain events.
- Wallet balances and transaction amounts MUST remain non-negative integers at or below `WalletConfig.MaxBalance`; additions that would overflow that safe-integer boundary MUST fail without mutation.

## Positive example

```lua
local result = walletModule:TrySpend(player, "Coins", price, "Purchase", metadata)
if result.Ok then
	equipmentModule:Grant(player, itemId, "Purchase", metadata)
end
```

The orchestration module owns the transaction; each domain module owns its state.

## Negative example

```lua
saveController.Document.Providers.Wallet.Data.Coins -= price
```

This bypasses the runtime owner, validation, signals, and client synchronization.

## Verification

- Domain validation and boundary tests.
- Save dirty/capture tests.
- Communication ordering/resync tests for client-visible changes.
