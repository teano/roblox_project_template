#!/usr/bin/env python3
"""Deterministically convert strict UTF-8 CSV data to a safe Luau module."""

from __future__ import annotations

import argparse
import dataclasses
import decimal
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid
from typing import Any, Callable, Iterable, NoReturn, Sequence


LIMITS = {
    "source_bytes": 32 * 1024 * 1024,
    "target_bytes": 64 * 1024 * 1024,
    "output_bytes": 64 * 1024 * 1024,
    "records": 100_000,
    "columns": 256,
    "cells": 1_000_000,
    "field_bytes": 1 * 1024 * 1024,
    "record_bytes": 4 * 1024 * 1024,
    "diagnostics": 50,
    "sample_first": 3,
    "sample_last": 3,
    "array_candidates": 32,
    "json_bytes": 256 * 1024,
    "chat_bytes": 16 * 1024,
    "chat_lines": 200,
    "memory_bytes": 512 * 1024 * 1024,
    "project_bytes": 1 * 1024 * 1024,
    "project_nodes": 100_000,
    "project_depth": 64,
}

DELIMITERS = {
    "comma": ",",
    "semicolon": ";",
    "tab": "\t",
    "pipe": "|",
}
DELIMITER_ORDER = tuple(DELIMITERS)
ARRAY_DELIMITERS = {
    "comma": ",",
    "semicolon": ";",
    "pipe": "|",
    "tab": "\t",
    "newline": "\n",
}
ARRAY_CANDIDATE_ORDER = ("semicolon", "pipe", "tab", "newline")
NUMBER_RE = re.compile(
    r"[+-]?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\Z"
)
IDENTIFIER_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
IDENTIFIER_TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
NUMBER_TOKEN_RE = re.compile(
    r"[+-]?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"
)
LONG_COMMENT_RE = re.compile(r"--\[(=*)\[")
RETURN_TOKEN_RE = re.compile(r"return\b")
LUA_RESERVED = {
    "and", "break", "do", "else", "elseif", "end", "false", "for",
    "function", "if", "in", "local", "nil", "not", "or", "repeat",
    "return", "then", "true", "until", "while",
}
HEX = set("0123456789abcdefABCDEF")


@dataclasses.dataclass(frozen=True)
class ParsedField:
    text: str
    quoted: bool
    physical_start_line: int


@dataclasses.dataclass(frozen=True)
class LogicalRecord:
    logical_number: int
    physical_start_line: int
    fields: tuple[ParsedField, ...]


@dataclasses.dataclass(frozen=True)
class Scalar:
    kind: str
    value: str | bool | float | tuple[Scalar, ...]
    canonical: str

    @property
    def key(self) -> tuple[str, str]:
        if self.kind == "array":
            raise ValueError("array values cannot be dictionary keys")
        if self.kind == "string":
            return (self.kind, str(self.value))
        return (self.kind, self.canonical)

    def json_value(self) -> Any:
        if self.kind == "array":
            assert isinstance(self.value, tuple)
            return [item.json_value() for item in self.value]
        if self.kind == "number":
            number = float(self.value)
            if number.is_integer() and abs(number) <= 9_007_199_254_740_992:
                return int(number)
            return number
        return self.value


@dataclasses.dataclass
class ExistingData:
    mode: str
    rows: list[dict[str, Scalar]]
    keys: list[Scalar]
    key_column: str | None
    prefix: str


@dataclasses.dataclass
class Conversion:
    repo_root: Path
    source_path: Path
    source_bytes: bytes
    target_path: Path
    target_relative: str
    target_bytes: bytes | None
    delimiter_name: str
    delimiter_candidates: list[str]
    headers: list[str]
    schemas: list[dict[str, Any]]
    array_candidates: list[dict[str, Any]]
    array_candidate_total: int
    rows: list[dict[str, Scalar]]
    keys: list[Scalar]
    mode: str
    key_column: str | None
    output_bytes: bytes
    diff: dict[str, int]
    empty_cells: int
    samples: dict[str, Any]
    project_sha256: str
    mapped_roots: tuple[Path, ...]
    source_identity: tuple[int, int, int, int, int]
    target_identity: tuple[int, int, int, int, int] | None
    parent_identity: tuple[int, int]
    memory_estimate_bytes: int


class ConversionIssue(Exception):
    def __init__(
        self,
        status: str,
        code: str,
        message: str,
        *,
        diagnostics: list[dict[str, Any]] | None = None,
        diagnostic_total: int | None = None,
        required_decisions: list[str] | None = None,
        capability: bool = False,
    ) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.diagnostics = diagnostics or [
            {"code": code, "message": message}
        ]
        self.diagnostic_total = diagnostic_total if diagnostic_total is not None else len(self.diagnostics)
        self.required_decisions = required_decisions or []
        self.capability = capability


class OutputFailure(Exception):
    """Result transport failed; ``started`` forbids appending another JSON object."""

    def __init__(self, started: bool, cause: BaseException) -> None:
        super().__init__(str(cause))
        self.started = started
        self.cause = cause


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_identity(path: Path) -> tuple[int, int, int, int, int]:
    """Return a change-sensitive identity without following the final link."""
    try:
        value = path.stat(follow_symlinks=False)
    except OSError as exc:
        reject("path-recheck", f"Path identity cannot be read: {exc}")
    return (
        value.st_dev,
        value.st_ino,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def directory_identity(path: Path) -> tuple[int, int]:
    try:
        value = path.stat(follow_symlinks=False)
    except OSError as exc:
        reject("path-recheck", f"Directory identity cannot be read: {exc}")
    if not stat.S_ISDIR(value.st_mode):
        reject("path-recheck", "Expected transaction parent is no longer a directory")
    return (value.st_dev, value.st_ino)


def estimated_peak_memory(
    *,
    project_bytes: int = 0,
    source_bytes: int = 0,
    target_bytes: int = 0,
    output_bytes: int = 0,
    records: int = 0,
    columns: int = 0,
    cells: int = 0,
) -> int:
    """Conservative deterministic upper estimate for retained conversion state."""
    return (
        16 * 1024 * 1024
        + project_bytes * 8
        + source_bytes * 6
        + target_bytes * 8
        + output_bytes * 3
        + records * 384
        + columns * 2_048
        + cells * 384
    )


def enforce_memory_budget(*, source: str, **values: int) -> int:
    estimate = estimated_peak_memory(**values)
    if estimate > LIMITS["memory_bytes"]:
        reject(
            "memory-budget",
            "The deterministic combined peak-memory estimate exceeds the 512 MiB budget",
            source=source,
            capability=True,
        )
    return estimate


def display_text(value: str, maximum: int = 256) -> str:
    raw = value.encode("utf-8")
    if len(raw) <= maximum:
        return value
    digest = hashlib.sha256(raw).hexdigest()[:12]
    budget = max(0, maximum - len(("…#" + digest).encode("utf-8")))
    prefix = raw[:budget]
    while prefix:
        try:
            return prefix.decode("utf-8") + "…#" + digest
        except UnicodeDecodeError:
            prefix = prefix[:-1]
    return "…#" + digest


def diagnostic(
    source: str,
    code: str,
    message: str,
    *,
    record: int | None = None,
    column: str | int | None = None,
    physical_line: int | None = None,
) -> dict[str, Any]:
    item: dict[str, Any] = {
        "code": code,
        "source": display_text(source, 512),
        "message": display_text(message, 512),
    }
    if record is not None:
        item["logical_record"] = record
    if column is not None:
        item["column"] = display_text(str(column), 256)
    if physical_line is not None:
        item["physical_start_line"] = physical_line
    return item


def reject(
    code: str,
    message: str,
    *,
    source: str | None = None,
    record: int | None = None,
    column: str | int | None = None,
    physical_line: int | None = None,
    capability: bool = False,
) -> NoReturn:
    diagnostics = None
    if source is not None:
        diagnostics = [
            diagnostic(
                source,
                code,
                message,
                record=record,
                column=column,
                physical_line=physical_line,
            )
        ]
    raise ConversionIssue(
        "rejected", code, message, diagnostics=diagnostics, capability=capability
    )


def needs_input(
    code: str,
    message: str,
    decision: str,
    *,
    diagnostics: list[dict[str, Any]] | None = None,
) -> NoReturn:
    raise ConversionIssue(
        "needs-input",
        code,
        message,
        diagnostics=diagnostics,
        required_decisions=[decision],
    )


def normalized_common_path(child: Path, parent: Path) -> bool:
    try:
        common = os.path.commonpath((str(child), str(parent)))
    except ValueError:
        return False
    return os.path.normcase(common) == os.path.normcase(str(parent))


def same_normalized_path(left: Path, right: Path) -> bool:
    return os.path.normcase(os.path.normpath(str(left))) == os.path.normcase(
        os.path.normpath(str(right))
    )


def resolve_repository(repo_arg: str) -> tuple[Path, dict[str, Any], list[Path], bytes]:
    repo_requested = Path(repo_arg).expanduser()
    try:
        repo_real = repo_requested.resolve(strict=True)
    except OSError as exc:
        reject("repo-unavailable", f"Repository root is unavailable: {exc}", capability=True)
    if not repo_real.is_dir():
        reject("repo-unavailable", "Repository root is not a directory", capability=True)
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_real), "rev-parse", "--show-toplevel"],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except (FileNotFoundError, OSError, subprocess.SubprocessError) as exc:
        reject("git-unavailable", f"Git is unavailable: {exc}", capability=True)
    if result.returncode != 0:
        reject(
            "git-root-unavailable",
            "The supplied repository root is not inside a readable Git work tree",
            capability=True,
        )
    try:
        git_root = Path(result.stdout.strip()).resolve(strict=True)
    except OSError as exc:
        reject("git-root-unavailable", f"Git root cannot be resolved: {exc}", capability=True)
    if os.path.normcase(str(git_root)) != os.path.normcase(str(repo_real)):
        reject(
            "repo-root-mismatch",
            "--repo-root must name the exact current Git work-tree root",
            capability=True,
        )

    project_path = git_root / "default.project.json"
    try:
        project_bytes = project_path.read_bytes()
        if len(project_bytes) > LIMITS["project_bytes"]:
            reject(
                "rojo-project-too-large",
                "default.project.json exceeds the 1 MiB input budget",
                capability=True,
            )
        project = json.loads(project_bytes.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, RecursionError) as exc:
        reject(
            "rojo-project-unavailable",
            f"default.project.json is unavailable or invalid: {exc}",
            capability=True,
        )

    mapped: list[Path] = []
    pending: list[tuple[Any, int]] = [(project, 1)]
    nodes = 0
    while pending:
        value, depth = pending.pop()
        nodes += 1
        if nodes > LIMITS["project_nodes"]:
            reject(
                "rojo-project-nodes",
                "default.project.json exceeds the structural node budget",
                capability=True,
            )
        if depth > LIMITS["project_depth"]:
            reject(
                "rojo-project-depth",
                "default.project.json exceeds the structural depth budget",
                capability=True,
            )
        if isinstance(value, dict):
            path_value = value.get("$path")
            if isinstance(path_value, str):
                candidate = Path(path_value)
                if not candidate.is_absolute():
                    candidate = git_root / candidate
                try:
                    mapped.append(candidate.resolve(strict=True))
                except OSError:
                    pass
            pending.extend((child, depth + 1) for child in value.values())
        elif isinstance(value, list):
            pending.extend((child, depth + 1) for child in value)
    if not mapped:
        reject(
            "rojo-path-unavailable",
            "default.project.json has no existing filesystem-backed $path",
            capability=True,
        )
    return git_root, project, mapped, project_bytes


def resolve_target(
    repo_root: Path,
    mapped_roots: Sequence[Path],
    target_arg: str,
) -> tuple[Path, str, bytes | None]:
    raw = Path(target_arg).expanduser()
    lexical = Path(os.path.abspath(str(raw if raw.is_absolute() else repo_root / raw)))
    if not normalized_common_path(lexical, repo_root):
        reject("target-outside-repository", "Target path leaves the Git repository")
    if lexical.suffix.lower() != ".luau":
        reject("target-extension", "Target must have the .luau extension")
    lower_name = lexical.name.lower()
    if lower_name.endswith(".server.luau") or lower_name.endswith(".client.luau"):
        reject("target-executable", "Executable .server.luau/.client.luau targets are forbidden")
    try:
        parent_real = lexical.parent.resolve(strict=True)
    except OSError as exc:
        reject("target-parent", f"Target parent must already exist: {exc}")
    if not parent_real.is_dir():
        reject("target-parent", "Target parent must be a directory")
    if not same_normalized_path(lexical.parent, parent_real):
        reject(
            "target-redirect",
            "Target lexical parent differs from its resolved parent (symlink/junction/reparse redirect)",
        )
    if not os.access(parent_real, os.W_OK):
        reject("target-parent-readonly", "Target parent is not writable")
    target_entry_exists = os.path.lexists(lexical)
    try:
        target_real = lexical.resolve(strict=True) if target_entry_exists else parent_real / lexical.name
    except OSError as exc:
        reject("target-realpath", f"Target real path cannot be resolved: {exc}")
    if not same_normalized_path(lexical, target_real):
        reject(
            "target-redirect",
            "Target lexical path differs from its resolved path (symlink/junction/reparse redirect)",
        )
    if not normalized_common_path(target_real, repo_root):
        reject("target-realpath", "Target redirects outside the Git repository")
    if not any(normalized_common_path(target_real, mapped) for mapped in mapped_roots):
        reject("target-outside-rojo", "Target is outside every filesystem-backed Rojo $path")
    if target_real.exists() and not target_real.is_file():
        reject("target-not-file", "Existing target is not a regular file")
    target_bytes: bytes | None = None
    if target_real.exists():
        try:
            size = target_real.stat().st_size
            if size > LIMITS["target_bytes"]:
                reject("target-too-large", "Existing target exceeds the 64 MiB budget")
            target_bytes = target_real.read_bytes()
        except OSError as exc:
            reject("target-unreadable", f"Existing target cannot be read: {exc}")
        if len(target_bytes) > LIMITS["target_bytes"]:
            reject("target-too-large", "Existing target exceeds the 64 MiB budget")
    relative = target_real.relative_to(repo_root).as_posix()
    return target_real, relative, target_bytes


def read_source(source_arg: str) -> tuple[Path, bytes, str]:
    source = Path(source_arg).expanduser()
    try:
        source_real = source.resolve(strict=True)
    except OSError as exc:
        reject("source-unreadable", f"CSV source is unavailable: {exc}", source=str(source))
    if not source_real.is_file():
        reject("source-unreadable", "CSV source is not a regular file", source=str(source_real))
    try:
        if source_real.stat().st_size > LIMITS["source_bytes"]:
            reject("source-too-large", "CSV source exceeds the 32 MiB budget", source=str(source_real))
        data = source_real.read_bytes()
    except OSError as exc:
        reject("source-unreadable", f"CSV source cannot be read: {exc}", source=str(source_real))
    if len(data) > LIMITS["source_bytes"]:
        reject("source-too-large", "CSV source exceeds the 32 MiB budget", source=str(source_real))
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        reject(
            "source-encoding",
            f"CSV source must be UTF-8 with an optional BOM: {exc}",
            source=str(source_real),
        )
    return source_real, data, text


def parse_csv(
    text: str,
    delimiter: str,
    source_name: str,
    *,
    stop_after_records: int | None = None,
    capacity_check: Callable[[int, int, int], None] | None = None,
) -> list[LogicalRecord]:
    records: list[LogicalRecord] = []
    fields: list[ParsedField] = []
    chars: list[str] = []
    state = "start"
    field_quoted = False
    field_bytes = 0
    record_bytes = 0
    physical_line = 1
    field_start_line = 1
    record_start_line = 1
    record_started = False
    data_cells = 0
    index = 0

    def add_record_bytes(token: str) -> None:
        nonlocal record_bytes
        record_bytes += len(token.encode("utf-8"))
        if record_bytes > LIMITS["record_bytes"]:
            reject(
                "record-too-large",
                "Logical CSV record exceeds the 4 MiB source-byte budget",
                source=source_name,
                record=len(records) + 1,
                physical_line=record_start_line,
            )

    def append_value(token: str) -> None:
        nonlocal field_bytes
        chars.append(token)
        field_bytes += len(token.encode("utf-8"))
        if field_bytes > LIMITS["field_bytes"]:
            reject(
                "field-too-large",
                "Decoded CSV field exceeds the 1 MiB UTF-8 budget",
                source=source_name,
                record=len(records) + 1,
                column=len(fields) + 1,
                physical_line=field_start_line,
            )

    def finish_field() -> None:
        nonlocal chars, field_quoted, field_bytes, field_start_line
        value = "".join(chars)
        if not records and len(fields) >= LIMITS["columns"]:
            reject(
                "columns-too-many",
                f"Header exceeds the {LIMITS['columns']} column budget",
                source=source_name,
                record=1,
                column=len(fields) + 1,
                physical_line=field_start_line,
            )
        if records and data_cells + len(fields) + 1 > LIMITS["cells"]:
            reject(
                "cells-too-many",
                f"CSV exceeds the {LIMITS['cells']} data-cell budget",
                source=source_name,
                record=len(records) + 1,
                column=len(fields) + 1,
                physical_line=field_start_line,
            )
        fields.append(ParsedField(value, field_quoted, field_start_line))
        chars = []
        field_quoted = False
        field_bytes = 0
        field_start_line = physical_line

    def finish_record() -> None:
        nonlocal fields, record_bytes, record_start_line, record_started, field_start_line, data_cells
        logical = len(records) + 1
        if records and logical - 1 > LIMITS["records"]:
            reject(
                "records-too-many",
                f"CSV exceeds the {LIMITS['records']} data-record budget",
                source=source_name,
                record=logical,
                physical_line=record_start_line,
            )
        if records:
            data_cells += len(fields)
        records.append(LogicalRecord(logical, record_start_line, tuple(fields)))
        if capacity_check is not None and len(records) > 1:
            capacity_check(len(records) - 1, len(records[0].fields), data_cells)
        fields = []
        record_bytes = 0
        record_started = False
        record_start_line = physical_line + 1
        field_start_line = physical_line + 1

    while index < len(text):
        char = text[index]
        if char == "\r":
            newline = "\r\n" if index + 1 < len(text) and text[index + 1] == "\n" else "\r"
        elif char == "\n":
            newline = "\n"
        else:
            newline = None

        if state == "quoted":
            if char == '"':
                if index + 1 < len(text) and text[index + 1] == '"':
                    add_record_bytes('""')
                    append_value('"')
                    index += 2
                    continue
                add_record_bytes('"')
                state = "after-quote"
                index += 1
                continue
            if newline is not None:
                add_record_bytes(newline)
                append_value(newline)
                index += len(newline)
                physical_line += 1
                continue
            add_record_bytes(char)
            append_value(char)
            index += 1
            continue

        if newline is not None:
            if state == "start" and not fields and not record_started:
                index += len(newline)
                physical_line += 1
                record_bytes = 0
                record_start_line = physical_line
                field_start_line = physical_line
                continue
            add_record_bytes(newline)
            finish_field()
            finish_record()
            state = "start"
            index += len(newline)
            physical_line += 1
            if stop_after_records is not None and len(records) >= stop_after_records:
                return records
            continue

        if state == "after-quote":
            if char != delimiter:
                reject(
                    "csv-after-quote",
                    "Only a delimiter or record ending may follow a closing quote",
                    source=source_name,
                    record=len(records) + 1,
                    column=len(fields) + 1,
                    physical_line=field_start_line,
                )
            add_record_bytes(char)
            finish_field()
            state = "start"
            record_started = True
            field_start_line = physical_line
            index += 1
            continue

        if char == delimiter:
            add_record_bytes(char)
            finish_field()
            state = "start"
            record_started = True
            field_start_line = physical_line
            index += 1
            continue
        if char == '"':
            if state != "start":
                reject(
                    "csv-unexpected-quote",
                    "A quote may only begin an otherwise empty CSV field",
                    source=source_name,
                    record=len(records) + 1,
                    column=len(fields) + 1,
                    physical_line=field_start_line,
                )
            add_record_bytes(char)
            state = "quoted"
            field_quoted = True
            record_started = True
            index += 1
            continue
        add_record_bytes(char)
        append_value(char)
        state = "unquoted"
        record_started = True
        index += 1

    if state == "quoted":
        reject(
            "csv-unclosed-quote",
            "Quoted CSV field reaches end-of-file without a closing quote",
            source=source_name,
            record=len(records) + 1,
            column=len(fields) + 1,
            physical_line=field_start_line,
        )
    if state != "start" or fields or record_started:
        finish_field()
        finish_record()
    return records


def normalized_field(field: ParsedField) -> str | None:
    text = field.text if field.quoted else field.text.strip()
    return None if text == "" else text


def validate_csv_structure(
    records: Sequence[LogicalRecord],
    source_name: str,
    *,
    collect_rows: bool,
) -> tuple[list[str], list[list[str | None]], Sequence[LogicalRecord]]:
    """Validate header/row structure without retaining a converted row graph."""
    if not records:
        reject("csv-empty", "CSV source has no header record", source=source_name)
    header_record = records[0]
    headers: list[str] = []
    errors: list[dict[str, Any]] = []
    error_total = 0

    def add_error(item: dict[str, Any]) -> None:
        nonlocal error_total
        error_total += 1
        if len(errors) < LIMITS["diagnostics"]:
            errors.append(item)

    for index, field in enumerate(header_record.fields, start=1):
        value = normalized_field(field)
        if value is None:
            add_error(
                diagnostic(
                    source_name,
                    "header-empty",
                    "Header name is empty",
                    record=1,
                    column=index,
                    physical_line=field.physical_start_line,
                )
            )
            headers.append("")
        else:
            headers.append(value)
    if len(headers) > LIMITS["columns"]:
        add_error(
            diagnostic(
                source_name,
                "columns-too-many",
                f"Header exceeds the {LIMITS['columns']} column budget",
                record=1,
                physical_line=header_record.physical_start_line,
            )
        )
    seen_headers: set[str] = set()
    for index, header in enumerate(headers, start=1):
        if header and header in seen_headers:
            add_error(
                diagnostic(
                    source_name,
                    "header-duplicate",
                    f"Duplicate header {header!r}",
                    record=1,
                    column=header,
                    physical_line=header_record.physical_start_line,
                )
            )
        seen_headers.add(header)

    data_records = records[1:]
    if len(data_records) > LIMITS["records"]:
        over = data_records[LIMITS["records"]]
        add_error(
            diagnostic(
                source_name,
                "records-too-many",
                f"CSV exceeds the {LIMITS['records']} data-record budget",
                record=over.logical_number,
                physical_line=over.physical_start_line,
            )
        )
    actual_cells = sum(len(record.fields) for record in data_records)
    if actual_cells > LIMITS["cells"]:
        add_error(
            diagnostic(
                source_name,
                "cells-too-many",
                f"CSV exceeds the {LIMITS['cells']} data-cell budget",
            )
        )

    normalized_rows: list[list[str | None]] = []
    for record in data_records:
        if len(record.fields) != len(headers):
            add_error(
                diagnostic(
                    source_name,
                    "row-width",
                    f"Record has {len(record.fields)} columns; expected {len(headers)}",
                    record=record.logical_number,
                    physical_line=record.physical_start_line,
                )
            )
            continue
        values = [normalized_field(field) for field in record.fields]
        if all(value is None for value in values):
            add_error(
                diagnostic(
                    source_name,
                    "row-empty",
                    "Logical data record has no non-empty cells",
                    record=record.logical_number,
                    physical_line=record.physical_start_line,
                )
            )
            continue
        if collect_rows:
            normalized_rows.append(values)
    if error_total:
        raise ConversionIssue(
            "rejected",
            "csv-validation",
            f"CSV validation found {error_total} error(s)",
            diagnostics=errors,
            diagnostic_total=error_total,
        )
    return headers, normalized_rows, data_records


def csv_structure_digest(records: Sequence[LogicalRecord]) -> str:
    """Return a constant-space digest of exact parsed structure and provenance."""
    digest = hashlib.sha256()
    digest.update(len(records).to_bytes(8, "big"))
    for record in records:
        digest.update(len(record.fields).to_bytes(4, "big"))
        for field in record.fields:
            encoded = field.text.encode("utf-8")
            digest.update(b"\x01" if field.quoted else b"\x00")
            digest.update(len(encoded).to_bytes(8, "big"))
            digest.update(encoded)
    return digest.hexdigest()


def select_delimiter(
    text: str,
    source_name: str,
    explicit: str | None,
    capacity_check: Callable[[int, int, int], None] | None = None,
) -> tuple[str, str, list[LogicalRecord], list[str]]:
    if explicit is not None:
        records = parse_csv(
            text,
            DELIMITERS[explicit],
            source_name,
            capacity_check=capacity_check,
        )
        return explicit, DELIMITERS[explicit], records, [explicit]

    header_candidates: list[tuple[str, int]] = []
    parse_failures: list[ConversionIssue] = []
    for name in DELIMITER_ORDER:
        try:
            candidate = parse_csv(
                text,
                DELIMITERS[name],
                source_name,
                stop_after_records=1,
            )
        except ConversionIssue as issue:
            parse_failures.append(issue)
            continue
        if not candidate:
            continue
        width = len(candidate[0].fields)
        header_candidates.append((name, width))
        del candidate
    if not header_candidates:
        if parse_failures:
            raise parse_failures[0]
        reject("csv-empty", "CSV source has no logical records", source=source_name)

    # Fully validate candidates one at a time. Retain only constant-size
    # summaries, then parse the selected candidate once more for conversion.
    # This prevents four maximum-size record graphs/signatures from coexisting.
    # When the header contains a supported delimiter, absent-delimiter
    # one-column parses cannot rescue a malformed multi-column source.
    multi_column_headers = [item for item in header_candidates if item[1] > 1]
    structural_candidates = multi_column_headers or header_candidates
    full_candidates: list[tuple[str, int, str]] = []
    full_failures: list[tuple[str, ConversionIssue]] = []
    for name, width in structural_candidates:
        try:
            candidate = parse_csv(
                text,
                DELIMITERS[name],
                source_name,
                capacity_check=capacity_check,
            )
            validate_csv_structure(candidate, source_name, collect_rows=False)
        except ConversionIssue as issue:
            full_failures.append((name, issue))
            continue
        full_candidates.append((name, width, csv_structure_digest(candidate)))
        del candidate
    if not full_candidates:
        raise full_failures[0][1]

    multi_column = [item for item in full_candidates if item[1] > 1]
    plausible = multi_column or full_candidates
    distinct_structures = {item[2] for item in plausible}
    if len(distinct_structures) > 1:
        names = [item[0] for item in plausible]
        needs_input(
            "delimiter-ambiguous",
            "Multiple delimiters produce different plausible CSV structures: "
            + ", ".join(names),
            "delimiter",
            diagnostics=[diagnostic(source_name, "delimiter-ambiguous", "Choose one delimiter: " + ", ".join(names))],
        )
    selected_name = plausible[0][0]
    records = parse_csv(
        text,
        DELIMITERS[selected_name],
        source_name,
        capacity_check=capacity_check,
    )
    return selected_name, DELIMITERS[selected_name], records, [item[0] for item in plausible]


def parse_number(text: str) -> Scalar | None:
    if not NUMBER_RE.fullmatch(text):
        return None
    try:
        number = float(text)
    except (ValueError, OverflowError):
        return None
    if not math.isfinite(number):
        return None
    try:
        exact = decimal.Decimal(text)
        round_trip = decimal.Decimal(repr(number))
    except decimal.InvalidOperation:
        return None
    if exact != round_trip:
        return None
    if number == 0:
        canonical = "0"
    elif number.is_integer() and abs(number) < 1e21:
        canonical = str(int(number))
    else:
        canonical = repr(number).lower()
    return Scalar("number", number, canonical)


def parse_boolean(text: str) -> Scalar | None:
    lowered = text.lower()
    if lowered == "true":
        return Scalar("boolean", True, "true")
    if lowered == "false":
        return Scalar("boolean", False, "false")
    return None


def parse_overrides(items: Sequence[str], source_name: str) -> dict[str, str]:
    overrides: dict[str, str] = {}
    for item in items:
        if "=" not in item:
            reject("type-override", "Type override must be <header>=<type>", source=source_name)
        header, value = item.rsplit("=", 1)
        if not header or value not in {"string", "number", "boolean"}:
            reject("type-override", "Type override must name a header and string, number, or boolean", source=source_name)
        if header in overrides:
            reject("type-override-duplicate", f"Duplicate type override for column {header!r}", source=source_name, column=header)
        overrides[header] = value
    return overrides


def parse_array_overrides(items: Sequence[str], source_name: str) -> dict[str, str]:
    overrides: dict[str, str] = {}
    for item in items:
        if "=" not in item:
            reject(
                "array-delimiter-override",
                "Array delimiter override must be <header>=<delimiter>",
                source=source_name,
            )
        header, value = item.rsplit("=", 1)
        if not header or value not in ARRAY_DELIMITERS:
            reject(
                "array-delimiter-override",
                "Array delimiter override must name a header and comma, semicolon, pipe, tab, or newline",
                source=source_name,
            )
        if header in overrides:
            reject(
                "array-delimiter-override-duplicate",
                f"Duplicate array delimiter override for column {header!r}",
                source=source_name,
                column=header,
            )
        overrides[header] = value
    return overrides


def split_array_value(value: str, delimiter_name: str) -> tuple[str, ...]:
    if delimiter_name == "newline":
        raw_parts = re.split(r"\r\n|\r|\n", value)
    else:
        raw_parts = value.split(ARRAY_DELIMITERS[delimiter_name])
    return tuple(part.strip() for part in raw_parts)


def contains_array_delimiter(value: str, delimiter_name: str) -> bool:
    if delimiter_name == "newline":
        return "\r" in value or "\n" in value
    return ARRAY_DELIMITERS[delimiter_name] in value


def array_candidate(
    header: str,
    delimiter_name: str,
    nonempty: Sequence[str],
    values: Sequence[str | None],
    data_records: Sequence[LogicalRecord],
) -> dict[str, Any] | None:
    matching_cells = 0
    sample: tuple[int, str, tuple[str, ...]] | None = None
    generated_elements = 0
    for row_index, value in enumerate(values):
        if value is None:
            continue
        if contains_array_delimiter(value, delimiter_name):
            parts = split_array_value(value, delimiter_name)
            if len(parts) < 2 or any(part == "" for part in parts):
                return None
            matching_cells += 1
            if sample is None:
                sample = (row_index, value, parts)
            generated_elements += len(parts)
        else:
            generated_elements += 1
    if sample is None:
        return None
    row_index, sample_value, sample_parts = sample
    record = data_records[row_index]
    return {
        "column": display_text(header, 128),
        "delimiter": delimiter_name,
        "matching_cells": matching_cells,
        "non_empty_cells": len(nonempty),
        "generated_elements": generated_elements,
        "sample": {
            "logical_record": record.logical_number,
            "physical_line": record.physical_start_line,
            "value": display_text(sample_value, 160),
            "items": [display_text(part, 80) for part in sample_parts[:6]],
            "items_truncated": len(sample_parts) > 6,
        },
    }


def infer_and_convert(
    records: Sequence[LogicalRecord],
    source_name: str,
    override_items: Sequence[str],
    array_override_items: Sequence[str] = (),
) -> tuple[
    list[str],
    list[dict[str, Any]],
    list[dict[str, Scalar]],
    int,
    int,
    list[dict[str, Any]],
    int,
]:
    headers, normalized_rows, data_records = validate_csv_structure(
        records,
        source_name,
        collect_rows=True,
    )

    overrides = parse_overrides(override_items, source_name)
    array_overrides = parse_array_overrides(array_override_items, source_name)
    for header in overrides:
        if header not in headers:
            reject("type-override-column", f"Type override names unknown column {header!r}", source=source_name, column=header)
    for header in array_overrides:
        if header not in headers:
            reject(
                "array-delimiter-column",
                f"Array delimiter override names unknown column {header!r}",
                source=source_name,
                column=header,
            )
        if header in overrides:
            reject(
                "array-delimiter-conflict",
                f"Column {header!r} cannot have both type and array delimiter overrides",
                source=source_name,
                column=header,
            )

    schemas: list[dict[str, Any]] = []
    candidates: list[dict[str, Any]] = []
    candidate_total = 0
    converted_columns: list[list[Scalar | None]] = []
    empty_cells = 0
    generated_values = 0
    for column_index, header in enumerate(headers):
        values = [row[column_index] for row in normalized_rows]
        nonempty = [value for value in values if value is not None]
        empty_count = len(values) - len(nonempty)
        empty_cells += empty_count
        if not nonempty:
            inferred = "empty"
        elif any("," in value for value in nonempty):
            inferred = "array<string>"
        elif all(parse_number(value) is not None for value in nonempty):
            inferred = "number"
        elif all(parse_boolean(value) is not None for value in nonempty):
            inferred = "boolean"
        else:
            inferred = "string"
        override = overrides.get(header)
        array_delimiter = array_overrides.get(header)
        if array_delimiter is not None and not any(
            contains_array_delimiter(value, array_delimiter) for value in nonempty
        ):
            reject(
                "array-delimiter-unused",
                f"Selected array delimiter {array_delimiter!r} does not occur in column {header!r}",
                source=source_name,
                column=header,
            )
        if override is None and array_delimiter is None and inferred != "array<string>":
            for candidate_delimiter in ARRAY_CANDIDATE_ORDER:
                candidate = array_candidate(
                    header,
                    candidate_delimiter,
                    nonempty,
                    values,
                    data_records,
                )
                if candidate is not None:
                    candidate_total += 1
                    if len(candidates) < LIMITS["array_candidates"]:
                        candidates.append(candidate)
        effective = "array<string>" if array_delimiter is not None else (override or inferred)
        selected_array_delimiter = array_delimiter
        if effective == "array<string>" and selected_array_delimiter is None:
            selected_array_delimiter = "comma"
        converted: list[Scalar | None] = []
        for row_index, value in enumerate(values):
            if value is None:
                converted.append(None)
                continue
            if effective == "array<string>":
                assert selected_array_delimiter is not None
                parts = split_array_value(value, selected_array_delimiter)
                if any(part == "" for part in parts):
                    record = data_records[row_index]
                    reject(
                        "array-element-empty",
                        f"{selected_array_delimiter.capitalize()}-separated array contains an empty element",
                        source=source_name,
                        record=record.logical_number,
                        column=header,
                        physical_line=record.physical_start_line,
                    )
                generated_values += len(parts)
                if generated_values > LIMITS["cells"]:
                    record = data_records[row_index]
                    reject(
                        "cells-too-many",
                        f"Generated scalar values exceed the {LIMITS['cells']} value budget",
                        source=source_name,
                        record=record.logical_number,
                        column=header,
                        physical_line=record.physical_start_line,
                    )
                scalar = Scalar(
                    "array",
                    tuple(Scalar("string", part, part) for part in parts),
                    "",
                )
            elif effective == "string":
                scalar = Scalar("string", value, value)
            elif effective == "number":
                scalar = parse_number(value)
            elif effective == "boolean":
                scalar = parse_boolean(value)
            else:
                scalar = None
            if scalar is None:
                record = data_records[row_index]
                reject(
                    "type-incompatible",
                    f"Value is incompatible with effective type {effective}",
                    source=source_name,
                    record=record.logical_number,
                    column=header,
                    physical_line=record.physical_start_line,
                )
            if effective != "array<string>":
                generated_values += 1
                if generated_values > LIMITS["cells"]:
                    record = data_records[row_index]
                    reject(
                        "cells-too-many",
                        f"Generated scalar values exceed the {LIMITS['cells']} value budget",
                        source=source_name,
                        record=record.logical_number,
                        column=header,
                        physical_line=record.physical_start_line,
                    )
            converted.append(scalar)
        converted_columns.append(converted)
        schemas.append(
            {
                "index": column_index,
                "name": display_text(header),
                "inferred_type": inferred,
                "effective_type": effective,
                "override": override,
                "array_delimiter": selected_array_delimiter,
                "non_empty_count": len(nonempty),
                "empty_count": empty_count,
            }
        )

    rows: list[dict[str, Scalar]] = []
    for row_index in range(len(normalized_rows)):
        row: dict[str, Scalar] = {}
        for column_index, header in enumerate(headers):
            scalar = converted_columns[column_index][row_index]
            if scalar is not None:
                row[header] = scalar
        rows.append(row)
    return (
        headers,
        schemas,
        rows,
        empty_cells,
        generated_values,
        candidates,
        candidate_total,
    )


@dataclasses.dataclass(frozen=True)
class Token:
    kind: str
    value: Any
    start: int


class LuauTokenizer:
    def __init__(self, text: str, start: int, source_name: str) -> None:
        self.text = text
        self.index = start
        self.source_name = source_name
        self._lookahead: Token | None = None

    def _unsafe(self, message: str) -> NoReturn:
        needs_input(
            "unsafe-target",
            message,
            "unsafe_target_disposition",
            diagnostics=[diagnostic(self.source_name, "unsafe-target", message)],
        )

    def _scan_string(self) -> Token:
        start = self.index
        self.index += 1
        result: list[str] = []
        escapes = {
            "a": "\a", "b": "\b", "f": "\f", "n": "\n",
            "r": "\r", "t": "\t", "v": "\v", "\\": "\\", '"': '"',
        }
        while self.index < len(self.text):
            char = self.text[self.index]
            if char == '"':
                self.index += 1
                return Token("string", "".join(result), start)
            if char in "\r\n":
                self._unsafe("Existing target has a raw newline in a string literal")
            if char != "\\":
                result.append(char)
                self.index += 1
                continue
            self.index += 1
            if self.index >= len(self.text):
                self._unsafe("Existing target ends inside a string escape")
            escaped = self.text[self.index]
            if escaped == "x":
                digits = self.text[self.index + 1:self.index + 3]
                if len(digits) != 2 or any(ch not in HEX for ch in digits):
                    self._unsafe("Existing target has an invalid \\xNN escape")
                result.append(chr(int(digits, 16)))
                self.index += 3
                continue
            if escaped not in escapes:
                self._unsafe("Existing target uses an unsupported string escape")
            result.append(escapes[escaped])
            self.index += 1
        self._unsafe("Existing target has an unterminated string literal")

    def _next(self) -> Token:
        while self.index < len(self.text) and self.text[self.index].isspace():
            self.index += 1
        if self.index >= len(self.text):
            return Token("eof", None, self.index)
        start = self.index
        if self.text.startswith("--", self.index):
            self._unsafe("Comments inside or after the returned table are not safe to replace")
        char = self.text[self.index]
        if char in "{}[]=,":
            self.index += 1
            return Token(char, char, start)
        if char == '"':
            return self._scan_string()
        identifier = IDENTIFIER_TOKEN_RE.match(self.text, self.index)
        if identifier:
            value = identifier.group(0)
            self.index += len(value)
            return Token("identifier", value, start)
        number = NUMBER_TOKEN_RE.match(self.text, self.index)
        if number:
            value = number.group(0)
            self.index += len(value)
            return Token("number", value, start)
        self._unsafe("Existing target contains unsupported or computed Luau syntax")

    def peek(self) -> Token:
        if self._lookahead is None:
            self._lookahead = self._next()
        return self._lookahead

    def pop(self, kind: str | None = None) -> Token:
        token = self.peek()
        if kind is not None and token.kind != kind:
            self._unsafe(f"Existing target expected {kind!r} but found {token.kind!r}")
        self._lookahead = None
        return token


def scan_luau_prefix(text: str, source_name: str) -> tuple[str, int]:
    if text.startswith("\ufeff"):
        needs_input("unsafe-target", "Existing target must not contain a UTF-8 BOM", "unsafe_target_disposition")
    index = 0
    while True:
        while index < len(text) and text[index].isspace():
            index += 1
        if not text.startswith("--", index):
            break
        if text.startswith("--[", index):
            match = LONG_COMMENT_RE.match(text, index)
            if match:
                close = "]" + match.group(1) + "]"
                end = text.find(close, index + len(match.group(0)))
                if end < 0:
                    needs_input("unsafe-target", "Existing target has an unterminated header long comment", "unsafe_target_disposition")
                index = end + len(close)
                continue
        # Advance one monotonic cursor instead of searching the complete
        # remaining suffix separately for CR and LF on every line comment.
        while index < len(text) and text[index] not in "\r\n":
            index += 1
        if index < len(text):
            ending = text[index]
            index += 1
            if ending == "\r" and index < len(text) and text[index] == "\n":
                index += 1
    return_start = index
    match = RETURN_TOKEN_RE.match(text, index)
    if not match:
        needs_input(
            "unsafe-target",
            "Existing target must contain only header comments and one literal return table",
            "unsafe_target_disposition",
            diagnostics=[diagnostic(source_name, "unsafe-target", "Existing target has executable or unsupported content before return")],
        )
    index += len(match.group(0))
    prefix = text[:return_start].replace("\r\n", "\n").replace("\r", "\n")
    return prefix, index


class LuauParser:
    def __init__(self, tokenizer: LuauTokenizer) -> None:
        self.tokens = tokenizer

    def scalar(self) -> Scalar:
        token = self.tokens.peek()
        if token.kind == "string":
            self.tokens.pop()
            return Scalar("string", token.value, token.value)
        if token.kind == "number":
            self.tokens.pop()
            parsed = parse_number(token.value)
            if parsed is None:
                self.tokens._unsafe("Existing target has a non-canonical or unsafe number literal")
            return parsed
        if token.kind == "identifier" and token.value in {"true", "false"}:
            self.tokens.pop()
            return Scalar("boolean", token.value == "true", token.value)
        self.tokens._unsafe("Existing target row values must be string, number, or boolean literals")

    def value(self) -> Scalar:
        if self.tokens.peek().kind != "{":
            return self.scalar()
        self.tokens.pop("{")
        values: list[Scalar] = []
        if self.tokens.peek().kind == "}":
            self.tokens._unsafe("Existing target string arrays must not be empty")
        while self.tokens.peek().kind != "}":
            item = self.scalar()
            if item.kind != "string":
                self.tokens._unsafe("Existing target nested arrays may contain only string literals")
            values.append(item)
            if self.tokens.peek().kind == ",":
                self.tokens.pop(",")
                continue
            if self.tokens.peek().kind != "}":
                self.tokens._unsafe("Existing target array entries must be comma-separated")
        self.tokens.pop("}")
        return Scalar("array", tuple(values), "")

    def row(self) -> dict[str, Scalar]:
        self.tokens.pop("{")
        row: dict[str, Scalar] = {}
        while self.tokens.peek().kind != "}":
            token = self.tokens.peek()
            if token.kind == "identifier":
                name = self.tokens.pop().value
                if name in LUA_RESERVED or not IDENTIFIER_RE.fullmatch(name):
                    self.tokens._unsafe("Existing target has an invalid bare row field")
            elif token.kind == "[":
                self.tokens.pop("[")
                name = self.tokens.pop("string").value
                self.tokens.pop("]")
            else:
                self.tokens._unsafe("Existing target row uses an unsupported field form")
            self.tokens.pop("=")
            value = self.value()
            if name in row:
                self.tokens._unsafe("Existing target row has a duplicate field")
            row[name] = value
            if self.tokens.peek().kind == ",":
                self.tokens.pop(",")
                continue
            if self.tokens.peek().kind != "}":
                self.tokens._unsafe("Existing target table entries must be comma-separated")
        self.tokens.pop("}")
        return row

    def top(
        self, requested_mode: str | None = None
    ) -> tuple[str, list[dict[str, Scalar]], list[Scalar]]:
        self.tokens.pop("{")
        if self.tokens.peek().kind == "}":
            self.tokens.pop("}")
            if self.tokens.pop().kind != "eof":
                self.tokens._unsafe("Existing target has trailing executable content")
            if requested_mode is None:
                needs_input(
                    "mode-required",
                    "An empty existing table requires an explicit array/dictionary mode",
                    "mode",
                    diagnostics=[
                        diagnostic(
                            self.tokens.source_name,
                            "mode-required",
                            "Choose array or dictionary mode for the safe empty existing table",
                        )
                    ],
                )
            return requested_mode, [], []
        mode = "array" if self.tokens.peek().kind == "{" else "dictionary" if self.tokens.peek().kind == "[" else ""
        if not mode:
            self.tokens._unsafe("Existing target has an ambiguous top-level table shape")
        rows: list[dict[str, Scalar]] = []
        keys: list[Scalar] = []
        seen_keys: set[tuple[str, str]] = set()
        while self.tokens.peek().kind != "}":
            if mode == "array":
                if self.tokens.peek().kind != "{":
                    self.tokens._unsafe("Existing target mixes array and dictionary entries")
                rows.append(self.row())
            else:
                self.tokens.pop("[")
                key = self.scalar()
                self.tokens.pop("]")
                self.tokens.pop("=")
                if key.key in seen_keys:
                    self.tokens._unsafe("Existing target has duplicate typed dictionary keys")
                seen_keys.add(key.key)
                keys.append(key)
                rows.append(self.row())
            if self.tokens.peek().kind == ",":
                self.tokens.pop(",")
                continue
            if self.tokens.peek().kind != "}":
                self.tokens._unsafe("Existing target top-level entries must be comma-separated")
        self.tokens.pop("}")
        if self.tokens.pop().kind != "eof":
            self.tokens._unsafe("Existing target has trailing executable content")
        return mode, rows, keys


def parse_existing(
    target_bytes: bytes,
    source_name: str,
    requested_key: str | None,
    requested_mode: str | None = None,
) -> ExistingData:
    try:
        text = target_bytes.decode("utf-8")
    except UnicodeDecodeError:
        needs_input(
            "unsafe-target",
            "Existing target is not valid UTF-8",
            "unsafe_target_disposition",
            diagnostics=[diagnostic(source_name, "unsafe-target", "Existing target is not valid UTF-8")],
        )
    prefix, start = scan_luau_prefix(text, source_name)
    tokenizer = LuauTokenizer(text, start, source_name)
    mode, rows, keys = LuauParser(tokenizer).top(requested_mode)
    key_column: str | None = None
    if mode == "dictionary":
        candidates: list[str] = []
        if rows:
            common = set(rows[0])
            for row in rows[1:]:
                common.intersection_update(row)
            for header in sorted(common):
                if any(row[header].kind == "array" for row in rows):
                    continue
                if all(row[header].key == key.key for row, key in zip(rows, keys)):
                    candidates.append(header)
        if requested_key is not None:
            if rows and requested_key not in candidates:
                reject(
                    "key-column-mismatch",
                    f"Requested key column {requested_key!r} does not reproduce existing outer keys",
                    source=source_name,
                    column=requested_key,
                )
            key_column = requested_key
        elif len(candidates) == 1:
            key_column = candidates[0]
        else:
            needs_input(
                "key-column-ambiguous",
                "Existing dictionary key column cannot be determined uniquely",
                "key_column",
                diagnostics=[diagnostic(source_name, "key-column-ambiguous", "Candidate key columns: " + (", ".join(candidates) if candidates else "none"))],
            )
    return ExistingData(mode, rows, keys, key_column, prefix)


def render_string(value: str) -> str:
    escapes = {
        '"': '\\"', "\\": "\\\\", "\a": "\\a", "\b": "\\b",
        "\f": "\\f", "\n": "\\n", "\r": "\\r", "\t": "\\t", "\v": "\\v",
    }
    output: list[str] = ['"']
    for char in value:
        if char in escapes:
            output.append(escapes[char])
        elif ord(char) < 32 or ord(char) == 127:
            output.append(f"\\x{ord(char):02X}")
        else:
            output.append(char)
    output.append('"')
    return "".join(output)


def render_scalar(value: Scalar) -> str:
    if value.kind == "array":
        raise ValueError("render_scalar does not accept array values")
    if value.kind == "string":
        return render_string(str(value.value))
    return value.canonical


def render_field(header: str) -> str:
    if IDENTIFIER_RE.fullmatch(header) and header not in LUA_RESERVED:
        return header
    return "[" + render_string(header) + "]"


def render_module(
    prefix: str,
    headers: Sequence[str],
    rows: Sequence[dict[str, Scalar]],
    mode: str,
    keys: Sequence[Scalar],
    *,
    source_name: str,
) -> bytes:
    lines: list[str] = []
    if prefix:
        lines.append(prefix)
        if not prefix.endswith("\n"):
            lines.append("\n")
    lines.append("return {\n")
    for index, row in enumerate(rows):
        if mode == "array":
            lines.append("\t{\n")
        else:
            lines.append(f"\t[{render_scalar(keys[index])}] = {{\n")
        for header in headers:
            value = row.get(header)
            if value is not None:
                if value.kind == "array":
                    assert isinstance(value.value, tuple)
                    lines.append(f"\t\t{render_field(header)} = {{\n")
                    for item in value.value:
                        lines.append(f"\t\t\t{render_scalar(item)},\n")
                    lines.append("\t\t},\n")
                else:
                    lines.append(f"\t\t{render_field(header)} = {render_scalar(value)},\n")
        lines.append("\t},\n")
    lines.append("}\n")
    output = "".join(lines).encode("utf-8")
    if len(output) > LIMITS["output_bytes"]:
        reject(
            "output-too-large",
            "Generated Luau exceeds the 64 MiB output budget",
            source=source_name,
        )
    return output


def dictionary_keys(
    rows: Sequence[dict[str, Scalar]], key_column: str, source_name: str
) -> list[Scalar]:
    keys: list[Scalar] = []
    seen: dict[tuple[str, str], int] = {}
    for index, row in enumerate(rows, start=2):
        key = row.get(key_column)
        if key is None:
            reject(
                "dictionary-key-empty",
                "Dictionary key column is empty",
                source=source_name,
                record=index,
                column=key_column,
            )
        if key.kind == "array":
            reject(
                "dictionary-key-array",
                "Dictionary key column cannot contain string arrays",
                source=source_name,
                record=index,
                column=key_column,
            )
        if key.key in seen:
            reject(
                "dictionary-key-duplicate",
                f"Typed dictionary key duplicates logical record {seen[key.key]}",
                source=source_name,
                record=index,
                column=key_column,
            )
        seen[key.key] = index
        keys.append(key)
    return keys


def compute_diff(
    mode: str,
    rows: Sequence[dict[str, Scalar]],
    keys: Sequence[Scalar],
    existing: ExistingData | None,
) -> dict[str, int]:
    if existing is None:
        return {"added": len(rows), "changed": 0, "removed": 0}
    if mode == "array":
        common = min(len(rows), len(existing.rows))
        changed = sum(1 for index in range(common) if rows[index] != existing.rows[index])
        return {
            "added": max(0, len(rows) - common),
            "changed": changed,
            "removed": max(0, len(existing.rows) - common),
        }
    old = {key.key: row for key, row in zip(existing.keys, existing.rows)}
    new = {key.key: row for key, row in zip(keys, rows)}
    return {
        "added": len(new.keys() - old.keys()),
        "changed": sum(1 for key in new.keys() & old.keys() if new[key] != old[key]),
        "removed": len(old.keys() - new.keys()),
    }


def sample_scalar(value: Scalar) -> dict[str, Any]:
    if value.kind == "array":
        assert isinstance(value.value, tuple)
        first_count = min(LIMITS["sample_first"], len(value.value))
        last_start = max(first_count, len(value.value) - LIMITS["sample_last"])
        selected = value.value[:first_count] + value.value[last_start:]
        return {
            "type": "array<string>",
            "value": [display_text(str(item.value), 64) for item in selected],
            "count": len(value.value),
            "truncated": len(selected) < len(value.value),
        }
    rendered: Any = value.json_value()
    if isinstance(rendered, str):
        rendered = display_text(rendered, 64)
    return {"type": value.kind, "value": rendered}


def sample_row(
    index: int,
    row: dict[str, Scalar],
    headers: Sequence[str],
    mode: str,
    key: Scalar | None,
) -> dict[str, Any]:
    item: dict[str, Any] = {
        "record": index + 1,
        "fields": [
            {"name": display_text(header, 128), **sample_scalar(row[header])}
            for header in headers
            if header in row
        ],
    }
    if mode == "dictionary" and key is not None:
        item["key"] = sample_scalar(key)
    return item


def make_samples(
    rows: Sequence[dict[str, Scalar]],
    headers: Sequence[str],
    mode: str,
    keys: Sequence[Scalar],
) -> dict[str, Any]:
    first_count = min(LIMITS["sample_first"], len(rows))
    last_start = max(first_count, len(rows) - LIMITS["sample_last"])
    first = [sample_row(index, rows[index], headers, mode, keys[index] if keys else None) for index in range(first_count)]
    last = [sample_row(index, rows[index], headers, mode, keys[index] if keys else None) for index in range(last_start, len(rows))]
    return {"first": first, "last": last, "truncated": first_count + len(last) < len(rows)}


def convert(args: argparse.Namespace) -> Conversion:
    repo_root, _project, mapped, project_bytes = resolve_repository(args.repo_root)
    source_path, source_bytes, source_text = read_source(args.source)
    target_path, target_relative, target_bytes = resolve_target(repo_root, mapped, args.target)
    source_name = str(source_path)
    same_path = same_normalized_path(source_path, target_path)
    same_identity = (
        target_bytes is not None
        and file_identity(source_path)[:2] == file_identity(target_path)[:2]
    )
    if same_path or same_identity:
        reject(
            "source-target-alias",
            "CSV source and Luau target must not resolve to the same file or filesystem identity",
            source=source_name,
        )

    enforce_memory_budget(
        source=source_name,
        project_bytes=len(project_bytes),
        source_bytes=len(source_bytes),
        target_bytes=len(target_bytes or b""),
    )

    existing: ExistingData | None = None
    if target_bytes is not None:
        existing = parse_existing(
            target_bytes,
            target_relative,
            args.key_column,
            args.mode,
        )

    def delimiter_capacity(records: int, columns: int, cells: int) -> None:
        enforce_memory_budget(
            source=source_name,
            project_bytes=len(project_bytes),
            source_bytes=len(source_bytes),
            target_bytes=len(target_bytes or b""),
            output_bytes=LIMITS["output_bytes"],
            records=records,
            columns=columns,
            cells=cells,
        )

    delimiter_name, _delimiter, records, candidates = select_delimiter(
        source_text,
        source_name,
        args.delimiter,
        delimiter_capacity,
    )
    data_cells = sum(len(record.fields) for record in records[1:])
    enforce_memory_budget(
        source=source_name,
        project_bytes=len(project_bytes),
        source_bytes=len(source_bytes),
        target_bytes=len(target_bytes or b""),
        output_bytes=LIMITS["output_bytes"],
        records=max(0, len(records) - 1),
        columns=len(records[0].fields) if records else 0,
        cells=data_cells,
    )
    (
        headers,
        schemas,
        rows,
        empty_cells,
        generated_values,
        array_candidates,
        array_candidate_total,
    ) = infer_and_convert(records, source_name, args.types, args.array_delimiters)

    if existing is None:
        if args.mode is None:
            needs_input("mode-required", "A new target requires array or dictionary mode", "mode")
        mode = args.mode
    else:
        mode = existing.mode
        if args.mode is not None and args.mode != mode:
            reject("mode-conflict", f"Requested mode {args.mode!r} conflicts with detected existing mode {mode!r}", source=target_relative)

    key_column: str | None = None
    keys: list[Scalar] = []
    if mode == "dictionary":
        key_column = args.key_column or (existing.key_column if existing else None)
        if key_column is None:
            needs_input("key-column-required", "Dictionary mode requires an exact key column", "key_column")
        if key_column not in headers:
            reject("key-column-unknown", f"Dictionary key column {key_column!r} is not in the CSV header", source=source_name, column=key_column)
        keys = dictionary_keys(rows, key_column, source_name)
    elif args.key_column is not None:
        reject("key-column-array", "A key column is only valid in dictionary mode", source=source_name)

    prefix = existing.prefix if existing else "--!strict\n\n"
    output_bytes = render_module(
        prefix,
        headers,
        rows,
        mode,
        keys,
        source_name=source_name,
    )
    memory_estimate = enforce_memory_budget(
        source=source_name,
        project_bytes=len(project_bytes),
        source_bytes=len(source_bytes),
        target_bytes=len(target_bytes or b""),
        output_bytes=len(output_bytes),
        records=len(rows),
        columns=len(headers),
        cells=max(data_cells, generated_values),
    )
    diff = compute_diff(mode, rows, keys, existing)
    samples = make_samples(rows, headers, mode, keys)
    return Conversion(
        repo_root=repo_root,
        source_path=source_path,
        source_bytes=source_bytes,
        target_path=target_path,
        target_relative=target_relative,
        target_bytes=target_bytes,
        delimiter_name=delimiter_name,
        delimiter_candidates=candidates,
        headers=headers,
        schemas=schemas,
        array_candidates=array_candidates,
        array_candidate_total=array_candidate_total,
        rows=rows,
        keys=keys,
        mode=mode,
        key_column=key_column,
        output_bytes=output_bytes,
        diff=diff,
        empty_cells=empty_cells,
        samples=samples,
        project_sha256=sha256(project_bytes),
        mapped_roots=tuple(mapped),
        source_identity=file_identity(source_path),
        target_identity=file_identity(target_path) if target_bytes is not None else None,
        parent_identity=directory_identity(target_path.parent),
        memory_estimate_bytes=memory_estimate,
    )


def limits_payload() -> dict[str, int]:
    return dict(LIMITS)


def preview_payload(conversion: Conversion) -> dict[str, Any]:
    needs_array_decision = conversion.array_candidate_total > 0
    return {
        "status": "needs-input" if needs_array_decision else "ok",
        "operation": "preview",
        "source": {
            "display_path": display_text(str(conversion.source_path), 512),
            "bytes": len(conversion.source_bytes),
            "sha256": sha256(conversion.source_bytes),
        },
        "target": {
            "repo_relative_path": conversion.target_relative,
            "exists": conversion.target_bytes is not None,
            "bytes": len(conversion.target_bytes or b""),
            "sha256": sha256(conversion.target_bytes) if conversion.target_bytes is not None else None,
            "detected_mode": conversion.mode if conversion.target_bytes is not None else None,
        },
        "delimiter": {"selected": conversion.delimiter_name, "candidates": conversion.delimiter_candidates},
        "shape": {
            "records": len(conversion.rows),
            "columns": len(conversion.headers),
            "empty_cells": conversion.empty_cells,
        },
        "schema": conversion.schemas,
        "array_candidates": {
            "total": conversion.array_candidate_total,
            "shown": conversion.array_candidates,
            "truncated": conversion.array_candidate_total > len(conversion.array_candidates),
        },
        "mode": conversion.mode,
        "key_column": conversion.key_column,
        "diff": conversion.diff,
        "samples": conversion.samples,
        "diagnostics": {"total": 0, "shown": []},
        "required_decisions": ["array_delimiter"] if needs_array_decision else [],
        "output": {"bytes": len(conversion.output_bytes), "sha256": sha256(conversion.output_bytes)},
        "memory": {"estimated_peak_bytes": conversion.memory_estimate_bytes},
        "limits": limits_payload(),
    }


def current_preimage(path: Path) -> bytes | None:
    if not os.path.lexists(path):
        return None
    try:
        value = path.stat(follow_symlinks=False)
        if not stat.S_ISREG(value.st_mode):
            reject("target-changed", "Target entry is no longer a regular file")
        if value.st_size > LIMITS["target_bytes"]:
            reject("target-changed", "Target grew beyond the existing-target budget before replace")
        return path.read_bytes()
    except OSError as exc:
        reject("target-recheck", f"Target preimage cannot be re-read: {exc}")


def revalidate_conversion(conversion: Conversion, args: argparse.Namespace) -> None:
    repo_root, _project, mapped, project_bytes = resolve_repository(args.repo_root)
    mapped_identity = tuple(os.path.normcase(str(path)) for path in mapped)
    expected_mapped = tuple(os.path.normcase(str(path)) for path in conversion.mapped_roots)
    if (
        os.path.normcase(str(repo_root)) != os.path.normcase(str(conversion.repo_root))
        or sha256(project_bytes) != conversion.project_sha256
        or mapped_identity != expected_mapped
    ):
        reject("project-changed", "Repository or Rojo path mapping changed during apply")

    source_path, source_bytes, _source_text = read_source(args.source)
    if (
        os.path.normcase(str(source_path)) != os.path.normcase(str(conversion.source_path))
        or source_bytes != conversion.source_bytes
        or file_identity(source_path) != conversion.source_identity
    ):
        reject("source-changed", "CSV source changed during the apply transaction")

    target_path, target_relative, target_bytes = resolve_target(repo_root, mapped, args.target)
    target_identity = file_identity(target_path) if target_bytes is not None else None
    if (
        os.path.normcase(str(target_path)) != os.path.normcase(str(conversion.target_path))
        or target_relative != conversion.target_relative
        or directory_identity(target_path.parent) != conversion.parent_identity
        or target_bytes != conversion.target_bytes
        or target_identity != conversion.target_identity
    ):
        reject("target-changed", "Target path, parent, or preimage changed during apply")


def atomic_write(
    path: Path,
    output: bytes,
    expected_preimage: bytes | None,
    validator: Callable[[], None] | None = None,
) -> None:
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp.luau"
    descriptor: int | None = None
    temporary_identity: tuple[int, int] | None = None
    failure = os.environ.get("CSV_TO_LUAU_TEST_FAIL_AT")
    try:
        descriptor = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
        opened = os.fstat(descriptor)
        temporary_identity = (opened.st_dev, opened.st_ino)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = None
            if failure == "temporary-write":
                stream.write(output[: max(1, len(output) // 2)])
                raise OSError("injected temporary write failure")
            written = 0
            while written < len(output):
                count = stream.write(output[written:])
                if count is None or count <= 0:
                    raise OSError("Temporary output write did not make progress.")
                written += count
            if failure == "temporary-flush":
                raise OSError("injected temporary flush failure")
            stream.flush()
            os.fsync(stream.fileno())
        if failure == "temporary-close":
            raise OSError("injected temporary close failure")
        if failure == "unexpected-exception":
            raise RuntimeError("injected unexpected exception")
        if failure == "interrupt":
            raise KeyboardInterrupt("injected cancellation")
        if failure == "before-replace":
            raise OSError("injected failure before replace")
        if validator is not None:
            validator()
        if current_preimage(path) != expected_preimage:
            reject("target-changed", "Target preimage changed immediately before atomic replace")
        try:
            candidate = temporary.stat(follow_symlinks=False)
        except OSError as exc:
            reject("temporary-changed", f"Owned temporary cannot be revalidated: {exc}")
        if (
            temporary_identity is None
            or (candidate.st_dev, candidate.st_ino) != temporary_identity
            or not stat.S_ISREG(candidate.st_mode)
        ):
            reject(
                "temporary-changed",
                "Temporary entry changed before atomic replace",
            )
        if failure == "at-replace":
            raise OSError("injected failure at replace")
        os.replace(temporary, path)
        # Successful return is the commit point. No later exception may restore
        # the preimage, retry the write, or attempt rollback.
        if failure == "after-replace":
            raise RuntimeError("injected failure after successful replace")
        if failure == "after-replace-interrupt":
            raise KeyboardInterrupt("injected cancellation after successful replace")
    except OSError as exc:
        raise ConversionIssue(
            "rejected", "atomic-write", f"Atomic target write failed: {exc}"
        ) from exc
    finally:
        cleanup_errors: list[str] = []
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError as exc:
                cleanup_errors.append(f"descriptor close failed: {exc}")
        if os.path.lexists(temporary):
            try:
                observed = temporary.stat(follow_symlinks=False)
                observed_identity = (observed.st_dev, observed.st_ino)
                if temporary_identity is None or observed_identity != temporary_identity:
                    cleanup_errors.append(
                        "temporary cleanup refused an entry not proven to belong to this invocation"
                    )
                elif not stat.S_ISREG(observed.st_mode):
                    cleanup_errors.append(
                        "temporary cleanup refused a non-regular entry"
                    )
                else:
                    temporary.unlink()
            except OSError as exc:
                cleanup_errors.append(f"temporary cleanup failed: {exc}")
        if cleanup_errors:
            raise ConversionIssue(
                "rejected",
                "temporary-cleanup",
                "; ".join(cleanup_errors),
                capability=True,
            )


def validate_apply_hashes(conversion: Conversion, args: argparse.Namespace) -> None:
    expected_target = args.expect_target_sha256
    actual_target = sha256(conversion.target_bytes) if conversion.target_bytes is not None else "absent"
    if sha256(conversion.source_bytes) != args.expect_source_sha256:
        reject("source-changed", "CSV source hash no longer matches the successful preview")
    if actual_target != expected_target:
        reject("target-changed", "Target preimage hash no longer matches the successful preview")
    if sha256(conversion.output_bytes) != args.expect_output_sha256:
        reject("output-changed", "Recomputed output hash no longer matches the successful preview")


def apply_result_payload(conversion: Conversion, status: str) -> dict[str, Any]:
    return {
        "status": status,
        "operation": "apply",
        "target": {
            "repo_relative_path": conversion.target_relative,
            "bytes": len(conversion.output_bytes),
            "sha256": sha256(conversion.output_bytes),
        },
        "records": len(conversion.rows),
        "diff": conversion.diff if status == "written" else {"added": 0, "changed": 0, "removed": 0},
        "diagnostics": {"total": 0, "shown": []},
    }


def issue_payload(issue: ConversionIssue, operation: str) -> dict[str, Any]:
    shown = issue.diagnostics[:LIMITS["diagnostics"]]
    return {
        "status": issue.status,
        "operation": operation,
        "diagnostics": {"total": issue.diagnostic_total, "shown": shown},
        "required_decisions": issue.required_decisions,
        "output": None,
        "limits": limits_payload(),
    }


def encode_payload(payload: dict[str, Any]) -> bytes:
    def encode(value: dict[str, Any]) -> bytes:
        return json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8") + b"\n"

    encoded = encode(payload)
    if len(encoded) <= LIMITS["json_bytes"]:
        return encoded
    reduced = dict(payload)
    samples = reduced.get("samples")
    if isinstance(samples, dict):
        def compact_sample(item: Any) -> dict[str, Any]:
            if not isinstance(item, dict):
                return {"value": display_text(str(item), 64)}
            compact: dict[str, Any] = {}
            if "record" in item:
                compact["record"] = item["record"]
            if "key" in item:
                compact["key"] = item["key"]
            fields = item.get("fields")
            if isinstance(fields, list):
                compact["fields"] = [
                    {
                        "name": display_text(str(field.get("name", "")), 48),
                        "type": field.get("type"),
                        "value": display_text(str(field.get("value", "")), 48),
                    }
                    for field in fields
                    if isinstance(field, dict)
                ]
            return compact

        reduced["samples"] = {
            "first": [compact_sample(item) for item in samples.get("first", [])],
            "last": [compact_sample(item) for item in samples.get("last", [])],
            "truncated": True,
        }
    schema = reduced.get("schema")
    if isinstance(schema, list):
        reduced["schema"] = [
            {
                key: display_text(str(value), 128) if key == "name" else value
                for key, value in item.items()
            }
            if isinstance(item, dict)
            else {"name": display_text(str(item), 128)}
            for item in schema
        ]
    if isinstance(reduced.get("key_column"), str):
        reduced["key_column"] = display_text(reduced["key_column"], 256)
    diagnostics = reduced.get("diagnostics")
    if isinstance(diagnostics, dict):
        diagnostics = dict(diagnostics)
        diagnostics["shown"] = diagnostics.get("shown", [])[:5]
        reduced["diagnostics"] = diagnostics
    encoded = encode(reduced)
    if len(encoded) > LIMITS["json_bytes"]:
        if isinstance(samples, dict):
            compact = dict(reduced)
            compact["samples"] = {
                "first": [
                    {"record": item.get("record"), "fields_truncated": True}
                    if isinstance(item, dict) else {"fields_truncated": True}
                    for item in samples.get("first", [])
                ],
                "last": [
                    {"record": item.get("record"), "fields_truncated": True}
                    if isinstance(item, dict) else {"fields_truncated": True}
                    for item in samples.get("last", [])
                ],
                "truncated": True,
            }
            encoded = encode(compact)
            if len(encoded) <= LIMITS["json_bytes"]:
                return encoded
        minimal = {
            "status": payload.get("status", "rejected"),
            "operation": payload.get("operation"),
            "shape": payload.get("shape"),
            "mode": payload.get("mode"),
            "key_column": display_text(str(payload.get("key_column")), 256)
            if payload.get("key_column") is not None
            else None,
            "diff": payload.get("diff"),
            "output": payload.get("output"),
            "schema": reduced.get("schema"),
            "array_candidates": payload.get("array_candidates"),
            "diagnostics": {
                "total": 1,
                "shown": [
                    {
                        "code": "json-budget",
                        "message": "Verbose result metadata was compacted to the JSON budget",
                    }
                ],
            },
            "required_decisions": payload.get("required_decisions", []),
        }
        if isinstance(samples, dict):
            minimal["samples"] = {
                "first": [
                    {"record": item.get("record"), "fields_truncated": True}
                    if isinstance(item, dict) else {"fields_truncated": True}
                    for item in samples.get("first", [])
                ],
                "last": [
                    {"record": item.get("record"), "fields_truncated": True}
                    if isinstance(item, dict) else {"fields_truncated": True}
                    for item in samples.get("last", [])
                ],
                "truncated": True,
            }
        encoded = encode(minimal)
        if len(encoded) <= LIMITS["json_bytes"]:
            return encoded
        # With the normative 256 KiB limit this fixed envelope is always below
        # budget, even when every input-controlled string is enormous.
        fallback = {
            "status": display_text(str(payload.get("status", "rejected")), 32),
            "operation": display_text(str(payload.get("operation", "unknown")), 32),
            "diagnostics": {
                "total": 1,
                "shown": [
                    {
                        "code": "json-budget",
                        "message": "Result metadata exceeded the JSON budget",
                    }
                ],
            },
        }
        encoded = encode(fallback)
        if len(encoded) > LIMITS["json_bytes"]:
            raise ConversionIssue(
                "rejected",
                "json-budget",
                "The configured JSON budget is too small for a result envelope",
                capability=True,
            )
        return encoded
    return encoded


def emit_encoded(encoded: bytes) -> None:
    if os.environ.get("CSV_TO_LUAU_TEST_FAIL_AT") == "stdout":
        raise OutputFailure(False, OSError("injected stdout failure"))
    try:
        descriptor = sys.stdout.fileno()
    except BaseException as exc:
        raise OutputFailure(False, exc) from exc
    offset = 0
    while offset < len(encoded):
        try:
            pending = encoded[offset:]
            if (
                os.environ.get("CSV_TO_LUAU_TEST_FAIL_AT") == "stdout-partial"
                and len(pending) > 1
            ):
                pending = pending[: min(32, len(pending) - 1)]
            written = os.write(descriptor, pending)
        except BaseException as exc:
            raise OutputFailure(offset > 0, exc) from exc
        if written <= 0:
            raise OutputFailure(
                offset > 0,
                OSError("stdout accepted only a partial JSON result"),
            )
        offset += written
        if os.environ.get("CSV_TO_LUAU_TEST_FAIL_AT") == "stdout-partial":
            raise OutputFailure(True, OSError("injected failure after partial stdout"))


def emit_issue(issue: ConversionIssue, operation: str) -> None:
    try:
        emit_encoded(encode_payload(issue_payload(issue, operation)))
    except BaseException:
        # Output transport is outside the mutation boundary. A committed
        # target is never rolled back from this best-effort error reporting.
        pass


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        raise ConversionIssue("rejected", "arguments", message)


def build_parser() -> argparse.ArgumentParser:
    parser = JsonArgumentParser(prog="csv_to_luau.py")
    subparsers = parser.add_subparsers(dest="operation", required=True)
    for operation in ("preview", "apply"):
        command = subparsers.add_parser(operation)
        command.add_argument("--repo-root", required=True)
        command.add_argument("--source", required=True)
        command.add_argument("--target", required=True)
        command.add_argument("--mode", choices=("array", "dictionary"))
        command.add_argument("--key-column")
        command.add_argument("--delimiter", choices=tuple(DELIMITERS))
        command.add_argument("--type", dest="types", action="append", default=[])
        command.add_argument(
            "--array-delimiter",
            dest="array_delimiters",
            action="append",
            default=[],
        )
        if operation == "apply":
            command.add_argument("--expect-source-sha256", required=True)
            command.add_argument("--expect-target-sha256", required=True)
            command.add_argument("--expect-output-sha256", required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    operation = "unknown"
    try:
        if sys.version_info < (3, 10):
            raise ConversionIssue(
                "rejected",
                "python-version",
                "Python 3.10 or newer is required",
                capability=True,
            )
        args = build_parser().parse_args(argv)
        operation = args.operation
        if operation == "preview":
            conversion = convert(args)
            payload = preview_payload(conversion)
            emit_encoded(encode_payload(payload))
            return 2 if conversion.array_candidate_total > 0 else 0

        conversion = convert(args)
        if conversion.array_candidate_total > 0:
            needs_input(
                "array-delimiter-required",
                "Potential array delimiters require an explicit per-column decision before apply",
                "array_delimiter",
            )
        validate_apply_hashes(conversion, args)
        status = "unchanged" if conversion.target_bytes == conversion.output_bytes else "written"
        payload = apply_result_payload(conversion, status)
        if os.environ.get("CSV_TO_LUAU_TEST_FAIL_AT") == "encode-success":
            raise RuntimeError("injected success-result encoding failure")
        encoded = encode_payload(payload)
        if status == "unchanged":
            revalidate_conversion(conversion, args)
            emit_encoded(encoded)
            return 0

        atomic_write(
            conversion.target_path,
            conversion.output_bytes,
            conversion.target_bytes,
            lambda: revalidate_conversion(conversion, args),
        )
        if os.environ.get("CSV_TO_LUAU_TEST_FAIL_AT") == "after-commit":
            raise RuntimeError("injected post-commit failure")
        emit_encoded(encoded)
        return 0
    except OutputFailure as failure:
        if not failure.started:
            issue = ConversionIssue(
                "rejected",
                "output-transport",
                "Result transport failed before any JSON bytes were written",
                capability=True,
            )
            emit_issue(issue, operation)
        return 4
    except ConversionIssue as issue:
        emit_issue(issue, operation)
        if issue.status == "needs-input":
            return 2
        return 4 if issue.capability else 3
    except BaseException as exc:  # Fail closed without exposing a stack trace.
        issue = ConversionIssue("rejected", "internal", f"Internal conversion failure: {type(exc).__name__}", capability=True)
        emit_issue(issue, operation)
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
