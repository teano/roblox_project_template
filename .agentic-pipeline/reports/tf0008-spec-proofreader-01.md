# TF-0008 Specification Proofread — Wave 1

- PROOFREADER_ID: tf-0008-proofreader-01
- PRD_SHA256: d4d27516cfe2524fbd1a7e095319157c4bc705e115b996124f5f603228bf91a3
- SPEC_SHA256: 40a05d734c312e0432bc67e59c4262b7bfb53e46b4045cbfa627d640de1c8a4c
- COVERAGE_COMPLETE: no
- MINORS_ENGINEER_RESOLVABLE: yes
- VERDICT: revise

## Findings

PF-001 | Major | verification-closure | PRD-REQ-001, PRD-REQ-008, PRD-REQ-015, PRD-NFR-007, PRD-AC-007, PRD-AC-013 | The current `Sync-FeatureIndex` computes desired content by replacing only the generated marker block in the current README, so drift in the title or explanatory prose outside the markers is preserved and accepted. The draft correctly changes the design to a full-file renderer in §4.3, but `SPEC-TEST-007` mutates only counters, a feature row, date, marker, table content, and row order, while `SPEC-TEST-013` covers only creation from a missing file. No named case distinguishes the required full-file implementation from the current marker-replacement implementation for an existing dashboard. | Extend the normalized real-drift evidence with at least title and explanatory-prose/path mutations outside the marker block; assert Check fails without mutation, owning sync restores the exact canonical scaffold, and foreign Check reports content drift without repair. Map the added assertions to the listed requirements and acceptance criteria.

PF-002 | Minor | implementation-contract | PRD-REQ-009, PRD-REQ-010, PRD-NFR-001, PRD-NFR-003 | §4.3 and §5.1 define strict canonical UTF-8 bytes, §5.3 requires strict output encoding before any temporary output is opened, and §4.6 says to use the existing atomic `Write-Utf8NoBom`. The current helper accepts a string and calls `UTF8Encoding(false)`, whose replacement fallback is not strict; the draft does not identify whether rendering returns bytes, performs a separate strict preflight and then re-encodes, or changes the shared writer used by manifests, leases, handoffs, and worklogs. | Specify one exact local write boundary: preferably strict-encode once to bytes, compare those bytes for the idempotence fast path, and atomically write the same bytes, or explicitly define a strict pre-encode plus writer contract. State how shared non-dashboard callers retain their behavior and add an assertion that an unpaired surrogate cannot be replacement-encoded into canonical dashboard output.

## Unresolved

product=0 | scope=0 | boundary=0 | ownership=0 | public-contract=0 | IDs=none
