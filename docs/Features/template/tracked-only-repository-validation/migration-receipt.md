# TF-0011 workflow migration receipt

- Captured: 2026-08-26T21:17:17.7257017Z
- Source HEAD: `fbc34584f1495d388bce2159e9a45c9c57fd9abc`
- Outcome: independent acceptance passed; minimal bookkeeping close authorized

## Pre-close exact-byte inventory

Captured at `2026-08-26T22:09:02.6652601Z` before the final acceptance text was
appended:

| File | SHA-256 |
|---|---|
| `feature.json` | `c705384263ae0f40a1d2302a6e66bbc00498d900e09f82d6670a2caf9f20fc3c` |
| `handoff.md` | `eb56af5cac1cdc4493cc58b4285abd78498eaacd98e9512c30ba913edc63402a` |
| `worklog.md` | `3d4f0542e1d2b6d8d4b08335e7b9e88eee1d1c4ade811a5251e966e8d6bb21e3` |
| `product-requirements.md` | `4a376538389407b8672b14582deb201a0cbdd7c72cab71eef4db79146fae037c` |
| `technical-specification.md` | `1eb316155e39ee1a65e0d5c5448bba8932acb58bdbf2f3bd67c54339bf639fa2` |
| `development-plan.md` | `d86aae4e8a8287990a8081555878ca6aa9c8ce0e3bff1a7348de3834245aaadc` |
| `migration-receipt.md` | `dd99fb744d256b1015f254b312beb4ae39942a75f837beb7a828fbf34e9835df` |

The feature manifest, PRD, specification, and plan are not edited before the
close. The handoff, worklog, and this receipt receive only the acceptance text
that preserves and labels their earlier historical content.

## Why the old candidate was retired

TF-0011 began as a narrow attempt to remove the generic repository validator's
dependency on ignored root `/tests` evidence. The implementation expanded into
a parser-heavy PowerShell replica of Luau/runtime and specification semantics,
then accumulated repeated late fixture failures through Engineering generation
75. That candidate treated symptoms of the old workflow instead of removing
the root cause.

ADR-0046 and the KISS/YAGNI refactor supersede that candidate with:

- one self-contained template init/update/validate tool;
- a bounded structural and changed-path ownership validator;
- focused PowerShell tests for template tooling;
- existing Luau/Studio suites as runtime-semantic owners;
- optional `open|done` feature records without pipeline state or leases.

The approved historical PRD, specification, and development plan are retained
unchanged as evidence of the path taken. The original handoff and worklog
bodies are preserved, with a clearly separated current migration checkpoint;
their pre-migration hashes below make the boundary auditable. Historical text
is not a current execution instruction.

## Canonical feature history inventory

| File | Pre-migration Git blob |
|---|---|
| `development-plan.md` | `b997f5465f1c4bd4bf711b7c4b89c5b23de36ba3` |
| `feature.json` | `ae67dca4c17e53b81f7104eec63c3cb9b092b024` |
| `handoff.md` | `ab60eb36a3b8f98efc5f0ea149e7c49c1d548875` |
| `product-requirements.md` | `2a6ef2924dc8ea50634ee0b1a3218094f9d3be85` |
| `technical-specification.md` | `c6fd9e1e47bea58fac42f703f75f3350685214cf` |
| `worklog.md` | `b8a9de9f565bdbb0fdcfab5f78c925d031c7f657` |

## Tracked pipeline inventory

Before deletion, 114 tracked paths existed under `.agentic-pipeline/**` and
`.agentic-pipeline-v2/**`. The canonical manifest is the ordinal path list
where every line contains:

```text
<mode> <HEAD/index Git blob> <current worktree Git blob or MISSING> <path>
```

SHA-256 of that UTF-8/LF manifest:
`00389b7471383f6ada8b5266f8ebea2a59213f7617524d9de6cf116a12d7a7f1`.
The exact path set and HEAD blobs are reconstructible from the source revision;
the six non-clean worktree entries are captured below.

| Path | HEAD/index blob | Pre-deletion worktree blob |
|---|---|---|
| `.agentic-pipeline-v2/state.json` | `cc3377a1c0c910558d9bbc9bae2334d60340a6ef` | `841136b563ac00a6975f385fb18efc99e6cefb51` |
| `.agentic-pipeline/development-plan-state.json` | `121b9a197c97eed61f53f3d472ecdd971d944556` | `c5545e2f8d5c04cac805f4e3ed9bb536a590387b` |
| `.agentic-pipeline/director-checkpoint.json` | `b81c958224d216387a018e72aa7a4123cbb31029` | `MISSING` |
| `.agentic-pipeline/findings.json` | `f2efc8f2340d447dbcab10490b0284bf52120512` | `MISSING` |
| `.agentic-pipeline/specification-state.json` | `2d8a65ae375b4cd2cb5ec063f72df6ecdae427d8` | `a59fd04a4ef2a482c28cbbb4a35df6492b9ffbc8` |
| `.agentic-pipeline/state.json` | `65e47d6d8382bf74da574cb2494d258bafc7763b` | `MISSING` |

The current v2 controller snapshot reported run
`tf0011-kiss-tracked-only-validation`, phase `engineering`, generation 13.
It is historical process state, not feature authority.

## Preserved untracked artifacts

Forty-five untracked pipeline/archive/output/report files were inventoried
before the ignore rule changed. Their Git-blob/path manifest SHA-256 is
`3a59905dd9b80c69eac15d3a2a5632031c9c367c4326ddb4e8a2985e9a19704f`.
They were not deleted, moved, rewritten, or promoted to source. This includes
the TF-0011 pre-KISS controller snapshot and proofreader/output artifacts.

## Retired instruction surfaces

Ten tracked files under the four lifecycle skills and project-initialize skill
were inventoried before deletion. Their mode/HEAD/current/path manifest
SHA-256 is
`30f26e2e1fd95c24222e4a3c7aec17673db2dc7dd6404868cd2dfe5ce1c24e2f`.
The independent `window-authoring` skill remains and routes to the current
rules.

## Cutover result

All 114 tracked pipeline paths are represented as deletions in the cutover
diff. Of those, 111 files existed and were removed; three were already absent
from the worktree and remain recorded above. All ten obsolete skill files are
likewise represented as deletions, while `window-authoring` remains.

A post-cutover filesystem enumeration found exactly the same 45 ignored
pipeline archive/output/report artifacts and no additional pipeline files.
Those untracked artifacts remain byte-owned by the local workspace and were
not edited or deleted by this cutover.

## Final independent acceptance

Independent review reported no blocking findings. Focused template-tool suites
passed 51/51 under Windows PowerShell 5.1 and PowerShell 7; prior extended
103/103 evidence remains valid for the unchanged covered behavior. Standalone
wrappers passed on both hosts, parser checks passed, and a temporary Rojo build
passed at 1,679,039 bytes before removal. Diff, active-link, and active-reference
checks passed. All 114 tracked pipeline paths remain deleted, all 45 ignored
local artifacts remain preserved, and the runtime source/config/place/project
identity invariants are unchanged.

Studio was not run because no Roblox runtime source, mapping, scene, or
DataModel behavior changed. This is acceptance of the root-cause workflow
refactor, not a release claim.

Immediate pre-close `handoff.md` SHA-256:
`acaecc6755c45d33b7b903f5dc0c7ad042236b29ad257231c1157b04f0c7d0b9`.

## Pre-close boundary

The explicit goal authorizes the owning feature tool to migrate the exact
schema-v2 manifest to schema v3, preserve it as `feature.legacy.json`, and
close TF-0011. The current schema-v3 manifest and current handoff become final
state authority after that command; PRD, specification, plan, worklog, and
legacy sidecars remain historical evidence.
