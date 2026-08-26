---
name: project-initialize
description: Initialize a repository derived from this Roblox template, including its project-owned ADR/feature namespaces, Rojo identity, safe configuration review, and exact derived UI authoring source. Use only when the user explicitly asks to create or initialize a derived project.
---

# Initialize a derived project

Follow `AGENTS.md`, `.agents/rules/index.md`, and
`.agents/rules/project-initialization.md` as the complete authority. This skill
orchestrates that existing workflow; it does not replace its repository,
identity, ADR, feature, verification, commit, or push gates.

## Execute the workflow

1. Resolve the target repository, role, remotes, root directory name, and
   initialization state exactly as the rule requires. Never run this workflow
   against the reusable template.
2. Before the first Rojo preflight, remove inherited template cloud identity,
   keep `servePort` absent, and establish only independently verified derived
   identity. Complete the project README, project ADR namespace/ADR-0001,
   project feature namespace, configuration review, and CodeGraph setup when
   available.
3. As a mandatory initialization artifact, create exactly
   `src/ReplicatedStorage/Project/Client/UI/DerivedWindowConfig.luau` as strict
   UTF-8 with this valid empty duplicate-preserving sequence:

   ```lua
   --!strict

   return table.freeze({})
   ```

   Future project windows may directly require canonical modules from the
   sibling `Definitions` directory and list those exact returned tables in
   this sequence. Do not create an alternate UI config/registry/manifest,
   runtime repository marker, or empty `DerivedUiActionIds.luau`.
4. Record the exact derived config path in initialization evidence as a new
   project-owned path, not a modification of a template-owned path and not a
   template-divergence entry. Future upstream merges preserve it.
5. Run `scripts/validate-repository-layout.ps1` successfully before any later
   implementation or build. Complete all other initialization verification in
   the governing rule. If upstream supplies the reserved
   `src/ReplicatedStorage/Project/` namespace or the exact derived config path,
   stop instead of merging over project ownership.

Do not publish, attach, enable production DataStore access, force-push, or
overwrite a canonical place unless separately authorized by the user and the
governing rule permits that action.
