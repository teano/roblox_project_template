# Teleport lifecycle rules

## Scope

Apply to `TeleportModule`, `TeleportClient`, teleport session identifiers,
arrival envelopes, destination policy, `TeleportService`, attempt lifecycle,
and teleport presentation messages.

Required context: `docs/Teleport.md`, `docs/TeleportTesting.md`,
`docs/Communication.md`, and `docs/InitializationAndSaveSystem.md`.

## Mandatory rules

- The server `TeleportModule` MUST be the only authority that creates or
  continues teleport session IDs and initiates supported teleports.
- A session ID is correlation data visible to clients, never proof of
  entitlement, progress, currency, or other protected state.
- Continuation MUST require a canonical session GUID for the arriving user,
  an official positive `joinData.SourcePlaceId`, an exact matching envelope
  source, and an explicit allowed-place policy entry.
- `TeleportModule` MUST consume arrival and removal only through the server
  `PlayersModule`; it MUST NOT subscribe to `Players.PlayerAdded` or
  `Players.PlayerRemoving`.
- Every group teleport MUST install and transition a separate attempt record
  for each player after validating the complete group atomically.
- `TeleportAsync` return means only platform acceptance. Only validated target
  arrival may publish `Teleported`; acceptance and source removal MUST NOT
  synthesize target arrival.
- A correlated `TeleportInitFailed` received while `TeleportAsync` is still
  yielding MUST be retained per player. A successful return publishes
  `Accepted` before exactly one `Failed`; a synchronous exception publishes
  only its synchronous failure. Removal, Stop, stale results, and replacement
  attempts MUST retire the pending result without affecting newer state.
- Synchronous and late failures MUST preserve the player's current session.
  A late failure MUST be correlated to the active request by the module-owned
  envelope attempt ID and MUST NOT end a newer request; Roblox does not return
  the original `TeleportOptions` object in `TeleportInitFailed`.
- Own lifecycle DTOs MUST use `State` priority. Other-player appearance and
  departure DTOs MUST use `Presentation` priority and exclude session IDs,
  attempt details, selectors, access codes, and failure details.
- Client handlers MUST register before bootstrap, validate complete payloads,
  enforce prior attempt state, and throw on impossible transitions so the
  communication boundary can recover by resync.
- Teleport client state MUST be included in every initial and recovery global
  snapshot generation. The server MUST capture it before `BeginSnapshot`, and
  the client MUST validate and apply it before communication resumes.
- Every successful Teleport snapshot replacement MUST publish the client-local
  `ProjectionReconciled` signal only after the complete projection is installed;
  subscribers MUST re-read all required getters instead of treating missed
  lifecycle messages as replayed transitions.
- The present-player snapshot bound MUST follow the explicitly injected
  `Players.MaxPlayers` capacity. It MUST remain independent of the platform
  teleport-group cap of 50 participants and the complete response MUST still
  pass the communication snapshot network bound.
- A failed own-player State queue MUST explicitly require communication
  resync; clearing or collapsing a queue MUST NOT leave Teleport projection on
  an older baseline.
- `TeleportClient:Stop()` MUST be terminal. Retained communication callbacks
  MUST ignore all later delivery and MUST NOT repopulate cleared projection.
- Removal and shutdown cleanup MUST be idempotent and MUST NOT emit duplicate
  terminal attempt results.
- Each additional source or destination place MUST be explicitly added by
  project composition. The template default policy permits exactly PlaceIds
  `91045933836846` and `101736951773632` only while `game.GameId` is exactly
  `10596427617`; every other Experience remains current-place-only.
- An unpublished DataModel is inert only when both `game.PlaceId` and
  `game.GameId` are zero. A mixed zero/nonzero identity MUST fail closed before
  Teleport policy construction.
- The physical validation trigger MUST be disabled by default in the reusable
  template. Its server-only configuration MUST default to `Enabled=false`, a
  non-authoritative GameId, and empty route/tester maps. Disabled, invalid,
  incomplete, inherited, or current-DataModel-mismatched configuration MUST
  fail closed before player observation, scene mutation, or a Teleport call.
- An enabled validation configuration MUST be an exact plain dictionary with
  only `Enabled`, `GameId`, `RoutesBySourcePlaceId`, and `AuthorizedUserIds`;
  unknown fields are rejected rather than retained as an implicit fallback.
- An explicitly enabled validation trigger MUST use directed positive
  source-to-destination PlaceId routes and a positive-UserId boolean allowlist.
  It MUST create its physical surface only at server runtime while an
  allowlisted tester is present, target only the current source's configured
  destination through the public `Services.Teleport:Teleport` contract,
  consume presence and character lookup through `PlayersModule`, debounce
  re-entry, select the lowest present authorized UserId deterministically when
  several testers overlap, and clean up idempotently. It MUST NOT expand `TeleportPolicy`, add
  a canonical scene object, standalone Script, direct remote, session
  diagnostic, or broader identity fallback.
- Published validation MUST follow `docs/TeleportTesting.md`. The operator MUST
  verify exact cloud identity, configure both the production Teleport policy
  and the independent validation harness, use ordinary Publish, run forward,
  return, and rapid-repeat Roblox-client checks, then restore and publish the
  disabled configuration. A secondary project used only as the endpoint is not
  a release-readiness target for the primary template.

## Forbidden patterns

- MUST NOT treat `TeleportAsync`, `PlayerRemoving`, or `Player.OnTeleport` as
  proof of successful target arrival.
- MUST NOT accept caller-owned `TeleportOptions` or arbitrary `TeleportData`.
- MUST NOT use legacy teleport APIs, automatic retry, direct gameplay remotes,
  DataStore persistence, or a save provider for the base teleport lifecycle.
- MUST NOT publish another player's session ID, attempt ID, destination
  selector, access code, or failure details.

## Verification

- `TeleportModuleTestRunner`.
- `SystemTestRunner`, `ProductionIntegrationTestRunner`,
  `ProductionReadinessTestRunner`, and `AllTestsRunner`.
- `scripts/validate-repository-layout.ps1` static boundary checks.
- Clean server/client bootstrap in the exact selected Studio instance.
- A published Roblox-client multi-place E2E before a production-ready verdict;
  ordinary Studio Play does not satisfy this evidence gate.
