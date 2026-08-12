# TF-0008 Specification Proofreader Report — Wave 2

PROOFREADER_ID: tf-0008-proofreader-02

PRD_SHA256: d4d27516cfe2524fbd1a7e095319157c4bc705e115b996124f5f603228bf91a3

SPEC_SHA256: 0c247f689e01801af15007a16b1af48c84acc81c923bcbcee00f576a83b656c2

COVERAGE_COMPLETE: no

FINDING_COUNTS: Critical=0 | Major=1 | Minor=0

FINDINGS:

- PF-003 | Major | verification-closure | `PRD-REQ-009`, `PRD-REQ-010`, `PRD-NFR-001`, `PRD-NFR-003`, `PRD-NFR-004` | Sections 4.1 and 4.6 require manifest JSON to pass through `ConvertFrom-Json`, while `SPEC-TEST-018` expects the JSON escape `\uD800` to survive as an unpaired high surrogate and make the strict dashboard encoder fail before mutation. On both supported local hosts, Windows PowerShell 5.1.26100.8875 and PowerShell 7.6.3, `'"\uD800"' | ConvertFrom-Json` instead produces a one-character string containing U+FFFD; `[Text.UTF8Encoding]::new($false, $true).GetBytes(...)` then succeeds with bytes `EF-BF-BD`. Thus the prescribed fixture cannot reach the failure it claims to verify, and a conforming loader can silently materialize the exact replacement character the test forbids. The implementation criterion in section 1 also names only `SPEC-TEST-001..017`, so it does not require the new strict-boundary case to pass. | Define a realizable Unicode-scalar boundary: either reject unpaired escaped surrogates from raw JSON with JSON-aware validation before `ConvertFrom-Json`, then separately inject `[char]0xD800` directly into the strict encoder test, or use another repository-compatible parsing boundary that demonstrably preserves/rejects the invalid scalar on both hosts. Update `SPEC-TEST-018` to distinguish loader rejection from direct encoder rejection, retain destination/directory/temp-file no-mutation assertions, and change the section 1 gate to `SPEC-TEST-001..018`.

UNRESOLVED:

- product: 0 | IDs: none
- scope: 0 | IDs: none
- boundary: 0 | IDs: none
- ownership: 0 | IDs: none
- public-contract: 0 | IDs: none

MINORS_ENGINEER_RESOLVABLE: yes

VERDICT: revise

## Prior finding closure audit

- PF-001: closed. `SPEC-REQ-003`, `SPEC-REQ-005`, `SPEC-REQ-006`,
  `SPEC-TEST-007`, and `SPEC-TEST-008` now require canonical full-file
  rendering, outer-scaffold title/prose/path drift detection, Check
  immutability, owning full-file restoration, and foreign failure without
  repair.
- PF-002: not fully closed. The single strict dashboard encode-to-byte writer
  boundary and shared atomic byte writer are specified, but `SPEC-TEST-018`'s
  only invalid-surrogate path is neutralized by the mandated JSON parser before
  that boundary. PF-003 is the remaining deduplicated closure finding.

## Read-only evidence inspected

- Entire immutable approved PRD and specification.
- `.agents/rules/index.md`, `feature-workflow.md`, `architecture.md`,
  `architecture-decisions.md`, and `testing.md`.
- `docs/adr/README.md`, the template ADR index, Accepted template/ADR-0037,
  and its feature-workflow predecessor chain.
- Current `scripts/FeatureWorkflow.psm1`,
  `scripts/tests/feature-workflow.tests.ps1`, dashboard entrypoints,
  feature manifest schema, generated template dashboard, and `.gitattributes`.
- Capability checks on Windows PowerShell 5.1 and PowerShell 7.x for
  `ConvertFrom-Json` date support and unpaired-surrogate behavior.
