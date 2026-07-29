# ADR-0010: Use ADR-grounded upstream merges and preserve the project place

- Status: Accepted
- Date: 2026-07-29
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Derived games periodically receive changes from the reusable template. Clean
template changes should arrive without manual reimplementation, but games may
also intentionally modify files originally supplied by the template. A future
merge cannot safely infer why those local changes exist from a textual conflict
alone.

The canonical `place.rbxl` is binary and becomes game-owned after initial
project creation. Git may replace it with a newer template version without
raising a conflict when only upstream changed it, which would silently discard
the game's intended scene baseline.

## Decision

Apply incoming template text files as delivered when the derived project has no
local change on those paths.

Every intentional project modification to a template-owned path must be
recorded in a project ADR. The ADR names the exact paths, upstream baseline,
project invariant, future merge policy, and removal condition. An upstream
merge inspects those ADRs before resolving any path changed both locally and by
the template. If the ADR and implementation do not establish a safe durable
resolution, the merge stops for user direction.

During the first import into an empty project, accept the template
`place.rbxl`. After initialization, preserve the project's complete pre-merge
`place.rbxl` on every template update, regardless of whether Git reports a
binary conflict. Template scene changes are ignored unless they are manually
replayed through Roblox Studio as a separate authorized project change.

Every completed upstream merge reports the template commit range, cleanly
applied files or systems, preserved project files, ADR-guided resolutions,
conflicts, and verification results.

## Alternatives considered

### Always prefer template files

Rejected because it discards intentional game behavior and configuration.

### Always prefer project files

Rejected because games would silently stop receiving fixes and architectural
improvements from the template.

### Resolve conflicts only from the current diff

Rejected because a diff shows what changed but not the invariant or future
merge policy that motivated the project divergence.

### Accept upstream place when Git reports no conflict

Rejected because conflict-free binary replacement can still overwrite the
game's canonical scene.

## Consequences

### Positive

- Clean template fixes apply without project-side reimplementation.
- Intentional divergences remain traceable and reviewable.
- Future agents can resolve overlapping changes from explicit project context.
- Project scenes cannot be silently replaced by template updates.
- Merge reports expose exactly what happened to the user.

### Negative

- Changing template-owned code requires project ADR maintenance.
- Upstream merges require a deliberate pre-merge path intersection review.
- Ambiguous undocumented divergences block automation and require user input.
- Desired template scene changes must be replayed manually in Studio.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/template-updates.md`,
  `.agents/rules/architecture-decisions.md`,
  `.agents/rules/project-initialization.md`,
  `.agents/rules/rojo-project.md`
- Current documentation: `README.md`, `docs/adr/README.md`
- Code boundaries: `place.rbxl`, template-owned paths, `docs/adr/project/`
- Tests: `scripts/validate-repository-layout.ps1`, Rojo validation build,
  affected Studio suites and clean Play checks
