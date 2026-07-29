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

1. Resolve the repository root with `git rev-parse --show-toplevel` and use the
   final directory name as the stable project identifier.
2. Verify that `origin` points to the game repository and `upstream` points to
   the reusable template. Do not replace an unexpected existing remote without
   explicit user approval.
3. Set `default.project.json` `name` exactly to the repository root directory
   name. This is the Rojo connection name shown in Studio and distinguishes
   concurrently running project servers.
4. Assign a dedicated fixed Rojo server port:
   - inspect `servePort` in other `*.project.json` files under the target
     repository's parent directory and every available local workspace root,
     excluding the target repository's own configuration;
   - inspect active TCP listeners so a port reserved by another process is not
     selected;
   - choose the first port that is neither configured elsewhere nor actively
     listening in the inclusive range `34872` through `34999`;
   - write that integer to `default.project.json` as `servePort`;
   - if the range cannot be inspected reliably or has no free port, stop and
     ask the user instead of reusing or inventing a port outside the range.
5. Replace template-facing root README content with the game's name, purpose,
   local start commands, upstream update workflow, and a link to the template
   README.
6. Create `docs/adr/project/README.md` with an empty decision-index table and
   independent numbering instructions.
7. Copy the structure of `docs/adr/_template.md` into
   `docs/adr/project/0001-initialize-project-from-template.md`, mark it
   Accepted, add it to the project index, and record:
   - project identity and repository;
   - template upstream URL and baseline commit;
   - Rojo connection name;
   - selected Rojo `servePort`;
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
     matches the repository directory and `servePort` remains the selected
     dedicated port. Its upstream merge policy must reconcile other incoming
     JSON changes while always preserving the project's current `name` and
     `servePort`.
   Project ADR-0001 remains the owning record for these initialization
   divergences. Future template merges reuse it while those invariants and
   merge policies remain unchanged; they do not create migration or duplicate
   ADRs for the same paths.
8. Review every project-specific configuration surface:
   - `default.project.json` project/connection name and fixed `servePort`;
   - `VersionConfig.CurrentVersion`;
   - `StorageConfig.DataStoreName`, scope, prefix, limits, and Studio storage;
   - `WalletConfig` currencies and defaults;
   - root README and canonical `place.rbxl`.
9. Use deterministic project-derived values where semantics are clear. Do not
   invent production economy, persistence compatibility, or product behavior.
   If those choices cannot be inferred from the project request, keep the safe
   template behavior, record the unresolved decision in project ADR-0001, and
   ask one focused user question before production-dependent work.
10. Initialize local CodeGraph according to `docs/CodeGraphSetup.md` when the
   tool is available. Generated index files remain untracked.
11. Read `template-updates.md` so future upstream merges preserve documented
    project decisions.

## Required verification

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-repository-layout.ps1
rojo build default.project.json --output $env:TEMP\project-validation.rbxlx
```

Immediately before starting Rojo, recheck that the selected `servePort` is not
owned by another active listener. Then open `place.rbxl`, start
`rojo serve default.project.json` without a `--port` override, and confirm that
Rojo reports the port recorded in `default.project.json` and Studio shows the
repository directory name as the connection. If binding fails, repeat the port
selection and update project ADR-0001 before committing. Run a clean Play
session and inspect both server and client output.

Do not automatically commit, push, publish a Roblox experience, enable
production DataStore access, or overwrite an existing canonical place unless
the user has authorized that action. A request to create or initialize from a
supplied target repository URL authorizes only the initialization commit and
normal push described above.
