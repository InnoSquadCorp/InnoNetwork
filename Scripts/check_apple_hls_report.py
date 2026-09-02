#!/usr/bin/env python3
"""Fail when an Apple hlsreport HTML artifact contains Must Fix issues."""

from __future__ import annotations

import argparse
import re
from html.parser import HTMLParser
from pathlib import Path


class TextCollector(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        value = " ".join(data.split())
        if value:
            self.parts.append(value)


def fail(message: str) -> None:
    raise SystemExit(f"apple-hls-report: {message}")


def visible_text(path: Path) -> str:
    if not path.is_file():
        fail(f"report is missing: {path}")
    if path.stat().st_size == 0:
        fail(f"report is empty: {path}")
    parser = TextCollector()
    try:
        parser.feed(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as error:
        fail(f"cannot read {path}: {error}")
    return " ".join(parser.parts)


def must_fix_section(report_text: str) -> str | None:
    headings = list(re.finditer(r"must\s+fix\s+issues", report_text, re.IGNORECASE))
    if not headings:
        return None

    start = headings[-1].end()
    end_match = re.search(
        r"should\s+fix\s+issues|report\s+information",
        report_text[start:],
        re.IGNORECASE,
    )
    end = start + end_match.start() if end_match else len(report_text)
    return report_text[start:end].strip(" \t\r\n:.-")


def validate(path: Path) -> None:
    report_text = visible_text(path)
    if not re.search(r"report\s+information", report_text, re.IGNORECASE):
        fail(f"report format is unrecognized: {path}")

    section = must_fix_section(report_text)
    if section is None:
        return
    if not section or re.fullmatch(
        r"(?:none|no\s+(?:must\s+fix\s+)?issues(?:\s+found)?)",
        section,
        re.IGNORECASE,
    ):
        return
    fail(f"Must Fix issues found in {path}: {section}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    arguments = parser.parse_args()
    validate(arguments.report.resolve())
    print(f"apple-hls-report: OK ({arguments.report})")


if __name__ == "__main__":
    main()
