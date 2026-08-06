---
name: csv-to-luau
description: Convert an attached or explicitly named UTF-8 CSV file into a deterministic repository-owned Luau data ModuleScript, or fully synchronize an existing pure data module. Use only when the user explicitly invokes `$csv-to-luau` to create or update CSV-backed `.luau` data inside the current Git/Rojo repository.
---

# Convert CSV to Luau

Use the bundled `scripts/csv_to_luau.py` for every parse, validation, preview,
Luau inspection, render, boundary check, and write. Do not reproduce its logic
with shell pipelines, snippets, or manual editing.

## Resolve the request

1. Read the repository `AGENTS.md` and every rule it routes for the requested
   target before changing files.
2. Resolve the CSV to one readable attachment-backed or explicitly supplied
   path. Resolve the target to one exact `.luau` path. If a verbal target is
   missing or matches multiple files, list the ambiguity, ask one minimal
   question, and do not run `apply`.
3. For a new target, require the user to choose `array` or `dictionary`. For a
   new dictionary, also require an exact key-column header. Ask only the first
   missing decision. Let the helper detect the mode and key column of an
   existing safe target.
4. Pass explicit delimiter or `--type <header>=<type>` overrides only when the
   user supplied those decisions. Never guess an ambiguous value.

## Check capabilities

Before preview, confirm Python 3.10 or newer, Git, the current Git root, and a
readable `default.project.json`. Stop with one bounded diagnostic if any is
unavailable. Do not install packages or use network, Studio, browser control,
Computer Use, a daemon, or platform-specific text-processing pipelines.

## Preview

Invoke the helper with direct arguments from the Git root:

```text
python <skill>/scripts/csv_to_luau.py preview
  --repo-root <git-root> --source <source> --target <target>
  [--mode array|dictionary] [--key-column <header>]
  [--delimiter comma|semicolon|tab|pipe]
  [--type <header>=string|number|boolean]...
  [--array-delimiter <header>=comma|semicolon|pipe|tab|newline]...
```

Treat stdout as one JSON object. Never write a repository file during preview.

- On `needs-input`, show the candidates or reason, ask only the first item in
  `required_decisions`, and stop. For `array_delimiter`, group the shown
  candidates for the first column, report their delimiter names, matching-cell
  counts, generated-element counts, and bounded sample, then ask one question:
  which delimiter to use or whether to keep the column as a string. Do not run
  `apply` while this decision remains unresolved.
- On `rejected`, show the bounded diagnostics and stop without proposing a
  write.
- On `ok`, show the source and target, selected delimiter, shape, complete
  bounded schema, mode/key, empty count, diff counts, diagnostics, first three
  and last three samples, and the three hashes. Keep chat output within 16 KiB
  and 200 lines. Do not show a large generated module or full CSV.
- Treat the helper's `array<string>` schema as authoritative. Pass an explicit
  `<header>=string` override only when the user says commas in that column are
  literal text; do not suppress an inferred array by guessing intent.
- Treat comma arrays as automatic. For semicolon, pipe, tab, or newline, rely
  only on the helper's bounded `array_candidates`; never infer a separator from
  an ad hoc scan. After the user chooses, re-run preview with
  `--array-delimiter <header>=<name>`. If the user declines, re-run with
  `--type <header>=string`. Preserve each explicit decision in all later
  preview/apply calls so the helper can surface the next unresolved candidate.

## Apply without another confirmation

After an unambiguous successful `ok` preview with no required decisions, do not
ask for confirmation. Directly before `apply`, run the repository-mandated
source-edit preflight exactly as the current rules require. On this template
that is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/ensure-rojo-server.ps1
```

Use `pwsh` only when it is the repository-supported PowerShell host on the
current platform. Stop without mutation if the host or preflight is
unavailable or fails.

Invoke `apply` with the identical conversion arguments plus the successful
preview hashes:

```text
--expect-source-sha256 <source.sha256>
--expect-target-sha256 <target.sha256-or-absent>
--expect-output-sha256 <output.sha256>
```

Do not bypass a changed-hash rejection. Re-run preview instead. The helper
recomputes the conversion and owns the same-directory temporary write, flush,
close, final path/parent revalidation, and atomic replacement for a single sequential invocation.

Treat a successful return from the helper's atomic replace as the commit point.
The helper does not coordinate concurrent same-target invocations or protect
against an external writer. Never retry the write automatically after an
uncertain result. Never roll back a target after a possible commit point, and
never delete an unknown sibling file as a stale artifact.

## Report the result

For acknowledged `written`/`unchanged`, report the exact repo-relative target,
status, record count, output bytes/hash, and diff counts. Then use direct
argument arrays limited to that target, with the option boundary in every
target-scoped command:
`git status --short -- <target>`, `git diff --numstat -- <target>`, and
`git diff --stat -- <target>`.

For an untracked target, obtain summaries only with
`git diff --no-index --numstat -- <os.devnull> <target>` and
`git diff --no-index --stat -- <os.devnull> <target>`; treat ordinary
difference exit code `1` as expected. Do not run raw untracked
`git diff --no-index` before a byte/line bound. Never interpolate Git commands
through a shell. A full diff is optional and may be shown only when a complete
capture proves the full diff is at most 16 KiB and at most 200 lines; otherwise
show summaries only. Do not stage or commit unless separately requested.

Treat a complete parseable exit-2 `needs-input` payload as an authoritative
decision request: show its bounded reason, ask only the first item in
`required_decisions`, and stop without writing. Treat a complete parseable
exit-3 `rejected` payload as an authoritative pre-commit rejection: show its
bounded diagnostics and stop. For `source-changed`, `target-changed`, or
`output-changed`, re-run `preview` instead of retrying the write with stale
hashes.

Treat exit 4, absent JSON, partial JSON, and unparseable or incomplete JSON as
an uncertain result. Report one bounded uncertain-result error and stop. Do
not retry the write, inspect the target with ad hoc snippets, or attempt
rollback. Never infer a failed or successful commit solely from an exit code.
Never claim macOS, Linux, Luau-runtime, or other environment evidence that was
not actually executed.
