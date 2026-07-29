# Architecture decision record rules

## Scope

Apply when reading, creating, superseding, indexing, moving, or reviewing an
architecture decision record.

Required context: `docs/adr/README.md` and the relevant Accepted ADRs selected
from every index that exists for the current repository.

## Repository roles

The reusable template and a derived game have different ADR ownership:

- The template owns `docs/adr/README.md`, `docs/adr/_template.md`,
  `docs/adr/template/`, and `docs/adr/template/README.md`.
- A derived game owns `docs/adr/project/`, including its own `README.md` index
  and numbered project ADRs.
- The template repository MUST NOT contain `docs/adr/project/`.
- A derived game MUST NOT edit template ADRs, the template index, or the
  top-level router.

## Reading workflow

Before an architectural change:

1. Read `docs/adr/README.md`.
2. Read `docs/adr/template/README.md` and every relevant Accepted template ADR.
3. In a derived repository, read `docs/adr/project/README.md` and every relevant
   Accepted project ADR.
4. Report architectural drift when ADRs, higher-precedence agent rules, current
   documentation, code, or tests disagree.

Local edits that preserve architecture do not require reading unrelated ADRs.

## Writing workflow

- Template decisions use `docs/adr/template/NNNN-short-title.md` and update
  only `docs/adr/template/README.md`.
- Game decisions use `docs/adr/project/NNNN-short-title.md` and update only
  `docs/adr/project/README.md`.
- Both namespaces allocate independent four-digit sequences starting at
  `0001`; never reuse a removed or rejected number.
- Use `docs/adr/_template.md` as the document structure.
- Write decisions in present tense and link rules, current documentation, code
  boundaries, and tests under `Enforcement`.
- Never add numbered ADR links to `docs/adr/README.md`.

## Lifecycle and supersession

Accepted ADR bodies are historical records. Do not materially rewrite one
after its decision changes. Create a new ADR in the same owning namespace,
record the old decision under `Supersedes`, update the old status metadata, and
update only that namespace's index.

A derived game may locally supersede a template decision only with a new
project ADR plus explicit updates to applicable higher-precedence project
rules, current documentation, and tests. The original template ADR and its
index remain untouched.

## Project namespace initialization

If `docs/adr/project/README.md` is absent in a derived repository, do not invent
an ad-hoc ADR location. Follow `project-initialization.md`, which creates the
project index and initial `0001` decision as one atomic setup change.

## Verification

- `scripts/validate-repository-layout.ps1`.
- Confirm every numbered ADR is referenced by its owning index.
- Confirm the top-level router contains no numbered decision index.
