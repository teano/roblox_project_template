# Architecture decision records

ADRs preserve durable decisions that materially affect several systems or
future template/derived-project compatibility. Routine edits and ordinary
template updates do not require an ADR.

| Namespace | Index | Owner |
|---|---|---|
| Template | [template/README.md](template/README.md) | Reusable template |
| Project | `project/README.md` | One derived game, when it needs ADRs |

Template ADRs are upstream history and must not be edited by a derived project.
A derived project may create `docs/adr/project/` for its own durable decisions;
the template intentionally does not track that directory. Namespace numbering
is independent, so use `template/ADR-####` or `project/ADR-####` when an ID is
ambiguous.

Before changing an active durable decision, read the relevant Accepted ADRs in
the owning index. Accepted bodies remain historical: add a new ADR that
supersedes the old decision and update only status metadata and the owning
index. Copy [_template.md](_template.md) as a starting point. Do not create an
ADR merely to explain a local path conflict; the atomic template updater and
normal review own that decision at update time.
