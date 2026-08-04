# Derived-project initialization rules

## Scope

Apply once, before the first source change in a repository created from this
template. A repository is derived when it has an `upstream` remote pointing to
the template. It is initialized when `docs/adr/project/README.md` exists and
the checklist below has been completed.

Required subsystem rules: `architecture-decisions.md`, `rojo-project.md`,
`domain-data.md`, `save-system.md`, `communication.md`, and `testing.md`.

## Bootstrap from a target repository URL

When the user asks to create or initialize a project from this template and
supplies the target repository URL, that single request authorizes the normal
end-to-end bootstrap within the named target: clone/fetch, configure remotes,
initialize project-owned files, verify, create the initialization commit, and
push it to the target `origin`. It does not authorize deleting existing work,
replacing an unrelated repository, force-pushing, publishing a Roblox
experience, or enabling production DataStore access.

Use this procedure:

1. Treat the supplied URL as the derived project's `origin`.
2. Derive the local directory from the repository URL without its trailing
   `.git`, unless the user supplied an explicit destination.
3. Resolve and inspect the destination before writing. Refuse to overwrite a
   non-empty directory that belongs to another repository.
4. Inspect the target remote before choosing a history strategy.
5. For an empty target remote:
   - clone `https://github.com/teano/roblox_project_template.git` into the
     destination;
   - rename the cloned `origin` remote to `upstream`;
   - add the supplied target URL as `origin`;
   - continue with Mandatory initialization before the first push.
6. For a target containing only bootstrap content such as an initial README:
   - clone the target;
   - add the template URL as `upstream`;
   - fetch `upstream`;
   - merge `upstream/main` once with `--allow-unrelated-histories --no-commit`;
   - resolve bootstrap-document conflicts as project-owned content;
   - stop and ask before continuing if source, binary place, or other
     non-bootstrap conflicts appear.
7. For a target that already shares template history, configure or verify
   `upstream`, fetch it, and use a normal merge.
8. For a non-empty target with unrelated source or project data, do not import
   automatically. Report the existing contents and ask whether the user wants
   a reviewed migration.
9. Never use GitHub **Use this template** for a new repository that must receive
   normal upstream merges; it creates an unrelated history.
10. After Mandatory initialization and Required verification succeed, create
    one initialization commit and push `main` to the supplied `origin`. Use a
    normal push only; if it is rejected, report the remote change instead of
    forcing it.

## Mandatory initialization

Before running the first Rojo preflight or connecting Studio in a newly derived
checkout, remove the reusable template's inherited top-level `placeId`,
`gameId`, and `servePlaceIds` from `default.project.json`. This identity belongs
only to the template validation Experience and its two recorded places and is
never evidence about the derived
game. This safety normalization is part of initialization and precedes the
otherwise mandatory Rojo preflight.

1. Resolve the repository root with `git rev-parse --show-toplevel` and use the
   final directory name as the stable project identifier.
2. Verify that `origin` points to the game repository and `upstream` points to
   the reusable template. Do not replace an unexpected existing remote without
   explicit user approval.
3. Set `default.project.json` `name` exactly to the repository root directory
   name. This is the Rojo connection name shown in Studio and distinguishes
   concurrently running project servers.
4. Keep `servePort` absent. All template-derived projects share Rojo's default
   endpoint and use `scripts/ensure-rojo-server.ps1` to make the current
   repository the active server before source edits or Studio work.
5. Resolve the project's cloud-place state:
   - If no published place exists or its stable IDs were not supplied, keep
     top-level `placeId`, `gameId`, and `servePlaceIds` absent, document cloud
     identity as unresolved, and use the unpublished local-file launch flow.
   - If an existing published destination is supplied and verified, set
     top-level `placeId` to its numeric Place ID, `gameId` to its numeric
     Universe/Experience ID, and `servePlaceIds` to a non-empty duplicate-free
     array containing every approved sync target, including `placeId`. These
     three fields are either all absent or all present as one complete positive
     integer identity. Each JSON identity value must be a bare decimal integer
     token in Roblox's exact safe-integer range `1..2^53-1`; fractional,
     exponent, floating-point, decimal-normalized, and out-of-range values fail
     closed. `placeId` and `servePlaceIds` may not reuse either
     template validation PlaceId, and `gameId` may not reuse the template
     validation GameId. Never invent IDs, create or attach a place, or publish
     merely to complete initialization.
   - Never reuse the template validation IDs as the derived project's supplied
     or verified destination, even if they are still visible in Git history.
   - Once a previously unpublished initialized project is attached with user
     authorization, immediately read exact nonzero `game.PlaceId` and
     `game.GameId` from the selected resulting DataModel. Do not derive them
     from the chosen destination, its URL or name, or any prior expectation.
     Before any further cloud-dependent operation, write those observed IDs
     and the exact approved `servePlaceIds` allowlist to
     `default.project.json`, create a new project ADR for that durable identity
     decision, and update the existing `default.project.json` divergence
     ownership through normal supersession rules. Rerun the Rojo preflight,
     reconnect if needed, and verify the DataModel IDs against the recorded
     values. If observation or verification fails, stop without recording
     guessed or partial identity.
6. Replace template-facing root README content with the game's name, purpose,
   local start commands, upstream update workflow, and a link to the template
   README.
7. Create `docs/adr/project/README.md` with an empty decision-index table and
   independent numbering instructions.
8. Copy the structure of `docs/adr/_template.md` into
   `docs/adr/project/0001-initialize-project-from-template.md`, mark it
   Accepted, add it to the project index, and record:
   - project identity and repository;
   - template upstream URL and baseline commit;
   - Rojo connection name;
   - the shared default Rojo endpoint and required absence of `servePort`;
   - known `placeId`, `gameId`, and `servePlaceIds`, or the explicit absence
     of a published cloud identity;
   - canonical `place.rbxl` ownership;
   - initial version, DataStore, and Wallet decisions;
   - any explicitly unresolved project choices;
   - a `Template divergence` section following
     `architecture-decisions.md`, listing every template-owned path changed by
     initialization, including at minimum the project README and
     `default.project.json`, plus each configuration file actually changed.
     Also list `place.rbxl` as an ownership/merge-policy entry even when its
     binary content was not changed, and record that the initialized project's
     complete place is preserved on future upstream updates.
     For `default.project.json`, state the project invariant that `name`
     matches the repository directory and `servePort` remains absent. When
     cloud identity is known, the invariant also preserves the exact
     `placeId`, `gameId`, and `servePlaceIds`. Its upstream merge policy must
     reconcile other incoming JSON changes while always preserving those
     project-owned values and removing any incoming `servePort`.
   Project ADR-0001 remains the owning record for these initialization
   divergences. Future template merges reuse it while those invariants and
   merge policies remain unchanged; they do not create migration or duplicate
   ADRs for the same paths.
9. Review every project-specific configuration surface:
   - `default.project.json` project/connection name, absence of `servePort`,
     and cloud identity fields when published;
   - `VersionConfig.CurrentVersion`;
   - `StorageConfig.DataStoreName`, scope, prefix, limits, and Studio storage;
   - `WalletConfig` currencies and defaults;
   - root README and canonical `place.rbxl`.
10. Use deterministic project-derived values where semantics are clear. Do not
   invent production economy, persistence compatibility, or product behavior.
   If those choices cannot be inferred from the project request, keep the safe
   template behavior, record the unresolved decision in project ADR-0001, and
   ask one focused user question before production-dependent work.
11. Initialize local CodeGraph according to `docs/CodeGraphSetup.md` when the
    tool is available. Generated index files remain untracked.
12. Preserve the inherited `docs/Features/template/` namespace byte-for-byte,
    create `docs/Features/project/`, and generate its initially empty
    `README.md` with `scripts/sync-feature-index.ps1 -Scope Project`.
    `docs/Features/README.md` remains the template-owned router. Validate both
    dashboards without rewriting the template namespace. New game-owned
    features use `PF-####`; inherited template features retain their immutable
    `TF-####` identifiers and remain read-only in the derived repository. Do
    not install Git hooks; lifecycle checks are invoked through the explicit
    feature chat commands.
13. Read `template-updates.md` so future upstream merges preserve documented
    project decisions.

## Required verification

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-repository-layout.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-feature-workflow.ps1
rojo build default.project.json --output $env:TEMP\project-validation.rbxlx
```

Run `scripts/ensure-rojo-server.ps1` and confirm through Rojo's `/api/rojo`
metadata that the repository directory name owns the default endpoint. Run it
a second time and confirm that it does not restart an already-correct server.
For an unpublished project, open `place.rbxl`, connect the Studio plugin at its
unchanged default endpoint, and confirm Studio shows the repository directory
name as the connection. For a published project, open the recorded cloud place
through My Experiences/`EditPlace`, or open `place.rbxl` and connect the
verified Rojo project before any cloud-dependent operation; then confirm exact
nonzero `game.PlaceId`/`game.GameId` and the configured `servePlaceIds`.
Run a clean Play session only after identity verification and inspect both
server and client output.

Do not automatically commit, push, publish a Roblox experience, enable
production DataStore access, or overwrite an existing canonical place unless
the user has authorized that action. A request to create or initialize from a
supplied target repository URL authorizes only the initialization commit and
normal push described above.
