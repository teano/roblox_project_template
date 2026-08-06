#!/usr/bin/env python3
"""Contract tests for the bundled CSV-to-Luau helper."""

from __future__ import annotations

import ast
import contextlib
import gc
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid


SCRIPT = Path(__file__).with_name("csv_to_luau.py")
SKILL_ROOT = SCRIPT.parent.parent
TIMEOUT_SECONDS = 120


def load_helper():
    name = "csv_to_luau_contract_module"
    spec = importlib.util.spec_from_file_location(name, SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load helper module")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    return module


HELPER = load_helper()


def full_diff_capture_fits_chat_budget(capture: bytes, *, complete: bool) -> bool:
    if not complete:
        return False
    line_count = capture.count(b"\n")
    if capture and not capture.endswith(b"\n"):
        line_count += 1
    return (
        len(capture) <= HELPER.LIMITS["chat_bytes"]
        and line_count <= HELPER.LIMITS["chat_lines"]
    )


@contextlib.contextmanager
def patched_limits(**values):
    previous = {key: HELPER.LIMITS[key] for key in values}
    HELPER.LIMITS.update(values)
    try:
        yield
    finally:
        HELPER.LIMITS.update(previous)


class FixtureRepository:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="csv-to-luau-test-")
        self.root = Path(self.temporary.name)
        self.source = self.root / "input.csv"
        self.mapped = self.root / "src"
        self.data = self.mapped / "Data"
        self.data.mkdir(parents=True)
        self.target = self.data / "Generated.luau"
        subprocess.run(
            ["git", "init", "--quiet", str(self.root)],
            check=True,
            capture_output=True,
            timeout=TIMEOUT_SECONDS,
        )
        (self.root / "default.project.json").write_text(
            json.dumps(
                {
                    "name": "csv-to-luau-fixture",
                    "tree": {
                        "$className": "DataModel",
                        "ReplicatedStorage": {"$path": "src"},
                    },
                }
            ),
            encoding="utf-8",
            newline="\n",
        )

    def close(self) -> None:
        self.temporary.cleanup()

    def args(
        self,
        operation: str,
        *,
        target: Path | None = None,
        mode: str | None = None,
        key: str | None = None,
        delimiter: str | None = None,
        types: list[str] | None = None,
        array_delimiters: list[str] | None = None,
        hashes: dict | None = None,
    ) -> list[str]:
        arguments = [
            operation,
            "--repo-root",
            str(self.root),
            "--target",
            str(target or self.target),
        ]
        arguments.extend(("--source", str(self.source)))
        if mode:
            arguments.extend(("--mode", mode))
        if key:
            arguments.extend(("--key-column", key))
        if delimiter:
            arguments.extend(("--delimiter", delimiter))
        for item in types or []:
            arguments.extend(("--type", item))
        for item in array_delimiters or []:
            arguments.extend(("--array-delimiter", item))
        if hashes is not None:
            arguments.extend(
                (
                    "--expect-source-sha256",
                    hashes["source"]["sha256"],
                    "--expect-target-sha256",
                    hashes["target"]["sha256"] or "absent",
                    "--expect-output-sha256",
                    hashes["output"]["sha256"],
                )
            )
        return arguments


def run_cli(arguments: list[str], *, env: dict[str, str] | None = None):
    process_env = os.environ.copy()
    process_env["PYTHONDONTWRITEBYTECODE"] = "1"
    if env:
        process_env.update(env)
    result = subprocess.run(
        [sys.executable, str(SCRIPT), *arguments],
        check=False,
        capture_output=True,
        timeout=TIMEOUT_SECONDS,
        env=process_env,
    )
    if result.stderr:
        raise AssertionError(f"unexpected stderr: {result.stderr!r}")
    payload = json.loads(result.stdout.decode("utf-8"))
    if len(result.stdout) > 256 * 1024:
        raise AssertionError("helper JSON exceeded 256 KiB")
    return result.returncode, payload, result.stdout


def apply_preview(repo: FixtureRepository, preview: dict, *, env=None, **kwargs):
    return run_cli(repo.args("apply", hashes=preview, **kwargs), env=env)


class CsvToLuauCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = FixtureRepository()

    def tearDown(self) -> None:
        self.repo.close()

    def preview(self, csv: bytes | str, **kwargs):
        data = csv.encode("utf-8") if isinstance(csv, str) else csv
        self.repo.source.write_bytes(data)
        return run_cli(self.repo.args("preview", **kwargs))

    def test_array_exact_canonical_output_and_empty_cells(self) -> None:
        code, preview, _ = self.preview("id,name,note\n1,Alice,\n2,Bob,ok\n", mode="array")
        self.assertEqual((code, preview["status"]), (0, "ok"))
        code, result, _ = apply_preview(self.repo, preview, mode="array")
        self.assertEqual((code, result["status"], result["records"]), (0, "written", 2))
        self.assertEqual(
            self.repo.target.read_bytes(),
            (
                "--!strict\n\nreturn {\n"
                "\t{\n\t\tid = 1,\n\t\tname = \"Alice\",\n\t},\n"
                "\t{\n\t\tid = 2,\n\t\tname = \"Bob\",\n\t\tnote = \"ok\",\n\t},\n"
                "}\n"
            ).encode("utf-8"),
        )

    def test_new_target_without_mode_needs_input_and_does_not_write(self) -> None:
        code, payload, _ = self.preview("id,name\n1,A\n")
        self.assertEqual((code, payload["status"], payload["required_decisions"]), (2, "needs-input", ["mode"]))
        self.assertFalse(self.repo.target.exists())

    def test_cli_missing_target_is_bounded_json_and_writes_nothing(self) -> None:
        self.repo.source.write_text("id\n1\n", encoding="utf-8")
        args = ["preview", "--repo-root", str(self.repo.root), "--source", str(self.repo.source)]
        code, payload, _ = run_cli(args)
        self.assertEqual((code, payload["status"]), (3, "rejected"))
        self.assertFalse(self.repo.target.exists())

    def test_path_traversal_rojo_boundary_and_executable_targets(self) -> None:
        self.repo.source.write_text("id\n1\n", encoding="utf-8")
        outside = self.repo.root.parent / f"outside-{uuid.uuid4().hex}.luau"
        cases = [
            (outside, "target-outside-repository"),
            (self.repo.root / "NotMapped.luau", "target-outside-rojo"),
            (self.repo.data / "Run.server.luau", "target-executable"),
            (self.repo.data / "Run.client.luau", "target-executable"),
        ]
        for target, expected in cases:
            with self.subTest(target=target):
                code, payload, _ = run_cli(self.repo.args("preview", target=target, mode="array"))
                self.assertEqual(code, 3)
                self.assertEqual(payload["diagnostics"]["shown"][0]["code"], expected)
                self.assertFalse(target.exists())

    def test_symlink_redirect_outside_is_rejected(self) -> None:
        self.repo.source.write_text("id\n1\n", encoding="utf-8")
        external_dir = Path(tempfile.mkdtemp(prefix="csv-to-luau-external-"))
        link = self.repo.mapped / "Redirect"
        try:
            try:
                os.symlink(external_dir, link, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"directory symlinks unavailable: {exc}")
            target = link / "Outside.luau"
            code, payload, _ = run_cli(self.repo.args("preview", target=target, mode="array"))
            self.assertEqual(code, 3)
            self.assertEqual(payload["diagnostics"]["shown"][0]["code"], "target-redirect")
            self.assertFalse(target.exists())
        finally:
            if link.is_symlink():
                link.unlink()
            try:
                external_dir.rmdir()
            except OSError:
                pass

    def test_preexisting_internal_directory_alias_is_rejected(self) -> None:
        self.repo.source.write_text("id\n1\n", encoding="utf-8")
        real = self.repo.mapped / "Real"
        real.mkdir()
        alias = self.repo.mapped / "Alias"
        made = False
        try:
            try:
                os.symlink(real, alias, target_is_directory=True)
                made = True
            except OSError:
                if os.name == "nt":
                    result = subprocess.run(
                        ["cmd", "/c", "mklink", "/J", str(alias), str(real)],
                        check=False,
                        capture_output=True,
                        timeout=TIMEOUT_SECONDS,
                    )
                    made = result.returncode == 0
            if not made:
                self.skipTest("directory symlink/junction creation unavailable")
            target = alias / "Generated.luau"
            code, payload, _ = run_cli(
                self.repo.args("preview", target=target, mode="array")
            )
            self.assertEqual(code, 3)
            self.assertEqual(
                payload["diagnostics"]["shown"][0]["code"],
                "target-redirect",
            )
            self.assertFalse((real / "Generated.luau").exists())
        finally:
            if made and os.path.lexists(alias):
                if alias.is_symlink():
                    alias.unlink()
                else:
                    os.rmdir(alias)

    def test_utf8_bom_doubled_quote_delimiter_and_crlf_inside_quote(self) -> None:
        source = b'\xef\xbb\xbfid,text\r\n1,"A,""B""\r\nC"\r\n'
        code, preview, _ = self.preview(source, mode="array", types=["text=string"])
        self.assertEqual((code, preview["shape"]["records"]), (0, 1))
        apply_preview(self.repo, preview, mode="array", types=["text=string"])
        output = self.repo.target.read_text(encoding="utf-8")
        self.assertIn('text = "A,\\"B\\"\\r\\nC"', output)

    def test_unique_nonstandard_delimiters_and_structural_ambiguity(self) -> None:
        for name, delimiter in (("semicolon", ";"), ("tab", "\t"), ("pipe", "|")):
            with self.subTest(name=name):
                code, payload, _ = self.preview(f"id{delimiter}name\n1{delimiter}A\n", mode="array")
                self.assertEqual((code, payload["delimiter"]["selected"]), (0, name))
        code, payload, _ = self.preview("a,b;c\n1,2;3\n", mode="array")
        self.assertEqual((code, payload["status"]), (2, "needs-input"))
        self.assertEqual(set(payload["required_decisions"]), {"delimiter"})
        self.assertFalse(self.repo.target.exists())

        code, payload, _ = self.preview(
            "a,b,c;name\n1,2,3;Alice\n4,5,6;Bob\n", mode="array"
        )
        self.assertEqual((code, payload["status"]), (2, "needs-input"))
        self.assertEqual(payload["required_decisions"], ["delimiter"])

        code, payload, _ = self.preview(
            'a,b;c\n1,"2;3"\n',
            mode="array",
            types=["b;c=string"],
        )
        self.assertEqual((code, payload["status"]), (0, "ok"))
        self.assertEqual(payload["delimiter"]["selected"], "comma")
        self.assertEqual(payload["delimiter"]["candidates"], ["comma"])

        structural_fixture = "a,b;c\n1,2;3\n4,5\n"
        code, payload, _ = self.preview(
            structural_fixture,
            mode="array",
            types=["b;c=string"],
        )
        self.assertEqual((code, payload["status"]), (0, "ok"))
        self.assertEqual(payload["delimiter"]["selected"], "comma")
        self.assertEqual(payload["delimiter"]["candidates"], ["comma"])
        code, payload, _ = self.preview(
            structural_fixture,
            mode="array",
            delimiter="semicolon",
        )
        self.assertEqual((code, payload["status"]), (3, "rejected"))
        self.assertEqual(payload["diagnostics"]["shown"][0]["code"], "row-width")

    def test_type_inference_and_leading_zero_contract(self) -> None:
        code, preview, _ = self.preview(
            "integer,negative,decimal,flag,mixed,identifier\n"
            "1,-2,3.5,TRUE,x,00123\n"
            "2,-3,4.5,false,2,00456\n",
            mode="array",
        )
        self.assertEqual(code, 0)
        inferred = {column["name"]: column["inferred_type"] for column in preview["schema"]}
        self.assertEqual(
            inferred,
            {
                "integer": "number",
                "negative": "number",
                "decimal": "number",
                "flag": "boolean",
                "mixed": "string",
                "identifier": "string",
            },
        )

    def test_comma_separated_cells_render_string_arrays_and_round_trip(self) -> None:
        source = (
            "id,Assets,DefaultBus,DefaultVolume\n"
            'ui.button-click,"rbxassetid://123456,rbxassetid://1234562",UI,0.8\n'
            "ui.button-click1,rbxassetid://1234561,UI,0.82\n"
            "ui.button-click2,rbxassetid://1234562,UI,0.83\n"
        )
        code, preview, _ = self.preview(
            source,
            mode="dictionary",
            key="id",
        )
        self.assertEqual((code, preview["status"]), (0, "ok"))
        schema = {column["name"]: column for column in preview["schema"]}
        self.assertEqual(
            (schema["Assets"]["inferred_type"], schema["Assets"]["effective_type"]),
            ("array<string>", "array<string>"),
        )
        code, result, _ = apply_preview(
            self.repo,
            preview,
            mode="dictionary",
            key="id",
        )
        self.assertEqual((code, result["status"]), (0, "written"))
        output = self.repo.target.read_text(encoding="utf-8")
        self.assertIn(
            'Assets = {\n\t\t\t"rbxassetid://123456",\n'
            '\t\t\t"rbxassetid://1234562",\n\t\t},',
            output,
        )
        self.assertIn(
            'Assets = {\n\t\t\t"rbxassetid://1234561",\n\t\t},',
            output,
        )
        code, second, _ = self.preview(source)
        self.assertEqual((code, second["target"]["detected_mode"]), (0, "dictionary"))
        self.assertEqual(second["diff"], {"added": 0, "changed": 0, "removed": 0})

    def test_string_override_preserves_commas_and_invalid_arrays_reject(self) -> None:
        source = 'id,Assets\n1,"a,b"\n'
        code, preview, _ = self.preview(
            source,
            mode="array",
            types=["Assets=string"],
        )
        self.assertEqual(code, 0)
        schema = {column["name"]: column for column in preview["schema"]}
        self.assertEqual(
            (schema["Assets"]["inferred_type"], schema["Assets"]["effective_type"]),
            ("array<string>", "string"),
        )
        apply_preview(
            self.repo,
            preview,
            mode="array",
            types=["Assets=string"],
        )
        self.assertIn('Assets = "a,b"', self.repo.target.read_text(encoding="utf-8"))

        self.repo.target.unlink()
        for value in ("a,,b", ",a", "a,"):
            with self.subTest(value=value):
                code, payload, _ = self.preview(
                    f'id,Assets\n1,"{value}"\n',
                    mode="array",
                )
                self.assertEqual(code, 3)
                shown = payload["diagnostics"]["shown"][0]
                self.assertEqual(
                    (shown["code"], shown["logical_record"], shown["column"]),
                    ("array-element-empty", 2, "Assets"),
                )

        code, payload, _ = self.preview(
            'id,name\n"a,b",row\n',
            mode="dictionary",
            key="id",
        )
        self.assertEqual(code, 3)
        self.assertEqual(
            payload["diagnostics"]["shown"][0]["code"],
            "dictionary-key-array",
        )

    def test_pipe_candidate_requires_decision_then_renders_or_stays_string(self) -> None:
        source = "id,Assets\n1,rbxassetid://1|rbxassetid://2\n2,rbxassetid://3\n"
        code, preview, _ = self.preview(source, mode="array")
        self.assertEqual(
            (code, preview["status"], preview["required_decisions"]),
            (2, "needs-input", ["array_delimiter"]),
        )
        candidates = preview["array_candidates"]
        self.assertEqual((candidates["total"], candidates["truncated"]), (1, False))
        candidate = candidates["shown"][0]
        self.assertEqual(
            (
                candidate["column"],
                candidate["delimiter"],
                candidate["matching_cells"],
                candidate["non_empty_cells"],
                candidate["generated_elements"],
                candidate["sample"]["items"],
            ),
            ("Assets", "pipe", 1, 2, 3, ["rbxassetid://1", "rbxassetid://2"]),
        )
        self.assertFalse(self.repo.target.exists())

        code, selected, _ = self.preview(
            source,
            mode="array",
            array_delimiters=["Assets=pipe"],
        )
        self.assertEqual((code, selected["status"]), (0, "ok"))
        schema = {column["name"]: column for column in selected["schema"]}
        self.assertEqual(
            (schema["Assets"]["effective_type"], schema["Assets"]["array_delimiter"]),
            ("array<string>", "pipe"),
        )
        code, result, _ = apply_preview(
            self.repo,
            selected,
            mode="array",
            array_delimiters=["Assets=pipe"],
        )
        self.assertEqual((code, result["status"]), (0, "written"))
        output = self.repo.target.read_text(encoding="utf-8")
        self.assertIn('"rbxassetid://1",\n\t\t\t"rbxassetid://2",', output)

        code, scalar, _ = self.preview(
            source,
            mode="array",
            types=["Assets=string"],
        )
        self.assertEqual((code, scalar["status"], scalar["array_candidates"]["total"]), (0, "ok", 0))
        code, result, _ = apply_preview(
            self.repo,
            scalar,
            mode="array",
            types=["Assets=string"],
        )
        self.assertEqual((code, result["status"]), (0, "written"))
        self.assertIn(
            'Assets = "rbxassetid://1|rbxassetid://2"',
            self.repo.target.read_text(encoding="utf-8"),
        )

    def test_array_candidate_order_bound_and_override_validation(self) -> None:
        source = 'id,mixed,tabbed,multiline\n1,"a;b|c","d\te","f\ng"\n'
        code, payload, _ = self.preview(source, mode="array")
        self.assertEqual((code, payload["status"]), (2, "needs-input"))
        self.assertEqual(
            [(item["column"], item["delimiter"]) for item in payload["array_candidates"]["shown"]],
            [
                ("mixed", "semicolon"),
                ("mixed", "pipe"),
                ("tabbed", "tab"),
                ("multiline", "newline"),
            ],
        )

        headers = [f"c{index}" for index in range(40)]
        values = [f"a{index}|b{index}" for index in range(40)]
        code, bounded, raw = self.preview(
            ",".join(headers) + "\n" + ",".join(values) + "\n",
            mode="array",
        )
        self.assertEqual((code, bounded["array_candidates"]["total"]), (2, 40))
        self.assertEqual(
            (len(bounded["array_candidates"]["shown"]), bounded["array_candidates"]["truncated"]),
            (32, True),
        )
        self.assertLessEqual(len(raw), 256 * 1024)

        invalid_cases = (
            (["missing=pipe"], [], "array-delimiter-column"),
            (["mixed=pipe", "mixed=semicolon"], [], "array-delimiter-override-duplicate"),
            (["mixed=pipe"], ["mixed=string"], "array-delimiter-conflict"),
            (["mixed=unknown"], [], "array-delimiter-override"),
            (["mixed=newline"], [], "array-delimiter-unused"),
        )
        for array_delimiters, types, expected_code in invalid_cases:
            with self.subTest(expected_code=expected_code):
                code, rejected, _ = self.preview(
                    source,
                    mode="array",
                    array_delimiters=array_delimiters,
                    types=types,
                )
                self.assertEqual(code, 3)
                self.assertEqual(rejected["diagnostics"]["shown"][0]["code"], expected_code)

        code, rejected, _ = self.preview(
            "id,Assets\n1,a||b\n",
            mode="array",
            array_delimiters=["Assets=pipe"],
        )
        self.assertEqual(code, 3)
        self.assertEqual(rejected["diagnostics"]["shown"][0]["code"], "array-element-empty")

        self.repo.source.write_text("id,Assets\n1,a|b\n", encoding="utf-8", newline="\n")
        fake_hashes = {
            "source": {"sha256": "0" * 64},
            "target": {"sha256": None},
            "output": {"sha256": "0" * 64},
        }
        code, blocked, _ = run_cli(
            self.repo.args("apply", mode="array", hashes=fake_hashes)
        )
        self.assertEqual(
            (code, blocked["status"], blocked["required_decisions"]),
            (2, "needs-input", ["array_delimiter"]),
        )
        self.assertFalse(self.repo.target.exists())

    def test_string_override_and_incompatible_boolean_override(self) -> None:
        code, preview, _ = self.preview("id\n1\n2\n", mode="array", types=["id=string"])
        self.assertEqual(code, 0)
        apply_preview(self.repo, preview, mode="array", types=["id=string"])
        self.assertIn('id = "1"', self.repo.target.read_text(encoding="utf-8"))
        before = self.repo.target.read_bytes()
        code, payload, _ = self.preview("id\n1\n2\n", types=["id=boolean"])
        self.assertEqual(code, 3)
        self.assertEqual(self.repo.target.read_bytes(), before)

    def test_identifier_reserved_and_bracket_field_rendering(self) -> None:
        code, preview, _ = self.preview("name,display name,end\nA,B,C\n", mode="array")
        self.assertEqual(code, 0)
        apply_preview(self.repo, preview, mode="array")
        output = self.repo.target.read_text(encoding="utf-8")
        self.assertIn('name = "A"', output)
        self.assertIn('["display name"] = "B"', output)
        self.assertIn('["end"] = "C"', output)

    def test_empty_and_duplicate_headers_reject_before_write(self) -> None:
        for source in ("id,,name\n1,2,A\n", "id,id\n1,2\n"):
            with self.subTest(source=source):
                code, payload, _ = self.preview(source, mode="array")
                self.assertEqual((code, payload["status"]), (3, "rejected"))
                self.assertFalse(self.repo.target.exists())
                self.assertFalse(list(self.repo.data.glob(".*.tmp.luau")))

    def test_width_diagnostic_and_present_empty_cell(self) -> None:
        code, payload, _ = self.preview("id,name\n1\n", mode="array")
        self.assertEqual(code, 3)
        shown = payload["diagnostics"]["shown"][0]
        self.assertEqual((shown["code"], shown["logical_record"]), ("row-width", 2))
        code, payload, _ = self.preview("id,name\n1,\n", mode="array")
        self.assertEqual((code, payload["status"]), (0, "ok"))

    def test_empty_physical_lines_ignored_but_empty_records_rejected(self) -> None:
        code, payload, _ = self.preview("id,name\n\n1,A\n\n2,B\n", mode="array")
        self.assertEqual((code, payload["shape"]["records"]), (0, 2))
        for empty_record in ("id,name,note\n,,\n", 'id,name,note\n"","",""\n'):
            code, payload, _ = self.preview(empty_record, mode="array")
            self.assertEqual(code, 3)
            self.assertEqual(payload["diagnostics"]["shown"][0]["code"], "row-empty")

    def test_partial_row_omits_empty_fields_and_empty_dictionary_key_rejects(self) -> None:
        code, preview, _ = self.preview("id,name,note\n,Bob,\n", mode="array")
        self.assertEqual(code, 0)
        apply_preview(self.repo, preview, mode="array")
        output = self.repo.target.read_text(encoding="utf-8")
        self.assertIn('name = "Bob"', output)
        self.assertNotIn("id =", output)
        self.repo.target.unlink()
        code, payload, _ = self.preview("id,name,note\n,Bob,\n", mode="dictionary", key="id")
        self.assertEqual(code, 3)
        self.assertEqual(payload["diagnostics"]["shown"][0]["code"], "dictionary-key-empty")

    def test_duplicate_typed_dictionary_keys_reject_without_write(self) -> None:
        code, payload, _ = self.preview("id,name\n0,A\n-0,B\n", mode="dictionary", key="id")
        self.assertEqual(code, 3)
        self.assertEqual(payload["diagnostics"]["shown"][0]["code"], "dictionary-key-duplicate")
        self.assertFalse(self.repo.target.exists())

    def test_numeric_dictionary_key_is_retained_and_ordered(self) -> None:
        code, preview, _ = self.preview("id,name\n2,B\n1,A\n", mode="dictionary", key="id")
        self.assertEqual(code, 0)
        apply_preview(self.repo, preview, mode="dictionary", key="id")
        output = self.repo.target.read_text(encoding="utf-8")
        self.assertLess(output.index("\t[2] ="), output.index("\t[1] ="))
        self.assertIn("\t\tid = 2,", output)

    def test_string_escaping_unicode_controls_and_existing_parser_round_trip(self) -> None:
        source = "name,text\nrow,\"quote \"\" slash \\\\ tab\t bell\a snowman ☃\r\nnext\"\n"
        code, preview, _ = self.preview(source, mode="array", types=["text=string"])
        self.assertEqual(code, 0)
        apply_preview(self.repo, preview, mode="array", types=["text=string"])
        output = self.repo.target.read_text(encoding="utf-8")
        self.assertIn("\\\"", output)
        self.assertIn("\\\\", output)
        self.assertIn("\\t", output)
        self.assertIn("\\a", output)
        self.assertIn("☃", output)
        code, second, _ = self.preview(source, types=["text=string"])
        self.assertEqual((code, second["target"]["detected_mode"]), (0, "array"))

    def test_bounded_large_preview_has_complete_shape_schema_and_samples(self) -> None:
        rows = [f"{index},name-{index}" for index in range(100_000)]
        code, preview, raw = self.preview("id,name\n" + "\n".join(rows) + "\n", mode="array")
        self.assertEqual(code, 0)
        self.assertLessEqual(len(raw), 256 * 1024)
        self.assertEqual((preview["shape"]["records"], len(preview["schema"])), (100_000, 2))
        self.assertEqual((len(preview["samples"]["first"]), len(preview["samples"]["last"])), (3, 3))
        self.assertTrue(preview["samples"]["truncated"])

    def test_array_full_sync_diff_and_removal(self) -> None:
        code, preview, _ = self.preview("id,name\n1,A\n2,B\n3,C\n", mode="array")
        self.assertEqual(code, 0)
        apply_preview(self.repo, preview, mode="array")
        code, changed, _ = self.preview("id,name\n1,A\n2,B2\n", mode=None)
        self.assertEqual(code, 0)
        self.assertEqual(changed["diff"], {"added": 0, "changed": 1, "removed": 1})
        apply_preview(self.repo, changed)
        self.assertNotIn('name = "C"', self.repo.target.read_text(encoding="utf-8"))

    def test_dictionary_full_sync_detects_key_column_and_removal(self) -> None:
        code, preview, _ = self.preview("id,name\n1,A\n2,B\n", mode="dictionary", key="id")
        self.assertEqual(code, 0)
        apply_preview(self.repo, preview, mode="dictionary", key="id")
        code, changed, _ = self.preview("id,name\n2,B2\n3,C\n")
        self.assertEqual(code, 0)
        self.assertEqual((changed["mode"], changed["key_column"]), ("dictionary", "id"))
        self.assertEqual(changed["diff"], {"added": 1, "changed": 1, "removed": 1})

    def test_safe_prefix_comments_are_preserved_with_lf_normalization(self) -> None:
        self.repo.target.write_bytes(
            b"--!strict\r\n-- generated header\r\n--[=[long\r\ncomment]=]\r\n\r\nreturn {\r\n\t{\r\n\t\tid = 1,\r\n\t},\r\n}\r\n"
        )
        code, preview, _ = self.preview("id\n2\n")
        self.assertEqual(code, 0)
        apply_preview(self.repo, preview)
        output = self.repo.target.read_bytes()
        self.assertTrue(output.startswith(b"--!strict\n-- generated header\n--[=[long\ncomment]=]\n\nreturn"))
        self.assertNotIn(b"\r", output)

    def test_unsafe_luau_constructs_need_input_and_preserve_exact_bytes(self) -> None:
        unsafe = [
            "local x = 1\nreturn {\n}\n",
            "return require(script.Data)\n",
            "return { function() end }\n",
            "return setmetatable({}, {})\n",
            "return { { value = 1 + 2, }, }\n",
            "return { { value = 1, -- internal\n}, }\n",
            "return { { value = unknown, }, }\n",
            "return { { value = 1, }, }\nprint(\"extra\")\n",
        ]
        for content in unsafe:
            with self.subTest(content=content):
                before = content.encode("utf-8")
                self.repo.target.write_bytes(before)
                code, payload, _ = self.preview("id\n1\n")
                self.assertEqual((code, payload["status"]), (2, "needs-input"))
                self.assertEqual(payload["required_decisions"], ["unsafe_target_disposition"])
                self.assertEqual(self.repo.target.read_bytes(), before)

    def test_existing_mode_is_detected_and_apply_needs_no_confirmation_flag(self) -> None:
        code, preview, _ = self.preview("id\n1\n", mode="array")
        self.assertEqual(code, 0)
        apply_preview(self.repo, preview, mode="array")
        code, second, _ = self.preview("id\n2\n")
        self.assertEqual((code, second["status"], second["mode"]), (0, "ok", "array"))
        code, result, _ = apply_preview(self.repo, second)
        self.assertEqual((code, result["status"]), (0, "written"))

    def test_single_writer_precommit_failures_preserve_target_and_clean_owned_temp(self) -> None:
        for seam in (
            "temporary-write",
            "temporary-flush",
            "temporary-close",
            "before-replace",
            "at-replace",
            "unexpected-exception",
            "interrupt",
            "encode-success",
        ):
            with self.subTest(seam=seam):
                self.repo.target.write_text("--!strict\n\nreturn {\n\t{\n\t\tid = 1,\n\t},\n}\n", encoding="utf-8", newline="\n")
                before = self.repo.target.read_bytes()
                code, preview, _ = self.preview("id\n2\n")
                self.assertEqual(code, 0)
                code, payload, _ = apply_preview(self.repo, preview, env={"CSV_TO_LUAU_TEST_FAIL_AT": seam})
                self.assertIn(code, (3, 4))
                self.assertEqual(payload["status"], "rejected")
                self.assertEqual(self.repo.target.read_bytes(), before)
                self.assertFalse(list(self.repo.data.glob(".*.tmp.luau")))

    def test_owned_temporary_cleanup_failure_is_reported_not_silenced(self) -> None:
        self.repo.source.write_text("id\n1\n", encoding="utf-8", newline="\n")
        args = HELPER.build_parser().parse_args(
            self.repo.args("preview", mode="array", delimiter="comma")
        )
        conversion = HELPER.convert(args)
        original_unlink = Path.unlink

        def deny_owned_temp(path: Path, *call_args, **call_kwargs):
            if path.name.endswith(".tmp.luau"):
                raise PermissionError("injected owned-temp cleanup denial")
            return original_unlink(path, *call_args, **call_kwargs)

        try:
            with mock.patch.dict(
                os.environ,
                {"CSV_TO_LUAU_TEST_FAIL_AT": "before-replace"},
            ), mock.patch.object(Path, "unlink", deny_owned_temp):
                with self.assertRaises(HELPER.ConversionIssue) as caught:
                    HELPER.atomic_write(
                        conversion.target_path,
                        conversion.output_bytes,
                        conversion.target_bytes,
                    )
            self.assertEqual(caught.exception.code, "temporary-cleanup")
            leftovers = list(self.repo.data.glob(".*.tmp.luau"))
            self.assertEqual(len(leftovers), 1)
        finally:
            for leftover in self.repo.data.glob(".*.tmp.luau"):
                original_unlink(leftover)

    def test_single_writer_cleanup_never_deletes_unknown_siblings(self) -> None:
        code, preview, _ = self.preview("id\n1\n", mode="array")
        self.assertEqual(code, 0)
        stale_temp = self.repo.data / f".{self.repo.target.name}.{uuid.uuid4().hex}.tmp.luau"
        unknown = self.repo.data / f".{self.repo.target.name}.{uuid.uuid4().hex}.keep"
        stale_temp.write_bytes(b"legitimate sibling temp-like bytes")
        unknown.write_bytes(b"legitimate unknown sibling bytes")
        code, result, _ = apply_preview(self.repo, preview, mode="array")
        self.assertEqual((code, result["status"]), (0, "written"))
        self.assertEqual(stale_temp.read_bytes(), b"legitimate sibling temp-like bytes")
        self.assertEqual(unknown.read_bytes(), b"legitimate unknown sibling bytes")
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("recover_stale_temporaries", source)
        self.assertNotIn("os.scandir", source)

    def test_postcommit_failures_keep_output_without_rollback(self) -> None:
        for seam in (
            "after-replace",
            "after-replace-interrupt",
            "after-commit",
            "stdout",
        ):
            with self.subTest(seam=seam):
                self.repo.target.write_text(
                    "--!strict\n\nreturn {\n\t{\n\t\tid = 1,\n\t},\n}\n",
                    encoding="utf-8",
                    newline="\n",
                )
                code, preview, _ = self.preview("id\n2\n")
                self.assertEqual(code, 0)
                environment = os.environ.copy()
                environment.update(
                    {
                        "PYTHONDONTWRITEBYTECODE": "1",
                        "CSV_TO_LUAU_TEST_FAIL_AT": seam,
                    }
                )
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), *self.repo.args("apply", hashes=preview)],
                    check=False,
                    capture_output=True,
                    timeout=TIMEOUT_SECONDS,
                    env=environment,
                )
                self.assertEqual(result.returncode, 4)
                self.assertEqual(
                    HELPER.sha256(self.repo.target.read_bytes()),
                    preview["output"]["sha256"],
                )
                self.assertFalse(
                    [
                        path
                        for path in self.repo.data.glob(".*.tmp.luau")
                        if path.is_file()
                    ]
                )

    def test_partial_stdout_emits_no_second_json_and_keeps_committed_output(self) -> None:
        code, preview, _ = self.preview("id\n1\n", mode="array")
        self.assertEqual(code, 0)
        environment = os.environ.copy()
        environment.update(
            {
                "PYTHONDONTWRITEBYTECODE": "1",
                "CSV_TO_LUAU_TEST_FAIL_AT": "stdout-partial",
            }
        )
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                *self.repo.args("apply", mode="array", hashes=preview),
            ],
            check=False,
            capture_output=True,
            timeout=TIMEOUT_SECONDS,
            env=environment,
        )
        self.assertEqual(result.returncode, 4)
        self.assertGreater(len(result.stdout), 0)
        with self.assertRaises(json.JSONDecodeError):
            json.loads(result.stdout.decode("utf-8"))
        self.assertNotIn(b"}{", result.stdout)
        self.assertLessEqual(len(result.stdout), 32)
        self.assertEqual(
            HELPER.sha256(self.repo.target.read_bytes()),
            preview["output"]["sha256"],
        )

    def test_apply_transaction_detects_source_target_and_parent_changes(self) -> None:
        code, first, _ = self.preview("id\n1\n", mode="array")
        self.assertEqual(code, 0)
        apply_preview(self.repo, first, mode="array")
        original = self.repo.target.read_bytes()

        code, changed, _ = self.preview("id\n2\n")
        self.assertEqual(code, 0)
        arguments = self.repo.args("apply", hashes=changed)
        args = HELPER.build_parser().parse_args(arguments)
        conversion = HELPER.convert(args)

        concurrent = b"--!strict\n\nreturn {\n\t{\n\t\tid = 99,\n\t},\n}\n"

        def target_validator() -> None:
            self.repo.target.write_bytes(concurrent)
            HELPER.revalidate_conversion(conversion, args)

        with self.assertRaises(HELPER.ConversionIssue) as caught:
            HELPER.atomic_write(
                self.repo.target,
                conversion.output_bytes,
                conversion.target_bytes,
                target_validator,
            )
        self.assertEqual(caught.exception.code, "target-changed")
        self.assertEqual(self.repo.target.read_bytes(), concurrent)
        self.assertFalse(list(self.repo.data.glob(".*.tmp.luau")))

        self.repo.target.write_bytes(original)
        conversion = HELPER.convert(args)

        def source_validator() -> None:
            self.repo.source.write_text("id\n3\n", encoding="utf-8")
            HELPER.revalidate_conversion(conversion, args)

        with self.assertRaises(HELPER.ConversionIssue) as caught:
            HELPER.atomic_write(
                self.repo.target,
                conversion.output_bytes,
                conversion.target_bytes,
                source_validator,
            )
        self.assertEqual(caught.exception.code, "source-changed")
        self.assertEqual(self.repo.target.read_bytes(), original)

        self.repo.source.write_text("id\n2\n", encoding="utf-8", newline="\n")
        conversion = HELPER.convert(args)
        old_parent = self.repo.mapped / "Data.old"
        self.repo.data.rename(old_parent)
        self.repo.data.mkdir()
        try:
            with self.assertRaises(HELPER.ConversionIssue) as caught:
                HELPER.revalidate_conversion(conversion, args)
            self.assertEqual(caught.exception.code, "target-changed")
        finally:
            self.repo.data.rmdir()
            old_parent.rename(self.repo.data)

    def test_source_target_exact_path_alias_is_rejected(self) -> None:
        self.repo.target.write_text("id\n1\n", encoding="utf-8", newline="\n")
        exact_args = [
            "preview",
            "--repo-root",
            str(self.repo.root),
            "--source",
            str(self.repo.target),
            "--target",
            str(self.repo.target),
            "--mode",
            "array",
            "--delimiter",
            "comma",
        ]
        before = self.repo.target.read_bytes()
        code, payload, _ = run_cli(exact_args)
        self.assertEqual((code, payload["diagnostics"]["shown"][0]["code"]), (3, "source-target-alias"))
        self.assertEqual(self.repo.target.read_bytes(), before)

    def test_three_hash_guard_rejects_each_changed_input(self) -> None:
        code, preview, _ = self.preview("id\n1\n", mode="array")
        self.assertEqual(code, 0)
        self.repo.source.write_text("id\n2\n", encoding="utf-8")
        code, payload, _ = apply_preview(self.repo, preview, mode="array")
        self.assertEqual((code, payload["diagnostics"]["shown"][0]["code"]), (3, "source-changed"))

        code, preview, _ = self.preview("id\n1\n", mode="array")
        self.assertEqual(code, 0)
        self.repo.target.write_text("--!strict\n\nreturn {\n\t{\n\t\tid = 9,\n\t},\n}\n", encoding="utf-8")
        code, payload, _ = apply_preview(self.repo, preview, mode="array")
        self.assertEqual((code, payload["diagnostics"]["shown"][0]["code"]), (3, "target-changed"))

        self.repo.target.unlink()
        code, preview, _ = self.preview("id\n1\n", mode="array")
        self.assertEqual(code, 0)
        preview["output"]["sha256"] = "0" * 64
        code, payload, _ = apply_preview(self.repo, preview, mode="array")
        self.assertEqual((code, payload["diagnostics"]["shown"][0]["code"]), (3, "output-changed"))

    def test_deterministic_idempotent_second_apply_is_unchanged(self) -> None:
        code, preview, _ = self.preview("id,name\n1,Å\n", mode="array")
        self.assertEqual(code, 0)
        code, first, _ = apply_preview(self.repo, preview, mode="array")
        first_bytes = self.repo.target.read_bytes()
        code, second_preview, _ = self.preview("id,name\n1,Å\n")
        self.assertEqual(code, 0)
        code, second, _ = apply_preview(self.repo, second_preview)
        self.assertEqual((code, second["status"], second["diff"]), (0, "unchanged", {"added": 0, "changed": 0, "removed": 0}))
        self.assertEqual(self.repo.target.read_bytes(), first_bytes)
        self.assertEqual(first["target"]["sha256"], second["target"]["sha256"])

    def test_header_only_canonical_output_reparses_and_is_unchanged(self) -> None:
        for mode, key in (("array", None), ("dictionary", "id")):
            with self.subTest(mode=mode):
                if self.repo.target.exists():
                    self.repo.target.unlink()
                code, preview, _ = self.preview(
                    "id\n",
                    mode=mode,
                    key=key,
                    delimiter="comma",
                )
                self.assertEqual(code, 0)
                code, first, _ = apply_preview(
                    self.repo,
                    preview,
                    mode=mode,
                    key=key,
                    delimiter="comma",
                )
                self.assertEqual((code, first["status"]), (0, "written"))
                first_bytes = self.repo.target.read_bytes()
                code, decision, _ = self.preview(
                    "id\n",
                    delimiter="comma",
                )
                self.assertEqual(
                    (code, decision["status"], decision["required_decisions"]),
                    (2, "needs-input", ["mode"]),
                )
                self.assertEqual(
                    decision["diagnostics"]["shown"][0]["source"],
                    "src/Data/Generated.luau",
                )
                self.assertEqual(self.repo.target.read_bytes(), first_bytes)
                code, second_preview, _ = self.preview(
                    "id\n",
                    mode=mode,
                    key=key,
                    delimiter="comma",
                )
                self.assertEqual(code, 0)
                code, second, _ = apply_preview(
                    self.repo,
                    second_preview,
                    mode=mode,
                    key=key,
                    delimiter="comma",
                )
                self.assertEqual((code, second["status"]), (0, "unchanged"))
                self.assertEqual(self.repo.target.read_bytes(), first_bytes)

    def test_success_and_rejection_summaries_are_target_scoped_and_bounded(self) -> None:
        code, preview, _ = self.preview("id\n1\n", mode="array")
        self.assertEqual(code, 0)
        code, result, raw = apply_preview(self.repo, preview, mode="array")
        self.assertEqual(code, 0)
        self.assertEqual(result["target"]["repo_relative_path"], "src/Data/Generated.luau")
        self.assertEqual(result["records"], 1)
        self.assertLessEqual(len(raw), 256 * 1024)
        before = self.repo.target.read_bytes()
        code, payload, _ = self.preview("id,id\n1,2\n", mode=None)
        self.assertEqual(code, 3)
        self.assertEqual(self.repo.target.read_bytes(), before)

    def test_capability_failures_are_exit_four_and_non_mutating(self) -> None:
        self.repo.source.write_text("id\n1\n", encoding="utf-8")
        project = self.repo.root / "default.project.json"
        project.unlink()
        code, payload, _ = run_cli(self.repo.args("preview", mode="array"))
        self.assertEqual((code, payload["status"]), (4, "rejected"))
        self.assertFalse(self.repo.target.exists())

        project.write_text('{"name":"x","tree":{"R":{"$path":"src"}}}', encoding="utf-8")
        code, payload, _ = run_cli(self.repo.args("preview", mode="array"), env={"PATH": ""})
        self.assertEqual((code, payload["status"]), (4, "rejected"))
        self.assertFalse(self.repo.target.exists())


class BudgetAndPackageContractTests(unittest.TestCase):
    def test_source_budget_below_at_above(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "input.csv"
            with patched_limits(source_bytes=10):
                for size, rejected in ((9, False), (10, False), (11, True)):
                    source.write_bytes(b"a" * size)
                    with self.subTest(size=size):
                        if rejected:
                            with self.assertRaises(HELPER.ConversionIssue) as caught:
                                HELPER.read_source(str(source))
                            self.assertEqual(caught.exception.code, "source-too-large")
                        else:
                            self.assertEqual(len(HELPER.read_source(str(source))[1]), size)

    def test_target_budget_below_at_above(self) -> None:
        repo = FixtureRepository()
        try:
            with patched_limits(target_bytes=10):
                for size, rejected in ((9, False), (10, False), (11, True)):
                    repo.target.write_bytes(b"a" * size)
                    with self.subTest(size=size):
                        if rejected:
                            with self.assertRaises(HELPER.ConversionIssue) as caught:
                                HELPER.resolve_target(repo.root, [repo.mapped.resolve()], str(repo.target))
                            self.assertEqual(caught.exception.code, "target-too-large")
                        else:
                            self.assertEqual(len(HELPER.resolve_target(repo.root, [repo.mapped.resolve()], str(repo.target))[2]), size)
        finally:
            repo.close()

    def test_field_and_record_budgets_below_at_above(self) -> None:
        with patched_limits(field_bytes=5, record_bytes=100):
            HELPER.parse_csv("aaaa\n", ",", "source.csv")
            HELPER.parse_csv("aaaaa\n", ",", "source.csv")
            with self.assertRaises(HELPER.ConversionIssue) as caught:
                HELPER.parse_csv("aaaaaa\n", ",", "source.csv")
            self.assertEqual(caught.exception.code, "field-too-large")
        with patched_limits(field_bytes=100, record_bytes=5):
            HELPER.parse_csv("aaaa", ",", "source.csv")
            HELPER.parse_csv("aaaaa", ",", "source.csv")
            with self.assertRaises(HELPER.ConversionIssue) as caught:
                HELPER.parse_csv("aaaaaa", ",", "source.csv")
            self.assertEqual(caught.exception.code, "record-too-large")

    def test_record_column_and_cell_budgets_below_at_above(self) -> None:
        field = lambda text: HELPER.ParsedField(text, False, 1)
        record = lambda number, values: HELPER.LogicalRecord(number, number, tuple(field(value) for value in values))
        with patched_limits(records=2, columns=10, cells=10):
            HELPER.infer_and_convert([record(1, ["id"]), record(2, ["1"]), record(3, ["2"])], "x.csv", [])
            with self.assertRaises(HELPER.ConversionIssue):
                HELPER.infer_and_convert([record(1, ["id"]), record(2, ["1"]), record(3, ["2"]), record(4, ["3"])], "x.csv", [])
        with patched_limits(records=10, columns=2, cells=10):
            HELPER.infer_and_convert([record(1, ["a"]), record(2, ["1"])], "x.csv", [])
            HELPER.infer_and_convert([record(1, ["a", "b"]), record(2, ["1", "2"])], "x.csv", [])
            with self.assertRaises(HELPER.ConversionIssue):
                HELPER.infer_and_convert([record(1, ["a", "b", "c"]), record(2, ["1", "2", "3"])], "x.csv", [])
        with patched_limits(records=10, columns=10, cells=2):
            HELPER.infer_and_convert([record(1, ["a", "b"]), record(2, ["1", "2"])], "x.csv", [])
            with self.assertRaises(HELPER.ConversionIssue):
                HELPER.infer_and_convert([record(1, ["a", "b"]), record(2, ["1", "2"]), record(3, ["3", "4"])], "x.csv", [])
            HELPER.infer_and_convert([record(1, ["items"]), record(2, ["a,b"])], "x.csv", [])
            with self.assertRaises(HELPER.ConversionIssue) as caught:
                HELPER.infer_and_convert([record(1, ["items"]), record(2, ["a,b,c"])], "x.csv", [])
            self.assertEqual(caught.exception.code, "cells-too-many")

    def test_output_budget_below_at_above(self) -> None:
        scalar = HELPER.Scalar("string", "x", "x")
        baseline = HELPER.render_module(
            "", ["a"], [{"a": scalar}], "array", [], source_name="source.csv"
        )
        size = len(baseline)
        with patched_limits(output_bytes=size + 1):
            HELPER.render_module(
                "", ["a"], [{"a": scalar}], "array", [], source_name="source.csv"
            )
        with patched_limits(output_bytes=size):
            HELPER.render_module(
                "", ["a"], [{"a": scalar}], "array", [], source_name="source.csv"
            )
        with patched_limits(output_bytes=size - 1):
            with self.assertRaises(HELPER.ConversionIssue) as caught:
                HELPER.render_module(
                    "",
                    ["a"],
                    [{"a": scalar}],
                    "array",
                    [],
                    source_name="source.csv",
                )
            self.assertEqual(caught.exception.code, "output-too-large")
            self.assertEqual(caught.exception.diagnostics[0]["source"], "source.csv")

    def test_diagnostic_sample_and_json_budgets(self) -> None:
        field = HELPER.ParsedField("", False, 1)
        with patched_limits(diagnostics=2, columns=256):
            for count, shown, total in ((1, 1, 1), (2, 2, 2), (3, 2, 3)):
                bad_header = HELPER.LogicalRecord(1, 1, tuple(field for _ in range(count)))
                with self.subTest(diagnostic_count=count):
                    with self.assertRaises(HELPER.ConversionIssue) as caught:
                        HELPER.infer_and_convert([bad_header], "x.csv", [])
                    self.assertEqual(len(caught.exception.diagnostics), shown)
                    self.assertEqual(caught.exception.diagnostic_total, total)
        rows = [{"a": HELPER.Scalar("string", str(index), str(index))} for index in range(7)]
        with patched_limits(sample_first=3, sample_last=3):
            for count, expected in (
                (5, (3, 2, False)),
                (6, (3, 3, False)),
                (7, (3, 3, True)),
            ):
                with self.subTest(sample_count=count):
                    samples = HELPER.make_samples(rows[:count], ["a"], "array", [])
                    self.assertEqual(
                        (len(samples["first"]), len(samples["last"]), samples["truncated"]),
                        expected,
                    )
        small_payload = {
            "operation": "preview",
            "status": "ok",
            "samples": {"first": ["x" * 1_000], "last": [], "truncated": False},
            "diagnostics": {"total": 0, "shown": []},
        }
        raw_size = len(json.dumps(small_payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")) + 1
        for limit in (raw_size + 1, raw_size, raw_size - 1):
            with self.subTest(json_limit=limit), patched_limits(json_bytes=limit):
                self.assertLessEqual(len(HELPER.encode_payload(small_payload)), limit)
        payload = {"operation": "preview", "status": "ok", "samples": {"first": ["x" * 300_000], "last": [], "truncated": True}, "diagnostics": {"total": 0, "shown": []}}
        encoded = HELPER.encode_payload(payload)
        self.assertLessEqual(len(encoded), HELPER.LIMITS["json_bytes"])

        headers = [f"column-{index}-" + "x" * 96 for index in range(256)]
        rows = [
            {
                header: HELPER.Scalar("string", "v" * 64, "v" * 64)
                for header in headers
            }
            for _ in range(7)
        ]
        wide_payload = {
            "operation": "preview",
            "status": "ok",
            "schema": [{"name": header, "inferred_type": "string"} for header in headers],
            "samples": HELPER.make_samples(rows, headers, "array", []),
            "diagnostics": {"total": 0, "shown": []},
        }
        reduced = json.loads(HELPER.encode_payload(wide_payload).decode("utf-8"))
        self.assertEqual(
            (len(reduced["samples"]["first"]), len(reduced["samples"]["last"])),
            (3, 3),
        )

        huge_key_payload = {
            "operation": "preview",
            "status": "ok",
            "shape": {"records": 0, "columns": 1, "empty_cells": 0},
            "mode": "dictionary",
            "key_column": "k" * 300_000,
            "schema": [{"name": "k" * 300_000, "inferred_type": "empty"}],
            "samples": {"first": [], "last": [], "truncated": False},
            "diagnostics": {"total": 0, "shown": []},
        }
        huge_key_encoded = HELPER.encode_payload(huge_key_payload)
        self.assertLessEqual(len(huge_key_encoded), HELPER.LIMITS["json_bytes"])
        self.assertEqual(json.loads(huge_key_encoded)["operation"], "preview")

    def test_chat_and_full_diff_budget_below_at_above(self) -> None:
        def capture(byte_count: int, line_count: int) -> bytes:
            separators = max(0, line_count - 1)
            self.assertGreaterEqual(byte_count, separators + 1)
            return b"\n" * separators + b"x" * (byte_count - separators)

        byte_limit = HELPER.LIMITS["chat_bytes"]
        line_limit = HELPER.LIMITS["chat_lines"]
        cases = (
            (byte_limit - 1, line_limit - 1, True),
            (byte_limit, line_limit, True),
            (byte_limit + 1, line_limit, False),
            (byte_limit, line_limit + 1, False),
        )
        for byte_count, line_count, expected in cases:
            with self.subTest(bytes=byte_count, lines=line_count):
                candidate = capture(byte_count, line_count)
                self.assertEqual(
                    full_diff_capture_fits_chat_budget(candidate, complete=True),
                    expected,
                )
        self.assertFalse(
            full_diff_capture_fits_chat_budget(
                capture(byte_limit - 1, line_limit - 1),
                complete=False,
            )
        )

        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        compact_skill = " ".join(skill.split())
        self.assertIn(
            "complete capture proves the full diff is at most 16 KiB and at most 200 lines",
            compact_skill,
        )

    def test_combined_memory_and_rojo_project_structural_budgets(self) -> None:
        estimate = HELPER.estimated_peak_memory(
            project_bytes=100,
            source_bytes=1_000,
            target_bytes=2_000,
            output_bytes=3_000,
            records=10,
            columns=2,
            cells=20,
        )
        with patched_limits(memory_bytes=estimate):
            self.assertEqual(
                HELPER.enforce_memory_budget(
                    source="source.csv",
                    project_bytes=100,
                    source_bytes=1_000,
                    target_bytes=2_000,
                    output_bytes=3_000,
                    records=10,
                    columns=2,
                    cells=20,
                ),
                estimate,
            )
        with patched_limits(memory_bytes=estimate - 1):
            with self.assertRaises(HELPER.ConversionIssue) as caught:
                HELPER.enforce_memory_budget(
                    source="source.csv",
                    project_bytes=100,
                    source_bytes=1_000,
                    target_bytes=2_000,
                    output_bytes=3_000,
                    records=10,
                    columns=2,
                    cells=20,
                )
            self.assertEqual(caught.exception.code, "memory-budget")
            self.assertEqual(caught.exception.diagnostics[0]["source"], "source.csv")

        repo = FixtureRepository()
        project = repo.root / "default.project.json"
        original = project.read_bytes()
        try:
            with patched_limits(project_bytes=len(original) - 1):
                with self.assertRaises(HELPER.ConversionIssue) as caught:
                    HELPER.resolve_repository(str(repo.root))
                self.assertEqual(caught.exception.code, "rojo-project-too-large")

            project.write_text(
                json.dumps({"$path": "src", "nested": [[[[[0]]]]]}),
                encoding="utf-8",
            )
            with patched_limits(project_depth=5):
                with self.assertRaises(HELPER.ConversionIssue) as caught:
                    HELPER.resolve_repository(str(repo.root))
                self.assertEqual(caught.exception.code, "rojo-project-depth")

            project.write_text(
                json.dumps({"$path": "src", "items": list(range(20))}),
                encoding="utf-8",
            )
            with patched_limits(project_nodes=10):
                with self.assertRaises(HELPER.ConversionIssue) as caught:
                    HELPER.resolve_repository(str(repo.root))
                self.assertEqual(caught.exception.code, "rojo-project-nodes")
        finally:
            project.write_bytes(original)
            repo.close()

    def test_delimiter_evaluation_retains_at_most_one_full_graph(self) -> None:
        original = HELPER.parse_csv
        state = {"live": 0, "peak": 0}

        class TrackedRecords(list):
            def __init__(self, values):
                super().__init__(values)
                state["live"] += 1
                state["peak"] = max(state["peak"], state["live"])

            def __del__(self):
                state["live"] -= 1

        def tracked(*args, **kwargs):
            gc.collect()
            return TrackedRecords(original(*args, **kwargs))

        HELPER.parse_csv = tracked
        records = None
        try:
            _name, _delimiter, records, candidates = HELPER.select_delimiter(
                "h\nx\n", "input.csv", None
            )
            self.assertEqual(candidates, ["comma", "semicolon", "tab", "pipe"])
            self.assertLessEqual(state["peak"], 1)
        finally:
            records = None
            HELPER.parse_csv = original
            gc.collect()

    def test_existing_luau_scanners_have_linear_suffix_behavior(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("self.text[self.index:]", source)
        self.assertNotIn("text[index:]", source)

        def elapsed(comment_count: int) -> float:
            text = "-- h\n" * comment_count + "return {}\n"
            started = time.perf_counter()
            prefix, return_end = HELPER.scan_luau_prefix(text, "Generated.luau")
            duration = time.perf_counter() - started
            self.assertEqual(prefix, "-- h\n" * comment_count)
            self.assertEqual(text[return_end:], " {}\n")
            return duration

        small = min(elapsed(20_000) for _ in range(2))
        large = min(elapsed(80_000) for _ in range(2))
        self.assertLess(large, small * 7.0)

    def test_helper_git_has_no_timeout_and_test_harness_retains_120_seconds(self) -> None:
        repo = FixtureRepository()
        calls: list[dict] = []

        def completed_git(*args, **kwargs):
            calls.append(kwargs)
            return subprocess.CompletedProcess(
                args=args[0],
                returncode=0,
                stdout=str(repo.root) + "\n",
                stderr="",
            )

        try:
            with mock.patch.object(HELPER.subprocess, "run", side_effect=completed_git):
                resolved, _project, mapped, _project_bytes = HELPER.resolve_repository(
                    str(repo.root)
                )
            self.assertEqual(resolved, repo.root.resolve(strict=True))
            self.assertTrue(mapped)
            self.assertEqual(len(calls), 1)
            self.assertNotIn("timeout", calls[0])

            helper_tree = ast.parse(SCRIPT.read_text(encoding="utf-8"))
            helper_timeouts = [
                keyword
                for node in ast.walk(helper_tree)
                if isinstance(node, ast.Call)
                for keyword in node.keywords
                if keyword.arg == "timeout"
            ]
            self.assertFalse(helper_timeouts)

            test_tree = ast.parse(Path(__file__).read_text(encoding="utf-8"))
            test_timeouts = [
                keyword.value
                for node in ast.walk(test_tree)
                if isinstance(node, ast.Call)
                for keyword in node.keywords
                if keyword.arg == "timeout"
            ]
            self.assertTrue(test_timeouts)
            self.assertTrue(
                all(
                    isinstance(value, ast.Name) and value.id == "TIMEOUT_SECONDS"
                    for value in test_timeouts
                )
            )
            self.assertEqual(TIMEOUT_SECONDS, 120)
        finally:
            repo.close()

    def test_option_like_target_is_safe_in_documented_git_argv(self) -> None:
        repo = FixtureRepository()
        try:
            (repo.root / "default.project.json").write_text(
                json.dumps({"name": "git-argv", "tree": {"$path": "."}}),
                encoding="utf-8",
            )
            target = repo.root / "--output=foo.luau"
            repo.source.write_text("id\n1\n", encoding="utf-8")
            code, preview, _ = run_cli(repo.args("preview", target=target, mode="array"))
            self.assertEqual(code, 0)
            code, result, _ = apply_preview(repo, preview, target=target, mode="array")
            self.assertEqual((code, result["status"]), (0, "written"))
            relative = result["target"]["repo_relative_path"]
            status = subprocess.run(
                ["git", "-C", str(repo.root), "status", "--short", "--", relative],
                check=False,
                capture_output=True,
                text=True,
                timeout=TIMEOUT_SECONDS,
            )
            self.assertEqual(status.returncode, 0)
            self.assertIn("--output=foo.luau", status.stdout)
            target.write_text("line\n" * 5_000, encoding="utf-8", newline="\n")
            for summary_option in ("--numstat", "--stat"):
                no_index = subprocess.run(
                    [
                        "git",
                        "-C",
                        str(repo.root),
                        "diff",
                        "--no-index",
                        summary_option,
                        "--",
                        os.devnull,
                        relative,
                    ],
                    check=False,
                    capture_output=True,
                    timeout=TIMEOUT_SECONDS,
                )
                self.assertEqual(no_index.returncode, 1)
                self.assertTrue(no_index.stdout)
                self.assertLess(len(no_index.stdout), 4_096)
                self.assertLess(len(no_index.stdout.splitlines()), 10)
            self.assertFalse((repo.root / "foo.luau").exists())
        finally:
            repo.close()

    def test_package_exactly_four_files_metadata_and_single_writer_contract(self) -> None:
        files = sorted(path.relative_to(SKILL_ROOT).as_posix() for path in SKILL_ROOT.rglob("*") if path.is_file())
        self.assertEqual(
            files,
            ["SKILL.md", "agents/openai.yaml", "scripts/csv_to_luau.py", "scripts/test_csv_to_luau.py"],
        )
        metadata = (SKILL_ROOT / "agents" / "openai.yaml").read_text(encoding="utf-8")
        self.assertEqual(
            metadata,
            "interface:\n"
            "  display_name: \"CSV to Luau\"\n"
            "  short_description: \"Convert CSV into safe Luau data modules\"\n"
            "  default_prompt: \"Use $csv-to-luau to convert an attached or local CSV into a repository-owned Luau data module.\"\n\n"
            "policy:\n"
            "  allow_implicit_invocation: false\n",
        )
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        compact_skill = " ".join(skill.split())
        frontmatter = skill.split("---", 2)[1]
        keys = [line.split(":", 1)[0] for line in frontmatter.splitlines() if ":" in line]
        self.assertEqual(keys, ["name", "description"])
        self.assertIn("ensure-rojo-server.ps1", skill)
        self.assertIn("git diff --numstat", skill)
        self.assertIn("os.devnull", skill)
        self.assertIn("git status --short -- <target>", skill)
        self.assertIn("git diff --no-index --numstat -- <os.devnull> <target>", skill)
        self.assertIn("git diff --no-index --stat -- <os.devnull> <target>", skill)
        self.assertNotIn("git diff --no-index -- <os.devnull> <target>", skill)
        self.assertIn("at most 16 KiB and at most 200 lines", compact_skill)
        self.assertIn("complete parseable exit-2", compact_skill)
        self.assertIn("complete parseable exit-3", compact_skill)
        self.assertIn("Treat exit 4", compact_skill)
        self.assertIn(
            "re-run `preview` instead of retrying the write with stale",
            compact_skill,
        )
        self.assertIn("single sequential invocation", skill)
        self.assertIn("Never retry the write", skill)
        self.assertIn("Never roll back", skill)
        self.assertNotIn("reconcile", skill.lower())

        helper = SCRIPT.read_text(encoding="utf-8")
        for forbidden in (
            "class ApplyLock",
            "LOCK_MAGIC",
            "csv-to-luau-locks",
            "os.link(",
            "os.scandir",
            "time.sleep(",
            "reconcile",
            "rollback_write",
            "recover_stale_temporaries",
        ):
            self.assertNotIn(forbidden, helper)
        self.assertIn(".tmp.luau", helper)
        self.assertIn("os.fsync", helper)
        self.assertEqual(helper.count("os.replace("), 1)

    def test_no_external_runtime_dependency_or_platform_shell_pipeline(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        forbidden = ("import pandas", "import yaml", "import requests", "shell=True", "pip install", "loadstring", "Start-Process")
        for token in forbidden:
            self.assertNotIn(token, source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
