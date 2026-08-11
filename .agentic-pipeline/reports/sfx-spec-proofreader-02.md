# SFX Specification Proofread — Wave 2

- PROOFREADER_ID: sfx-spec-proofreader-02
- PRD_SHA256: 9b46904c64242100c6aa61377cf5b9d0d79720a1a30865ffec13b2965c9c3dde
- SPEC_SHA256: 88d83641dae9b45ac06ef266ce635b2d374218d5a639d25c2454abc66076d459
- COVERAGE_COMPLETE: yes
- MINORS_ENGINEER_RESOLVABLE: yes
- VERDICT: pass

## Findings

PF-002 | Minor | internal-metadata consistency | PRD-REQ-050, PRD-AC-074 | Header declares approved revision 12, while §§1.2 and 12.3 still identify revision 11 and §1.2 calls it `draft-ok` | Update the stale self-references to approved revision 12 without changing normative content.

PF-003 | Minor | safety-limit rationale wording | PRD-REQ-016, PRD-NFR-002, PRD-AC-073 | `TS-DEC-002` says shipped budgets total `4*(128+64)=768`, but declared shipped totals are server `96+48` and client `112+54`; `128/64` are absolute aggregate ceilings | Relabel `768` as the absolute ceiling boundary or state the actual shipped totals; validator constants and topology remain unchanged.

## Unresolved

product=0 | scope=0 | boundary=0 | ownership=0 | public-contract=0 | IDs=none
