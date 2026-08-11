# ADR-0042: Bind Studio Audio QA through existing bootstraps

- Status: Accepted
- Date: 2026-08-09
- Deciders: Project maintainers
- Supersedes: None
- Superseded by: None

## Context

Collaborative Audio QA must drive the real initialized production Audio
services. An operator command may execute in a Luau environment whose
ModuleScript cache is separate from the bootstrap environment, so requiring a
manifest again constructs an uninitialized service graph instead of recovering
the running one. Publishing the service graph in a replicated table, adding a
QA remote, or inspecting private module fields would violate composition,
authority, transport, and public-contract boundaries.

The capability is needed only for Studio Play validation. It must be absent
from live non-Studio servers and clients, keep server internals server-local,
and expose no generic service lookup.

## Decision

After the existing side-specific initialization runner succeeds, each existing
bootstrap may, only while `RunService:IsStudio()` is true, install one
side-local `BindableFunction` below its own bootstrap Script. Its callback
closes over that bootstrap environment's actual `manifest.Services` table.

The server and client use separate bindables and exact command whitelists. The
reviewed `Bridge.Invoke` caller contract accepts and returns only bounded,
deep-copied, serializable primitive tables; it rejects Instances, functions,
userdata, cycles, mixed/sparse tables, non-finite numbers, excessive
depth/nodes, oversized strings, and unknown commands before engine transport.
It never returns a service, module, or callback. The server bridge
remains under `ServerScriptService`; the client bridge remains client-local
under `PlayerScripts`. No RemoteEvent, RemoteFunction, Communication message,
new Script, new LocalScript, second bootstrap, or startup command is added.

Outside Studio the bootstraps do not require the QA drivers and create no
bridge. QA sessions own and clean their playback handles, one-shot labels,
transient Instances, Music entries, and settings overrides. The Play DataModel
owns bridge lifetime and destroys it on teardown.

## Alternatives considered

### Require the manifest again from each operator command

Rejected because a separate ModuleScript cache can construct a new,
uninitialized service graph and cannot prove binding to the production
bootstrap generation.

### Publish a service locator or bootstrap result table

Rejected because it exposes mutable runtime owners, encourages hidden lookup,
and risks replicating server internals.

### Add a QA remote or Communication protocol

Rejected because the bridge is side-local Studio tooling, not gameplay
transport. A network path would widen attack surface and create a live protocol
solely for tests.

## Consequences

### Positive

- Operator calls execute against the exact production bootstrap service graph.
- Non-Studio runtime composition and network surface remain unchanged.
- Server internals remain server-local and bridge evidence is bounded and
  machine-readable.
- Deterministic tests prove the exact whitelist, serialization, binding, and
  cleanup contracts. This includes caller-side rejection before engine
  transformation and the observed raw-Bindable boundary: cyclic tables are
  rejected before `OnInvoke`; metadata/frozen state is removed, coroutines
  become `nil`, mixed dictionary fields are dropped, sparse numeric keys are
  stringified, and a plain copy reaches `OnInvoke` without executing `__iter`.
  `OnInvoke` does not claim it can detect data already removed or transformed
  by Roblox; direct raw invocation is evidence, not an accepted operator API.
  The repository layout validator separately proves the
  whitespace/comment-tolerant bootstrap source-path Studio gate, exact reviewed
  QA inventory, and lexer-aware absence of executable QA remote structures,
  Tests/QA `.server`/`.client` Lua/Luau files, or a non-Studio QA-driver
  require path.

### Negative

- Both bootstraps contain a small Studio-only post-success hook.
- The manual QA driver command surface must remain explicitly whitelisted and
  versioned with its runbook.
- A future driver command requires coordinated bridge, test, and documentation
  updates.

## Enforcement

- Agent rules: `.agents/rules/architecture.md`,
  `.agents/rules/initialization.md`, `.agents/rules/audio.md`,
  `.agents/rules/communication.md`, and `.agents/rules/testing.md`.
- Current documentation: `docs/AudioSystem.md`, `docs/AudioManualQA.md`, and
  `docs/TestCoverage.md`.
- Code boundaries: both existing bootstrap scripts,
  `Shared/Tests/AudioManualQaBridge`, and the side-specific Audio manual QA
  drivers.
- Tests: `AudioManualQaTestRunner`, `SystemTestRunner`, aggregate
  `AllTestsRunner`, `scripts/validate-repository-layout.ps1`, and clean
  server/client Studio Play verification.
