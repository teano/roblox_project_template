# ADR-0017: Use a server-owned Experience Config catalog with explicit client projections

- Status: Accepted
- Date: 2026-07-30
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Gameplay systems need complex designer-authored configuration without storing
parallel representations in ModuleScripts, Attributes, ValueObjects, and JSON
blobs. Roblox Experience Configs provide structured values, staged publishing,
history, and live updates, but `ConfigService` is server-only and does not
validate project-specific schemas.

Most configuration is server-only. Some clients need a safe subset during
bootstrap. Letting clients submit arbitrary Experience Config keys, or storing
the client allowlist in another mutable Experience Config, would make a data
editing mistake a disclosure-policy change. Sending whole server documents
would also expose fields that a client does not need.

The existing batched RemoteEvent transport waits until the initial save
snapshot establishes `ClientReady`. A client domain provider may need config
before that snapshot, so waiting for a normal batched response would deadlock
bootstrap.

## Decision

Use one server-owned `ExperienceConfigCatalog`. It obtains a `ConfigSnapshot`
once, reads only definitions from an explicit server manifest, invokes pure
domain codecs, and atomically publishes an immutable generation after every
required definition succeeds.

Keep client disclosure in reviewed server code. A client requests a named
bundle, never an Experience Config key. Every exposed definition supplies an
explicit `ToClient` projection. The server prevalidates and caches the complete
bundle, and the client applies matching codecs before atomically publishing
its own immutable generation.

Add one bounded synchronous request API to the communication module for
server-read startup boundaries. It owns the RemoteFunction, registered request
types, serialization validation, response-size enforcement, and per-player
request/byte rate limits. Ordinary runtime mutations and notifications remain
compact batched messages under ADR-0004.

Treat `UpdateAvailable` as a notification only. Refresh constructs and
validates a complete candidate generation. A failed refresh preserves the last
valid generation, and domains choose their own safe application boundary.

## Alternatives considered

### Attributes and ValueObjects

Rejected as the primary representation because complex structures require a
second format, names and types remain manually mutable, and project schemas
cannot be enforced before runtime without an additional contract.

### JSON StringValues in the place

Rejected because they retain mutable Instance paths, move configuration into a
binary place source, produce poor Git review, and duplicate Experience Config
publishing.

### Experience Config client allowlist

Rejected because a tunable value must not grant access to other server values.
Disclosure policy is code-reviewed and deny-by-default.

### Let clients request arbitrary keys

Rejected because key validation becomes an externally controlled namespace,
enables enumeration, and makes accidental overexposure easier than named
bundles.

### Send normal batched messages during bootstrap

Rejected because server batches intentionally wait for `ClientReady`, while
client config is needed before domain and save initialization. The bounded
request boundary resolves this ordering without weakening runtime message
rules.

## Consequences

### Positive

- Tunable values have one Experience Config source of truth.
- Domain codecs own structure, validation, and typed model construction.
- Missing, malformed, or partially updated data never becomes visible.
- Client access is explicit, minimal, and code-reviewed.
- Server and client consume immutable generation snapshots.
- Live refresh preserves the last valid generation on failure.

### Negative

- Projects must maintain server definitions, projections, and matching client
  codecs.
- Client-visible data must fit below the communication request response limit.
- Experience Config values are not intrinsically tied to a Git commit.
- Domains must explicitly decide when a valid refreshed generation may replace
  active provider configuration.
- The communication module gains a second transport shape whose use must
  remain limited to synchronous server-read boundaries.

## Enforcement

- Agent rules: `.agents/rules/configuration.md`,
  `.agents/rules/communication.md`, `.agents/rules/initialization.md`,
  `.agents/rules/architecture.md`, and `.agents/rules/testing.md`.
- Current documentation: `docs/ExperienceConfiguration.md` and
  `docs/InitializationAndSaveSystem.md`.
- Code boundaries: shared config protocol, server and client config manifests,
  `ExperienceConfigCatalog`, `ClientConfigCatalog`, both config initialization
  commands, and the bounded request API in both communication modules.
- Tests: `ConfigCatalogTestRunner`, `SystemTestRunner`,
  `ProductionIntegrationTestRunner`, Rojo validation build, and clean
  server/client bootstrap.
