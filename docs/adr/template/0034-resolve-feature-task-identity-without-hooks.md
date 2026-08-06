# ADR-0034: Resolve feature task identity without repository hooks

- Status: Accepted
- Date: 2026-08-04
- Deciders: Project maintainers
- Supersedes: ADR-0033
- Superseded by: ADR-0036

## Context

ADR-0033 separates template and project feature registries, while the feature
lifecycle inherited ADR-0032's dependency on repository-scoped Codex
`SessionStart` and `PreToolUse` hooks. A checkout could contain the correct
workflow but still fail every state transition when its local Codex
installation had not trusted or activated those hooks. This made a repository
configuration step, rather than the active agent and deterministic lifecycle
command, responsible for starting feature work.

Codex already provides the current task UUID to commands through the process
environment. Requiring a hook to copy the same value into a command argument
adds configuration, trust, matching, and shell-rewrite failure modes without
strengthening feature ownership. Allowing an agent to type an arbitrary task
argument would avoid the hook but would permit guessed or stale identity.

## Decision

Keep ADR-0033's separate feature-state namespaces and one shared lifecycle
engine:

- `docs/Features/template/` remains the template-owned `TF-####` registry;
- `docs/Features/project/` remains the derived-game-owned `PF-####` registry;
- branch reservation and writer exclusion continue across every visible
  namespace.

Remove repository-scoped Codex hooks from the feature workflow. Every
state-changing lifecycle action reads and validates the app-provided
`CODEX_THREAD_ID` directly inside `scripts/feature-workflow.ps1`. The public
command has no `-SessionId` parameter, and agents must not invent or override
the app-provided identity. A missing or malformed value fails before feature
state or writer leases are mutated. Read-only `Context` remains available
without task identity.

Skills recover startup and continuation context explicitly from canonical
feature artifacts, Git, rules, ADRs, and targeted task history. The repository
does not install Codex or Git hooks for feature lifecycle behavior.

## Alternatives considered

### Keep repository hooks and improve setup instructions

Rejected because feature availability would still depend on per-checkout trust
and activation outside the repository's deterministic command contract.

### Let the agent pass `-SessionId`

Rejected because a public identity argument can be guessed, copied from stale
history, or accidentally bound to the wrong task.

### Remove task ownership and writer leases

Rejected because sequential task history, active-writer exclusion, pause and
continue ownership, and safe stale-lease recovery remain required.

## Consequences

### Positive

- Feature commands work in a normal Codex task without repository-hook trust
  or restart steps.
- Task identity has one app-owned source and cannot be supplied through the
  public lifecycle command.
- Derived projects inherit fewer local configuration and shell-matching failure
  modes during template updates.

### Negative

- State-changing feature commands cannot run outside an app context that
  provides `CODEX_THREAD_ID`.
- Automated tests must provide isolated app-style task UUIDs through their
  process environment.
- Agents must request context explicitly instead of receiving automatic
  session-start feature reminders.

## Enforcement

- Agent rules: `AGENTS.md`, `.agents/rules/feature-workflow.md`
- Current documentation:
  `docs/Features/template/feature-workflow/product-requirements.md`,
  `docs/Features/template/feature-workflow/technical-specification.md`
- Code boundaries: `.agents/skills/feature-*`, `.codex/config.toml`,
  `scripts/feature-workflow.ps1`
- Tests: `scripts/tests/feature-workflow.tests.ps1`,
  `scripts/validate-feature-workflow.ps1`,
  `scripts/validate-repository-layout.ps1`
