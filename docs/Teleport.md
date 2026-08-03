# Teleport lifecycle

## Boundary

`TeleportModule` is the server-authoritative boundary for teleport session
continuity inside one Roblox Experience. An external arrival receives a new
canonical GUID. A target arrival continues a GUID only when the official
`SourcePlaceId`, the module envelope source, the allowed-place policy, and the
arriving user's envelope entry all validate.

The identifier is client-visible correlation data. It is not a credential and
must never authorize currency, progress, inventory, rewards, or other
protected state.

`PlayersModule` remains the only wrapper that subscribes directly to Roblox
player arrival and removal. `TeleportModule` observes that wrapper and owns
only its session and active-attempt records. It does not persist them.

## Public services

The server manifest exposes `Services.Teleport` with:

```lua
GetSession(player)
GetAttempt(player)
Teleport(players, destination)
```

Destinations are explicit `Public`, `ServerInstance`, `ReservedServer`, or
`NewReservedServer` values. The complete dense group and destination are
validated before any attempt is installed. Project composition must explicitly
allow every source and destination place. The template policy allows exactly
PlaceIds `91045933836846` and `101736951773632` when the running DataModel has
`GameId=10596427617`. Any other Experience remains current-place-only, so a
derived game cannot inherit the template's cross-place trust boundary. An
unpublished local DataModel with `game.PlaceId=0` and `game.GameId=0` receives
an empty inert policy: Teleport sessions and client projection still
initialize for clean local Play, but every teleport destination is rejected
before a platform call. A mixed zero/nonzero DataModel identity fails closed
during policy construction instead of being treated as either published or
unpublished.

The client manifest exposes a read-only `Services.Teleport` projection with:

```lua
GetLocalArrival()
GetLocalAttempt()
GetPresentPlayers()
```

It owns subscribable `LocalArrived`, `LocalAttemptStarted`,
`LocalAttemptAccepted`, `LocalAttemptFailed`, `PlayerAppeared`, and
`PlayerDeparted` side-local signals. `ProjectionReconciled` fires after every
successful bootstrap or recovery snapshot has atomically replaced the complete
projection. Its subscribers re-read `GetLocalArrival()`, `GetLocalAttempt()`,
and `GetPresentPlayers()`; it does not replay lifecycle transitions that may
have been lost. Subscriptions are optional and do not affect authoritative
state transitions.

## Optional published validation pad

The server manifest also composes `TeleportValidationPad` after `Players` and
`Teleport`. It is an operator-only physical surface for a published two-place
validation loop, not a reusable gameplay destination policy. The reusable
template injects `TeleportValidationConfig` with `Enabled=false`, `GameId=0`,
and empty route/tester maps. In this default state the controller does not
observe players and does not create a `Workspace` object.

An operator temporarily enables the controller with one exact positive GameId,
directed source-to-destination PlaceId routes, and a positive-UserId boolean
allowlist. The controller validates the complete immutable configuration,
rejects any unknown outer field, and fails closed unless the running DataModel
matches that GameId and one source route. Only while an allowlisted tester is present does it create a visible,
anchored, touch-enabled Part at runtime. It selects a nearby `SpawnLocation`
through a deterministic bounded traversal and uses a fixed bounded fallback
when no spawn is found. The label names the configured destination PlaceId.

Collision resolves the character through `PlayersModule` and invokes the
public server `Services.Teleport:Teleport` facade with one `Public`
destination. One attempt is latched per authorized presence to prevent touch
re-entry while `TeleportAsync` yields. When several allowlisted testers overlap,
the lowest present UserId owns the pad regardless of observer delivery order;
arrival or removal reconciles that owner and replaces the runtime pad when
needed. Arrival into the other place and repeated `Stop` otherwise destroy or
recreate the runtime pad deterministically.
The controller creates no RemoteEvent, logs no session or attempt identifiers,
and never modifies `place.rbxl` or another canonical scene object.

Validation configuration never expands `TeleportPolicy`; both boundaries must
independently allow the destination. Follow [TeleportTesting.md](TeleportTesting.md)
to configure template or derived-project identities, publish both endpoints,
run forward/return and rapid-repeat Roblox-client checks, and restore
`Enabled=false` afterward.

## Attempt lifecycle

```text
validate whole group
  → Started per player
  → TeleportAsync
      → synchronous exception: Failed per player, session preserved
      → return: Accepted per player (not target arrival)
          → correlated failure received before return: Accepted then Failed
          → correlated TeleportInitFailed: Failed for that player only
          → PlayersModule removal: source departure and local cleanup only
```

One group call shares an attempt ID but keeps separate per-player records.
`TeleportInitFailed` is matched to the active request's `TeleportOptions`, so
a stale platform result cannot terminate a newer request. Removal never
publishes target arrival. Only validated `GetJoinData()` processing on the
target server publishes `Teleported`.

`TeleportAsync` may yield long enough for a matching `TeleportInitFailed` to
arrive before the call returns. The per-player attempt retains the first such
failure while it is `Started`. If the call returns successfully, the module
publishes `Accepted` and then the retained `Failed`, preserving the client
state-machine order and exactly-once terminal delivery. If the call throws,
the synchronous `TeleportRequestFailed` is the only terminal result. Removal,
`Stop`, and a newer attempt retire the old pending failure with the old record.

## Envelope and privacy

The module creates a fresh `TeleportOptions` and writes only:

```lua
{
  TeleportModule = {
    Version = 1,
    SourcePlaceId = game.PlaceId,
    AttemptId = attemptId,
    SessionsByUserId = {
      [tostring(player.UserId)] = sessionId,
    },
  },
}
```

Incoming dictionaries must be plain, bounded, exactly shaped, and contain
canonical GUIDs. Invalid or untrusted continuation fails closed to a new
external session.

The attempt ID is also the correlation token for `TeleportInitFailed`.
Roblox supplies that event with a newly created `TeleportOptions` instance,
not the original object, so object identity cannot safely distinguish a stale
failure from a newer request.

Own lifecycle messages contain the local player's session and attempt data.
Other-player appearance contains only `UserId`, `EntryKind`, and an optional
validated source place; departure contains only `UserId`. Other-player DTOs
never include session IDs, attempts, server selectors, reserved access codes,
or failure details.

## Communication and recovery

All network delivery uses the existing communication module. Own lifecycle
messages use `State`; other-player appearance and departure use
`Presentation`. The client registers handlers during construction, then makes
the bounded `Teleport.Bootstrap` request after communication initialization.
Bootstrap atomically establishes the current local arrival, optional attempt,
and safe current-player appearances. An invalid payload or impossible attempt
transition throws inside the registered handler so communication recovery can
request a fresh baseline.

The later global snapshot generation also includes that complete Teleport
projection. The server captures save and Teleport snapshots before
`BeginSnapshot` clears the old queue. The client validates Teleport first,
applies the save transaction, installs the prepared Teleport projection, and
fires `ProjectionReconciled` only after that complete installation; only then
does it resume the epoch and acknowledge `ClientReady`. The same path runs
after a sequence gap, handler failure, or backpressure resync, so discarded
Started, Accepted, Failed, arrival, or presentation messages cannot leave
either projection state or subscribers on an older baseline. A failed
own-player State queue explicitly requires that recovery.

The bootstrap and recovery validators accept safe appearances up to the
injected `Players.MaxPlayers - 1` peer capacity. This presentation-snapshot
bound is independent of the 50-participant `TeleportAsync` group cap. The
existing complete-response network byte and node limits remain authoritative,
so a capacity-valid but oversized snapshot still fails before `BeginSnapshot`.

`Stop` clears projection and signals and is terminal. Communication handlers
are intentionally registered for the communication object's lifetime, but
their stopped guard makes every later delivery a no-op.

## Verification

Run `TeleportModuleTestRunner` and the aggregate deterministic gates documented
in [TestCoverage.md](TestCoverage.md). A real successful teleport cannot be
proved by ordinary Studio Play; a production-ready verdict also requires a
published Roblox-client multi-place E2E that records the same session GUID on
the target and a supported failure returning the client projection to normal.
