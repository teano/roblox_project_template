# Derived-project initialization rules

## Scope

Apply once, before the first source change in a repository created from this
template. A repository is derived when it has an `upstream` remote pointing to
the template. It is initialized when `docs/adr/project/README.md` exists and
the checklist below has been completed.

Required subsystem rules: `architecture-decisions.md`, `rojo-project.md`,
`domain-data.md`, `save-system.md`, `communication.md`, and `testing.md`.

## Mandatory initialization

1. Resolve the repository root with `git rev-parse --show-toplevel` and use the
   final directory name as the stable project identifier.
2. Verify that `origin` points to the game repository and `upstream` points to
   the reusable template. Do not replace an unexpected existing remote without
   explicit user approval.
3. Set `default.project.json` `name` exactly to the repository root directory
   name. This is the Rojo connection name shown in Studio and distinguishes
   concurrently running project servers.
4. Replace template-facing root README content with the game's name, purpose,
   local start commands, upstream update workflow, and a link to the template
   README.
5. Create `docs/adr/project/README.md` with an empty decision-index table and
   independent numbering instructions.
6. Copy the structure of `docs/adr/_template.md` into
   `docs/adr/project/0001-initialize-project-from-template.md`, mark it
   Accepted, add it to the project index, and record:
   - project identity and repository;
   - template upstream URL and baseline commit;
   - Rojo connection name;
   - canonical `place.rbxl` ownership;
   - initial version, DataStore, and Wallet decisions;
   - any explicitly unresolved project choices.
7. Review every project-specific configuration surface:
   - `default.project.json` project/connection name;
   - `VersionConfig.CurrentVersion`;
   - `StorageConfig.DataStoreName`, scope, prefix, limits, and Studio storage;
   - `WalletConfig` currencies and defaults;
   - root README and canonical `place.rbxl`.
8. Use deterministic project-derived values where semantics are clear. Do not
   invent production economy, persistence compatibility, or product behavior.
   If those choices cannot be inferred from the project request, keep the safe
   template behavior, record the unresolved decision in project ADR-0001, and
   ask one focused user question before production-dependent work.
9. Initialize local CodeGraph according to `docs/CodeGraphSetup.md` when the
   tool is available. Generated index files remain untracked.

## Required verification

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-repository-layout.ps1
rojo build default.project.json --output $env:TEMP\project-validation.rbxlx
```

Then open `place.rbxl`, start `rojo serve default.project.json`, confirm that
Studio shows the repository directory name as the connection, run a clean Play
session, and inspect both server and client output.

Do not automatically commit, push, publish a Roblox experience, enable
production DataStore access, or overwrite an existing canonical place unless
the user has authorized that action.
