# ADR-0039: Allow deterministic audio-only AssetKey first-wins

- Status: Accepted
- Date: 2026-08-07
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

ADR-0013 requires every `AssetKey` visible to one side-owned
`AssetRegistry` to be unique and fails initialization on a duplicate. That is
the correct default for singular static templates. Physical `Sound`
descriptors under `ReplicatedStorage.Assets.Shared.Sounds` also participate in
the SFX catalog, where authoring errors must be diagnosable without disabling
all unrelated assets or gameplay.

Roblox descendant order cannot define a winner, and a global fail-soft policy
would make required singular assets ambiguous. The exception therefore has to
be exact, deterministic, immutable, and incapable of leaking beyond the audio
root.

## Decision

Extend `AssetRegistry` with an explicit manifest-injected duplicate policy for
`AssetKey` collisions only when every colliding candidate:

- is a `Sound`;
- is a descendant of the canonical `Shared/Sounds` catalog path; and
- belongs to the same side-visible immutable startup scan.

The registry derives and validates canonical paths first, sorts candidates by
canonical path using ordinal comparison, and assigns the key index to the
first valid candidate. Later eligible candidates remain addressable by their
unique canonical paths and produce a bounded stable
`CatalogConflictFirstWins` diagnostic. The result is frozen with the rest of
the catalog generation.

Any collision containing a non-`Sound`, a candidate outside `Shared/Sounds`,
or a root/path/name error remains fatal exactly as under ADR-0013. Duplicate
logical paths remain fatal. Cue, Variant, ResourcePath, and generated-row
identifier conflicts belong to the audio catalog validator, not to this
AssetRegistry policy. No consumer may select a winner from raw
`GetDescendants()` order.

## Alternatives considered

### Keep every duplicate audio key fatal

Rejected because one malformed optional descriptor would disable the complete
side asset catalog instead of containing the authoring error to audio lookup.

### Make every duplicate key first-wins

Rejected because required singular templates outside audio would silently
bind to an arbitrary authored candidate.

### Resolve duplicate keys inside each audio consumer

Rejected because consumers would rescan originals, disagree on ordering, and
bypass the immutable AssetRegistry snapshot.

## Consequences

### Positive

- Audio descriptor conflicts are deterministic and fail-soft without
  weakening unrelated asset contracts.
- All sides derive the same winner from canonical paths.
- Losing audio descriptors remain inspectable by path for diagnostics.
- Asset discovery stays one immutable startup operation.

### Negative

- `AssetRegistry` gains one narrowly scoped policy branch and diagnostic.
- Authors must inspect warnings because a losing public audio key is not
  addressable through that key.
- Tests must prove both the exception and the unchanged fatal default.

## Enforcement

- Agent rules: `.agents/rules/audio.md`, `.agents/rules/assets.md`,
  `.agents/rules/architecture.md`, `.agents/rules/initialization.md`, and
  `.agents/rules/testing.md`.
- Current documentation: `docs/AudioSystem.md`, `docs/AssetRegistry.md`, and
  `docs/Features/template/sfx-system/technical-specification.md`.
- Code boundaries: shared `AssetRegistry`, both asset initialization command
  compositions, `ReplicatedStorage.Assets.Shared.Sounds`, and the audio catalog
  resolver.
- Tests: `AssetRegistryTestRunner`, `AudioCatalogTestRunner`,
  `SystemTestRunner`, and clean server/client bootstrap verification.
