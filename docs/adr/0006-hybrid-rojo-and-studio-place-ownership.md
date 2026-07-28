# ADR-0006: Track one canonical Studio place alongside partial Rojo source

- Status: Accepted
- Date: 2026-07-28
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

The project synchronizes reusable scripts and selected Instance properties
through Rojo, but it does not yet represent the complete Studio scene as text
or model source. Maps, models, and other unmanaged scene Instances therefore
exist only in a Roblox place file.

Ignoring that place would make scene changes local to one developer. Treating a
source-only Rojo build as the complete project would discard unmanaged scene
data. The public repository is also intended to remain usable as a GitHub
template, where Git LFS objects are not supported.

## Decision

Track `template_place.rbxl` in ordinary Git as the single canonical Studio
place while partial Rojo synchronization is active.

Use `src/` and `default.project.json` as the source of truth for everything
described by Rojo. Use the tracked place as the source of truth only for
Studio-authored scene data outside those mappings. Filesystem-backed mappings
set `$ignoreUnknownInstances` to `true` so live sync preserves unmanaged
children.

Treat scene editing as a serialized team operation because Git cannot merge
binary place files. Make scene changes through Roblox Studio, never by
programmatically patching the binary.

## Alternatives considered

### Ignore the local place

Rejected because unmanaged scene changes would not reach collaborators or
repositories created from the template.

### Store the place with Git LFS

Rejected while this is a GitHub template repository because template
repositories cannot include Git LFS files.

### Use Team Create as the canonical scene

Deferred. It can support concurrent scene authoring, but would make a cloud
experience an additional operational dependency and would not package the
canonical scene into the public template repository.

### Represent the complete place through Rojo

Preferred as a possible future direction, but not adopted until all required
scene data has a reviewed, reproducible source representation.

## Consequences

### Positive

- Every repository clone and template-derived project receives the scene.
- Rojo-managed code remains reviewable and reproducible as text.
- Live sync does not delete unmanaged scene children.

### Negative

- Binary scene changes cannot be meaningfully diffed or automatically merged.
- The team must coordinate and serialize place edits.
- Source-only Rojo builds are validation artifacts, not complete scene builds.

## Enforcement

- Agent rules: `.agents/rules/rojo-project.md`
- Current documentation: `README.md`
- Code boundaries: `default.project.json`, `src/`, `template_place.rbxl`
- Tests: Rojo validation build, Git ignore/tracking checks, clean Studio Play
