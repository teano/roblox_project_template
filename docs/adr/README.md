# Architecture decision records

This file routes architecture decisions without making template updates and
game-specific work share an index.

## Decision namespaces

| Namespace | Index | Owner |
|---|---|---|
| Template | [template/README.md](template/README.md) | Reusable upstream template |
| Project | `project/README.md` | The derived game repository |

Template ADRs describe durable constraints shipped by the reusable template.
Derived repositories receive them from `upstream` and must not edit their files
or index.

Project ADRs describe decisions made by one game. The template intentionally
contains no `project/` directory or project ADR files. During mandatory
derived-project initialization, the agent creates `project/README.md` and the
initial project ADR by following
[`project-initialization.md`](../../.agents/rules/project-initialization.md).
Those files belong only to the derived repository; the template never tracks
or updates them.

The namespaces have independent four-digit numbering. Refer to an ambiguous ID
as `template/ADR-0001` or `project/ADR-0001`.

## Reading policy

Before an architectural change:

1. Read this router.
2. Read the template index and every relevant Accepted template ADR.
3. If `project/README.md` exists, read the project index and every relevant
   Accepted project ADR.

If an ADR conflicts with current agent rules, code, tests, or system
documentation, report the drift instead of silently choosing whichever version
is easier to implement.

## Writing policy

- Template maintainers add template ADRs only under `template/` and update only
  `template/README.md`.
- Derived projects add game ADRs only under `project/` and update only
  `project/README.md`.
- Never index numbered decisions in this router.
- Copy `_template.md` into the owning namespace.
- Allocate the next four-digit number within that namespace and never reuse a
  removed or rejected number.
- Accepted ADR bodies remain historical. Reverse a decision with a new ADR in
  the owning namespace.
- A project may locally supersede a template decision without editing template
  history. Its project ADR must identify the template ADR and update applicable
  higher-precedence project rules, current documentation, and tests.
- Every intentional modification to a template-owned path must be recorded in
  a project ADR with the exact path, upstream baseline, project invariant, and
  future merge policy.
