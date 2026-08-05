# ADR-0035: Collect statistics in server-owned bounded snapshots

- Status: Accepted
- Date: 2026-08-04
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

The template had server-authoritative Wallet and generic save infrastructure,
but no reusable owner for gameplay statistics. Projects otherwise had to mix
facts into unrelated domain state, expose broad profile snapshots, or build
incompatible counters without a shared lifecycle, retention, deduplication,
Teleport-continuity, or size policy.

Statistics need several lifetimes at once. Profile-wide facts outlive servers,
Session facts must follow only the trusted server-owned Teleport session, Place
facts end on each visit, and project-defined lifetimes such as rounds require
explicit ownership. The persisted representation may contain private facts and
deduplication cursors that must never enter the ordinary client save snapshot.

Wallet facts also require a precise commit boundary. Observing asynchronous
signals after a balance change can lose ordering or race final profile close,
while replaying persisted balances would incorrectly count startup state as new
earnings.

## Decision

Add one server-authoritative `Statistics` provider and domain module. It owns
all statistic runtime data and persists bounded `Global`, `Session`, `Place`,
and configured custom snapshot records. Snapshot IDs increase monotonically per
type. Creation metadata and filter policy are copied into each record, history
is creation ordered and retention bounded, and every operation validates one
complete candidate before committing values and deduplication state.

`TeleportModule:GetSession()` is the only source of Session continuity.
Profile close moves the current Session to a private pending slot; a target
continues it only when the trusted session ID matches. Place always closes and
restarts for the selected DataModel.

The provider sets `ClientSnapshotPolicy = "Omit"`. Clients receive no
Statistics provider envelope. Two bounded read requests expose only configured
projections of current built-in snapshots. Project client facts are available
only through exact code-reviewed definitions; the reusable template declares
none and offers no generic mutation endpoint.

Add a synchronous Wallet committed-change registration boundary. Wallet
provider version 3 persists a monotonically increasing transaction sequence.
Positive committed deltas produce ordered `Wallet.<Currency>.Earned` facts
before asynchronous signals and network delivery; starting balances and
spending do not produce earned facts.

Extend the generic save controller with explicit client snapshot omission and
a full close capture. Dirty capture advances revision only when the captured
provider envelope differs. Extend autosave with per-controller/player
coalesced requested saves so Statistics can request persistence without
creating unbounded writes.

The required server-only `statistics_config` Experience Config owns snapshot
types, retention, filters, public projections, byte/count limits, and requested
save cooldown. Code-owned hard caps and theoretical provider-capacity checks
bound every accepted policy.

## Alternatives considered

### Store counters in Wallet or a monolithic profile table

Rejected because Wallet owns balances, while a mutable profile object would
bypass the template's domain-owned provider boundary and make independent
lifecycles, validation, and rollback difficult.

### Replicate the complete Statistics provider through global save snapshots

Rejected because private facts, Session identity, closed history, filters, and
deduplication state are not client contracts. A small explicit projection is
safer and independently bounded.

### Derive Wallet earnings from stored balances or asynchronous signals

Rejected because balances do not encode transaction intent, startup values are
not earnings, and asynchronous delivery can race save and close boundaries.

### Continue Session statistics from client-provided Teleport data

Rejected because clients are not authoritative for session continuity. The
existing trusted Teleport session contract already owns that decision.

## Consequences

### Positive

- Projects receive one persistence-safe API for multiple statistic lifetimes.
- Operation and deduplication state commit atomically under explicit limits.
- Teleport continuity and Wallet facts have deterministic server-owned
  identities.
- Clients see only reviewed current-state projections and have no generic
  mutation surface.
- Requested saves and final close capture do not create write storms or lose
  late facts.

### Negative

- Every Experience must publish a valid native-JSON `statistics_config` before
  bootstrap can succeed.
- Wallet provider version increases and persists an additional sequence field.
- Derived projects must retain stable custom snapshot type IDs or explicitly
  migrate persisted Statistics data.
- The conservative theoretical budget may reject policies whose typical data
  would fit but whose allowed maximum would not.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/save-system.md`,
	`.agents/rules/domain-data.md`, `.agents/rules/communication.md`,
	`.agents/rules/teleport.md`
- Runtime: `StatisticsModule`, `StatisticsValidation`,
  `StatisticsRequestController`, `StatisticsClientFactController`,
  `WalletStatisticsController`, `ServerSaveController`, `AutoSaveModule`
- Composition: server/client manifests and Statistics initialization commands
- Configuration: `ServerConfigManifest`, `StatisticsConfigCodec`
- Documentation: `docs/Statistics.md`,
  `docs/ExperienceConfiguration.md`,
  `docs/InitializationAndSaveSystem.md`
- Tests: `StatisticsTestRunner`, `ConfigCatalogTestRunner`,
  `SystemTestRunner`, `ProductionIntegrationTestRunner`, and `AllTestsRunner`
