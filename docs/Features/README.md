# Feature records

Feature records are optional, lightweight context for work that benefits from a
stable identifier. They are not an execution gate, branch reservation, lease,
or generated dashboard.

| Namespace | Location | Owner |
|---|---|---|
| Template | [template/](template/) | Reusable template |
| Project | `project/` | One derived game |

The template tracks only `docs/Features/template/`. A derived project may
create and own `docs/Features/project/`; inherited template history remains
read-only. Current records use only `open` or `done`. Use
`scripts/feature.ps1` for new records, status, and closure. Ordinary edits do
not require a feature record.

Legacy manifests, worklogs, handoffs, PRDs, and specifications remain history.
When a legacy manifest is migrated, the tool keeps its exact original bytes in
a sidecar and does not rewrite the foreign template namespace in a derived
project.
