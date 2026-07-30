# Experience configuration rules

## Scope

Apply to `ConfigService`, Experience Config keys, config definitions/codecs,
server config snapshots, client bundles/projections, config refresh, and config
delivery through the communication request boundary.

Required context: `docs/ExperienceConfiguration.md`,
`docs/InitializationAndSaveSystem.md`, and template ADR-0017.

## Mandatory rules

- Experience Config values MUST be loaded only by the server-owned
  `ExperienceConfigCatalog`.
- Structured Experience Config values MUST use the native Experience Config
  type `JSON`. A `String` containing serialized JSON is not an equivalent
  configuration value and MUST NOT be used for a JSON config contract.
- Every consumed key MUST have one explicit server manifest definition with a
  stable logical `Id`, Experience Config `Key`, and pure `Decode` function.
- A decode MUST construct and validate a complete candidate before it returns
  success. It MUST NOT partially mutate a published model.
- Startup MUST atomically publish one immutable generation only after every
  required definition, cross-reference, and client projection succeeds.
- A failed refresh MUST preserve the complete last valid generation.
- Client access MUST be deny-by-default and declared in the server-owned
  `ClientBundles` manifest. Experience Config values MUST NOT grant client
  access to other Experience Config values.
- Every client-exposed definition MUST provide an explicit `ToClient`
  projection. Never assume the full server model is safe to disclose.
- Client bundle requests MUST use the bounded synchronous request API owned by
  the communication module. Ordinary runtime mutations remain compact batched
  messages.
- Client bundles MUST fit below `ConfigProtocol.MaxClientBundleEstimatedBytes`.
  Split or reduce projections instead of bypassing communication limits.
- Each client MUST decode a complete bundle into a temporary model and publish
  it atomically as one immutable generation.
- Config authority, client disclosure, codecs, and reload policy belong in
  reviewed code. Tunable values belong in Experience Configs.
- Live refresh MUST be invoked at a domain-safe boundary. Receiving
  `UpdateAvailable` alone MUST NOT mutate active providers.
- Startup-only config consumers such as Wallet initialization and GlobalSave
  scheduling MUST capture one validated catalog generation during
  initialization and MUST NOT silently change active behavior after refresh.

## Forbidden patterns

- MUST NOT call `ConfigService` from domain modules or client code.
- MUST NOT store the client allowlist in an Experience Config.
- MUST NOT accept arbitrary Experience Config keys from a client.
- MUST NOT send a server config to a client without an explicit projection.
- MUST NOT decode the same JSON document into a partially updated published
  object.
- MUST NOT introduce direct gameplay remotes for config delivery.
- MUST NOT put config values in Attributes, ValueObjects, or a place-only JSON
  blob alongside the Experience Config source of truth.
- MUST NOT automatically refresh and replace active domain providers without
  their explicit lifecycle policy.

## Adding a config

1. Add its server definition and pure decoder to
   `ServerConfigManifest.Definitions`.
2. Inject `Services.Config` into the owning initialization composition and
   obtain the immutable model with `GetRequired`.
3. If the client needs data, add a minimal `ToClient` projection, include the
   logical config ID in one server-owned bundle, and add the matching client
   decoder.
4. Keep secret, authority, anti-cheat, and server-only fields out of the client
   projection.
5. Add focused tests for missing fields, wrong types, unknown values,
   projection disclosure, size, and atomic refresh behavior.

## Verification

- `ConfigCatalogTestRunner`.
- `SystemTestRunner`.
- `ProductionIntegrationTestRunner` when request transport changes.
- Clean server/client bootstrap with configured Experience Config values.
- Rojo build and repository layout validation for architecture or manifest
  changes.
