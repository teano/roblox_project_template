# Compatibility pointer: template updates

This filename is retained for one migration release so older derived projects
and historical documents do not fail on a missing link.

Current authority is `.agents/rules/template-workflow.md`. Use the target
revision's self-contained `scripts/template-project.ps1 update` command. Do
not execute the retired per-path ADR gate, generated update-branch workflow,
feature-dashboard validation, or parser-heavy repository checks.
