# Architecture decision records

## When to use an ADR

Create or supersede an ADR only for a durable decision about ownership,
authority, lifecycle, persistence, synchronization, public contracts, or a
deliberate reversal of a prior decision. Routine fixes, local implementation
choices, project creation, and ordinary template divergences do not require an
ADR.

When an ADR is needed, read `docs/adr/README.md`, the owning index, and only the
relevant decisions. Do not read the complete history for an unrelated edit.

## Ownership

- The reusable template owns `docs/adr/README.md`, `docs/adr/_template.md`, and
  `docs/adr/template/**`.
- A derived game may create and own `docs/adr/project/**` when it has its first
  durable game-specific decision.
- A derived game never edits template ADRs or the template index.
- The template never adds project ADR files.

The two namespaces allocate independent four-digit IDs. Use the owning
`README.md` as its index and `docs/adr/_template.md` as the document shape.

## Supersession

Accepted ADR bodies are historical records. When an active decision changes:

1. create a new ADR in the same owning namespace;
2. name only the still-active decisions it supersedes;
3. update the old records' status metadata and `Superseded by` field without
   rewriting their reasoning;
4. update only the owning index.

Do not claim to supersede an ADR that is already superseded. A derived project
may locally choose a different durable policy with a project ADR while leaving
template history unchanged.

## Template updates

Project ADRs are optional context, not merge authorization. The updater
preserves `docs/adr/project/**` when it exists, while Git handles ordinary
non-overlapping divergence. A real unresolved conflict is reported for a
focused decision; it is not solved by requiring an ADR for every touched path.

## Verification

- Confirm the new ADR is linked from the owning index.
- Confirm every newly superseded ADR was active immediately before the change.
- Confirm historical bodies changed only in status metadata.
- Run link/reference checks and `git diff --check` for documentation-only ADR
  work. Run executable checks only when the decision accompanies executable
  changes.
